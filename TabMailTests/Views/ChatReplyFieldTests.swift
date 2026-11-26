/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
import UIKit
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

    @Test("The alt line offers the suggestion's alternative reply while it shows; with no AI Suggestion there is no line",
          arguments: [
            (true, "No rush, reply whenever you can" as String?, "No rush, reply whenever you can" as String?),
            (true, "  ask for Friday \n", "ask for Friday"),
            (true, nil, nil),
            (true, "   ", nil),
            (false, "ask for Friday", nil),
            (false, nil, nil),
          ])
    func alternativeLine(_ shows: Bool, _ alternative: String?, _ expected: String?) {
        let shown = shows ? ReplyResult(body: "Hi Alex", textMessage: "Tuesday works", changeCommand: alternative) : nil
        #expect(ChatReplyField.alternative(shown: shown) == expected)
        #expect(ChatSuggestionConfig.alternativeLine("No rush") == "alt: No rush")
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

    @Test("The closed field asks for the user's own message; the open panel says it asks TabMail")
    func placeholder() {
        #expect(ChatReplyField.writePlaceholder == "Write your message")
        #expect(ChatReplyField.panelPlaceholder == "Ask TabMail")
    }

    // MARK: - 2. The "alt:" line

    @Test("No configured example lists remain: the only line under the field is the AI Suggestion's alternative")
    func noConfiguredExamples() throws {
        let config = try Self.code("TabMail/Services/ChatViewConfig.swift")
        let field = try Self.code("TabMail/Views/Chat/ChatReplyField.swift")
        for gone in ["replyExamples", "newEmailExamples", "randomExample", "exampleLine", "\"e.g. "] {
            #expect(Self.count(gone, in: config + field) == 0, "\(gone) is gone")
        }
        #expect(ChatSuggestionConfig.statusLine == "AI Suggestion · Tap to use")
    }

    // MARK: - 3. No message to the agent

    @Test("Words reach the agent only from the open panel: no field's words go with a nudge, a reply's or a new email's")
    func noAgentNudge() throws {
        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let field = try Self.source("TabMail/Views/Chat/ChatReplyField.swift")
        #expect(Self.count("ChatReplyField.agentMessage", in: island + field) == 0, "the reply field's nudge is gone")
        #expect(Self.count("agentMessage(emailNumericId", in: island + field) == 0)
        #expect(Self.count("typed in its reply field", in: island + field) == 0)
        // A new email's chat composes directly too (ADR-IOS-114 decision 10), so its nudge is gone.
        #expect(Self.count("agentMessage(", in: island + field) == 0, "no field's words reach the agent with a nudge")
        #expect(Self.count("var newEmailWrite: ChatNewEmailField.Write?", in: island) == 1,
                "only the Send's own variable carries a new email's people; no agent request takes them")
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
        // The "alt: " line's reply goes in as words and is never sent from here.
        #expect(Self.count("func putAlternative(_ alternative: String) { fieldFill.apply(.put(alternative)) inputSelection = .init(insertionPoint: inputText.endIndex) }", in: text) == 1)
        // A new email's saved words go in once per email, as its chat first opens; the screen hidden
        // and shown again keeps what was typed since (ChatNewThreadScreenTests.hiddenAndShownKeepsTyping).
        // Then its reply field takes the keyboard: the panel's input, which `isTextFieldFocused`
        // focuses, is never there in a new email's chat. Only the forked chat's put focuses the panel.
        // The next email after a Send (a new session) starts from its own words, which empties the
        // sent ones, and leaves the keyboard as it is.
        #expect(Self.count("guard let newEmail = replyField?.newEmail, newEmail.sessionKey != newEmailSession else { return } let opening = newEmailSession == nil newEmailSession = newEmail.sessionKey if opening { if !newEmail.startWords.isEmpty { fieldFill.apply(.put(newEmail.startWords)) } focusedInput = .replyField } else { fieldFill.apply(.put(newEmail.startWords)) } }", in: text) == 1)
        #expect(Self.count("focusedInput = .replyField", in: text) == 1, "the new email's opening is the only one that focuses the reply field")
        #expect(Self.count("isTextFieldFocused = true", in: text) == 1, "the forked chat's put is the only one that focuses the panel's input")
        // A new email's field compose: sent, the words go as the card reports the send, before it
        // closes, so they never come back into the field under the closing card (the blink after
        // Send); otherwise they are the user's again.
        #expect(Self.count("if case .sent? = written { fieldFill.apply(.completed) } else { fieldFill.apply(.notWritten) } if case .nothing? = written { showAgentToast(Self.newEmailNotWrittenNote) } }", in: text) == 1)
        #expect(Self.count("fieldFill.apply(", in: text) == 12)
        // What the two changes do to the words of a field send whose card opened: on `.completed`
        // they go, on `.notWritten` they are back in the field (what showed under the closing card).
        var sent = ChatFieldFill()
        sent.apply(.put("Tell them Friday works"))
        sent.apply(.sentFromField)
        sent.apply(.composeOpened)
        var notSent = sent
        sent.apply(.completed)
        notSent.apply(.notWritten)
        #expect(sent.words.isEmpty && sent.unsent.isEmpty, "sent: the words go: \(sent)")
        #expect(notSent.words == "Tell them Friday works" && notSent.unsent == "Tell them Friday works",
                "not written: the words are the user's again: \(notSent)")
    }

    @Test("The closed field's Send writes the email from the words and never reaches the agent; a new email's chat's own Send first says who it is to, or asks and stops there")
    func fieldSendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        // Collapsed, the reply field's Send takes the field's route; the open sheet keeps the chat's.
        let message = try Self.body(of: "private func sendMessage() {", in: text)
        // Send refuses only an empty input, and the collapsed field then takes its own route.
        #expect(message.hasPrefix(" let text = inputText.trimmingCharacters(in: .whitespaces) guard !text.isEmpty else { return } if let replyField, !isExpanded { sendFromReplyField(text, replyField) return }"))
        let send = try Self.body(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {", in: text)
        // A new email's chat's own Send runs first: with nobody picked it asks and the send stops
        // there; with people picked, the words are the message of the email written to them (what
        // its Send does is driven in ChatNewThreadScreenTests). Every other send from the field
        // writes the reply.
        #expect(send.contains("var newEmailWrite: ChatNewEmailField.Write? if let newEmail = field.newEmail { guard let write = newEmail.send(text) else { return } newEmailWrite = write } else if message == nil { return } isTextFieldFocused = false"),
                "a new email's chat takes its own Send, first")
        #expect(Self.count("return", in: send) == 2, "every other send from the field writes the reply")
        #expect(Self.count("onSendReadyReply", in: text) == 0 && Self.count("ChatReplyField.route", in: text) == 0)
        #expect(Self.count("onFieldSend?(text)", in: send) == 1)
        // ADR-IOS-114 decision 10 (amended 2026-11-25): the UI state decides, never the agent. The
        // field's Send never reaches the agent: a reply's words write the reply, and a new email's
        // chat's words write the new email (ChatNewThreadTests).
        #expect(Self.count("sendAgentChat", in: send) == 0, "no Send from the field reaches the agent")
        #expect(Self.count("if let newEmailWrite { composeNewEmailFromField(text, newEmailWrite) } else if let message {", in: send) == 1)
        #expect(Self.count("composeFromField(text, ChatFieldSend(message: message, onlyTo: field.onlyTo))", in: send) == 1)
        // The words go up as the user's bubble at once, before anything is written.
        #expect(Self.count("fieldSending = true onFieldSend?(text) if let newEmailWrite", in: send) == 1)
        let compose = try Self.body(of: "private func composeFromField(_ text: String, _ send: ChatFieldSend) {", in: text)
        #expect(Self.count("sendAgentChat", in: compose) == 0 && Self.count("sendChatMessage", in: compose) == 0)
        // ADR-IOS-114 decision 10 (amended 2026-11-26): the words are the user's own message, written
        // by the compose text request, never an edit of the AI Suggestion and never the agent's tool.
        #expect(Self.count("runFieldCompose(fieldReply: send.fieldReply, fieldWordsKey: fieldWordsKey) { invocation in await ChatFieldCompose().reply(text, invocation: invocation) }", in: compose) == 1)
        let newEmail = try Self.body(of: "private func composeNewEmailFromField(_ text: String, _ write: ChatNewEmailField.Write) {", in: text)
        #expect(Self.count("sendAgentChat", in: newEmail) == 0 && Self.count("sendChatMessage", in: newEmail) == 0)
        #expect(Self.count("runFieldCompose(fieldReply: nil, fieldWordsKey: nil) { invocation in await ChatFieldCompose().newEmail(text, to: to, subject: write.subject, invocation: invocation) }", in: newEmail) == 1)
        #expect(Self.count("EmailReplyTool", in: text) == 0 && Self.count("EmailComposeTool", in: text) == 0,
                "the field never runs the agent's tools")
        // Both run in the one field compose: "Writing your email" above the field, and its task
        // the one Stop cancels.
        let run = try Self.body(of: "private func runFieldCompose(", in: text)
        #expect(Self.count("sendAgentChat", in: run) == 0 && Self.count("sendChatMessage", in: run) == 0)
        #expect(Self.count("enqueueStatus(ChatReplyField.writingStatus)", in: run) == 1)
        #expect(Self.count("let written = await compose(invocation)", in: run) == 1)
        #expect(Self.count("runFieldCompose(", in: text) == 3, "a reply's and a new email's, and its own")
        #expect(Self.count("sendFromReplyField(", in: text) == 2, "Send reaches it")
        #expect(Self.count("enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)", in: text) == 1)
    }

    @Test("The chat opens compose for the AI Suggestion, empties the field after a send, and shows the outbox's unsent replies")
    func chatWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("readyReply = ChatReadyReply(message: newest, suggestion: shown, accounts: context.accounts)", in: text) == 1)
        #expect(Self.count("req.composeView(account:", in: text) == 1, "every agent compose opens through the one presenter")
        #expect(Self.count("onAgentOutcome:", in: text) == 0, "the ghost's and the paperclip's card open through their one builder")
        #expect(Self.count("composeEnded(.", in: text) == 0 && Self.count("{ _ in composeEnded", in: text) == 0)
        // The ghost's and the paperclip's card are not a send from the field: their outcome leaves
        // the field's words alone (a completion with no field send would empty them); a sent reply
        // clears "Replying only to".
        #expect(Self.count("ready.composeView(openedOn: composeScreen(answering: ready.message)) { outcome in readyCardEnded(outcome) }", in: text) == 1,
                "the card is the value's own builder (its suggestion, draft and pick) and records the chat's screen")
        let readyEnded = try Self.body(of: "private func readyCardEnded(_ outcome: ComposeOutcome) {", in: text)
        #expect(readyEnded.hasPrefix(" guard case .sent = outcome else { return } heldGhost?.sent = true replyTarget = .replyAll }"),
                "only a sent reply resets who the next one goes to and ends a held ghost as a send, and the field is never emptied: \(readyEnded)")
        #expect(Self.count("alternative: ChatReplyField.alternative(shown: shown),", in: text) == 1,
                "the alt line reads the shown AI Suggestion, nothing else")
        #expect(Self.count("randomExample", in: text) == 0, "no configured example")
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
        #expect(Self.count("ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() }, undo: { reply.undo() })", in: text) == 1,
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
        let bottom = try #require(text.range(of: "Color.clear.frame(height: ChatViewLayout.pillGap).id(Self.bottomId)"))
        #expect(rows.upperBound < unsent.lowerBound && unsent.upperBound < ghost.lowerBound && ghost.upperBound < bottom.lowerBound,
                "the AI Suggestion is the last chat row")
    }

    @Test("A held ghost ends once its card has closed: at once unsent or with no bubble, after a send once the reply shows",
          arguments: [false, true], [false, true])
    func heldGhostEnds(sent: Bool, showsBubble: Bool) {
        var held = ChatHeldGhost(text: "Tuesday works for me", showsBubble: showsBubble)
        held.sent = sent
        // While the card is up the ghost stays, whatever else happened.
        #expect(!held.ends(replyShows: false) && !held.ends(replyShows: true), "the ghost stays while its card is up")
        held.cardClosed = true
        #expect(held.ends(replyShows: true), "a shown reply always ends it once the card closed")
        let waitsForReply = sent && showsBubble
        #expect(held.ends(replyShows: false) == !waitsForReply,
                "closed: it waits only for a sent reply the chat shows as its bubble (sent \(sent), bubble \(showsBubble))")
        #expect(held.morphs == waitsForReply, "only that reply's bubble takes the ghost's place in motion")
    }

    @Test("The field's Send: the user's own words show at once as their bubble, pulsing until the email is written, then still and unchanged")
    func fieldMessageBubble() {
        var message = ChatFieldMessage(text: "Tuesday works for me")
        #expect(message.text == "Tuesday works for me" && message.pulses, "the words as sent, pulsing")
        message.written = true
        #expect(message.text == "Tuesday works for me" && !message.pulses, "written: the same words, still")
        #expect(ChatSuggestionConfig.writtenHold > 0, "the message stays a moment before the card opens")
        #expect(ChatFieldMessageBubble.writingId == "chat.fieldMessage.writing" && ChatFieldMessageBubble.bubbleId == "chat.fieldMessage")
        #expect(ChatFieldMessageBubble.bubbleId != ChatSuggestionBubble.bubbleId
                && ChatFieldMessageBubble.writingId != ChatSuggestionWorkingBubble.bubbleId,
                "the user's own message is never the AI Suggestion's bubble")
    }

    @Test("The ghost tapped open stays while its card is up, and turns into the sent reply's bubble once the card has closed")
    func heldGhostWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The tap holds the ghost it opened, with whether the chat shows this card's send as a bubble.
        let open = try Self.body(of: "private func openSuggestion(_ shown: ReplyResult, on newest: MessageHeader, tutorialMove: TutorialCoordinator.FieldMove?) {", in: text)
        #expect(Self.count("heldGhost = shown.textMessage.map { ChatHeldGhost(text: $0, showsBubble: composeScreen(answering: newest) == .chat) }", in: open) == 1)
        #expect(Self.count("heldGhost = ", in: text) == 3, "set by the tap or the field's card, cleared only as the hold ends")
        // The field's own card holds the user's message bubble, as a tapped ghost is held, and its
        // close and send end the hold through the same rule.
        let agentOpen = try Self.body(of: "private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {", in: text)
        #expect(Self.count("if req.isFieldsOwnReply, let message = fieldMessage {", in: agentOpen) == 1)
        #expect(Self.count("heldGhost = ChatHeldGhost( text: message.text, isMessage: true, showsBubble: composeScreen(answering: req.replyTo) == .chat) fieldMessage = nil", in: agentOpen) == 1)
        #expect(Self.count(".fullScreenCover(item: $agentCompose, onDismiss: readyCardClosed) { composeView(for: $0) }", in: text) == 1)
        let agentEnded = try Self.body(of: "private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {", in: text)
        #expect(Self.count("heldGhost?.sent = true", in: agentEnded) == 1, "a sent field card turns the held email into its bubble")
        #expect(Self.count(".onChange(of: chatWorking) { _, working in if !working { fieldMessage = nil } }", in: text) == 1,
                "the send's end (Stop, nothing written) takes the user's bubble down")
        // The card's close and the reply's arrival both end it, through the one rule.
        #expect(Self.count(".fullScreenCover(item: $readyReply, onDismiss: readyCardClosed) { ready in", in: text) == 1)
        let closed = try Self.body(of: "private func readyCardClosed() {", in: text)
        #expect(closed.hasPrefix(" heldGhost?.cardClosed = true endHeldGhostIfDone() }"))
        #expect(Self.count(".onChange(of: sentReplyShows) { _, _ in endHeldGhostIfDone() }", in: text) == 1)
        #expect(Self.count("!unsentReplies.isEmpty || (thread.items.last?.isOwn ?? false)", in: text) == 1,
                "the reply shows as its outbox bubble or as the sent email")
        let end = try Self.body(of: "private func endHeldGhostIfDone() {", in: text)
        #expect(Self.count("guard let held = heldGhost, held.ends(replyShows: sentReplyShows) else { return }", in: end) == 1)
        #expect(Self.count("withAnimation(held.morphs && !reduceMotion ? morph : nil) { heldGhost = nil }", in: end) == 1,
                "the morph moves only after a send it shows, and never under Reduce Motion")
        // While held the ghost keeps its row and the outbox bubbles wait; the newest bubble and the
        // held ghost share one id, so the one turns into the other.
        #expect(Self.count("if heldGhost == nil { ForEach(unsentReplies) { reply in", in: text) == 1)
        #expect(Self.count(".matchedGeometryEffect(id: Self.sentMorphId(reply, newest: unsentReplies.last), in: sentMorph)", in: text) == 1)
        // The held one is the ghost tapped open, or the user's own message the field sent, in the
        // ghost's look or the message's.
        #expect(Self.count("if let held = heldGhost { Group { if held.isMessage { ChatFieldMessageBubble(text: held.text, pulses: false) } else { ChatSuggestionBubble(text: held.text) {} } } .matchedGeometryEffect(id: Self.heldGhostMorphId, in: sentMorph)", in: text) == 1)
        #expect(Self.count("} else if let newest = thread.newest, let suggestion {", in: text) == 1, "the live ghost only when none is held")
    }

    @Test("Only the newest outbox bubble takes the held ghost's place")
    func sentMorphIds() {
        func reply(_ id: String) -> ChatUnsentReply {
            ChatUnsentReply(outboxId: id, status: .queued, sentAt: nil, holdUntil: nil, draftId: nil, instanceEpoch: nil,
                            filed: false, textMessage: nil)
        }
        let older = reply("outbox-1"), newest = reply("outbox-2")
        #expect(ChatThreadView.sentMorphId(newest, newest: newest) == ChatThreadView.heldGhostMorphId)
        #expect(ChatThreadView.sentMorphId(older, newest: newest) != ChatThreadView.heldGhostMorphId)
        #expect(ChatThreadView.sentMorphId(older, newest: newest) != ChatThreadView.sentMorphId(reply("outbox-3"), newest: newest),
                "every other bubble keeps an id of its own")
    }

    @Test("With the chat view on, the email's detail has no compose button; the classic view keeps it")
    func detailComposeOnlyInClassic() throws {
        let detail = try Self.source("TabMail/Views/Message/MessageDetailView.swift")
        #expect(Self.count("@State private var opensInChat = ChatViewConfig.opensInChat", in: detail) == 1,
                "the chat view's setting as the email opens")
        #expect(Self.count("if !opensInChat { ToolbarItem(placement: .topBarTrailing) { ComposeToolbarButton(onNewCompose: {", in: detail) == 1,
                "the compose button only in the classic view")
        #expect(Self.count("ComposeToolbarButton(", in: detail) == 1, "and nowhere else on the email's screen")
    }

    @Test("The paperclip's choices open in a pop-up over the field, and the pick runs once the pop-up has gone")
    func paperclipPopUpWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        let start = try #require(text.range(of: "struct ChatPaperclipButton: View {"))
        let end = try #require(text.range(of: "struct ChatAttachChoices: View {"))
        let clip = String(text[start.lowerBound..<end.lowerBound])
        #expect(Self.count("Menu {", in: clip) == 0, "no system menu: it grows out of the field's glass and takes the field's place")
        #expect(Self.count(".popover(isPresented: $showsChoices, arrowEdge: .bottom) {", in: clip) == 1)
        #expect(Self.count("attach(", in: clip) == 1, "one call of the pick")
        #expect(Self.count(".onDisappear { guard let source = chosen else { return } chosen = nil attach(source) }", in: clip) == 1,
                "the pick runs once the pop-up has gone, so its picker is not refused while the pop-up closes")
        #expect(Self.count("ChatAttachChoices { source in chosen = source showsChoices = false }", in: clip) == 1)
        #expect(Self.count(".presentationCompactAdaptation(.popover)", in: text) >= 1, "a pop-up on iPhone too, never a sheet")
    }

    @Test("The ghost is dashed on a faded fill and captioned in one button; the alt line hides while dictating; compose's stored edits refresh the chat")
    func suggestionLookWiring() throws {
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        let ghost = try #require(bubble.range(of: "struct ChatSuggestionBubble: View {")
            .flatMap { start in bubble[start.lowerBound...].range(of: "struct ChatSuggestionWorkingBubble").map { String(bubble[start.lowerBound..<$0.lowerBound]) } })
        let captionText = "Text(ChatSuggestionConfig.statusLine)"
        #expect(Self.count(".stroke(Palette.chatSuggestionStroke, style: StrokeStyle( lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))", in: ghost) == 1, "a dashed outline")
        #expect(Self.count(".fill(Palette.chatSuggestionFill)", in: ghost) == 1, "on a faded fill")
        #expect(Self.count(".foregroundStyle(Palette.chatSuggestionText)", in: ghost) == 1, "dark-blue text")
        #expect(Self.count(captionText, in: ghost) == 1, "the caption shows")
        // The caption sits inside the button's label, so it takes the tap too.
        let button = try #require(ghost.range(of: "Button(action: onTap) {"))
        let caption = try #require(ghost.range(of: captionText))
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
                "the alt line shows only on an empty, signed-in field, never while dictating")

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
        return ready.composeView(openedOn: .chat, onOutcome: { _ in })
    }

    /// The compose card the chat opens for the agent's reply, as the chat's cover builds it.
    private static func card(agent request: AgentToolRouter.ComposeRequest, accounts: [Account]) -> ComposeView {
        request.composeView(account: accounts.first, openedOn: .chat, onOutcome: { _ in })
    }

    @Test("The one presenter opens the agent's new email from the account the host gives it, the bound From account")
    func presenterOpensANewEmailFromTheAccountGiven() {
        let second = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: ["david@example.com"], cc: [], bcc: [], subject: "Friday",
            body: "Friday works", origin: ComposeOrigin(sessionKey: "chat", screen: .chat, fromAccountId: second.id))
        let bound = request.composeView(account: second, onOutcome: { _ in })
        #expect(bound.account?.id == second.id, "the card sends from the account given, never the primary")
        let control = request.composeView(account: Self.me, onOutcome: { _ in })
        #expect(control.account?.id == Self.me.id && Self.me.id != second.id, "control: another account given, another From")
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

    @Test("The AI Suggestion's card carries the whole suggestion the chat shows: its email, its text version and its change command")
    func readyCardCarriesTheWholeSuggestion() {
        let email = Self.groupEmail()
        let shown = ReplyResult(body: "Hi Alex,\n\nTuesday works.", textMessage: "Tuesday works", changeCommand: "make it shorter")
        let ready = ChatReadyReply(message: email, suggestion: shown, accounts: [Self.me])
        #expect(ready.suggestion == shown, "control: the ready reply holds the suggestion as shown")
        let compose = ready.composeView(openedOn: .chat, onOutcome: { _ in })
        // An edit in the card starts from this value and is stored only over it, so a part missing
        // (its change command) would make the card's edit differ from what is stored.
        #expect(compose.suggestion == shown, "the card opens on the suggestion as shown: \(String(describing: compose.suggestion))")
    }

    /// The reply request the AI reply tool opens for `arguments`, asked in the chat's sheet, on an
    /// email from sender@example.com to the user (test@example.com) and team@example.com.
    private static func agentReplyRequest(
        _ arguments: [String: JSONValue]
    ) async throws -> (request: AgentToolRouter.ComposeRequest, accounts: [Account]) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        let account = try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "r1", subject: "Plans", to: "test@example.com, team@example.com")
        await translator.seed(header.id, as: 1)
        let tool = EmailReplyTool(context: ToolContext(db: db, translator: translator, router: router))
        // Asked in the chat view, which takes the request (ADR-IOS-053 Phase 2).
        let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
        let invocation = ToolInvocation(composeOrigin: asked)
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

    /// The reply request the field's compose opens on the same email, with who was chosen in Reply
    /// to as it was sent (nil: nobody, Reply All); its email is written by a stand-in request that
    /// changes no recipients.
    private static func fieldReplyRequest(
        onlyTo: [String]?
    ) async throws -> (request: AgentToolRouter.ComposeRequest, accounts: [Account]) {
        let db = try TestDatabase.make()
        let router = AgentToolRouter()
        let account = try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "r1", subject: "Plans", to: "test@example.com, team@example.com")
        let compose = ChatFieldCompose(
            context: ToolContext(db: db, translator: MockChatIdTranslator(), router: router),
            composeText: { _, _, _, _ in
                guard let written = AIService.parseInlineEditResponse(ComposeEditJSON.make(
                    response: "Done.", subject: "Re: Plans", body: "Hi,\n\nFriday works.\n\nMe",
                    textMessage: "Friday works", changeCommand: "")) else {
                    throw InlineEditFailure(message: "control: the stand-in answer parses")
                }
                return written
            })
        let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
        let invocation = ToolInvocation(fieldReply: ChatFieldReply(email: header, onlyTo: onlyTo), composeOrigin: asked)
        let task = Task { @MainActor in await compose.reply("Friday works", invocation: invocation) }
        defer { task.cancel() }
        var pending: AgentToolRouter.ComposeRequest?
        let host = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = router.takeCompose(for: host)
            await Task.yield()
        }
        let req = try #require(pending, "the field's compose opens a reply")
        req.onOutcome(.cancelled)
        _ = await task.value
        return (req, [account])
    }

    @Test("The field's reply follows the same rule: Reply All to everyone, a plain reply to the people chosen as it was sent")
    func fieldReplyFollowsTheTarget() async throws {
        let (chosen, chosenAccounts) = try await Self.fieldReplyRequest(onlyTo: [Self.david.address])
        #expect(chosen.isFieldsOwnReply, "control: the field's own card")
        #expect(chosen.mode == .reply && !chosen.isReplyAll && chosen.to == [Self.david.address] && chosen.cc.isEmpty && chosen.bcc.isEmpty,
                "the request itself is the plain reply to David")
        #expect(chosen.subject == ThreadUtils.replySubject(for: "Plans"), "the reply subject")
        let toChosen = Self.card(agent: chosen, accounts: chosenAccounts)
        #expect(!toChosen.isReplyAll, "Replying only to David is a plain reply")
        #expect(toChosen.prefillTo == [Self.david.address] && toChosen.prefillCc == [] && toChosen.prefillBcc == [],
                "Replying only to David: nobody else, seen or hidden")

        let (req, accounts) = try await Self.fieldReplyRequest(onlyTo: nil)
        let toEveryone = Self.card(agent: req, accounts: accounts)
        #expect(req.isReplyAll && toEveryone.isReplyAll, "nobody chosen: Reply All")
        #expect(toEveryone.prefillTo == req.to && toEveryone.prefillCc == req.cc && toEveryone.prefillBcc == req.bcc,
                "nobody chosen: the card keeps the request's recipients")
    }

    @Test("A reply the agent widens is still Reply All: its recipients contain the whole audience")
    func agentReplyThatAddsPeopleIsStillReplyAll() async throws {
        let (widened, accounts) = try await Self.agentReplyRequest([
            "add_cc": .array([.string("extra@example.com")]),
            "add_bcc": .array([.string("hidden@example.com")]),
        ])
        #expect(widened.to.contains("sender@example.com") && widened.cc.contains("extra@example.com") && widened.bcc == ["hidden@example.com"],
                "the agent added a Cc and a Bcc and kept everyone")
        let compose = Self.card(agent: widened, accounts: accounts)
        #expect(compose.isReplyAll, "everyone in the Reply All audience is on it, plus people the agent added: Reply All")
        #expect(compose.prefillTo == widened.to && compose.prefillCc == widened.cc && compose.prefillBcc == widened.bcc,
                "the card keeps the agent's recipients")

        let (widenedNarrowed, otherAccounts) = try await Self.agentReplyRequest([
            "add_cc": .array([.string("extra@example.com")]),
            "remove_recipients": .array([.string("team@example.com")]),
        ])
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
        let (moved, accounts) = try await Self.agentReplyRequest([
            "remove_recipients": .array([.string("team@example.com")]),
            "add_cc": .array([teamLead]),
        ])
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

        // The narrowed control: the agent names someone else in Cc and leaves team@example.com out.
        let otherLead: JSONValue = .dictionary(["name": .string("Team Lead"), "email": .string("lead@example.com")])
        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest([
            "remove_recipients": .array([.string("team@example.com")]),
            "add_cc": .array([otherLead]),
        ])
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
                subject: edited.subject, body: "Friday works", origin: ComposeOrigin(sessionKey: "chat", screen: .chat),
                isReplyAll: edited.isReplyAll)
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
        let (everyone, accounts) = try await Self.agentReplyRequest([:])
        #expect(everyone.fieldReply == nil, "control: asked for in the sheet, the request carries no field choice")
        let all = Self.card(agent: everyone, accounts: accounts)
        #expect(all.isReplyAll, "the agent's reply goes to the whole audience")
        #expect(all.prefillTo == everyone.to && all.prefillCc == everyone.cc)

        let (widened, widenedAccounts) = try await Self.agentReplyRequest(["add_cc": .array([.string("extra@example.com")])])
        let compose = Self.card(agent: widened, accounts: widenedAccounts)
        #expect(compose.isReplyAll, "someone added, everyone kept: Reply All")
        #expect(compose.prefillTo == widened.to && compose.prefillCc == widened.cc, "the open chat keeps everyone the agent chose")

        let (narrowed, narrowedAccounts) = try await Self.agentReplyRequest(
            ["remove_recipients": .array([.string("team@example.com")])])
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
        // The field is the chat's bottom bar, so the strip under it blurs as in Messages; a plain
        // inset or a sibling over the scroll view has no scroll-edge effect.
        #expect(Self.count(".safeAreaBar(edge: .bottom, spacing: 0) {", in: chat) == 1, "the field is the bottom bar")
        #expect(Self.count(".safeAreaInset(edge: .bottom", in: chat) == 0)
        #expect(Self.count("ZStack(alignment: .bottom)", in: chat) == 0, "no field floating over the chat")
        // The bar holds only the slot; the field is drawn on the page right over it. The bar's
        // UIKit container takes touches only inside its own bounds, so a panel opened out of it
        // could not be touched above the slot.
        let chatCode = try Self.code("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count(".safeAreaBar(edge: .bottom, spacing: 0) { if thread.newest != nil { Color.clear.frame(height: pillHeight) } } .overlay(alignment: .bottom) { if let newest = thread.newest { pill(on: newest) .onGeometryChange(", in: chatCode) == 1,
                "the field is drawn on the page over the bar's slot")
        #expect(Self.count("pill(on: newest)", in: chatCode) == 1, "one field")
        // The panel's own dim stays drawn but takes no touch in the chat view: a tap outside the
        // panel reaches the page's dim.
        let panel = try Self.code("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count(".frame(width: 3000, height: 3000) .contentShape(Rectangle()) .onTapGesture { withAnimation(expandSpring) { isExpanded = false } } .allowsHitTesting(replyField == nil)", in: panel) == 1)
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

    @Test("Every open field bar draws the one row, and the collapsed Chat pill keeps its size")
    func everyOpenBarSharesTheRow() throws {
        // The chat's reply field, the opened pill's input bar (inbox, edit mode over a draft and
        // the per-message pill are this one view) and the tutorial's copy read the same values.
        let field = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        let pill = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let tutorial = try Self.source("TabMail/Views/Tutorial/TutorialChatInputBar.swift")
        #expect(Self.count("ChatFieldBarRow {", in: field) == 1)
        #expect(Self.count("ChatFieldBarRow {", in: pill) == 1, "the opened pill's input bar")
        #expect(Self.count("ChatFieldBarRow {", in: tutorial) == 1)
        // (The tutorial's tooltip keeps its own padding.)
        for (name, text) in [("field", field), ("pill", pill)] {
            #expect(Self.count("HStack(spacing: 10) { micButton", in: text) == 0, "\(name): no centred row of its own")
            #expect(Self.count(".padding(.horizontal, 14) .padding(.vertical, 10)", in: text) == 0, "\(name): no old bar padding")
        }
        // The collapsed Chat pill: today's padding and wand.
        #expect(Self.count(".padding(.horizontal, 22) .padding(.vertical, 12)", in: pill) == 1)
        #expect(Self.count("ChatPillWandIcon(isWorking: isWorking || ActiveAgentTracker.shared.anyWorking, size: 24)", in: pill) == 1)
        // One line is the line plus the padding above and below; the corner is half of it.
        #expect(ChatViewLayout.fieldLineHeight + 2 * ChatViewLayout.fieldVerticalPadding == 42)
        #expect(ChatViewLayout.fieldCornerRadius * 2 == 42)
    }

    @Test("A one-time tip above the field says what the drag up shows, and a tap or the first drag ends it")
    func fieldDragTip() throws {
        #expect(ChatFieldDragTip.text == "Drag up to see what you asked TabMail about this conversation.")
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // Inline above the field (its arrow points down at it), never a popover, never over the
        // open panel or the tutorial.
        #expect(Self.count(".popoverTip(", in: chat) == 0)
        #expect(Self.count(".overlay(alignment: .top) { if !chatExpanded && !TutorialCoordinator.shared.isRunning { Color.clear .frame(height: 0) .overlay(alignment: .bottom) { ViewThatFits(in: .vertical) { TipView(ChatFieldDragTip(), arrowEdge: .bottom)", in: chat) == 1)
        // On the whole stack, the one the side inset pads, so it sits above "Replying only to" and
        // the no-reply notice rather than over them: hung by its bottom from the stack's top edge.
        // Only while the whole card fits between the header and the stack: otherwise nothing, so
        // the tip waits for room and keeps its one showing.
        // VoiceOver can still reach a waiting card (tabmail-ios#1255): hiding the choice while the
        // stand-in shows did not take.
        #expect(Self.count("TipView(ChatFieldDragTip(), arrowEdge: .bottom) .fixedSize(horizontal: false, vertical: true) // Debug UI tests only: where the whole card is (`ChatFieldDragMarker`). .modifier(ChatFieldDragMarker.TipCard(roomTop: headerBottom, roomBottom: pillTop)) Color.clear.frame(height: 0) // Debug UI tests only: the tip waits for room (`ChatFieldDragMarker`). .modifier(ChatFieldDragMarker.TipWait()) } // VoiceOver can still reach a card waiting for room (tabmail-ios#1255). .frame(height: tipRoom, alignment: .bottom) } } } .padding(.horizontal, chatExpanded ? 0 : ChatViewLayout.fieldSideInset)", in: chat) == 1)
        let room = try Self.body(of: "private var tipRoom: CGFloat {", in: chat)
        #expect(Self.count("let room = pillTop - headerBottom return room.isFinite ? max(0, room) : 0", in: room) == 1,
                "the measured space between the header's bottom and the stack's top; none until measured")
        // A tap on the field focuses it, a drag starts, or the panel opens: each ends the tip for good.
        // The panel opening also cuts off a drag held on the field.
        #expect(Self.count(".onChange(of: chatInputFocused) { _, focused in if focused { ChatFieldDragTip.close() } }", in: chat) == 1)
        #expect(Self.count(".onChange(of: chatExpanded) { _, expanded in if expanded { ChatFieldDragTip.close(); fieldPanCut() } }", in: chat) == 1)
        let changed = try Self.body(of: "private func fieldDragChanged(_ dragging: Bool) {", in: chat)
        let dragStart = try #require(changed.range(of: "if dragging {"))
        let dragEnd = try #require(changed[dragStart.upperBound...].range(of: "return }"))
        guard dragStart.upperBound <= dragEnd.lowerBound else { return }
        #expect(Self.count("ChatFieldDragTip.close()", in: String(changed[dragStart.upperBound..<dragEnd.lowerBound])) == 1,
                "once per drag, at its start, not on every frame")
        #expect(Self.count("ChatFieldDragTip.close()", in: chat) == 3)
        let tips = try Self.source("TabMail/Views/Components/AppTips.swift")
        let start = try #require(tips.range(of: "struct ChatFieldDragTip: Tip {"))
        let end = try #require(tips[start.upperBound...].range(of: "struct ComposeChatPillTip: Tip {"))
        let tip = String(tips[start.upperBound..<end.lowerBound])
        #expect(Self.count("MaxDisplayCount(1)", in: tip) == 1, "shown once")
        #expect(Self.count("invalidate(reason: .actionPerformed)", in: tip) == 1)
        #expect(Self.count("OnboardingTipGate.$onboardingComplete", in: tip) == 1, "today's tip gate")
    }

    @Test("TipKit is configured in one place, and a release build keeps daily tips on the default datastore and none in screenshot mode")
    func tipKitConfiguration() throws {
        let app = try Self.source("TabMail/App/TabMailApp.swift")
        let start = try #require(app.range(of: "@MainActor private static func configureTips() {"))
        let end = try #require(app[start.upperBound...].range(of: " init() {"))
        let tips = String(app[start.upperBound..<end.lowerBound])
        #expect(Self.count("Self.configureTips()", in: app) == 1, "once, at launch")
        #expect(Self.count("Tips.configure(", in: tips) == 3, "control: the debug, screenshot and everyday branches")
        #expect(Self.count("Tips.configure(", in: app) == 3, "the app's launch configures TipKit only there")
        // What a release build compiles: the debug UI tests' variants are not in it.
        let release = Self.releaseView(of: tips)
        #expect(Self.count("let usesFieldDragTipStore = false", in: release) == 1)
        #expect(Self.count("if (ScreenshotMode.isActive || ScreenshotMode.isSplashMode) && !usesFieldDragTipStore { // Suppress all tips in screenshot mode try? Tips.configure([ .datastoreLocation(.applicationDefault) ]) Tips.hideAllTipsForTesting() return }", in: release) == 1,
                "screenshot mode hides every tip")
        #expect(Self.count("let tipStore = Tips.ConfigurationOption.DatastoreLocation.applicationDefault do { try Tips.configure([ .displayFrequency(.daily), .datastoreLocation(tipStore) ]) } catch { } }", in: release) == 1,
                "daily pacing on the app's default datastore")
        for debugOnly in ["showTipsForTesting", ".immediate", "resetDatastore", "fieldDragTipTestStore", "preconditionFailure", "OnboardingTipGate"] {
            #expect(Self.count(debugOnly, in: release) == 0, "\(debugOnly) is in debug builds only")
            #expect(Self.count(debugOnly, in: tips) > 0, "control: \(debugOnly) is in the debug build")
        }
        #expect(Self.count("Tips.configure(", in: release) == 2, "a release build compiles the screenshot and everyday branches only")
        // A release launch reaches it: init calls it outside every conditional block. (Counted
        // in init, not by `releaseView` over the file: a comment there names `#if DEBUG`.)
        let launch = try #require(app.range(of: " init() {"))
        let call = try #require(app[launch.upperBound...].range(of: "Self.configureTips()"))
        let beforeCall = String(app[launch.upperBound..<call.lowerBound])
        let opened = Self.count("#if ", in: beforeCall)
        let closed = Self.count("#endif", in: beforeCall)
        #expect(opened == closed, "a release launch configures TipKit")
    }

    @Test("The drag is the UIKit field pan; its swell resets with the pill's spring however it ends; it holds the freeze once per drag")
    func fieldDragWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The SwiftUI drag is gone: a simultaneous SwiftUI drag left the field's text view the
        // touch, so a short drag ended as a tap and focused the field.
        #expect(Self.count("DragGesture", in: chat) == 0)
        #expect(Self.count("@GestureState", in: chat) == 0)
        #expect(Self.count("fieldDragGesture", in: chat) == 0)
        #expect(Self.count("@State private var fieldDrag = ChatFieldDrag.Model()", in: chat) == 1)
        #expect(Self.count("@State private var fieldSwell", in: chat) == 0)
        // The drag's progress is written by the pan's two calls and read only inside modifiers, so a
        // moving finger never rebuilds the chat's body or the reply field.
        #expect(Self.count("fieldDrag.progress", in: chat) == 2, "only the two writes below")
        #expect(Self.count("drag: fieldDrag,", in: chat) == 1, "the field gets the model, not a swell")
        #expect(Self.count(".modifier(ChatFieldDrag.Swell(model: fieldDrag, sign: -1))", in: chat) == 1,
                "the swell taken back out of the layout")
        // Taking the swell back out leaves a floating-point remainder at some swells (UI run
        // 2026-11-22): the bar's height moves only by a change a screen can show.
        #expect(Self.count("if !chatExpanded, Self.pillHeightMoved(from: pillHeight, to: height) { pillHeight = height }", in: chat) == 1,
                "the measured height sets the bar's height only once it really moved")
        // Every write to the bar's height, whatever it is set to: the declaration and that one write.
        let heightWrites = try NSRegularExpression(pattern: #"\bpillHeight\s*[-+*/]?=(?!=)"#)
        let writes = heightWrites.numberOfMatches(in: chat, range: NSRange(chat.startIndex..., in: chat))
        #expect(writes == 2, "the declaration and the guarded write: nothing else sets the bar's height")
        #expect(Self.count("$pillHeight", in: chat) == 0, "and no binding hands it to a writer elsewhere")
        #expect(Self.count("_pillHeight", in: chat) == 0, "nor is it written through its storage")
        let referenceWrites = try NSRegularExpression(pattern: #"&\s*(?:self\s*\.\s*)?[_$]?pillHeight\b"#)
        let byReference = referenceWrites.numberOfMatches(in: chat, range: NSRange(chat.startIndex..., in: chat))
        #expect(byReference == 0, "nor handed on by reference, qualified or not")
        let control = "swap(&self.pillHeight, &next)"
        let controlCaught = referenceWrites.numberOfMatches(in: control, range: NSRange(control.startIndex..., in: control))
        #expect(controlCaught == 1, "control: the reference check sees a qualified inout write")
        let fieldBar = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        #expect(Self.count(".modifier(ChatFieldDrag.Swell(model: field.drag, sign: 1))", in: fieldBar) == 1, "the swell on the glass")
        let editor = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count(".modifier(ChatFieldDragMarker.InputFieldBuilt())", in: editor) == 1,
                "the swipe UI tests' editor build count is taken on the reply field's own editor")
        let replyField = try Self.source("TabMail/Views/Chat/ChatReplyField.swift")
        #expect(Self.count(".progress", in: fieldBar) == 0 && Self.count(".progress", in: replyField) == 0,
                "the reply field passes the model on and never reads the drag's progress, so a moving finger does not rebuild its editor")
        #expect(Self.count(".modifier(ChatFieldDragMarker.Field(model: fieldDrag))", in: chat) == 1)
        let moved = try Self.body(of: "private func fieldDragMoved(_ drag: ChatHorizontalPan.Sample) {", in: chat)
        #expect(Self.count("fieldDrag.progress = ChatFieldDrag.progress(translation: drag.travel) }", in: moved) == 1)
        #expect(Self.count("chatExpanded", in: moved) == 0, "a move only swells the field")
        // A cancelled drag resets too, so the field never stays swollen; only a finished drag opens.
        let ended = try Self.body(of: "private func fieldDragEnded(_ drag: ChatHorizontalPan.Sample, finished: Bool) {", in: chat)
        #expect(Self.count("let opens = finished && ChatFieldDrag.opens(letGo: drag)", in: ended) == 1)
        #expect(Self.count("withAnimation(Self.pillSpring) { fieldDrag.progress = ChatFieldDrag.Progress() if opens { chatExpanded = true } }", in: ended) == 1)
        // The freeze, under its own id, from the gesture state, so a cancelled drag releases.
        #expect(Self.count(".modifier(ChatFieldDrag.Watch(model: fieldDrag) { fieldDragChanged($0) })", in: chat) == 1)
        let dragModifiers = try Self.source("TabMail/Views/Chat/ChatFieldBarRow.swift")
        #expect(Self.count("content.onChange(of: model.progress.isDragging) { _, dragging in changed(dragging) }", in: dragModifiers) == 1)
        #expect(Self.count("content.padding(.top, sign * (model?.progress.swell ?? 0))", in: dragModifiers) == 1)
        let changed = try Self.body(of: "private func fieldDragChanged(_ dragging: Bool) {", in: chat)
        #expect(Self.count("ChatSwipeHold.shared.begin(Self.fieldDragHoldId)", in: changed) == 1)
        // Every let-go holds through the settle and the freeze rule's cooldown, on the swipes' own
        // settle (a newer begin cancels it).
        #expect(Self.count("ChatSwipeHold.shared.release(Self.fieldDragHoldId, after: Self.fieldDragSettle + ChatViewLayout.freezeCooldown)", in: changed) == 1)
        #expect(Self.count("ChatSwipeHold.shared.releaseNow(Self.fieldDragHoldId)", in: chat) == 1, "and if the chat goes away")
        // Never over the open panel, and in the tutorial only at the step whose move is the drag up.
        #expect(Self.count("let opensPanel = !chatExpanded && (!TutorialCoordinator.shared.isRunning || move == .dragUp)", in: chat) == 1)
        #expect(Self.count(".gesture(ChatFieldPan(isEnabled: opensPanel, cut: fieldPanCut, moved: fieldDragMoved, ended: fieldDragEnded))", in: chat) == 1)
        #expect(Self.count("simultaneousGesture", in: chat) == 0)
        // One bridge for every chat pan: the field's drag reads the swipes' sample and outcome, with
        // no delivery of its own.
        let swipe = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        #expect(Self.count("ChatHorizontalPan.deliver(recognizer, moved: { moved(coordinator.share($0)) }, ended: { coordinator.letGo() ended(coordinator.share(ChatFieldDrag.letGo($0, rested: recognizer.restedBeforeLift), atLetGo: true), $1) })", in: swipe) == 1,
                "the field's pan hands on only the field's share of each sample (`ChatFieldPan.Coordinator.share`), its let-go at rest after a hold (`ChatFieldDrag.letGo`)")
        // The rest is read on the touches' clock from the last move to the lift; a touch coming
        // down is not a move (a second finger landing during a hold leaves it a hold), and each
        // new drag starts with nothing.
        #expect(Self.count("override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { moved(at: event.timestamp) super.touchesMoved(touches, with: event) }", in: swipe) == 1)
        #expect(Self.count("override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(at: event.timestamp) super.touchesEnded(touches, with: event) }", in: swipe) == 1)
        #expect(Self.count("override func touchesBegan(", in: swipe) == 0)
        #expect(Self.count("override func reset() { super.reset() lastMove = nil lift = nil }", in: swipe) == 1)
        #expect(Self.count("static func deliver(", in: swipe) == 2, "the bridge's, and the swipe's sideways reading of it")
        #expect(Self.count("recognizer.translation(in:", in: swipe) == 1, "one place samples a pan")
        // VoiceOver opens the panel with a named action on the text field it focuses, offered only
        // while the panel is closed, never on the field's container.
        #expect(ChatViewConfig.showChatActionName == "Show TabMail chat")
        #expect(Self.count("showChat: opensPanel ? { withAnimation(Self.pillSpring) { chatExpanded = true } } : nil", in: chat) == 1)
        #expect(Self.count("Button(ChatViewConfig.showChatActionName)", in: chat) == 0, "not on the container")
        let bar = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        // One helper, only while the panel is closed.
        #expect(Self.count("func showChatAction(_ showChat: (() -> Void)?, isExpanded: Bool) -> some View { accessibilityActions { if let showChat, !isExpanded { Button(ChatViewConfig.showChatActionName) { showChat() } } } }", in: bar) == 1)
        // On the text field, and on the hint the field shows while the email is written (the drag
        // stays on then).
        #expect(Self.count("inputField(placeholder: hasTabMailSession ? ChatReplyField.writePlaceholder : \"Sign in to reply\", showChat: field.showChat, focus: .replyField)", in: bar) == 1)
        #expect(Self.count("Text(ChatReplyField.writePlaceholder) .foregroundStyle(Theme.textSecondary) .lineLimit(1) .frame(maxWidth: .infinity, alignment: .leading) // The drag stays on while the email is written: so does its VoiceOver action. .showChatAction(field.showChat, isExpanded: isExpanded)", in: bar) == 1)
        // While dictating, VoiceOver cannot reach the hidden text field: the waveform carries it.
        let pill = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count(".accessibilityHidden(dictation.isActive) .showChatAction(showChat, isExpanded: isExpanded)", in: pill) == 1)
        #expect(Self.count(".onTapGesture { dictation.finish() } .showChatAction(showChat, isExpanded: isExpanded)", in: pill) == 1)
        // A field built without the action offers none (the panel open, the tutorial).
        #expect(ChatReplyField(alternative: nil).showChat == nil)
        #expect(ChatReplyField(alternative: nil, showChat: {}).showChat != nil)
        // The reply field and the panel's input are two text fields, each with its own focus value,
        // and the panel opening moves a typed-in field's keyboard to the panel's input (mock v15
        // H2; on screen: `ChatSwipeUITests`, the drags that open the panel from the focused field).
        // Read in code only, so a commented-out line does not count.
        let pillCode = try Self.code("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let barCode = try Self.code("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        #expect(Self.count("@FocusState private var focusedInput: InputFocus?", in: pillCode) == 1)
        #expect(Self.count(".focused($focusedInput, equals: focus)", in: pillCode) == 1)
        #expect(Self.count(".focused(", in: pillCode) == 1, "the input field is the pill's one focusable view")
        #expect(Self.count("focus: .replyField", in: barCode) == 1, "the reply field is the only field focused as the reply field")
        // The first statement of the branch that opens the panel.
        #expect(Self.count(".onChange(of: isExpanded) { _, expanded in autoStartTask?.cancel() autoStartTask = nil if expanded { if focusedInput == .replyField { focusedInput = .panel } dismissAgentToast()", in: pillCode) == 1,
                "the hand-over opens the branch that opens the panel")
        #expect(Self.count("focusedInput = .panel", in: pillCode) == 1, "the opening is the only hand-over")
    }

    @Test("The settle lasts the pill spring's own settling duration, which drives the panel and the swell too")
    func fieldDragSettleIsThePillSpring() throws {
        let spring = ChatThreadView.pillSpringModel
        #expect(spring.settlingDuration > 0, "control: the spring settles")
        #expect(ChatThreadView.fieldDragSettle == .seconds(spring.settlingDuration))
        #expect(ChatThreadView.fieldDragSettle > .zero)
        #expect(ChatViewLayout.freezeCooldown > .zero, "control: the freeze rule's cooldown")
        #expect(ChatViewLayout.freezeCooldown + .seconds(ChatViewLayout.swipeSpringResponse) == ChatViewLayout.swipeSettleHold,
                "the same cooldown the swipes' hold carries")
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("private static let pillSpring = Animation.spring(pillSpringModel)", in: chat) == 1)
        #expect(Self.count("static let fieldDragSettle: Duration = .seconds(pillSpringModel.settlingDuration)", in: chat) == 1)
    }

    @Test("A new email's arrival re-pins the landing in the rise, only after the landing and not for the user's own email")
    func arrivalWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", in: chat) == 1)
        #expect(Self.count(".onChange(of: thread.items.last?.id) { old, new in guard ChatArrival.isArrival(landed: didInitialScroll, oldNewest: old, newNewest: new, newestIsOwn: thread.items.last?.isOwn ?? false), let target = scrollTarget else { return } withAnimation(ChatArrival.animation(ChatArrival.style(reduceMotion: reduceMotion))) { proxy.scrollTo(target.id, anchor: target.anchor) } }", in: chat) == 1)
        #expect(Self.count(".animation(ChatArrival.animates(landed: didInitialScroll, newestIsOwn: thread.items.last?.isOwn ?? false) ? ChatArrival.animation(ChatArrival.style(reduceMotion: reduceMotion)) : nil, value: thread.items.last?.id)", in: chat) == 1)
        #expect(Self.count("ChatArrival.style(reduceMotion: reduceMotion), isArrivalRow: item.id == thread.items.last?.id && ChatArrival.animates(landed: didInitialScroll, newestIsOwn: item.isOwn)", in: chat) == 1)
        #expect(Self.count("reduceMotion: false", in: chat) == 0 && Self.count("reduceMotion: true", in: chat) == 0)
    }

    @Test("The agent's status on a Send shows above the field, outside its glass, on both chat screens")
    func statusLineAboveTheField() throws {
        let field = try Self.code("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        // The field draws no status of its own: it hands the line to the screen.
        #expect(Self.count("Text(workingStatus", in: field) == 0, "no status inside the field's glass")
        #expect(Self.count("private func liveReplyFieldBar(_ field: ChatReplyField) -> some View { ChatFieldBarRow {", in: field) == 1,
                "the field's bar is its one row")
        #expect(Self.count(".preference(key: ChatFieldStatusKey.self, value: sentWorking ? (workingStatus.isEmpty ? \"Thinking...\" : workingStatus) : nil) .modifier(ChatFieldDrag.Swell(model: field.drag, sign: 1))", in: field) == 1)
        // Each screen shows it in the stack above the field, so its bar, and the chat, move up for it.
        for path in ["TabMail/Views/Chat/ChatThreadView.swift", "TabMail/Views/Chat/ChatNewThreadView.swift"] {
            let screen = try Self.code(path)
            #expect(Self.count("if let fieldStatus { ChatFieldStatusLine(text: fieldStatus) .transition(.opacity) } DynamicIslandChat(", in: screen) == 1, "\(path): the line right above the field")
            #expect(Self.count(".onPreferenceChange(ChatFieldStatusKey.self) { status in withAnimation(", in: screen) == 1, "\(path)")
            #expect(Self.count("fieldStatus = status }", in: screen) == 1, "\(path)")
        }
    }

    @Test("Only one status reaches the screen: the first field's")
    func statusKeyKeepsTheFirst() {
        var value: String? = nil
        ChatFieldStatusKey.reduce(value: &value) { "Thinking..." }
        #expect(value == "Thinking...")
        ChatFieldStatusKey.reduce(value: &value) { "Searching email" }
        #expect(value == "Thinking...")
        ChatFieldStatusKey.reduce(value: &value) { nil }
        #expect(value == "Thinking...")
        #expect(ChatFieldStatusKey.defaultValue == nil)
    }

    @Test("The open panel closes like a sheet: past the close distance, on the let-go only")
    func panelPull() {
        let close = ChatViewLayout.panelCloseDistance
        #expect(close == ChatViewLayout.fieldDragOpenDistance, "opening and closing go the same distance")
        // At rest at the top of the history the offset is minus the top inset: not pulled.
        #expect(ChatPanelPull.pastTop(offsetY: -40, topInset: 40) == 0)
        #expect(ChatPanelPull.pastTop(offsetY: 200, topInset: 40) == 0, "scrolled down into the history")
        #expect(ChatPanelPull.pastTop(offsetY: -40 - close, topInset: 40) == close)
        #expect(!ChatPanelPull.isPastClose(offsetY: -40 - close + 1, topInset: 40))
        #expect(ChatPanelPull.isPastClose(offsetY: -40 - close, topInset: 40))
        // Only the finger's let-go closes, and only while pulled past the distance.
        #expect(ChatPanelPull.closesOnLetGo(from: .interacting, to: .decelerating, pulledPastClose: true))
        #expect(ChatPanelPull.closesOnLetGo(from: .interacting, to: .idle, pulledPastClose: true))
        #expect(!ChatPanelPull.closesOnLetGo(from: .interacting, to: .decelerating, pulledPastClose: false))
        #expect(!ChatPanelPull.closesOnLetGo(from: .decelerating, to: .idle, pulledPastClose: true), "a bounce settling is not a let-go")
        #expect(!ChatPanelPull.closesOnLetGo(from: .tracking, to: .interacting, pulledPastClose: true))
        // The header: the drag, or a flick's predicted end.
        #expect(ChatPanelPull.headerCloses(translation: close, predictedEnd: 0))
        #expect(ChatPanelPull.headerCloses(translation: 10, predictedEnd: close))
        #expect(!ChatPanelPull.headerCloses(translation: close - 1, predictedEnd: close - 1))
        #expect(!ChatPanelPull.headerCloses(translation: -close * 2, predictedEnd: -close * 2), "a drag up does not close")
    }

    @Test("Both closes are the chat view's only and close the panel as Close does")
    func panelPullWiring() throws {
        let panel = try Self.code("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count(".gesture(DragGesture().onEnded { drag in if ChatPanelPull.headerCloses(translation: drag.translation.height, predictedEnd: drag.predictedEndTranslation.height) { withAnimation(expandSpring) { isExpanded = false } } }, isEnabled: replyField != nil)", in: panel) == 1)
        #expect(Self.count(".scrollBounceBehavior(replyField != nil ? .always : .basedOnSize)", in: panel) == 1)
        #expect(Self.count(".onScrollGeometryChange(for: Bool.self) { geo in ChatPanelPull.isPastClose(offsetY: geo.contentOffset.y, topInset: geo.contentInsets.top) } action: { _, pulled in historyPulledToClose = pulled }", in: panel) == 1)
        #expect(Self.count(".onScrollPhaseChange { old, phase in guard replyField != nil, ChatPanelPull.closesOnLetGo(from: old, to: phase, pulledPastClose: historyPulledToClose) else { return } historyPulledToClose = false withAnimation(expandSpring) { isExpanded = false } }", in: panel) == 1)
    }

    @Test("The tutorial tooltip's arrow points at the mic circle's centre")
    func tutorialArrowOnTheMic() {
        let micCentre = ChatViewLayout.fieldMicInset + ChatViewLayout.fieldMicSize / 2
        #expect(TutorialChatInputBar.tooltipArrowCenterX + TutorialChatInputBar.tooltipInset == micCentre)
    }

    @Test("The mic circle mirrors Send and draws in grays only: Send is the field's one colour")
    func micCircleGrays() throws {
        #expect(ChatViewLayout.fieldMicSize == ChatViewLayout.fieldSendSize)
        #expect(ChatViewLayout.fieldMicInset == ChatViewLayout.fieldSendInset)
        for dark in [false, true] {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            // A gray has (almost) no saturation; the accent's and red's are far above this.
            let colors = [(Palette.chatMicIdleFill, false), (Palette.chatMicIdleGlyph, false), (Palette.chatMicListeningFill, false),
                          (Palette.chatMicListeningStop, false), (Theme.accent, true)]
            for (color, isAccent) in colors {
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                UIColor(color).resolvedColor(with: traits).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                let gray = saturation < 0.1
                #expect(gray != isAccent, "saturation \(saturation), dark \(dark), accent \(isAccent) (the accent is the control)")
            }
            // Listening: black on white in light mode, white on black in dark mode.
            var fill: CGFloat = 0, stop: CGFloat = 0, alpha: CGFloat = 0
            UIColor(Palette.chatMicListeningFill).resolvedColor(with: traits).getWhite(&fill, alpha: &alpha)
            UIColor(Palette.chatMicListeningStop).resolvedColor(with: traits).getWhite(&stop, alpha: &alpha)
            let expectedFill: CGFloat = dark ? 1 : 0
            #expect(abs(fill - expectedFill) < 0.01 && abs(stop - (1 - expectedFill)) < 0.01, "fill \(fill), stop \(stop), dark \(dark)")
            // Idle: a soft gray circle, light in light mode and dark in dark mode, so it reads quieter
            // than the listening circle, with the mic in a gray that stands well apart from it.
            var idleFill: CGFloat = 0, idleGlyph: CGFloat = 0
            UIColor(Palette.chatMicIdleFill).resolvedColor(with: traits).getWhite(&idleFill, alpha: &alpha)
            UIColor(Palette.chatMicIdleGlyph).resolvedColor(with: traits).getWhite(&idleGlyph, alpha: &alpha)
            #expect(dark ? idleFill < 0.3 : idleFill > 0.8, "idle fill \(idleFill), dark \(dark)")
            #expect(abs(idleFill - fill) > 0.5, "idle fill \(idleFill), listening fill \(fill), dark \(dark)")
            #expect(abs(idleGlyph - idleFill) > 0.5, "idle glyph \(idleGlyph), idle fill \(idleFill), dark \(dark)")
        }
        // The idle circle is filled, with no outline ring.
        let row = try Self.source("TabMail/Views/Chat/ChatFieldBarRow.swift")
        let circleStart = try #require(row.range(of: "struct ChatMicCircle: View {"))
        let circleEnd = try #require(row[circleStart.upperBound...].range(of: "struct FieldButtonSlot: ViewModifier {"))
        let circle = String(row[circleStart.upperBound..<circleEnd.lowerBound])
        #expect(Self.count("strokeBorder", in: circle) == 0 && Self.count(".stroke(", in: circle) == 0, "no outline ring")
        #expect(Self.count(".fill(listening ? Palette.chatMicListeningFill : Palette.chatMicIdleFill)", in: circle) == 1)
        // Transcribing in the mic: its spinner in the mic's own gray, in place of the glyph.
        #expect(Self.count("if transcribing { DictationSpinner(tint: Palette.chatMicIdleGlyph, diameter: ChatViewLayout.fieldMicSpinnerSize) } else {", in: circle) == 1)
        #expect(ChatViewLayout.fieldMicSpinnerSize < ChatViewLayout.fieldMicSize)
        // Every field bar draws its mic as the circle and colours it nowhere else.
        let chat = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let micButton = try Self.body(of: "var micButton: some View {", in: chat)
        #expect(Self.count("ChatMicCircle(symbol: micSymbol, listening: micListening, transcribing: spinnerPlace == .mic)", in: micButton) == 1)
        #expect(Self.count(".accessibilityLabel(spinnerPlace == .mic ? \"Transcribing\" : micListening ? \"Stop dictation\" : \"Dictate\")", in: micButton) == 1)
        #expect(Self.count(".foregroundStyle", in: micButton) == 0, "the circle sets its own grays")
        let symbol = try Self.body(of: "var micSymbol: String {", in: chat)
        #expect(Self.count("if micListening { return \"stop.fill\" } return canDictate ? \"mic\" : \"mic.slash\"", in: symbol) == 1)
        let tutorial = try Self.source("TabMail/Views/Tutorial/TutorialChatInputBar.swift")
        #expect(Self.count("ChatMicCircle(symbol: \"mic\", listening: false)", in: tutorial) == 1)
    }

    @Test("Reply to, Forward and the chosen people reach the field and the compose card")
    func recipientsWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The field itself; the suggestion's rule takes them too (`shownSuggestion`, pinned above).
        #expect(Self.count("alternative: ChatReplyField.alternative(shown: shown), onlyTo: replyTarget.only,", in: chat) == 1, "the field knows the people chosen")
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
        #expect(Self.count("onFieldSend: { fieldSent($0) }, onFieldWritten: { await fieldMessageWritten() }, onAgentCompose: openAgentCompose, composeFromAccountId: viewModel.message?.accountId, composeHostCovered: isAnyPresentation)", in: chat) == 1,
                "the chat's pill binds the email's account as a new message's From and takes nothing while the chat is covered")
        // A new message's card opens from the account bound when the turn started, and records the
        // chat's screen, in the one presenter call.
        #expect(Self.count("req.composeView(account: navigationStore.accounts.first { $0.id == req.fromAccountId }, openedOn: composeScreen(answering: req.replyTo)) { outcome in", in: chat) == 1)
        // The card and fieldComposeOpened are set only for a request this chat's own pill took
        // (ADR-IOS-053 Phase 2; ChatComposeRoutingTests runs it with the inbox and the email screen mounted).
        #expect(Self.count("private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {", in: chat) == 1)
        // Read with comments blanked: the body's first line is a comment, and the next function's
        // doc comment would end it.
        let open = try Self.body(of: "private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {",
                                 in: try Self.code("TabMail/Views/Chat/ChatThreadView.swift"))
        #expect(open.hasPrefix(" guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } fieldComposeOpened = req.isFieldsOwnReply"),
                "a new email's bound account is looked up as the card is taken, before anything is set")
        #expect(open.hasSuffix(" agentCompose = req }"))
        #expect(Self.count("private func agentAnswered() { guard !fieldComposeOpened else { return }", in: chat) == 1)
        #expect(Self.count("fieldComposeOpened = true", in: chat) == 0)
        #expect(Self.count("if replyTo != nil { replyTarget = .replyAll }", in: chat) == 1, "a sent reply clears it")
        #expect(Self.count("ownAddresses: context.ownAddresses) { replyTarget = $0 }", in: chat) == 1, "Done sets it")
        // The names open who the reply goes to, from the thread's own header or, for a thread a
        // new email's chat hosts, from the chat's header (`ChatThreadHeader.asksReplyTo`).
        #expect(Self.count("ChatHeaderView(thread: thread) { openReplyTo() }", in: chat) == 1)
        #expect(Self.count("private func openReplyTo() { guard TutorialCoordinator.shared.admits(.other) else { return } showsReplyTo = true }", in: chat) == 1)
        #expect(Self.count("guard asks else { return } hostedHeader?.asksReplyTo = false openReplyTo() }", in: chat) == 1)
        #expect(Self.count("showsReplyTo = true", in: chat) == 1, "nothing else opens it")
        #expect(Self.count("Button { guard TutorialCoordinator.shared.admits(.other) else { return } forwardMessage = thread.newest }", in: chat) == 1)
        #expect(Self.count(".fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true, openedOn: composeScreen(answering: $0)) }", in: chat) == 1)
        #expect(Self.count(".onChange(of: thread.newest.map(ChatThread.copyKey)) { _, _ in replyTarget = .replyAll }", in: chat) == 1,
                "a new newest email resets the choice, even one whose UID matches the last")

        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("composeFromField(text, ChatFieldSend(message: message, onlyTo: field.onlyTo))", in: island) == 1,
                "the people chosen are read once, as the field's send starts")
        #expect(Self.count("runFieldCompose(fieldReply: send.fieldReply, fieldWordsKey: fieldWordsKey)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session, fieldWordsKey: fieldWordsKey), sessionKey: capturedSessionKey, fieldReply: fieldReply, composeOrigin: origin, fieldWordsKey: fieldWordsKey, fieldWritten: onFieldWritten)", in: island) == 1,
                "and travel with the request to the field's compose")
        // With the chat that asked, read as the send starts: the closed field's compose belongs to the
        // chat view, the pill's send to the screen that asked. No send to the agent carries a field's
        // request (the field writes the email, ADR-IOS-114 decision 10).
        #expect(Self.count("let origin = composeOrigin(sessionKey: capturedSessionKey, fieldReply: fieldReply)", in: island) == 1)
        #expect(Self.count("let origin = composeOrigin(sessionKey: capturedSessionKey, fieldReply: nil)", in: island) == 1)
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, composeOrigin: origin)", in: island) == 2,
                "the pill's send and its resume carry no field request")
        #expect(Self.count("return ComposeOrigin(sessionKey: sessionKey, screen: fieldReply != nil ? .chat : screen, fromAccountId: composeFromAccountId)", in: island) == 1)
        // A covered screen does not take: the pill takes only while its screen shows and nothing covers it.
        #expect(Self.count("let host = (composeHostShown ?? composeHostAppeared) && !composeHostCovered", in: island) == 1)
        // A recovered send keeps its origin: the resume carries the cut-off send's request and
        // origin (ChatReplyRecoveryTests sends it through the real chat).
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, origin: origin)", in: island) == 1)
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
        #expect(Self.count("pendingResume = .init(request: resumable.resumeRequest, origin: resume.origin)", in: island) == 1)
        #expect(Self.count("lastFailedSend = .init(text: text)", in: island) == 1)
        #expect(Self.count("sendAgentChat(failed.text)", in: island) == 1)
        // Re-send of the last turn sends its words again from the panel.
        #expect(Self.count("chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date()))", in: island) == 1)
        #expect(Self.count("resendLastUserMessage(text: msg.content, afterIndex: index)", in: island) == 1)
        // Rewind trims the later turns and sends the chosen turn again as a fresh turn, which names
        // the screen that asked (an earlier field turn's recipients choice is not kept with it).
        #expect(Self.count("rewindToMessage(text: msg.content, atIndex: index)", in: island) >= 1, "the menu's Rewind reaches the rewind")
        #expect(Self.count("private func rewindToMessage(text: String, atIndex index: Int) { trimForRewind(atIndex: index) lastFailedSend = nil sendAgentChat(text) }", in: island) == 1,
                "Rewind sends the turn again through the send that names the screen")
        #expect(Self.count("trimForResendLast(atIndex: index) lastFailedSend = nil sendAgentChat(text)", in: island) == 1)
        #expect(Self.count("replyField?.onlyTo", in: island) == 0 && Self.count("replyField?.isNoReply", in: island) == 0,
                "no send reads the field's choice later")
    }

    /// ADR-IOS-053 Phase 2: the census of the turns that can reach a compose tool. Every invocation
    /// the app builds is one of four: the pill's send and its resume, which name the screen that
    /// asked (every send, retry, resend, rewind and tutorial prompt goes through `sendAgentChat`);
    /// the chat view's closed field, whose compose names the chat view
    /// (`ChatFieldCompose`, ADR-IOS-114 decision 10 amended 2026-11-26); and the
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
        #expect(Self.count("composeOrigin: origin, fieldWordsKey:", in: island) == 1,
                "the closed field's compose names the screen that asked and keeps its words")
        #expect(Self.count("uiSink: SessionUISink(session: session), sessionKey: sessionKey, composeOrigin: origin)", in: island) == 2,
                "the panel's send and the resume name the screen that asked")
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
