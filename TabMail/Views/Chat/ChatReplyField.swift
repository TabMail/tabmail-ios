/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The chat's reply field (ADR-IOS-114 decision 10): the pill on the newest email becomes
/// [mic] [field] [Send]. The field holds the ready AI Reply's text message when there is one; Send
/// with it unchanged opens the compose card with the full AI Reply, and anything else the user says
/// or types goes to the agent on the newest email, as today's Chat pill on that email.
struct ChatReplyField: Equatable {
    /// The ready AI Reply's text message; nil when there is none.
    let readyText: String?
    /// The newest email is from a no-reply address.
    let isNoReply: Bool
    /// Changes when the field must empty: the reply went out, or the agent answered in the
    /// sheet.
    let clearCount: Int
    /// The reply goes only to these people; nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// What Send does with the field's text.
    enum Route: Equatable {
        /// The ready AI Reply, unchanged: straight to the compose card, no agent.
        case readyReply
        /// The user's own words: the agent.
        case agent
    }

    /// With recipients changed the ready AI Reply was written for everyone, so Send has the agent
    /// write it again for the people chosen.
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
    /// email's reply field, so an unclear request is a reply to it. For a no-reply
    /// sender the nudge says it takes no replies.
    /// With recipients chosen in Reply to the nudge names them: a reply goes only to them.
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

    /// The line above the field while the agent works: the agent's own labels, except that
    /// writing a reply reads "Writing your email".
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] ? "Writing your email" : label
    }
}

/// The chat input's words and what the reply field shows. One rule (owner
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

/// Who the chat's next reply goes to: Reply All, or only the people chosen in Reply to.
struct ChatReplyTarget: Equatable {
    /// Nil: Reply All, the newest email's people.
    let only: [ChatThread.Person]?

    static let replyAll = ChatReplyTarget(only: nil)

    /// Done in Reply to: everyone on the newest email ticked and nobody added is Reply All.
    static func chosen(_ ticked: [ChatThread.Person], replyPeople: [ChatThread.Person]) -> ChatReplyTarget {
        Set(ticked.map(\.address)) == Set(replyPeople.map(\.address)) ? .replyAll : ChatReplyTarget(only: ticked)
    }

    /// The "Replying only to" chips: up to `nameCount` names, then how many more.
    static func chips(_ people: [ChatThread.Person], nameCount: Int = ChatViewLayout.headerNameCount) -> (names: [String], more: Int) {
        (people.prefix(nameCount).map(\.name), max(0, people.count - nameCount))
    }
}

/// How a reply from the chat opens compose: Reply All or a plain reply, and to whom, read together
/// from who the chat's reply goes to (`ChatReplyTarget`), so the kind the send records on the
/// original (`ComposeView.isReplyAll`, #915) is the kind the "Replying only to" line shows. Read once,
/// as the card opens: a newer email resetting the target must not change an open card's kind.
struct ChatReplyCompose: Equatable {
    let isReplyAll: Bool
    let to: [String]
    let cc: [String]
    let bcc: [String]

    /// The reply to `message`. `agent`: the agent's reply request and whether it was asked for in the
    /// collapsed field (not the open chat sheet); nil for the ready AI Reply.
    /// - The ready AI Reply, and a reply asked for in the field, are a Reply All to the newest
    ///   email's people exactly when nobody was chosen in Reply to (`target.only == nil`); with people
    ///   chosen, a plain reply to only them, with no Cc or Bcc.
    /// - A reply asked for in the open sheet keeps the agent's recipients, and is a Reply All only
    ///   when the agent opened it as one and those recipients are the whole Reply All audience.
    static func make(
        replyTo message: MessageHeader?, target: ChatReplyTarget,
        agent: (request: AgentToolRouter.ComposeRequest, fromField: Bool)?, accounts: [Account]
    ) -> ChatReplyCompose {
        if let only = target.only, agent?.fromField ?? true {
            return ChatReplyCompose(isReplyAll: false, to: only.map(\.address), cc: [], bcc: [])
        }
        let audience = message.map { buildReplyAllRecipients(for: $0, allAccounts: accounts) }
        guard let agent else {
            return ChatReplyCompose(isReplyAll: audience != nil, to: audience?.to ?? [], cc: audience?.cc ?? [], bcc: [])
        }
        let req = agent.request
        let isReplyAll: Bool
        if agent.fromField {
            isReplyAll = audience != nil
        } else {
            let addresses = { (list: [String]) in Set(list.map { $0.lowercased() }) }
            isReplyAll = req.isReplyAll && audience.map { addresses(req.to + req.cc + req.bcc) == addresses($0.to + $0.cc) } == true
        }
        return ChatReplyCompose(isReplyAll: isReplyAll, to: req.to, cc: req.cc, bcc: req.bcc)
    }

