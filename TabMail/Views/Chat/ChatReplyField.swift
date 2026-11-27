/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The chat's reply field (ADR-IOS-114 decision 10): the pill on the newest email becomes
/// [mic] [field] [Send]. The field holds only the user's words: the ready AI Suggestion waits as a
/// ghost bubble in the chat (`ChatSuggestionBubble`), and a tap on it opens the compose card.
/// What the words mean is decided by where they are sent, never by the AI guessing (decision 10,
/// amended 2026-11-25 and 2026-11-26): the closed field's words are always the user's own message,
/// in the way they would text it. Send there puts them up at once as the user's bubble, and the
/// email that says them is written to the people of this chat (`ChatFieldCompose`),
/// never a message to the agent; the words typed in the open TabMail panel go to the agent. Under
/// the AI Suggestion, while the field is empty, a line offers another reply the user could send
/// instead (`ChatAlternativeLink`, `alternativeTap`); a tap puts it in the field and never sends it.
struct ChatReplyField {
    /// The latest tap on the line under the AI Suggestion (`ChatAlternativeLink`): its reply goes
    /// in the field (`DynamicIslandChat.putAlternative`); nil, none yet.
    var alternativeTap: ChatAlternativeTap? = nil
    /// Told whenever a dictation into the field starts or ends (`DynamicIslandChat.isDictating`):
    /// while its words are coming, the chat shows no line under the AI Suggestion, so a tap never
    /// cuts off or mixes with them; nil, not told.
    var dictationChanged: ((Bool) -> Void)? = nil
    /// The reply goes only to these people; nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil
    /// In the tutorial, the step's move in the read-only field (part 2); nil, none.
    var tutorialMove: TutorialCoordinator.FieldMove? = nil
    /// In the tutorial, in the chat that holds Priya's practice email (part 2): the open panel
    /// shows the step's coach card above its input, and its input the step's request
    /// (`TutorialCoordinator.panelPrompt`). The chat's own handling after a card button ran; nil
    /// in any other chat.
    var tutorialPanelCard: ((TutorialCoachContent.Action) -> Void)? = nil
    /// A drag up in flight, whose swell grows the field toward the panel (`ChatFieldDrag.Swell`);
    /// nil swells nothing.
    var drag: ChatFieldDrag.Model? = nil
    /// VoiceOver's "Show TabMail chat" (`ChatViewConfig.showChatActionName`), the drag up's
    /// equivalent, offered on the element VoiceOver focuses (`showChatAction`); nil offers nothing
    /// (the panel open, the tutorial except at its drag-up step).
    var showChat: (() -> Void)? = nil
    /// A new email's chat (`ChatNewThreadView`): the field has no email to reply to; nil in a
    /// thread's chat.
    var newEmail: ChatNewEmailField? = nil
    /// A thread's chat: a choice in the paperclip's menu, which opens the reply's compose card once
    /// something is picked (`ChatReadyReply(attaching:)`); nil shows no paperclip.
    var attach: ((ChatNewEmailField.AttachSource) -> Void)? = nil

    /// The paperclip's choice at the text's end: a new email's or a thread's; nil, none.
    var paperclip: ((ChatNewEmailField.AttachSource) -> Void)? {
        newEmail?.attach ?? attach
    }

    /// The closed field's hint, a thread's and a new email's alike: its words are the user's own
    /// message, which its Send writes as the email to the people (a no-reply sender's too; the chat
    /// says replies won't be read).
    static let writePlaceholder = "Write your message"
    /// The open TabMail panel's hint in a chat: its words go to TabMail, about this chat.
    static let panelPlaceholder = "Ask TabMail"

    /// The ready AI Suggestion of the thread's newest email, the one value the ghost bubble and the
    /// line under it read (`MessageHeader.suggestion`): shown while its full
    /// reply and its text version are stored. Nothing on the user's turn, for a no-reply sender,
    /// or while the reply goes only to people chosen in Reply to (`onlyTo`): the suggestion was
    /// written for everyone.
    /// Nothing while the field's Send writes its email (`writing`: the user's own bubble stands in
    /// its place) or a compose card is open (`cardOpen`): a suggestion that became ready meanwhile
    /// shows once the card closes without sending (a send makes it the user's turn). Words in the
    /// field never hide it: it waits as the ghost.
    static func shown(
        newest: MessageHeader, usersTurn: Bool, onlyTo: [ChatThread.Person]?,
        writing: Bool = false, cardOpen: Bool = false
    ) -> ReplyResult? {
        guard !writing, !cardOpen, !usersTurn, onlyTo == nil, !EmailFilter.isNoReply(newest.fromAddress),
              let suggestion = newest.suggestion, !suggestion.body.isEmpty,
              let text = suggestion.textMessage, !text.isEmpty else { return nil }
        return suggestion
    }

