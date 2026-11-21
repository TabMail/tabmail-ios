/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// No AI request leaves the device before the person has made the AI choice (the AI screen
/// shown after the first account is added). The state is the one a reinstall starts from: the
/// choice flag and the Opt Out of AI flag are both absent, the account is already added and its
/// mail is syncing, so the queue and the notification extension can already ask for summaries.
///
/// The clients use their default reading of the setting (the production predicate), the app's
/// summary goes through `AIService.generateSummary` and `BackendClient`, and the extension's
/// through `BackendNSEClient`, each to a fake backend that counts the requests it receives.
/// `.processGlobalState`: it clears and restores real `UserDefaults` keys other suites write.
@Suite(.serialized, .processGlobalState)
struct AIChoiceComesBeforeAnyRequestTests {

    private static let choiceKey = "hasSeenAIConsent"
    private static let answer = "event: final\ndata: {\"assistant\":\"Two-line summary: A short summary.\"}\n\n"

    /// Runs `body` with both flags absent, as after a reinstall (in the app's own defaults and in
    /// the App Group suite), then restores them.
    private func withChoiceNotMade<T>(_ body: () async throws -> T) async rethrows -> T {
        let standard = UserDefaults.standard
        let savedChoice = standard.object(forKey: Self.choiceKey)
        let restoreShared = AITestSetting.save()
        defer {
            if let savedChoice { standard.set(savedChoice, forKey: Self.choiceKey) } else { standard.removeObject(forKey: Self.choiceKey) }
            restoreShared()
        }
        standard.removeObject(forKey: Self.choiceKey)
        AITestSetting.clear()
        return try await body()
    }

