/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
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

    /// Runs `body` with both flags absent, as after a reinstall, then restores them.
    private func withChoiceNotMade<T>(_ body: () async throws -> T) async rethrows -> T {
        let standard = UserDefaults.standard
        let group = AIService.optOutStore
        let savedChoice = standard.object(forKey: Self.choiceKey)
        let savedOptOut = group.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let savedChoice { standard.set(savedChoice, forKey: Self.choiceKey) } else { standard.removeObject(forKey: Self.choiceKey) }
            if let savedOptOut { group.set(savedOptOut, forKey: AIService.optOutAllAIKey) } else { group.removeObject(forKey: AIService.optOutAllAIKey) }
        }
        standard.removeObject(forKey: Self.choiceKey)
        group.removeObject(forKey: AIService.optOutAllAIKey)
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
                subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com", date: Date(),
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
}
