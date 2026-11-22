/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The chat's reply field (ADR-IOS-114 decision 10): the pill on the newest email becomes
/// [mic] [field] [Send]. The field holds only the user's words: the ready AI Suggestion waits as a
/// ghost bubble in the chat (`ChatSuggestionBubble`), and a tap on it opens the compose card.
/// Everything the user says or types goes to the agent on the newest email, as today's Chat pill
/// on that email. Under the empty field an "e.g." line shows a change the user could ask for
/// (`example`); a tap puts it in the field and never sends it.
struct ChatReplyField {
    /// The change the "e.g." line offers; nil shows no line.
    let example: String?
    /// The newest email is from a no-reply address.
    let isNoReply: Bool
    /// Changes when the field must empty: the reply went out, or the agent answered in the
    /// sheet.
    let clearCount: Int
    /// The reply goes only to these people; nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil
    /// In the tutorial, what the read-only field holds and sends (part 2); nil holds nothing.
    var tutorialMove: TutorialCoordinator.FieldMove? = nil
    /// How far a drag up has swelled the field toward the panel (`ChatFieldDrag`); 0 at rest.
    var swell: CGFloat = 0
    /// VoiceOver's "Show TabMail chat" (`ChatViewConfig.showChatActionName`), the drag up's
    /// equivalent, offered on the element VoiceOver focuses (`showChatAction`); nil offers nothing
    /// (the panel open, the tutorial).
    var showChat: (() -> Void)? = nil
    /// A new email's chat (`ChatNewThreadView`): the field has no email to reply to; nil in a
    /// thread's chat.
    var newEmail: ChatNewEmailField? = nil

    var placeholder: String {
        if newEmail != nil { return ChatNewEmailField.placeholder }
        return isNoReply ? "Ask anything" : "Reply or ask anything"
    }

    /// The ready AI Suggestion of the thread's newest email, as its ghost bubble shows it: its text
    /// message, while the full reply is stored. Nothing on the user's turn, for a no-reply sender,
    /// or while the reply goes only to people chosen in Reply to (`onlyTo`): the suggestion was
    /// written for everyone.
    static func suggestionText(newest: MessageHeader, usersTurn: Bool, onlyTo: [ChatThread.Person]?) -> String? {
        guard !usersTurn, onlyTo == nil, !EmailFilter.isNoReply(newest.fromAddress),
              let reply = newest.cachedReply, !reply.isEmpty,
              let text = newest.replyTextMessage, !text.isEmpty else { return nil }
        return text
    }