    @Test("before the AI choice is made, neither the app nor the notification extension sends an AI request")
    func noRequestBeforeTheChoice() async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive && !DemoModeStore.shared.isTutorialPractice })
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST", response: .bytes(Data(Self.answer.utf8), contentType: "text/event-stream"))
        let service = AIService(backendClient: BackendClient(llmSession: http.session))
        let transport: BackendNSEClient.Transport = { try await http.session.data(for: $0) }

        try await withChoiceNotMade {
            #expect(UserDefaults.standard.bool(forKey: Self.choiceKey) == false)

            // The app: a summary job for a newly synced inbox message.
            let summary = try await service.generateSummary(
                subject: "Quarterly planning", from: "Sender", fromAddress: "sender@example.com", date: Date(),
                bodyText: "Notes from the planning call.", htmlContent: nil, userName: "Recipient", kbText: "")
            let appRequests = http.recordedCalls().count

            // The notification extension: a summary for a pushed message.
            let nse = await BackendNSEClient.$transport.withValue(transport) {
                await BackendNSEClient.sendCompletions(
                    promptAlias: "system_prompt_summary", variables: BackendNSEClient.Vars([:]), authToken: "test-token")
            }
            let nseRequests = http.recordedCalls().count - appRequests

            #expect(appRequests == 0, "the app sent \(appRequests) AI request(s) before the AI choice (summary: \(summary.blurb ?? "nil"))")
            #expect(nseRequests == 0, "the notification extension sent \(nseRequests) AI request(s) before the AI choice (answer: \(nse?.assistant ?? "nil"))")
        }
    }

    // MARK: - Fixtures

    /// A fresh, empty defaults suite for one test; removed when `body` ends.
    private static func withScratchDefaults<T>(_ count: Int, _ body: ([UserDefaults]) async throws -> T) async rethrows -> T {
        let names = (0..<count).map { _ in "test.ai-setting.\(UUID().uuidString)" }
        defer { for name in names { UserDefaults.standard.removePersistentDomain(forName: name) } }
        return try await body(names.map { UserDefaults(suiteName: $0)! })
    }

    private func summarize(_ service: AIService) async throws -> SummaryResult {
        try await service.generateSummary(
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@example.com", date: Date(),
            bodyText: "Notes from the planning call.", htmlContent: nil, userName: "Recipient", kbText: "")
    }

    private func nseSummary(_ transport: @escaping BackendNSEClient.Transport) async -> String? {
        await BackendNSEClient.$transport.withValue(transport) {
            await BackendNSEClient.sendCompletions(
                promptAlias: "system_prompt_summary", variables: BackendNSEClient.Vars([:]), authToken: "test-token")?.assistant
        }
    }

    private func answering() -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST", response: .bytes(Data(Self.answer.utf8), contentType: "text/event-stream"))
        return http
    }

    // MARK: - The predicate

    @Test("AI is on only when the choice is made and AI is not opted out; a missing value never turns it on",
          arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func thePredicate(choice: Bool?, optedOut: Bool?) async {
        await Self.withScratchDefaults(1) { suites in
            let defaults = suites[0]
            if let choice { defaults.set(choice, forKey: AIConsentPolicy.completedChoiceKey) }
            if let optedOut { defaults.set(optedOut, forKey: AIConsentPolicy.optOutKey) }
            let aiOn = choice == true && optedOut != true
            #expect(AIConsentPolicy.isDisabled(in: defaults) == !aiOn)
        }
    }

    // MARK: - Moving the setting into the shared suite

    @Test("an earlier completed choice moves to the shared suite; no choice moves as none")
    func theChoiceMoves() async {
        for legacyChoice in [nil, false, true] as [Bool?] {
            await Self.withScratchDefaults(2) { suites in
                let (legacy, shared) = (suites[0], suites[1])
                if let legacyChoice { legacy.set(legacyChoice, forKey: AIConsentPolicy.completedChoiceKey) }
                AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared)
                if legacyChoice == true {
                    #expect(shared.object(forKey: AIConsentPolicy.completedChoiceKey) as? Bool == true)
                    #expect(!AIConsentPolicy.isDisabled(in: shared))
                } else {
                    #expect(shared.object(forKey: AIConsentPolicy.completedChoiceKey) == nil)
                    #expect(AIConsentPolicy.isDisabled(in: shared))
                }
            }
        }
    }

    @Test("a value already in the shared suite is never overwritten, and a second run changes nothing")
    func sharedValuesStay() async {
        for sharedValue in [false, true] {
            await Self.withScratchDefaults(2) { suites in
                let (legacy, shared) = (suites[0], suites[1])
                legacy.set(!sharedValue, forKey: AIConsentPolicy.completedChoiceKey)
                legacy.set(!sharedValue, forKey: AIConsentPolicy.optOutKey)
                shared.set(sharedValue, forKey: AIConsentPolicy.completedChoiceKey)
                shared.set(sharedValue, forKey: AIConsentPolicy.optOutKey)
                #expect(AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared).isEmpty)
                #expect(shared.object(forKey: AIConsentPolicy.completedChoiceKey) as? Bool == sharedValue)
                #expect(shared.object(forKey: AIConsentPolicy.optOutKey) as? Bool == sharedValue)
                #expect(legacy.object(forKey: AIConsentPolicy.completedChoiceKey) == nil)
                #expect(legacy.object(forKey: AIConsentPolicy.optOutKey) == nil)
            }
        }
        await Self.withScratchDefaults(2) { suites in
            let (legacy, shared) = (suites[0], suites[1])
            legacy.set(true, forKey: AIConsentPolicy.completedChoiceKey)
            legacy.set(false, forKey: AIConsentPolicy.optOutKey)
            #expect(Set(AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared)) == [AIConsentPolicy.completedChoiceKey, AIConsentPolicy.optOutKey])
            #expect(AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared).isEmpty)
            #expect(!AIConsentPolicy.isDisabled(in: shared))
        }
    }

    @Test("a launch stopped after any write of the move never reads AI on for an earlier no, and the next launch finishes the move once without overwriting a newer answer",
          arguments: [true, false], [1, 2])
    func aStoppedMoveKeepsAnEarlierNo(earlierAnswer aiEnabled: Bool, stopAfterWrite k: Int) throws {
        for newerAnswerBeforeRelaunch in [false, true] {
            let legacyName = "test.ai-setting.legacy.\(UUID().uuidString)"
            let sharedName = "test.ai-setting.shared.\(UUID().uuidString)"
            defer {
                UserDefaults.standard.removePersistentDomain(forName: legacyName)
                UserDefaults.standard.removePersistentDomain(forName: sharedName)
            }
            let process = StoppingProcess(stopAfterSharedWrite: k)
            let legacy = try #require(StoppableDefaults(suiteName: legacyName, process: process, countsWrites: false))
            let shared = try #require(StoppableDefaults(suiteName: sharedName, process: process, countsWrites: true))
            legacy.set(true, forKey: AIConsentPolicy.completedChoiceKey)
            legacy.set(!aiEnabled, forKey: AIConsentPolicy.optOutKey)

            // The first launch stops right after shared write k; nothing after it is written.
            process.start()
            AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared)
            try #require(process.stopped, "the move has at least \(k) shared writes")
            let readsOffWhenStopped = AIConsentPolicy.isDisabled(in: UserDefaults(suiteName: sharedName)!)
            if !aiEnabled {
                #expect(readsOffWhenStopped, "an earlier no read AI on after write \(k) of the move")
            }

            // Between the stop and the relaunch the person may answer again in the new version.
            let fresh = UserDefaults(suiteName: sharedName)!
            if newerAnswerBeforeRelaunch {
                fresh.set(true, forKey: AIConsentPolicy.optOutKey)
                fresh.set(true, forKey: AIConsentPolicy.completedChoiceKey)
            }

            // The relaunch runs the move again to the end.
            let relaunchLegacy = UserDefaults(suiteName: legacyName)!
            AIConsentPolicy.migrateLegacyValues(from: relaunchLegacy, to: fresh)

            #expect(relaunchLegacy.object(forKey: AIConsentPolicy.completedChoiceKey) == nil, "the earlier choice is retired")
            #expect(relaunchLegacy.object(forKey: AIConsentPolicy.optOutKey) == nil, "the earlier opt-out is retired")
            #expect(AIConsentPolicy.migrateLegacyValues(from: relaunchLegacy, to: fresh).isEmpty, "the move happens once")
            #expect(fresh.object(forKey: AIConsentPolicy.completedChoiceKey) as? Bool == true)
            let expectedOptOut = newerAnswerBeforeRelaunch ? true : !aiEnabled
            #expect(fresh.object(forKey: AIConsentPolicy.optOutKey) as? Bool == expectedOptOut, "newer answer kept: \(newerAnswerBeforeRelaunch)")
            #expect(AIConsentPolicy.isDisabled(in: fresh) == expectedOptOut, "an earlier yes reads AI on unless a newer no replaced it")
        }
    }

    @Test("an earlier opt-out moves in the same step as the choice, so the moved setting never reads AI on")
    func anEarlierOptOutMovesWithTheChoice() async {
        await Self.withScratchDefaults(2) { suites in
            let (legacy, shared) = (suites[0], suites[1])
            legacy.set(true, forKey: AIConsentPolicy.completedChoiceKey)
            legacy.set(true, forKey: AIConsentPolicy.optOutKey)
            AIConsentPolicy.migrateLegacyValues(from: legacy, to: shared)
            #expect(shared.object(forKey: AIConsentPolicy.optOutKey) as? Bool == true)
            #expect(AIConsentPolicy.isDisabled(in: shared))
        }
    }

    @Test("the setting moves first on every launch, before anything else the app runs")
    func theMoveRunsFirst() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        let app = try String(contentsOf: root.appendingPathComponent("TabMail/App/TabMailApp.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        let start = try #require(app.firstIndex(of: "init() {"))
        #expect(app[start + 1].contains("AIConsentPolicy.migrateLegacyValues(from: .standard, to: AIService.optOutStore)"),
                "first statement of TabMailApp.init: \(app[start + 1])")
        let delegate = try String(contentsOf: root.appendingPathComponent("TabMail/App/AppDelegate.swift"), encoding: .utf8)
        #expect(!delegate.contains("optOut"), "the delegate runs no second, later move")

        // No other production code moves the setting.
        let callers = try ["TabMail", "TabMailNotificationService", "Shared"].flatMap { dir -> [String] in
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            return try files.filter { file in
                try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                    .contains { $0.contains("migrateLegacyValues(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            }.map(\.lastPathComponent)
        }
        #expect(callers.sorted() == ["AIConsentPolicy.swift", "TabMailApp.swift"], "\(callers)")
    }

    // MARK: - The notification extension before the app's first launch

    @Test("the extension sends nothing until the app has moved the choice; then it sends")
    func theExtensionWaitsForTheMove() async throws {
        let http = answering()
        defer { http.close() }
        let transport: BackendNSEClient.Transport = { try await http.session.data(for: $0) }
        try await withChoiceNotMade {
            try await Self.withScratchDefaults(1) { suites in
                // An earlier version answered the choice: the answer is only in the app's defaults.
                let legacy = suites[0]
                legacy.set(true, forKey: AIConsentPolicy.completedChoiceKey)
                legacy.set(false, forKey: AIConsentPolicy.optOutKey)
                #expect(await nseSummary(transport) == nil)
                #expect(http.recordedCalls().isEmpty)

                AIConsentPolicy.migrateLegacyValues(from: legacy, to: AIService.optOutStore)
                let answer = try #require(await nseSummary(transport))
                #expect(!answer.isEmpty)
                #expect(http.recordedCalls().count == 1)
            }
        }
    }

    // MARK: - The queue holds until the choice

    @Test("queued jobs run only with AI on, or with Device Sync for its cache alone",
          arguments: [false, true], [false, true])
    func theQueueGate(aiOff: Bool, deviceSync: Bool) {
        #expect(ActiveAIQueue.canProcessAI(
            hasSession: true, hasCompletedConsent: true, aiOff: aiOff,
            deviceSyncConnected: deviceSync, subscriptionActive: true) == (!aiOff || deviceSync))
        for missing in 0..<3 {
            #expect(!ActiveAIQueue.canProcessAI(
                hasSession: missing != 0, hasCompletedConsent: missing != 1, aiOff: false,
                deviceSyncConnected: deviceSync, subscriptionActive: missing != 2))
        }
    }

    @Test("before the choice the queue reads AI as off; once AI is enabled there it reads it on")
    func theQueueReadsTheChoice() async {
        await withChoiceNotMade {
            #expect(AIService.isAIOff)
            #expect(!ActiveAIQueue.canProcessAI(
                hasSession: true, hasCompletedConsent: true, aiOff: AIService.isAIOff,
                deviceSyncConnected: false, subscriptionActive: true))
            AIConsentPolicy.recordChoice(aiEnabled: true, in: AIService.optOutStore)
            #expect(ActiveAIQueue.canProcessAI(
                hasSession: true, hasCompletedConsent: true, aiOff: AIService.isAIOff,
                deviceSyncConnected: false, subscriptionActive: true))
        }
    }

    // MARK: - Answering the choice

    @Test("answering writes the opt-out before the choice; enabling AI resumes the held mail, declining resumes nothing",
          arguments: [false, true])
    func answeringTheChoice(aiEnabled: Bool) async throws {
        let store = try #require(WriteRecordingDefaults(suiteName: "test.ai-setting.\(UUID().uuidString)"))
        defer { UserDefaults.standard.removePersistentDomain(forName: store.name) }
        let resumed = ResumeCount()

        AIService.recordAIChoice(aiEnabled: aiEnabled, in: store) { resumed.add() }
        #expect(store.writes == [AIConsentPolicy.optOutKey, AIConsentPolicy.completedChoiceKey])
        #expect(store.object(forKey: AIConsentPolicy.optOutKey) as? Bool == !aiEnabled)
        #expect(AIConsentPolicy.isDisabled(in: store) == !aiEnabled)

        // The resume runs in its own task: give it time to run, or to show it never does.
        for _ in 0..<50 where resumed.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(resumed.count == (aiEnabled ? 1 : 0))
    }

    @Test("after declining, nothing is sent; after enabling, the next summary is sent")
    func theAnswerDecidesWhatIsSent() async throws {
        for aiEnabled in [false, true] {
            let http = answering()
            defer { http.close() }
            let service = AIService(backendClient: BackendClient(llmSession: http.session))
            try await withChoiceNotMade {
                AIService.recordAIChoice(aiEnabled: aiEnabled) {}
                _ = try await summarize(service)
                #expect(http.recordedCalls().count == (aiEnabled ? 1 : 0))
            }
        }
    }

    @Test("enabling AI on the choice offers the inbox mail held while it was open to the queue again; declining offers nothing")
    func enablingOffersTheHeldMail() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-ai-choice"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        var header = MessageHeader(
            messageId: "1", subject: "Quarterly planning", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "Notes from the planning call.",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
            accountId: accountId, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<held-1@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        let held = header
        try await pool.write { db in try held.insert(db) }

        // The queue the production default resume offers to; dispatch is held so the offer is observable.
        let queue = ActiveAIQueue.shared
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(true)
        func offered() async -> Bool { await queue.queuedJobsForTesting.contains { $0.headerId == held.id } }

        await Self.withScratchDefaults(1) { suites in
            AIService.recordAIChoice(aiEnabled: false, in: suites[0])
            try? await Task.sleep(for: .milliseconds(300))
            let offeredAfterDeclining = await offered()
            #expect(!offeredAfterDeclining, "declining offers nothing")

            // The default resume, as RootView records the choice. A recent cancel delays it up to 2s.
            AIService.recordAIChoice(aiEnabled: true, in: suites[0])
            var waited = 0
            while !(await offered()), waited < 100 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            #expect(await offered(), "the held message is offered to the queue again")
        }
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }
}

