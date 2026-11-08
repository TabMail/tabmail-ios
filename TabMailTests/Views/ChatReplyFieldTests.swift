/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// ADR-IOS-103: the chat's reply field.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The field holds the ready AI Reply's text message only for someone else's email that has
///     a full AI Reply, from an address that takes replies (N2.6, E1).
///  2. Send with that text unchanged opens the compose card; any other words go to the agent
///     (N2.6, N4.4, A1).
///  3. Words for the agent name the newest email and say they came from its reply field; for a
///     no-reply sender they say not to write a reply (section 3c, E1.2).
///  4. While the agent writes a reply the line above the field says so (N5.1).
///  5. A reply sent from the chat shows as a Sending bubble following its queued email, and only a
///     sent card makes one (N7; the bubble itself: `ChatSendingBubbleTests`).
///  6. The view wires each of these: hosted SwiftUI views cannot be driven from a unit test, so the
///     wiring is read from the source.
///  7. A ready AI Reply shows in the field only while the field holds no words of the user's
///     (owner 2026-11-07), collapsed or in the open sheet: what the field shows is a function of
///     the user's words (`ChatFieldFill.shown`), so words typed or said are never replaced, said
///     words replace a shown reply, no reply shows while a dictation is bringing words, a field
///     emptied by hand stays empty for that email only, and a completion empties only the words
///     that were sent.
@Suite("Chat reply field")
@MainActor
struct ChatReplyFieldTests {
    private static let now = Date()

    private static func header(
        _ uid: String,
        fromAddress: String = "alex@example.com",
        minutesAgo: Double = 0,
        inReplyTo: String? = nil,
        reply: String? = nil,
        replyText: String? = nil,
        text: String? = nil
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Alex Doe", fromAddress: fromAddress,
            to: "me@example.com", date: now.addingTimeInterval(-minutesAgo * 60),
            snippet: "snippet \(uid)", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(uid)@example.com>"
        header.inReplyTo = inReplyTo
        header.cachedReply = reply
        header.replyTextMessage = replyText
        header.summaryTextMessage = text
        return header
    }

    private static func item(_ header: MessageHeader) -> ChatThread.Item {
        ChatThread(
            members: [header], replyAddresses: { [$0.fromAddress] }, ownAddresses: ["me@example.com"],
            draftFolderIds: [], sentFolderIds: [], unreadAtOpen: [], preferredId: nil
        ).items[0]
    }

    // MARK: - 1. The ready AI Reply

    @Test("The field holds the AI Reply's text message only for someone else's email with a full reply")
    func readyText() {
        let ready = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.readyText(newest: ready, isOwn: false) == "Tuesday works")
        #expect(ChatReplyField.readyText(newest: ready, isOwn: true) == nil, "the user's own email")

        let noReply = Self.header("2", fromAddress: "noreply@example.com", reply: "Hi", replyText: "Hi")
        #expect(ChatReplyField.readyText(newest: noReply, isOwn: false) == nil, "a no-reply sender")

        let noFullReply = Self.header("3", reply: "", replyText: "Tuesday works")
        #expect(ChatReplyField.readyText(newest: noFullReply, isOwn: false) == nil, "no full reply stored")
        let missingReply = Self.header("4", replyText: "Tuesday works")
        #expect(ChatReplyField.readyText(newest: missingReply, isOwn: false) == nil)

