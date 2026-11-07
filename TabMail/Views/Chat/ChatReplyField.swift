/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation

/// The chat's reply field (N2.6 to N7, A1 to A4, E1, E1b): the pill on the newest email becomes
/// [mic] [field] [Send]. The field holds the ready AI Reply's text message when there is one; Send
/// with it unchanged opens the compose card with the full AI Reply, and anything else the user says
/// or types goes to the agent on the newest email, as today's Chat pill on that email (section 3c).
struct ChatReplyField: Equatable {
    /// The ready AI Reply's text message; nil when there is none.
    let readyText: String?
    /// The newest email is from a no-reply address (E1).
    let isNoReply: Bool
    /// Changes when the field must empty: the reply went out (N7), or the agent answered in the
    /// sheet (A3).
    let clearCount: Int

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// What Send does with the field's text.
    enum Route: Equatable {
        /// The ready AI Reply, unchanged: straight to the compose card, no agent (N2.6).
        case readyReply
        /// The user's own words: the agent (N4.4, A1).
        case agent
    }

    static func route(text: String, readyText: String?) -> Route {
        guard let readyText else { return .agent }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            == readyText.trimmingCharacters(in: .whitespacesAndNewlines) ? .readyReply : .agent
    }

    /// Dictation over the untouched ready AI Reply replaces it rather than adding to it (N4.3):
    /// the AI Reply is not the user's words. Edited words or no ready reply keep the text.
    static func dictationReplaces(input: String, readyText: String?) -> Bool {
        guard let readyText else { return false }
        return input == readyText
    }

    /// The field's text once dictation brings `words`: they replace it when `replacing`, else they
    /// are added to what is there.
    static func dictated(_ words: String, onto input: String, replacing: Bool) -> String {
        DictationController.appending(words, to: replacing ? "" : input)
    }

    /// The ready AI Reply of the thread's newest email, as the field shows it: its text message,
    /// while the full reply is stored. Nothing for the user's own email or a no-reply sender.
    static func readyText(newest: MessageHeader, isOwn: Bool) -> String? {
        guard !isOwn, !EmailFilter.isNoReply(newest.fromAddress),
              let reply = newest.cachedReply, !reply.isEmpty,
              let text = newest.replyTextMessage, !text.isEmpty else { return nil }
        return text
    }

    /// The agent's message for words typed or said in the field: today's Chat pill message on the
    /// newest email (`Regarding [Email](N): …`), with a nudge that the words came from this
    /// email's reply field, so an unclear request is a reply to it (section 3c). For a no-reply
    /// sender the nudge says it takes no replies (E1.2).
    static func agentMessage(emailNumericId: Int, text: String, isNoReply: Bool) -> String {
        let nudge = isNoReply
            ? "typed in its reply field; the sender is a no-reply address, so do not write a reply to it"
            : "typed in its reply field; if what I want is unclear, I am replying to it"
        return "Regarding [Email](\(emailNumericId)) (\(nudge)): \(text)"
    }

    /// The line above the field while the agent works (A2.1): the agent's own labels, except that
    /// writing a reply reads "Writing your email" (N5.1).
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] ? "Writing your email" : label
    }
}

/// Whose words are in the reply field (N2.7, N4.3). One rule (owner 2026-11-07): the ready AI
/// Reply shows in the field only while the field holds no words of the user's, typed or said,
/// whenever the reply arrives: an empty field, or the AI Reply the app itself put there, takes it.
/// Once the user empties the field by hand it stays empty for that email. The field and the open
/// chat sheet share the words, so the rule is the same in both.
struct ChatFieldFill: Equatable {
    /// The AI Reply the app last put in the field: only it, or nothing, may be replaced.
    private(set) var filled: String?
    /// The email the user emptied the field on by hand: no AI Reply fills it while that email is
    /// the newest. A newer email is a new turn and shows its own.
    private(set) var emptiedOn: String?
    /// The field's words when the user last sent, from the field or from the open sheet; nil once
    /// a completion emptied it. An answer or a sent reply completes that send, so it empties only
    /// those words: words the user typed after it, in the open sheet, are newer and stay.
    private(set) var atSend: String?

    /// The field's words once the ready AI Reply `ready` of the newest email `email` is offered,
    /// or nil to leave them as they are: over an empty field or the AI Reply the app put there,
    /// unless the user emptied the field on that email. Not while the user spoke last (`busy`): a
    /// dictation is bringing their words, which a reply would join, or the agent is still answering
    /// them. Offered again when that ends and whenever the field empties.
    mutating func offer(_ ready: String?, input: String, busy: Bool, email: String?) -> String? {
        guard !busy, input.isEmpty || input == filled else { return nil }
        filled = email == emptiedOn ? nil : ready
        return filled ?? ""
    }

