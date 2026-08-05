/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// This file is compiled into the NSE target AND into `TabMailTests` (see the
// `TabMailTests` sources list in `project.yml`), so the staging writers can be
// driven by the code under test instead of a hand-mirrored copy of their SQL —
// a mirrored row cannot red-prove a fix that lives in `stageHeader`, because
// the fix is upstream of the row. In the test target the `Shared` types this
// file names (`RenderedBody`) belong to the main-app module and are internal,
// hence `@testable`; in the NSE they are compiled in directly and no import is
// wanted. `TABMAIL_TESTS` is set ONLY on the `TabMailTests` target
// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `project.yml`) — deliberately an
// explicit condition rather than `canImport(TabMail)`, whose value in an
// app-extension target depends on the module search paths and is not something
// this file should be betting on.
#if TABMAIL_TESTS
@testable import TabMail
#endif

enum NSEStagingDB {
    /// Open the shared staging database. Returns nil if unavailable.
    static func open() -> DatabaseQueue? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedNSEData.appGroupIdentifier
        )?.appendingPathComponent(NSEConfig.stagingDBFileName) else { return nil }

        var config = Configuration()
        config.busyMode = .timeout(NSEConfig.stagingDBBusyTimeoutSeconds)
        guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        ensureObservedUidValidityColumn(db: queue)
        return queue
    }

    // Note: TABLE creation lives in `AppDatabase.createNSEStagingDBIfNeeded`
    // (main-app-only). The main app always creates the DB + schema before the
    // NSE can run (NSE is a bundled extension — can't launch without the host
    // app having been installed + launched). No duplicate creator here.
    // `ensureObservedUidValidityColumn` below is the ONE exception, and why is
    // stated at it.

    /// Add `nse_processed_message.observedUidValidity` when the column is
    /// missing. Re-entrant and idempotent: `PRAGMA table_info` first, `ALTER
    /// TABLE … ADD COLUMN` only on absence — the same schema-evolution idiom
    /// `BodyAssetStore.migrateAttachmentIdentitySchema` uses for the OTHER
    /// App-Group sidecar the NSE writes, and for the same reason: this file is
    /// a SEPARATE database from `AppDatabase`, so it has no GRDB
    /// `DatabaseMigrator` and no numbered `vNN`.
    ///
    /// ⚑ WHY THE NSE ADDS IT AND NOT THE MAIN APP. `AppDatabase
    /// .createNSEStagingDBIfNeeded` gates its whole `ALTER` list behind a
    /// version marker in the App Group suite, so its schema only advances on a
    /// main-app LAUNCH. A push can reach the NSE before the first launch after
    /// an update — a window in which `stageHeader`/`persistProcessedMessage`
    /// would name a column that does not exist and lose the entire staged row.
    /// Running the ensure here, in the process that names the column, closes
    /// that window by construction.
    ///
    /// CONVERGENCE: a DB whose main-app migrator later gains this column in its
    /// own `ALTER` list finds it already present — that migrator swallows
    /// "duplicate column" by design — and a DB that only ever meets this
    /// function gets it here. Both end at the identical schema. Two processes
    /// racing the `ALTER` are serialized by SQLite's writer lock; the loser's
    /// `PRAGMA` re-read on its next open sees the column.
    ///
    /// Best-effort, matching every other writer in this type: a failure is
    /// logged, never thrown. There is deliberately NO fallback that writes the
    /// row without the stamp — an unstamped row is indistinguishable from a
    /// pre-upgrade one and would silently launder an unproven UID into the
    /// merge. A failure here fails this push's staging write instead, which the
    /// next push retries (the NSE is best-effort by policy).
    private static func ensureObservedUidValidityColumn(db: DatabaseQueue) {
        do {
            try db.write { db in
                guard try db.tableExists("nse_processed_message") else { return }
                let columns = Set(
                    try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
                        .map { $0["name"] as String }
                )
                guard !columns.contains("observedUidValidity") else { return }
                try db.execute(
                    sql: "ALTER TABLE nse_processed_message ADD COLUMN observedUidValidity INTEGER"
                )
            }
        } catch {
            NSELog.error("ensureObservedUidValidityColumn failed: \(error)")
        }
    }

    /// Check if a message was already AI-processed (by a previous NSE run).
    /// Returns the cached result if aiCompleted, nil otherwise.
    static func getCachedResult(
        db: DatabaseQueue,
        accountId: String,
        messageId: String
    ) -> (summaryBlurb: String?, summaryTodos: String?, actionTag: String?,
          reminderDate: String?, reminderTime: String?, reminderContent: String?)? {
        let id = "\(accountId):\(messageId)"
        return try? db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT summaryBlurb, summaryTodos, actionTag, reminderDate, reminderTime, reminderContent, aiCompleted
                FROM nse_processed_message WHERE id = ? AND aiCompleted = 1
                """, arguments: [id]) else { return nil }
            return (
                summaryBlurb: row["summaryBlurb"],
                summaryTodos: row["summaryTodos"],
                actionTag: row["actionTag"],
                reminderDate: row["reminderDate"],
                reminderTime: row["reminderTime"],
                reminderContent: row["reminderContent"]
            )
        }
    }

    /// Persist a processed message. Uses INSERT OR REPLACE for dedup.
    /// `renderedBody` (when provided) is persisted alongside AI results so the main
    /// app's merge can write MessageBody + FTS directly, avoiding a redundant
    /// re-fetch. `hasUnresolvedCIDs` flags whether the main app must re-render on
    /// first open (CIDs stayed as cid: refs because NSE has no attachment fetcher).
    static func persistProcessedMessage(
        db: DatabaseQueue,
        accountId: String, accountEmail: String, provider: String,
        message: NSEMessageMetadata,
        renderedBody: RenderedBody? = nil,
        summaryBlurb: String?, summaryTodos: String?, actionTag: String?,
        reminderDate: String?, reminderTime: String?, reminderContent: String?,
        historyId: String?, aiCompleted: Bool, notified: Bool
    ) {
        let id = "\(accountId):\(message.messageId)"
        let attachmentsJSON: String? = {
            guard let atts = renderedBody?.attachments, !atts.isEmpty else { return nil }
            return (try? JSONEncoder().encode(atts)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        // JSON-encode array fields for staging. Empty arrays persist as NULL
        // (not `"[]"`) so the merge's decode branch can fast-path the "no
        // chain" case — mirrors `MessageHeader.encodeReferences`, which
        // also stores NULL for empty references.
        func encodeJSONArray(_ arr: [String]) -> String? {
            guard !arr.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: arr),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
        let referencesJSON = encodeJSONArray(message.references)
        let providerLabelsJSON = encodeJSONArray(message.providerLabels)
        do {
            try db.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId, threadId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     toRaw, ccRaw, bccRaw, replyToRaw, inReplyTo, referencesJSON,
                     isRead, isFlagged, hasAttachments, providerLabelsJSON,
                     isReplied, isForwarded,
                     summaryBlurb, summaryTodos, actionTag, reminderDate, reminderTime, reminderContent,
                     processedAt, historyId, aiCompleted, notified,
                     htmlContent, textContent, attachmentsJSON, icsText, hasUnresolvedCIDs,
                     observedUidValidity, populated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?,
                            ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, ?, ?,
                            ?, 1)
                    """, arguments: [
                        // `folderPath` stores the provider-canonical folder path
                        // (Gmail: "INBOX"; Graph: parentFolderId; IMAP: "INBOX").
                        // The legacy `folderId` column is left in the schema for
                        // back-compat with older main-app versions but no new
                        // writes go to it; AppDatabase's v3 migration backfills
                        // folderPath from folderId for pre-existing rows.
                        //
                        // `populated=1` literal in the VALUES list above is the
                        // sole writer that flips the merge-visibility flag.
                        // AIOwnershipLease.ensureRow leaves it at the default 0
                        // so half-written lease placeholders stay invisible to
                        // the merge SELECT and get reaped on age.
                        id, accountId, accountEmail, provider, message.messageId,
                        message.rfc822MessageId, message.threadId, message.folderPath,
                        message.subject, message.senderName, message.senderEmail,
                        message.snippet, message.date?.timeIntervalSince1970,
                        message.to, message.cc, message.bcc, message.replyTo,
                        message.inReplyTo, referencesJSON,
                        message.isRead ? 1 : 0, message.isFlagged ? 1 : 0,
                        message.hasAttachments ? 1 : 0, providerLabelsJSON,
                        message.isReplied ? 1 : 0, message.isForwarded ? 1 : 0,
                        summaryBlurb, summaryTodos, actionTag,
                        reminderDate, reminderTime, reminderContent,
                        Date().timeIntervalSince1970, historyId,
                        aiCompleted ? 1 : 0, notified ? 1 : 0,
                        renderedBody?.htmlContent, renderedBody?.textContent,
                        attachmentsJSON, renderedBody?.icsText,
                        (renderedBody?.hasUnresolvedCIDs ?? false) ? 1 : 0,
                        // The epoch the NSE's own SELECT observed for this
                        // row's folder (nil for Gmail/Graph and whenever the
                        // server reported none) — see
                        // `NSEMessageMetadata.observedUidValidity`.
                        message.observedUidValidity
                    ])
            }
        } catch {
            NSELog.error("persistProcessedMessage failed: \(error)")
        }
    }

    // MARK: - Gradual staging (header → body → summary → [terminal] persist)
    //
    // Instead of one big `persistProcessedMessage` at the very end (after AI),
    // the NSE writes the row in stages so the main app's merge can surface the
    // message the moment its header is known, then fill in body and AI as they
    // land. The first writer (`stageHeader`) flips `populated=1`; `mergeNSEStagingData`
    // applies whatever subset is present and keeps the row until AI completes.

    /// Is the row already staged at `id` POSITIVELY a different message than the
    /// one now being staged? Returns `true` only on evidence of disagreement,
    /// never on an absence of evidence that it is the same message.
    ///
    /// The two doors are `NSEDataBridge.nseMergeIdentityConfirmed`'s, with the
    /// same precedence, so the staging side and the merge side cannot drift on
    /// what "a different message" means:
    ///  (a) RFC door — FIRST and UNCONDITIONAL. Both sides' normalized RFC 822
    ///      Message-IDs present and UNEQUAL ⇒ different, and that verdict is
    ///      never overridden by an epoch agreement.
    ///  (b) Epoch door — consulted ONLY when the RFC door could not adjudicate.
    ///      Both `observedUidValidity`s present and UNEQUAL ⇒ different: the two
    ///      runs read the same folder under two different UIDVALIDITYs, so this
    ///      row's UID-addressed `messageId` does not name the same message twice.
    ///
    /// Nil on either side of both doors ⇒ `false` (retain). That is the whole
    /// point: a nil is an unanswered question, not a mismatch — the same rule
    /// `NSEMessageMetadata.observedUidValidity` states for the durable side.
    ///
    /// ⚑ `nseMergeIdentityConfirmed`'s epoch door additionally requires
    /// `!folderQuarantined`; that guard is deliberately NOT carried here, and the
    /// invariant behind it does not apply. There it compares a live NSE
    /// observation against the DURABLE `Folder.lastKnownUidValidity`, which lags
    /// mid-reset, so a disagreement can mean "our stamp has not caught up". Here
    /// BOTH values are live SELECT observations the NSE made itself, of the same
    /// folder, at two different times — no third party's staleness can manufacture
    /// a disagreement, so a disagreement is the turnover itself.
    ///
    /// Uses `MessageIdentity.comparableRfc822Identity` — the tree's single
    /// identity-COMPARISON normalizer, deliberately NOT `usableRfc822Tail` (whose
    /// extra `':'` rejection exists for key MINTING and would call a legitimate
    /// `no-fold-literal` domain "not the same message").
    private static func stagedIdentityPositivelyDiffers(
        db: Database, id: String, message: NSEMessageMetadata
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT rfc822MessageId, observedUidValidity FROM nse_processed_message WHERE id = ?",
            arguments: [id]
        ) else { return false }

        if let incoming = MessageIdentity.comparableRfc822Identity(message.rfc822MessageId),
           let stored = MessageIdentity.comparableRfc822Identity(row["rfc822MessageId"]) {
            return incoming != stored
        }
        if let incoming = message.observedUidValidity,
           let stored = row["observedUidValidity"] as Int? {
            return incoming != stored
        }
        return false
    }

    /// Stage 1 — the message header (everything needed to DISPLAY the row) +
    /// `populated=1`, so the merge surfaces the message BEFORE body fetch and AI.
    /// UPSERT (not INSERT OR REPLACE) so a pre-existing row — a prior duplicate-
    /// push run that already carries body/AI, or the `AIOwnershipLease` placeholder
    /// — keeps those columns; only the header fields + `populated` are (re)written.
    /// `processedAt` is set on first insert only (it anchors the orphan/abandon age
    /// window); the conflict path leaves it untouched.
    ///
    /// ⚑ EXCEPT when the incoming identity POSITIVELY disagrees with the identity
    /// already on the row (`IOS-NSE-005`). The staging key is
    /// `"<accountId>:<messageId>"` — no folder, no epoch, no generation — and on
    /// IMAP a UIDVALIDITY turnover can reissue the same UID to a DIFFERENT
    /// message. Retaining the payload then splices the predecessor's body,
    /// summary, todos, reminder and action tag onto the successor's identity, and
    /// nothing downstream can tell: `getCachedResult` (`WHERE id = ? AND
    /// aiCompleted = 1`) serves it as the successor's NOTIFICATION and returns
    /// before this run's own terminal write, and the merge's new-header arm
    /// (`NSEDataBridge.insertNewHeaderFromStaging`) writes it durably — poisoning
    /// `messageAICache` under the successor's RFC key and queueing a `setTag`
    /// keyword write for the predecessor's tag against the successor. That is a
    /// C3 misattribution no sync pass repairs.
    ///
    /// So on positive disagreement the row is DELETED first, inside this same
    /// write transaction, and the statement below lands as a plain INSERT — every
    /// column stageHeader does not write returns to its schema default (payload
    /// NULL, `aiCompleted`/`notified` 0, `processedAt` re-anchored to now, the
    /// AI-ownership lease cleared, which is correct because a lease held for the
    /// predecessor says nothing about the successor).
    ///
    /// Because `stageHeader` runs strictly BEFORE the peer probe and before
    /// `getCachedResult` in `NotificationService.process`, clearing here closes
    /// the notification half and the durable half with one write. That ordering
    /// is load-bearing — do not move this call later in the run.
    ///
    /// The gate is POSITIVE evidence of a different message, never absence of
    /// evidence that it is the same one. Clearing on any conflict would destroy
    /// the two cases the retention exists for: a re-push of the SAME message
    /// (which must keep the body and AI a previous run already paid for) and the
    /// `AIOwnershipLease` placeholder (`populated = 0`, both identity columns
    /// NULL), which must survive to be filled in.
    static func stageHeader(
        db: DatabaseQueue,
        accountId: String, accountEmail: String, provider: String,
        message: NSEMessageMetadata, historyId: String?
    ) {
        let id = "\(accountId):\(message.messageId)"
        func encodeJSONArray(_ arr: [String]) -> String? {
            guard !arr.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: arr),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
        let referencesJSON = encodeJSONArray(message.references)
        let providerLabelsJSON = encodeJSONArray(message.providerLabels)
        do {
            try db.write { db in
                // IOS-NSE-005 — see the doc comment. The retained payload is
                // only safe while the row still names the SAME message; on
                // positive disagreement drop it so the statement below lands as
                // a plain INSERT with the payload columns at their defaults.
                if try stagedIdentityPositivelyDiffers(db: db, id: id, message: message) {
                    try db.execute(
                        sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: [id])
                }
                // `observedUidValidity` is on the ON CONFLICT SET list below
                // because it is IDENTITY, not payload: a re-push must overwrite
                // it with the epoch THIS run's SELECT observed, exactly as the
                // list already overwrites `rfc822MessageId` / `folderPath`. The
                // columns this UPSERT deliberately RETAINS are the body/AI
                // payload; keeping a PREVIOUS run's epoch beside a re-read UID
                // is precisely what would misattribute the row.
                try db.execute(sql: """
                    INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId, threadId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     toRaw, ccRaw, bccRaw, replyToRaw, inReplyTo, referencesJSON,
                     isRead, isFlagged, hasAttachments, providerLabelsJSON,
                     isReplied, isForwarded, processedAt, historyId, observedUidValidity, populated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET
                        accountEmail = excluded.accountEmail, provider = excluded.provider,
                        rfc822MessageId = excluded.rfc822MessageId, threadId = excluded.threadId,
                        folderPath = excluded.folderPath, subject = excluded.subject,
                        senderName = excluded.senderName, senderEmail = excluded.senderEmail,
                        snippet = excluded.snippet, date = excluded.date,
                        toRaw = excluded.toRaw, ccRaw = excluded.ccRaw, bccRaw = excluded.bccRaw,
                        replyToRaw = excluded.replyToRaw, inReplyTo = excluded.inReplyTo,
                        referencesJSON = excluded.referencesJSON, isRead = excluded.isRead,
                        isFlagged = excluded.isFlagged, hasAttachments = excluded.hasAttachments,
                        providerLabelsJSON = excluded.providerLabelsJSON,
                        isReplied = excluded.isReplied, isForwarded = excluded.isForwarded,
                        historyId = excluded.historyId,
                        observedUidValidity = excluded.observedUidValidity, populated = 1
                    """, arguments: [
                        id, accountId, accountEmail, provider, message.messageId,
                        message.rfc822MessageId, message.threadId, message.folderPath,
                        message.subject, message.senderName, message.senderEmail,
                        message.snippet, message.date?.timeIntervalSince1970,
                        message.to, message.cc, message.bcc, message.replyTo,
                        message.inReplyTo, referencesJSON,
                        message.isRead ? 1 : 0, message.isFlagged ? 1 : 0,
                        message.hasAttachments ? 1 : 0, providerLabelsJSON,
                        message.isReplied ? 1 : 0, message.isForwarded ? 1 : 0,
                        Date().timeIntervalSince1970, historyId,
                        message.observedUidValidity
                    ])
            }
        } catch {
            NSELog.error("stageHeader failed: \(error)")
        }
    }

    /// Stage 2 — add the rendered body to an already-staged header row. No-op if
    /// NSE didn't render one. Idempotent plain UPDATE.
    static func stageBody(
        db: DatabaseQueue,
        accountId: String, messageId: String, renderedBody: RenderedBody?
    ) {
        guard let rb = renderedBody else { return }
        let id = "\(accountId):\(messageId)"
        let attachmentsJSON: String? = {
            guard !rb.attachments.isEmpty else { return nil }
            return (try? JSONEncoder().encode(rb.attachments)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        do {
            try db.write { db in
                try db.execute(sql: """
                    UPDATE nse_processed_message SET
                        htmlContent = ?, textContent = ?, attachmentsJSON = ?,
                        icsText = ?, hasUnresolvedCIDs = ?
                    WHERE id = ?
                    """, arguments: [
                        rb.htmlContent, rb.textContent, attachmentsJSON,
                        rb.icsText, rb.hasUnresolvedCIDs ? 1 : 0, id
                    ])
            }
        } catch {
            NSELog.error("stageBody failed: \(error)")
        }
    }

    /// Stage 3a — summary (computed before the action vote). Updates the
    /// summary/reminder columns so a merge landing during the action vote shows
    /// the summary. Does NOT set `aiCompleted` — the terminal `persistProcessedMessage`
    /// flips that once the action lands.
    static func stageSummary(
        db: DatabaseQueue,
        accountId: String, messageId: String,
        summaryBlurb: String?, summaryTodos: String?,
        reminderDate: String?, reminderTime: String?, reminderContent: String?
    ) {
        let id = "\(accountId):\(messageId)"
        do {
            try db.write { db in
                try db.execute(sql: """
                    UPDATE nse_processed_message SET
                        summaryBlurb = ?, summaryTodos = ?,
                        reminderDate = ?, reminderTime = ?, reminderContent = ?
                    WHERE id = ?
                    """, arguments: [
                        summaryBlurb, summaryTodos,
                        reminderDate, reminderTime, reminderContent, id
                    ])
            }
        } catch {
            NSELog.error("stageSummary failed: \(error)")
        }
    }

    /// Persist messages removed from inbox (archived/deleted/moved).
    /// Main app merges these on wake to update GRDB.
    static func persistInboxRemovals(
        db: DatabaseQueue,
        accountId: String,
        messageIds: [String]
    ) {
        guard !messageIds.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        do {
            try db.write { db in
                for messageId in messageIds {
                    let id = "\(accountId):\(messageId)"
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [id, accountId, messageId, now])
                }
            }
        } catch {
            NSELog.error("persistInboxRemovals failed: \(error)")
        }
    }

    /// Persist a task result for main app to consume.
    static func persistTaskResult(
        db: DatabaseQueue,
        taskName: String, taskInstruction: String, result: String
    ) {
        do {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO nse_pending_task_result (taskName, taskInstruction, result, timestamp)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [taskName, taskInstruction, result, Date().timeIntervalSince1970])
            }
        } catch {
            NSELog.error("persistTaskResult failed: \(error)")
        }
    }
}