        let noText = Self.header("5", reply: "Hi Alex", replyText: "")
        #expect(ChatReplyField.readyText(newest: noText, isOwn: false) == nil, "no text message")
        let missingText = Self.header("6", reply: "Hi Alex")
        #expect(ChatReplyField.readyText(newest: missingText, isOwn: false) == nil)
    }

    @Test("The placeholder offers a reply only when the sender takes replies")
    func placeholder() {
        #expect(ChatReplyField(readyText: nil, isNoReply: false, clearCount: 0).placeholder == "Reply or ask anything")
        #expect(ChatReplyField(readyText: nil, isNoReply: true, clearCount: 0).placeholder == "Ask anything")
    }

    // MARK: - 2. Send

    @Test("Send with the AI Reply unchanged opens compose; anything else goes to the agent")
    func route() {
        #expect(ChatReplyField.route(text: "Tuesday works", readyText: "Tuesday works") == .readyReply)
        #expect(ChatReplyField.route(text: "  Tuesday works\n", readyText: "Tuesday works ") == .readyReply,
                "spacing at the ends is not a change")
        #expect(ChatReplyField.route(text: "Tuesday works, see you", readyText: "Tuesday works") == .agent)
        #expect(ChatReplyField.route(text: "Tuesday works", readyText: nil) == .agent, "no AI Reply")
        #expect(ChatReplyField.route(text: "", readyText: "Tuesday works") == .agent)
    }

    // MARK: - 3. The agent's message

    @Test("Words for the agent name the email and say where they came from")
    func agentMessage() {
        let reply = ChatReplyField.agentMessage(emailNumericId: 42, text: "say yes", isNoReply: false)
        #expect(reply == "Regarding [Email](42) (typed in its reply field; if what I want is unclear, I am replying to it): say yes")

        let noReply = ChatReplyField.agentMessage(emailNumericId: 7, text: "what is this", isNoReply: true)
        #expect(noReply.hasPrefix("Regarding [Email](7) ("))
        #expect(noReply.hasSuffix("): what is this"))
        #expect(noReply.contains("no-reply address, so do not write a reply"))
        #expect(!noReply.contains("I am replying to it"))
    }

    // MARK: - 4. The status line

    @Test("Writing a reply reads Writing your email; other steps keep the agent's label")
    func statusLine() throws {
        let writing = try #require(ToolRegistry.activityLabels["email_reply"])
        #expect(ChatReplyField.statusLine(writing) == "Writing your email")
        #expect(ChatReplyField.statusLine("Searching email") == "Searching email")
    }

    // MARK: - 5. Sent replies

    @Test("Only a sent compose card makes a Sending bubble, for a reply, following its queued email; a cancelled or failed one changes nothing",
          arguments: ["sent", "cancelled", "failed"])
    func composeEndedKeepsOnlySent(outcomeName: String) {
        let outcome: ComposeOutcome = switch outcomeName {
        case "sent": .sent(outboxId: "outbox-1")
        case "cancelled": .cancelled
        default: .failed("The account could not send")
        }
        let sent = outcomeName == "sent"
        let replies = ChatSentReplies()
        var parent = Self.header("1")
        parent.rfc822MessageId = "<1@example.com>"
        #expect(replies.composeEnded(outcome, replyTo: parent) == sent, "the field empties only after a send")
        #expect(replies.entries.map(\.outboxId) == (sent ? ["outbox-1"] : []), "the bubble follows the queued email")
        #expect(replies.entries.map(\.repliedTo) == (sent ? ["<1@example.com>"] : []))
        // A sent card without a parent (a new email or a forward) still empties the field.
        #expect(replies.composeEnded(outcome, replyTo: nil) == sent)
        #expect(replies.entries.count == (sent ? 1 : 0), "no parent, no bubble")
        #expect(replies.entries(accountId: parent.accountId, messageIds: ["<1@example.com>"]).count == (sent ? 1 : 0))
        #expect(replies.entries(accountId: parent.accountId, messageIds: ["<9@example.com>"]).isEmpty, "another chat")
        #expect(replies.entries(accountId: "acc2", messageIds: ["<1@example.com>"]).isEmpty, "another account")
    }

    @Test("Dictation starts by itself only with the preference on and never in the chat's reply field",
          arguments: [false, true], [false, true])
    func autoListens(autoDictation: Bool, inChat: Bool) {
        #expect(DynamicIslandChat.autoListens(autoDictation: autoDictation, inChat: inChat) == (autoDictation && !inChat))
    }

    @Test("Both automatic dictation starts ask the one rule, and nothing else starts dictation by itself")
    func autoListenWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("Self.autoListens(autoDictation: autoDictation, inChat: replyField != nil)", in: text) == 2,
                "the open and the after-the-agent's-turn starts")
        #expect(Self.count("startDictation(auto: true)", in: text) == 3, "those two and the prompt's Enable; no other automatic start")
        #expect(Self.count("} else if !dictationPromptShown && !TutorialCoordinator.shared.isRunning && replyField == nil {", in: text) == 1,
                "the prompt whose Enable starts dictation never shows in the chat")
    }

    @Test("A sent reply's bubble goes after its lifetime, and adding one prunes old ones")
    func sentReplyLifetime() {
        let replies = ChatSentReplies()
        var parent = Self.header("1")
        parent.rfc822MessageId = "<1@example.com>"
        replies.composeEnded(.sent(outboxId: "outbox-old"), replyTo: parent, now: Self.now)
        replies.settle([], now: Self.now.addingTimeInterval(ChatViewLayout.sentReplyLifetime))
        #expect(replies.entries.count == 1, "kept through its lifetime")
        replies.composeEnded(.sent(outboxId: "outbox-new"), replyTo: parent,
                             now: Self.now.addingTimeInterval(ChatViewLayout.sentReplyLifetime + 1))
        #expect(replies.entries.map(\.outboxId) == ["outbox-new"], "adding prunes old entries")
        replies.settle([], now: Self.now.addingTimeInterval(2 * ChatViewLayout.sentReplyLifetime + 2))
        #expect(replies.entries.isEmpty, "gone after it")
    }

    // MARK: - 7. What the field shows

    /// A field after `changes`, in order, all through the one API.
    private static func fill(_ changes: ChatFieldFill.Change...) -> ChatFieldFill {
        var fill = ChatFieldFill()
        for change in changes { fill.apply(change) }
        return fill
    }

    /// The user typed `text` into a reply field showing `shown`, on email `email`.
    private static func typed(_ text: String, over shown: String = "", email: String = "e1") -> ChatFieldFill.Change {
        .typed(text, shown: shown, email: email, replyField: true)
    }

    @Test("With no words of the user's the field shows the ready reply; their words always win")
    func shownIsTheUsersWordsOrTheReadyReply() {
        let fresh = ChatFieldFill()
        #expect(fresh.shown(ready: "A reply", busy: false, email: "e1") == "A reply")
        #expect(fresh.shown(ready: nil, busy: false, email: "e1") == "", "no ready reply, nothing")
        // A ready reply that changes is shown as it is now: nothing was ever written.
        #expect(fresh.shown(ready: "A newer reply", busy: false, email: "e1") == "A newer reply")
        #expect(fresh.words == "", "the reply is shown, never written into the words")

        let mine = Self.fill(Self.typed("My words", over: "A reply"))
        #expect(mine.shown(ready: "A reply", busy: false, email: "e1") == "My words")
        #expect(mine.shown(ready: "A reply", busy: true, email: "e1") == "My words")
    }

    @Test("While the user spoke last, a dictation running or the agent answering, no reply shows; said words replace a shown one")
    func busyHidesTheReply() {
        #expect(ChatFieldFill().shown(ready: "Yes, Tuesday works.", busy: true, email: "e1") == "")
        // The said words are the user's words: whichever order the words and the end of the
        // dictation come in, the field shows them.
        let said = Self.fill(.said("Can we do Monday"))
        let words = DictationController.appending("Can we do Monday", to: "")
        #expect(said.words == words)
        #expect(said.shown(ready: "Yes, Tuesday works.", busy: true, email: "e1") == words)
        #expect(said.shown(ready: "Yes, Tuesday works.", busy: false, email: "e1") == words)
        // Said words add to the words as they are when they come back, never to an older copy.
        let more = Self.fill(Self.typed("Hi"), .said("there"))
        #expect(more.words == DictationController.appending("there", to: "Hi"))
    }

    @Test("Edited, the shown reply becomes the user's words; emptied by hand, the field stays empty for that email only")
    func editsAreTheUsers() {
        var fill = ChatFieldFill()
        fill.apply(Self.typed("A reply, and more", over: "A reply"))
        #expect(fill.words == "A reply, and more", "an edit of the shown reply is the user's")
        #expect(fill.emptiedOn == nil, "an edit that leaves words is not an emptying")

        fill.apply(Self.typed("", over: "A reply, and more"))
        #expect(fill.words == "" && fill.emptiedOn == "e1")
        #expect(fill.shown(ready: "A reply", busy: false, email: "e1") == "", "it stays empty")
        #expect(fill.shown(ready: "A newer reply to it", busy: false, email: "e1") == "",
                "even for a newer AI Reply to that email")
        // A new email is a new turn, also when its AI Reply has the same text as the old one's.
        #expect(fill.shown(ready: "A reply", busy: false, email: "e2") == "A reply")

        // A set that leaves the shown reply as it was is no edit: the reply stays the app's.
        let untouched = Self.fill(Self.typed("A reply", over: "A reply"))
        #expect(untouched.words == "" && untouched.changes == 0)
        // Emptying a field that showed nothing is not an emptying by hand, nor is the plain chat input's.
        #expect(Self.fill(Self.typed("", over: "")).emptiedOn == nil)
        #expect(Self.fill(.typed("", shown: "x", email: "e1", replyField: false)).emptiedOn == nil)
    }

    @Test("A completion empties only the words that were sent, or none; newer words stay")
    func completionClearsOnlyTheSentWords() {
        // Nothing sent yet (a reply sent from a bubble's compose card): the words empty.
        #expect(Self.fill(Self.typed("Anything"), .completed).words == "")

        // Sent from the collapsed field, then a newer draft typed in the open sheet.
        var fill = Self.fill(Self.typed("First request"), .sentFromField)
        #expect(fill.atSend == "First request" && fill.words == "First request", "the words wait in the field")
        fill.apply(Self.typed("My newer draft", over: "First request"))
        fill.apply(.completed)
        #expect(fill.words == "My newer draft", "words written after the send are newer")
        #expect(fill.atSend == nil)
        // Once completed, the next completion has no send to protect.
        fill.apply(.completed)
        #expect(fill.words == "")
        // The words sent, still there: the completion empties them.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .completed).words == "")

        // The untouched AI Reply sent from the field: no words were the user's, so any typed since stay.
        #expect(Self.fill(.sentFromField, Self.typed("Typed after the send"), .completed).words == "Typed after the send")
        // From the open sheet the words go at once; a draft typed next stays through the completion.
        let sheet = Self.fill(Self.typed("Ask"), .sentFromSheet)
        #expect(sheet.words == "" && sheet.atSend == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromSheet, Self.typed("Next draft"), .completed).words == "Next draft")
        // A confirmation card empties the words sent, and the send stays open for its completion.
        let card = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard)
        #expect(card.words == "" && card.atSend == "Ask")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Newer", over: "Ask"), .confirmationCard).words == "Newer")
    }

    @Test("A send or an answer empties the words, and the ready reply then shows again")
    func sendThenShowAgain() {
        var fill = Self.fill(Self.typed("My question"), .sentFromField)
        #expect(fill.shown(ready: "A reply", busy: false, email: "e1") == "My question",
                "never while the words wait in the field")
        fill.apply(.completed)
        #expect(fill.shown(ready: "A reply", busy: false, email: "e1") == "A reply")
    }

    @Test("A live transcript adds to the words it started on, and is dropped once anything else changed them")
    func liveTranscriptComparesTheChangeCounter() {
        var fill = Self.fill(Self.typed("Hi"), .startHearing)
        fill.apply(.heard("there"))
        #expect(fill.words == DictationController.appending("there", to: "Hi"))
        // Each transcript is the whole of what was heard so far: it replaces its own last one.
        fill.apply(.heard("there friend"))
        #expect(fill.words == DictationController.appending("there friend", to: "Hi"))

        // The user changes the words: a transcript that comes after is dropped, and so is every
        // later one of that dictation.
        let current = fill.words
        fill.apply(Self.typed("My own words", over: current))
        fill.apply(.heard("there friend, late"))
        #expect(fill.words == "My own words")
        fill.apply(.heard("there friend, later"))
        #expect(fill.words == "My own words")
        // So does any other change: a completion, a send, an Edit, a dictation's text.
        for change in [ChatFieldFill.Change.completed, .sentFromSheet, .put("Edited"), .said("said")] {
            var other = Self.fill(Self.typed("Hi"), .startHearing, .heard("one"))
            other.apply(change)
            let after = other.words
            other.apply(.heard("one two"))
            #expect(other.words == after, "a transcript after \(change) is dropped")
        }
        // A transcript with no dictation started changes nothing.
        #expect(Self.fill(Self.typed("Hi"), .heard("stray")).words == "Hi")
        // A new dictation starts from the words as they are now.
        fill.apply(.startHearing)
        fill.apply(.heard("again"))
        #expect(fill.words == DictationController.appending("again", to: "My own words"))
    }

    // MARK: - 6. Wiring

    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature))
        let end = try #require(text[start.upperBound...].range(of: " private "))
        return String(text[start.upperBound..<end.lowerBound])
    }

    @Test("The input shows ChatFieldFill's text, and every change to its words goes through the one API")
    func fieldShownWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("TextField(placeholder, text: typedText,", in: text) == 1)
        #expect(Self.count("Binding(get: { fieldText }, set: { typed in fieldFill.apply(.typed(typed, shown: fieldText, email: fieldEmail, replyField: replyField != nil)) })", in: text) == 1)
        #expect(Self.count("fieldFill.shown(ready: replyField?.readyText, busy: isDictating || isWorking, email: fieldEmail)", in: text) == 1)
        #expect(Self.count("message.map(ChatThread.copyKey)", in: text) == 1)
        #expect(Self.count("dictation.isActive || speech.isRecording || speech.isStarting", in: text) == 1)
        // ONE API: the view only reads the words; every change is a `fieldFill.apply`.
        #expect(Self.count("private var inputText: String { fieldFill.words }", in: text) == 1)
        #expect(Self.count("var inputText", in: text) == 1)
        #expect(Self.count("fieldFill.", in: text)
                == Self.count("fieldFill.apply(", in: text) + Self.count("fieldFill.shown(", in: text) + Self.count("fieldFill.words", in: text),
                "nothing else touches the field's state")
        // Each change, where it happens: typing (above), both dictations, both sends, the
        // completion, a confirmation card, and an Edit.
        #expect(Self.count("fieldFill.apply(.startHearing) speech.start(locale: speechLocale, auto: auto) { transcript in fieldFill.apply(.heard(transcript))", in: text) == 1)
        #expect(Self.count("{ text in fieldFill.apply(.said(text))", in: text) == 1)
        #expect(Self.count("fieldSentText = nil // Words written after the send this completes are newer, and stay (`ChatFieldFill`). fieldFill.apply(.completed)", in: text) == 1)
        #expect(Self.count("guard hasCard, replyField != nil, !isExpanded else { return } fieldFill.apply(.confirmationCard)", in: text) == 1)
        #expect(Self.count("dictation.inputSent(inputText) // From the open sheet the input empties as it goes; a newer draft is what is typed next. fieldFill.apply(.sentFromSheet)", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.apply(.sentFromField) if ChatReplyField.route", in: text) == 1)
        #expect(Self.count("fieldFill.apply(.put(text)) isTextFieldFocused = true", in: text) == 1)
        #expect(Self.count("fieldFill.apply(", in: text) == 9)
    }

    @Test("The field's Send opens compose for the unchanged AI Reply, else sends the words to the agent")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Collapsed, the reply field's Send takes the field's route; the open sheet keeps the chat's.
        let message = try Self.body(of: "private func sendMessage() {", in: text)
        // Send refuses only an empty input, and the collapsed field then takes its own route.
        #expect(message.hasPrefix(" let text = fieldText.trimmingCharacters(in: .whitespaces) guard !text.isEmpty else { return } if let replyField, !isExpanded { sendFromReplyField(text, replyField) return }"))
        let send = try Self.body(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {", in: text)
        #expect(Self.count("if ChatReplyField.route(text: text, readyText: field.readyText) == .readyReply { onSendReadyReply?() return }", in: send) == 1)
        #expect(Self.count("onFieldSend?(text)", in: send) == 1)
        #expect(Self.count("sendAgentChat(text, fromReplyField: true)", in: send) == 1)
        #expect(Self.count("sendFromReplyField(", in: text) == 2, "Send reaches it")
        #expect(Self.count("enrichedText = ChatReplyField.agentMessage( emailNumericId: numericId, text: text, isNoReply: replyField?.isNoReply ?? false)", in: text) == 1)
        #expect(Self.count("enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)", in: text) == 1)
    }

    @Test("The chat opens compose for the AI Reply and shows a sent reply's Sending bubble")
    func chatWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("onSendReadyReply: { readyReplyMessage = newest }", in: text) == 1)
        #expect(Self.count("onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg) }", in: text) == 1)
        #expect(Self.count("composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)", in: text) == 1)
        #expect(Self.count("onAgentOutcome: onOutcome)", in: text) == 3, "every agent compose")
        // Every compose card hands its own outcome on: four callbacks, none naming an outcome itself.
        #expect(Self.count("onAgentOutcome:", in: text) == 4)
        #expect(Self.count("composeEnded(.", in: text) == 0 && Self.count("{ _ in composeEnded", in: text) == 0)
        #expect(Self.count("onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg) })", in: text) == 1,
                "the field's own compose hands on its outcome")
        #expect(Self.count("req.onOutcome(outcome) composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)", in: text) == 1,
                "an agent compose hands on its outcome")
        let ended = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {", in: text)
        #expect(Self.count("if sentReplies.composeEnded(outcome, replyTo: replyTo) { fieldClearCount += 1 }", in: ended) == 1)
        #expect(Self.count("sentReplies.settle(thread.items)", in: text) == 1)
        #expect(Self.count("ChatSentReplyBubble( progress: sentReplies.progress[entry.id], "
            + "retry: { sentReplies.retry(entry) }, delete: { sentReplies.delete(entry) } )", in: text) == 1,
                "a failed send's Retry and Delete act on its own entry")
    }
}
