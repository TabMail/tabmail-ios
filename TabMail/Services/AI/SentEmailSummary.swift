/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The summary of an email the user just sent, made when it is queued: the
/// chat's Sending bubble shows it while the email is still going out, and the email's Sent copy
/// takes it from the AI cache when it arrives, so the two never differ. It is the ordinary summary
/// call on the final email (`isSentByUser`), written under the Sent folder and the email's own
/// Message-ID, which the outbox row carries from the queue write. Only with the chat view on.
///
/// Thunderbird summarizes a sent email when it processes its Sent copy; this only moves the trigger
/// earlier (ADR-IOS-008, recorded divergence). Nothing new is stored: it is the AI cache entry the
/// Sent copy would have written. An entry no Sent copy takes (the send was undone, or Outlook filed
/// its own copy under a Message-ID of its own) is purged with the other orphaned AI cache entries.
///
/// An email sent with its text version already in hand makes no summary call: the text version
/// written with its body (the chat's field composition, the AI Suggestion, an edit of the card),
/// sent with that body unchanged, goes into the same entry with the queue write
/// (`writeTextVersion`). Only an email whose body was edited by hand, or that came with no text
/// version, is summarized (ADR-IOS-114 decision 10).
enum SentEmailSummary {
    /// Whether a send summarizes its email now: the chat view is on and AI may run. Read once, at
    /// the queue write.
    @MainActor static func mayRun() -> Bool {
        // An open goes to the chat only with the chat view and AI on, or as a tutorial run teaches
        // (`ChatViewConfig.opensInChat`, through the tutorial-aware gate `followingTutorial`).
        ChatViewConfig.opensInChat
            && TabMailAuthService.hasSession()
            && UserDefaults.standard.bool(forKey: AgeAndTermsConsent.completedKey)
    }

    /// What the summary call needs, read from the queued outbox row.
    struct Source: Sendable {
        let accountId: String
        let sentFolderPath: String
        let messageId: String
        let subject: String
        let senderName: String
        let senderEmail: String
        let to: String
        let cc: String
        let plainText: String
        let userAddresses: [String]
    }

    static func source(outboxId: String, db: Database) throws -> Source? {
        guard let row = try OutboxMessage.fetchOne(db, key: outboxId),
              let messageId = row.sentMessageId,
              let account = try Account.fetchOne(db, key: row.accountId),
              let sent = try Folder
                .filter(Column("accountId") == row.accountId && Column("role") == FolderRole.sent.rawValue)
                .fetchOne(db) else { return nil }
        return Source(
            accountId: row.accountId,
            sentFolderPath: sent.path,
            messageId: EmailFilter.normalizeMessageId(messageId),
            subject: row.subject,
            senderName: account.displayName,
            senderEmail: account.emailAddress,
            to: row.to.joined(separator: ", "),
            cc: row.cc.joined(separator: ", "),
            plainText: row.isHTML ? EmailFilter.htmlToPlainText(row.body) : row.body,
            userAddresses: try Account.fetchAll(db).map(\.emailAddress))
    }

    /// Summarizes the queued email `outboxId` and writes the result to the AI cache under its Sent
    /// folder and Message-ID. A Sent copy already there without a summary takes it at once.
    static func summarize(outboxId: String, aiService: AIService = .shared) async {
        await write(outboxId: outboxId) { source in
            try await aiService.generateSummary(
                subject: source.subject,
                from: source.senderName,
                fromAddress: source.senderEmail,
                date: Date(),
                bodyText: source.plainText,
                htmlContent: nil,
                userName: source.senderName,
                kbText: PromptStore.kbTextSnapshot(),
                recipientStatus: PromptVariables.classifyRecipientStatus(
                    toField: source.to, ccField: source.cc, fromField: source.senderEmail,
                    claimEmails: [source.senderEmail], suppressEmails: source.userAddresses),
                isSentByUser: true)
        }
    }

    /// The demo account's own sends, which make no AI call (the guided tutorial is scripted
    /// and has no TabMail session): the summary is the email's own words, without the
    /// quoted email, written exactly as `summarize` writes, so its Sending bubble and Sent copy
    /// carry a text message like every other email's.
    static func summarizeLocally(outboxId: String) async {
        await write(outboxId: outboxId) { source in
            let words = EmailFilter.splitMessageAndQuotes(source.plainText).message
            return SummaryResult(
                blurb: words, todos: nil, reminderDate: nil, reminderTime: nil, reminderContent: nil,
                textMessage: words)
        }
    }

