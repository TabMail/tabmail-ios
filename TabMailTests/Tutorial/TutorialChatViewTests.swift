/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import UIKit
import GRDB
import Testing
@testable import TabMail

// The guided tutorial in the chat view (ADR-IOS-114 decision 13): its cards, the reply field's moves,
// the seeded chats it opens, and a run from Part 2 to the Chat View switch.

@Suite("Tutorial in the chat view — cards and moves")
struct TutorialChatViewContentTests {
    typealias Step = TutorialCoordinator.Step

    private static let allSteps: [Step] = [
        .starting, .archiveReceipt, .receiptArchived, .retagDailyTech, .actOnEmailDone,
        .replyToPriya, .makeTemplate, .reuseReplyDone, .askFlights, .askAnythingDone, .moreToAsk,
        .chatViewSwitch, .finished,
    ]
    private static let hosts: [TutorialCoachHost] = [
        .inbox, .compose(showingSuggestion: true), .compose(showingSuggestion: false), .message, .chat,
        .actionRules, .chatViewSwitch,
    ]

    private func card(
        _ step: Step, _ lesson: TutorialLesson, _ host: TutorialCoachHost, teachesChat: Bool = true,
        flightsAsked: Bool = false, replyEdited: Bool = false, isSending: Bool = false
    ) -> TutorialCoachContent? {
        TutorialCoachContent.make(
            step: step, lesson: lesson, host: host, flightsAsked: flightsAsked, replyEdited: replyEdited,
            isSending: isSending, teachesChat: teachesChat)
    }

    @Test("Today's run shows no chat or switch card; the chat view's run shows each where its step happens")
    func cardsWhereTheStepHappens() throws {
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps {
                for flightsAsked in [false, true] {
                    #expect(card(step, lesson, .chat, teachesChat: false, flightsAsked: flightsAsked) == nil, "\(step)")
                    #expect(card(step, lesson, .chatViewSwitch, teachesChat: false, flightsAsked: flightsAsked) == nil)
                }
            }
        }
        // Part 2: open Priya's email, then the ready reply, the request, the saved template, in her chat.
        let open = try #require(card(.replyToPriya, .reuseReply, .inbox))
        #expect(open.title.contains("Open Priya"))
        let ready = try #require(card(.replyToPriya, .reuseReply, .chat))
        #expect(ready.message.contains("Tap the AI Suggestion") && !ready.message.contains("Tap Send"))
        let ask = try #require(card(.makeTemplate, .reuseReply, .chat))
        #expect(ask.message.contains("tap Send"))
        #expect(card(.makeTemplate, .reuseReply, .inbox) != nil, "back in the inbox the card says where to go")
        for host in [TutorialCoachHost.chat, .inbox] {
            let saved = try #require(card(.reuseReplyDone, .reuseReply, host))
            #expect(saved.progressLine.hasSuffix("· done"))
            #expect(saved.buttons.map(\.action) == [.seeTemplate, .nextLesson])
        }
        // Part 3: the answer, in Jordan's chat, goes on to what else to ask.
        let answer = try #require(card(.askAnythingDone, .askAnything, .chat))
        #expect(answer.buttons.map(\.action) == [.showMoreToAsk])
        // Last step: the switch, after the three parts, closes with Finish.
        let last = try #require(card(.chatViewSwitch, .askAnything, .chatViewSwitch))
        #expect(last.progressLine == "Last step")
        #expect(last.message.contains("Chat View"))
        #expect(last.buttons.map(\.action) == [.finishChatViewSwitch])
        // Sending waits out in the chat as it does in the inbox.
        #expect(try #require(card(.replyToPriya, .reuseReply, .chat, isSending: true)).showsProgress)
    }

    @Test("In the chat view, compose still asks for the Edit, then Use Suggestion, then Send")
    func composeInTheChatView() throws {
        let first = try #require(card(.replyToPriya, .reuseReply, .compose(showingSuggestion: true)))
        #expect(first.message.contains("Edit"))
        let edited = try #require(card(.replyToPriya, .reuseReply, .compose(showingSuggestion: true), replyEdited: true))
        #expect(edited.message.contains("Use Suggestion"))
        let send = try #require(card(.replyToPriya, .reuseReply, .compose(showingSuggestion: false), replyEdited: true))
        #expect(send.title.contains("Send"))
    }

    @Test("Part 2 is \"Reply like a message\" in the chat view; every part card says n of 3 and none says lesson")
    func progressLines() {
        #expect(TutorialLesson.reuseReply.title(teachesChat: true) == "Reply like a message")
        #expect(TutorialLesson.reuseReply.title(teachesChat: false) == "Reuse a reply")
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps where step != .chatViewSwitch {
                for host in Self.hosts {
                    guard let c = card(step, lesson, host) else { continue }
                    #expect(c.progressLine.hasPrefix(
                        "\(lesson.rawValue) of \(TutorialLesson.allCases.count) · \(lesson.title(teachesChat: true))"))
                    let text = ([c.progressLine, c.title, c.message] + c.buttons.map(\.label)).joined(separator: " ")
                    #expect(!text.lowercased().contains("lesson"), "\(step) on \(host)")
                }
            }
        }
    }

    @Test("A chat-view card asks for Send only on a screen that has a Send button")
    func sendOnlyWhereItExists() {
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps {
                for flightsAsked in [false, true] {
                    for host in [TutorialCoachHost.inbox, .message, .actionRules, .chatViewSwitch] {
                        guard let c = card(step, lesson, host, flightsAsked: flightsAsked) else { continue }
                        #expect(!(c.title + " " + c.message).lowercased().contains("tap send"), "\(step) on \(host)")
                    }
                }
            }
        }
    }

    @Test("The reply field moves only in Priya's chat in the chat view: a tap on the AI Suggestion, then the request")
    func fieldMoves() {
        typealias C = TutorialCoordinator
        for step in Self.allSteps.map(Optional.some) + [nil] {
            for practice in [false, true] {
                for teachesChat in [false, true] {
                    let move = C.fieldMove(for: step, inPracticeChat: practice, teachesChat: teachesChat)
                    let expected: C.FieldMove?
                    switch step {
                    case .replyToPriya where practice && teachesChat: expected = .tapSuggestion
                    case .makeTemplate where practice && teachesChat: expected = .ask(.saveReplyAsTemplate)
                    default: expected = nil
                    }
                    #expect(move == expected, "\(String(describing: step)) practice=\(practice) chat=\(teachesChat)")
                }
            }
        }
    }

    @Test("In the chat view the template is asked for in the chat's field, never the inbox chat")
    func inboxChatPrompts() {
        typealias C = TutorialCoordinator
        #expect(C.chatPrompt(for: .makeTemplate, flightsAsked: false, teachesChat: true) == nil)
        #expect(C.chatPrompt(for: .makeTemplate, flightsAsked: false, teachesChat: false) == .makeTemplate)
        #expect(C.chatPrompt(for: .askFlights, flightsAsked: false, teachesChat: true) == .flights)
        #expect(C.chatPrompt(for: .moreToAsk, flightsAsked: true, teachesChat: true) == .whatCanYouDo)
        #expect(C.ChatPrompt.saveReplyAsTemplate.workingStatus == "Saving template")
        for prompt in C.ChatPrompt.allCases where prompt != .saveReplyAsTemplate {
            #expect(prompt.workingStatus == nil)
        }
    }

    @Test("A chat shows the card only for its own part: Priya's for part 2, Jordan's for part 3's answer")
    func chatCards() {
        for step in Self.allSteps.map(Optional.some) + [nil] {
            for practice in [false, true] {
                for source in [false, true] {
                    for teachesChat in [false, true] {
                        let shows = TutorialCoordinator.chatShowsCard(
                            step: step, teachesChat: teachesChat, holdsPracticeEmail: practice, holdsSourceEmail: source)
                        let expected: Bool
                        switch step {
                        case .replyToPriya, .makeTemplate, .reuseReplyDone: expected = teachesChat && practice
                        case .askAnythingDone: expected = teachesChat && source
                        default: expected = false
                        }
                        #expect(shows == expected, "\(String(describing: step)) p=\(practice) s=\(source) c=\(teachesChat)")
                    }
                }
            }
        }
    }

    /// The Sent bubble shows the AI Suggestion's text message, so the scripted edit must not
    /// turn the reply into something else.
    @MainActor
    @Test("The chat view's edit keeps the reply a yes, as its Sent bubble says; today's edit declines")
    func editKeepsTheMeaning() {
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "’", with: "'").lowercased() }
        #expect(TutorialCoordinator.editPrompt(teachesChat: false) == TutorialCoordinator.editPrompt)
        #expect(TutorialCoordinator.editPrompt(teachesChat: true) == TutorialCoordinator.chatViewEditPrompt)
        #expect(TutorialChatScript.editedReply(teachesChat: false) == TutorialChatScript.declinedReply)
        #expect(plain(TutorialChatScript.editedReply(teachesChat: true)).contains("i'm in"))
    }
}

