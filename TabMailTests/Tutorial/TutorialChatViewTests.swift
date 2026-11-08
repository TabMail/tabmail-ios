/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

// The guided tutorial in the chat view (tutorial mock v3): its cards, the reply field's moves,
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
        // T2: open Priya's email, then the ready reply, the request, the saved template, in her chat.
        let open = try #require(card(.replyToPriya, .reuseReply, .inbox))
        #expect(open.title.contains("Open Priya"))
        let ready = try #require(card(.replyToPriya, .reuseReply, .chat))
        #expect(ready.message.contains("Tap Send"))
        let ask = try #require(card(.makeTemplate, .reuseReply, .chat))
        #expect(ask.message.contains("tap Send"))
        #expect(card(.makeTemplate, .reuseReply, .inbox) != nil, "back in the inbox the card says where to go")
        for host in [TutorialCoachHost.chat, .inbox] {
            let saved = try #require(card(.reuseReplyDone, .reuseReply, host))
            #expect(saved.progressLine.hasSuffix("· done"))
            #expect(saved.buttons.map(\.action) == [.seeTemplate, .nextLesson])
        }
        // T3: the answer, in Jordan's chat, goes on to what else to ask.
        let answer = try #require(card(.askAnythingDone, .askAnything, .chat))
        #expect(answer.buttons.map(\.action) == [.showMoreToAsk])
        // T4: the switch, after the three parts, closes with Finish.
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

    @Test("The reply field moves only in Priya's chat in the chat view: the AI Reply, then the request")
    func fieldMoves() {
        typealias C = TutorialCoordinator
        for step in Self.allSteps.map(Optional.some) + [nil] {
            for practice in [false, true] {
                for teachesChat in [false, true] {
                    let move = C.fieldMove(for: step, inPracticeChat: practice, teachesChat: teachesChat)
                    let expected: C.FieldMove?
                    switch step {
                    case .replyToPriya where practice && teachesChat: expected = .sendReadyReply
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

    /// The Sent bubble shows the AI Reply's text message (N7), so the scripted edit must not
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

    @Test("Priya's and Jordan's chats hold a conversation, every bubble has its text, and Priya's AI Reply is ready")
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
        let ready = try #require(ChatReplyField.readyText(newest: newest, isOwn: false), "the field holds the AI Reply")
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

    @Test("Every seeded email outside Drafts has a text message, and an AI Reply text exactly when it has a reply")
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

    /// Runs `body` with the Chat View setting and the AI opt-out as given, then puts both back.
    private func withSettings(chatView: Bool, optedOut: Bool = false, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let savedChat = defaults.object(forKey: ChatViewConfig.enabledKey)
        let savedOptOut = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        let progressKeys = ["tutorial.version", "tutorial.completedLessons", "tutorial.discoveries"]
        let savedProgress = progressKeys.map { defaults.object(forKey: $0) }
        let gate = AISubscriptionGate.shared
        let gateWasActive = gate.isActive
        defer {
            defaults.set(savedChat, forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(savedOptOut, forKey: AIService.optOutAllAIKey)
            for (key, value) in zip(progressKeys, savedProgress) { defaults.set(value, forKey: key) }
            if gateWasActive { gate.openGate() } else { gate.closeGate() }
            DemoModeStore.shared._resetForTests()
        }
        defaults.set(chatView, forKey: ChatViewConfig.enabledKey)
        AIService.optOutStore.set(optedOut, forKey: AIService.optOutAllAIKey)
        for key in progressKeys { defaults.removeObject(forKey: key) }
        DemoModeStore.shared._resetForTests()
        gate.closeGate()
        try await body()
    }

    private func start(_ lesson: TutorialLesson) async throws {
        let coordinator = TutorialCoordinator.shared
        try #require(!coordinator.isRunning)
        await coordinator.start(lesson, hasTabMailSession: false)
        try await DemoModeService.shared.completeSetup()
        coordinator.seedingFinished()
    }

    @Test("With Chat View on, the run teaches in the chat view from its start to the switch, whatever the setting does meanwhile")
    func chatViewRun() async throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
        try await withSettings(chatView: true) {
            let coordinator = TutorialCoordinator.shared
            let pool = fixture.0
            try await start(.reuseReply)
            #expect(coordinator.teachesChat)
            #expect(coordinator.step == .replyToPriya)
            #expect(ChatViewConfig.opensInChat, "the run's chats open as chats")
            // The setting changes mid-run: the run keeps what it started with.
            UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
            #expect(coordinator.teachesChat)
            #expect(ChatViewConfig.opensInChat)
            #expect(!TutorialCoordinator.chatViewOnForTutorial, "the next run would not")

            // T2.2: the AI Reply waits in Priya's field; the inbox chat has nothing to send.
            #expect(coordinator.fieldMove(inPracticeChat: true) == .sendReadyReply)
            #expect(coordinator.fieldMove(inPracticeChat: false) == nil)
            #expect(coordinator.chatPrompt == nil)
            // T2.3: the edit keeps the reply a yes.
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

            // T2.4 to T2.6: the request in the same field, then Create.
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

            // T3: the answer opens Jordan's chat at his email.
            coordinator.nextLesson()
            #expect(coordinator.chatPrompt == .flights)
            coordinator.chatPromptSent(.flights)
            coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
            #expect(coordinator.step == .askAnythingDone)
            coordinator.showMoreToAsk()
            coordinator.chatPromptSent(.whatCanYouDo)

            // T4, then the recap.
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

    @Test("With Chat View off, or AI opted out, the run is today's: no chat, and Finish goes straight to the recap")
    func todaysRun() async throws {
        for (chatView, optedOut) in [(false, false), (true, true)] {
            let fixture = try install()
            defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }
            try await withSettings(chatView: chatView, optedOut: optedOut) {
                let coordinator = TutorialCoordinator.shared
                #expect(!TutorialCoordinator.chatViewOnForTutorial)
                try await start(.askAnything)
                #expect(!coordinator.teachesChat)
                #expect(!ChatViewConfig.opensInChat, "the run's emails open in today's view")
                #expect(coordinator.fieldMove(inPracticeChat: true) == nil)
                coordinator.chatPromptSent(.flights)
                coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
                coordinator.showMoreToAsk()
                coordinator.showRecap()
                #expect(coordinator.step == .finished, "no switch step in today's run")
                await coordinator.end()
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

    @Test("The tutorial's field holds the AI Reply, then the request, and nothing else")
    func fieldText() {
        let ready = "Thanks Priya, I'm in."
        let field = { (move: TutorialCoordinator.FieldMove?) in
            ChatReplyField(readyText: ready, isNoReply: false, clearCount: 0, tutorialMove: move)
        }
        #expect(DynamicIslandChat.tutorialFieldText(field(.sendReadyReply)) == ready)
        #expect(DynamicIslandChat.tutorialFieldText(field(.ask(.saveReplyAsTemplate)))
                == TutorialCoordinator.ChatPrompt.saveReplyAsTemplate.rawValue)
        #expect(DynamicIslandChat.tutorialFieldText(field(nil)) == nil)
    }

    @Test("The field's Send: the AI Reply opens compose, the request goes to the scripted agent")
    func fieldSendWiring() throws {
        let pill = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("TutorialChatInputBar( prompt: Self.tutorialFieldText(field), isWorking: isWorking, label: field.tutorialMove == .sendReadyReply ? \"AI Reply\" : nil, send: { sendTutorialField(field) })", in: pill) == 1)
        #expect(Self.count("case .sendReadyReply: onSendReadyReply?()", in: pill) == 1)
        #expect(Self.count("TutorialCoordinator.shared.chatPromptSent(prompt) sendAgentChat(prompt.rawValue, script: prompt, fromReplyField: true)", in: pill) == 1)
        #expect(Self.count("if let status = script?.workingStatus { enqueueStatus(status) }", in: pill) == 1, "Saving template shows while it works")
        #expect(Self.count("if (isInboxChat || replyField != nil) && TutorialCoordinator.shared.highlightsChatClose {", in: pill) == 1,
                "the chat's sheet rings its close as the inbox chat's does")
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("tutorialMove: TutorialCoordinator.shared.fieldMove(inPracticeChat: holdsTutorialEmail(thread).practice)", in: chat) == 1)
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

        // TQ2: in the chat view the Reply tag opens the chat, before today's compose.
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        let tagged = try #require(inbox.range(of: "private func executeTaggedAction("))
        let reply = try #require(inbox.range(of: "case .reply:", range: tagged.upperBound..<inbox.endIndex))
        let opens = try #require(inbox.range(of: "if ChatViewConfig.opensInChat { selectedMessageId = snapshot.id break }", range: reply.upperBound..<inbox.endIndex))
        let markRead = try #require(inbox.range(of: "Mark as read", range: reply.upperBound..<inbox.endIndex))
        #expect(opens.lowerBound < markRead.lowerBound)
    }
}