    /// The text version a send writes with its queue write, or nil when its email is summarized as
    /// before: only a text version that says something, and only when the Send-time summary would
    /// run (`mayRun`, or the demo account's own sends, which `summarizeLocally` would cover).
    static func textVersionToWrite(_ text: String?, isDemo: Bool) async -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if isDemo { return text }
        return await mayRun() ? text : nil
    }

    /// Writes `text`, the queued email's text version already in hand, as its summary under its
    /// Sent folder and Message-ID, inside the queue write that inserted `outboxId`: the chat's
    /// Sending bubble reads it from its first value, and the Sent copy restores it. The blurb is the
    /// same words, as `summarizeLocally` writes it: an entry without one counts as not summarized.
    /// No Sent folder yet writes nothing, as `summarize` skips.
    static func writeTextVersion(_ text: String, outboxId: String, db: Database) throws {
        guard let source = try source(outboxId: outboxId, db: db) else { return }
        try MessageAICache.writeThrough(
            accountId: source.accountId,
            folderPath: source.sentFolderPath,
            rfc822MessageId: source.messageId,
            summaryBlurb: text,
            summaryTextMessage: text,
            db: db)
    }

    /// The text version of the queued email `row` (written with it, or the summary made at Send),
    /// from the AI cache under its Sent folder and Message-ID; nil until there is one.
    static func textMessage(of row: OutboxMessage, db: Database) throws -> String? {
        guard let messageId = row.sentMessageId.map(EmailFilter.normalizeMessageId),
              let sentPath = try Folder
                .filter(Column("accountId") == row.accountId && Column("role") == FolderRole.sent.rawValue)
                .fetchOne(db)?.path,
              let key = MessageAICache.cacheKey(accountId: row.accountId, folderPath: sentPath, rfc822MessageId: messageId),
              let text = try MessageAICache.fetchOne(db, key: key)?.summaryTextMessage,
              !text.isEmpty else { return nil }
        return text
    }

    /// Reads the queued email `outboxId`, makes its summary with `produce`, and writes it to the AI
    /// cache under its Sent folder and Message-ID.
    private static func write(
        outboxId: String, produce: (Source) async throws -> SummaryResult
    ) async {
        let pool = AppDatabase.dbPool
        do {
            guard let source = try await pool.read({ db in try Self.source(outboxId: outboxId, db: db) }) else {
                BackgroundSyncLogger.logAIProcessing("Sent summary SKIPPED for \(outboxId): no row, Message-ID or Sent folder")
                return
            }
            let summary = try await produce(source)
            guard let blurb = summary.blurb, !blurb.isEmpty else {
                BackgroundSyncLogger.logAIProcessing("Sent summary EMPTY for \(outboxId)")
                return
            }
            let restored = try await pool.write { db -> [String] in
                try MessageAICache.writeThrough(
                    accountId: source.accountId,
                    folderPath: source.sentFolderPath,
                    rfc822MessageId: source.messageId,
                    summaryBlurb: blurb,
                    summaryTodos: summary.todos,
                    reminderDate: summary.reminderDate,
                    reminderTime: summary.reminderTime,
                    reminderContent: summary.reminderContent,
                    summaryTextMessage: summary.textMessage,
                    db: db)
                // A Sent copy that arrived before the summary returned takes it now.
                var restored: [String] = []
                let waiting = try MessageHeader
                    .filter(Column("accountId") == source.accountId && Column("folderPath") == source.sentFolderPath)
                    .filter(Column("rfc822MessageId") == source.messageId && Column("summaryBlurb") == nil)
                    .fetchAll(db)
                for var header in waiting {
                    try MessageAICache.restoreIfCached(
                        into: &header, accountId: source.accountId, folderPath: source.sentFolderPath, db: db)
                    try header.update(db)
                    restored.append(header.id)
                }
                return restored
            }
            for id in restored {
                NotificationCenter.default.post(name: .messageDataDidChange, object: id)
            }
            BackgroundSyncLogger.logAIProcessing("Sent summary written for \(outboxId)")
        } catch {
            BackgroundSyncLogger.logAIProcessing("Sent summary FAILED for \(outboxId): \(error.localizedDescription)")
        }
    }
}
