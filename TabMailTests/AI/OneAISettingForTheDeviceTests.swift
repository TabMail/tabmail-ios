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
}
