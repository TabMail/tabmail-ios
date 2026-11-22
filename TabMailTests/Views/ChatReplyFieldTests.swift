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
///     to everyone (`ChatSuggestionBubbleTests` runs the ghost itself).
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
///     whole Reply All audience, compared by address (a mailbox the agent names counts as its
///     address, in any case; an entry that names no address counts as the text written).
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

    private static func phase(_ email: MessageHeader, usersTurn: Bool = false, onlyTo: [ChatThread.Person]? = nil,
                              aiOn: Bool = true, subscribed: Bool = true) -> ChatSuggestionPhase? {
        ChatReplyField.suggestionPhase(newest: email, usersTurn: usersTurn, onlyTo: onlyTo,
                                       aiSourceEnabled: aiOn, subscribed: subscribed)
    }

    @Test("Writing is the inbox row's AI-is-working rule on the newest email: each case")
    func suggestionPhaseWritingRule() {
        // Case 1: tagged with no reply processed.
        var tagged = Self.header("r1")
        tagged.actionTag = .reply
        #expect(Self.phase(tagged) == .writing, "tagged with no reply: Writing")
        // Case 2: untagged in the Inbox with an AI source on.
        let untagged = Self.header("r2")
        #expect(untagged.actionTag == nil && untagged.isInInbox)
        #expect(Self.phase(untagged) == .writing, "untagged in the Inbox with AI on: Writing")
        #expect(Self.phase(untagged, aiOn: false) == nil, "untagged in the Inbox with AI off: nothing")
        var elsewhere = Self.header("r3")
        elsewhere.isInInbox = false
        #expect(Self.phase(elsewhere) == nil, "untagged and not in the Inbox: nothing")
        // Filtered: the empty-reply sentinel makes the reply processed.
        var filtered = Self.header("r4", reply: "")
        filtered.actionTag = ActionTag.none
        #expect(Self.phase(filtered) == nil, "filtered: no reply will come, no Writing")
        // The same predicate the inbox row reads.
        #expect(AIWorkingRule.isWorking(tagged: true, replyProcessed: false, inInbox: false, aiSourceEnabled: false, subscribed: true))
        #expect(AIWorkingRule.isWorking(tagged: false, replyProcessed: false, inInbox: true, aiSourceEnabled: true, subscribed: false))
        #expect(!AIWorkingRule.isWorking(tagged: true, replyProcessed: true, inInbox: true, aiSourceEnabled: true, subscribed: true))
        #expect(!AIWorkingRule.anyAISourceEnabled(demoHidesAI: true, optedOutAllAI: false, deviceSyncAuto: false, subscribed: true))
        #expect(!AIWorkingRule.anyAISourceEnabled(demoHidesAI: false, optedOutAllAI: true, deviceSyncAuto: false, subscribed: true))
        #expect(AIWorkingRule.anyAISourceEnabled(demoHidesAI: false, optedOutAllAI: true, deviceSyncAuto: true, subscribed: true))
        #expect(!AIWorkingRule.anyAISourceEnabled(demoHidesAI: false, optedOutAllAI: false, deviceSyncAuto: false, subscribed: false))
        #expect(AIWorkingRule.anyAISourceEnabled(demoHidesAI: false, optedOutAllAI: false, deviceSyncAuto: false, subscribed: true),
                "the ordinary user: not in a demo, not opted out, Device Sync auto off, subscribed")
    }

    @Test("The inbox row's thread forms: shimmer while any tagged member awaits its reply, spinner while not every Inbox member is tagged")
    func rowThreadFormRules() {
        // Shimmer, thread form: the row passes replyProcessed = !anyMemberStillProcessingReply.
        for (anyMemberStillProcessingReply, expected) in [(true, true), (false, false)] {
            #expect(AIWorkingRule.writesReply(tagged: true, replyProcessed: !anyMemberStillProcessingReply, subscribed: true) == expected,
                    "thread with a member awaiting its reply: \(anyMemberStillProcessingReply)")
        }
        #expect(!AIWorkingRule.writesReply(tagged: false, replyProcessed: false, subscribed: true), "untagged thread: no shimmer")
        #expect(!AIWorkingRule.writesReply(tagged: true, replyProcessed: false, subscribed: false), "not subscribed: no shimmer")
        // Spinner, thread form: the row passes tagged = allMembersTagged.
        for (allMembersTagged, expected) in [(true, false), (false, true)] {
            #expect(AIWorkingRule.classifies(tagged: allMembersTagged, inInbox: true, aiSourceEnabled: true) == expected,
                    "every Inbox member tagged: \(allMembersTagged)")
        }
        #expect(!AIWorkingRule.classifies(tagged: false, inInbox: false, aiSourceEnabled: true), "outside the Inbox: no spinner")
        #expect(!AIWorkingRule.classifies(tagged: false, inInbox: true, aiSourceEnabled: false), "no AI source: no spinner")
        // A demo with AI declined hides every AI source, so a seeded untagged row shows no spinner.
        let demoSource = AIWorkingRule.anyAISourceEnabled(demoHidesAI: true, optedOutAllAI: false, deviceSyncAuto: false, subscribed: true)
        #expect(!AIWorkingRule.classifies(tagged: false, inInbox: true, aiSourceEnabled: demoSource))
    }

    @Test("The inbox row reads the one AI-working rule with the thread-form inputs")
    func rowWorkingRuleWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/MessageRowView.swift")
        #expect(Self.count("AIWorkingRule.anyAISourceEnabled( demoHidesAI: DemoModeStore.shared.hidesAIContent, optedOutAllAI: optOutAllAI, deviceSyncAuto: DeviceSyncService.shared.isAutoEnabled, subscribed: AISubscriptionGate.shared.isActive)", in: text) == 1,
                "the row's AI source is the shared rule, demo included")
        #expect(Self.count("AIWorkingRule.classifies(tagged: effectiveTag != nil, inInbox: message.isInInbox, aiSourceEnabled: anyAISourceEnabled)", in: text) == 1,
                "the single row's spinner")
        #expect(Self.count("let replyProcessed = threadInfo.map { !$0.anyMemberStillProcessingReply } ?? message.isReplyProcessed", in: text) == 1,
                "a thread is processed only when no member still awaits its reply")
        #expect(Self.count("AIWorkingRule.writesReply(tagged: effectiveTag != nil, replyProcessed: replyProcessed, subscribed: AISubscriptionGate.shared.isActive)", in: text) == 1,
                "the shimmer")
        #expect(Self.count("AIWorkingRule.classifies(tagged: threadInfo.allMembersTagged, inInbox: message.isInInbox, aiSourceEnabled: anyAISourceEnabled)", in: text) == 1,
                "the thread spinner")
        #expect(Self.count("AIWorkingRule.", in: text) == 4, "no inline copy of the rule")
    }

    @Test("The AI Suggestion's row is the working bubble while the reply is written, then the ghost")
    func suggestionPhaseWritingThenReady() {
        var email = Self.header("w1")
        email.actionTag = .reply
        #expect(Self.phase(email) == .writing, "tagged with no reply yet: Writing")
        email.cachedReply = "Hi Alex,\n\nTuesday works."
        email.replyTextMessage = "Tuesday works"
        #expect(Self.phase(email) == .ready("Tuesday works"), "the stored reply fills it in")

        // Nothing where the user cannot use a suggestion.
        var writing = Self.header("w4")
        writing.actionTag = .reply
        #expect(Self.phase(writing, usersTurn: true) == nil, "the user's turn")
        #expect(Self.phase(writing, onlyTo: [Self.david]) == nil, "only some people chosen")
        #expect(Self.phase(writing, aiOn: false, subscribed: false) == nil, "no plan")
        var noReply = Self.header("w5", fromAddress: "noreply@example.com")
        noReply.actionTag = .reply
        #expect(Self.phase(noReply) == nil, "a no-reply sender")
    }

    @Test("A new email above a ready ghost puts the row back to Writing, tagged or not yet; only Writing to ready fills in")
    func suggestionPhaseNewEmailResetsToWriting() {
        var first = Self.header("n1", minutesAgo: 5, reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        first.actionTag = .reply
        let shown = Self.phase(first)
        #expect(shown == .ready("Tuesday works"))

        // The usual arrival: staged before it is tagged.
        var second = Self.header("n2", inReplyTo: first.rfc822MessageId)
        let untaggedArrival = Self.phase(second)
        #expect(untaggedArrival == .writing, "an untagged arrival: Writing at once, no blank row")
        #expect(!ChatSuggestionPhase.fills(from: shown, to: untaggedArrival), "back to Writing at once, no fill")

        second.actionTag = .reply
        let afterArrival = Self.phase(second)
        #expect(afterArrival == .writing, "tagged, still writing")
        #expect(!ChatSuggestionPhase.fills(from: untaggedArrival, to: afterArrival), "the tag changes nothing")

        second.cachedReply = "Hi Alex,\n\nSee you then."
        second.replyTextMessage = "See you then"
        let ready = Self.phase(second)
        #expect(ready == .ready("See you then"))
        #expect(ChatSuggestionPhase.fills(from: afterArrival, to: ready), "the working bubble grows into the ghost")

        #expect(!ChatSuggestionPhase.fills(from: nil, to: ready), "a ghost with no working bubble before it shows at once")
        #expect(!ChatSuggestionPhase.fills(from: .ready("Tuesday works"), to: ready), "a rewrite in place")
        #expect(!ChatSuggestionPhase.fills(from: .writing, to: nil), "the row going away")
    }

    @Test("The working bubble's dots pulse between the dim opacity and full")
    func workingDots() {
        let period = ChatSuggestionConfig.dotPulsePeriod
        #expect(abs(ChatSuggestionWorkingBubble.dotOpacity(at: 0) - ChatSuggestionConfig.dotDimOpacity) < 0.0001)
        #expect(abs(ChatSuggestionWorkingBubble.dotOpacity(at: period / 2) - 1) < 0.0001)
        #expect(abs(ChatSuggestionWorkingBubble.dotOpacity(at: -period / 4) - ChatSuggestionWorkingBubble.dotOpacity(at: period * 3 / 4)) < 0.0001,
                "a staggered dot before zero is in range")
        #expect(ChatSuggestionConfig.writingLine == "AI Suggestion · Writing")
        #expect(ChatSuggestionWorkingBubble.bubbleId != ChatSuggestionBubble.bubbleId, "its own identifier")
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
    private static func typed(_ text: String) -> ChatFieldFill.Change { .put(text) }

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
        #expect(Self.count("Binding(get: { inputText }, set: { fieldFill.apply(.put($0)) })", in: text) == 1)
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
        #expect(Self.count("ready.compose.composeView( replyTo: ready.message, suggestedBody: ready.message.cachedReply, draftId: ready.draftId, onAgentOutcome: { _ in })", in: text) == 1,
                "the card holds the tapped row's reply and never completes the field")
        #expect(Self.count("@State private var example = ChatSuggestionConfig.randomExample()", in: text) == 1,
                "one example per chat open, kept across redraws")
        #expect(Self.count("composeEnded(", in: text) == 2, "only agent compose cards end through it")
        // Who the reply goes to and whose turn it is decide whether the suggestion shows.
        #expect(Self.count("let usersTurn = (thread.items.last?.isOwn ?? false) || !unsentReplies.isEmpty", in: text) == 1)
        #expect(Self.count("guard viewModel.hasLoadedThread, context.isLoaded, !chatWorking, context.accounts.contains(where: { $0.id == newest.accountId }) else { return nil }", in: text) == 1,
                "no suggestion before the thread and accounts load, or while the agent works")
        #expect(Self.count("ChatReplyField.suggestionPhase(newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only, aiSourceEnabled: aiSourceEnabled, subscribed: subscribed)", in: text) == 1)
        #expect(Self.count("let aiSourceEnabled = AIWorkingRule.anyAISourceEnabled( demoHidesAI: DemoModeStore.shared.hidesAIContent, optedOutAllAI: optOutAllAI, deviceSyncAuto: DeviceSyncService.shared.isAutoEnabled, subscribed: subscribed)", in: text) == 1,
                "the chat reads the inbox row's AI-source rule")
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

    @Test("The working bubble grows into the ghost with its re-pin in one animation; every other change shows at once")
    func suggestionFillWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count(".onChange(of: suggestion, initial: true) { old, new in showSuggestion(new, from: old, proxy: proxy) }", in: text) == 1)
        let show = try Self.body(of: "private func showSuggestion(_ new: ChatSuggestionPhase?, from old: ChatSuggestionPhase?, proxy: ScrollViewProxy) {", in: text)
        // Only Writing to ready animates; anything else holds the working bubble only while Writing.
        #expect(show.hasPrefix(" guard ChatSuggestionPhase.fills(from: old, to: new) else { suggestionGrowPending = new == .writing ghostFadesIn = false return }"),
                "every other change, opening on a ready suggestion included, shows at once with no working bubble")
        // The grow and its re-pin in one transaction; under Reduce Motion no height animation, a fade.
        #expect(Self.count("ghostFadesIn = reduceMotion", in: show) == 1)
        #expect(Self.count("withAnimation(reduceMotion ? nil : .easeInOut(duration: ChatSuggestionConfig.fillDuration)) { suggestionGrowPending = false if let target = scrollTarget { proxy.scrollTo(target.id, anchor: target.anchor) } }", in: show) == 1)
        #expect(Self.count("suggestionGrowPending = ", in: text) == 3 && Self.count("ghostFadesIn = ", in: text) == 3, "declared, then written only by showSuggestion")
        // The row: the ghost whenever ready and no grow is pending; its fade only on the fill; it
        // leaves with its transaction. The suggestion block is the last row, after the emails.
        #expect(Self.count("if !suggestionGrowPending, case .ready(let text) = suggestion {", in: text) == 1)
        #expect(Self.count(".transition(.asymmetric( insertion: ghostFadesIn ? .opacity.animation(.easeInOut(duration: ChatSuggestionConfig.ghostFadeDuration)) : .opacity, removal: .opacity))", in: text) == 1)
        #expect(Self.count(".animation(.easeInOut(duration: ChatSuggestionConfig.ghostFadeDuration))", in: text) == 1)
        let rows = try #require(text.range(of: "ForEach(thread.items) { item in"))
        let unsent = try #require(text.range(of: "ForEach(unsentReplies) { reply in"))
        let ghost = try #require(text.range(of: "if let newest = thread.newest, let suggestion {"))
        let bottom = try #require(text.range(of: "Color.clear.frame(height: pillHeight + ChatViewLayout.pillGap).id(Self.bottomId)"))
        #expect(rows.upperBound < unsent.lowerBound && unsent.upperBound < ghost.lowerBound && ghost.upperBound < bottom.lowerBound,
                "the AI Suggestion is the last chat row")
    }

    @Test("The ghost is dashed on a faded fill and captioned in one button; the e.g. line hides while dictating; compose's stored edits refresh the chat")
    func suggestionLookWiring() throws {
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        let ghost = try #require(bubble.range(of: "struct ChatSuggestionBubble: View {")
            .flatMap { start in bubble[start.lowerBound...].range(of: "struct ChatSuggestionWorkingBubble").map { String(bubble[start.lowerBound..<$0.lowerBound]) } })
        #expect(Self.count(".stroke(Palette.chatSuggestionStroke, style: StrokeStyle( lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))", in: ghost) == 1, "a dashed outline")
        #expect(Self.count(".fill(Palette.chatSuggestionFill)", in: ghost) == 1, "on a faded fill")
        #expect(Self.count(".foregroundStyle(Palette.chatSuggestionText)", in: ghost) == 1, "dark-blue text")
        #expect(Self.count("Text(ChatSuggestionConfig.statusLine)", in: ghost) == 1, "the caption shows")
        // The caption sits inside the button's label, so it takes the tap too.
        let button = try #require(ghost.range(of: "Button(action: onTap) {"))
        let caption = try #require(ghost.range(of: "Text(ChatSuggestionConfig.statusLine)"))
        let style = try #require(ghost.range(of: ".buttonStyle(.plain)"))
        #expect(button.upperBound <= caption.lowerBound && caption.upperBound <= style.lowerBound)
        #expect(Self.count("if pulses { TutorialPulseRing(", in: ghost) == 1, "the tutorial rings it")
        #expect(ChatViewLayout.suggestionDash.count == 2 && ChatViewLayout.suggestionDash.allSatisfy { $0 > 0 }, "the dash is a dash")
        // The working bubble: the ghost's dashed bubble on its fill, with capped pulsing dots and the Writing line.
        let working = try #require(bubble.range(of: "struct ChatSuggestionWorkingBubble: View {")
            .flatMap { start in bubble[start.lowerBound...].range(of: "struct ChatUnsentReplyBubble").map { String(bubble[start.lowerBound..<$0.lowerBound]) } })
        #expect(Self.count(".stroke(Palette.chatSuggestionStroke, style: StrokeStyle( lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))", in: working) == 1, "the ghost's dashed outline")
        #expect(Self.count(".fill(Palette.chatSuggestionFill)", in: working) == 1, "on the ghost's fill")
        #expect(Self.count("TimelineView(.animation(minimumInterval: ChatSuggestionConfig.dotFrameInterval))", in: working) == 1, "dots capped like the other AI indicators")
        #expect(ChatSuggestionConfig.dotFrameInterval >= 1.0 / 30)
        #expect(Self.count("ForEach(0..<3, id: \\.self)", in: working) == 1, "three dots")
        #expect(Self.count("Text(ChatSuggestionConfig.writingLine)", in: working) == 1 && Self.count(".accessibilityIdentifier(Self.bubbleId)", in: working) == 1)
        #expect(Self.count("Button(", in: working) == 0, "nothing to tap")

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
        // Asked in the chat view, which takes the request (ADR-IOS-053 Phase 2).
        let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
        let invocation = ToolInvocation(fieldReply: fieldReply, composeOrigin: asked)
        let task = Task { @MainActor () -> String in
            try await tool.execute(
                arguments: ["unique_id": .int(1), "body": .string("Friday works")].merging(arguments) { $1 }, invocation: invocation)
        }
        defer { task.cancel() }
        var pending: AgentToolRouter.ComposeRequest?
        let host = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = router.takeCompose(for: host)
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

    /// The agent names a recipient as `{name, email}`, which the reply tool keeps as a mailbox
    /// with its display name (`"Team Lead" <team@example.com>`). Moving an original To recipient
    /// to Cc that way keeps everyone, so the card is still Reply All: the audience is compared by
    /// address, not by the text the agent wrote.
    @Test("A reply the agent moves someone from To to Cc by name is still Reply All, and the card keeps the name and the Cc")
    func agentReplyThatMovesSomeoneToCcByNameIsStillReplyAll() async throws {
        let teamLead: JSONValue = .dictionary(["name": .string("Team Lead"), "email": .string("team@example.com")])
        for origin in [Origin.field(onlyTo: nil), .sheet] {
            let (moved, accounts) = try await Self.agentReplyRequest([
                "remove_recipients": .array([.string("team@example.com")]),
                "add_cc": .array([teamLead]),
            ], from: origin)
            #expect(moved.to == ["sender@example.com"] && moved.bcc.isEmpty, "control: team@example.com left To")
            let named = RecipientEntry(moved.cc).recipients
            let expectedCc = [RecipientEntry.Recipient(address: "team@example.com", name: "Team Lead")]
            #expect(named == expectedCc, "control: the agent's Cc is the named mailbox, not a bare address")
            let compose = Self.card(agent: moved, accounts: accounts)
            #expect(compose.isReplyAll, "everyone in the Reply All audience is on it, one of them by name in Cc: Reply All")
            #expect(compose.prefillTo == ["sender@example.com"], "the card keeps the To the agent chose")
            #expect(compose.prefillCc == moved.cc && compose.prefillBcc == nil, "the card keeps the agent's Cc as written")
            let cardCc = RecipientEntry(compose.prefillCc ?? []).recipients
            #expect(cardCc == expectedCc, "the card's Cc is team@example.com, under its name")
        }

        // The narrowed control: the agent names someone else in Cc and leaves team@example.com out.
        let otherLead: JSONValue = .dictionary(["name": .string("Team Lead"), "email": .string("lead@example.com")])
        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest([
            "remove_recipients": .array([.string("team@example.com")]),
            "add_cc": .array([otherLead]),
        ], from: .field(onlyTo: nil))
        let fewer = Self.card(agent: narrowed, accounts: narrowedAccounts)
        #expect(!fewer.isReplyAll, "someone of the audience left out, another named instead: a plain reply")
        #expect(fewer.prefillTo == ["sender@example.com"] && fewer.prefillCc == narrowed.cc,
                "the card goes to the agent's recipients only")
    }

    /// The audience is compared as compose reads its fields: each mailbox by its address in any
    /// case, wherever the agent puts it (To, Cc or Bcc alone, by name, the same person in both To
    /// and Cc), and an entry that names no sendable address (a Reply-To's
    /// `undisclosed-recipients:;`) as the text written, so a reply that leaves that entry out
    /// leaves part of the audience out. The valid recipients stay the same in the two cases that
    /// differ only in that entry.
    @Test("""
    A reply the agent writes to mixed-case named mailboxes is Reply All exactly when it holds the \
    whole audience, a Reply-To entry with no address included and someone moved to Bcc alone, \
    from the field and the sheet; the card keeps the To, Cc and Bcc as written
    """)
    func agentReplyAudienceIsComparedAsComposeReadsIt() {
        var email = Self.header("n1")
        email.replyTo = "Alex Doe <alex@example.com>, undisclosed-recipients:;"
        email.to = "me@example.com, David Roe <David@Example.com>"
        email.cc = "Sam Poe <sam@example.com>"
        let audience = buildReplyAllRecipients(for: email, allAccounts: [Self.me])
        #expect(audience.to == ["alex@example.com", "undisclosed-recipients:;", "david@example.com"] && audience.cc == ["sam@example.com"],
                "control: the audience is Alex, the entry with no address, David and Sam")

        let alex = "\"Alex Doe\" <Alex@Example.com>"
        let noAddress = "undisclosed-recipients:;"
        let davidTo = "\"David Roe\" <DAVID@example.com>"
        let davidCc = "\"David Roe\" <david@EXAMPLE.com>"
        let sam = "\"Sam Poe\" <Sam@Example.COM>"
        let davidBcc = "\"David Roe\" <David@EXAMPLE.com>"
        let written = RecipientEntry([alex, noAddress, davidTo, sam, davidCc])
        #expect(written.addresses == ["Alex@Example.com", "DAVID@example.com", "Sam@Example.COM"] && written.leftovers == [noAddress],
                "control: the agent's mailboxes keep their mixed case, David counts once, the entry stays as written")

        // Each case: the agent's To, Cc and Bcc, and whether they hold the whole audience. The first
        // two differ only in the entry with no address; Alex is in To alone. In the last, the agent
        // moved David from To to Bcc and nowhere else: he still gets the reply, so it is Reply All.
        let cases: [(name: String, to: [String], cc: [String], bcc: [String], whole: Bool)] = [
            ("everyone, David in To and in Cc", [alex, noAddress, davidTo], [sam, davidCc], [], true),
            ("the entry with no address left out", [alex, davidTo], [sam, davidCc], [], false),
            ("David left out", [alex, noAddress], [sam], [], false),
            ("everyone, David moved to Bcc alone", [alex, noAddress], [sam], [davidBcc], true),
        ]
        for origin in [Origin.field(onlyTo: nil), .sheet] {
            var fieldReply: ChatFieldReply?
            if case .field(let onlyTo) = origin { fieldReply = ChatFieldReply(emailKey: ChatThread.copyKey(email), onlyTo: onlyTo) }
            for item in cases {
                // As the AI reply tool builds it: a reply from the Reply All set, as the agent edited it.
                let request = AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: email, to: item.to, cc: item.cc, bcc: item.bcc,
                    subject: "Re: Plans", body: "Friday works", origin: ComposeOrigin(sessionKey: "chat", screen: .chat),
                    isReplyAll: true, fieldReply: fieldReply)
                let compose = Self.card(agent: request, accounts: [Self.me])
                let expectedBcc: [String]? = item.bcc.isEmpty ? nil : item.bcc
                #expect(compose.isReplyAll == item.whole, "\(origin), \(item.name): Reply All is \(item.whole)")
                #expect(compose.prefillTo == item.to && compose.prefillCc == item.cc && compose.prefillBcc == expectedBcc,
                        "\(origin), \(item.name): the card keeps the agent's To, Cc and Bcc as written")
            }
        }
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
        #expect(Self.count("ChatSubjectLine(subject: subject(thread), labels: context.labels, landed: didInitialScroll, reportContent: { AISummariesNotice.reportContent(items: thread.items, unsent: unsentReplies) })", in: chat) == 1)
        // The subject and the coach card are the chat's top bar, so the scroll edge reaches under
        // them; a plain inset has no backdrop and lets the bubbles draw through the subject. The
        // bar's stack may carry modifiers after it (the swipes measure where the header ends).
        #expect(Self.count(".safeAreaBar(edge: .top, spacing: 0) { VStack(spacing: 0) { ChatSubjectLine(subject: subject(thread), labels: context.labels, landed: didInitialScroll, reportContent: { AISummariesNotice.reportContent(items: thread.items, unsent: unsentReplies) }) tutorialCard(thread) }", in: chat) == 1,
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
        #expect(Self.count("onlyTo: replyTarget.only, tutorialMove: tutorialMove(thread))", in: chat) == 1, "the field knows the people chosen")
        // Both reply cards open through the one helper, read as the card opens: Reply All exactly
        // when the reply goes to everyone, and the recipients with it.
        #expect(Self.count("agentCompose = ChatAgentCard(request: req, reply: ChatReplyCompose.make(agent: req, accounts: context.accounts))", in: chat) == 1,
                "the agent's card is read from its request alone (who it goes to is the request's: ChatReplyComposeOriginTests)")
        #expect(Self.count("case .reply: card.reply.composeView( replyTo: req.replyTo, suggestedBody: req.body, draftId: card.draftId, onAgentOutcome: onOutcome)", in: chat) == 1,
                "the agent's reply card opens in the helper's kind, under the card's own draft (ChatComposeRoutingTests)")
        #expect(Self.count("ChatReplyCompose.make(", in: chat) == 2, "the AI Suggestion and the agent's reply")
        #expect(Self.count("isReplyAll", in: chat) == 0 && Self.count("buildReplyAllRecipients", in: chat) == 1,
                "no card decides the kind or the Reply All recipients itself; the one call left is the header's people")
        // A card from a field request: the agent's closing words open nothing; a field send starts afresh.
        #expect(Self.count("fieldComposeOpened = req.fieldReply != nil", in: chat) == 1)
        #expect(Self.count("onFieldSend: { _ in fieldComposeOpened = false }, onAgentCompose: openAgentCompose, composeFromAccountId: viewModel.message?.accountId, composeHostCovered: isAnyPresentation)", in: chat) == 1,
                "the chat's pill binds the email's account as a new message's From and takes nothing while the chat is covered")
        // A new message's card opens from the account bound when the turn started.
        #expect(Self.count("ComposeView( suggestedBody: req.body, account: navigationStore.accounts.first { $0.id == req.fromAccountId },", in: chat) == 1)
        // The card and fieldComposeOpened are set only for a request this chat's own pill took
        // (ADR-IOS-053 Phase 2; ChatComposeRoutingTests runs it with the inbox and the email screen mounted).
        #expect(Self.count("private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {", in: chat) == 1)
        #expect(Self.count("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } fieldComposeOpened = req.fieldReply != nil agentCompose = ChatAgentCard(", in: chat) == 1,
                "a new email's bound account is looked up as the card is taken, before anything is set")
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
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, fieldReply: fieldReply, composeOrigin: origin)", in: island) == 1,
                "and travel with the request to the agent's tools")
        // With the chat that asked, read as the send starts; the field's request belongs to the chat view.
        #expect(Self.count("let origin = composeOrigin(sessionKey: capturedSessionKey, fieldReply: fieldReply)", in: island) == 1)
        #expect(Self.count("return ComposeOrigin(sessionKey: sessionKey, screen: fieldReply != nil ? .chat : screen, fromAccountId: composeFromAccountId)", in: island) == 1)
        // A covered screen does not take: the pill takes only while its screen shows and nothing covers it.
        #expect(Self.count("let host = (composeHostShown ?? composeHostAppeared) && !composeHostCovered", in: island) == 1)
        // A recovered send keeps them: the resume carries the cut-off send's request, the retry the
        // failed send as it was sent (ChatReplyRecoveryTests sends both through the real chat).
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, fieldReply: fieldReply, origin: origin)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, fieldReply: resume.fieldReply, composeOrigin: origin)", in: island) == 1)
        // A resume continues its turn: the origin the turn started with, from any screen of the thread.
        #expect(Self.count("let origin = resume.origin", in: island) == 1)
        #expect(Self.count("composeOrigin(sessionKey: capturedSessionKey,", in: island) == 1, "only the send reads the pill's origin")
        // No screen takes another screen's compose request: no global slot is left to race for.
        for path in ["TabMail/Views/Chat/ChatThreadView.swift", "TabMail/Views/Inbox/InboxView.swift", "TabMail/Views/Message/MessageDetailView.swift"] {
            let text = try Self.source(path)
            #expect(Self.count("pendingCompose", in: text) == 0, "\(path) takes compose requests only through its pill")
        }
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        let detail = try Self.source("TabMail/Views/Message/MessageDetailView.swift")
        #expect(Self.count("onAgentCompose: { agentCompose = $0 }, composeHostCovered: isAnyPresentation, composeHostShown: composeHostShown)", in: inbox) == 1,
                "the inbox says from its navigation whether it shows, and passes its own sheets, covers and alert")
        #expect(Self.count("private var composeHostShown: Bool { emailsOpenBeside || (selectedMessageId == nil && pushedMessageId == nil) }", in: inbox) == 1)
        // Whether an opened email shows beside the inbox comes from the split view's own width, read
        // outside its columns, and reaches the inbox through the content column.
        let navigation = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("@Environment(\\.horizontalSizeClass) private var sizeClass", in: navigation) == 1, "the split view's horizontal width")
        #expect(Self.count("emailsOpenBeside: sizeClass == .regular)", in: navigation) == 1, "the expanded split view opens an email beside the inbox")
        #expect(Self.count("emailsOpenBeside: emailsOpenBeside)", in: navigation) == 2, "through the content column to the inbox")
        #expect(Self.count("showSearch || labelMenuMessage != nil || showLabelFilterPicker || moveMessageId != nil || moveThreadGroup != nil || replyMessage != nil || draftOpen != nil || agentCompose != nil || contactComposeRequest != nil || viewModel.showCompose || showUndoAlert }", in: inbox) == 1,
                "every sheet, cover and alert of the inbox holds a compose card")
        #expect(Self.count("showCompose || contactComposeRequest != nil || replyMessage != nil || replyAllMessage != nil || forwardMessage != nil || agentCompose != nil || moveMessage != nil || labelMenuMessage != nil }", in: detail) == 1,
                "every sheet and cover of the email screen holds a compose card")
        #expect(Self.count("onAgentCompose: openAgentCompose, composeFromAccountId: message.accountId, composeHostCovered: isAnyCoverPresented)", in: detail) == 1)
        let detailActions = try Self.source("TabMail/Views/Message/MessageDetailView+Actions.swift")
        #expect(Self.count("account: fromAccount(of: req),", in: detailActions) == 1, "the email screen's new message opens from its bound account")
        #expect(Self.count("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } agentCompose = req", in: detailActions) == 1)
        #expect(Self.count("navigationStore.accounts.first { $0.id == req.fromAccountId }", in: detailActions) == 1)
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, fieldReply: resume.fieldReply, origin: resume.origin)", in: island) == 1)
        #expect(Self.count("lastFailedSend = .init(text: text, field: field)", in: island) == 1)
        #expect(Self.count("sendAgentChat(failed.text, field: failed.field)", in: island) == 1)
        // Re-send of the last turn sends it as it was sent: the bubble keeps the field's send and
        // the menu passes it on (ChatComposeRoutingTests checks the bubble keeps it).
        #expect(Self.count("chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date(), fieldSend: field))", in: island) == 1)
        #expect(Self.count("resendLastUserMessage(text: msg.content, field: msg.fieldSend, afterIndex: index)", in: island) == 1)
        // Rewind trims the later turns and sends the chosen turn again as a fresh turn, which names
        // the screen that asked (an earlier field turn's recipients choice is not kept with it).
        #expect(Self.count("rewindToMessage(text: msg.content, atIndex: index)", in: island) >= 1, "the menu's Rewind reaches the rewind")
        #expect(Self.count("private func rewindToMessage(text: String, atIndex index: Int) { trimForRewind(atIndex: index) lastFailedSend = nil sendAgentChat(text) }", in: island) == 1,
                "Rewind sends the turn again through the send that names the screen")
        #expect(Self.count("trimForResendLast(atIndex: index) lastFailedSend = nil sendAgentChat(text, field: field)", in: island) == 1)
        #expect(Self.count("replyField?.onlyTo", in: island) == 0 && Self.count("replyField?.isNoReply", in: island) == 0,
                "no send reads the field's choice later")
    }

    /// ADR-IOS-053 Phase 2: the census of the turns that can reach a compose tool. Every invocation
    /// the app builds is one of three: the pill's send and its resume, which name the screen that
    /// asked (every send, retry, resend, rewind and tutorial prompt goes through `sendAgentChat`),
    /// and the compose editor's chat, whose host is a compose window and opens no agent card, so a
    /// compose tool there fails fast. Every other caller (reply precompute, inline edit, the BYOK
    /// check) runs `.noninteractive`, where a compose tool fails fast too. A new turn that builds
    /// its own invocation fails here until it names its screen or is added with its reason.
    @Test("Every agent turn that could open a compose card names the screen that asked")
    func everyTurnNamesItsScreen() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try #require(FileManager.default.enumerator(at: projectRoot.appendingPathComponent("TabMail"), includingPropertiesForKeys: nil))
        var built: [String: Int] = [:]
        for case let url as URL in sources where url.pathExtension == "swift" && url.lastPathComponent != "ToolInvocation.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = Self.count("ToolInvocation(", in: text)
            if count > 0 { built[url.lastPathComponent] = count }
        }
        #expect(built == ["DynamicIslandChatButton.swift": 3], "only the pill builds invocations: \(built)")

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("composeOrigin: origin)", in: island) == 2, "the send and the resume name the screen that asked")
        #expect(Self.count("invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey) )", in: island) == 1,
                "the compose editor's chat, which opens no card, names none")
        #expect(Self.count("guard onAgentCompose != nil, composeContext == nil else { return nil }", in: island) == 1,
                "a compose editor's pill has no compose screen")
        // Every turn of the pill starts in one of the two.
        // A fresh send names its screen; a resume reuses the origin its turn started with.
        #expect(Self.count("let origin = composeOrigin(", in: island) == 1)
        #expect(Self.count("let origin = resume.origin", in: island) == 1)
        #expect(Self.count("activeChatTask = Task {", in: island) == Self.count("let origin = composeOrigin(", in: island) + Self.count("let origin = resume.origin", in: island) + 1,
                "one turn task per send and per resume, and the compose editor's")
    }
}