// MARK: - The script and the seed

@Suite("Tutorial in the chat view — the scripted request and the seeded chats", .serialized, .processGlobalState)
struct TutorialChatViewSeedTests {
    @MainActor
    final class RecordingSink: AgentUISink {
        private(set) var delivered: [AgentToolRouter.ActionConfirmation] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            delivered.append(confirmation)
            confirmation.onRespond(false)
        }
    }

    @MainActor
    @Test("The field's request shows the real Create card for the reply as written, and never reaches the model")
    func requestShowsTheCreateCard() async throws {
        let sink = RecordingSink()
        var modelCalls = 0
        let response = try await TutorialChatScript.response(
            for: .saveReplyAsTemplate, invocation: ToolInvocation(uiSink: sink)
        ) {
            modelCalls += 1
            return nil
        }
        #expect(modelCalls == 0)
        #expect(response?.text.contains("No template made") == true, "Cancel saves nothing")
        try #require(sink.delivered.count == 1)
        #expect(sink.delivered[0].action == .templateCreate)
        try #require(sink.delivered[0].templates.count == 1)
        #expect(sink.delivered[0].templates[0].name == TutorialChatScript.chatViewTemplateName)

        let reply = "Count me in for the offsite."
        let sink2 = RecordingSink()
        _ = await TutorialChatScript.answer(.saveReplyAsTemplate, practiceReply: reply, invocation: ToolInvocation(uiSink: sink2))
        try #require(sink2.delivered.count == 1)
        try #require(sink2.delivered[0].templates.count == 1)
        #expect(sink2.delivered[0].templates[0].exampleReplyPreview.contains("Count me in"))
    }

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorial-chat-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func chat(_ messageId: String, pool: DatabasePool) throws -> ChatThread {
        let opened = try #require(try pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == DemoSeed.demoAccountId && Column("messageId") == messageId)
                .fetchOne(db)
        })
        let related = try ThreadDetection.findRelatedMessages(for: opened, in: pool)
        let account = DemoSeed.demoAccountId
        return ChatThread(
            members: [opened] + related,
            replyAddresses: { [$0.fromAddress] },
            ownAddresses: [DemoSeed.demoEmail],
            draftFolderIds: ["\(account):DRAFTS"],
            sentFolderIds: ["\(account):SENT"],
            unreadAtOpen: [],
            preferredId: opened.id)
    }

    @Test("Priya's and Jordan's chats hold a conversation, every bubble has its text, and Priya's AI Suggestion is ready")
    func seededChats() throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try DemoSeed.seed()
        let pool = fixture.0

        let priya = try chat(DemoSeed.TutorialFixture.priyaOffsite, pool: pool)
        #expect(priya.items.map(\.header.messageId) == ["demo-msg-14", DemoSeed.TutorialFixture.priyaOffsite],
                "Sam's email, then Priya's")
        #expect(priya.items.allSatisfy { $0.textMessage != nil })
        let newest = try #require(priya.newest)
        #expect(newest.messageId == DemoSeed.TutorialFixture.priyaOffsite)
        let ready = try #require(ChatReplyField.suggestionText(newest: newest, usersTurn: false, onlyTo: nil), "the AI Suggestion is ready")
        #expect(ready.contains("I'm in"))

        let jordan = try chat(DemoSeed.TutorialFixture.jordanFlights, pool: pool)
        #expect(jordan.items.map(\.header.messageId) == ["demo-msg-15", "demo-msg-16", DemoSeed.TutorialFixture.jordanFlights])
        #expect(jordan.items.map(\.isOwn) == [false, true, false], "Alex's answer is a blue bubble")
        #expect(jordan.items.allSatisfy { $0.textMessage != nil })

        // The inbox shows each thread as one row: Priya's with Sam's email, Jordan's alone.
        let inbox = try pool.read { db in
            try MessageHeader.filter(Column("folderId") == "\(DemoSeed.demoAccountId):INBOX").fetchAll(db)
        }
        let groups = ThreadGroupBuilder.buildDisplayGroups(from: inbox.map { MessageSnapshot(from: $0) })
        let priyaRow = try #require(groups.first { $0.representative.messageId == DemoSeed.TutorialFixture.priyaOffsite })
        #expect(priyaRow.memberCount == 2)
        let jordanRow = try #require(groups.first { $0.representative.messageId == DemoSeed.TutorialFixture.jordanFlights })
        #expect(jordanRow.memberCount == 1)
    }

    @Test("Every seeded email outside Drafts has a text message, and an AI Suggestion text exactly when it has a reply")
    func everyEmailHasItsText() throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try DemoSeed.seed()
        let headers = try fixture.0.read { db in
            try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId).fetchAll(db)
        }
        #expect(headers.count >= 16)
        for header in headers where header.folderPath != "DRAFTS" {
            #expect(!(header.summaryTextMessage ?? "").isEmpty, "\(header.messageId) has no text message")
            #expect((header.replyTextMessage != nil) == !(header.cachedReply ?? "").isEmpty, "\(header.messageId)")
        }
    }
}

