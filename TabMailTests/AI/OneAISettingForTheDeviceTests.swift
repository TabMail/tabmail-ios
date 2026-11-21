/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The device has one AI setting (the AI choice and Opt Out of AI), used by the demo and by the
/// person's own accounts. An answer given while trying the demo is never applied to the person's
/// own mail: signing in to TabMail on a device with no mail account clears it, so the AI screen
/// asks again after the first account is added, and nothing is sent until it is answered.
///
/// Requests are counted at a fake backend, from the app (`AIService` through `BackendClient`,
/// default reading of the setting) and from the notification extension (`BackendNSEClient`).
/// `.processGlobalState`: it writes the real App Group values and the shared app database.
@Suite(.serialized, .processGlobalState)
struct OneAISettingForTheDeviceTests {

    private static let answer = "event: final\ndata: {\"assistant\":\"Two-line summary: A short summary.\"}\n\n"

    // MARK: - Fixtures

    private func answering() -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST", response: .bytes(Data(Self.answer.utf8), contentType: "text/event-stream"))
        return http
    }

    /// Requests sent for one summary from the app and one from the notification extension.
    private func requestsForOneMessage(_ http: FakeHTTP.Scenario) async throws -> (app: Int, nse: Int) {
        let before = http.recordedCalls().count
        let service = AIService(backendClient: BackendClient(llmSession: http.session))
        _ = try await service.generateSummary(
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@example.com", date: Date(),
            bodyText: "Notes from the planning call.", htmlContent: nil, userName: "Recipient", kbText: "")
        let app = http.recordedCalls().count - before
        let transport: BackendNSEClient.Transport = { try await http.session.data(for: $0) }
        _ = await BackendNSEClient.$transport.withValue(transport) {
            await BackendNSEClient.sendCompletions(
                promptAlias: "system_prompt_summary", variables: BackendNSEClient.Vars([:]), authToken: "test-token")
        }
        return (app, http.recordedCalls().count - before - app)
    }

    /// Runs `body` with an empty app database and the App Group AI values restored afterwards.
    private func withDeviceState<T>(_ body: (DatabasePool) async throws -> T) async throws -> T {
        let restoreSetting = AITestSetting.save()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            restoreSetting()
        }
        AITestSetting.clear()
        return try await body(pool)
    }

    /// The demo's AI screen answered, as RootView's demo branch records it.
    private func answerTheDemosAIScreen(aiEnabled: Bool) {
        AIService.recordAIChoice(aiEnabled: aiEnabled, resume: {})
    }

    /// A TabMail sign-in, at the point where the session is written. The accounts are counted
    /// the production way, from the app database (`pool`, installed as `AppDatabase.shared`).
    private func signIn(_ pool: DatabasePool) async {
        await TabMailAuthService.clearAIChoiceIfNoMailAccount()
    }

    private func addMailAccount(_ id: String, pool: DatabasePool) throws {
        _ = try FolderEpochTestFixture.makeAccount(id: id, provider: .imap, pool: pool)
    }

    /// After the demo and a sign-in with no mail account: once an account is added, nothing is
    /// sent from the app or the extension until the real AI screen is answered; then it is.
    private func expectAskedAgain(_ pool: DatabasePool) async throws {
        try addMailAccount("account-one", pool: pool)
        let http = answering()
        defer { http.close() }

        #expect(AIService.isAIOff)
        #expect(!ActiveAIQueue.canProcessAI(
            hasSession: true, hasCompletedConsent: true, aiOff: AIService.isAIOff,
            deviceSyncConnected: false, subscriptionActive: true))
        let held = try await requestsForOneMessage(http)
        #expect(held.app == 0, "the app sent \(held.app) AI request(s) on the demo's answer")
        #expect(held.nse == 0, "the extension sent \(held.nse) AI request(s) on the demo's answer")

        AIService.recordAIChoice(aiEnabled: true, resume: {})
        let answered = try await requestsForOneMessage(http)
        #expect(answered.app == 1 && answered.nse == 1, "after the real AI screen: \(answered)")
    }

    // MARK: - An answer given in the demo

    @Test("an AI answer given in the demo is asked again once the person signs in and adds an account",
          arguments: [true, false])
    func theDemosAnswerIsAskedAgain(demoAnswer: Bool) async throws {
        try await withDeviceState { pool in
            answerTheDemosAIScreen(aiEnabled: demoAnswer)
            #expect(AIService.isAIOff == !demoAnswer)

            await signIn(pool)

            #expect(AIService.optOutStore.object(forKey: AIService.aiChoiceMadeKey) == nil)
            #expect(AIService.optOutStore.object(forKey: AIService.optOutAllAIKey) == nil)
            try await expectAskedAgain(pool)
        }
    }

    @Test("a demo account row left by an unfinished cleanup does not count as the person's account")
    func aLeftoverDemoRowIsNotAnAccount() async throws {
        try await withDeviceState { pool in
            answerTheDemosAIScreen(aiEnabled: true)
            // The demo ended but its cleanup did not finish: its account row is still there.
            _ = try FolderEpochTestFixture.makeAccount(id: DemoSeed.demoAccountId, provider: .imap, pool: pool)

            await signIn(pool)

            try await expectAskedAgain(pool)
        }
    }

    @Test("an AI answer given in a demo the app was closed in is asked again after sign-in")
    func aDemoClosedMidwayIsAskedAgain() async throws {
        try await withDeviceState { pool in
            await MainActor.run {
                DemoModeStore.shared._resetForTests()
                DemoModeStore.shared.isActive = true
            }
            answerTheDemosAIScreen(aiEnabled: true)
            _ = try FolderEpochTestFixture.makeAccount(id: DemoSeed.demoAccountId, provider: .imap, pool: pool)
            // The app is closed in the demo, with no exit: the next launch starts with the demo
            // off in memory, and its rows still on disk.
            await MainActor.run { DemoModeStore.shared._resetForTests() }

            await signIn(pool)

            try await expectAskedAgain(pool)
        }
    }

    // MARK: - An existing answer

    @Test("signing in with a mail account on the device keeps the answer already given",
          arguments: [true, false])
    func anExistingAnswerIsKept(aiEnabled: Bool) async throws {
        try await withDeviceState { pool in
            try addMailAccount("account-one", pool: pool)
            AIService.recordAIChoice(aiEnabled: aiEnabled, resume: {})

            // The same person signing in again, or another person, on a device with mail accounts.
            await signIn(pool)

            #expect(AIService.optOutStore.object(forKey: AIService.aiChoiceMadeKey) as? Bool == true)
            #expect(AIService.optOutStore.object(forKey: AIService.optOutAllAIKey) as? Bool == !aiEnabled)
            let http = answering()
            defer { http.close() }
            let sent = try await requestsForOneMessage(http)
            #expect(sent.app == (aiEnabled ? 1 : 0) && sent.nse == (aiEnabled ? 1 : 0), "\(sent)")
        }
    }

    @Test("the AI choice is removed before Opt Out of AI, so AI never reads as on in between; the answer stays when there is a mail account")
    func theChoiceGoesFirst() throws {
        for (count, cleared) in [(0, true), (1, false)] {
            let store = try #require(RemovalRecordingDefaults(suiteName: "test.ai-setting.\(UUID().uuidString)"))
            defer { UserDefaults.standard.removePersistentDomain(forName: store.name) }
            AIConsentPolicy.recordChoice(aiEnabled: true, in: store)

            TabMailAuthService.clearAIChoice(mailAccountCount: count, in: store)

            #expect(store.removals == (cleared ? [AIConsentPolicy.completedChoiceKey, AIConsentPolicy.optOutKey] : []))
            #expect(store.disabledAfterEachRemoval.allSatisfy { $0 })
            #expect(AIConsentPolicy.isDisabled(in: store) == cleared)
        }
    }

    @Test("when the accounts cannot be counted, the answer is cleared")
    func anUnreadableCountClears() throws {
        let store = try #require(RemovalRecordingDefaults(suiteName: "test.ai-setting.\(UUID().uuidString)"))
        defer { UserDefaults.standard.removePersistentDomain(forName: store.name) }
        AIConsentPolicy.recordChoice(aiEnabled: true, in: store)

        TabMailAuthService.clearAIChoice(mailAccountCount: nil, in: store)

        #expect(store.object(forKey: AIConsentPolicy.completedChoiceKey) == nil)
        #expect(store.object(forKey: AIConsentPolicy.optOutKey) == nil)
    }

    // MARK: - Where it runs

    @Test("each sign-in clears before it writes the session, and nothing else clears")
    func everySessionWriteClearsFirst() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        let auth = try String(contentsOf: root.appendingPathComponent("TabMail/Services/TabMailAuthService.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        let writes = auth.indices.filter { auth[$0].contains("installNewSession(") }
        #expect(writes.count == 3, "session writes: \(writes.map { auth[$0] })")
        for index in writes {
            #expect(index > 0 && auth[index - 1] == "await Self.clearAIChoiceIfNoMailAccount()",
                    "before \(auth[index]): \(index > 0 ? auth[index - 1] : "")")
        }

        let callers = try ["TabMail", "TabMailNotificationService", "Shared"].flatMap { dir -> [String] in
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            return try files.flatMap { file in
                try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                    .filter { $0.contains("clearAIChoiceIfNoMailAccount(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                        && !$0.contains("static func") }
                    .map { _ in file.lastPathComponent }
            }
        }
        #expect(callers == Array(repeating: "TabMailAuthService.swift", count: 3), "\(callers)")

        // Only the sign-in step clears the device's AI answer.
        let clearers = try ["TabMail", "TabMailNotificationService", "Shared"].flatMap { dir -> [String] in
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            return try files.flatMap { file in
                try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                    .filter { $0.contains("AIConsentPolicy.clearChoice(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .map { _ in file.lastPathComponent }
            }
        }
        #expect(clearers == ["TabMailAuthService+AIChoice.swift"], "\(clearers)")
    }

    // MARK: - An answer from an earlier version

    @Test("an answer moved from an earlier version and cleared at sign-in does not come back on the next launch",
          arguments: [true, false])
    func aClearedMovedAnswerStaysCleared(earlierAnswer aiEnabled: Bool) async throws {
        try await withDeviceState { pool in
            let legacyName = "test.ai-setting.legacy.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: legacyName) }
            let legacy = try #require(UserDefaults(suiteName: legacyName))
            // An earlier version: the choice in the app's own defaults, the opt-out already in the shared suite.
            legacy.set(true, forKey: AIConsentPolicy.completedChoiceKey)
            AIService.optOutStore.set(!aiEnabled, forKey: AIService.optOutAllAIKey)

            AIConsentPolicy.migrateLegacyValues(from: legacy, to: AIService.optOutStore)
            #expect(AIService.isAIOff == !aiEnabled, "the first launch keeps the earlier answer")

            await signIn(pool)
            try addMailAccount("account-one", pool: pool)
            // The app is closed before the AI screen is answered; the next launch moves values again.
            AIConsentPolicy.migrateLegacyValues(from: legacy, to: AIService.optOutStore)

            #expect(AIService.optOutStore.object(forKey: AIService.aiChoiceMadeKey) == nil)
            let http = answering()
            defer { http.close() }
            let held = try await requestsForOneMessage(http)
            #expect(held.app == 0 && held.nse == 0, "sent before a new answer: \(held)")

            AIService.recordAIChoice(aiEnabled: true, resume: {})
            let answered = try await requestsForOneMessage(http)
            #expect(answered.app == 1 && answered.nse == 1, "after the new answer: \(answered)")
        }
    }

    // MARK: - The sign-in step itself

    @Test("at sign-in, accounts that cannot be counted clear the answer; a counted account keeps it")
    func theSignInStepClearsWhenTheCountFails() async throws {
        try await withDeviceState { _ in
            AIService.recordAIChoice(aiEnabled: true, resume: {})
            await TabMailAuthService.clearAIChoiceIfNoMailAccount(countMailAccounts: { 1 })
            #expect(!AIService.isAIOff, "a counted account keeps the answer")

            struct Unreadable: Error {}
            await TabMailAuthService.clearAIChoiceIfNoMailAccount(countMailAccounts: { throw Unreadable() })
            #expect(AIService.optOutStore.object(forKey: AIService.aiChoiceMadeKey) == nil)
            #expect(AIService.optOutStore.object(forKey: AIService.optOutAllAIKey) == nil)
            let http = answering()
            defer { http.close() }
            let sent = try await requestsForOneMessage(http)
            #expect(sent.app == 0 && sent.nse == 0, "\(sent)")
        }
    }

    // MARK: - The demo's screens

    @Test("the demo's AI screen and its Settings buttons record the device's AI setting")
    func theDemoScreensRecordTheDeviceSetting() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        func code(_ path: String) throws -> [String] {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        }
        // RootView's demo branch: the AI screen is shown while the device has no choice, and records it.
        let root_ = try code("TabMail/Views/RootView.swift")
        let demoStart = try #require(root_.firstIndex(of: "} else if demoStore.isActive {"))
        let demoEnd = try #require(root_[demoStart...].firstIndex(of: "} else if hasEmailAccounts && !hasTabMailSession {"))
        let demo = Array(root_[demoStart..<demoEnd])
        let screen = try #require(demo.firstIndex(of: "} else if !hasSeenAIConsent && !tutorial.isRunning {"))
        #expect(demo[screen + 1] == "AIConsentView { aiEnabled in")
        let closeOfScreen = try #require(demo[screen...].firstIndex(of: "} else if !demoSeedingComplete {"))
        #expect(demo[screen..<closeOfScreen].contains("withAnimation { AIService.recordAIChoice(aiEnabled: aiEnabled, resume: {}) }"))
        #expect(!demo.contains { $0.contains("demo.") && $0.contains("AI") }, "no demo AI key in the demo branch")

        // The demo Settings page: "Turn off AI" and the "Enable AI" sheet.
        let dashboard = try code("TabMail/Views/Account/DemoAccountDashboardView.swift")
        #expect(dashboard.filter { $0 == "AIService.recordAIChoice(aiEnabled: false, resume: {})" }.count == 1)
        let sheet = try #require(dashboard.firstIndex(of: "AIConsentView { aiEnabled in"))
        #expect(dashboard[sheet + 1] == "AIService.recordAIChoice(aiEnabled: aiEnabled, resume: {})")
        #expect(dashboard.contains("if !AIConsentPolicy.isDisabled(choiceMade: aiChoiceMade, optedOut: aiOptedOut) {"))
        #expect(!dashboard.contains { $0.contains("store.aiEnabled") })
    }
}

/// Records the order of the keys removed from it, and whether AI read as off after each removal.
/// Used synchronously on the test's own task.
private final class RemovalRecordingDefaults: UserDefaults {
    private(set) var removals: [String] = []
    private(set) var disabledAfterEachRemoval: [Bool] = []
    let name: String

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        name = suiteName
        super.init(suiteName: suiteName)
    }

    override func removeObject(forKey defaultName: String) {
        removals.append(defaultName)
        super.removeObject(forKey: defaultName)
        disabledAfterEachRemoval.append(AIConsentPolicy.isDisabled(in: self))
    }
}
