/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The AI setting as a test switches it, from inside the fake backend while a request is out.
final class AISettingSwitch: Sendable {
    private let off = Mutex(false)

    var isOff: Bool { off.withLock { $0 } }

    func turnOff() { off.withLock { $0 = true } }
    func turnOn() { off.withLock { $0 = false } }
}

/// Counts the requests a fake backend handler answered, so it can answer the first differently.
private final class Answered: Sendable {
    private let count = Mutex(0)

    /// Counts this request and returns its number, from 1.
    func next() -> Int { count.withLock { $0 += 1; return $0 } }
}

/// Settings → Opt Out of AI applies to every AI request, not only at the start of an operation.
/// Once it is turned on, the next request an operation would send (a tool round, a rate-limit
/// retry, a job that waited for its turn, the notification extension's next call) is not sent,
/// and the operation ends the way it ends when AI is already off at its start. A request already
/// out finishes and its answer is used; with AI back on, the next request goes out at once.
///
/// The clients' reading of the setting is injected, so a test turns AI off from inside the fake
/// backend while a request is out. The entry checks read the real setting, held on here (off for
/// the entry-check comparison): `.processGlobalState`, because other suites write it and the chat
/// test swaps `AppDatabase.shared`.
@Suite(.serialized, .processGlobalState)
struct AISettingAppliesToEveryRequestTests {

    // MARK: - Fixtures

    private static let primer = ":" + String(repeating: " ", count: 600) + "\n\n"

    /// The backend's stream with its `final` event.
    private static func stream(_ final: String) -> FakeHTTP.CannedResponse {
        .bytes(Data((primer + "event: final\ndata: " + final + "\n\n").utf8), contentType: "text/event-stream")
    }

