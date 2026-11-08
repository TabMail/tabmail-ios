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
    /// The reply goes only to these people (R2); nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// What Send does with the field's text.
    enum Route: Equatable {
        /// The ready AI Reply, unchanged: straight to the compose card, no agent (N2.6).
        case readyReply
        /// The user's own words: the agent (N4.4, A1).
        case agent
    }

    /// With recipients changed the ready AI Reply was written for everyone, so Send has the agent
    /// write it again for the people chosen (R2.4, Q33).
    static func route(text: String, readyText: String?, recipientsChanged: Bool = false) -> Route {
        guard let readyText, !recipientsChanged else { return .agent }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            == readyText.trimmingCharacters(in: .whitespacesAndNewlines) ? .readyReply : .agent
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
    /// With recipients chosen (R2) the nudge names them: a reply goes only to them.
    static func agentMessage(
        emailNumericId: Int, text: String, isNoReply: Bool, onlyTo: [ChatThread.Person]? = nil
    ) -> String {
        var nudge = isNoReply
            ? "typed in its reply field; the sender is a no-reply address, so do not write a reply to it"
            : "typed in its reply field; if what I want is unclear, I am replying to it"
        if let onlyTo, !onlyTo.isEmpty {
            let people = onlyTo.map { "\($0.name) <\($0.address)>" }.joined(separator: ", ")
            nudge += "; a reply goes only to \(people)"
        }
        return "Regarding [Email](\(emailNumericId)) (\(nudge)): \(text)"
    }

    /// The line above the field while the agent works (A2.1): the agent's own labels, except that
    /// writing a reply reads "Writing your email" (N5.1).
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] ? "Writing your email" : label
    }
}

/// The chat input's words and what the reply field shows (N2.7, N4.3). One rule (owner
/// 2026-11-07): the ready AI Reply shows in the field while it holds no words of the user's, typed
/// or said; once the user empties the field by hand it stays empty for that email; a completed send
/// empties only the words that were sent. The field and the open chat sheet share the words, so the
/// rule is the same in both.
///
/// ONE API (owner 2026-11-08, the ADR-035 shape): `apply` is the only way the words change, for
/// typing, dictation, a send, a completion and the app's own edits, and the view cannot write them
/// any other way (`words` is `private(set)`). Every change is synchronous on the main actor, so the
/// main actor is the FIFO lock: each change runs whole, in arrival order, and none is held across
/// an await. The AI Reply never enters: what the field shows is a function of the words and the
/// state at render (`shown`), so no late reply can land on the user's words or on another email.
/// The one asynchronous producer that replaces words, the on-device live transcript, enters with
/// a change-counter compare (`heard`): it is dropped once anything else changed the words.
struct ChatFieldFill {
    /// The user's own words in the input: typed, said, or put there by the app for them (an Edit).
    /// Never an AI Reply.
    private(set) var words = ""
    /// The email (`ChatThread.copyKey`) the user emptied the field on by hand: no AI Reply shows
    /// while it is the newest. A newer email is a new turn and shows its own.
    private(set) var emptiedOn: String?
    /// The user's words when they last sent, from the field or from the open sheet; nil once that
    /// send completed. An answer or a sent reply completes it, so it empties only those words:
    /// words the user wrote after it are newer and stay.
    private(set) var atSend: String?
    /// How many changes the words have had: the change counter a live transcript compares.
    private(set) var changes = 0
    /// The live transcript in progress: the words it adds to, and the change count of its own last
    /// write. Ends when anything else changes the words.
    private var hearing: (base: String, at: Int)?

    /// Every change to the words.
    enum Change {
        /// The user edited the input from `shown` to the new text, which is now their words. In the
        /// reply field, emptying it while it showed something keeps the AI Reply out of it for
        /// `email`.
        case typed(String, shown: String, email: String?, replyField: Bool)
        /// A dictation's text came back: it is added to the words as they are now.
        case said(String)
        /// An on-device dictation starts: its live transcript adds to the words as they are now.
        case startHearing
        /// The live transcript so far. Dropped if anything else changed the words since the
        /// transcript's last write (the change counter).
        case heard(String)
        /// The app puts words in for the user (an Edit of an earlier message).
        case put(String)
        /// Send from the open sheet: the words go, and nothing is left to complete.
        case sentFromSheet
        /// Send from the collapsed field: the words stay, pulsing, until the send completes.
        case sentFromField
        /// The last send completed (the reply went out, or the agent answered in the sheet): it
        /// empties the words only if they are still the words sent, or none.
        case completed
        /// A confirmation card opened the sheet: the same check, and the send is still open.
        case confirmationCard
    }

    /// The only way the words change.
    mutating func apply(_ change: Change) {
        let before = words
        switch change {
        case let .typed(typed, shown, email, replyField):
            // A set that leaves the shown text as it was is no edit (an untouched AI Reply stays
            // the app's, not the user's words).
            guard typed != shown else { return }
            if replyField, typed.isEmpty, !shown.isEmpty { emptiedOn = email }
            words = typed
        case let .said(text):
            words = DictationController.appending(text, to: words)
        case .startHearing:
            hearing = (words, changes)
            return
        case let .heard(transcript):
            guard let hearing, hearing.at == changes else { self.hearing = nil; return }
            words = DictationController.appending(transcript, to: hearing.base)
            changes += 1
            self.hearing = (hearing.base, changes)
            return
        case let .put(text):
            words = text
        case .sentFromSheet:
            atSend = ""
            words = ""
        case .sentFromField:
            atSend = words
        case .completed:
            if clears { words = "" }
            atSend = nil
        case .confirmationCard:
            if clears { words = "" }
        }
        if words != before { changes += 1 }
    }