    /// The reply of the line under the AI Suggestion (`ChatAlternativeLink`): while the suggestion
    /// shows (`shown`), the other reply that came with it, one line in the user's voice that goes
    /// the other way (stored in the suggestion's
    /// one-line slot, `ReplyResult.changeCommand`); nil when no suggestion shows or it has none.
    static func alternative(shown: ReplyResult?) -> String? {
        guard let line = shown?.changeCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return nil
        }
        return line
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

    /// The agent's status while it works from the reply field: its own labels, except that
    /// writing a reply, or a new email's chat's email, reads "Writing your email" (`writingStatus`).
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] || label == ToolRegistry.activityLabels["email_compose"]
            ? writingStatus : label
    }

    /// The line under the user's own bubble while the closed field's Send writes the email
    /// (`ChatFieldMessageBubble.status`).
    static let writingStatus = "Writing your email"
}

/// The field of a new email's chat (`ChatNewThreadView`): no email to reply to, so Send goes to the
/// new email's chat, which asks who it is to or writes it; the field's words are the new email's
/// draft, the user's own message as in a thread's chat; the paperclip at the field's end adds
/// attachments. Its agent chat is its own, in memory only (`sessionKey`), never an email's thread
/// chat or the inbox chat.
struct ChatNewEmailField {
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
    /// Send with words in the field: the chat decides (`ChatNewDraft.send`). It returns whom the
    /// email is written to and under what subject, read at the tap, and the field's words are the
    /// message the new email says, as a reply's are (`ChatFieldCompose.newEmail`, never the agent);
    /// nil when the chat asked who it is to, and the words stay as they are.
    let send: (String) -> Write?
    /// A choice in the paperclip's menu.
    let attach: (AttachSource) -> Void

    /// Whom a new email's Send writes to: the people picked in the chat, and the subject the chat
    /// shows ("" when it shows none: the email written gives one).
    struct Write: Equatable {
        let people: [ChatThread.Person]
        let subject: String
    }

    /// A new email's chat session key: a fresh one for each new email's chat.
    static func newSessionKey() -> String { "\(sessionKeyPrefix)\(UUID().uuidString)" }

    private static let sessionKeyPrefix = "new-email:"

    /// Whether `key` is a new email's chat session key (`newSessionKey`).
    static func isSessionKey(_ key: String) -> Bool { key.hasPrefix(sessionKeyPrefix) }
}

