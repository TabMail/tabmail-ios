/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// ADR-IOS-114: the chat's reply field.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The AI Suggestion (the ghost bubble) shows the ready reply's text message only for someone
///     else's email that has a full reply, from an address that takes replies, while the reply goes
///     to everyone (`ChatThreadViewSuggestionTests` runs the ghost itself).
///  2. The field holds only the user's words, and Send sends them to the agent on the newest
///     email; under the empty field the "e.g." line shows a change from the config set.
///  3. Words for the agent name the newest email and say they came from its reply field; for a
///     no-reply sender they say not to write a reply.
///  4. While the agent writes a reply the line above the field says so.
///  5. Only a sent compose card empties the field, and the field never starts dictation by itself
///     (the Sending bubble is read from the outbox: `ChatSendingBubbleTests`).
///  6. With recipients changed (Reply to), no AI Suggestion shows (it was written for everyone),
///     and the agent's message names the people chosen; everyone ticked is Reply All.
///  6b. A reply opened from the chat records Reply All on the original (`ComposeView.isReplyAll`)
///     exactly when it goes to the chat's whole audience: the AI Suggestion and a reply asked for
///     in the field are Reply All to everyone and a plain reply to the people chosen; a reply the
///     agent writes in the open sheet keeps its recipients and is Reply All only when they are the
///     whole Reply All audience.
///  7. VoiceOver reads who an email went to when it was not everyone.
///  8. The field shows the user's words and nothing else, collapsed or in the open sheet: words
///     typed or said are never replaced, and a completion empties only the words that were sent.
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

    // MARK: - 1. The AI Suggestion

    @Test("The AI Suggestion shows the reply's text message only for someone else's email with a full reply, to everyone")
    func suggestionText() {
        let ready = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.suggestionText(newest: ready, usersTurn: false, onlyTo: nil) == "Tuesday works")
        #expect(ChatReplyField.suggestionText(newest: ready, usersTurn: true, onlyTo: nil) == nil, "the user's turn")
        #expect(ChatReplyField.suggestionText(newest: ready, usersTurn: false, onlyTo: [Self.david]) == nil,
                "written for everyone, so none while the reply goes only to some")

        let noReply = Self.header("2", fromAddress: "noreply@example.com", reply: "Hi", replyText: "Hi")
        #expect(ChatReplyField.suggestionText(newest: noReply, usersTurn: false, onlyTo: nil) == nil, "a no-reply sender")

        let noFullReply = Self.header("3", reply: "", replyText: "Tuesday works")
        #expect(ChatReplyField.suggestionText(newest: noFullReply, usersTurn: false, onlyTo: nil) == nil, "no full reply stored")
        let missingReply = Self.header("4", replyText: "Tuesday works")
        #expect(ChatReplyField.suggestionText(newest: missingReply, usersTurn: false, onlyTo: nil) == nil)

        let noText = Self.header("5", reply: "Hi Alex", replyText: "")
        #expect(ChatReplyField.suggestionText(newest: noText, usersTurn: false, onlyTo: nil) == nil, "no text message")
        let missingText = Self.header("6", reply: "Hi Alex")
        #expect(ChatReplyField.suggestionText(newest: missingText, usersTurn: false, onlyTo: nil) == nil)
    }

    @Test("The placeholder offers a reply only when the sender takes replies")
    func placeholder() {
        #expect(ChatReplyField(example: nil, isNoReply: false, clearCount: 0).placeholder == "Reply or ask anything")
        #expect(ChatReplyField(example: nil, isNoReply: true, clearCount: 0).placeholder == "Ask anything")
    }

    // MARK: - 2. The "e.g." line

    @Test("The e.g. example comes from the config's reply set, content changes only")
    func exampleFromConfig() {
        let set = ChatSuggestionConfig.replyExamples
        #expect(!set.isEmpty)
        #expect(Set(set).count == set.count, "no example twice")
        #expect(!set.contains { $0.localizedCaseInsensitiveContains("shorter") }, "no style tweaks")
        for _ in 0..<50 {
            #expect(ChatSuggestionConfig.randomExample().map(set.contains) == true)
        }
        #expect(Set((0..<200).compactMap { _ in ChatSuggestionConfig.randomExample() }).count > 1, "picked at random")
        #expect(ChatSuggestionConfig.randomExample(from: []) == nil)
        #expect(ChatSuggestionConfig.randomExample(from: ["only one"]) == "only one")
        #expect(ChatSuggestionConfig.exampleLine("politely decline") == "e.g. politely decline")
        #expect(ChatSuggestionConfig.statusLine == "AI Suggestion · Tap to use")
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

    // MARK: - 5. Dictation

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

    // MARK: - 6. Changed recipients

    private static let david = ChatThread.Person(address: "david@example.com", name: "David Kim")
    private static let sarah = ChatThread.Person(address: "sarah@example.com", name: "Sarah Chen")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam Lee")

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

    // MARK: - 8. What the field shows

    /// A field after `changes`, in order, all through the one API.
    private static func fill(_ changes: ChatFieldFill.Change...) -> ChatFieldFill {
        var fill = ChatFieldFill()
        for change in changes { fill.apply(change) }
        return fill
    }

    /// The user typed `text` into the field.
    private static func typed(_ text: String) -> ChatFieldFill.Change { .typed(text) }

    @Test("The field holds only the user's words; said words add to them")
    func fieldHoldsTheUsersWords() {
        #expect(ChatFieldFill().words == "", "a new field is empty: no AI text ever enters it")
        #expect(Self.fill(Self.typed("My words")).words == "My words")
        let said = Self.fill(.said("Can we do Monday"))
        #expect(said.words == DictationController.appending("Can we do Monday", to: ""))
        // Said words add to the words as they are when they come back, never to an older copy.
        let more = Self.fill(Self.typed("Hi"), .said("there"))
        #expect(more.words == DictationController.appending("there", to: "Hi"))
        // The "e.g." line's change is put in as the user's words, to send or edit.
        #expect(Self.fill(.put("politely decline")).words == "politely decline")
        #expect(Self.fill(Self.typed("x"), .put("politely decline")).words == "politely decline")
        // A set that leaves the words as they are is no change.
        let same = Self.fill(Self.typed("Hi"), Self.typed("Hi"))
        #expect(same.changes == 1)
    }

    @Test("A completion empties only the words that were sent, or none; newer words stay")
    func completionClearsOnlyTheSentWords() {
        // Nothing sent yet (a reply sent from a bubble's compose card): the words empty.
        #expect(Self.fill(Self.typed("Anything"), .completed).words == "")

        // Sent from the collapsed field, then a newer draft typed in the open sheet.
        var fill = Self.fill(Self.typed("First request"), .sentFromField)
        #expect(fill.atSend == "First request" && fill.words == "First request", "the words wait in the field")
        fill.apply(Self.typed("My newer draft"))
        fill.apply(.completed)
        #expect(fill.words == "My newer draft", "words written after the send are newer")
        #expect(fill.atSend == nil)
        // Once completed, the next completion has no send to protect.
        fill.apply(.completed)
        #expect(fill.words == "")
        // The words sent, still there: the completion empties them.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .completed).words == "")

        // From the open sheet the words go at once; a draft typed next stays through the completion.
        let sheet = Self.fill(Self.typed("Ask"), .sentFromSheet)
        #expect(sheet.words == "" && sheet.atSend == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromSheet, Self.typed("Next draft"), .completed).words == "Next draft")
        // A confirmation card empties the words sent, and the send stays open for its completion.
        let card = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard)
        #expect(card.words == "" && card.atSend == "Ask")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Newer"), .confirmationCard).words == "Newer")
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
        fill.apply(Self.typed("My own words"))
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

    @Test("The input shows the user's words, and every change to them goes through the one API")
    func fieldShownWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("TextField(placeholder, text: typedText,", in: text) == 1)
        #expect(Self.count("Binding(get: { inputText }, set: { fieldFill.apply(.typed($0)) })", in: text) == 1)
        #expect(Self.count("dictation.isActive || speech.isRecording || speech.isStarting", in: text) == 1)
        // ONE API: the view only reads the words; every change is a `fieldFill.apply`.
        #expect(Self.count("var inputText: String { fieldFill.words }", in: text) == 1)
        #expect(Self.count("var inputText", in: text) == 1)
        #expect(Self.count("fieldFill.", in: text)
                == Self.count("fieldFill.apply(", in: text) + Self.count("fieldFill.words", in: text),
                "nothing else touches the field's state")
        // Each change, where it happens: typing (above), both dictations, both sends, the
        // completion, a confirmation card, and an Edit.
        #expect(Self.count("fieldFill.apply(.startHearing) speech.start(locale: speechLocale, auto: auto) { transcript in fieldFill.apply(.heard(transcript))", in: text) == 1)
        #expect(Self.count("{ text in fieldFill.apply(.said(text))", in: text) == 1)
        #expect(Self.count("fieldSentText = nil // Words written after the send this completes are newer, and stay (`ChatFieldFill`). fieldFill.apply(.completed)", in: text) == 1)
        // A confirmation card raises the sheet and ends the field's pulse over the earlier send
        // (the sheet rising is also run for real: `ChatReplyFieldRuntimeTests.confirmationCardOpensTheSheet`).
        // It watches the thread's whole chat, so a card raised for an earlier email of the thread counts.
        #expect(Self.count(".onChange(of: shownMessages.last?.actionConfirmation != nil) { _, hasCard in guard hasCard, replyField != nil, !isExpanded else { return } fieldFill.apply(.confirmationCard) fieldSentText = nil withAnimation(expandSpring) { isExpanded = true } }", in: text) == 1)
        #expect(Self.count("dictation.inputSent(inputText) // From the open sheet the input empties as it goes; a newer draft is what is typed next. fieldFill.apply(.sentFromSheet)", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.apply(.sentFromField) dictation.inputSent(inputText)", in: text) == 1)
        #expect(Self.count("fieldFill.apply(.put(text)) isTextFieldFocused = true", in: text) == 1)
        // The "e.g." line's change goes in as words and is never sent from here.
        #expect(Self.count("func putExample(_ example: String) { fieldFill.apply(.put(example)) inputSelection = .init(insertionPoint: inputText.endIndex) }", in: text) == 1)
        #expect(Self.count("fieldFill.apply(", in: text) == 10)
    }

    @Test("The field's Send sends the words to the agent; nothing in the field opens compose")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Collapsed, the reply field's Send takes the field's route; the open sheet keeps the chat's.
        let message = try Self.body(of: "private func sendMessage() {", in: text)
        // Send refuses only an empty input, and the collapsed field then takes its own route.
        #expect(message.hasPrefix(" let text = inputText.trimmingCharacters(in: .whitespaces) guard !text.isEmpty else { return } if let replyField, !isExpanded { sendFromReplyField(text, replyField) return }"))
        let send = try Self.body(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {", in: text)
        #expect(Self.count("return", in: send) == 0, "every send from the field goes to the agent")
        #expect(Self.count("onSendReadyReply", in: text) == 0 && Self.count("ChatReplyField.route", in: text) == 0)
        #expect(Self.count("onFieldSend?(text)", in: send) == 1)
        #expect(Self.count("sendAgentChat(text, field: send)", in: send) == 1)
        #expect(Self.count("sendFromReplyField(", in: text) == 2, "Send reaches it")
        #expect(Self.count("enrichedText = ChatReplyField.agentMessage( emailNumericId: numericId, text: text, isNoReply: field.isNoReply, onlyTo: field.onlyTo)", in: text) == 1)
        #expect(Self.count("enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)", in: text) == 1)
    }

    @Test("The chat opens compose for the AI Suggestion, empties the field after a send, and shows the outbox's unsent replies")
    func chatWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("readyReply = ChatReadyReply(message: newest, compose: ChatReplyCompose.make( replyAllTo: newest, accounts: context.accounts))", in: text) == 1)
        #expect(Self.count("onAgentOutcome: onOutcome)", in: text) == 3, "every agent compose")
        #expect(Self.count("onAgentOutcome:", in: text) == 4)
        #expect(Self.count("composeEnded(.", in: text) == 0 && Self.count("{ _ in composeEnded", in: text) == 0)
        // The AI Suggestion's card is not a send from the field: its outcome leaves the field's
        // words alone (a completion with no field send would empty them).
        #expect(Self.count("ready.compose.composeView( replyTo: ready.message, suggestedBody: ready.message.cachedReply, onAgentOutcome: { _ in })", in: text) == 1,
                "the card holds the tapped row's reply and never completes the field")
        #expect(Self.count("@State private var example = ChatSuggestionConfig.randomExample()", in: text) == 1,
                "one example per chat open, kept across redraws")
        #expect(Self.count("composeEnded(", in: text) == 2, "only agent compose cards end through it")
        // Who the reply goes to and whose turn it is decide whether the suggestion shows.
        #expect(Self.count("let usersTurn = (thread.items.last?.isOwn ?? false) || !unsentReplies.isEmpty", in: text) == 1)
        #expect(Self.count("ChatReplyField.suggestionText(newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only)", in: text) == 1)
        #expect(Self.count("req.onOutcome(outcome) composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)", in: text) == 1,
                "an agent compose hands on its outcome")
        let ended = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {", in: text)
        #expect(Self.count("guard case .sent = outcome else { return }", in: ended) == 1)
        #expect(Self.count("fieldClearCount += 1", in: ended) == 1, "only after a send")
        // The bubbles are the database's: one observation keyed by the chat's Message-IDs.
        #expect(Self.count("for try await found in ChatUnsentReply.changes(answering: messageIds) {", in: text) == 1)
        // A reply filed or gone reloads the chat's emails, so a sent reply's copy takes its place.
        #expect(Self.count("unsentReplies = found if left || found.contains(where: \\.filed) { viewModel.reloadThread() }", in: text) == 1)
        #expect(Self.count("unsentReplies = ", in: text) == 1, "nothing else writes them")
        #expect(Self.count("ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() })", in: text) == 1,
                "a failed send's Retry and Delete act on its own row")
    }

    @Test("The ghost is dashed and captioned in one button; the e.g. line hides while dictating; compose's stored edits refresh the chat")
    func suggestionLookWiring() throws {
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        let ghost = try #require(bubble.range(of: "struct ChatSuggestionBubble: View {")
            .flatMap { start in bubble[start.lowerBound...].range(of: "struct ChatUnsentReplyBubble").map { String(bubble[start.lowerBound..<$0.lowerBound]) } })
        #expect(Self.count("lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))", in: ghost) == 1, "a dashed outline")
        #expect(Self.count(".background(", in: ghost) == 0 && Self.count(".fill(", in: ghost) == 0, "on a clear bubble")
        #expect(Self.count("Text(ChatSuggestionConfig.statusLine)", in: ghost) == 1, "the caption shows")
        // The caption sits inside the button's label, so it takes the tap too.
        let button = try #require(ghost.range(of: "Button(action: onTap) {"))
        let caption = try #require(ghost.range(of: "Text(ChatSuggestionConfig.statusLine)"))
        let style = try #require(ghost.range(of: ".buttonStyle(.plain)"))
        #expect(button.upperBound <= caption.lowerBound && caption.upperBound <= style.lowerBound)
        #expect(Self.count("if pulses { TutorialPulseRing(", in: ghost) == 1, "the tutorial rings it")
        #expect(ChatViewLayout.suggestionDash.count == 2 && ChatViewLayout.suggestionDash.allSatisfy { $0 > 0 }, "the dash is a dash")

        let field = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        #expect(Self.count("hasTabMailSession && inputText.isEmpty && !isDictating", in: field) == 1,
                "the e.g. line shows only on an empty, signed-in field, never while dictating")

        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        #expect(Self.count("if outcome == .written { await postMessageDataDidChange(reply.id) }", in: compose) == 2,
                "both the edit and the Recompute writer refresh an open chat after a stored write")
    }

    // MARK: - 6b. Reply All is recorded exactly when the reply goes to the chat's whole audience

    /// The user's own account.
    private static let me = Account(emailAddress: "me@example.com", displayName: "Me", provider: .gmail)

    /// The newest email: from Alex to the user and David, Cc Sam.
    private static func groupEmail() -> MessageHeader {
        var email = Self.header("g1", reply: "Hi all,\n\nTuesday works.", replyText: "Tuesday works")
        email.to = "me@example.com, david@example.com"
        email.cc = "sam@example.com"
        return email
    }

    /// The people of `groupEmail()`, as Reply to lists them.
    private static let groupPeople = [
        ChatThread.Person(address: "alex@example.com", name: "Alex Doe"), david, sam,
    ]

    /// The compose card the chat opens for the AI Suggestion, as the chat's cover builds it.
    private static func card(_ message: MessageHeader, accounts: [Account] = [me]) -> ComposeView {
        ChatReplyCompose.make(replyAllTo: message, accounts: accounts)
            .composeView(replyTo: message, onAgentOutcome: { _ in })
    }

    /// The compose card the chat opens for the agent's reply, as the chat's cover builds it.
    private static func card(agent request: AgentToolRouter.ComposeRequest, accounts: [Account]) -> ComposeView {
        ChatReplyCompose.make(agent: request, accounts: accounts)
            .composeView(replyTo: request.replyTo, suggestedBody: request.body, onAgentOutcome: { _ in })
    }

    /// Where the agent's reply was asked for: the open sheet, or the reply field with who was
    /// chosen in Reply to as it was sent (nil: nobody, Reply All).
    enum Origin {
        case sheet
        case field(onlyTo: [String]?)
    }

    @Test("The AI Suggestion opens compose as Reply All, to the whole group")
    func readyReplyToEveryoneIsReplyAll() {
        let email = Self.groupEmail()
        let compose = Self.card(email)
        #expect(compose.isReplyAll, "the send records a Reply All on the original")
        #expect(compose.prefillTo == ["alex@example.com", "david@example.com"] && compose.prefillCc == ["sam@example.com"])
        #expect(compose.prefillBcc == nil && compose.replyTo?.id == email.id && !compose.isForward)
    }

    /// The reply request the AI reply tool opens for `arguments`, on an email from
    /// sender@example.com to the user (test@example.com) and team@example.com.
    private static func agentReplyRequest(
        _ arguments: [String: JSONValue], from origin: Origin
    ) async throws -> (request: AgentToolRouter.ComposeRequest, accounts: [Account]) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        let account = try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "r1", subject: "Plans", to: "test@example.com, team@example.com")
        await translator.seed(header.id, as: 1)
        let tool = EmailReplyTool(context: ToolContext(db: db, translator: translator, router: router))
        var fieldReply: ChatFieldReply?
        if case .field(let onlyTo) = origin { fieldReply = ChatFieldReply(emailKey: ChatThread.copyKey(header), onlyTo: onlyTo) }
        let invocation = ToolInvocation(fieldReply: fieldReply)
        let task = Task { @MainActor () -> String in
            try await tool.execute(
                arguments: ["unique_id": .int(1), "body": .string("Friday works")].merging(arguments) { $1 }, invocation: invocation)
        }
        defer { task.cancel() }
        var pending: AgentToolRouter.ComposeRequest?
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = router.pendingCompose
            await Task.yield()
        }
        let req = try #require(pending, "the tool opens a reply")
        req.onOutcome(.cancelled)
        _ = try await task.value
        return (req, [account])
    }

    @Test("A reply the agent writes from the field follows the same rule: Reply All to everyone, a plain reply to the people chosen as it was sent")
    func agentReplyFromTheFieldFollowsTheTarget() async throws {
        let widening: [String: JSONValue] = [
            "add_cc": .array([.string("extra@example.com")]),
            "add_bcc": .array([.string("hidden@example.com")]),
        ]
        let (chosen, chosenAccounts) = try await Self.agentReplyRequest(widening, from: .field(onlyTo: [Self.david.address]))
        #expect(chosen.mode == .reply && chosen.bcc == ["hidden@example.com"] && chosen.cc.contains("extra@example.com"))
        let toChosen = Self.card(agent: chosen, accounts: chosenAccounts)
        #expect(!toChosen.isReplyAll, "Replying only to David is a plain reply")
        #expect(toChosen.prefillTo == [Self.david.address] && toChosen.prefillCc == nil && toChosen.prefillBcc == nil,
                "Replying only to David: nobody else, seen or hidden")

        let (req, accounts) = try await Self.agentReplyRequest(widening, from: .field(onlyTo: nil))
        let toEveryone = Self.card(agent: req, accounts: accounts)
        #expect(toEveryone.isReplyAll, "nobody chosen, the agent added people but kept everyone: Reply All")
        #expect(toEveryone.prefillTo == req.to && toEveryone.prefillCc == req.cc && toEveryone.prefillBcc == req.bcc,
                "nobody chosen: the card keeps the agent's recipients")
    }

    @Test("A reply the agent writes from the field with nobody chosen is Reply All only when it goes to the whole audience")
    func agentReplyFromTheFieldIsReplyAllOnlyToTheWholeAudience() async throws {
        let (everyone, accounts) = try await Self.agentReplyRequest([:], from: .field(onlyTo: nil))
        let whole = Self.card(agent: everyone, accounts: accounts)
        #expect(whole.isReplyAll, "the agent's reply goes to the whole audience: Reply All")
        #expect(whole.prefillTo == everyone.to && whole.prefillCc == (everyone.cc.isEmpty ? nil : everyone.cc))

        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest(
            ["remove_recipients": .array([.string("team@example.com")])], from: .field(onlyTo: nil))
        #expect(narrowed.to == ["sender@example.com"] && narrowed.cc.isEmpty && narrowed.bcc.isEmpty,
                "the agent itself left team@example.com out")
        let fewer = Self.card(agent: narrowed, accounts: narrowedAccounts)
        #expect(!fewer.isReplyAll, "someone left out by the agent: a plain reply, never recorded as Reply All")
        #expect(fewer.prefillTo == ["sender@example.com"] && fewer.prefillCc == nil && fewer.prefillBcc == nil,
                "the card goes to the agent's recipients only")
    }

    @Test("A reply the agent widens is still Reply All: its recipients contain the whole audience, from the field and the sheet")
    func agentReplyThatAddsPeopleIsStillReplyAll() async throws {
        for origin in [Origin.field(onlyTo: nil), .sheet] {
            let (widened, accounts) = try await Self.agentReplyRequest([
                "add_cc": .array([.string("extra@example.com")]),
                "add_bcc": .array([.string("hidden@example.com")]),
            ], from: origin)
            #expect(widened.to.contains("sender@example.com") && widened.cc.contains("extra@example.com") && widened.bcc == ["hidden@example.com"],
                    "the agent added a Cc and a Bcc and kept everyone")
            let compose = Self.card(agent: widened, accounts: accounts)
            #expect(compose.isReplyAll, "everyone in the Reply All audience is on it, plus people the agent added: Reply All")
            #expect(compose.prefillTo == widened.to && compose.prefillCc == widened.cc && compose.prefillBcc == widened.bcc,
                    "the card keeps the agent's recipients")
        }

        let (widenedNarrowed, otherAccounts) = try await Self.agentReplyRequest([
            "add_cc": .array([.string("extra@example.com")]),
            "remove_recipients": .array([.string("team@example.com")]),
        ], from: .field(onlyTo: nil))
        let swapped = Self.card(agent: widenedNarrowed, accounts: otherAccounts)
        #expect(!swapped.isReplyAll, "someone added but someone dropped: a plain reply")
    }

    @Test("A reply the agent writes in the open sheet keeps its recipients, and is Reply All only to the whole audience")
    func agentReplyFromTheSheetKeepsItsRecipients() async throws {
        let (everyone, accounts) = try await Self.agentReplyRequest([:], from: .sheet)
        #expect(everyone.fieldReply == nil, "control: asked for in the sheet, the request carries no field choice")
        let all = Self.card(agent: everyone, accounts: accounts)
        #expect(all.isReplyAll, "the agent's reply goes to the whole audience")
        #expect(all.prefillTo == everyone.to && all.prefillCc == (everyone.cc.isEmpty ? nil : everyone.cc))

        let (widened, widenedAccounts) = try await Self.agentReplyRequest(["add_cc": .array([.string("extra@example.com")])], from: .sheet)
        let compose = Self.card(agent: widened, accounts: widenedAccounts)
        #expect(compose.isReplyAll, "someone added, everyone kept: Reply All")
        #expect(compose.prefillTo == widened.to && compose.prefillCc == widened.cc, "the open chat keeps everyone the agent chose")

        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest(
            ["remove_recipients": .array([.string("team@example.com")])], from: .sheet)
        let fewer = Self.card(agent: narrowed, accounts: narrowedAccounts)
        #expect(!fewer.isReplyAll, "someone left out: a plain reply")
        #expect(fewer.prefillTo == ["sender@example.com"])
    }

    @Test("The chat sits like Messages: header in the navigation bar, field just above the safe area")
    func messagesLayout() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The safe area already clears the home indicator: the field adds only its small gap,
        // collapsed or opened, and a side inset from the layout config.
        #expect(Self.count(".padding(.bottom, ChatViewLayout.fieldBottomGap)", in: chat) == 1)
        #expect(Self.count(".padding(.horizontal, chatExpanded ? 0 : ChatViewLayout.fieldSideInset)", in: chat) == 1)
        #expect(Self.count(": 34", in: chat) == 0 && Self.count("? 8 :", in: chat) == 0, "no literal insets")
        #expect(ChatViewLayout.fieldBottomGap == 8 && ChatViewLayout.fieldSideInset == 16)
        // The people are in the bar's principal slot, level with Back; under the bar only the
        // subject line, with no band of its own.
        #expect(Self.count("ToolbarItem(placement: .principal) {", in: chat) == 1)
        #expect(Self.count("ChatSubjectLine(subject: subject(thread), labels: context.labels)", in: chat) == 1)
        // The subject and the coach card are the chat's top bar, so the scroll edge reaches under
        // them; a plain inset has no backdrop and lets the bubbles draw through the subject.
        #expect(Self.count(".safeAreaBar(edge: .top, spacing: 0) { VStack(spacing: 0) { ChatSubjectLine(subject: subject(thread), labels: context.labels) tutorialCard(thread) } }", in: chat) == 1,
                "the subject and the coach card form the chat's top bar")
        #expect(Self.count(".safeAreaInset(edge: .top", in: chat) == 0, "no plain top inset: it has no scroll-edge backdrop")
        let header = try Self.source("TabMail/Views/Chat/ChatHeaderView.swift")
        #expect(Self.count(".background(.bar)", in: header) == 0)
        #expect(Self.count("Text(subject)", in: header) == 1, "the subject only in the thin line")
        // The bar holds who the chat is with: the chat never hides it, not even while the opened
        // pill has focus. The inbox and the email screen keep their rule.
        let hide = ".toolbarVisibility(chatExpanded && chatInputFocused ? .hidden : .automatic, for: .navigationBar)"
        #expect(Self.count(".toolbarVisibility(", in: chat) == 0)
        #expect(Self.count(hide, in: try Self.source("TabMail/Views/Inbox/InboxView.swift")) == 1)
        #expect(Self.count(hide, in: try Self.source("TabMail/Views/Message/MessageDetailView.swift")) == 1)
    }

    @Test("Reply to, Forward and the chosen people reach the field and the compose card")
    func recipientsWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("onlyTo: replyTarget.only,", in: chat) == 1, "the field knows the people chosen")
        // Both reply cards open through the one helper, read as the card opens: Reply All exactly
        // when the reply goes to everyone, and the recipients with it.
        #expect(Self.count("agentCompose = ChatAgentCard(request: req, reply: ChatReplyCompose.make(agent: req, accounts: context.accounts))", in: chat) == 1,
                "the agent's card is read from its request alone (who it goes to is the request's: ChatReplyComposeOriginTests)")
        #expect(Self.count("case .reply: card.reply.composeView(replyTo: req.replyTo, suggestedBody: req.body, onAgentOutcome: onOutcome)", in: chat) == 1,
                "the agent's reply card opens in the helper's kind")
        #expect(Self.count("ChatReplyCompose.make(", in: chat) == 2, "the AI Suggestion and the agent's reply")
        #expect(Self.count("isReplyAll", in: chat) == 0 && Self.count("buildReplyAllRecipients", in: chat) == 1,
                "no card decides the kind or the Reply All recipients itself; the one call left is the header's people")
        // A card from a field request: the agent's closing words open nothing; a field send starts afresh.
        #expect(Self.count("fieldComposeOpened = req.fieldReply != nil", in: chat) == 1)
        #expect(Self.count("onFieldSend: { _ in fieldComposeOpened = false })", in: chat) == 1)
        #expect(Self.count("private func agentAnswered() { guard !fieldComposeOpened else { return }", in: chat) == 1)
        #expect(Self.count("fieldComposeOpened = true", in: chat) == 0)
        #expect(Self.count("if replyTo != nil { replyTarget = .replyAll }", in: chat) == 1, "a sent reply clears it")
        #expect(Self.count("ownAddresses: context.ownAddresses) { replyTarget = $0 }", in: chat) == 1, "Done sets it")
        #expect(Self.count("ChatHeaderView(thread: thread) { guard TutorialCoordinator.shared.admits(.other) else { return } showsReplyTo = true }", in: chat) == 1)
        #expect(Self.count("Button { guard TutorialCoordinator.shared.admits(.other) else { return } forwardMessage = thread.newest }", in: chat) == 1)
        #expect(Self.count(".fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true) }", in: chat) == 1)
        #expect(Self.count(".onChange(of: thread.newest.map(ChatThread.copyKey)) { _, _ in replyTarget = .replyAll }", in: chat) == 1,
                "a new newest email resets the choice, even one whose UID matches the last")

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply) }", in: island) == 1,
                "the people chosen are read once, as the field's send starts")
        #expect(Self.count("let fieldReply = field?.fieldReply", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, fieldReply: fieldReply)", in: island) == 1,
                "and travel with the request to the agent's tools")
        // A recovered send keeps them: the resume carries the cut-off send's request, the retry the
        // failed send as it was sent (ChatReplyRecoveryTests sends both through the real chat).
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, fieldReply: fieldReply)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, fieldReply: resume.fieldReply)", in: island) == 1)
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, fieldReply: resume.fieldReply)", in: island) == 1)
        #expect(Self.count("lastFailedSend = .init(text: text, field: field)", in: island) == 1)
        #expect(Self.count("sendAgentChat(failed.text, field: failed.field)", in: island) == 1)
        #expect(Self.count("replyField?.onlyTo", in: island) == 0 && Self.count("replyField?.isNoReply", in: island) == 0,
                "no send reads the field's choice later")
    }
}