    private static let answerText = "Here is the answer."
    private static let answer = stream(#"{"assistant":"Here is the answer."}"#)

    /// A round asking for a client tool: the loop runs it and sends its result in the next round.
    private static let toolRound = stream(
        #"{"tool_calls":[{"id":"call-1","function":{"name":"not_a_tool","arguments":"{}"}}],"conversation_state":{"harmony_messages":[],"current_round":1}}"#
    )

    private static let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

    /// Runs `body` with the real setting (the App Group flag) set as given, then restores it.
    private func withRealSetting<T>(aiOff: Bool, _ body: () async throws -> T) async rethrows -> T {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(aiOff)
        return try await body()
    }

    private func makeService(_ http: FakeHTTP.Scenario, _ setting: AISettingSwitch) -> AIService {
        AIService(backendClient: BackendClient(llmSession: http.session, isAIOff: { setting.isOff }))
    }

    // MARK: - Every way a request is sent

    enum Send: String, CaseIterable, Sendable {
        case completions, completionsDirect, maintenance, toolLoop, toolLoopDirect, transcription
    }

    private func send(_ kind: Send, _ client: BackendClient) async throws {
        switch kind {
        case .completions: _ = try await client.sendCompletions(Self.request)
        case .completionsDirect: _ = try await client.sendCompletionsDirect(Self.request)
        case .maintenance: _ = try await client.sendCompletionsDirect(Self.request, longTimeout: true)
        case .toolLoop: _ = try await client.sendCompletionsWithTools(Self.request)
        case .toolLoopDirect: _ = try await client.sendCompletionsWithToolsDirect(Self.request)
        case .transcription: _ = try await client.transcribeDictation(flac: Data([1, 2, 3]), language: nil, vocabulary: [])
        }
    }

    @Test("every way an AI request is sent checks the setting right before it, and sends again once AI is back on", arguments: Send.allCases)
    func everySendChecksTheSetting(kind: Send) async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive && !DemoModeStore.shared.isTutorialPractice })
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.answer)
        http.register(path: DictationConfig.transcribePath, method: "POST", response: .json(raw: #"{"text":"hello"}"#))
        let setting = AISettingSwitch()
        let client = BackendClient(llmSession: http.session, isAIOff: { setting.isOff })

        setting.turnOff()
        await #expect(throws: AIOffError.self) { try await send(kind, client) }
        #expect(http.recordedCalls().isEmpty)

        setting.turnOn()
        try await send(kind, client)
        #expect(http.recordedCalls().count == 1)
    }

    @Test("a refusal is not read as a dropped connection or a server failure, so nothing retries it")
    func aRefusalIsNeitherAConnectionLossNorAServerFailure() {
        #expect(!BackendClient.isConnectionLost(AIOffError()))
        #expect(!DictationController.isServerError(AIOffError()))
        #expect(!DictationController.backendTimedOut(AIOffError()))
    }

    // MARK: - Chat: the next tool round

    /// A chat turn's stored shape, for comparing two turns' history.
    private struct Saved: Equatable {
        let role: String
        let content: String
        let userMessage: String?
        let type: String
    }

    /// One chat turn as the chat pill makes it: the user's message is saved to the chat history
    /// first, then sent. Returns the answer and the session's history afterwards.
    private func chatTurn(
        _ service: AIService, pool: DatabasePool, typed: String
    ) async throws -> (answer: ChatResponse?, history: [Saved]) {
        let sessionId = "inbox-\(UUID().uuidString)"
        let userTurn = ChatTurn(
            id: ChatTurn.generateId(), timestamp: Date().timeIntervalSince1970 * 1000, role: "user",
            content: "chat_converse", userMessage: typed, type: "normal", chars: typed.count,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        try await ChatStore.shared.appendTurn(userTurn, admission: nil)

        let answer = try await service.sendChatMessage(userText: typed, history: [])

        let history = try await pool.read { db in
            try ChatTurn.filter(Column("sessionId") == sessionId).order(Column("timestamp").asc).fetchAll(db)
        }
        return (answer, history.map { Saved(role: $0.role, content: $0.content, userMessage: $0.userMessage, type: $0.type) })
    }

    @Test("a chat turn stops at its next tool round once AI is turned off, and its user's message stays as with AI off at the start")
    func aChatTurnStopsAtItsNextToolRound() async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        await MemoryIndex.shared._testReset()

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        let answered = Answered()
        http.register(path: "/completions/chat", method: "POST") { _ in
            guard answered.next() == 1 else { return Self.answer }
            // AI is turned off while the first round is out; that round asks for a client tool.
            setting.turnOff()
            return Self.toolRound
        }
        let service = makeService(http, setting)
        let typed = "What is on my calendar tomorrow?"

        // AI off at the start: the entry check ends the turn.
        let atStart = try await withRealSetting(aiOff: true) {
            try await chatTurn(service, pool: pool, typed: typed)
        }
        #expect(atStart.answer == nil)
        #expect(http.recordedCalls().isEmpty)

        // AI turned off while the first round is out: its tool runs, the next round is not sent.
        let midTurn = try await withRealSetting(aiOff: false) {
            try await chatTurn(service, pool: pool, typed: typed)
        }
        #expect(http.recordedCalls().count == 1)
        // The same end as the entry check's: no answer and no error, so the pill shows its
        // no-answer line, saves nothing more, and offers no retry or resume of a sent request.
        #expect(midTurn.answer == nil)
        // The user's own message stays exactly as the entry check leaves it; only the answer is missing.
        #expect(midTurn.history == [Saved(role: "user", content: "chat_converse", userMessage: typed, type: "normal")])
        #expect(midTurn.history == atStart.history)

        // Back on: the next turn is sent at once and answered.
        setting.turnOn()
        let next = try await withRealSetting(aiOff: false) {
            try await service.sendChatMessage(userText: "And the day after?", history: [])
        }
        #expect(next?.text == Self.answerText)
        #expect(http.recordedCalls().count == 2)
    }

    // MARK: - Reply: a rate-limit retry

    private func reply(_ service: AIService) async throws -> String? {
        try await service.generateReply(
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com",
            to: "sender@company.com", cc: "", bodyText: "Can we meet on Thursday?", userName: "Recipient",
            compositionPrompt: "", kbText: "", currentTime: "", relatedDate: "", relatedSubject: "",
            relatedFrom: "", relatedTo: "", relatedCc: ""
        )
    }

    @Test("a reply rate limited when AI is turned off is not tried again, and ends as with AI off at the start")
    func aRateLimitedReplyIsNotTriedAgain() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        let answered = Answered()
        http.register(path: "/completions/chat", method: "POST") { _ in
            guard answered.next() == 1 else {
                return Self.stream(#"{"assistant":"Subject: Re: Quarterly planning\nBody: Thursday works."}"#)
            }
            // AI is turned off while the first request is out, which the backend rate limits.
            setting.turnOff()
            return .status(429)
        }
        let service = makeService(http, setting)

        try await withRealSetting(aiOff: false) {
            // After the back-off, the retry is not sent: no reply, as the entry check returns.
            let refused = try await reply(service)
            #expect(refused == nil)
            #expect(http.recordedCalls().count == 1)

            setting.turnOn()
            let answeredReply = try await reply(service)
            #expect(answeredReply != nil)
            #expect(http.recordedCalls().count == 2)
        }
    }

    // MARK: - Summary and action: a job that waited, and a request already out

    /// Answers the summary prompt with a blurb and the action prompt with an action.
    private func registerSummaryAndAction(_ http: FakeHTTP.Scenario, onEach: @escaping @Sendable () -> Void = {}) {
        http.register(path: "/completions/chat", method: "POST") { request in
            onEach()
            let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let prompt = ((json["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            return prompt == "system_prompt_action"
                ? Self.stream(#"{"assistant":"{\"action\":\"archive\"}"}"#)
                : Self.stream(#"{"assistant":"Two-line summary: A short summary."}"#)
        }
    }

    private func process(_ service: AIService) async throws -> (summary: SummaryResult, action: ActionTag?, reply: String?)? {
        // `rfc822MessageId: nil` skips the Device Sync probe, so both prompts run.
        try await service.process(
            messageId: "msg-1", rfc822MessageId: nil, accountEmail: "recipient@example.com",
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com",
            date: Date(), bodyText: "Notes from the planning call.", htmlContent: nil,
            hasExistingAction: false, userName: "Recipient", kbText: "", actionPrompt: "",
            recipientStatus: ""
        )
    }

    @Test("a summary or action that passed its check before AI was turned off is not sent, and ends as with AI off at the start")
    func aWaitingJobIsNotSent() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        registerSummaryAndAction(http)
        let setting = AISettingSwitch()
        let service = makeService(http, setting)

        try await withRealSetting(aiOff: false) {
            // The entry checks passed; AI is off by the time the requests would go out (as for
            // a job waiting for a free slot or its sign-in token).
            setting.turnOff()
            let summary = try await service.generateSummary(
                subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com", date: Date(),
                bodyText: "Notes from the planning call.", htmlContent: nil, userName: "Recipient", kbText: "")
            #expect(summary.blurb == nil && summary.todos == nil && summary.reminderDate == nil)
            let action = try await service.classifyAction(
                subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com",
                bodyText: "Notes from the planning call.", htmlContent: nil, summary: summary,
                userName: "Recipient", actionPrompt: "", recipientStatus: "")
            #expect(action == nil)
            #expect(http.recordedCalls().isEmpty)

            setting.turnOn()
            let result = try #require(try await process(service))
            #expect(result.summary.blurb != nil)
            #expect(result.action == .archive)
            #expect(http.recordedCalls().count == 2)
        }
    }

    @Test("a summary out when AI is turned off is kept, and the action after it is not sent")
    func theRequestOutFinishesAndTheNextIsNotSent() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        // AI is turned off while the summary request is out.
        registerSummaryAndAction(http) { setting.turnOff() }
        let service = makeService(http, setting)

        try await withRealSetting(aiOff: false) {
            let result = try #require(try await process(service))
            #expect(result.summary.blurb != nil)
            #expect(result.action == nil)
            #expect(http.recordedCalls().count == 1)
        }
    }

    // MARK: - Notification extension

    private static let nseAnswer = "event: final\ndata: {\"assistant\":\"A short summary.\"}\n\n"

    private func nseSummary() async -> String? {
        await BackendNSEClient.sendCompletions(
            promptAlias: "system_prompt_summary", variables: BackendNSEClient.Vars([:]), authToken: "test-token"
        )?.assistant
    }

    @Test("the notification extension sends nothing once AI is turned off: no retry, no action vote; back on, it sends again")
    func theNotificationExtensionStopsAtItsNextRequest() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        http.register(path: "/completions/chat", method: "POST") { _ in
            // AI is turned off while this request is out.
            setting.turnOff()
            return .bytes(Data(Self.nseAnswer.utf8), contentType: "text/event-stream")
        }
        let transport: BackendNSEClient.Transport = { try await http.session.data(for: $0) }

        await BackendNSEClient.$transport.withValue(transport) {
            await BackendNSEClient.$isAIOff.withValue({ setting.isOff }) {
                // The request out finishes and its answer is used.
                #expect(await nseSummary() == "A short summary.")
                #expect(http.recordedCalls().count == 1)

                // A summary retry and the action vote are not sent.
                #expect(await nseSummary() == nil)
                let vote = await BackendNSEClient.sendActionVote(
                    promptAlias: "system_prompt_action", variables: BackendNSEClient.Vars([:]),
                    authToken: "test-token", voteCount: 3)
                #expect(vote == nil)
                #expect(http.recordedCalls().count == 1)

                setting.turnOn()
                #expect(await nseSummary() == "A short summary.")
                #expect(http.recordedCalls().count == 2)
            }
        }
    }

    // MARK: - Wiring

    @Test("by default both clients read the Opt Out of AI setting itself")
    func theDefaultsReadTheSetting() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.answer)
        let client = BackendClient(llmSession: http.session)
        let transport: BackendNSEClient.Transport = { try await http.session.data(for: $0) }

        await withRealSetting(aiOff: true) {
            await #expect(throws: AIOffError.self) { try await client.sendCompletionsDirect(Self.request) }
            let nse = await BackendNSEClient.$transport.withValue(transport) { await nseSummary() }
            #expect(nse == nil)
            #expect(http.recordedCalls().isEmpty)
        }
        try await withRealSetting(aiOff: false) {
            let app = try await client.sendCompletionsDirect(Self.request)
            #expect(app.assistant == Self.answerText)
            let nse = await BackendNSEClient.$transport.withValue(transport) { await nseSummary() }
            #expect(nse == Self.answerText)
            #expect(http.recordedCalls().count == 2)
        }
    }

    // MARK: - Source fences

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: DiagnosticPrintGateTests.repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("the backend client sends AI requests only right after its check of the setting")
    func theBackendClientSendsOnlyAfterItsCheck() throws {
        let lines = Self.codeLines(try Self.source("TabMail/Services/BackendClient.swift"))
        let sendPattern = #"\.(bytes|data|upload|download)\((for|from):|(data|upload|download|webSocket)Task\("#
        let sends = lines.indices.filter { index in
            lines[index].range(of: sendPattern, options: .regularExpression) != nil
                && !lines[index].contains("sharedEphemeralSession")
        }
        #expect(sends.count == 2, "sends outside the shared session: \(sends.map { lines[$0] })")
        for index in sends {
            #expect(lines[index - 1].contains("try refuseIfAIOff()"), "\(lines[index]) is not right after the check")
            #expect(lines[index].contains("llmSession"))
        }
        // The LLM sessions carry nothing else.
        let sessionUses = lines.filter { $0.contains("llmSession.") || $0.contains("llmLongOpSession.") }
        #expect(sessionUses.allSatisfy { line in sends.contains { lines[$0] == line } })
    }

    @Test("the notification extension sends AI requests only right after its check of the setting")
    func theNotificationExtensionSendsOnlyAfterItsCheck() throws {
        let lines = Self.codeLines(try Self.source("TabMailNotificationService/BackendNSEClient.swift"))
        let sends = lines.indices.filter { lines[$0].contains("BackendNSEClient.transport(") }
        #expect(sends.count == 1)
        for index in sends {
            #expect(lines[index - 1].contains("guard !BackendNSEClient.isAIOff() else { return .refused }"))
        }
        #expect(lines.filter { $0.contains("URLSession.shared") }.count == 1, "only the default transport")
    }

    @Test("only the two clients name the AI endpoints")
    func onlyTheClientsNameTheAIEndpoints() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        var completions: Set<String> = []
        var transcription: Set<String> = []
        for folder in ["TabMail", "Shared", "TabMailNotificationService"] {
            let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                let lines = Self.codeLines(try String(contentsOf: url, encoding: .utf8))
                if lines.contains(where: { $0.contains(#"/completions/chat""#) }) { completions.insert(relative) }
                if lines.contains(where: { $0.contains(".transcribePath") }) { transcription.insert(relative) }
            }
        }
        #expect(completions == ["TabMail/Services/BackendClient.swift", "TabMailNotificationService/BackendNSEClient.swift"])
        #expect(transcription == ["TabMail/Services/BackendClient.swift"])
    }
}
