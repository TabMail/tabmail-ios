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
struct ChatReplyField: Equatable {
    /// The change the "e.g." line offers; nil shows no line.
    let example: String?
    /// The newest email is from a no-reply address.
    let isNoReply: Bool
    /// The reply goes only to these people; nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil
    /// In the tutorial, what the read-only field holds and sends (part 2); nil holds nothing.
    var tutorialMove: TutorialCoordinator.FieldMove? = nil
    /// The full email of the AI Suggestion the chat shows now (`cachedReply`); nil when no ghost
    /// shows. A request sent while it shows is a compose edit of it (`ChatFieldReply.suggestion`).
    var suggestion: ReplyResult? = nil

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// The ready AI Suggestion of the thread's newest email, the one value the ghost bubble, the
    /// "e.g." line and the field's edit all read (`MessageHeader.suggestion`): shown while its full
    /// reply and its text version are stored. Nothing on the user's turn, for a no-reply sender,
    /// or while the reply goes only to people chosen in Reply to (`onlyTo`): the suggestion was
    /// written for everyone.
    /// Nothing while "Writing your email" runs (`writing`) or a compose card is open (`cardOpen`):
    /// a suggestion that became ready meanwhile shows once the card closes without sending (a send
    /// makes it the user's turn). Words in the field never hide it: it waits as the ghost.
    static func shown(
        newest: MessageHeader, usersTurn: Bool, onlyTo: [ChatThread.Person]?,
        writing: Bool = false, cardOpen: Bool = false
    ) -> ReplyResult? {
        guard !writing, !cardOpen, !usersTurn, onlyTo == nil, !EmailFilter.isNoReply(newest.fromAddress),
              let suggestion = newest.suggestion, !suggestion.body.isEmpty,
              let text = suggestion.textMessage, !text.isEmpty else { return nil }
        return suggestion
    }

