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

/// A harmless client tool, registered in the shared registry under its own name, that counts its runs.
private final class CountingTool: AgentTool, Sendable {
    let name = "test_counting_tool_\(UUID().uuidString.prefix(8))"
    private let count = Mutex(0)

    var runs: Int { count.withLock { $0 } }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        count.withLock { $0 += 1 }
        return "done"
    }

    /// Registers this tool after the default set, so the tool loop finds it.
    func register() async {
        await ToolRegistry.shared.ensureDefaultToolsRegistered()
        await ToolRegistry.shared.register(self)
    }
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

    /// A round asking for the client tool `name`: the loop runs it and sends its result in the next round.
    private static func toolRound(_ name: String) -> FakeHTTP.CannedResponse {
        stream(
            #"{"tool_calls":[{"id":"call-1","function":{"name":""# + name + #"","arguments":"{}"}}],"conversation_state":{"harmony_messages":[],"current_round":1}}"#
        )
    }

    private static let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

    /// Runs `body` with the real setting (the App Group values, the AI choice made) set as given,
    /// then restores it.
    private func withRealSetting<T>(aiOff: Bool, _ body: () async throws -> T) async rethrows -> T {
        try await AITestSetting.with(aiOff: aiOff, body)
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
        try await withTestDatabase { pool in try await chatTurnStopsAtItsNextToolRound(pool) }
    }

    /// Runs `body` with a fresh database installed as `AppDatabase.shared`, then restores the previous one.
    private func withTestDatabase<T>(_ body: (DatabasePool) async throws -> T) async throws -> T {
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
        return try await body(pool)
    }

    private func chatTurnStopsAtItsNextToolRound(_ pool: DatabasePool) async throws {
        let tool = CountingTool()
        await tool.register()
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        let answered = Answered()
        http.register(path: "/completions/chat", method: "POST") { _ in
            guard answered.next() == 1 else { return Self.answer }
            // AI is turned off while the first round is out; that round asks for a client tool.
            setting.turnOff()
            return Self.toolRound(tool.name)
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
        // The tool the first round asked for ran, once; only the round carrying its result was refused.
        #expect(tool.runs == 1)
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

    @Test("a client tool an answer asked for runs once after AI is turned off, and the round carrying its result is not sent")
    func aRequestedToolRunsAndItsResultIsNotSent() async throws {
        let tool = CountingTool()
        await tool.register()

        // Control, AI on throughout: the tool runs and its result goes out in the next round.
        let enabled = FakeHTTP.Scenario()
        defer { enabled.close() }
        let enabledAnswered = Answered()
        enabled.register(path: "/completions/chat", method: "POST") { _ in
            enabledAnswered.next() == 1 ? Self.toolRound(tool.name) : Self.answer
        }
        let on = AISettingSwitch()
        let answered = try await BackendClient(llmSession: enabled.session, isAIOff: { on.isOff })
            .sendCompletionsWithToolsDirect(Self.request)
        #expect(answered.assistant == Self.answerText)
        #expect(tool.runs == 1)
        let enabledCalls = enabled.recordedCalls()
        #expect(enabledCalls.count == 2)
        guard enabledCalls.count == 2 else { return }
        let continuation = String(decoding: enabledCalls[1].body ?? Data(), as: UTF8.self)
        #expect(continuation.contains(#""tool_call_id":"call-1""#), "the next round carries the tool's result")

        // AI turned off while the first round is out: the tool still runs once; its result is not sent.
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let setting = AISettingSwitch()
        http.register(path: "/completions/chat", method: "POST") { _ in
            setting.turnOff()
            return Self.toolRound(tool.name)
        }
        let client = BackendClient(llmSession: http.session, isAIOff: { setting.isOff })
        await #expect(throws: AIOffError.self) { try await client.sendCompletionsWithToolsDirect(Self.request) }
        #expect(tool.runs == 2, "the requested tool ran exactly once more")
        #expect(http.recordedCalls().count == 1, "no continuation request")
    }

    // MARK: - Chat resume, inline edit: refused after the entry check

    private static let draftSubject = "Quarterly planning"
    private static let draftBody = "Can we meet on Thursday?"

    private func inlineEdit(_ service: AIService) async throws -> InlineEditResult {
        let context = ComposeEditContext(
            recipients: ["recipient@example.com"], toRecipients: ["recipient@example.com"], ccRecipients: [], bccRecipients: [],
            toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:], senderName: "Sender", senderEmail: "sender@company.com",
            mode: "edit_new", compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "", relatedFrom: "",
            relatedTo: "", relatedCc: "", bodyText: "")
        return try await service.performInlineEdit(
            currentSubject: Self.draftSubject, currentBody: Self.draftBody, context: context,
            instruction: "Make it shorter.", chatHistory: [])
    }

    @Test("a resumed chat turn refused after its check ends with no answer, as with AI off at the start")
    func aRefusedResumeHasNoAnswer() async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive })
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.answer)
        let setting = AISettingSwitch()
        let service = makeService(http, setting)

        try await withRealSetting(aiOff: false) {
            setting.turnOff()
            let refused = try await service.resumeChatMessage(request: Self.request)
            #expect(refused == nil)
            #expect(http.recordedCalls().isEmpty)

            setting.turnOn()
            let resumed = try await service.resumeChatMessage(request: Self.request)
            #expect(resumed?.text == Self.answerText)
            #expect(http.recordedCalls().count == 1)
        }
    }

    @Test("an inline edit refused after its check returns the AI-off result and leaves the draft as it was")
    func aRefusedInlineEditLeavesTheDraft() async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive })
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.stream(#"{"assistant":"Response: Shortened.\nSubject: Planning\nBody: Thursday?"}"#))
        let setting = AISettingSwitch()
        let service = makeService(http, setting)

        try await withRealSetting(aiOff: false) {
            setting.turnOff()
            let refused = try await inlineEdit(service)
            #expect(refused.response == AIService.inlineEditWithAIOff.response)
            #expect(refused.response == "AI calls are disabled.")
            // No new subject, body or recipients: the draft stays as it was.
            #expect(refused.subject == nil && refused.body == nil)
            #expect(refused.toDelta == nil && refused.ccDelta == nil && refused.bccDelta == nil)
            #expect(refused.raw.isEmpty)
            #expect(http.recordedCalls().isEmpty)

            setting.turnOn()
            let edited = try await inlineEdit(service)
            #expect(edited.response == "Shortened.")
            #expect(edited.subject == "Planning" && edited.body == "Thursday?")
            #expect(http.recordedCalls().count == 1)
        }
    }

    // MARK: - Demo Mode: a refused call uses none of the budget

    enum DemoCall: String, CaseIterable, Sendable {
        case send, resume, edit
    }

    /// The Demo Mode calls used, as stored.
    private static func storedDemoCalls() -> Int {
        UserDefaults.standard.integer(forKey: "demo.callsConsumed")
    }

    /// Runs `body` in a running demo with a stored demo token, then ends the demo.
    private func inDemo(_ body: () async throws -> Void) async throws {
        let session = DemoTokenManager.DemoSession(
            accessToken: "test-demo-token", sub: "test",
            expiresAt: Int(Date().addingTimeInterval(3600).timeIntervalSince1970))
        try KeychainHelper.save(try JSONEncoder().encode(session), for: "demo_session")
        await MainActor.run {
            DemoModeStore.shared._resetForTests()
            DemoModeStore.shared.isActive = true
        }
        func end() async {
            await MainActor.run { DemoModeStore.shared._resetForTests() }
            DemoTokenManager.clearSession()
        }
        do {
            try await body()
        } catch {
            await end()
            throw error
        }
        await end()
    }

    /// Makes the call and returns whether it ended as with AI off at the start.
    private func demoCall(_ call: DemoCall, _ service: AIService) async throws -> Bool {
        switch call {
        case .send: return try await service.sendChatMessage(userText: "What is on my calendar tomorrow?", history: []) == nil
        case .resume: return try await service.resumeChatMessage(request: Self.request) == nil
        case .edit: return try await inlineEdit(service).response == AIService.inlineEditWithAIOff.response
        }
    }

    @Test("in the demo, chat, inline edit and the dictation warm-up follow the device's AI setting by default",
          arguments: [true, false])
    func theDemoReadsTheDeviceSetting(aiOff: Bool) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.answer)
        http.register(path: DictationConfig.warmUpPath, response: .status(200))
        // The default reading of the setting: no injected switch.
        let client = BackendClient(llmSession: http.session)
        let service = AIService(backendClient: client)

        try await withTestDatabase { _ in
            try await withRealSetting(aiOff: aiOff) {
                try await inDemo {
                    _ = try await service.sendChatMessage(userText: "What is on my calendar tomorrow?", history: [])
                    _ = try await inlineEdit(service)
                    await client.warmUpDictation()
                    #expect(http.recordedCalls().count == (aiOff ? 0 : 3), "\(http.recordedCalls().map(\.url))")
                }
            }
        }
    }

    @Test("a demo call refused after its check uses none of the demo budget; one sent uses exactly one", arguments: DemoCall.allCases)
    func aRefusedDemoCallUsesNoBudget(call: DemoCall) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: Self.answer)
        let setting = AISettingSwitch()
        let service = makeService(http, setting)

        try await withTestDatabase { _ in
            try await withRealSetting(aiOff: false) {
                try await inDemo {
                    let before = Self.storedDemoCalls()
                    setting.turnOff()
                    let refused = try await demoCall(call, service)
                    #expect(refused)
                    #expect(http.recordedCalls().isEmpty)
                    #expect(Self.storedDemoCalls() == before, "a refused call is not charged")

                    setting.turnOn()
                    let sentLikeOff = try await demoCall(call, service)
                    #expect(!sentLikeOff)
                    #expect(http.recordedCalls().count == 1)
                    #expect(Self.storedDemoCalls() == before + 1, "a sent call uses exactly one")
                }
            }
        }
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

    @Test("by default both clients read the AI setting itself: Opt Out of AI and the AI choice")
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
        // Not opted out, but the AI choice not made yet: both refuse.
        let restore = AITestSetting.save()
        defer { restore() }
        AITestSetting.clear()
        AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
        await #expect(throws: AIOffError.self) { try await client.sendCompletionsDirect(Self.request) }
        let nse = await BackendNSEClient.$transport.withValue(transport) { await nseSummary() }
        #expect(nse == nil)
        #expect(http.recordedCalls().count == 2)
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

    /// Files allowed to name the AI setting's keys: the policy and AIService that declare them,
    /// the writers (the AI choice, screenshot seeding, the debug reset), the Settings switch, and
    /// views that only hide AI content (reachable after the choice). Every other reader decides
    /// through `AIService.isAIOff` / `NSEState.isAIDisabled`.
    private static let keyNamingFiles: Set<String> = [
        "Shared/AI/AIConsentPolicy.swift",
        "TabMail/Services/AI/AIService.swift",
        "TabMail/Views/RootView.swift",
        "TabMail/App/ScreenshotMode.swift",
        "TabMail/Views/Settings/DebugLogView.swift",
        "TabMail/Views/Settings/TabMailSettingsView.swift",
        "TabMail/Views/Message/MessageCardView.swift",
        "TabMail/Views/Message/MessageDetailView.swift",
        "TabMail/Views/Message/SummaryBubbleView.swift",
        "TabMail/Views/Inbox/TriageCardView.swift",
        "TabMail/Views/Inbox/DynamicIslandChatButton.swift",
        "TabMail/Views/Inbox/MessageRowView.swift",
        // Display only: observes both values so the demo's AI section redraws; it records
        // through AIService.recordAIChoice.
        "TabMail/Views/Account/DemoAccountDashboardView.swift",
        // The chat screen only hides AI content, as the detail does (`AIWorkingRule`); it opens
        // through the chat view setting, which reads AIService.isAIOff.
        "TabMail/Views/Chat/ChatThreadView.swift",
        // The tutorial is a scripted demo and sends no AI request: whether it teaches the chat
        // view follows Opt Out of AI alone, so a tour before the AI choice teaches it.
        "TabMail/Services/Tutorial/TutorialCoordinator.swift",
    ]

    @Test("only the AI setting's own files name its keys; everything else reads the one predicate")
    func onlyThePolicyNamesTheKeys() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        var literals: Set<String> = []
        var keyNames: Set<String> = []
        for folder in ["TabMail", "Shared", "TabMailNotificationService"] {
            let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                let lines = Self.codeLines(try String(contentsOf: url, encoding: .utf8))
                if lines.contains(where: { $0.contains(#""privacy_opt_out_all_ai""#) || $0.contains(#""hasSeenAIConsent""#) }) {
                    literals.insert(relative)
                }
                let keyPattern = #"\b(optOutAllAIKey|aiChoiceMadeKey|completedChoiceKey|optOutKey)\b"#
                if lines.contains(where: { $0.range(of: keyPattern, options: .regularExpression) != nil }) {
                    keyNames.insert(relative)
                }
            }
        }
        #expect(literals == ["Shared/AI/AIConsentPolicy.swift"])
        #expect(keyNames.isSubset(of: Self.keyNamingFiles), "read the setting through AIService.isAIOff: \(keyNames.subtracting(Self.keyNamingFiles).sorted())")
        // The request and queue paths that read it decide only through the predicate.
        for path in [
            "TabMail/Services/AI/ActiveAIQueue.swift", "TabMail/Services/Account/AccountManagerAI.swift",
            "TabMail/Services/AI/KBRefinementService.swift", "TabMail/Services/Dictation/DictationController.swift",
            "TabMail/Views/MailNavigationView.swift",
        ] {
            #expect(!keyNames.contains(path), "\(path) names the setting's keys")
            #expect(Self.codeLines(try Self.source(path)).contains { $0.contains("AIService.isAIOff") }, "\(path) does not read AIService.isAIOff")
        }
    }
}
