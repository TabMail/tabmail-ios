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
        return try? DatabaseQueue(path: url.path, configuration: config)
    }

    // Note: schema creation lives in `AppDatabase.createNSEStagingDBIfNeeded`
    // (main-app-only). The main app always creates the DB + schema before the
    // NSE can run (NSE is a bundled extension — can't launch without the host
    // app having been installed + launched). No duplicate creator here.

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
                     populated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?,
                            ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, ?, ?,
                            1)
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
                        (renderedBody?.hasUnresolvedCIDs ?? false) ? 1 : 0
                    ])
            }
        } catch {
            NSELog.error("persistProcessedMessage failed: \(error)")
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