// MARK: - A run in the chat view

@Suite("Tutorial in the chat view — a run from Part 2 to the switch", .serialized, .processGlobalState)
@MainActor
struct TutorialChatViewRunTests {
    @MainActor
    final class AcceptingSink: AgentUISink {
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmation.onRespond(true)
        }
    }

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorial-chat-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func waitFor(_ step: TutorialCoordinator.Step) async throws {
        for _ in 0..<200 {
            if TutorialCoordinator.shared.step == step { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("the tutorial never reached \(step); it is at \(String(describing: TutorialCoordinator.shared.step))")
    }

    /// Runs `body` with the Chat View setting and the AI setting as given (the AI choice made,
    /// opted out or not; or, with `aiChoiceMade` false, no AI choice yet), then puts both back.
    private func withSettings(chatView: Bool, optedOut: Bool = false, aiChoiceMade: Bool = true,
                              _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let savedChat = defaults.object(forKey: ChatViewConfig.enabledKey)
        let restoreAISetting = AITestSetting.save()
        let progressKeys = ["tutorial.version", "tutorial.completedLessons", "tutorial.discoveries"]
        let savedProgress = progressKeys.map { defaults.object(forKey: $0) }
        let gate = AISubscriptionGate.shared
        let gateWasActive = gate.isActive
        defer {
            defaults.set(savedChat, forKey: ChatViewConfig.enabledKey)
            restoreAISetting()
            for (key, value) in zip(progressKeys, savedProgress) { defaults.set(value, forKey: key) }
            if gateWasActive { gate.openGate() } else { gate.closeGate() }
            DemoModeStore.shared._resetForTests()
        }
        defaults.set(chatView, forKey: ChatViewConfig.enabledKey)
        if aiChoiceMade { AITestSetting.set(aiOff: optedOut) } else { AITestSetting.clear() }
        for key in progressKeys { defaults.removeObject(forKey: key) }
        DemoModeStore.shared._resetForTests()
        gate.closeGate()
        try await body()
    }

    @Test("With Chat View on, the run teaches in the chat view from its start to the switch, whatever the setting does meanwhile")
    func chatViewRun() async throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: true) {
            let coordinator = TutorialCoordinator.shared
            let pool = fixture.0
            try await whileRunning(.reuseReply) {
                #expect(coordinator.teachesChat)
                #expect(coordinator.step == .replyToPriya)
                #expect(ChatViewConfig.opensInChat, "the run's chats open as chats")
                // The setting changes mid-run: the run keeps what it started with.
                UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
                #expect(coordinator.teachesChat)
                #expect(ChatViewConfig.opensInChat)
                #expect(!TutorialCoordinator.chatViewOnForTutorial, "the next run would not")

                // Part 2: the AI Suggestion waits in Priya's chat; the inbox chat has nothing to send.
                #expect(coordinator.fieldMove(inPracticeChat: true) == .tapSuggestion)
                #expect(coordinator.fieldMove(inPracticeChat: false) == nil)
                #expect(coordinator.chatPrompt == nil)
                // The edit keeps the reply a yes.
                #expect(coordinator.composeEditPrompt == TutorialCoordinator.chatViewEditPrompt)
                var edited: String?
                await coordinator.runPracticeReplyEdit { edited = $0 }
                #expect(edited == TutorialChatScript.shorterReply)

                // The practice reply goes out, as compose sends it.
                let reply = TutorialChatScript.shorterReply
                coordinator.practiceReplyAuthored(reply)
                try await Task.sleep(for: .seconds(1))
                let draftId = "tutorial-practice-\(UUID().uuidString)"
                try await pool.write { db in
                    var draft = Draft(
                        id: draftId, accountId: DemoSeed.demoAccountId,
                        toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                        subject: "Re: Engineering offsite", body: reply, replyToId: nil,
                        isForward: false, editHistoryJSON: nil,
                        createdAt: Date().timeIntervalSince1970,
                        updatedAt: Date().timeIntervalSince1970)
                    draft.instanceEpoch = "E1"
                    try draft.insert(db)
                }
                let account = try #require(try await pool.read { try Account.fetchOne($0, key: DemoSeed.demoAccountId) })
                let priya = try #require(try await pool.read { db in
                    try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                        && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)
                })
                // Linked to Priya's email, as compose links a reply.
                let queued = try await AccountManager.shared.queueSend(
                    draft: DraftMessage(to: ["priya@company.com"], subject: "Re: Engineering offsite", body: reply,
                                        inReplyTo: priya.rfc822MessageId),
                    from: account, replyToHeaderId: priya.id, draftId: draftId, instanceEpoch: "E1", holdsForUndo: false)
                try await waitFor(.makeTemplate)

                // Its Sent copy joins Priya's chat as the user's own bubble, with its own words: the
                // tutorial makes no AI call, so nothing else would ever write its text message.
                var sentCopy: MessageHeader?
                for _ in 0..<80 {
                    sentCopy = try await pool.read { db in
                        try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                            && Column("messageId") == "sent-\(queued.outboxId)").fetchOne(db)
                    }
                    if sentCopy?.summaryTextMessage != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let sent = try #require(sentCopy, "the demo provider files the Sent copy")
                #expect(sent.summaryTextMessage == reply)
                let related = try ThreadDetection.findRelatedMessages(for: priya, in: pool)
                #expect(related.contains { $0.id == sent.id }, "the sent reply is in Priya's chat")
                let chat = ChatThread(
                    members: [priya] + related, replyAddresses: { [$0.fromAddress] },
                    ownAddresses: [DemoSeed.demoEmail.lowercased()], draftFolderIds: [],
                    sentFolderIds: [sent.folderId], unreadAtOpen: [], preferredId: priya.id)
                let bubble = try #require(chat.items.first { $0.id == sent.id })
                #expect(bubble.isOwn)
                #expect(bubble.textMessage == reply, "its own words, never Summarizing")

                // The request in the same field, then Create.
                #expect(coordinator.fieldMove(inPracticeChat: true) == .ask(.saveReplyAsTemplate))
                #expect(coordinator.chatPrompt == nil, "the request is in Priya's field, not the inbox chat")
                #expect(coordinator.highlightsTemplateCreate)
                _ = await TutorialChatScript.answer(
                    .saveReplyAsTemplate, practiceReply: coordinator.practiceReplyText,
                    invocation: ToolInvocation(uiSink: AcceptingSink()))
                try await waitFor(.reuseReplyDone)
                let templateId = try #require(coordinator.savedTemplateId)
                let template = try #require(PromptStore.shared.templates.first { $0.id == templateId })
                #expect(template.name == TutorialChatScript.chatViewTemplateName)
                #expect(template.exampleReply == reply)
                #expect(coordinator.highlightsChatClose, "the chat's sheet closes onto the card")

                // Part 3: the answer opens Jordan's chat at his email.
                coordinator.nextLesson()
                #expect(coordinator.chatPrompt == .flights)
                coordinator.chatPromptSent(.flights)
                coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
                #expect(coordinator.step == .askAnythingDone)
                coordinator.showMoreToAsk()
                coordinator.chatPromptSent(.whatCanYouDo)

                // The switch step, then the recap.
                #expect(!coordinator.highlightsChatViewSwitch)
                coordinator.finishChatViewSwitch()
                #expect(coordinator.step == .moreToAsk, "Finish on the switch counts only at the switch")
                coordinator.showRecap()
                #expect(coordinator.step == .chatViewSwitch)
                #expect(coordinator.highlightsChatViewSwitch)
                coordinator.showRecap()
                #expect(coordinator.step == .chatViewSwitch, "the recap's Finish runs once")
                coordinator.finishChatViewSwitch()
                #expect(coordinator.step == .finished)

                await coordinator.end()
                #expect(!coordinator.teachesChat, "an ended run teaches nothing")
                #expect(!coordinator.highlightsChatViewSwitch)
            }
        }
    }

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
    }

    /// Bounded: a condition that never holds fails the test rather than hanging it.
    private static func waitUntil(seconds: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Starts `lesson`, runs `body`, and ends the run on every way out. The cleanup boundary
    /// encloses the start itself: once the coordinator claims the run, a throw anywhere after (the
    /// demo's setup included) still ends it here, before `withSettings` resets the demo store.
    private func whileRunning(_ lesson: TutorialLesson, _ body: () async throws -> Void) async throws {
        let coordinator = TutorialCoordinator.shared
        try #require(!coordinator.isRunning, "control: no run is live before this one")
        do {
            await coordinator.start(lesson, hasTabMailSession: false)
            try await DemoModeService.shared.completeSetup()
            coordinator.seedingFinished()
            try await body()
        } catch {
            await coordinator.end()
            throw error
        }
        await coordinator.end()
    }

    /// Priya's email from the demo seed, as an inbox row shows it, with its two lines: the chat
    /// style's text message and today's snippet, which differ.
    private func priyaRow(_ pool: DatabasePool) async throws -> (row: MessageSnapshot, textMessage: String, snippet: String) {
        let found = try await pool.read { db in
            try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)
        }
        let priya = try #require(found, "the demo seed has Priya's email")
        let row = MessageSnapshot(from: priya)
        let textMessage = try #require(row.summaryTextMessage, "Priya's email has its text message")
        let snippet = row.snippet
        #expect(!snippet.isEmpty, "control: the row has a snippet")
        #expect(textMessage != snippet, "control: the chat-style line and the classic one differ")
        return (row, textMessage, snippet)
    }

    /// An inbox row and the Enable Chat View switch, each hosted in its own window as the inbox and
    /// Settings host them. They stay on screen until `close`, so a check after a change of the run
    /// or of a setting sees the same views repaint.
    @MainActor
    private final class HostedRowAndSwitch {
        let rowController: UIViewController
        let switchController: UIViewController
        private let windows: [UIWindow]

        init(row: MessageSnapshot) throws {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try #require(scenes.first, "a window scene hosts the row and the switch")
            rowController = UIHostingController(rootView: MessageRowView(message: row))
            switchController = UIHostingController(rootView: Form { ChatViewToggleRow() })
            let rowWindow = UIWindow(windowScene: scene)
            rowWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
            rowWindow.rootViewController = rowController
            let switchWindow = UIWindow(windowScene: scene)
            switchWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
            switchWindow.rootViewController = switchController
            windows = [rowWindow, switchWindow]
            for window in windows { window.makeKeyAndVisible() }
        }

        func close() {
            for window in windows {
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        /// The row's labels, for a failure message.
        func rowLabels() -> [String] { HostedAccessibility.labels(in: rowController.view) }

        func rowShows(_ line: String) -> Bool { rowLabels().contains(line) }

        func theSwitch() -> UISwitch? {
            let found = TutorialChatViewRunTests.switches(in: switchController.view)
            return found.count == 1 ? found[0] : nil
        }
    }

    // A first-launch tour starts before the AI choice and teaches the chat view. Its inbox rows and
    // its Chat View switch follow the run, as its opens do: chat-style rows and a switch that works.
    // The switch changes only the Chat View setting; the AI choice stays unmade. Once the run ends,
    // still before the choice, AI is off: the rows are classic and the switch is grayed out. Both
    // views stay on screen across the run's end, so they must repaint when the run state changes.
    @Test("Before the AI choice, a chat-view run shows chat-style rows and a working switch that records no AI choice; after it, classic rows and a grayed-out switch")
    func runBeforeTheAIChoice() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted row")
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: true, aiChoiceMade: false) {
            let coordinator = TutorialCoordinator.shared
            let store = AIService.optOutStore
            let defaults = UserDefaults.standard
            #expect(AIService.isAIOff, "control: no AI choice yet, so AI is off")
            try await whileRunning(.reuseReply) {
                #expect(coordinator.teachesChat, "control: the run teaches the chat view")
                let (row, textMessage, snippet) = try await priyaRow(fixture.0)
                try await HostedAccessibility.withAutomation {
                    let hosted = try HostedRowAndSwitch(row: row)
                    defer { hosted.close() }

                    // (1) The run: chat-style rows and a switch that works.
                    let chatRow = await Self.waitUntil { hosted.rowShows(textMessage) }
                    let runLabels = hosted.rowLabels()
                    #expect(chatRow, "the run's row shows the text message: \(runLabels)")
                    let runShowsSnippet = hosted.rowShows(snippet)
                    #expect(!runShowsSnippet, "the run's row does not show the snippet")
                    _ = await Self.waitUntil { hosted.theSwitch() != nil }
                    let rendered = hosted.theSwitch()
                    let control = try #require(rendered, "the switch renders")
                    #expect(control.isEnabled, "the run's switch can be used before the AI choice")
                    #expect(control.isOn, "it shows Chat View on")

                    // The switch changes the Chat View setting and nothing else: no AI choice is recorded.
                    control.setOn(false, animated: false)
                    control.sendActions(for: .valueChanged)
                    let off = await Self.waitUntil { defaults.object(forKey: ChatViewConfig.enabledKey) as? Bool == false }
                    #expect(off, "flipping the switch stores Chat View off")
                    #expect(store.object(forKey: AIService.aiChoiceMadeKey) == nil, "the switch records no AI choice")
                    #expect(store.object(forKey: AIService.optOutAllAIKey) == nil, "the switch writes no opt-out")
                    #expect(AIService.isAIOff, "AI stays off: the choice is still to be made")
                    control.setOn(true, animated: false)
                    control.sendActions(for: .valueChanged)
                    let on = await Self.waitUntil { defaults.object(forKey: ChatViewConfig.enabledKey) as? Bool == true }
                    #expect(on, "flipping it back stores Chat View on")
                    #expect(store.object(forKey: AIService.aiChoiceMadeKey) == nil, "still no AI choice")

                    // (2) The run ends, still before the AI choice: classic rows and a grayed-out switch.
                    await coordinator.end()
                    #expect(!coordinator.isRunning, "control: the run ended")
                    #expect(ChatViewConfig.isEnabledByUser, "control: Chat View is still on")
                    #expect(AIService.isAIOff, "control: still no AI choice")
                    let classicRow = await Self.waitUntil { hosted.rowShows(snippet) }
                    let afterLabels = hosted.rowLabels()
                    #expect(classicRow, "after the run the row shows the snippet: \(afterLabels)")
                    let afterShowsText = hosted.rowShows(textMessage)
                    #expect(!afterShowsText, "after the run the row does not show the text message")
                    let grayed = await Self.waitUntil { hosted.theSwitch()?.isEnabled == false }
                    #expect(grayed, "after the run the switch is grayed out")
                }
            }
        }
    }

    // A first-launch tour starts before the AI choice and teaches the chat view, so its sample email
    // opens as a chat: a real open (`MessageOpenView`, routed as its body routes it) made during the
    // run goes to the chat. The same open made once the run has ended, still before the choice, goes
    // to today's detail: outside a tour, AI is off until the choice is made.
    @Test("Before the AI choice, the tour opens its sample email as a chat; after the tour, still before the choice, a fresh open is today's detail")
    func openBeforeTheAIChoice() async throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: true, aiChoiceMade: false) {
            let coordinator = TutorialCoordinator.shared
            let database = PrioritizedDatabase(pool: fixture.0)
            #expect(AIService.isAIOff, "control: no AI choice yet, so AI is off")
            var priyaId: String?
            try await whileRunning(.reuseReply) {
                #expect(coordinator.teachesChat, "control: the run teaches the chat view")
                let found = try await fixture.0.read { db in
                    try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                        && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)
                }
                let priya = try #require(found, "the demo seed has Priya's email")
                priyaId = priya.id
                let route = MessageOpenView(messageId: priya.id).route(pool: database)
                #expect(route == .chat, "the tour opens its sample email as a chat before the AI choice")
            }
            #expect(!coordinator.isRunning, "control: the run ended")
            #expect(ChatViewConfig.isEnabledByUser, "control: Chat View is still on")
            #expect(AIService.isAIOff, "control: still no AI choice")
            let id = try #require(priyaId, "the run found Priya's email")
            let after = MessageOpenView(messageId: id).route(pool: database)
            #expect(after == .detail, "outside the tour, before the AI choice, an open is today's detail")
        }
    }

    // A run that teaches today's view (Chat View off when it started) keeps today's view on every
    // surface until it ends, even when every live value says chat: Chat View turned on, the AI
    // choice made with AI on, and a plan. The rows show the snippet and the switch stays grayed out
    // through the run's last moment; once it ends, the same hosted views show the chat style (the
    // control that the live values do say chat).
    @Test("A run teaching today's view shows classic rows and a grayed-out switch until it ends, whatever the live setting says")
    func classicRunStaysClassic() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted row")
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: false) {
            let coordinator = TutorialCoordinator.shared
            try await whileRunning(.reuseReply) {
                #expect(!coordinator.teachesChat, "control: the run teaches today's view")
                let (row, textMessage, snippet) = try await priyaRow(fixture.0)
                // Every live value says chat.
                UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
                AISubscriptionGate.shared.openGate()
                #expect(!AIService.isAIOff, "control: the AI choice is made and AI is on")
                let liveSaysChat = ChatViewConfig.isActive
                #expect(liveSaysChat, "control: the live chat view is on")
                try await HostedAccessibility.withAutomation {
                    let hosted = try HostedRowAndSwitch(row: row)
                    defer { hosted.close() }
                    _ = await Self.waitUntil { hosted.theSwitch() != nil && hosted.rowShows(snippet) }
                    // Through the run: today's view on both, checked over a span, not once.
                    for _ in 0..<5 {
                        let showsSnippet = hosted.rowShows(snippet)
                        let showsText = hosted.rowShows(textMessage)
                        let enabled = hosted.theSwitch()?.isEnabled
                        let labels = hosted.rowLabels()
                        #expect(showsSnippet, "the run's row shows the snippet: \(labels)")
                        #expect(!showsText, "the run's row does not show the text message")
                        #expect(enabled == false, "the run's switch is grayed out")
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(coordinator.isRunning, "control: the run was live for every check above")

                    // Once the run ends the same views follow the live values: the chat style.
                    await coordinator.end()
                    let chatRow = await Self.waitUntil { hosted.rowShows(textMessage) }
                    let afterLabels = hosted.rowLabels()
                    #expect(chatRow, "after the run the row shows the text message: \(afterLabels)")
                    let usable = await Self.waitUntil { hosted.theSwitch()?.isEnabled == true }
                    #expect(usable, "after the run the switch can be used")
                }
            }
        }
    }

    /// Runs `body` with a TabMail session and the age and terms consent in place (the summary at
    /// Send's other inputs), then puts both back.
    private func withSessionAndConsent(_ body: () async throws -> Void) async throws {
        let standard = UserDefaults.standard
        let consentBefore = standard.object(forKey: AgeAndTermsConsent.completedKey)
        let previousSession = TabMailSessionStore.shared.loadActiveSession()?.data
        defer {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previousSession { _ = try? TabMailSessionStore.shared.installNewSession(previousSession) }
            if let consentBefore { standard.set(consentBefore, forKey: AgeAndTermsConsent.completedKey) } else {
                standard.removeObject(forKey: AgeAndTermsConsent.completedKey)
            }
        }
        standard.set(true, forKey: AgeAndTermsConsent.completedKey)
        let sessionData = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-worker-token", "refresh_token": "synthetic-refresh-token",
            "expires_at": Int(Date().addingTimeInterval(86400).timeIntervalSince1970),
            "user": ["id": "11111111-1111-4111-8111-111111111111", "email": "user@example.com"],
        ])
        _ = try TabMailSessionStore.shared.installNewSession(sessionData)
        try await body()
    }

    // The summary at Send follows the run, as the run's opens do: with its other inputs met (a
    // session, consent, a plan, AI on), a chat-view run allows it with Chat View turned off live, and
    // a run teaching today's view refuses it with Chat View turned on live. The run's own practice
    // send is scripted: it is summarized on the device and sends no AI request.
    @Test("The summary at Send follows the run whatever the live Chat View setting says; the run's practice send sends no AI request",
          arguments: [true, false])
    func summaryAtSendFollowsTheRun(chatViewRun: Bool) async throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: chatViewRun) {
            try await withSessionAndConsent {
                let coordinator = TutorialCoordinator.shared
                try await whileRunning(.reuseReply) {
                    #expect(coordinator.teachesChat == chatViewRun, "control: the run kind")
                    // The live toggle disagrees with the run; every other input is met.
                    UserDefaults.standard.set(!chatViewRun, forKey: ChatViewConfig.enabledKey)
                    AISubscriptionGate.shared.openGate()
                    let liveActive = ChatViewConfig.isActive
                    #expect(liveActive == !chatViewRun, "control: the live chat view disagrees with the run")
                    #expect(TabMailAuthService.hasSession(), "control: signed in")
                    let mayRun = SentEmailSummary.mayRun()
                    #expect(mayRun == chatViewRun, "the summary at Send follows the run, not the live setting")
                    guard chatViewRun else { return }

                    // The run's practice send, with a summary service that records every request.
                    let http = FakeHTTP.Scenario()
                    defer { http.close() }
                    http.register(path: "/completions/chat", method: "POST", response: .status(500))
                    let recording = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
                    let pool = fixture.0
                    let reply = TutorialChatScript.shorterReply
                    let draftId = "tutorial-practice-\(UUID().uuidString)"
                    try await pool.write { db in
                        var draft = Draft(
                            id: draftId, accountId: DemoSeed.demoAccountId,
                            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                            subject: "Re: Engineering offsite", body: reply, replyToId: nil,
                            isForward: false, editHistoryJSON: nil,
                            createdAt: Date().timeIntervalSince1970,
                            updatedAt: Date().timeIntervalSince1970)
                        draft.instanceEpoch = "E1"
                        try draft.insert(db)
                    }
                    let demoAccount = try await pool.read { try Account.fetchOne($0, key: DemoSeed.demoAccountId) }
                    let account = try #require(demoAccount, "the demo account is set up")
                    let found = try await pool.read { db in
                        try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                            && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)
                    }
                    let priya = try #require(found, "the demo seed has Priya's email")
                    // Linked to Priya's email, as compose links the practice reply.
                    let queued = try await AccountManager.shared.queueSend(
                        draft: DraftMessage(to: ["priya@company.com"], subject: "Re: Engineering offsite", body: reply,
                                            inReplyTo: priya.rfc822MessageId),
                        from: account, replyToHeaderId: priya.id, draftId: draftId, instanceEpoch: "E1", holdsForUndo: false,
                        summaryService: recording)
                    // Its Sent copy carries its own words as its text message: the local summary ran.
                    var sentCopy: MessageHeader?
                    for _ in 0..<80 {
                        sentCopy = try await pool.read { db in
                            try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                                && Column("messageId") == "sent-\(queued.outboxId)").fetchOne(db)
                        }
                        if sentCopy?.summaryTextMessage != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let sentText = sentCopy?.summaryTextMessage
                    #expect(sentText == reply, "the practice send is summarized on the device, in its own words")
                    let requests = http.recordedCalls().count
                    #expect(requests == 0, "the practice send sends no AI request")
                }
            }
        }
    }

    // The coach card is part of the chat's top bar: while it shows, no bubble sits under it; once
    // the run moves on and it goes, no bubble sits under the subject.
    // The run moves on rather than ending: ending exits the demo, which takes the chat away.
    @Test("In Priya's chat the coach card sits in the top bar above the bubbles, and goes when the run moves on")
    func chatCardHoldsItsRoom() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: true) {
            let coordinator = TutorialCoordinator.shared
            try await whileRunning(.reuseReply) {
                #expect(coordinator.step == .replyToPriya)
                let priya = try #require(try await fixture.0.read { db in
                    try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                        && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)
                })
                try await HostedAccessibility.withAutomation {
                    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene)
                    let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: priya.id) })
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    defer {
                        window.isHidden = true
                        window.rootViewController = nil
                    }
                    @MainActor func coach() -> CGRect? {
                        HostedAccessibility.elements(under: controller.view)
                            .first { HostedAccessibility.identifier(of: $0) == "tutorial-coach" }?.accessibilityFrame
                    }
                    // The top of the first bubble: Priya's chat is short, so it sits at the bottom (its
                    // default anchor) and SwiftUI fills the space above it into the safe area. The room
                    // the card takes is therefore not readable from the scroll view here; what is
                    // readable, and what the bar must keep, is that nothing it holds covers a bubble.
                    @MainActor func firstBubbleTop() -> CGFloat? {
                        HostedAccessibility.elements(under: controller.view)
                            .filter { $0.accessibilityLabel?.contains(" said: ") == true }
                            .map(\.accessibilityFrame.minY).min()
                    }
                    @MainActor func subject() -> CGRect? {
                        HostedAccessibility.elements(under: controller.view)
                            .first { $0.accessibilityLabel == priya.subject && $0.accessibilityHint == nil }?.accessibilityFrame
                    }
                    for _ in 0..<80 where coach() == nil || firstBubbleTop() == nil { try await Task.sleep(for: .milliseconds(100)) }
                    try await Task.sleep(for: .milliseconds(500))
                    let card = try #require(coach(), "the coach card shows: \(HostedAccessibility.identifiers(in: controller.view))")
                    #expect(card.height > 0)
                    let withCard = try #require(firstBubbleTop(), "Priya's bubbles show")
                    #expect(withCard >= card.maxY - 0.5, "the first bubble \(withCard) sits below the card \(card)")

                    // Part 3 starts in the inbox: Priya's chat holds no card for it. The demo, and so the
                    // chat, stays.
                    coordinator.nextLesson()
                    #expect(coordinator.step != .replyToPriya, "control: the run moved on")
                    for _ in 0..<80 where coach() != nil { try await Task.sleep(for: .milliseconds(100)) }
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(coach() == nil, "the card goes once the run moves on")
                    let line = try #require(subject(), "the subject line shows: \(HostedAccessibility.labels(in: controller.view).prefix(20))")
                    let without = try #require(firstBubbleTop())
                    #expect(without >= line.maxY - 0.5, "the first bubble \(without) sits below the subject \(line)")
                }
            }
        }
    }

    @Test("With Chat View off, or AI opted out, the run is today's: no chat, and Finish goes straight to the recap")
    func todaysRun() async throws {
        for (chatView, optedOut) in [(false, false), (true, true)] {
            let fixture = try install()
            defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
            try await withSettings(chatView: chatView, optedOut: optedOut) {
                let coordinator = TutorialCoordinator.shared
                #expect(!TutorialCoordinator.chatViewOnForTutorial)
                try await whileRunning(.askAnything) {
                    #expect(!coordinator.teachesChat)
                    #expect(!ChatViewConfig.opensInChat, "the run's emails open in today's view")
                    #expect(coordinator.fieldMove(inPracticeChat: true) == nil)
                    coordinator.chatPromptSent(.flights)
                    coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
                    coordinator.showMoreToAsk()
                    coordinator.showRecap()
                    #expect(coordinator.step == .finished, "no switch step in today's run")
                }
            }
        }
    }
}