    /// The compose card, opened in this kind, as main's Reply All entries open it.
    @MainActor
    func composeView(
        replyTo message: MessageHeader?, suggestedBody: String? = nil,
        onAgentOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        ComposeView(
            replyTo: message, suggestedBody: suggestedBody, isReplyAll: isReplyAll,
            prefillTo: to.isEmpty ? nil : to, prefillCc: cc.isEmpty ? nil : cc,
            prefillBcc: bcc.isEmpty ? nil : bcc, onAgentOutcome: onAgentOutcome)
    }
}

/// The ready AI Reply's compose card: the email it answers and how it opens.
struct ChatReadyReply: Identifiable {
    let message: MessageHeader
    let compose: ChatReplyCompose
    var id: MessageHeader.ID { message.id }
}

/// A compose card the agent opens in the chat, with how a reply opens, read as it opened.
struct ChatAgentCard: Identifiable {
    let request: AgentToolRouter.ComposeRequest
    let reply: ChatReplyCompose
    var id: UUID { request.id }
}

/// A reply in the outbox the chat does not show as an email yet, shown as the user's bubble at the
/// bottom of the chat whose email it answers. Read from the database and the chat's own emails,
/// with nothing kept in memory (owner 2026-11-09): every outbox row whose In-Reply-To is the
/// Message-ID of an email in the chat, from any account (the reply may go out from another account
/// than the email it answers). A failed row reads "Not sent", with Retry and Delete; any other
/// "Sending". Its text is the summary made at Send (`SentEmailSummary`), "Summarizing" until then.
///
/// The hand-over to the sent email: once the provider takes the email the send stamps `sentAt`, then
/// writes the optimistic Sent copy under the row's Message-ID. The chat's list of emails is not
/// observed, so the row keeps its bubble until its Sent copy is one of the chat's emails; once the
/// copy is in the database (`filed`) the chat reloads its emails, the copy's Message-ID joins
/// `messageIds`, and the bubble ends (ending it at the `sentAt` write would leave neither the bubble
/// nor the copy on screen). Undo, a discard or the send's own cleanup deletes the row, and the bubble goes.
struct ChatUnsentReply: Identifiable, Equatable, Sendable {
    let outboxId: String
    let failed: Bool
    /// The provider took the email and its Sent copy is in the database, not yet in the chat.
    let filed: Bool
    /// The email's summary as a text message, once made.
    let textMessage: String?

    var id: String { outboxId }

    /// The line under the bubble, as under every email of the user's.
    var caption: String { failed ? "Not sent" : "Sending" }

    /// The outbox rows answering one of `messageIds` (normalized Message-IDs of the chat's emails)
    /// whose email is not one of them, oldest first. A sent row without its Message-ID cannot be
    /// handed over and shows nothing.
    nonisolated static func fetch(answering messageIds: Set<String>, db: Database) throws -> [ChatUnsentReply] {
        guard !messageIds.isEmpty else { return [] }
        let rows = try OutboxMessage
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
        return try rows.compactMap { row in
            guard let parent = row.inReplyTo.map(EmailFilter.normalizeMessageId),
                  messageIds.contains(parent) else { return nil }
            var filed = false
            if row.sentAt != nil {
                guard let sentId = row.sentMessageId.map(EmailFilter.normalizeMessageId),
                      !messageIds.contains(sentId) else { return nil }
                filed = try MessageHeader
                    .filter(Column("accountId") == row.accountId && Column("rfc822MessageId") == sentId)
                    .fetchCount(db) > 0
            }
            return ChatUnsentReply(outboxId: row.id, failed: row.outboxStatus == .failed, filed: filed,
                                   textMessage: try summary(of: row, db: db))
        }
    }

    /// The unsent replies answering `messageIds`, now and after every change, from one observation.
    static func changes(answering messageIds: Set<String>) -> AsyncValueObservation<[ChatUnsentReply]> {
        ValueObservation
            .tracking { db in try fetch(answering: messageIds, db: db) }
            .removeDuplicates()
            .values(in: AppDatabase.rawPool)
    }

    /// The summary made at Send, from the AI cache under the row's Sent folder and Message-ID.
    private nonisolated static func summary(of row: OutboxMessage, db: Database) throws -> String? {
        guard let messageId = row.sentMessageId.map(EmailFilter.normalizeMessageId),
              let sentPath = try Folder
                .filter(Column("accountId") == row.accountId && Column("role") == FolderRole.sent.rawValue)
                .fetchOne(db)?.path,
              let key = MessageAICache.cacheKey(accountId: row.accountId, folderPath: sentPath, rfc822MessageId: messageId),
              let text = try MessageAICache.fetchOne(db, key: key)?.summaryTextMessage,
              !text.isEmpty else { return nil }
        return text
    }

    /// Retry on a "Not sent" bubble: the Outbox's own Retry for the same row.
    @MainActor func retry() {
        AccountManager.shared.retryOutboxMessage(outboxId)
    }

    /// Delete on a "Not sent" bubble: the Outbox's own Discard for the same row.
    @MainActor func delete() {
        AccountManager.shared.discardOutboxMessageConfirmed(outboxId)
    }
}