    /// The "e.g." line's change: while the AI Suggestion shows (`shown`), the change command that
    /// came with it, so the example fits the reply on screen; otherwise, or when the suggestion
    /// has none, the chat's configured example (`ChatSuggestionConfig.randomExample`).
    static func example(shown: ReplyResult?, configured: String?) -> String? {
        if let command = shown?.changeCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return command
        }
        return configured
    }

    /// The working bubble under the newest email: `.writing` while the AI still works on the email
    /// (the inbox row's rule, `AIWorkingRule`: tagged with no reply processed, or untagged in the
    /// Inbox with an AI source on), else nothing. Never `.ready`: the ghost is only the suggestion
    /// the chat shows (`shown`, gated by "Writing your email" and an open compose card). A stored
    /// suggestion that `shown` would show without those gates gives no working bubble either, so
    /// an open card hides the row until it closes. A filtered email's empty-reply sentinel counts as
    /// processed, so it never writes. Keyed by the newest email alone, so a new email that arrives
    /// above a ready ghost, tagged or not yet, puts the row back to `.writing` until its own
    /// suggestion is stored.
    static func suggestionPhase(
        newest: MessageHeader, usersTurn: Bool, onlyTo: [ChatThread.Person]?, aiSourceEnabled: Bool, subscribed: Bool
    ) -> ChatSuggestionPhase? {
        guard shown(newest: newest, usersTurn: usersTurn, onlyTo: onlyTo) == nil,
              !usersTurn, onlyTo == nil, !EmailFilter.isNoReply(newest.fromAddress),
              AIWorkingRule.isWorking(tagged: newest.actionTag != nil, replyProcessed: newest.suggestion != nil,
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
///
/// A pill about an email does not hold its own: its chat's one fill is in `ChatFieldWords`
/// (ADR-IOS-117), which every pill on that chat reads and changes, and which keeps what is not sent.
struct ChatFieldFill: Equatable {
    /// The user's own words in the input: typed, said, or put there by the app for them (an Edit).
    /// Never AI text.
    private(set) var words = ""
    /// The user's words when they last sent, from the field or from the open sheet; nil once that
    /// send completed. An answer or a sent reply completes it, so it empties only those words:
    /// words the user wrote after it are newer and stay.
    private(set) var atSend: String?
    /// How many changes the words have had: the change counter a live transcript compares.
    private(set) var changes = 0
    /// A compose card opened for the field's send: the reply is the point, so the agent's closing
    /// answer completes nothing; the card's own send does (`completed`).
    private(set) var composing = false
    /// The live transcript in progress: the words it adds to, and the change count of its own last
    /// write. Ends when anything else changes the words.
    private var hearing: Hearing?

    private struct Hearing: Equatable {
        let base: String
        let at: Int
    }

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
        /// The open send completed (its compose card's reply went out): it empties the words only
        /// if a send is open and they are still the words sent, or none.
        case completed
        /// The agent answered the field's send: `completed`, unless a compose card opened for it.
        case answered
        /// A compose card opened for the field's send (`composing`).
        case composeOpened
        /// A confirmation card opened the sheet: the same check, and the send is still open.
        case confirmationCard
    }

    /// The words to keep for the chat (`ChatFieldWords`): the words, except a send's still in
    /// flight (they went to the agent).
    var unsent: String { words == atSend ? "" : words }

    /// The only way the words change.
    mutating func apply(_ change: Change) {
        let before = words
        switch change {
        case let .said(text):
            words = DictationController.appending(text, to: words)
        case .startHearing:
            hearing = Hearing(base: words, at: changes)
            return
        case let .heard(transcript):
            guard let hearing, hearing.at == changes else { self.hearing = nil; return }
            words = DictationController.appending(transcript, to: hearing.base)
            changes += 1
            self.hearing = Hearing(base: hearing.base, at: changes)
            return
        case let .put(text):
            words = text
        case .sentFromSheet:
            atSend = ""
            words = ""
        case .sentFromField:
            atSend = words
            composing = false
        case .completed:
            if clears { words = "" }
            atSend = nil
            composing = false
        case .answered:
            // A compose card that opened for the send owns its completion: a closed card's
            // closing answer leaves the words.
            guard !composing else { return }
            if clears { words = "" }
            atSend = nil
        case .composeOpened:
            composing = true
        case .confirmationCard:
            if clears { words = "" }
        }
        if words != before { changes += 1 }
    }

    /// Whether a send's completion may empty the words: only while a send is open, and only if
    /// they are still the words sent, or none. With no send open (a compose card's Send already
    /// completed it, or nothing was sent), a later card, compose or answer of the same request
    /// leaves the words: they are newer than the send.
    private var clears: Bool {
        guard let atSend else { return false }
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
    /// The email the field showed, as it showed it: its row and that row's identity. Its AI
    /// Suggestion belongs to this row alone, and only while the row is still this email.
    let email: MessageHeader
    /// The addresses chosen in Reply to; nil: Reply All.
    let onlyTo: [String]?
    /// The AI Suggestion showing when the request was sent: its full email, text version and
    /// change command, as shown; nil when none showed. The agent's reply to that email with a
    /// request edits it (`EmailReplyTool`), stored only over this same suggestion.
    var suggestion: ReplyResult? = nil

    /// Whether the user's choice in Reply to applies to a reply to `header`: the email the field
    /// showed in the same account, any copy of it (another folder's), never another account's copy.
    func audienceApplies(to header: MessageHeader) -> Bool {
        header.accountId == email.accountId && ChatThread.copyKey(header) == ChatThread.copyKey(email)
    }
}

/// A send from the chat's reply field, read once as it starts: the email it is about, who the user
/// chose in Reply to, and whether that email takes replies. The send's words and its request are
/// built from it, and a resume or a retry of that send carries it, so neither reads the field again.
struct ChatFieldSend {
    let message: MessageHeader
    let onlyTo: [ChatThread.Person]?
    let isNoReply: Bool
    /// The AI Suggestion showing as the send started (`ChatReplyField.suggestion`).
    var suggestion: ReplyResult? = nil

    var fieldReply: ChatFieldReply {
        ChatFieldReply(email: message, onlyTo: onlyTo?.map(\.address), suggestion: suggestion)
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
    /// The subject the card opens with, exactly: an empty one stays empty.
    let subject: String

    /// THE envelope of the AI Suggestion to `message`, the one builder the ghost's card and the
    /// field's edit of the suggestion both use: the Reply All audience by role, the reply subject,
    /// from the email's own account, exactly (an empty To stays empty: the card never refills it
    /// from the reply's Reply-To). The suggestion slot holds a body for this envelope only.
    static func suggestionEnvelope(for message: MessageHeader, accounts: [Account]) -> ChatReplyCompose {
        let audience = buildReplyAllRecipients(for: message, allAccounts: accounts)
        return ChatReplyCompose(
            isReplyAll: true, to: audience.to, cc: audience.cc, bcc: [],
            subject: ThreadUtils.replySubject(for: message.subject))
    }

    /// The fields as compose holds them (`ComposeDraftGuards.Recipients`), so an edit's recipient
    /// changes apply by the card's own operation (`Recipients.applying`).
    var recipients: ComposeDraftGuards.Recipients {
        ComposeDraftGuards.Recipients().filling(to: RecipientEntry(to), cc: RecipientEntry(cc), bcc: RecipientEntry(bcc))
    }

    /// A plain reply to only `people` (who the user chose in Reply to), with no Cc or Bcc and the
    /// reply subject.
    static func onlyTo(_ people: [String], replying message: MessageHeader) -> ChatReplyCompose {
        ChatReplyCompose(isReplyAll: false, to: people, cc: [], bcc: [], subject: ThreadUtils.replySubject(for: message.subject))
    }

    /// The envelope with `recipients` and `subject`, exactly: the card shows these fields as they are,
    /// each recipient under the name its field holds for it (keyed by the address as the field
    /// stores it, in any case). Its kind follows the final audience: a Reply All only while the
    /// recipients (To, Cc and Bcc) still hold this envelope's whole Reply All audience (its To and
    /// Cc), people added included; narrowed, even to one person, it is a plain reply, so the send
    /// records a reply on the original. Both sides are read as compose reads its fields: each
    /// mailbox as its address, and an entry that names no sendable address (a Reply-To's
    /// `undisclosed-recipients:;`) as the text written, in any case; leaving that entry out
    /// narrows the audience too.
    func with(recipients: ComposeDraftGuards.Recipients, subject: String) -> ChatReplyCompose {
        func texts(_ field: ComposeDraftGuards.RecipientField) -> [String] {
            field.tokens.map {
                RecipientEntry.text(name: field.displayNames[$0] ?? field.displayNames[$0.lowercased()], address: $0)
            } + field.rejected
        }
        let fields = [recipients.to, recipients.cc, recipients.bcc]
        let final = Set(fields.flatMap { $0.tokens + $0.rejected }.map { $0.lowercased() })
        let start = RecipientEntry(to + cc)
        let audience = Set((start.addresses + start.leftovers).map { $0.lowercased() })
        return ChatReplyCompose(
            isReplyAll: isReplyAll && final.isSuperset(of: audience),
            to: texts(recipients.to), cc: texts(recipients.cc), bcc: texts(recipients.bcc), subject: subject)
    }

    /// The envelope with another subject, its recipients and kind as they are.
    func with(subject: String) -> ChatReplyCompose {
        ChatReplyCompose(isReplyAll: isReplyAll, to: to, cc: cc, bcc: bcc, subject: subject)
    }

    /// Whether a draft with `recipients` and `subject`, from `accountId`, is this envelope: the same
    /// subject, exactly, and in each role the same addresses and the same entries that name no
    /// sendable address (a Reply-To's `undisclosed-recipients:;`), each read as its text, in any
    /// case. Names and order do not count.
    func holds(recipients: ComposeDraftGuards.Recipients, subject: String, accountId: String, of message: MessageHeader) -> Bool {
        func addresses(_ list: [String]) -> Set<String> { Set(RecipientEntry(list).addresses.map { $0.lowercased() }) }
        func addresses(_ field: ComposeDraftGuards.RecipientField) -> Set<String> {
            Set(field.tokens.map { $0.lowercased() })
        }
        func leftovers(_ list: [String]) -> Set<String> { Set(RecipientEntry(list).leftovers.map { $0.lowercased() }) }
        func leftovers(_ field: ComposeDraftGuards.RecipientField) -> Set<String> {
            Set(field.rejected.map { $0.lowercased() })
        }
        return accountId == message.accountId
            && subject == self.subject
            && addresses(recipients.to) == addresses(to) && addresses(recipients.cc) == addresses(cc)
            && addresses(recipients.bcc) == addresses(bcc)
            && leftovers(recipients.to) == leftovers(to) && leftovers(recipients.cc) == leftovers(cc)
            && leftovers(recipients.bcc) == leftovers(bcc)
    }

    /// The compose card, opened in this kind, as main's Reply All entries open it.
    /// `draftId`: the draft it saves to; nil, the reply's usual one.
    @MainActor
    func composeView(
        replyTo message: MessageHeader?, suggestedBody: String? = nil, suggestion: ReplyResult? = nil,
        draftId: String? = nil, onAgentOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        // The fields exactly as given, an empty one included: a reply whose To is empty (an edit
        // removed everyone, or the only Reply-To is the user's own) opens with To empty, never
        // refilled from the reply.
        ComposeView(
            replyTo: message, suggestedBody: suggestedBody, suggestion: suggestion, isReplyAll: isReplyAll,
            prefillTo: to, prefillCc: cc, prefillBcc: bcc, prefillSubject: subject,
            prefillDraftId: draftId, onAgentOutcome: onAgentOutcome)
    }
}

/// THE presenter of the agent's compose card, for every host (the chat, the inbox, the email's
/// screen): the request carries the card exactly, so where it opens decides nothing.
extension AgentToolRouter.ComposeRequest {
    /// `account`: the sender a new email opens with.
    @MainActor
    func composeView(account: Account?, onOutcome: @escaping @MainActor (ComposeOutcome) -> Void) -> ComposeView {
        switch mode {
        case .compose:
            ComposeView(
                suggestedBody: body, account: account, prefillTo: to, prefillCc: cc, prefillBcc: bcc,
                prefillSubject: subject, onAgentOutcome: onOutcome)
        case .reply:
            // The reply tool's envelope exactly (`EmailReplyTool`): its fields, an empty one
            // included, its subject and its kind.
            ComposeView(
                replyTo: replyTo, suggestedBody: body, suggestion: suggestion, isReplyAll: isReplyAll,
                prefillTo: to, prefillCc: cc, prefillBcc: bcc, prefillSubject: subject,
                prefillDraftId: draftId, onAgentOutcome: onOutcome)
        case .forward:
            ComposeView(
                replyTo: replyTo, suggestedBody: body, isForward: true, prefillTo: to, prefillCc: cc, prefillBcc: bcc,
                onAgentOutcome: onOutcome)
        }
    }
}

/// The ready AI Suggestion's compose card: the email it answers, the suggestion as the ghost showed
/// it, and its envelope (`ChatReplyCompose.suggestionEnvelope`).
struct ChatReadyReply: Identifiable {
    let message: MessageHeader
    let suggestion: ReplyResult
    let compose: ChatReplyCompose
    /// A draft of its own: the chat leaves the reply draft already saved for this email alone
    /// (it stays in Drafts), so the card never opens, saves over or deletes it.
    let draftId: String
    var id: MessageHeader.ID { message.id }

    init(message: MessageHeader, suggestion: ReplyResult, accounts: [Account]) {
        self.message = message
        self.suggestion = suggestion
        compose = ChatReplyCompose.suggestionEnvelope(for: message, accounts: accounts)
        draftId = Draft.separateReplyKey(replyTo: "\(message.accountId):\(message.stableId)")
    }
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

/// The AI Suggestion's row in the chat: the working bubble while the AI writes it
/// (`ChatReplyField.suggestionPhase`), then the ghost with its text (`ChatReplyField.shown`).
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