// MARK: - The views' wiring

@Suite("Tutorial in the chat view — the views' wiring")
@MainActor
struct TutorialChatViewWiringTests {
    /// The source with whitespace collapsed, so a move or a re-indent changes nothing checked.
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

    @Test("The tutorial's field holds the request and nothing else: never the AI Suggestion")
    func fieldText() {
        let field = { (move: TutorialCoordinator.FieldMove?) in
            ChatReplyField(example: nil, isNoReply: false, clearCount: 0, tutorialMove: move)
        }
        #expect(DynamicIslandChat.tutorialFieldText(field(.tapSuggestion)) == nil, "the move is a tap on the ghost")
        #expect(DynamicIslandChat.tutorialFieldText(field(.ask(.saveReplyAsTemplate)))
                == TutorialCoordinator.ChatPrompt.saveReplyAsTemplate.rawValue)
        #expect(DynamicIslandChat.tutorialFieldText(field(nil)) == nil)
    }

    @Test("The ghost's tap opens compose in its step only; the field's Send takes the request to the scripted agent")
    func fieldSendWiring() throws {
        let field = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        #expect(Self.count("TutorialChatInputBar( prompt: Self.tutorialFieldText(field), isWorking: isWorking, send: { sendTutorialField(field) })", in: field) == 1)
        #expect(Self.count("case .tapSuggestion, nil: break", in: field) == 1, "the field's Send never opens compose")
        #expect(Self.count("TutorialCoordinator.shared.chatPromptSent(prompt) let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply) } sendAgentChat(prompt.rawValue, script: prompt, field: send)", in: field) == 1)
        let pill = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("if let status = script?.workingStatus { enqueueStatus(status) }", in: pill) == 1, "Saving template shows while it works")
        #expect(Self.count("if (isInboxChat || replyField != nil) && TutorialCoordinator.shared.highlightsChatClose {", in: pill) == 1,
                "the chat's sheet rings its close as the inbox chat's does")
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("TutorialCoordinator.shared.fieldMove(inPracticeChat: holdsTutorialEmail(thread).practice)", in: chat) == 1)
        #expect(Self.count("tutorialMove: tutorialMove(thread)", in: chat) == 1)
        #expect(Self.count("ChatSuggestionBubble(text: text, pulses: move == .tapSuggestion) { openSuggestion(on: newest, tutorialMove: move) }", in: chat) == 1)
        #expect(Self.count("if TutorialCoordinator.shared.isRunning, tutorialMove != .tapSuggestion { _ = TutorialCoordinator.shared.admits(.other) return }", in: chat) == 1,
                "in the tutorial only the step that asks for it opens the card")
        #expect(Self.count("TutorialCoordinator.shared.messageOpened(accountId: opened.accountId, messageId: opened.messageId)", in: chat) == 1,
                "the chat opened at Jordan's email completes part 3")
    }

    @Test("The switch step's sheet, the Reply tag and the reference's highlight are wired")
    func screenWiring() throws {
        let navigation = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count(".sheet(isPresented: Binding( get: { TutorialCoordinator.shared.highlightsChatViewSwitch }, set: { _ in })) {", in: navigation) == 1)
        #expect(Self.count("TutorialChatViewSwitchSheet()", in: navigation) == 1)
        #expect(Self.count("MessageDetailResolvedContent(messageId: messageId, opensWithSkeletonDwell: true, highlightsMessage: true)", in: navigation) == 1,
                "an email opened from a reference highlights its text")
        let hosts = try Self.source("TabMail/Views/Tutorial/TutorialHostModifiers.swift")
        #expect(Self.count("ChatViewToggleRow() .overlay {", in: hosts) == 1, "the sheet's switch is Settings' own")
        #expect(Self.count(".interactiveDismissDisabled()", in: hosts) == 1)
        let settings = try Self.source("TabMail/Views/Settings/TabMailSettingsView.swift")
        #expect(Self.count("ChatViewToggleRow()", in: settings) == 1)

        // In the chat view the Reply tag opens the chat, before today's compose.
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        let tagged = try #require(inbox.range(of: "private func executeTaggedAction("))
        let reply = try #require(inbox.range(of: "case .reply:", range: tagged.upperBound..<inbox.endIndex))
        let opens = try #require(inbox.range(of: "if ChatViewConfig.opensInChat { selectedMessageId = snapshot.id break }", range: reply.upperBound..<inbox.endIndex))
        let markRead = try #require(inbox.range(of: "Mark as read", range: reply.upperBound..<inbox.endIndex))
        #expect(opens.lowerBound < markRead.lowerBound)
    }
}
