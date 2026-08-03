/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

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

    /// Stage 1 — the message header (everything needed to DISPLAY the row) +
    /// `populated=1`, so the merge surfaces the message BEFORE body fetch and AI.
    /// UPSERT (not INSERT OR REPLACE) so a pre-existing row — a prior duplicate-
    /// push run that already carries body/AI, or the `AIOwnershipLease` placeholder
    /// — keeps those columns; only the header fields + `populated` are (re)written.
    /// `processedAt` is set on first insert only (it anchors the orphan/abandon age
    /// window); the conflict path leaves it untouched.
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