    /// The user emptied the field by hand while `email` was the newest.
    mutating func emptiedByHand(on email: String?) {
        emptiedOn = email
        filled = nil
    }

    /// The user sent with `input` in the field.
    mutating func sent(input: String) {
        atSend = input
    }

    /// Whether the completion of the last send (the agent answered, or the reply went out) may
    /// empty the field holding `input`: it still holds the words sent, nothing, or the AI Reply the
    /// app put there. Anything else the user wrote after the send.
    func clears(_ input: String) -> Bool {
        guard let atSend else { return true }
        return input == atSend || input.isEmpty || input == filled
    }

    /// The reply went out, or the agent answered in the sheet: the field emptied.
    mutating func cleared() {
        atSend = nil
    }
}

/// Replies sent from the chat whose email is not in the chat yet (N7). Each follows its own queued
/// email through the outbox row the send wrote (owner 2026-11-07): its bubble shows from the queue
/// write, Undo window included, says "Sending" until the provider takes the email and "Sent" after,
/// and shows the email's summary as soon as it is made at Send ("Summarizing" until then). Undo or a
/// discard deletes the unsent row, and the bubble goes with it. The bubble ends when the email
/// itself, by its own Message-ID, is in the chat. A filed row whose Message-ID no email of its
/// account carries any more ends it too: the provider filed its own copy under a Message-ID of its
/// own (Outlook keeps none of ours) and the Sent sync replaced ours, so that copy is the email, and
/// it ends with no chat on screen. In memory only.
@MainActor @Observable
final class ChatSentReplies {
    static let shared = ChatSentReplies()

    struct Entry: Identifiable, Equatable {
        /// The queued email's outbox row.
        let outboxId: String
        let accountId: String
        /// The Message-ID of the email the reply answers (the reply's In-Reply-To).
        let repliedTo: String
        let sentAt: Date

        var id: String { outboxId }
    }

