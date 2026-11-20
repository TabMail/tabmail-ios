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

    @Test("The e.g. line offers the suggestion's change command while it shows, else the configured example",
          arguments: [
            (true, "ask for Friday" as String?, "ask for Friday" as String?),
            (true, nil, "politely decline"),
            (true, "   ", "politely decline"),
            (false, "ask for Friday", "politely decline"),
            (false, nil, "politely decline"),
          ])
    func exampleLine(_ shows: Bool, _ command: String?, _ expected: String?) {
        let shown = shows ? ReplyResult(body: "Hi Alex", textMessage: "Tuesday works", changeCommand: command) : nil
        #expect(ChatReplyField.example(shown: shown, configured: "politely decline") == expected)
    }

    @Test("The AI Suggestion shows the reply's text message only for someone else's email with a full reply, to everyone")
    func suggestionText() {
        let ready = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: ready, usersTurn: false, onlyTo: nil)?.textMessage == "Tuesday works")
        #expect(ChatReplyField.shown(newest: ready, usersTurn: false, onlyTo: nil) == ready.suggestion,
                "the ghost, the e.g. line and the field's edit read one value")
        #expect(ChatReplyField.shown(newest: ready, usersTurn: true, onlyTo: nil)?.textMessage == nil, "the user's turn")
        #expect(ChatReplyField.shown(newest: ready, usersTurn: false, onlyTo: [Self.david])?.textMessage == nil,
                "written for everyone, so none while the reply goes only to some")

        let noReply = Self.header("2", fromAddress: "noreply@example.com", reply: "Hi", replyText: "Hi")
        #expect(ChatReplyField.shown(newest: noReply, usersTurn: false, onlyTo: nil)?.textMessage == nil, "a no-reply sender")

        let noFullReply = Self.header("3", reply: "", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: noFullReply, usersTurn: false, onlyTo: nil)?.textMessage == nil, "no full reply stored")
        let missingReply = Self.header("4", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: missingReply, usersTurn: false, onlyTo: nil)?.textMessage == nil)

        let noText = Self.header("5", reply: "Hi Alex", replyText: "")
        #expect(ChatReplyField.shown(newest: noText, usersTurn: false, onlyTo: nil)?.textMessage == nil, "no text message")
        let missingText = Self.header("6", reply: "Hi Alex")
        #expect(ChatReplyField.shown(newest: missingText, usersTurn: false, onlyTo: nil)?.textMessage == nil)
    }

    /// A late AI Suggestion (ready while the user is busy): hidden while "Writing your email" runs
    /// and while a compose card is open, shown once the card closes without sending, never after a
    /// send (the reply in the outbox makes it the user's turn). Whether it shows takes no input from
    /// the field's words.
    @Test("A late AI Suggestion is hidden while writing")
    func lateSuggestionHiddenWhileWriting() {
        let late = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: true, cardOpen: false) == nil)
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: false, cardOpen: false) == late.suggestion,
                "shown once writing ends with no card open")
    }

    @Test("A late AI Suggestion is hidden while the compose card is open")
    func lateSuggestionHiddenWhileCardOpen() {
        let late = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: false, cardOpen: true) == nil)
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: true, cardOpen: true) == nil)
    }

    @Test("A late AI Suggestion shows after the card closes without sending")
    func lateSuggestionShownAfterCloseWithoutSend() {
        let late = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        // Closed without sending: no reply in the outbox, still the other side's turn.
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: false, cardOpen: false)?.textMessage == "Tuesday works")
    }

    @Test("A late AI Suggestion does not show after the card sends")
    func lateSuggestionNotShownAfterSend() {
        let late = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        // Sent: the reply in the outbox (or its Sent copy as the newest email) is the user's turn.
        #expect(ChatReplyField.shown(newest: late, usersTurn: true, onlyTo: nil, writing: false, cardOpen: false) == nil)
    }

    @Test("A late AI Suggestion shows with no writing and no card open, whatever the field holds")
    func lateSuggestionShownWithNoWritingOrCard() {
        let late = Self.header("1", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(ChatReplyField.shown(newest: late, usersTurn: false, onlyTo: nil, writing: false, cardOpen: false)?.textMessage == "Tuesday works",
                "shown takes no input from the field, so its words cannot hide the ghost")
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
        // A reply stored with no text version shows no ghost, so an untagged Inbox email with
        // one is still case 2: Writing.
        let bodyOnly = Self.header("r5", reply: "Hi Alex,\n\nTuesday works.")
        #expect(bodyOnly.actionTag == nil && bodyOnly.isInInbox)
        let bodyOnlyShown = ChatReplyField.shown(newest: bodyOnly, usersTurn: false, onlyTo: nil)
        #expect(bodyOnlyShown == nil, "control: no text version, no ghost")
        #expect(Self.phase(bodyOnly) == .writing, "untagged in the Inbox with a reply but no ghost: Writing")
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

    @Test("The row's rule is the working bubble while the reply is written, never the ghost")
    func suggestionPhaseWritingNeverReady() {
        var email = Self.header("w1")
        email.actionTag = .reply
        #expect(Self.phase(email) == .writing, "tagged with no reply yet: Writing")
        email.cachedReply = "Hi Alex,\n\nTuesday works."
        email.replyTextMessage = "Tuesday works"
        let stored = ChatReplyField.shown(newest: email, usersTurn: false, onlyTo: nil)?.textMessage
        #expect(stored == "Tuesday works", "control: the stored reply is the ghost the chat shows")
        #expect(Self.phase(email) == nil, "the stored reply ends Writing; the ghost is the chat's own")
        // Untagged in the Inbox with an AI source on stays the inbox row's case 2 with its reply
        // stored; the chat's row still gives no working bubble for it, card open or not.
        let untagged = Self.header("w2", reply: "Hi Alex,\n\nTuesday works.", replyText: "Tuesday works")
        #expect(untagged.actionTag == nil && untagged.isInInbox)
        let untaggedWorking = AIWorkingRule.isWorking(
            tagged: false, replyProcessed: true, inInbox: untagged.isInInbox, aiSourceEnabled: true, subscribed: true)
        #expect(untaggedWorking, "control: the inbox row's rule still counts it as working")
        #expect(Self.phase(untagged) == nil, "an untagged email with its reply stored: no Writing")

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
        #expect(Self.phase(first) == nil, "the row's rule adds no Writing under the ghost")
        let firstText = ChatReplyField.shown(newest: first, usersTurn: false, onlyTo: nil)?.textMessage
        #expect(firstText == "Tuesday works", "control: the first email's ghost shows")
        let shown = ChatSuggestionPhase.ready("Tuesday works")

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
        #expect(Self.phase(second) == nil, "its stored reply ends Writing")
        let secondText = ChatReplyField.shown(newest: second, usersTurn: false, onlyTo: nil)?.textMessage
        #expect(secondText == "See you then", "control: its ghost shows")
        let ready = ChatSuggestionPhase.ready("See you then")
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
        #expect(ChatReplyField(example: nil, isNoReply: false).placeholder == "Reply or ask anything")
        #expect(ChatReplyField(example: nil, isNoReply: true).placeholder == "Ask anything")
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
        // No send open (a reply sent from a bubble's compose card, or nothing sent): no
        // completion, card or answer touches the user's words.
        #expect(Self.fill(Self.typed("Anything"), .completed).words == "Anything")
        #expect(Self.fill(Self.typed("Anything"), .confirmationCard).words == "Anything")
        #expect(Self.fill(Self.typed("Anything"), .answered).words == "Anything")

        // Sent from the collapsed field, then a newer draft typed in the open sheet.
        var fill = Self.fill(Self.typed("First request"), .sentFromField)
        #expect(fill.atSend == "First request" && fill.words == "First request", "the words wait in the field")
        fill.apply(Self.typed("My newer draft"))
        fill.apply(.completed)
        #expect(fill.words == "My newer draft", "words written after the send are newer")
        #expect(fill.atSend == nil)
        // Once completed, the same request's later transitions have no send left to complete:
        // a second compose's Send, a later confirmation card and the closing answer keep the
        // newer draft.
        fill.apply(.completed)
        #expect(fill.words == "My newer draft", "a second compose's Send keeps the newer draft")
        fill.apply(.confirmationCard)
        #expect(fill.words == "My newer draft", "a later confirmation card keeps the newer draft")
        fill.apply(.answered)
        #expect(fill.words == "My newer draft", "the closing answer keeps the newer draft")
        #expect(fill.unsent == "My newer draft", "the newer draft is what is kept")
        // Control: the same sequences with the sent words unchanged empty them once.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .completed, .completed).words == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .completed, .confirmationCard).words == "")
        // The words sent, still there: the completion empties them.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .completed).words == "")
        // A compose card's Send completed the field's send; the request's closing answer after it
        // has nothing left to complete: newer words stay.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, Self.typed("Newer"), .completed, .answered).words == "Newer")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Newer"), .completed, .answered).words == "Newer")
        // An answer to a send still open empties the words sent.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .answered).words == "")
        // A compose card that opened and closed without sending: the closing answer completes
        // nothing; the sent words wait in the field, still the send's (none kept).
        let closed = Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, .answered)
        #expect(closed.words == "Ask" && closed.atSend == "Ask" && closed.unsent == "")

        // From the open sheet the words go at once; a draft typed next stays through the completion.
        let sheet = Self.fill(Self.typed("Ask"), .sentFromSheet)
        #expect(sheet.words == "" && sheet.atSend == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromSheet, Self.typed("Next draft"), .completed).words == "Next draft")
        // A confirmation card empties the words sent, and the send stays open for its completion.
        let card = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard)
        #expect(card.words == "" && card.atSend == "Ask")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Newer"), .confirmationCard).words == "Newer")
    }

    @Test("Words cleared and retyped to the sent text after Send are newly written: kept, never emptied by the send")
    func retypedSentTextIsNewWords() {
        // Unchanged sent words: not kept, and the send's answer empties them.
        let unchanged = Self.fill(Self.typed("Ask"), .sentFromField)
        #expect(unchanged.unsent == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .answered).words == "")
        // A binding's echo of the same text is no edit.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Ask")).unsent == "")
        // Cleared and retyped identically while the send is open: newly written words.
        let retyped = Self.fill(Self.typed("Ask"), .sentFromField, Self.typed(""), Self.typed("Ask"))
        #expect(retyped.words == "Ask" && retyped.unsent == "Ask", "the retyped words are kept")
        for ending in [ChatFieldFill.Change.answered, .completed, .confirmationCard] {
            var fill = retyped
            fill.apply(ending)
            #expect(fill.words == "Ask" && fill.unsent == "Ask", "the older send never empties newly written words")
        }
        // Said words, too, are an edit.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .said("more"), .answered).words != "")
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
        // So does any other change: a send, an Edit, a dictation's text.
        // A completion that empties the sent words is a change too.
        var completed = Self.fill(Self.typed("Hi"), .sentFromField, .startHearing)
        completed.apply(.completed)
        #expect(completed.words == "", "control: the completion emptied the sent words")
        completed.apply(.heard("one"))
        #expect(completed.words == "", "a transcript after the completion is dropped")
        for change in [ChatFieldFill.Change.sentFromSheet, .put("Edited"), .said("said")] {
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
        // Each change, where it happens: typing (above), both dictations, both sends, and an Edit.
        #expect(Self.count("fieldFill.apply(.startHearing) speech.start(locale: speechLocale, auto: auto) { transcript in fieldFill.apply(.heard(transcript))", in: text) == 1)
        #expect(Self.count("{ text in fieldFill.apply(.said(text))", in: text) == 1)
        // The completion and a confirmation card land on the sent request's chat key in
        // `ChatFieldWords`, never through this view (`ChatReplyFieldRuntimeTests.clearWiring`).
        #expect(Self.count("dictation.inputSent(inputText) // From the open sheet the input empties as it goes; a newer draft is what is typed next. fieldFill.apply(.sentFromSheet)", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.apply(.sentFromField) dictation.inputSent(inputText)", in: text) == 1)
        #expect(Self.count("fieldFill.apply(.put(text)) isTextFieldFocused = true", in: text) == 1)
        // The "e.g." line's change goes in as words and is never sent from here.
        #expect(Self.count("func putExample(_ example: String) { fieldFill.apply(.put(example)) inputSelection = .init(insertionPoint: inputText.endIndex) }", in: text) == 1)
        #expect(Self.count("fieldFill.apply(", in: text) == 8)
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
        #expect(Self.count("readyReply = ChatReadyReply(message: newest, suggestion: shown, accounts: context.accounts)", in: text) == 1)
        #expect(Self.count("req.composeView(account:", in: text) == 1, "every agent compose opens through the one presenter")
        #expect(Self.count("onAgentOutcome:", in: text) == 1, "only the AI Suggestion's card")
        #expect(Self.count("composeEnded(.", in: text) == 0 && Self.count("{ _ in composeEnded", in: text) == 0)
        // The AI Suggestion's card is not a send from the field: its outcome leaves the field's
        // words alone (a completion with no field send would empty them).
        #expect(Self.count("ready.compose.composeView( replyTo: ready.message, suggestion: ready.suggestion, draftId: ready.draftId, onAgentOutcome: { _ in })", in: text) == 1,
                "the card holds the suggestion the ghost showed and never completes the field")
        #expect(Self.count("@State private var example = ChatSuggestionConfig.randomExample()", in: text) == 1,
                "one example per chat open, kept across redraws")
        #expect(Self.count("composeEnded(", in: text) == 2, "only agent compose cards end through it")
        // Who the reply goes to and whose turn it is decide whether the suggestion shows.
        #expect(Self.count("let usersTurn = (thread.items.last?.isOwn ?? false) || !unsentReplies.isEmpty", in: text) == 2,
                "the suggestion and the working bubble read the user's turn the same way")
        #expect(Self.count("guard viewModel.hasLoadedThread, context.isLoaded, context.accounts.contains(where: { $0.id == newest.accountId }) else { return nil }", in: text) == 1,
                "no suggestion before the thread and accounts load")
        // Every compose card the chat opens hides it; "Writing your email" hides it.
        #expect(Self.count("let cardOpen = readyReply != nil || agentCompose != nil || forwardMessage != nil", in: text) == 1)
        #expect(Self.count("ChatReplyField.shown( newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only, writing: chatWorking, cardOpen: cardOpen)", in: text) == 1)
        // The working bubble: the inbox row's rule, never while the agent works on the field's request.
        #expect(Self.count("guard viewModel.hasLoadedThread, context.isLoaded, !chatWorking, context.accounts.contains(where: { $0.id == newest.accountId }) else { return nil }", in: text) == 1,
                "no working bubble before the thread and accounts load, or while the agent works")
        #expect(Self.count("return ChatReplyField.suggestionPhase(newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only, aiSourceEnabled: aiSourceEnabled, subscribed: subscribed)", in: text) == 1,
                "the working bubble is the row's rule as it is (it never yields the ghost)")
        #expect(Self.count("let aiSourceEnabled = AIWorkingRule.anyAISourceEnabled( demoHidesAI: DemoModeStore.shared.hidesAIContent, optedOutAllAI: optOutAllAI, deviceSyncAuto: DeviceSyncService.shared.isAutoEnabled, subscribed: subscribed)", in: text) == 1,
                "the chat reads the inbox row's AI-source rule")
        // The ghost is only ever the suggestion the chat shows; the row's rule adds the working bubble alone.
        #expect(Self.count("if let text = shown?.textMessage { return .ready(text) }", in: text) == 1)
        #expect(Self.count("suggestionPhase(on: $0, shown: shown, thread: thread)", in: text) == 1,
                "the row's phase takes the suggestion the chat shows, whichever card is open")
        #expect(Self.count("req.onOutcome(outcome) composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)", in: text) == 1,
                "an agent compose hands on its outcome")
        let ended = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {", in: text)
        #expect(Self.count("guard case .sent = outcome else { return }", in: ended) == 1)
        #expect(Self.count("ChatFieldWords", in: ended) == 0 && Self.count("fieldFill", in: ended) == 0,
                "the view never completes the field: the request does, on its own key (ChatFieldWordsRuntimeTests)")
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
        #expect(Self.count("if outcome == .written { await postMessageDataDidChange(reply.id) }", in: compose) == 1,
                "the one writer, used by the edit and the Recompute, refreshes an open chat after a stored write")
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
        let ready = ChatReadyReply(message: message, suggestion: message.suggestion ?? .filtered, accounts: accounts)
        return ready.compose.composeView(replyTo: message, suggestion: ready.suggestion, draftId: ready.draftId, onAgentOutcome: { _ in })
    }

    /// The compose card the chat opens for the agent's reply, as the chat's cover builds it.
    private static func card(agent request: AgentToolRouter.ComposeRequest, accounts: [Account]) -> ComposeView {
        request.composeView(account: accounts.first, onOutcome: { _ in })
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
        #expect(compose.prefillBcc == [] && compose.replyTo?.id == email.id && !compose.isForward)
        #expect(compose.prefillSubject == ThreadUtils.replySubject(for: email.subject))
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
        if case .field(let onlyTo) = origin { fieldReply = ChatFieldReply(email: header, onlyTo: onlyTo) }
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
        #expect(chosen.mode == .reply && !chosen.isReplyAll && chosen.to == [Self.david.address] && chosen.cc.isEmpty && chosen.bcc.isEmpty,
                "the request itself is the plain reply to David: the agent's added people are not applied")
        #expect(chosen.subject == ThreadUtils.replySubject(for: "Plans"), "the reply subject")
        let toChosen = Self.card(agent: chosen, accounts: chosenAccounts)
        #expect(!toChosen.isReplyAll, "Replying only to David is a plain reply")
        #expect(toChosen.prefillTo == [Self.david.address] && toChosen.prefillCc == [] && toChosen.prefillBcc == [],
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
        #expect(whole.prefillTo == everyone.to && whole.prefillCc == everyone.cc)

        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest(
            ["remove_recipients": .array([.string("team@example.com")])], from: .field(onlyTo: nil))
        #expect(narrowed.to == ["sender@example.com"] && narrowed.cc.isEmpty && narrowed.bcc.isEmpty,
                "the agent itself left team@example.com out")
        let fewer = Self.card(agent: narrowed, accounts: narrowedAccounts)
        #expect(!fewer.isReplyAll, "someone left out by the agent: a plain reply, never recorded as Reply All")
        #expect(fewer.prefillTo == ["sender@example.com"] && fewer.prefillCc == [] && fewer.prefillBcc == [],
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
            #expect(compose.prefillCc == moved.cc && compose.prefillBcc == moved.bcc,
                    "the card keeps the agent's Cc as written, and its empty Bcc exactly")
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

    /// A Reply-To entry that names no sendable address (`Undisclosed-Recipients:;`) is part of the
    /// Reply All audience as the text written: the card keeps it, so leaving it out narrows the
    /// audience as leaving out a person does, and keeping it in another case or in another field
    /// (To, Cc or Bcc) does not. The entry is written in mixed case on both sides, so the
    /// comparison must fold the case of each.
    @Test("An audience entry that names no address counts as its text: left out it is a plain reply, kept in any case or field it is Reply All")
    func audienceEntryWithNoAddressCountsAsItsText() {
        let entry = "Undisclosed-Recipients:;"
        var email = Self.header("n1")
        email.replyTo = "Alex Doe <alex@example.com>, \(entry)"
        email.to = "me@example.com, david@example.com"
        email.cc = "sam@example.com"
        let envelope = ChatReplyCompose.suggestionEnvelope(for: email, accounts: [Self.me])
        #expect(envelope.to == ["alex@example.com", entry, "david@example.com"] && envelope.cc == ["sam@example.com"],
                "control: the audience holds the entry as written, beside the addresses")
        let unchanged = envelope.with(recipients: envelope.recipients, subject: envelope.subject)
        #expect(unchanged.isReplyAll, "control: the whole audience, unchanged, is Reply All")

        let addressesOnly = envelope.recipients.filling(to: RecipientEntry(["alex@example.com", "david@example.com"]))
        #expect(addressesOnly.to.tokens == ["alex@example.com", "david@example.com"] && addressesOnly.to.rejected.isEmpty,
                "control: every address kept, the entry left out")
        let withoutEntry = envelope.with(recipients: addressesOnly, subject: envelope.subject)
        #expect(!withoutEntry.isReplyAll, "the entry that names no address left out: the audience narrowed, a plain reply")

        let otherCase = envelope.recipients.filling(
            to: RecipientEntry(["alex@example.com", "UNDISCLOSED-RECIPIENTS:;", "david@example.com"]))
        #expect(otherCase.to.rejected == ["UNDISCLOSED-RECIPIENTS:;"], "control: the entry kept, written in another case")
        let entryInOtherCase = envelope.with(recipients: otherCase, subject: envelope.subject)
        #expect(entryInOtherCase.isReplyAll, "the whole audience kept, the entry in another case: Reply All")

        let inCc = envelope.recipients.filling(
            to: RecipientEntry(["alex@example.com", "david@example.com"]), cc: RecipientEntry(["sam@example.com", entry]))
        #expect(inCc.to.rejected.isEmpty && inCc.cc.rejected == [entry], "control: the entry moved to Cc")
        let entryInCc = envelope.with(recipients: inCc, subject: envelope.subject)
        #expect(entryInCc.isReplyAll, "the whole audience kept, the entry only in Cc: Reply All")

        let inBcc = envelope.recipients.filling(
            to: RecipientEntry(["alex@example.com", "david@example.com"]), bcc: RecipientEntry([entry]))
        #expect(inBcc.to.rejected.isEmpty && inBcc.cc.rejected.isEmpty && inBcc.bcc.rejected == [entry],
                "control: the entry moved to Bcc")
        let entryInBcc = envelope.with(recipients: inBcc, subject: envelope.subject)
        #expect(entryInBcc.isReplyAll, "the whole audience kept, the entry only in Bcc: Reply All")

        let davidInBcc = envelope.recipients.filling(
            to: RecipientEntry(["alex@example.com", entry]), bcc: RecipientEntry(["david@example.com"]))
        #expect(davidInBcc.to.tokens == ["alex@example.com"] && davidInBcc.bcc.tokens == ["david@example.com"],
                "control: David moved to Bcc")
        let davidOnlyInBcc = envelope.with(recipients: davidInBcc, subject: envelope.subject)
        #expect(davidOnlyInBcc.isReplyAll, "the whole audience kept, David only in Bcc: Reply All")

        let davidLeftOut = envelope.recipients.filling(to: RecipientEntry(["alex@example.com", entry]))
        let withoutDavid = envelope.with(recipients: davidLeftOut, subject: envelope.subject)
        #expect(!withoutDavid.isReplyAll, "a person left out, the entry kept: a plain reply")
    }

    /// The audience is compared as compose reads its fields: each mailbox by its address in any
    /// case, wherever the agent puts it (To, Cc or Bcc alone, by name, the same person in both To
    /// and Cc), and an entry that names no sendable address (a Reply-To's
    /// `undisclosed-recipients:;`) as the text written, so a reply that leaves that entry out
    /// leaves part of the audience out. The valid recipients stay the same in the two cases that
    /// differ only in that entry. The reply tool decides the kind on the AI Suggestion's envelope
    /// (`ChatReplyCompose.with`), from the field and the sheet alike, and the card takes the
    /// request as it is (`ComposeRequest.composeView`).
    @Test("""
    A reply the agent writes to mixed-case named mailboxes is Reply All exactly when it holds the \
    whole audience, a Reply-To entry with no address included and someone moved to Bcc alone; \
    the card keeps each field's mailboxes with their names and case, and the entry as written
    """)
    func agentReplyAudienceIsComparedAsComposeReadsIt() {
        // The Reply-To writes the entry with no address in another case than the agent does, so
        // both sides of the comparison must fold the case.
        let startEntry = "Undisclosed-Recipients:;"
        var email = Self.header("n1")
        email.replyTo = "Alex Doe <alex@example.com>, \(startEntry)"
        email.to = "me@example.com, David Roe <David@Example.com>"
        email.cc = "Sam Poe <sam@example.com>"
        let audience = buildReplyAllRecipients(for: email, allAccounts: [Self.me])
        #expect(audience.to == ["alex@example.com", startEntry, "david@example.com"] && audience.cc == ["sam@example.com"],
                "control: the audience is Alex, the entry with no address as written, David and Sam")

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
        let envelope = ChatReplyCompose.suggestionEnvelope(for: email, accounts: [Self.me])
        #expect(envelope.to == ["alex@example.com", startEntry, "david@example.com"] && envelope.cc == ["sam@example.com"],
                "control: the AI Suggestion's envelope keeps the entry as the Reply-To wrote it, not as the agent does")
        for item in cases {
            // As the AI reply tool builds it: the AI Suggestion's envelope, as the agent edited it.
            let edited = envelope.with(
                recipients: ComposeDraftGuards.Recipients().filling(
                    to: RecipientEntry(item.to), cc: RecipientEntry(item.cc), bcc: RecipientEntry(item.bcc)),
                subject: envelope.subject)
            let request = AgentToolRouter.ComposeRequest(
                mode: .reply, replyTo: email, to: edited.to, cc: edited.cc, bcc: edited.bcc,
                subject: edited.subject, body: "Friday works", isReplyAll: edited.isReplyAll)
            let compose = Self.card(agent: request, accounts: [Self.me])
            #expect(compose.isReplyAll == item.whole, "\(item.name): Reply All is \(item.whole)")
            let fields: [(name: String, card: [String]?, agent: [String])] = [
                ("To", compose.prefillTo, item.to), ("Cc", compose.prefillCc, item.cc), ("Bcc", compose.prefillBcc, item.bcc),
            ]
            for field in fields {
                let card = RecipientEntry(field.card ?? [])
                let agent = RecipientEntry(field.agent)
                #expect(card.recipients == agent.recipients && card.leftovers == agent.leftovers,
                        "\(item.name): the card's \(field.name) keeps the agent's mailboxes, their names and their case, and the entry as written")
            }
        }
    }

    @Test("A reply the agent writes in the open sheet keeps its recipients, and is Reply All only to the whole audience")
    func agentReplyFromTheSheetKeepsItsRecipients() async throws {
        let (everyone, accounts) = try await Self.agentReplyRequest([:], from: .sheet)
        #expect(everyone.fieldReply == nil, "control: asked for in the sheet, the request carries no field choice")
        let all = Self.card(agent: everyone, accounts: accounts)
        #expect(all.isReplyAll, "the agent's reply goes to the whole audience")
        #expect(all.prefillTo == everyone.to && all.prefillCc == everyone.cc)

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
        // The field itself; the suggestion's rule takes them too (`shownSuggestion`, pinned above).
        #expect(Self.count("clearCount: fieldClearCount, onlyTo: replyTarget.only,", in: chat) == 1, "the field knows the people chosen")
        // Both reply cards open through the one helper, read as the card opens: Reply All exactly
        // when the reply goes to everyone, and the recipients with it.
        #expect(Self.count("agentCompose = req", in: chat) == 1,
                "the agent's card is its request, exactly as the reply tool built it (ChatReplyComposeOriginTests)")
        #expect(Self.count("ChatReplyCompose.", in: chat) == 0, "the chat builds no envelope of its own")
        #expect(Self.count("isReplyAll", in: chat) == 0,
                "no card decides the kind or the Reply All recipients itself")
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
        #expect(Self.count("let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply, suggestion: field.suggestion) }", in: island) == 1,
                "the people chosen are read once, as the field's send starts")
        #expect(Self.count("let fieldReply = field?.fieldReply", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session, fieldWordsKey: fieldWordsKey), sessionKey: sessionKey, fieldReply: fieldReply, fieldWordsKey: fieldWordsKey)", in: island) == 1,
                "and travel with the request to the agent's tools")
        // A recovered send keeps them: the resume carries the cut-off send's request, the retry the
        // failed send as it was sent (ChatReplyRecoveryTests sends both through the real chat).
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, fieldReply: fieldReply, fieldWordsKey: fieldWordsKey)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session, fieldWordsKey: resume.fieldWordsKey), sessionKey: sessionKey, fieldReply: resume.fieldReply, fieldWordsKey: resume.fieldWordsKey)", in: island) == 1)
        #expect(Self.count("pendingResume = .init( request: resumable.resumeRequest, fieldReply: resume.fieldReply, fieldWordsKey: resume.fieldWordsKey)", in: island) == 1)
        #expect(Self.count("lastFailedSend = .init(text: text, field: field)", in: island) == 1)
        #expect(Self.count("sendAgentChat(failed.text, field: failed.field)", in: island) == 1)
        #expect(Self.count("replyField?.onlyTo", in: island) == 0 && Self.count("replyField?.isNoReply", in: island) == 0,
                "no send reads the field's choice later")
    }
}
