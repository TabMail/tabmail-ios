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
    ///
    /// ⚑ ADDRESSED BY `id`, ADMITTED BY IDENTITY (`IOS-NSE-006`) — the READ half
    /// of the same class as `stageBody` / `stageSummary` / `persistProcessedMessage`.
    /// `id` is `"<accountId>:<messageId>"` and on IMAP `messageId` is the UID, an
    /// ADDRESS in a numbering space. `WHERE id = ? AND aiCompleted = 1` alone is
    /// an address plus a completion flag with NO identity term, so after a
    /// UIDVALIDITY turnover reissued the UID it serves the PREDECESSOR's summary,
    /// todos, reminder and action tag as the SUCCESSOR's notification —
    /// `NotificationService.process` hands the hit straight to
    /// `EmailNotificationBuilder.fill` beside the successor's own sender, subject
    /// and body. A notification that has been delivered and seen cannot be
    /// un-shown by any later sync, which is what puts this in the
    /// non-recoverable C3-misattribution set.
    ///
    /// ⚠️ **THE CALL ORDERING IS NOT THE GUARD, and the claim that it was is
    /// RETRACTED here.** `Companion/Memory/Current/107-…` left this function alone
    /// on the reasoning *"`stageHeader` runs strictly before it in
    /// `NotificationService.process`, so the row's identity is already this run's;
    /// the ordering IS the guard"*. `stageHeader` returns `Void` and wraps its
    /// whole write in `do { … } catch { NSELog.error(…) }`, so a THROWN write is
    /// logged and swallowed and **no caller can observe that the row was never
    /// re-headed**. The staging DB is a non-WAL cross-process App Group file, so
    /// `SQLITE_BUSY` under contention is a live outcome, not a hypothetical. The
    /// ordering establishes only that `stageHeader` was CALLED — never that it
    /// LANDED (`MIS-024`: reading a mechanism proves it is correct, never that it
    /// ran before the damage).
    ///
    /// FAIL DIRECTION — the same as `stageHeader`'s and the OPPOSITE of
    /// `stageBody`'s, because the question here is *may I REUSE payload already on
    /// the row*, not *may I ADD payload to it*. Only POSITIVE evidence of a
    /// different message turns a hit into a miss: an unanswerable identity (no RFC
    /// on either side, no epoch on either side) still SERVES, exactly as
    /// `unanswerableIdentityRetainsRatherThanClears` and
    /// `unanswerableIdentityWritesRatherThanRefuses` pin it. Refusing on absence of
    /// evidence would be the mirror image (`MIS-005`) and would make every rfc-less,
    /// epoch-less message recompute its AI on every duplicate push. A miss costs
    /// only that: the run computes its own summary through the path that already
    /// works.
    static func getCachedResult(
        db: DatabaseQueue,
        accountId: String,
        message: NSEMessageMetadata
    ) -> (summaryBlurb: String?, summaryTodos: String?, actionTag: String?,
          reminderDate: String?, reminderTime: String?, reminderContent: String?)? {
        let id = "\(accountId):\(message.messageId)"
        return try? db.read { db in
            // Same two doors, same precedence, as every writer in this file — so
            // the read side and the write side cannot drift on what "a different
            // message" means.
            guard try !stagedIdentityPositivelyDiffers(db: db, id: id, message: message) else {
                NSELog.error(
                    "getCachedResult REFUSED at \(id): the staged row names a different message "
                    + "(IOS-NSE-006) — this run computes its own AI rather than serving the "
                    + "predecessor's as its notification")
                return nil
            }
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
    ///
    /// ⚑ THE THIRD WRITER OF THE `IOS-NSE-006` CLASS, guarded here rather than
    /// left as the one exception — the class is *"a writer keyed on an ADDRESS
    /// assuming it still names the same message"*, and enumerating it by the two
    /// writers a finding happened to name would be `MIS-006` (fixed the
    /// instance, not the class). Its damage differs from the staging writers' and
    /// is stated rather than assumed: `INSERT OR REPLACE` rewrites the WHOLE row,
    /// so a zombie predecessor resuming past its terminal write does not splice
    /// mixed identities — it REPLACES the successor's staged row outright,
    /// destroying a push that was never merged (a dropped message) and
    /// resurrecting a predecessor the address no longer holds.
    ///
    /// Same two doors, same fail direction as `stageBody`: an absent row and an
    /// unanswerable identity both WRITE — the first is the ordinary first insert
    /// and the second is the rfc-less message accumulating across wakes — and
    /// only POSITIVE evidence of a different message suppresses it. On the
    /// natural path the row was created by THIS run's `stageHeader`, so the
    /// identity agrees and the guard is transparent.
    ///
    /// Returns `true` only when the row was actually written. `false` means the
    /// identity guard REFUSED it or the write THREW — both already logged here
    /// with their reason. Deliberately NOT `@discardableResult`: the caller's
    /// `NSE step7: persisted …` line used to fire unconditionally, so a
    /// sysdiagnose read `persistProcessedMessage REFUSED …` immediately followed
    /// by a claim that the write had landed. Forcing every caller to name the
    /// outcome is what keeps that from coming back.
    static func persistProcessedMessage(
        db: DatabaseQueue,
        accountId: String, accountEmail: String, provider: String,
        message: NSEMessageMetadata,
        renderedBody: RenderedBody? = nil,
        summaryBlurb: String?, summaryTodos: String?, actionTag: String?,
        reminderDate: String?, reminderTime: String?, reminderContent: String?,
        historyId: String?, aiCompleted: Bool, notified: Bool
    ) -> Bool {
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
            var refused = false
            try db.write { db in
                if try stagedIdentityPositivelyDiffers(db: db, id: id, message: message) {
                    refused = true
                    return
                }
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
            if refused {
                NSELog.error(
                    "persistProcessedMessage REFUSED at \(id): the staged row now names a "
                    + "different message (IOS-NSE-006) — dropping a terminal write computed "
                    + "for the predecessor rather than replacing the successor's row")
            }
            return !refused
        } catch {
            NSELog.error("persistProcessedMessage failed: \(error)")
            return false
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
    /// ⚑ Since 2026-08-06 `nseMergeIdentityConfirmed`'s epoch door also requires the
    /// durable row to be in the SAME folder the staged message was observed in,
    /// because `DurableIdentityLookup.find` step 2 is folder-blind and can hand it a
    /// row from another folder, where a UID-vs-epoch comparison is evidence about the
    /// wrong thing. That guard is likewise not carried here and cannot be: this
    /// function compares two observations of ONE staging row, so there is no second
    /// folder to disagree with. The precedence of the two doors is still identical;
    /// only the merge side's operand set is wider.
    ///
    /// Uses `MessageIdentity.comparableRfc822Identity`, deliberately NOT
    /// `usableRfc822Tail` (whose extra `':'` rejection exists for key MINTING and
    /// would call a legitimate `no-fold-literal` domain "not the same message").
    ///
    /// ⚠ THIS SAID "the tree's SINGLE identity-COMPARISON normalizer" until
    /// R13-U8, and it is not — `SyncEngineEpochVerify` compares through
    /// `EmailFilter.normalizeMessageId` directly at three sites. See the same
    /// correction on `NSEDataBridge.nseMergeIdentityConfirmed` for why both exist:
    /// `comparableRfc822Identity` is `normalizeMessageId` plus REJECTION, so it
    /// answers `nil` where the raw normalizer answers a string, and an identity
    /// DOOR must not let a malformed value confirm anything.
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
    ///
    /// ⚑ ADDRESSED BY `id`, ADMITTED BY IDENTITY (`IOS-NSE-006`). `id` is
    /// `"<accountId>:<messageId>"` and on IMAP `messageId` is the UID — an
    /// ADDRESS in a numbering space, not an identity. This UPDATE used to carry
    /// no identity term at all, so a PREDECESSOR run resuming from its body
    /// fetch after a successor had re-headed the row wrote the predecessor's
    /// body onto the successor: the merge then stores it as the successor's
    /// `MessageBody`, indexes the predecessor's text under the successor's
    /// header id and sets `bodyComplete = 1`, which the body queue
    /// (`bodyComplete = 0`) never revisits. That is a C3 misattribution no sync
    /// pass repairs — the same class `stageHeader` closes for the payload it
    /// RETAINS, arriving through the writer instead of through the UPSERT.
    ///
    /// The admission test is `stagedIdentityPositivelyDiffers` — the SAME two
    /// doors, in the same precedence, that `stageHeader` and
    /// `NSEDataBridge.nseMergeIdentityConfirmed` use, so the three cannot drift
    /// on what "a different message" means.
    ///
    /// FAIL DIRECTION, and it is the opposite of `stageHeader`'s: there the
    /// question is "may I KEEP payload already on the row", here it is "may I
    /// ADD payload to it", so the safe answer to an unanswerable identity is to
    /// WRITE. Skipping on absence of evidence would stop an rfc-less, epoch-less
    /// message ever accumulating a body across wakes (`MIS-IOS-004` — "could not
    /// determine" is not "provider says different"). Only POSITIVE evidence of a
    /// different message suppresses the write.
    ///
    /// The dropped payload is not silently lost: the row it was computed for is
    /// provably gone from this address, the main app's body queue re-fetches for
    /// whoever holds the address now, and the refusal is written to the NSE's
    /// durable log channel rather than to a detached console (topic 105).
    ///
    /// Returns `true` only when the UPDATE actually ran. `false` covers all three
    /// non-writing outcomes — nothing to stage (`renderedBody == nil`), the
    /// identity guard refused, or the write threw — the latter two already logged
    /// here with their reason. Deliberately NOT `@discardableResult`; see
    /// `persistProcessedMessage` for why the caller must name the outcome.
    static func stageBody(
        db: DatabaseQueue,
        accountId: String, message: NSEMessageMetadata, renderedBody: RenderedBody?
    ) -> Bool {
        guard let rb = renderedBody else { return false }
        let id = "\(accountId):\(message.messageId)"
        let attachmentsJSON: String? = {
            guard !rb.attachments.isEmpty else { return nil }
            return (try? JSONEncoder().encode(rb.attachments)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        do {
            // The identity read and the write share ONE transaction: a check
            // outside it is a TOCTOU seam a concurrent re-head can slip through.
            var refused = false
            try db.write { db in
                if try stagedIdentityPositivelyDiffers(db: db, id: id, message: message) {
                    refused = true
                    return
                }
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
            if refused {
                NSELog.error(
                    "stageBody REFUSED at \(id): the staged row now names a different message "
                    + "(IOS-NSE-006) — dropping a body computed for the predecessor")
            }
            return !refused
        } catch {
            NSELog.error("stageBody failed: \(error)")
            return false
        }
    }

    /// Stage 3a — summary (computed before the action vote). Updates the
    /// summary/reminder columns so a merge landing during the action vote shows
    /// the summary. Does NOT set `aiCompleted` — the terminal `persistProcessedMessage`
    /// flips that once the action lands.
    ///
    /// ⚑ ADDRESSED BY `id`, ADMITTED BY IDENTITY (`IOS-NSE-006`) — see
    /// `stageBody` for the full statement of the class, the two doors and the
    /// fail direction; this is the same guard on the AI half. It is the worse
    /// half of the two: the summary/todos/reminder a predecessor computed are
    /// merged durably onto the successor's header and cached in `messageAICache`
    /// under the SUCCESSOR's RFC key, so the poisoning survives every later UID
    /// re-key and is a permanent cache HIT.
    ///
    /// ⚠️ The existing `deliveredFlag.hasFired()` checkpoint at this call site is
    /// NOT this guard and does not subsume it. That flag is per-RUN — it asks
    /// "did MY run's watchdog already deliver", which says nothing about whether
    /// a LATER run has since re-headed the row. The two are complementary and
    /// both are load-bearing.
    static func stageSummary(
        db: DatabaseQueue,
        accountId: String, message: NSEMessageMetadata,
        summaryBlurb: String?, summaryTodos: String?,
        reminderDate: String?, reminderTime: String?, reminderContent: String?
    ) {
        let id = "\(accountId):\(message.messageId)"
        do {
            var refused = false
            try db.write { db in
                if try stagedIdentityPositivelyDiffers(db: db, id: id, message: message) {
                    refused = true
                    return
                }
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
            if refused {
                NSELog.error(
                    "stageSummary REFUSED at \(id): the staged row now names a different message "
                    + "(IOS-NSE-006) — dropping AI computed for the predecessor")
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