    /// The AI Suggestion's row under the newest email: `.ready` with the ghost's text once the
    /// reply is stored (`suggestionText`), `.writing` while the AI still works on the email (the
    /// inbox row's rule, `AIWorkingRule`: tagged with no reply processed, or untagged in the Inbox
    /// with an AI source on), else nothing. A filtered email's empty-reply sentinel counts as
    /// processed, so it never writes. Keyed by the newest email alone, so a new email that arrives
    /// above a ready ghost, tagged or not yet, puts the row back to `.writing` until its own
    /// suggestion is stored.
    static func suggestionPhase(
        newest: MessageHeader, usersTurn: Bool, onlyTo: [ChatThread.Person]?, aiSourceEnabled: Bool, subscribed: Bool
    ) -> ChatSuggestionPhase? {
        if let text = suggestionText(newest: newest, usersTurn: usersTurn, onlyTo: onlyTo) { return .ready(text) }
        guard !usersTurn, onlyTo == nil, !EmailFilter.isNoReply(newest.fromAddress),
              AIWorkingRule.isWorking(tagged: newest.actionTag != nil, replyProcessed: newest.cachedReply != nil,
                                      inInbox: newest.isInInbox, aiSourceEnabled: aiSourceEnabled,
                                      subscribed: subscribed) else { return nil }
        return .writing
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

/// The field of a new email's chat (`ChatNewThreadView`): no email to reply to, so Send goes to the
/// new email's chat, which asks who it is to or writes it; the field's words are the new email's
/// draft; the paperclip at the field's end adds attachments. Its agent chat is its own, in memory
/// only (`sessionKey`), never an email's thread chat or the inbox chat.
struct ChatNewEmailField {
    static let placeholder = "Message or ask anything"

    /// Where the paperclip's menu takes the user.
    enum AttachSource: CaseIterable {
        case photos, camera, files

        var title: String {
            switch self {
            case .photos: "Photos"
            case .camera: "Camera"
            case .files: "Files"
            }
        }

        var systemImage: String {
            switch self {
            case .photos: "photo.on.rectangle"
            case .camera: "camera"
            case .files: "folder"
            }
        }
    }

    /// The words a reopened draft puts in the field as it appears; empty for a new email.
    let startWords: String
    /// This new email's own agent session, in memory only.
    let sessionKey: String
    /// Each change of the field's words.
    let wordsChanged: (String) -> Void
    /// Send with words in the field.
    let send: (String) -> Void
    /// A choice in the paperclip's menu.
    let attach: (AttachSource) -> Void

    /// A new email's chat session key: a fresh one for each new email's chat.
    static func newSessionKey() -> String { "new-email:\(UUID().uuidString)" }
}

/// The chat input's words, which are all the reply field shows: the AI Suggestion never enters the
/// field (it waits as a ghost bubble in the chat). A completed send empties only the words that
/// were sent. The field and the open chat sheet share the words, so the rule is the same in both.
///
/// ONE API (the ADR-035 shape): `apply` is the only way the words change, for
/// typing, dictation, a send, a completion and the app's own edits, and the view cannot write them
/// any other way (`words` is `private(set)`). Every change is synchronous on the main actor, so the
/// main actor is the FIFO lock: each change runs whole, in arrival order, and none is held across
/// an await. No AI text enters, so no late suggestion can land on the user's words.
/// The one asynchronous producer that replaces words, the on-device live transcript, enters with
/// a change-counter compare (`heard`): it is dropped once anything else changed the words.
struct ChatFieldFill {
    /// The user's own words in the input: typed, said, or put there by the app for them (an Edit).
    /// Never AI text.
    private(set) var words = ""
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
        /// A dictation's text came back: it is added to the words as they are now.
        case said(String)
        /// An on-device dictation starts: its live transcript adds to the words as they are now.
        case startHearing
        /// The live transcript so far. Dropped if anything else changed the words since the
        /// transcript's last write (the change counter).
        case heard(String)
        /// The words become this text: the user's edit of the input, or words the app puts in for
        /// them (an Edit of an earlier message, or the "e.g." line's change).
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

/// A request sent from the chat's reply field, as it was when sent (ADR-IOS-114 decision 11): the
/// email the field replies to and who the user chose in Reply to. It travels with the request
/// (`ToolInvocation.fieldReply`, then `ComposeRequest.fieldReply` on a reply to that email), so the
/// chat that shows the compose card never decides who it goes to from its own state at that moment.
struct ChatFieldReply: Sendable, Equatable {
    /// The email the field replies to (`ChatThread.copyKey`: copies of one email are one).
    let emailKey: String
    /// The addresses chosen in Reply to; nil: Reply All.
    let onlyTo: [String]?
}

/// A send from the chat's reply field, read once as it starts: the email it is about, who the user
/// chose in Reply to, and whether that email takes replies. The send's words and its request are
/// built from it, and a resume or a retry of that send carries it, so neither reads the field again.
struct ChatFieldSend {
    let message: MessageHeader
    let onlyTo: [ChatThread.Person]?
    let isNoReply: Bool

    var fieldReply: ChatFieldReply {
        ChatFieldReply(emailKey: ChatThread.copyKey(message), onlyTo: onlyTo?.map(\.address))
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

    /// The AI Suggestion to `message`: a Reply All to its people. The suggestion shows only while
    /// nobody is chosen in Reply to (`ChatReplyField.suggestionText`).
    static func make(replyAllTo message: MessageHeader, accounts: [Account]) -> ChatReplyCompose {
        let audience = buildReplyAllRecipients(for: message, allAccounts: accounts)
        return ChatReplyCompose(isReplyAll: true, to: audience.to, cc: audience.cc, bcc: [])
    }

    /// The agent's reply, read from its request alone, never from the chat showing the card: whether
    /// its sheet is open, or who that chat would reply to now, decides nothing.
    /// - Asked for in the reply field with people chosen (`fieldReply.onlyTo`, as they were when it
    ///   was sent): a plain reply to only them, with no Cc or Bcc.
    /// - Otherwise the agent's recipients, a Reply All only when they (To, Cc and Bcc) contain the
    ///   whole Reply All audience, people the agent added included; asked for anywhere but the
    ///   field, also only when the agent opened it as one.
    static func make(agent req: AgentToolRouter.ComposeRequest, accounts: [Account]) -> ChatReplyCompose {
        if let only = req.fieldReply?.onlyTo {
            return ChatReplyCompose(isReplyAll: false, to: only, cc: [], bcc: [])
        }
        let audience = req.replyTo.map { buildReplyAllRecipients(for: $0, allAccounts: accounts) }
        let addresses = { (list: [String]) in Set(list.map { $0.lowercased() }) }
        let toWholeAudience = audience.map { addresses(req.to + req.cc + req.bcc).isSuperset(of: addresses($0.to + $0.cc)) } == true
        let isReplyAll = toWholeAudience && (req.fieldReply != nil || req.isReplyAll)
        return ChatReplyCompose(isReplyAll: isReplyAll, to: req.to, cc: req.cc, bcc: req.bcc)
    }

    /// The compose card, opened in this kind, as main's Reply All entries open it.
    /// `draftId`: the draft it saves to; nil, the reply's usual one.
    @MainActor
    func composeView(
        replyTo message: MessageHeader?, suggestedBody: String? = nil, draftId: String? = nil,
        onAgentOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        ComposeView(
            replyTo: message, suggestedBody: suggestedBody, isReplyAll: isReplyAll,
            prefillTo: to.isEmpty ? nil : to, prefillCc: cc.isEmpty ? nil : cc,
            prefillBcc: bcc.isEmpty ? nil : bcc, prefillDraftId: draftId, onAgentOutcome: onAgentOutcome)
    }
}

/// The ready AI Suggestion's compose card: the email it answers and how it opens.
struct ChatReadyReply: Identifiable {
    let message: MessageHeader
    let compose: ChatReplyCompose
    /// A draft of its own: the chat leaves the reply draft already saved for this email alone
    /// (it stays in Drafts), so the card never opens, saves over or deletes it.
    let draftId: String
    var id: MessageHeader.ID { message.id }

    init(message: MessageHeader, compose: ChatReplyCompose) {
        self.message = message
        self.compose = compose
        draftId = Draft.separateReplyKey(replyTo: "\(message.accountId):\(message.stableId)")
    }
}

/// A compose card the agent opens in the chat, with how a reply opens, read as it opened.
struct ChatAgentCard: Identifiable {
    let request: AgentToolRouter.ComposeRequest
    let reply: ChatReplyCompose
    var id: UUID { request.id }
}

/// A reply in the outbox the chat does not show as an email yet, shown as the user's bubble at the
/// bottom of the chat whose email it answers. Read from the database and the chat's own emails,
/// with nothing kept in memory: every outbox row whose In-Reply-To is the
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

/// The AI Suggestion's row in the chat (`ChatReplyField.suggestionPhase`): the working bubble while
/// the AI writes it, then the ghost with its text.
enum ChatSuggestionPhase: Equatable {
    case writing
    case ready(String)

    var isReady: Bool { if case .ready = self { true } else { false } }

    /// Whether a change of the row is the working bubble filling in, the one change that grows the
    /// row into the ghost with its re-pin in one animation. Anything else (the first value, a new
    /// email putting the ghost back to writing, a ghost that lands with no working bubble before it,
    /// a rewrite in place) shows at once.
    static func fills(from old: Self?, to new: Self?) -> Bool {
        old == .writing && new?.isReady == true
    }
}
