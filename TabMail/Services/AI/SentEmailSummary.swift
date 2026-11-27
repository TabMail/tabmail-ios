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
/// earlier (ADR-IOS-008, recorded divergence). The summary is the AI cache entry the Sent copy would
/// have written. An entry no Sent copy takes (the send was undone, or Outlook filed
/// its own copy under a Message-ID of its own) is purged with the other orphaned AI cache entries.
///
/// An email sent with its text version already in hand (written with its body: the chat's field
/// composition, the AI Suggestion, an edit of the card; sent with that body unchanged) keeps those
/// words, the user's own, apart from its summary: they go into the same entry's `userTextMessage`
/// with the queue write (`writeTextVersion`), and the chat's bubbles show them instead of the
/// summary's text message. The summary is made all the same, so its to-dos and reminder land on the
/// Sent copy like any other email's (ADR-IOS-114 decision 10).
enum SentEmailSummary {
    /// Whether a send summarizes its email now: the chat view is on and AI may run. Read once, at
    /// the queue write.
    @MainActor static func mayRun() -> Bool {
        // An open goes to the chat only with the chat view and AI on, or while a tutorial runs
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

    /// The text version a send keeps as the user's words with its queue write, or nil: only a text
    /// version that says something, and only when the send summarizes (`summarizes`: `mayRun`, or
    /// the demo account's own sends, read once by the caller for both).
    static func textVersionToWrite(_ text: String?, summarizes: Bool) -> String? {
        guard summarizes, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Writes `text`, the queued email's text version already in hand, as the user's words
    /// (`userTextMessage`) under its Sent folder and Message-ID, inside the queue write that inserted
    /// `outboxId`: the chat's Sending bubble reads them from its first value, and the Sent copy
    /// restores them. No AI field is written: the summary is made after the queue write as for any
    /// email. No Sent folder yet writes nothing, as `summarize` skips.
    static func writeTextVersion(_ text: String, outboxId: String, db: Database) throws {
        guard let source = try source(outboxId: outboxId, db: db) else { return }
        try MessageAICache.writeThrough(
            accountId: source.accountId,
            folderPath: source.sentFolderPath,
            rfc822MessageId: source.messageId,
            userTextMessage: text,
            db: db)
    }

    /// The two texts the bubble of a queued email can show, from its AI cache entry.
    struct BubbleTexts: Equatable, Sendable {
        /// The user's own words it was sent with.
        let words: String?
        /// The summary made at Send's text message.
        let summary: String?
        /// The bubble's text: the user's own words when it was sent with them, else the summary's;
        /// nil until there is one.
        var shown: String? { words ?? summary }
    }

    /// The bubble texts of the queued email `row`.
    static func texts(of row: OutboxMessage, db: Database) throws -> BubbleTexts {
        let entry = try cacheEntry(of: row, db: db)
        func said(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
        return BubbleTexts(words: said(entry?.userTextMessage), summary: said(entry?.summaryTextMessage))
    }

    /// The user's own words the queued email `row` was sent with (its text version), nil when it was
    /// sent without: what an Undo keeps for a send again. Never the summary's text message, which
    /// is the AI's, not the user's.
    static func textVersion(of row: OutboxMessage, db: Database) throws -> String? {
        guard let words = try cacheEntry(of: row, db: db)?.userTextMessage, !words.isEmpty else { return nil }
        return words
    }

    /// The AI cache entry of the queued email `row`, under its Sent folder and Message-ID.
    private static func cacheEntry(of row: OutboxMessage, db: Database) throws -> MessageAICache? {
        guard let messageId = row.sentMessageId.map(EmailFilter.normalizeMessageId),
              let sentPath = try Folder
                .filter(Column("accountId") == row.accountId && Column("role") == FolderRole.sent.rawValue)
                .fetchOne(db)?.path,
              let key = MessageAICache.cacheKey(accountId: row.accountId, folderPath: sentPath, rfc822MessageId: messageId)
        else { return nil }
        return try MessageAICache.fetchOne(db, key: key)
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
                // A Sent copy that arrived before the summary returned takes it now, under the
                // Message-ID the copy carries (its provider's own, when it gave one: `SentCopyLink`).
                var restored: [String] = []
                let copyMessageId = SentCopyLink.copyMessageId(
                    accountId: source.accountId, sentMessageId: source.messageId)
                let waiting = try MessageHeader
                    .filter(Column("accountId") == source.accountId && Column("folderPath") == source.sentFolderPath)
                    .filter(Column("rfc822MessageId") == copyMessageId && Column("summaryBlurb") == nil)
                    .fetchAll(db)
                for var header in waiting {
                    try MessageAICache.restoreIfCached(
                        into: &header, from: source.messageId,
                        accountId: source.accountId, folderPath: source.sentFolderPath, db: db)
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