    /// What the field shows: the user's words, or with none the newest email's ready AI Reply
    /// `ready`, unless the user emptied the field on that email or spoke last (`busy`: a dictation
    /// is bringing their words, or the agent is still answering them).
    func shown(ready: String?, busy: Bool, email: String?) -> String {
        guard words.isEmpty, !busy, let ready, emptiedOn == nil || email != emptiedOn else { return words }
        return ready
    }

    /// Whether the last send's completion may empty the words: they are still the words sent, or
    /// none. Anything else the user wrote after the send.
    private var clears: Bool {
        guard let atSend else { return true }
        return words == atSend || words.isEmpty
    }
}

/// Who the chat's next reply goes to (R1, R2): Reply All, or only the people chosen in Reply to.
struct ChatReplyTarget: Equatable {
    /// Nil: Reply All, the newest email's people (R1.3).
    let only: [ChatThread.Person]?

    static let replyAll = ChatReplyTarget(only: nil)

    /// Done in Reply to: everyone on the newest email ticked and nobody added is Reply All.
    static func chosen(_ ticked: [ChatThread.Person], replyPeople: [ChatThread.Person]) -> ChatReplyTarget {
        Set(ticked.map(\.address)) == Set(replyPeople.map(\.address)) ? .replyAll : ChatReplyTarget(only: ticked)
    }

    /// The "Replying only to" chips: up to `nameCount` names, then how many more (R2.3).
    static func chips(_ people: [ChatThread.Person], nameCount: Int = ChatViewLayout.headerNameCount) -> (names: [String], more: Int) {
        (people.prefix(nameCount).map(\.name), max(0, people.count - nameCount))
    }
}

/// A compose card the agent opens in the chat. `fromField`: it was asked for in the collapsed reply
/// field, not in the open chat sheet.
enum ChatAgentCompose {
    /// Who a reply goes to (R1): asked for in the field with people chosen in Reply to, only them,
    /// with no Cc or Bcc; otherwise the agent's own recipients.
    static func replyRecipients(
        fromField: Bool, target: ChatReplyTarget, request req: AgentToolRouter.ComposeRequest
    ) -> (to: [String], cc: [String], bcc: [String]) {
        guard fromField, let only = target.only else { return (req.to, req.cc, req.bcc) }
        return (only.map(\.address), [], [])
    }
}

/// Replies sent from the chat whose email is not in the chat yet (N7). Each follows its own queued
/// email through the outbox row the send wrote (owner 2026-11-07): its bubble shows from the queue
/// write, Undo window included, says "Sending" until the provider takes the email and "Sent" after,
/// and shows the email's summary as soon as it is made at Send ("Summarizing" until then). Undo or a
/// discard deletes the unsent row, and the bubble goes with it. The bubble ends when the email
/// itself, by its own Message-ID, is in the chat. A filed row whose Message-ID no email carries any
/// more ends it too: the provider filed its own copy under a Message-ID of its own (Outlook keeps
/// none of ours) and the Sent sync replaced ours, so that copy is the email, and it ends with no chat
/// on screen. The email is looked for by its Message-ID alone, in every account: the reply may go
/// out from another account than the email it answers (compose's From). In memory only.
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
    /// known, whether an email still carries it.
    struct Watch: Equatable, Sendable {
        let outboxId: String
        let messageId: String?
    }

    /// One read of the entries' rows and emails.
    struct Observed: Equatable, Sendable {
        var progress: [String: Progress] = [:]
        /// Entries whose row is gone and whose Message-ID no email carries.
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
                .filter(Column("rfc822MessageId") == messageId)
                .fetchCount(db) > 0
            if !carried { observed.withoutEmail.insert(watch.outboxId) }
        }
        return observed
    }

    /// Follows the entries' outbox rows and AI cache entries, and once a row is filed its email,
    /// while there are any.
    private func observe() {
        observation?.cancel()
        let watches = entries.map { Watch(outboxId: $0.id, messageId: progress[$0.id]?.messageId) }
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
    /// in the chat, or until no email carries its Message-ID (the provider's own
    /// copy replaced ours). A Message-ID learned here is followed from then on.
    private func apply(_ observed: Observed) {
        let found = observed.progress
        let undone = Set(entries.map(\.id).filter { found[$0] == nil && progress[$0]?.status != .sent })
        let gone = undone.union(observed.withoutEmail)
        for (id, value) in found { progress[id] = value }
        if !gone.isEmpty { entries.removeAll { gone.contains($0.id) } }
        progress = progress.filter { id, _ in entries.contains { $0.id == id } }
        let watches = entries.map { Watch(outboxId: $0.id, messageId: progress[$0.id]?.messageId) }
        if watches != watched { observe() }
    }

    #if DEBUG
    func removeAllForTesting() {
        entries = []
        progress = [:]
    }
    #endif
}
