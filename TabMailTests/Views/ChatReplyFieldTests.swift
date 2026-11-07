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
///     (owner 2026-11-07): an empty field, or the AI Reply the app put there, takes it whenever it
///     arrives, collapsed or in the open sheet; words typed or said are never replaced, and no
///     reply lands while a dictation is bringing words.
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

    @Test("Dictation over the untouched AI Reply replaces it; edited words or no reply keep the text")
    func dictationReplacesOnlyTheUntouchedReply() {
        let ready = "Sounds good, see you Friday"
        func field(after words: String, input: String, readyText: String?) -> String {
            ChatReplyField.dictated(words, onto: input, replacing: ChatReplyField.dictationReplaces(
                input: input, readyText: readyText))
        }
        #expect(field(after: "Can we do Monday", input: ready, readyText: ready) == "Can we do Monday",
                "the AI Reply is not the user's words, in the field or the open sheet")
        #expect(field(after: "or Monday", input: ready + " maybe", readyText: ready)
                == ready + " maybe or Monday", "edited words stay")
        #expect(field(after: "hello", input: "", readyText: nil) == "hello")
        #expect(field(after: "there", input: "hi", readyText: nil) == "hi there")
    }

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

    // MARK: - 7. Whose words are in the field

    /// Offers `ready` of the newest email `email` while the user has not spoken last, unless told otherwise.
    private static func offer(
        _ fill: inout ChatFieldFill, _ ready: String?, input: String, busy: Bool = false, email: String? = "email-1"
    ) -> String? {
        fill.offer(ready, input: input, busy: busy, email: email)
    }

    @Test("An empty field or the app's own AI Reply takes the ready reply; words typed over it stay")
    func readyReplyReplacesOnlyItsOwn() {
        var fill = ChatFieldFill()
        #expect(Self.offer(&fill, "First reply", input: "") == "First reply")
        #expect(Self.offer(&fill, "Newer reply", input: "First reply") == "Newer reply", "the app's own is replaced")
        #expect(Self.offer(&fill, "Latest reply", input: "Newer reply, and more") == nil, "typed words stay")
        #expect(Self.offer(&fill, "Latest reply", input: "Newer") == nil, "words cut back by hand stay")
        #expect(fill.filled == "Newer reply", "a refused offer changes nothing")

        // Emptied by the app (a send or an answer), the field holds no words of the user's: the reply shows again.
        #expect(Self.offer(&fill, "Latest reply", input: "") == "Latest reply")
        // A reply taken back empties the app's fill, and nothing else.
        #expect(Self.offer(&fill, nil, input: "Latest reply") == "")
        #expect(Self.offer(&fill, nil, input: "My own words") == nil)
    }

    @Test("A completion empties only the words that were sent, nothing, or the app's AI Reply; newer words stay")
    func completionClearsOnlyTheSentWords() {
        // Nothing sent yet (a reply sent from a bubble's compose card): the field empties.
        let fresh = ChatFieldFill()
        #expect(fresh.clears("Anything"))

        // Sent from the collapsed field, then a newer draft typed in the open sheet.
        var fill = ChatFieldFill()
        _ = Self.offer(&fill, "A ready reply", input: "")
        fill.sent(input: "First request")
        #expect(fill.clears("First request"), "the words sent")
        #expect(fill.clears(""))
        #expect(fill.clears("A ready reply"), "the app's own AI Reply")
        #expect(!fill.clears("My newer draft"), "words written after the send are newer")
        // Once emptied, the next completion has no send to protect.
        fill.cleared()
        #expect(fill.atSend == nil)
        #expect(fill.clears("Anything"))

        // Sent from the open sheet, which empties as it sends: whatever is typed next is newer.
        var sheet = ChatFieldFill()
        sheet.sent(input: "")
        #expect(sheet.clears(""))
        #expect(!sheet.clears("Typed after the send"))
    }

    @Test("Emptied by hand, the field stays empty for that email; a newer email shows its own reply")
    func emptiedByHandStaysEmpty() {
        var fill = ChatFieldFill()
        #expect(Self.offer(&fill, "A reply", input: "") == "A reply")
        fill.emptiedByHand(on: "email-1")
        #expect(fill.filled == nil, "the emptied field holds nothing of the app's")
        #expect(Self.offer(&fill, "A reply", input: "") == "", "it stays empty")
        #expect(Self.offer(&fill, "A newer reply to it", input: "") == "", "even for a newer AI Reply to that email")
        #expect(Self.offer(&fill, "My words", input: "My words") == nil, "and the user's words stay")
        #expect(Self.offer(&fill, "A reply to the newer email", input: "", email: "email-2") == "A reply to the newer email",
                "a new email is a new turn")
    }

    @Test("While the user spoke last, a dictation running or the agent answering, no AI Reply fills the field")
    func dictationOwnsTheField() {
        // Started on an empty field, a reply arrives while the words are transcribed.
        var fill = ChatFieldFill()
        _ = Self.offer(&fill, nil, input: "")
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "", busy: true) == nil)
        // The words land, then the dictation ends, in either order of the two changes.
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "My dictated request") == nil,
                "the end of the dictation never replaces the words it brought")
        #expect(Self.offer(&fill, "A later reply", input: "My dictated request") == nil, "nor does a later reply")

        // Nothing was said: the reply that arrived meanwhile fills the empty field at the end.
        var silent = ChatFieldFill()
        #expect(Self.offer(&silent, "Yes, Tuesday works.", input: "", busy: true) == nil)
        #expect(Self.offer(&silent, "Yes, Tuesday works.", input: "") == "Yes, Tuesday works.")
    }

    @Test("A send or an answer empties the field, and the ready reply then shows again")
    func sendThenRefill() {
        var fill = ChatFieldFill()
        _ = Self.offer(&fill, "A reply", input: "")
        fill.sent(input: "My question")
        #expect(Self.offer(&fill, "A reply", input: "My question") == nil, "never while the words wait in the field")
        #expect(fill.clears("My question"))
        fill.cleared()
        #expect(fill.atSend == nil)
        #expect(Self.offer(&fill, "A reply", input: "") == "A reply", "the emptied field shows the ready reply")
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

    @Test("Every change that can fill the field asks ChatFieldFill, with the dictation")
    func fieldFillWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let fill = try Self.body(of: "private func fillReadyReply() {", in: text)
        #expect(Self.count("guard let replyField, let words = fieldFill.offer( replyField.readyText, input: inputText, busy: isDictating || isWorking, email: message?.id) else { return } inputText = words", in: fill) == 1)
        // Only the user's own edits mark the field emptied by hand.
        #expect(Self.count("TextField(placeholder, text: typedText,", in: text) == 1)
        #expect(Self.count("if replyField != nil, typed.isEmpty, !inputText.isEmpty { fieldFill.emptiedByHand(on: message?.id) }", in: text) == 1)
        #expect(Self.count("fieldFill.emptiedByHand(", in: text) == 1)
        #expect(Self.count("if wasWorking && !nowWorking { fieldSentText = nil fillReadyReply() }", in: text) == 1)
        #expect(Self.count("dictation.isActive || speech.isRecording || speech.isStarting", in: text) == 1)
        #expect(Self.count(".onChange(of: replyField?.readyText, initial: true) { _, _ in fillReadyReply() }", in: text) == 1)
        #expect(Self.count(".onChange(of: inputText) { _, text in if text.isEmpty { fillReadyReply() } }", in: text) == 1)
        #expect(Self.count(".onChange(of: isDictating) { _, dictating in if !dictating { fillReadyReply() } }", in: text) == 1)
        // A completion empties the field only while it holds what was sent (`ChatFieldFill.clears`),
        // for an answer or a sent reply and for a confirmation card; both sends record it.
        #expect(Self.count("fieldSentText = nil // Words written after the send this completes are newer, and stay (`ChatFieldFill.clears`). guard fieldFill.clears(inputText) else { return } inputText = \"\" fieldFill.cleared()", in: text) == 1)
        #expect(Self.count("if fieldFill.clears(inputText) { inputText = \"\" }", in: text) == 1)
        #expect(Self.count("fieldFill.cleared()", in: text) == 1)
        #expect(Self.count("if replyField != nil { fieldFill.sent(input: \"\") }", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.sent(input: inputText) if ChatReplyField.route", in: text) == 1)
        #expect(Self.count("fillReadyReply()", in: text) == 5, "the four triggers and the definition")
        #expect(Self.count("inputText = words", in: text) == 1, "the field is filled in one place")
    }

    @Test("The field's Send opens compose for the unchanged AI Reply, else sends the words to the agent")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Collapsed, the reply field's Send takes the field's route; the open sheet keeps the chat's.
        let message = try Self.body(of: "private func sendMessage() {", in: text)
        // Send refuses only an empty input, and the collapsed field then takes its own route.
        #expect(message.hasPrefix(" let text = inputText.trimmingCharacters(in: .whitespaces) guard !text.isEmpty else { return } if let replyField, !isExpanded { sendFromReplyField(text, replyField) return }"))
        // Both dictation paths take the field's decision (on-device and cloud).
        #expect(Self.count("let replacesReadyReply = ChatReplyField.dictationReplaces( input: inputText, readyText: replyField?.readyText)", in: text) == 1)
        #expect(Self.count("speechBase = replacesReadyReply ? \"\" : inputText", in: text) == 1)
        #expect(Self.count("inputText = ChatReplyField.dictated(text, onto: inputText, replacing: replacesReadyReply)", in: text) == 1)
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
        #expect(Self.count("ChatSentReplyBubble(progress: sentReplies.progress[entry.id])", in: text) == 1)
    }
}