    /// Where a sent reply's email is, from its outbox row and the AI cache.
    struct Progress: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case sending, sent, notSent
        }

        let status: Status
        /// The email's own Message-ID, without brackets.
        let messageId: String?
        /// The email's summary as a text message, once made.
        let textMessage: String?

        /// The line under the bubble, as under every email of the user's.
        var caption: String {
            switch status {
            case .sending: "Sending"
            case .sent: "Sent"
            case .notSent: "Not sent"
            }
        }
    }

    private(set) var entries: [Entry] = [] {
        didSet { if entries.map(\.id) != oldValue.map(\.id) { observe() } }
    }
    /// The last progress read for each entry.
    private(set) var progress: [String: Progress] = [:]
    private var observation: Task<Void, Never>?
    /// What the running observation follows.
    private var watched: [Watch] = []

    /// What the observation follows for an entry: its outbox row, and once its Message-ID is
    /// known, whether an email of its account still carries it.
    struct Watch: Equatable, Sendable {
        let outboxId: String
        let accountId: String
        let messageId: String?
    }

    /// One read of the entries' rows and emails.
    struct Observed: Equatable, Sendable {
        var progress: [String: Progress] = [:]
        /// Entries whose row is gone and whose Message-ID no email of their account carries.
        var withoutEmail: Set<String> = []
    }

    /// A compose card opened from the chat ended. Only a sent one counts: a sent reply shows as its
    /// queued email's bubble until that email is in the chat, and the caller empties the field. A
    /// cancelled or failed card changes nothing. Returns whether it was sent.
    @discardableResult
    func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, now: Date = Date()) -> Bool {
        guard case .sent(let outboxId) = outcome else { return false }
        if let replyTo, let repliedTo = replyTo.rfc822MessageId {
            prune(now: now)
            entries.append(Entry(outboxId: outboxId, accountId: replyTo.accountId, repliedTo: repliedTo, sentAt: now))
        }
        return true
    }

    /// The entries for a chat whose emails have these Message-IDs.
    func entries(accountId: String, messageIds: Set<String>) -> [Entry] {
        entries.filter { $0.accountId == accountId && messageIds.contains($0.repliedTo) }
    }

    /// Whether the email of `entry` is among `items`, by its own Message-ID.
    func isInChat(_ entry: Entry, items: [ChatThread.Item]) -> Bool {
        guard let messageId = progress[entry.id]?.messageId else { return false }
        return items.contains { $0.header.rfc822MessageId.map(EmailFilter.normalizeMessageId) == messageId }
    }

    /// Retry on a "Not sent" bubble: the Outbox's own Retry for the same queued email, which puts a
    /// failed, unsent row back in the queue. The bubble follows the row back to "Sending". Returns
    /// whether the row was queued again.
    @discardableResult
    func retry(_ entry: Entry) -> Bool {
        AccountManager.shared.retryOutboxMessage(entry.outboxId)
    }

    /// Delete on a "Not sent" bubble: the Outbox's own Discard for the same queued email. The row
    /// goes unsent, so the bubble goes with it. Returns whether the row was deleted.
    @discardableResult
    func delete(_ entry: Entry) -> Bool {
        AccountManager.shared.discardOutboxMessageConfirmed(entry.outboxId)
    }

    /// Drops the entries whose email is in the chat, and old ones.
    func settle(_ items: [ChatThread.Item], now: Date = Date()) {
        let arrived = Set(entries.filter { isInChat($0, items: items) }.map(\.id))
        if !arrived.isEmpty { entries.removeAll { arrived.contains($0.id) } }
        prune(now: now)
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.sentAt) > ChatViewLayout.sentReplyLifetime }
    }

    /// The progress of each of `outboxIds` whose row is still there.
    nonisolated static func progress(of outboxIds: [String], db: Database) throws -> [String: Progress] {
        var found: [String: Progress] = [:]
        for row in try OutboxMessage.filter(keys: outboxIds).fetchAll(db) {
            let messageId = row.sentMessageId.map(EmailFilter.normalizeMessageId)
            let sentPath = try Folder
                .filter(Column("accountId") == row.accountId && Column("role") == FolderRole.sent.rawValue)
                .fetchOne(db)?.path
            let key = sentPath.flatMap {
                MessageAICache.cacheKey(accountId: row.accountId, folderPath: $0, rfc822MessageId: messageId)
            }
            let text = try key.flatMap { try MessageAICache.fetchOne(db, key: $0) }?.summaryTextMessage
            let status: Progress.Status = row.sentAt != nil ? .sent : row.outboxStatus == .failed ? .notSent : .sending
            found[row.id] = Progress(status: status, messageId: messageId, textMessage: text?.isEmpty == false ? text : nil)
        }
        return found
    }

    /// The progress of the watched rows, and which filed ones no email carries any more.
    nonisolated static func observed(_ watches: [Watch], db: Database) throws -> Observed {
        var observed = Observed(progress: try progress(of: watches.map(\.outboxId), db: db))
        for watch in watches where observed.progress[watch.outboxId] == nil {
            guard let messageId = watch.messageId else { continue }
            let carried = try MessageHeader
                .filter(Column("accountId") == watch.accountId && Column("rfc822MessageId") == messageId)
                .fetchCount(db) > 0
            if !carried { observed.withoutEmail.insert(watch.outboxId) }
        }
        return observed
    }

    /// Follows the entries' outbox rows and AI cache entries, and once a row is filed its email,
    /// while there are any.
    private func observe() {
        observation?.cancel()
        let watches = entries.map { Watch(outboxId: $0.id, accountId: $0.accountId, messageId: progress[$0.id]?.messageId) }
        watched = watches
        guard !watches.isEmpty else {
            observation = nil
            return
        }
        observation = Task { [weak self] in
            let tracking = ValueObservation.tracking { db in try Self.observed(watches, db: db) }.removeDuplicates()
            do {
                for try await found in tracking.values(in: AppDatabase.rawPool) {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(found)
                }
            } catch {
                BackgroundSyncLogger.logDebug("[Chat] sent reply observation ended: \(error)")
            }
        }
    }

    /// A row that is gone before its email went out was undone or discarded: its bubble goes. A
    /// sent email's row goes once it is filed in Sent; its bubble stays, "Sent", until the email is
    /// in the chat, or until no email of its account carries its Message-ID (the provider's own
    /// copy replaced ours). A Message-ID learned here is followed from then on.
    private func apply(_ observed: Observed) {
        let found = observed.progress
        let undone = Set(entries.map(\.id).filter { found[$0] == nil && progress[$0]?.status != .sent })
        let gone = undone.union(observed.withoutEmail)
        for (id, value) in found { progress[id] = value }
        if !gone.isEmpty { entries.removeAll { gone.contains($0.id) } }
        progress = progress.filter { id, _ in entries.contains { $0.id == id } }
        let watches = entries.map { Watch(outboxId: $0.id, accountId: $0.accountId, messageId: progress[$0.id]?.messageId) }
        if watches != watched { observe() }
    }

    #if DEBUG
    func removeAllForTesting() {
        entries = []
        progress = [:]
    }
    #endif
}
