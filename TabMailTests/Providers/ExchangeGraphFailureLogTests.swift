/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// A refused Graph request names Graph's error in the debug log, only while debug
/// logging is on, and never writes the request (its subject, body, recipient or
/// token) to any channel. The refusal still reaches the caller unchanged.
///
/// `.serialized, .processGlobalState`: these tests rebind the process-global
/// `AppLogStore.fileURLOverride` and `DebugModeManager.loggingEnabledOverrideForTesting`.
@Suite("Graph failures in the debug log", .serialized, .processGlobalState)
struct ExchangeGraphFailureLogTests {
    private static let token = "synthetic-access-token-7f3a"
    private static let subject = "Distinct subject 41c9"
    private static let body = "Distinct body text 9d2e"
    private static let recipient = "distinct-recipient-5b1@example.com"

    private static let graphError = FakeHTTP.CannedResponse.json(
        raw: #"{"error":{"code":"SomeCode","message":"Some message"}}"#, statusCode: 400)

    private func refusedReply(loggingEnabled: Bool, response: FakeHTTP.CannedResponse = graphError) async -> (error: (any Error)?, log: String, debug: String, otherChannels: [AppLogChannel: String]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphfailurelog_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = loggingEnabled }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: response)
        let provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in Self.token }, session: http.session)
        let draft = DraftMessage(to: [Self.recipient], subject: Self.subject, body: Self.body,
                                 inReplyTo: "parent@example.com", references: ["parent@example.com"])
        var thrown: (any Error)?
        do {
            try await provider.send(draft: draft)
        } catch {
            thrown = error
        }
        let others = Dictionary(uniqueKeysWithValues: AppLogChannel.allCases.filter { $0 != .debug }
            .map { ($0, AppLogStore.read(channel: $0)) })
        return (thrown, AppLogStore.read(), AppLogStore.read(channel: .debug), others)
    }

    private static func expectRefusal(_ error: (any Error)?, status expected: Int = 400) {
        guard let failure = error as? ProviderError, case .networkError(let underlying) = failure,
              let httpFailure = underlying as? HTTPError, case .networkError(let status) = httpFailure else {
            Issue.record("the refusal must reach the caller as networkError(\(expected)), got \(String(describing: error))")
            return
        }
        #expect(status == expected)
    }

    @Test("With debug logging on, the debug channel names Graph's error and no channel holds the request")
    func loggedWhileUnlocked() async {
        let result = await refusedReply(loggingEnabled: true)

        Self.expectRefusal(result.error)
        #expect(result.debug.contains("HTTP 400"))
        #expect(result.debug.contains("SomeCode: Some message"))
        for secret in [Self.token, Self.subject, Self.body, Self.recipient] {
            #expect(!result.log.contains(secret), "the log must not hold \(secret)")
        }
        for channel in AppLogChannel.allCases where channel != .debug {
            #expect(!result.otherChannels[channel, default: ""].contains("SomeCode"),
                    "Graph's message goes only to the debug channel, not \(channel)")
        }
    }

    @Test("With debug logging off, nothing about the refusal is written")
    func silentWhileLocked() async {
        let result = await refusedReply(loggingEnabled: false)

        Self.expectRefusal(result.error)
        #expect(!result.log.contains("SomeCode"))
    }

    @Test("With debug logging on, a refusal without a usable Graph error still reaches the caller unchanged")
    func refusalWithoutGraphError() async {
        let result = await refusedReply(loggingEnabled: true, response: .status(503))

        Self.expectRefusal(result.error, status: 503)
        #expect(result.debug.contains("HTTP 503"))
        for secret in [Self.token, Self.subject, Self.body, Self.recipient] {
            #expect(!result.log.contains(secret), "the log must not hold \(secret)")
        }
    }
}
