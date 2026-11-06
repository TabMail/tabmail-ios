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
///  6. With recipients changed (Reply to), Send has the agent write the reply again for the people
///     chosen, and its message names them; everyone ticked is Reply All (R1, R2.4, Q33).
///  7. VoiceOver reads who an email went to when it was not everyone (Q25).
///  8. A ready AI Reply fills the field only while the field is the app's, and only over an empty
///     field or the AI Reply the app put there: never over words typed or said, in the field or in
///     the open sheet, and never while a dictation is bringing words. One that arrives while the
///     sheet is open or a dictation runs fills the untouched field once that ends.
///  9. The view wires each of these: hosted SwiftUI views cannot be driven from a unit test, so the
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

    @Test("Only a sent compose card keeps the reply's words and empties the field; a cancelled or failed one changes nothing",
          arguments: ["sent", "cancelled", "failed"])
    func composeEndedKeepsOnlySent(outcomeName: String) {
        let outcome: ComposeOutcome = switch outcomeName {
        case "sent": .sent
        case "cancelled": .cancelled
        default: .failed("The account could not send")
        }
        let sent = outcomeName == "sent"
        let replies = ChatSentReplies()
        var parent = Self.header("1")
        parent.rfc822MessageId = "<1@example.com>"
        #expect(replies.composeEnded(outcome, replyTo: parent, words: "Tuesday works") == sent,
                "the field empties only after a send")
        #expect(replies.entries.map(\.text) == (sent ? ["Tuesday works"] : []), "the Sent bubble keeps the words only after a send")
        #expect(replies.entries.map(\.repliedTo) == (sent ? ["<1@example.com>"] : []))
        // A sent card without the field's words (an agent compose) or without a parent still empties the field.
        #expect(replies.composeEnded(outcome, replyTo: parent, words: nil) == sent)
        #expect(replies.composeEnded(outcome, replyTo: nil, words: "Hello") == sent)
        #expect(replies.entries.count == (sent ? 1 : 0), "no words, no Sent bubble")
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

    // MARK: - 6. Changed recipients

    private static let david = ChatThread.Person(address: "david@example.com", name: "David Kim")
    private static let sarah = ChatThread.Person(address: "sarah@example.com", name: "Sarah Chen")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam Lee")

    @Test("With recipients changed, the unchanged AI Reply goes to the agent to be written again")
    func changedRecipientsRoute() {
        #expect(ChatReplyField.route(text: "Tuesday works", readyText: "Tuesday works", recipientsChanged: true) == .agent)
        #expect(ChatReplyField.route(text: "Tuesday works", readyText: "Tuesday works", recipientsChanged: false) == .readyReply)
    }

    @Test("The agent's message names the people a reply goes only to")
    func agentMessageOnlyTo() {
        let message = ChatReplyField.agentMessage(
            emailNumericId: 3, text: "say yes", isNoReply: false, onlyTo: [Self.david, Self.sam])
        #expect(message == "Regarding [Email](3) (typed in its reply field; if what I want is unclear, I am replying to it; a reply goes only to David Kim <david@example.com>, Sam Lee <sam@example.com>): say yes")
        #expect(ChatReplyField.agentMessage(emailNumericId: 3, text: "x", isNoReply: false, onlyTo: [])
                == ChatReplyField.agentMessage(emailNumericId: 3, text: "x", isNoReply: false))
    }

    @Test("Everyone on the newest email ticked, nobody added, is Reply All; anything else is only them")
    func replyTarget() {
        let people = [Self.sarah, Self.david]
        #expect(ChatReplyTarget.chosen([Self.david, Self.sarah], replyPeople: people) == .replyAll, "order does not matter")
        #expect(ChatReplyTarget.chosen([Self.david], replyPeople: people).only == [Self.david])
        #expect(ChatReplyTarget.chosen(people + [Self.sam], replyPeople: people).only == people + [Self.sam],
                "someone added")
        let chips = ChatReplyTarget.chips([Self.david, Self.sarah, Self.sam, Self.david])
        #expect(chips.names == ["David Kim", "Sarah Chen"] && chips.more == 2)
        #expect(ChatReplyTarget.chips([Self.david]).more == 0)
    }

    @Test("Reply to starts from the current choice, ticks and unticks, and adds people")
    func replyToChoice() {
        let people = [Self.sarah, Self.david]
        var choice = ChatReplyToChoice(replyPeople: people, target: .replyAll)
        #expect(choice.people == people && choice.ticked == ["sarah@example.com", "david@example.com"])
        #expect(choice.target(replyPeople: people) == .replyAll)

        choice.toggle(Self.sarah)
        #expect(!choice.isTicked(Self.sarah) && choice.target(replyPeople: people).only == [Self.david])
        choice.toggle(Self.david)
        #expect(!choice.canFinish, "nobody to reply to")
        choice.toggle(Self.sarah)
        #expect(choice.canFinish)

        let own: Set<String> = ["me@example.com"]
        let addedSam = choice.add("Sam Lee <Sam@Example.com>", ownAddresses: own)
        #expect(addedSam)
        #expect(choice.people.last == Self.sam, "a typed address, lowercased, with its name")
        let addedPat = choice.add("pat@example.com", name: "Pat Doe", ownAddresses: own)
        #expect(addedPat)
        #expect(choice.people.last?.name == "Pat Doe", "a contact pick keeps the contact's name")
        let addedMe = choice.add("me@example.com", ownAddresses: own)
        #expect(!addedMe, "never the user")
        let addedText = choice.add("not an address", ownAddresses: own)
        #expect(!addedText)
        #expect(choice.people.count == 4)

        choice.toggle(Self.sam)
        let reAdded = choice.add("sam@example.com", ownAddresses: own)
        #expect(reAdded, "adding someone listed ticks them")
        #expect(choice.people.count == 4 && choice.isTicked(Self.sam))
        #expect(choice.target(replyPeople: people).only?.map(\.address)
                == ["sarah@example.com", "sam@example.com", "pat@example.com"])

        let reopened = ChatReplyToChoice(replyPeople: people, target: ChatReplyTarget(only: [Self.david, Self.sam]))
        #expect(reopened.people == people + [Self.sam], "the added person is listed again")
        #expect(reopened.ticked == ["david@example.com", "sam@example.com"])
    }

    // MARK: - 7. VoiceOver

    @Test("VoiceOver reads who an email went to when it was not everyone")
    func accessibilityOnlyTo() throws {
        func item(from: String, to: String, minutesAgo: Double) -> MessageHeader {
            var header = Self.header(String(Int(minutesAgo)), fromAddress: from, minutesAgo: minutesAgo)
            header.from = from == "me@example.com" ? "Me" : "Priya Vasanth"
            header.to = to
            return header
        }
        let all = item(from: "sarah@example.com", to: "me@example.com, Priya Vasanth <priya@example.com>", minutesAgo: 30)
        var allHeader = all
        allHeader.from = "Sarah Chen"
        let toMe = item(from: "priya@example.com", to: "me@example.com", minutesAgo: 20)
        let mine = item(from: "me@example.com", to: "Priya Vasanth <priya@example.com>", minutesAgo: 10)
        let chat = ChatThread(
            members: [allHeader, toMe, mine], replyAddresses: { [$0.fromAddress] },
            ownAddresses: ["me@example.com"], draftFolderIds: [], sentFolderIds: [], unreadAtOpen: [], preferredId: nil)
        guard chat.items.count == 3 else { Issue.record("three bubbles"); return }
        #expect(ChatBubbleView.accessibilityText(item: chat.items[0], words: "Hi all") == "Sarah Chen said: Hi all")
        #expect(ChatBubbleView.accessibilityText(item: chat.items[1], words: "Between us")
                == "Priya Vasanth replied only to you, said: Between us")
        #expect(ChatBubbleView.accessibilityText(item: chat.items[2], words: "Will do")
                == "You replied only to Priya Vasanth, saying: Will do")
        let only = try #require(chat.items[1].repliedOnlyTo)
        #expect(ChatBubbleView.listNames(only) == ["You"])
    }

    // MARK: - 8. Whose words are in the field

    /// Offers `ready` with the field collapsed, nothing sent and no dictation, unless told otherwise.
    private static func offer(
        _ fill: inout ChatFieldFill, _ ready: String?, input: String,
        expanded: Bool = false, sent: Bool = false, dictating: Bool = false
    ) -> String? {
        fill.offer(ready, input: input, expanded: expanded, sent: sent, dictating: dictating)
    }

    @Test("A newer AI Reply replaces the one the app put in the field, never words typed over it")
    func readyReplyReplacesOnlyItsOwn() {
        var fill = ChatFieldFill()
        #expect(Self.offer(&fill, "First reply", input: "") == "First reply")
        fill.edited("First reply", expanded: false)
        #expect(!fill.isUsers, "the app's own fill is not the user's edit")
        #expect(Self.offer(&fill, "Newer reply", input: "First reply") == "Newer reply")
        fill.edited("Newer reply", expanded: false)

        fill.edited("Newer reply, and more", expanded: false)
        #expect(fill.isUsers)
        #expect(Self.offer(&fill, "Latest reply", input: "Newer reply, and more") == nil)

        // Emptied by hand, the field stays empty: the user took it.
        var cleared = ChatFieldFill()
        _ = Self.offer(&cleared, "A reply", input: "")
        cleared.edited("", expanded: false)
        #expect(Self.offer(&cleared, "A newer reply", input: "") == nil)
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

    @Test("While a dictation runs no AI Reply fills the field; after it, the dictated words stay")
    func dictationOwnsTheField() {
        // Started on an empty field, a reply arrives while the words are transcribed.
        var fill = ChatFieldFill()
        _ = Self.offer(&fill, nil, input: "")
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "", dictating: true) == nil)
        // The words land, then the dictation ends, in either order of the two changes.
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "My dictated request") == nil,
                "the end of the dictation never replaces the words it brought")
        fill.edited("My dictated request", expanded: false)
        #expect(fill.isUsers)

        // Nothing was said: the reply that arrived meanwhile fills the untouched field at the end.
        var silent = ChatFieldFill()
        #expect(Self.offer(&silent, "Yes, Tuesday works.", input: "", dictating: true) == nil)
        #expect(Self.offer(&silent, "Yes, Tuesday works.", input: "") == "Yes, Tuesday works.")

        // A new newest email while the field is empty and a dictation runs: still nothing fills it.
        var newer = ChatFieldFill()
        newer.newEmail(input: "")
        #expect(Self.offer(&newer, "A reply to the newer email", input: "", dictating: true) == nil)
    }

    @Test("A reply that arrives while the sheet is open fills the untouched field when it closes; words left in the sheet stay")
    func sheetKeepsItsWordsAndFillsOnClose() {
        var fill = ChatFieldFill()
        _ = Self.offer(&fill, nil, input: "")
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "", expanded: true) == nil, "never into the open sheet")
        #expect(Self.offer(&fill, "Yes, Tuesday works.", input: "") == "Yes, Tuesday works.", "filled on close")

        var asked = ChatFieldFill()
        _ = Self.offer(&asked, nil, input: "")
        asked.edited("My own question", expanded: true)
        #expect(Self.offer(&asked, "Yes, Tuesday works.", input: "My own question") == nil, "on close")
        #expect(Self.offer(&asked, "A later reply", input: "My own question") == nil, "and later")

        // The sheet opened over the app's reply, a newer one came meanwhile: it replaces the older.
        var older = ChatFieldFill()
        _ = Self.offer(&older, "Older reply", input: "")
        #expect(Self.offer(&older, "Newer reply", input: "Older reply", expanded: true) == nil)
        #expect(Self.offer(&older, "Newer reply", input: "Older reply") == "Newer reply")
    }

    @Test("Words sent wait in the field; a send or an answer empties it for good; a new newest email frees an empty field")
    func sendAndNewEmail() {
        var fill = ChatFieldFill()
        #expect(Self.offer(&fill, "A reply", input: "", sent: true) == nil, "never while the words are with the agent")
        fill.cleared()
        #expect(Self.offer(&fill, "A reply", input: "") == nil, "the emptied field stays empty")

        fill.newEmail(input: "Words for the old email")
        #expect(Self.offer(&fill, "A reply to the new email", input: "Words for the old email") == nil,
                "words still in the field stay the user's")
        fill.newEmail(input: "")
        #expect(!fill.isUsers)
        #expect(Self.offer(&fill, "A reply to the new email", input: "") == "A reply to the new email")
        #expect(Self.offer(&fill, nil, input: "A reply to the new email") == "", "a reply taken back empties the app's fill")
    }

    // MARK: - 9. Wiring

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

    @Test("Every change that can fill the field asks ChatFieldFill, with the dictation and the sheet")
    func fieldFillWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let fill = try Self.body(of: "private func fillReadyReply() {", in: text)
        #expect(Self.count("guard let replyField, let words = fieldFill.offer( replyField.readyText, input: inputText, expanded: isExpanded, sent: fieldSentText != nil, dictating: isDictating) else { return } inputText = words", in: fill) == 1)
        #expect(Self.count("dictation.isActive || speech.isRecording || speech.isStarting", in: text) == 1)
        #expect(Self.count(".onChange(of: replyField?.readyText, initial: true) { _, _ in fillReadyReply() }", in: text) == 1)
        #expect(Self.count("fieldFill.newEmail(input: inputText) fillReadyReply()", in: text) == 1)
        #expect(Self.count(".onChange(of: isExpanded) { _, expanded in if !expanded { fillReadyReply() } }", in: text) == 1)
        #expect(Self.count(".onChange(of: isDictating) { _, dictating in if !dictating { fillReadyReply() } }", in: text) == 1)
        // A completion empties the field only while it holds what was sent (`ChatFieldFill.clears`),
        // for an answer or a sent reply and for a confirmation card; both sends record it.
        #expect(Self.count("fieldSentText = nil // Words written after the send this completes are newer, and stay (`ChatFieldFill.clears`). guard fieldFill.clears(inputText) else { return } inputText = \"\" fieldFill.cleared()", in: text) == 1)
        #expect(Self.count("if fieldFill.clears(inputText) { inputText = \"\" }", in: text) == 1)
        #expect(Self.count("fieldFill.cleared()", in: text) == 1)
        #expect(Self.count("if replyField != nil { fieldFill.sent(input: \"\") }", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.sent(input: inputText) if ChatReplyField.route", in: text) == 1)
        #expect(Self.count("guard replyField != nil else { return } fieldFill.edited(text, expanded: isExpanded)", in: text) == 1)
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
        #expect(Self.count("let replacesReadyReply = ChatReplyField.dictationReplaces( input: inputText, readyText: replyField?.readyText, expanded: isExpanded)", in: text) == 1)
        #expect(Self.count("speechBase = replacesReadyReply ? \"\" : inputText", in: text) == 1)
        #expect(Self.count("inputText = ChatReplyField.dictated(text, onto: inputText, replacing: replacesReadyReply)", in: text) == 1)
        let send = try Self.body(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {", in: text)
        #expect(Self.count("if ChatReplyField.route(text: text, readyText: field.readyText, recipientsChanged: field.onlyTo != nil) == .readyReply { onSendReadyReply?() return }", in: send) == 1)
        #expect(Self.count("onFieldSend?(text)", in: send) == 1)
        #expect(Self.count("sendAgentChat(text, fromReplyField: true)", in: send) == 1)
        #expect(Self.count("sendFromReplyField(", in: text) == 2, "Send reaches it")
        #expect(Self.count("enrichedText = ChatReplyField.agentMessage( emailNumericId: numericId, text: text, isNoReply: replyField?.isNoReply ?? false, onlyTo: replyField?.onlyTo)", in: text) == 1)
        #expect(Self.count("enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)", in: text) == 1)
    }

    @Test("The chat opens compose for the AI Reply and keeps a sent reply's words")
    func chatWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("onSendReadyReply: { readyReplyMessage = newest }", in: text) == 1)
        #expect(Self.count("onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg, words: words) }", in: text) == 1)
        #expect(Self.count("composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil, words: words)", in: text) == 1)
        #expect(Self.count("onAgentOutcome: onOutcome)", in: text) == 3, "every agent compose")
        // Every compose card hands its own outcome on: four callbacks, none naming an outcome itself.
        #expect(Self.count("onAgentOutcome:", in: text) == 4)
        #expect(Self.count("composeEnded(.", in: text) == 0 && Self.count("{ _ in composeEnded", in: text) == 0)
        #expect(Self.count("onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg, words: words) })", in: text) == 1,
                "the field's own compose hands on its outcome")
        #expect(Self.count("req.onOutcome(outcome) composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil, words: words)", in: text) == 1,
                "an agent compose hands on its outcome")
        let ended = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, words: String?) {", in: text)
        #expect(Self.count("if sentReplies.composeEnded(outcome, replyTo: replyTo, words: words) { fieldClearCount += 1 }", in: ended) == 1)
        #expect(Self.count("sentReplies.settle(thread.items)", in: text) == 1)
        #expect(Self.count("ChatSentReplyBubble(text: entry.text)", in: text) == 1)
    }

    @Test("A compose card asked for in the field carries the field's words and goes to the people chosen; one from the sheet keeps the agent's")
    func agentComposeFromTheField() {
        let chosen = ChatReplyTarget(only: [Self.david, Self.sam])
        let agentTo = ["sarah@example.com"], agentCc = ["team@example.com"]

        #expect(ChatAgentCompose.sentWords(mode: .reply, fromField: true, fieldWords: "Friday works") == "Friday works")
        #expect(ChatAgentCompose.sentWords(mode: .reply, fromField: false, fieldWords: "Friday works") == nil,
                "a reply from the sheet shows its email's own text message")
        #expect(ChatAgentCompose.sentWords(mode: .forward, fromField: true, fieldWords: "Friday works") == nil)
        #expect(ChatAgentCompose.sentWords(mode: .compose, fromField: true, fieldWords: "Friday works") == nil)

        let fromField = ChatAgentCompose.replyRecipients(fromField: true, target: chosen, to: agentTo, cc: agentCc)
        #expect(fromField.to == [Self.david.address, Self.sam.address] && fromField.cc.isEmpty)
        let fromSheet = ChatAgentCompose.replyRecipients(fromField: false, target: chosen, to: agentTo, cc: agentCc)
        #expect(fromSheet.to == agentTo && fromSheet.cc == agentCc, "the sheet's request keeps the agent's recipients")
        let replyAll = ChatAgentCompose.replyRecipients(fromField: true, target: .replyAll, to: agentTo, cc: agentCc)
        #expect(replyAll.to == agentTo && replyAll.cc == agentCc, "Reply All keeps the agent's recipients")
    }

    @Test("Reply to, Forward and the chosen people reach the field and the compose card")
    func recipientsWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("onlyTo: replyTarget.only)", in: chat) == 1, "the field knows the people chosen")
        #expect(Self.count("let (to, cc) = ChatAgentCompose.replyRecipients( fromField: fieldComposeOpened, target: replyTarget, to: req.to, cc: req.cc)", in: chat) == 1,
                "a reply asked for in the field goes to the people chosen")
        #expect(Self.count("let words = ChatAgentCompose.sentWords(mode: req.mode, fromField: fieldComposeOpened, fieldWords: fieldWords)", in: chat) == 1)
        // Where a card came from: the field while the sheet is closed; a field send starts afresh;
        // after a card from the field the agent's closing words open nothing.
        #expect(Self.count("fieldComposeOpened = !chatExpanded agentCompose = AgentToolRouter.shared.pendingCompose", in: chat) == 1)
        #expect(Self.count("fieldWords = words fieldComposeOpened = false", in: chat) == 1)
        #expect(Self.count("private func agentAnswered() { guard !fieldComposeOpened else { return }", in: chat) == 1)
        #expect(Self.count("fieldComposeOpened = true", in: chat) == 0)
        #expect(Self.count("prefillTo: to.isEmpty ? nil : to, prefillCc: cc.isEmpty ? nil : cc,", in: chat) == 1)
        #expect(Self.count("if replyTo != nil { replyTarget = .replyAll }", in: chat) == 1, "a sent reply clears it")
        #expect(Self.count("ownAddresses: context.ownAddresses) { replyTarget = $0 }", in: chat) == 1, "Done sets it")
        #expect(Self.count("ChatHeaderView(thread: thread, subject: subject(thread), labels: context.labels) { showsReplyTo = true }", in: chat) == 1)
        #expect(Self.count("Button { forwardMessage = thread.newest }", in: chat) == 1)
        #expect(Self.count(".fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true) }", in: chat) == 1)
        #expect(Self.count(".onChange(of: thread.newest?.stableId) { _, _ in replyTarget = .replyAll }", in: chat) == 1)

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("ChatReplyField.route(text: text, readyText: field.readyText, recipientsChanged: field.onlyTo != nil)", in: island) == 1)
        #expect(Self.count("onlyTo: replyField?.onlyTo)", in: island) == 1)
    }
}
