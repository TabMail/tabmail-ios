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
///  5. A reply sent from the chat shows its words on the user's bubble until that email's own text
///     message arrives, and only on the email that is that reply (N7).
///  6. The view wires each of these: hosted SwiftUI views cannot be driven from a unit test, so the
///     wiring is read from the source.
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

    @Test("Dictation over the untouched AI Reply in the field replaces it; edited words, no reply, or the open sheet keep the text")
    func dictationReplacesOnlyTheUntouchedReply() {
        let ready = "Sounds good, see you Friday"
        func field(after words: String, input: String, readyText: String?, expanded: Bool) -> String {
            ChatReplyField.dictated(words, onto: input, replacing: ChatReplyField.dictationReplaces(
                input: input, readyText: readyText, expanded: expanded))
        }
        #expect(field(after: "Can we do Monday", input: ready, readyText: ready, expanded: false) == "Can we do Monday")
        #expect(field(after: "or Monday", input: ready + " maybe", readyText: ready, expanded: false)
                == ready + " maybe or Monday", "edited words stay")
        #expect(field(after: "what is this about", input: ready, readyText: ready, expanded: true)
                == ready + " what is this about", "the open chat sheet adds to it")
        #expect(field(after: "hello", input: "", readyText: nil, expanded: false) == "hello")
        #expect(field(after: "there", input: "hi", readyText: nil, expanded: false) == "hi there")
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

    @Test("A sent reply belongs to the email that answers it, sent from about then, in the same account")
    func sentReplyMatching() {
        let replies = ChatSentReplies()
        replies.add(accountId: "acc1", repliedTo: "<1@example.com>", text: "  Tuesday works \n", sentAt: Self.now)
        replies.add(accountId: "acc1", repliedTo: "<1@example.com>", text: "   ", sentAt: Self.now)
        #expect(replies.entries.map(\.text) == ["Tuesday works"], "trimmed; empty words are not kept")

        let entries = replies.entries
        let sent = Self.header("2", inReplyTo: "<1@example.com>")
        #expect(ChatSentReplies.entry(for: sent, in: entries)?.text == "Tuesday works")

        let slackMinutes = ChatViewLayout.sentReplyDateSlack / 60
        let early = Self.header("3", minutesAgo: slackMinutes - 0.1, inReplyTo: "<1@example.com>")
        #expect(ChatSentReplies.entry(for: early, in: entries) != nil, "a clock a little behind")
        let older = Self.header("4", minutesAgo: slackMinutes + 1, inReplyTo: "<1@example.com>")
        #expect(ChatSentReplies.entry(for: older, in: entries) == nil, "an earlier reply to the same email")

        let other = Self.header("5", inReplyTo: "<9@example.com>")
        #expect(ChatSentReplies.entry(for: other, in: entries) == nil, "a reply to another email")
        let noParent = Self.header("6")
        #expect(ChatSentReplies.entry(for: noParent, in: entries) == nil)
        var otherAccount = sent
        otherAccount.accountId = "acc2"
        #expect(ChatSentReplies.entry(for: otherAccount, in: entries) == nil, "another account")

        #expect(replies.entries(accountId: "acc1", messageIds: ["<1@example.com>"]).count == 1)
        #expect(replies.entries(accountId: "acc1", messageIds: ["<9@example.com>"]).isEmpty, "another chat")
        #expect(replies.entries(accountId: "acc2", messageIds: ["<1@example.com>"]).isEmpty)
    }

    @Test("A sent reply goes once its email has a text message, or after its lifetime")
    func sentReplySettles() {
        let replies = ChatSentReplies()
        replies.add(accountId: "acc1", repliedTo: "<1@example.com>", text: "Tuesday works", sentAt: Self.now)
        replies.add(accountId: "acc1", repliedTo: "<8@example.com>", text: "Sure", sentAt: Self.now)

        let summarizing = Self.item(Self.header("2", inReplyTo: "<1@example.com>"))
        replies.settle([summarizing], now: Self.now)
        #expect(replies.entries.count == 2, "still being summarized")

        let summarized = Self.item(Self.header("2", inReplyTo: "<1@example.com>", text: "Tuesday works for me"))
        replies.settle([summarized], now: Self.now)
        #expect(replies.entries.map(\.repliedTo) == ["<8@example.com>"], "only the summarized email's entry goes")

        replies.settle([], now: Self.now.addingTimeInterval(ChatViewLayout.sentReplyLifetime))
        #expect(replies.entries.count == 1, "kept through its lifetime")
        replies.settle([], now: Self.now.addingTimeInterval(ChatViewLayout.sentReplyLifetime + 1))
        #expect(replies.entries.isEmpty, "gone after it")

        replies.add(accountId: "acc1", repliedTo: "<1@example.com>", text: "Old", sentAt: Self.now)
        replies.add(accountId: "acc1", repliedTo: "<1@example.com>", text: "New",
                    sentAt: Self.now.addingTimeInterval(ChatViewLayout.sentReplyLifetime + 1))
        #expect(replies.entries.map(\.text) == ["New"], "adding prunes old entries")
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

    @Test("The field's Send opens compose for the unchanged AI Reply, else sends the words to the agent")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Both dictation paths take the field's decision (on-device and cloud).
        #expect(Self.count("let replacesReadyReply = ChatReplyField.dictationReplaces( input: inputText, readyText: replyField?.readyText, expanded: isExpanded)", in: text) == 1)
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

    @Test("The chat opens compose for the AI Reply and keeps a sent reply's words")
    func chatWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("onSendReadyReply: { readyReplyMessage = newest }", in: text) == 1)
        #expect(Self.count("onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg, words: words) }", in: text) == 1)
        #expect(Self.count("composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil, words: words)", in: text) == 1)
        #expect(Self.count("onAgentOutcome: onOutcome)", in: text) == 3, "every agent compose")
        let ended = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, words: String?) {", in: text)
        #expect(Self.count("guard case .sent = outcome else { return }", in: ended) == 1)
        #expect(Self.count("sentReplies.add(accountId: replyTo.accountId, repliedTo: repliedTo, text: words)", in: ended) == 1)
        #expect(Self.count("sentReplies.settle(thread.items)", in: text) == 1)
        #expect(Self.count("ChatSentReplyBubble(text: entry.text)", in: text) == 1)
    }
}