/// Records the order of the keys written to it, once per write (a Bool write that Foundation
/// passes on to the object setter is not counted twice).
private final class WriteRecordingDefaults: UserDefaults {
    private(set) var writes: [String] = []
    private var inBoolWrite = false
    let name: String

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        name = suiteName
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if !inBoolWrite { writes.append(defaultName) }
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        writes.append(defaultName)
        inBoolWrite = true
        defer { inBoolWrite = false }
        super.set(value, forKey: defaultName)
    }
}

/// Counts resume calls from another task.
private final class ResumeCount: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add() { value.withLock { $0 += 1 } }
}

/// One launch of the app that stops right after its k-th write to the shared suite: from then
/// on no write or removal reaches either suite, as when the process ends at that point.
private final class StoppingProcess {
    let stopAfterSharedWrite: Int
    private(set) var sharedWrites = 0
    private(set) var running = false
    private(set) var stopped = false

    init(stopAfterSharedWrite: Int) { self.stopAfterSharedWrite = stopAfterSharedWrite }

    func start() { running = true }

    /// Whether a change may still be written.
    var writes: Bool { !(running && stopped) }

    func didWriteShared() {
        guard running else { return }
        sharedWrites += 1
        if sharedWrites == stopAfterSharedWrite { stopped = true }
    }
}

private final class StoppableDefaults: UserDefaults {
    private let process: StoppingProcess
    private let countsWrites: Bool

    init?(suiteName: String, process: StoppingProcess, countsWrites: Bool) {
        self.process = process
        self.countsWrites = countsWrites
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard process.writes else { return }
        super.set(value, forKey: defaultName)
        if countsWrites { process.didWriteShared() }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(NSNumber(value: value) as Any?, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard process.writes else { return }
        super.removeObject(forKey: defaultName)
    }
}