/// A tap on the line under the AI Suggestion (`ChatAlternativeLink`), carried from the chat to its
/// field (`ChatReplyField.alternativeTap`): the reply to put there. Each tap is a new value, so the
/// same reply tapped again is put again.
struct ChatAlternativeTap: Equatable {
    let id = UUID()
    let reply: String
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
    /// The field still holds the words of its open send, unedited: true from the field's Send until
    /// any edit of the words. Ownership follows edits, not content: words cleared and retyped to the
    /// same text after Send are newly written, so they are kept and no completion empties them.
    private(set) var holdsSentWords = false
    /// A confirmation card took the field's sent words off the input (the request shows in the
    /// sheet), unedited since: true from that card until any edit of the words or the send's end.
    /// They are still the send's words, so if the field's own compose card then closes unsent, the
    /// answer hands them back (`answered`) as it does when they stayed on the input.
    private(set) var sentWordsTaken = false
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
        /// them (an Edit of an earlier message, or the reply of the line under the AI Suggestion).
        case put(String)
        /// Send from the open sheet: the words go, and nothing is left to complete.
        case sentFromSheet
        /// Send from the collapsed field: the words are kept, held for the send (they show as the
        /// user's bubble, not in the field), until the send completes or hands them back.
        case sentFromField
        /// The open send completed (its compose card's reply went out): it empties the words only
        /// if a send is open and they are still the words sent, or none.
        case completed
        /// The field's send finished with something written (its compose card closed), or the
        /// agent answered it (the tutorial's scripted request):
        /// `completed`, unless a compose card opened for it and closed unsent; then the words are
        /// the user's again, kept and not emptied.
        case answered
        /// A compose card opened for the field's send (`composing`).
        case composeOpened
        /// A confirmation card opened the sheet: the same check, and the send is still open.
        case confirmationCard
        /// The field's Send wrote nothing (no compose card opened), or Stop ended it: the send ends
        /// and its words are the user's again, back in the field.
        case notWritten
    }

    /// The words to keep for the chat (`ChatFieldWords`): the words, except a send's still in
    /// flight (they are up as the user's bubble).
    var unsent: String { holdsSentWords ? "" : words }

    /// The only way the words change.
    mutating func apply(_ change: Change) {
        let before = words
        switch change {
        case let .said(text):
            words = DictationController.appending(text, to: words)
            holdsSentWords = false
            sentWordsTaken = false
        case .startHearing:
            hearing = Hearing(base: words, at: changes)
            return
        case let .heard(transcript):
            guard let hearing, hearing.at == changes else { self.hearing = nil; return }
            words = DictationController.appending(transcript, to: hearing.base)
            holdsSentWords = false
            sentWordsTaken = false
            changes += 1
            self.hearing = Hearing(base: hearing.base, at: changes)
            return
        case let .put(text):
            // A set that leaves the words as they are is no edit (a binding's echo); any real
            // edit, even one that ends back on the sent text, makes the words newly written.
            guard text != words else { return }
            words = text
            holdsSentWords = false
            sentWordsTaken = false
        case .sentFromSheet:
            atSend = ""
            words = ""
            holdsSentWords = false
            sentWordsTaken = false
        case .sentFromField:
            atSend = words
            holdsSentWords = true
            sentWordsTaken = false
            composing = false
        case .completed:
            if clears { words = "" }
            atSend = nil
            holdsSentWords = false
            sentWordsTaken = false
            composing = false
        case .answered:
            // A compose card that opened for the send owns its completion. The answer comes once
            // the card is done; if it is still composing, the card closed unsent: the answer
            // empties nothing and hands the words back to the user, so they are kept. Words a
            // confirmation card took off the input before the card opened come back too.
            if composing {
                if sentWordsTaken, let atSend { words = atSend }
            } else if clears {
                words = ""
            }
            atSend = nil
            holdsSentWords = false
            sentWordsTaken = false
            composing = false
        case .composeOpened:
            composing = true
        case .confirmationCard:
            // Same ownership as `answered`: once a compose card opened for the send, the card owns
            // its completion, and a confirmation for another step of the request empties nothing.
            // Before that, it takes the sent words off the input, still the send's words (a
            // second card finds them taken already).
            if !composing, clears {
                if holdsSentWords { sentWordsTaken = true }
                words = ""
                holdsSentWords = false
            }
        case .notWritten:
            atSend = nil
            holdsSentWords = false
            sentWordsTaken = false
            composing = false
        }
        if words != before { changes += 1 }
    }

    /// Whether a send's completion may empty the words: only while a send is open, and only if
    /// they are still the words sent, unedited (`holdsSentWords`), or none. With no send open (a compose card's Send already
    /// completed it, or nothing was sent), a later card, compose or answer of the same request
    /// leaves the words: they are newer than the send.
    private var clears: Bool {
        guard atSend != nil else { return false }
        return holdsSentWords || words.isEmpty
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

/// A Send from the chat's reply field, as it was when sent (ADR-IOS-114 decision 11): the email
/// the field replies to and who the user chose in Reply to. It travels with the Send
/// (`ToolInvocation.fieldReply`, then `ComposeRequest.fieldReply` on its reply), so the chat that
/// shows the compose card never decides who it goes to from its own state at that moment.
struct ChatFieldReply: Sendable, Equatable {
    /// The email the field showed, as it showed it: its row and that row's identity. The reply is
    /// written to this email only while the row is still this email.
    let email: MessageHeader
    /// The addresses chosen in Reply to; nil: Reply All.
    let onlyTo: [String]?
}

/// A send from the chat's reply field, read once as it starts: the email it is about and who the
/// user chose in Reply to. The send's request is built from it, so nothing reads the field again.
struct ChatFieldSend {
    let message: MessageHeader
    let onlyTo: [ChatThread.Person]?

    var fieldReply: ChatFieldReply {
        ChatFieldReply(email: message, onlyTo: onlyTo?.map(\.address))
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
        let audience = ChatThread.replyAllAudience(of: message, accounts: accounts)
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

    /// The compose card, opened in this kind, as main's Reply All entries open it. `draftId`: the
    /// draft it saves to; nil, the reply's usual one. `attachmentPick`: added once it has loaded
    /// (`ComposeView.attachmentPick`). `openedOn`: the screen the chat records for it
    /// (`ChatThreadView.composeScreen`).
    @MainActor
    func composeView(
        replyTo message: MessageHeader?, suggestedBody: String? = nil, suggestion: ReplyResult? = nil,
        offersStoredSuggestion: Bool = true, draftId: String? = nil, attachmentPick: ComposeAttachmentPick? = nil,
        openedOn: ComposeScreen?, onAgentOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        // The fields exactly as given, an empty one included: a reply whose To is empty (an edit
        // removed everyone, or the only Reply-To is the user's own) opens with To empty, never
        // refilled from the reply.
        ComposeView(
            replyTo: message, suggestedBody: suggestedBody, suggestion: suggestion,
            offersStoredSuggestion: offersStoredSuggestion, isReplyAll: isReplyAll,
            prefillTo: to, prefillCc: cc, prefillBcc: bcc, prefillSubject: subject,
            attachmentPick: attachmentPick, prefillDraftId: draftId, openedOn: openedOn, onAgentOutcome: onAgentOutcome)
    }
}

/// THE presenter of the agent's compose card, for every host (the chat, the inbox, the email's
/// screen): the request carries the card exactly, so where it opens decides nothing in it. The host
/// gives only the screen it records for a reply's or a forward's Undo (`openedOn`).
extension AgentToolRouter.ComposeRequest {
    /// `account`: the sender a new email opens with. `openedOn`: the screen the compose was opened on
    /// (`ComposeView.openedOn`): the chat's `composeScreen(answering:)`; nil on any other screen.
    @MainActor
    func composeView(account: Account?, openedOn: ComposeScreen? = nil, onOutcome: @escaping @MainActor (ComposeOutcome) -> Void) -> ComposeView {
        switch mode {
        case .compose:
            // A new email: no chat shows it, so it records no screen and keeps the toast.
            ComposeView(
                suggestedBody: body, account: account, prefillTo: to, prefillCc: cc, prefillBcc: bcc,
                prefillSubject: subject, onAgentOutcome: onOutcome)
        case .reply:
            // The reply tool's envelope exactly (`EmailReplyTool`): its fields, an empty one
            // included, its subject and its kind. A reply only to the people chosen in the field's
            // Reply to keeps its words written for them (`ComposeView.onlyToChosen`).
            ComposeView(
                replyTo: replyTo, suggestedBody: body, suggestion: suggestion, isReplyAll: isReplyAll,
                onlyToChosen: fieldReply?.onlyTo != nil,
                prefillTo: to, prefillCc: cc, prefillBcc: bcc, prefillSubject: subject,
                prefillDraftId: draftId, openedOn: openedOn, onAgentOutcome: onOutcome)
        case .forward:
            ComposeView(
                replyTo: replyTo, suggestedBody: body, isForward: true, prefillTo: to, prefillCc: cc, prefillBcc: bcc,
                openedOn: openedOn, onAgentOutcome: onOutcome)
        }
    }
}

/// A reply compose card the chat opens on its newest email: the ready AI Suggestion's (a tap on the
/// ghost), or the paperclip's (something picked in the reply field). It holds the email it answers,
/// the suggestion in its box as the chat showed it, its envelope and what was picked.
struct ChatReadyReply: Identifiable {
    let message: MessageHeader
    /// The suggestion in the card's box, as the chat showed it; nil: none, and the card reads no
    /// other (`ComposeView.offersStoredSuggestion`).
    let suggestion: ReplyResult?
    let compose: ChatReplyCompose
    /// A draft of its own: the chat leaves the reply draft already saved for this email alone
    /// (it stays in Drafts), so the card never opens, saves over or deletes it.
    let draftId: String
    /// The paperclip's pick, added once the card has loaded; nil for the ghost's card.
    let pick: ComposeAttachmentPick?
    var id: MessageHeader.ID { message.id }

    /// The ghost's card: Reply All with the suggestion the ghost showed (`ChatReplyCompose.suggestionEnvelope`).
    init(message: MessageHeader, suggestion: ReplyResult, accounts: [Account]) {
        self.message = message
        self.suggestion = suggestion
        compose = ChatReplyCompose.suggestionEnvelope(for: message, accounts: accounts)
        draftId = Self.ownDraftId(message)
        pick = nil
    }

    /// The paperclip's card: a reply to `message` to whom the field's reply goes, with `pick`
    /// attached. Reply All is the suggestion's envelope with the suggestion the chat shows
    /// (`shown`); "Replying only to" is a plain reply to only those people with no suggestion,
    /// since the suggestion was written for everyone.
    init(attaching pick: ComposeAttachmentPick, to message: MessageHeader, onlyTo: [ChatThread.Person]?,
         shown: ReplyResult?, accounts: [Account]) {
        self.message = message
        self.pick = pick
        if let onlyTo {
            compose = ChatReplyCompose.onlyTo(onlyTo.map(\.address), replying: message)
            suggestion = nil
        } else {
            compose = ChatReplyCompose.suggestionEnvelope(for: message, accounts: accounts)
            suggestion = shown
        }
        draftId = Self.ownDraftId(message)
    }

    private static func ownDraftId(_ message: MessageHeader) -> String {
        Draft.separateReplyKey(replyTo: "\(message.accountId):\(message.stableId)")
    }

    /// The card as the chat presents it: its envelope, its suggestion and nothing stored in its
    /// place, its own draft and its pick. `openedOn`: the screen the chat records for it
    /// (`ChatThreadView.composeScreen`).
    @MainActor
    func composeView(
        openedOn: ComposeScreen?, onOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        compose.composeView(
            replyTo: message, suggestion: suggestion, offersStoredSuggestion: false, draftId: draftId,
            attachmentPick: pick, openedOn: openedOn, onAgentOutcome: onOutcome)
    }
}

/// The AI Suggestion's ghost the user tapped, or the user's own message the field's Send wrote
/// (`isMessage`), held in its place in the chat while its compose card is up, so the chat behind
/// the card still shows it as the card opens and closes. UI only: the send itself is the card's,
/// persisted to the outbox before the card closes. The hold ends once the card has finished
/// closing: at once if nothing was sent, or if the chat does not show this send as its bubble
/// (`showsBubble`); after a send it shows, once the reply shows (its outbox bubble, or the sent
/// email itself), and the held bubble turns into that bubble.
struct ChatHeldGhost: Equatable {
    /// The bubble's words, as it showed them.
    let text: String
    /// The user's own message from the field (`ChatFieldMessageBubble`), not the ghost.
    var isMessage = false
    /// The chat shows this card's send as its bubble (`ChatThreadView.composeScreen`).
    let showsBubble: Bool
    /// The card sent the reply.
    var sent = false
    /// The card has finished closing.
    var cardClosed = false

    /// The hold ends now. `replyShows`: the chat shows the sent reply, as its outbox bubble or as
    /// the sent email.
    func ends(replyShows: Bool) -> Bool {
        cardClosed && (!sent || !showsBubble || replyShows)
    }

    /// Ending turns the held bubble into the sent reply's bubble (else it simply goes).
    var morphs: Bool { sent && showsBubble }
}

/// The user's own message while the closed field's Send writes its email (ADR-IOS-114 decision 10,
/// amended 2026-11-26): the words, verbatim, go up at once as the user's bubble in the AI
/// Suggestion's place (a ghost showing gives way to it), and the bubble pulses while the email is
/// written; written, it stops, stays to be read (`ChatSuggestionConfig.writtenHold`), then the
/// compose card opens and the bubble is held behind it (`ChatHeldGhost`). Stop, or nothing
/// written, takes it away and the words are back in the field. UI only, from Send until the card is
/// taken or the send ends.
struct ChatFieldMessage: Equatable {
    /// The words sent, as they were in the field.
    let text: String
    /// The email that says them is written.
    var written = false

    /// The bubble pulses while the email is written.
    var pulses: Bool { !written }
}

/// A reply or forward in the outbox the chat does not show as an email yet, shown as the user's
/// bubble at the bottom of the chat whose email it answers. Read from the database and the chat's
/// own emails, with nothing kept in memory: every outbox row whose parent (a reply's In-Reply-To,
/// or the last References id of a forward, `AccountManager.queuedParentRfc822MessageId`) is the
/// Message-ID of an email in the chat, from any account (the send may go out from another account
/// than the email it answers). A failed row reads "Not sent", with Retry and Delete; any other
/// "Sending". Its text is the email's text version (`SentEmailSummary.textMessage`): the one written
/// with its body when it was sent unchanged, from its first value; otherwise the summary made at
/// Send, "Summarizing" until then.
///
/// The hand-over from the ghost or the field's message: a ghost tapped open, or the user's own
/// message the field's Send wrote, is held in its place while its card is up (`ChatHeldGhost`),
/// and after a send it turns into this bubble.
///
/// The hand-over to the sent email: once the provider takes the email the send stamps `sentAt`, then
/// writes the optimistic Sent copy under the row's Message-ID, or under the one its provider gave the
/// copy (Gmail; `SentCopyLink`), which is then the copy's Message-ID here. A sent row whose copy is
/// one of the chat's emails is not read. The bubble itself is the chat's to keep (`ChatSendBubbles`):
/// the filing names the copy (`MailPointerMove.sent`), the chat then reloads its emails, and a filed
/// send's bubble stays, "Sent", after the send's cleanup deletes the row, until the chat shows the
/// copy. A row that goes with no filing (Undo, a discard) ends its bubble.
struct ChatUnsentReply: Identifiable, Equatable, Sendable {
    let outboxId: String
    /// The row's state, as the Outbox's own Cancel Send reads it (`OutboxCancellationPolicy`).
    let status: OutboxStatus
    let sentAt: Date?
    let holdUntil: Date?
    /// The send's draft generation, for Undo's reopen (`ChatUndoSendStatus`).
    let draftId: String?
    let instanceEpoch: String?
    var failed: Bool { status == .failed }
    /// The email's summary as a text message, once made.
    let textMessage: String?
    /// The send filed the email (`ChatSendBubbles`): it went out, and the bubble stays, "Sent",
    /// until the chat shows the email itself.
    var isSent = false

    var id: String { outboxId }

    /// The line under the bubble, as under every email of the user's.
    var caption: String { failed ? "Not sent" : isSent ? "Sent" : "Sending" }

    /// The outbox rows answering one of `messageIds` (normalized Message-IDs of the chat's emails)
    /// whose email is not one of them, oldest first. A sent row without its Message-ID cannot be
    /// handed over and shows nothing.
    nonisolated static func fetch(answering messageIds: Set<String>, db: Database) throws -> [ChatUnsentReply] {
        guard !messageIds.isEmpty else { return [] }
        let rows = try OutboxMessage
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
        return try rows.compactMap { row in
            guard answers(AccountManager.queuedParentRfc822MessageId(of: row), in: messageIds) else { return nil }
            if row.sentAt != nil {
                // The Sent copy's Message-ID: its provider's own when it gave one (`SentCopyLink`).
                guard let sentId = row.sentMessageId.map({
                          SentCopyLink.copyMessageId(accountId: row.accountId, sentMessageId: $0) }),
                      !messageIds.contains(sentId) else { return nil }
            }
            return ChatUnsentReply(outboxId: row.id, status: row.outboxStatus, sentAt: row.sentAt, holdUntil: row.holdUntil,
                                   draftId: row.draftId, instanceEpoch: row.instanceEpoch,
                                   textMessage: try SentEmailSummary.textMessage(of: row, db: db))
        }
    }

    /// Whether a send with this parent (a reply's In-Reply-To, a forward's last References id)
    /// shows in the chat whose emails have `messageIds` (normalized Message-IDs): it answers one of
    /// them. The one rule for which chat shows an outbox row (`fetch`), and so for which chat a
    /// compose records as its screen (`ChatThreadView.composeScreen`).
    nonisolated static func answers(_ parent: String?, in messageIds: Set<String>) -> Bool {
        guard let parent = parent.map(EmailFilter.normalizeMessageId) else { return false }
        return messageIds.contains(parent)
    }

    /// The unsent replies answering `messageIds`, now and after every change, from one observation.
    static func changes(answering messageIds: Set<String>) -> AsyncValueObservation<[ChatUnsentReply]> {
        ValueObservation
            .tracking { db in try fetch(answering: messageIds, db: db) }
            .removeDuplicates()
            .values(in: AppDatabase.rawPool)
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
