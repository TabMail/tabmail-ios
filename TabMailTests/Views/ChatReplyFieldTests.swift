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

    @Test("The closed field says it writes the reply; the open panel says it asks TabMail")
    func placeholder() {
        #expect(ChatReplyField(example: nil).placeholder == "Write your reply")
        #expect(ChatReplyField.writePlaceholder == "Write your reply")
        #expect(ChatReplyField.panelPlaceholder == "Ask TabMail")
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

    // MARK: - 3. No message to the agent

    @Test("The field's words reach the agent only from the open panel, with no reply-field nudge")
    func noAgentNudge() throws {
        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let field = try Self.source("TabMail/Views/Chat/ChatReplyField.swift")
        #expect(Self.count("agentMessage", in: island) == 0 && Self.count("agentMessage", in: field) == 0)
        #expect(Self.count("typed in its reply field", in: island + field) == 0)
    }

    // MARK: - 4. The status line

    @Test("Writing a reply reads Writing your email; other steps keep the agent's label")
    func statusLine() throws {
        let writing = try #require(ToolRegistry.activityLabels["email_reply"])
        #expect(ChatReplyField.statusLine(writing) == "Writing your email")
        #expect(ChatReplyField.writingStatus == "Writing your email")
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
        // A compose card that opened and closed without sending: the closing answer empties
        // nothing and hands the words back to the user, so they are kept.
        let closed = Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, .answered)
        #expect(closed.words == "Ask" && closed.atSend == nil && !closed.composing && closed.unsent == "Ask")
        // A compose card closed unsent, then a new field send before any answer: that send's
        // answer empties its sent words (the new send is not the closed card's).
        let resent = Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, Self.typed("Ask again"), .sentFromField, .answered)
        #expect(resent.words == "" && resent.atSend == nil && !resent.composing, "\(resent)")
        // A compose card opened for the send, then the same request raises a confirmation card for
        // another step: the compose card owns the completion, so the confirmation empties nothing,
        // and once the card closed unsent the answer hands the words back.
        let confirmed = Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, .confirmationCard)
        #expect(confirmed.words == "Ask" && confirmed.atSend == "Ask" && confirmed.composing, "\(confirmed)")
        let handedBack = Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, .confirmationCard, .answered)
        #expect(handedBack.words == "Ask" && handedBack.unsent == "Ask", "\(handedBack)")
        // Control: the compose card's own Send still completes the send and empties the sent words.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .composeOpened, .confirmationCard, .completed).words == "")

        // From the open sheet the words go at once; a draft typed next stays through the completion.
        let sheet = Self.fill(Self.typed("Ask"), .sentFromSheet)
        #expect(sheet.words == "" && sheet.atSend == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromSheet, Self.typed("Next draft"), .completed).words == "Next draft")
        // A confirmation card empties the words sent, and the send stays open for its completion.
        let card = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard)
        #expect(card.words == "" && card.atSend == "Ask")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, Self.typed("Newer"), .confirmationCard).words == "Newer")
    }

    @Test("Sent words a confirmation card took off the field come back when the field's own card then closes unsent; an edit since, or a completion, keeps them gone")
    func confirmationBeforeTheOwnCardHandsTheWordsBack() {
        // A confirmation card first (an archive), then the field's own reply card, closed unsent:
        // the answer hands the words back as it does when they stayed in the field.
        let taken = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard)
        #expect(taken.words == "" && taken.unsent == "" && taken.atSend == "Ask", "the card took them: \(taken)")
        let handedBack = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .composeOpened, .answered)
        #expect(handedBack.words == "Ask" && handedBack.unsent == "Ask" && handedBack.atSend == nil
                    && !handedBack.composing, "\(handedBack)")
        // Once handed back the send is over: a later answer or completion leaves them.
        let after = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .composeOpened, .answered, .completed, .answered)
        #expect(after.words == "Ask", "\(after)")
        // A second confirmation before the card finds them taken already.
        let twice = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .confirmationCard, .composeOpened, .answered)
        #expect(twice.words == "Ask", "\(twice)")
        // The user's edit after the card took them is the user's: nothing comes back over it.
        let edited = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, Self.typed("x"), Self.typed(""), .composeOpened, .answered)
        #expect(edited.words == "", "\(edited)")
        let newer = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, Self.typed("Newer"), .composeOpened, .answered)
        #expect(newer.words == "Newer", "\(newer)")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .said("more"), .composeOpened, .answered).words
                    == DictationController.appending("more", to: ""))
        // A live transcript is the user's too, also when it writes while the card is open.
        let heard = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .startHearing, .heard("Lunch instead"),
                              .composeOpened, .answered)
        #expect(heard.words == DictationController.appending("Lunch instead", to: ""), "\(heard)")
        let heardWhileOpen = Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .composeOpened, .startHearing,
                                       .heard("Lunch instead"), .answered)
        #expect(heardWhileOpen.words == DictationController.appending("Lunch instead", to: ""), "\(heardWhileOpen)")
        // With no card of the field's own the answer completes the send; a card's Send completes it.
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .answered).words == "")
        #expect(Self.fill(Self.typed("Ask"), .sentFromField, .confirmationCard, .composeOpened, .completed, .answered).words == "")
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
        try text(path).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `source` with its comments blanked first (`FixedDateFormatFenceTests.codeOnly`, string
    /// literals kept), so a fence on it counts code only: a commented-out line is not there.
    private static func code(_ path: String) throws -> String {
        String(FixedDateFormatFenceTests.codeOnly(try text(path), keepStrings: true))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func text(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature))
        let end = try #require(text[start.upperBound...].range(of: " private "))
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// `text` (from `source`) as a release build compiles it: each `#if DEBUG` part dropped, its
    /// `#else` part kept. For code with no nested conditions.
    private static func releaseView(of text: String) -> String {
        var kept = ""
        var rest = Substring(text)
        while let start = rest.range(of: "#if DEBUG") {
            kept += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "#endif") else { return "unterminated #if DEBUG" }
            let block = after[..<end.lowerBound]
            if let otherwise = block.range(of: "#else") { kept += " " + block[otherwise.upperBound...] }
            rest = after[end.upperBound...]
        }
        kept += rest
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("The input shows the user's words, and every change to them goes through the one API")
    func fieldShownWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("TextField(placeholder, text: typedText,", in: text) == 1)
        #expect(Self.count("Binding(get: { inputText }, set: { fieldFill.apply(.put($0)) })", in: text) == 1)
        #expect(Self.count("dictation.isActive || speech.isRecording || speech.isStarting", in: text) == 1)
        // ONE API: the view only reads the words and whether they are the sent words (both
        // read-only state); every change is a `fieldFill.apply`.
        #expect(Self.count("var inputText: String { fieldFill.words }", in: text) == 1)
        #expect(Self.count("var inputText", in: text) == 1)
        #expect(Self.count("fieldFill.", in: text)
                == Self.count("fieldFill.apply(", in: text) + Self.count("fieldFill.words", in: text)
                    + Self.count("fieldFill.holdsSentWords", in: text),
                "nothing else touches the field's state")
        // Each change, where it happens: typing (above), both dictations, both sends, an Edit, the
        // "e.g." line, and a new email's saved words.
        #expect(Self.count("fieldFill.apply(.startHearing) speech.start(locale: speechLocale, auto: auto) { transcript in fieldFill.apply(.heard(transcript))", in: text) == 1)
        #expect(Self.count("{ text in fieldFill.apply(.said(text))", in: text) == 1)
        // The completion and a confirmation card land on the sent request's chat key in
        // `ChatFieldWords`, never through this view (`ChatReplyFieldRuntimeTests.clearWiring`).
        #expect(Self.count("dictation.inputSent(inputText) // From the open sheet the input empties as it goes; a newer draft is what is typed next. fieldFill.apply(.sentFromSheet)", in: text) == 1)
        #expect(Self.count("isTextFieldFocused = false fieldFill.apply(.sentFromField) dictation.inputSent(inputText)", in: text) == 1)
        #expect(Self.count("fieldFill.apply(.put(text)) isTextFieldFocused = true", in: text) == 1)
        // The "e.g." line's change goes in as words and is never sent from here.
        #expect(Self.count("func putExample(_ example: String) { fieldFill.apply(.put(example)) inputSelection = .init(insertionPoint: inputText.endIndex) }", in: text) == 1)
        // A new email's saved words go in once, as its chat first opens; the screen hidden and
        // shown again keeps what was typed since (ChatNewThreadScreenTests.hiddenAndShownKeepsTyping).
        // Then its reply field takes the keyboard: the panel's input, which `isTextFieldFocused`
        // focuses, is never there in a new email's chat. Only the forked chat's put focuses the panel.
        #expect(Self.count("guard let newEmail = replyField?.newEmail, !newEmailStarted else { return } newEmailStarted = true if !newEmail.startWords.isEmpty { fieldFill.apply(.put(newEmail.startWords)) } focusedInput = .replyField }", in: text) == 1)
        #expect(Self.count("focusedInput = .replyField", in: text) == 1, "the new email's opening is the only one that focuses the reply field")
        #expect(Self.count("isTextFieldFocused = true", in: text) == 1, "the forked chat's put is the only one that focuses the panel's input")
        #expect(Self.count("fieldFill.apply(", in: text) == 9)
    }

    @Test("The closed field's Send writes the email from the words and never reaches the agent; a new email's chat takes its own Send")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Collapsed, the reply field's Send takes the field's route; the open sheet keeps the chat's.
        let message = try Self.body(of: "private func sendMessage() {", in: text)
        // Send refuses only an empty input, and the collapsed field then takes its own route.
        #expect(message.hasPrefix(" let text = inputText.trimmingCharacters(in: .whitespaces) guard !text.isEmpty else { return } if let replyField, !isExpanded { sendFromReplyField(text, replyField) return }"))
        let send = try Self.body(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {", in: text)
        // A new email's chat takes the words first and only (what its Send does is driven in
        // ChatNewThreadScreenTests); every other send from the field writes the reply.
        #expect(send.hasPrefix(" // A new email's chat decides what its Send does; the words stay until it acts on them. if let newEmail = field.newEmail { newEmail.send(text) return } guard let message else { return } isTextFieldFocused = false"),
                "a new email's chat takes its own Send, first")
        #expect(Self.count("return", in: send) == 2, "every other send from the field writes the reply")
        #expect(Self.count("onSendReadyReply", in: text) == 0 && Self.count("ChatReplyField.route", in: text) == 0)
        #expect(Self.count("onFieldSend?(text)", in: send) == 1)
        // ADR-IOS-114 decision 10 (amended 2026-11-25): the UI state decides, never the agent.
        #expect(Self.count("sendAgentChat", in: send) == 0, "the closed field never reaches the agent")
        #expect(Self.count("composeFromField(text, ChatFieldSend(message: message, onlyTo: field.onlyTo, suggestion: field.suggestion))", in: send) == 1)
        let compose = try Self.body(of: "private func composeFromField(_ text: String, _ send: ChatFieldSend) {", in: text)
        #expect(Self.count("sendAgentChat", in: compose) == 0 && Self.count("sendChatMessage", in: compose) == 0)
        #expect(Self.count("let written = await EmailReplyTool.composeWithRegisteredTool(text, invocation: invocation)", in: compose) == 1)
        #expect(Self.count("enqueueStatus(ChatReplyField.writingStatus)", in: compose) == 1)
        #expect(Self.count("sendFromReplyField(", in: text) == 2, "Send reaches it")
        #expect(Self.count("enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)", in: text) == 1)
    }

    @Test("The tutorial tooltip's arrow points at the mic glyph's centre")
    func tutorialArrowOnTheMic() {
        let micCentre = ChatViewLayout.fieldMicInset + ChatViewLayout.fieldMicGlyphWidth / 2
        #expect(TutorialChatInputBar.tooltipArrowCenterX + TutorialChatInputBar.tooltipInset == micCentre)
    }

    @Test("Reply to, Forward and the chosen people reach the field and the compose card")
    func recipientsWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The field itself; the suggestion's rule takes them too (`shownSuggestion`, pinned above).
        #expect(Self.count("configured: example), onlyTo: replyTarget.only,", in: chat) == 1, "the field knows the people chosen")
        // Both reply cards open through the one helper, read as the card opens: Reply All exactly
        // when the reply goes to everyone, and the recipients with it.
        #expect(Self.count("agentCompose = req", in: chat) == 1,
                "the agent's card is its request, exactly as the reply tool built it (ChatReplyComposeOriginTests)")
        #expect(Self.count("ChatReplyCompose.", in: chat) == 0, "the chat builds no envelope of its own")
        #expect(Self.count("isReplyAll", in: chat) == 0,
                "no card decides the kind or the Reply All recipients itself")
        #expect(Self.count("openedOn: composeScreen(answering: req.replyTo)", in: chat) == 1,
                "the agent's reply and forward cards record the chat's screen as they open")
        // A card from a field request: the agent's closing words open nothing; a field send starts afresh.
        #expect(Self.count("fieldComposeOpened = req.isFieldsOwnReply", in: chat) == 1,
                "the chat reads the reply tool's one decision of the field's own reply (FieldReplyCardWordsTests)")
        #expect(Self.count("onFieldSend: { _ in fieldComposeOpened = false }, onAgentCompose: openAgentCompose, composeFromAccountId: viewModel.message?.accountId, composeHostCovered: isAnyPresentation)", in: chat) == 1,
                "the chat's pill binds the email's account as a new message's From and takes nothing while the chat is covered")
        // A new message's card opens from the account bound when the turn started, and records the
        // chat's screen, in the one presenter call.
        #expect(Self.count("req.composeView(account: navigationStore.accounts.first { $0.id == req.fromAccountId }, openedOn: composeScreen(answering: req.replyTo)) { outcome in", in: chat) == 1)
        // The card and fieldComposeOpened are set only for a request this chat's own pill took
        // (ADR-IOS-053 Phase 2; ChatComposeRoutingTests runs it with the inbox and the email screen mounted).
        #expect(Self.count("private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {", in: chat) == 1)
        #expect(Self.count("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } fieldComposeOpened = req.isFieldsOwnReply agentCompose = req }", in: chat) == 1,
                "a new email's bound account is looked up as the card is taken, before anything is set")
        #expect(Self.count("private func agentAnswered() { guard !fieldComposeOpened else { return }", in: chat) == 1)
        #expect(Self.count("fieldComposeOpened = true", in: chat) == 0)
        #expect(Self.count("if replyTo != nil { replyTarget = .replyAll }", in: chat) == 1, "a sent reply clears it")
        #expect(Self.count("ownAddresses: context.ownAddresses) { replyTarget = $0 }", in: chat) == 1, "Done sets it")
        #expect(Self.count("ChatHeaderView(thread: thread) { guard TutorialCoordinator.shared.admits(.other) else { return } showsReplyTo = true }", in: chat) == 1)
        #expect(Self.count("Button { guard TutorialCoordinator.shared.admits(.other) else { return } forwardMessage = thread.newest }", in: chat) == 1)
        #expect(Self.count(".fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true, openedOn: composeScreen(answering: $0)) }", in: chat) == 1)
        #expect(Self.count(".onChange(of: thread.newest.map(ChatThread.copyKey)) { _, _ in replyTarget = .replyAll }", in: chat) == 1,
                "a new newest email resets the choice, even one whose UID matches the last")

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("composeFromField(text, ChatFieldSend(message: message, onlyTo: field.onlyTo, suggestion: field.suggestion))", in: island) == 1,
                "the people chosen are read once, as the field's send starts")
        #expect(Self.count("let fieldReply = field?.fieldReply", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session, fieldWordsKey: fieldWordsKey), sessionKey: sessionKey, fieldReply: fieldReply, composeOrigin: origin, fieldWordsKey: fieldWordsKey)", in: island) == 1,
                "and travel with the request to the agent's tools")
        // With the chat that asked, read as the send starts; the field's request belongs to the chat view.
        // The pill's send and the closed field's compose both read it.
        #expect(Self.count("let origin = composeOrigin(sessionKey: capturedSessionKey, fieldReply: fieldReply)", in: island) == 2)
        #expect(Self.count("return ComposeOrigin(sessionKey: sessionKey, screen: fieldReply != nil ? .chat : screen, fromAccountId: composeFromAccountId)", in: island) == 1)
        // A covered screen does not take: the pill takes only while its screen shows and nothing covers it.
        #expect(Self.count("let host = (composeHostShown ?? composeHostAppeared) && !composeHostCovered", in: island) == 1)
        // A recovered send keeps them: the resume carries the cut-off send's request, the retry the
        // failed send as it was sent (ChatReplyRecoveryTests sends both through the real chat).
        #expect(Self.count("pendingResume = .init( request: resumable.resumeRequest, fieldReply: fieldReply, origin: origin, fieldWordsKey: fieldWordsKey)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session, fieldWordsKey: resume.fieldWordsKey), sessionKey: sessionKey, fieldReply: resume.fieldReply, composeOrigin: origin, fieldWordsKey: resume.fieldWordsKey)", in: island) == 1)
        // A resume continues its turn: the origin the turn started with, from any screen of the thread.
        #expect(Self.count("let origin = resume.origin", in: island) == 1)
        #expect(Self.count("composeOrigin(sessionKey: capturedSessionKey,", in: island) == 2,
                "only the send and the closed field's compose read the pill's origin")
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
        #expect(Self.count("showSearch || labelMenuMessage != nil || showLabelFilterPicker || moveMessageId != nil || moveThreadGroup != nil || replyMessage != nil || draftOpen != nil || agentCompose != nil || newEmailCover != nil || viewModel.showCompose || showUndoAlert }", in: inbox) == 1,
                "every sheet, cover and alert of the inbox holds a compose card")
        #expect(Self.count("newEmailCover != nil || replyMessage != nil || replyAllMessage != nil || forwardMessage != nil || agentCompose != nil || moveMessage != nil || labelMenuMessage != nil }", in: detail) == 1,
                "every sheet and cover of the email screen holds a compose card")
        #expect(Self.count("onAgentCompose: openAgentCompose, composeFromAccountId: message.accountId, composeHostCovered: isAnyCoverPresented)", in: detail) == 1)
        #expect(Self.count(".fullScreenCover(item: $agentCompose) { req in req.composeView(account: fromAccount(of: req), onOutcome: req.onOutcome) }", in: detail) == 1,
                "the email screen's new message opens from its bound account, through the one presenter")
        let detailActions = try Self.source("TabMail/Views/Message/MessageDetailView+Actions.swift")
        #expect(Self.count("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } agentCompose = req", in: detailActions) == 1)
        #expect(Self.count("navigationStore.accounts.first { $0.id == req.fromAccountId }", in: detailActions) == 1)
        #expect(Self.count("pendingResume = .init( request: resumable.resumeRequest, fieldReply: resume.fieldReply, origin: resume.origin, fieldWordsKey: resume.fieldWordsKey)", in: island) == 1)
        #expect(Self.count("lastFailedSend = .init(text: text, field: field, ownsFieldWords: fieldWordsKey != nil)", in: island) == 1)
        #expect(Self.count("sendAgentChat(failed.text, field: failed.field, ownsFieldWords: failed.ownsFieldWords)", in: island) == 1)
        // Re-send of the last turn sends it with its email and choice: the bubble keeps the field's
        // send and the menu passes it on (ChatComposeRoutingTests checks the bubble keeps it); it owns
        // none of the field's words (ChatReplyFieldRuntimeTests.sheetResendsSendWithNoField).
        #expect(Self.count("chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date(), fieldSend: field))", in: island) == 1)
        #expect(Self.count("resendLastUserMessage(text: msg.content, field: msg.fieldSend, afterIndex: index)", in: island) == 1)
        // Rewind trims the later turns and sends the chosen turn again as a fresh turn, which names
        // the screen that asked (an earlier field turn's recipients choice is not kept with it).
        #expect(Self.count("rewindToMessage(text: msg.content, atIndex: index)", in: island) >= 1, "the menu's Rewind reaches the rewind")
        #expect(Self.count("private func rewindToMessage(text: String, atIndex index: Int) { trimForRewind(atIndex: index) lastFailedSend = nil sendAgentChat(text) }", in: island) == 1,
                "Rewind sends the turn again through the send that names the screen")
        #expect(Self.count("trimForResendLast(atIndex: index) lastFailedSend = nil sendAgentChat(text, field: field, ownsFieldWords: false)", in: island) == 1)
        #expect(Self.count("replyField?.onlyTo", in: island) == 0 && Self.count("replyField?.isNoReply", in: island) == 0,
                "no send reads the field's choice later")
    }

    /// ADR-IOS-053 Phase 2: the census of the turns that can reach a compose tool. Every invocation
    /// the app builds is one of four: the pill's send and its resume, which name the screen that
    /// asked (every send, retry, resend, rewind and tutorial prompt goes through `sendAgentChat`);
    /// the chat view's closed field, whose compose names the chat view
    /// (`EmailReplyTool.composeFromField`, ADR-IOS-114 decision 10 amended 2026-11-25); and the
    /// compose editor's chat, whose host is a compose window and opens no agent card, so a
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
        #expect(built == ["DynamicIslandChatButton.swift": 4], "only the pill builds invocations: \(built)")

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("composeOrigin: origin, fieldWordsKey:", in: island) == 3,
                "the send, the closed field's compose and the resume name the screen that asked")
        #expect(Self.count("invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey) )", in: island) == 1,
                "the compose editor's chat, which opens no card, names none")
        #expect(Self.count("guard onAgentCompose != nil, composeContext == nil else { return nil }", in: island) == 1,
                "a compose editor's pill has no compose screen")
        // Every turn of the pill starts in one of these.
        // A fresh send and the closed field's compose name their screen; a resume reuses the origin
        // its turn started with.
        #expect(Self.count("let origin = composeOrigin(", in: island) == 2)
        #expect(Self.count("let origin = resume.origin", in: island) == 1)
        #expect(Self.count("activeChatTask = Task {", in: island) == Self.count("let origin = composeOrigin(", in: island) + Self.count("let origin = resume.origin", in: island) + 1,
                "one task per send, per field compose and per resume, and the compose editor's")
    }
}
