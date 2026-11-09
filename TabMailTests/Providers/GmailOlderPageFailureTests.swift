/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Loading older Gmail mail as the list scrolls
/// (`GmailProvider.fetchOlderMessagesWithCoverage`) keeps the rest of a page
/// when one message's fetch fails with an answer about that message: a gone
/// message (404, 410) or any other unusable answer (400, 503, an unreadable
/// body). That message is reported as named but not loaded. A failure that is
/// not an answer about the message (a dropped connection, a 401 the token
/// refresh did not cure, cancellation) still fails the page.
@Suite("A Gmail older-mail page survives one message that fails to load")
struct GmailOlderPageFailureTests {

    private static func scenario(ids: [String], responses: [String: FakeHTTP.CannedResponse]) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/messages", method: "GET") { request in
            let id = request.url.lastPathComponent
            if id == "messages" {
                let refs = ids.map { #"{ "id": "\#($0)", "threadId": "t-\#($0)" }"# }
                return .json(raw: #"{ "messages": [ \#(refs.joined(separator: ", ")) ], "resultSizeEstimate": \#(ids.count) }"#)
            }
            return responses[id] ?? .json(raw: DeltaDetailFetchFailureTests.gmailMessageJSON(id: id))
        }
        return scenario
    }

    private static func provider(_ scenario: FakeHTTP.Scenario) -> GmailProvider {
        GmailProvider(
            userEmail: "gmail-older-page@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)
    }

    @Test("A gone message and an unusable answer do not stop the page")
    func goneAndUnusableMessagesDoNotStopThePage() async throws {
        let ids = ["ok-1", "gone-1", "gone-2", "bad-1", "down-1", "body-1", "ok-2"]
        let scenario = Self.scenario(ids: ids, responses: [
            "gone-1": .status(404),
            "gone-2": .status(410),
            "bad-1": .status(400),
            "down-1": .status(503),
            "body-1": .json(raw: "not a message"),
        ])
        defer { scenario.close() }

        let page = try await Self.provider(scenario).fetchOlderMessagesWithCoverage(
            folder: "INBOX", before: Date(), limit: ids.count)

        #expect(page.messages.map(\.messageId) == ["ok-1", "ok-2"],
                "every message the server answered for usably must load")
        #expect(page.coverage.unmaterialisedIds == ["gone-1", "gone-2", "bad-1", "down-1", "body-1"],
                "a message that failed to load stays named, not loaded")
        #expect(page.coverage.serverRecordCount == ids.count)
    }

    @Test("A failure that is not an answer about the message still fails the page",
          arguments: [FakeHTTP.CannedResponse.status(401), .transportError(.networkConnectionLost)])
    func aNonAnswerFailsThePage(failure: FakeHTTP.CannedResponse) async throws {
        let ids = ["ok-1", "stuck-1"]
        let scenario = Self.scenario(ids: ids, responses: ["stuck-1": failure])
        defer { scenario.close() }

        await #expect(throws: (any Error).self) {
            _ = try await Self.provider(scenario).fetchOlderMessagesWithCoverage(
                folder: "INBOX", before: Date(), limit: ids.count)
        }
    }

    /// A page cancelled while a message fetch waits out Gmail's rate-limit
    /// backoff is not a page: it must fail, not report the messages it never
    /// read as named but not loaded.
    @Test("A cancelled older-mail page fails instead of reporting coverage")
    func aCancelledPageFails() async throws {
        let ids = ["slow-1", "ok-2"]
        let scenario = Self.scenario(ids: ids, responses: ["slow-1": .status(429)])
        defer { scenario.close() }
        let provider = Self.provider(scenario)
        func asked() -> Set<String> {
            Set(scenario.recordedCalls().map { URL(string: $0.url)?.lastPathComponent ?? "" })
        }

        let fetch = Task {
            try await provider.fetchOlderMessagesWithCoverage(folder: "INBOX", before: Date(), limit: ids.count)
        }
        // The first 429 starts a backoff of `initialDelay`; cancel once the
        // message has been asked for, well inside that wait.
        let backoff = Duration.seconds(HTTPRetryPolicy.gmail.initialDelay)
        let deadline = ContinuousClock.now + backoff
        while ContinuousClock.now < deadline, !asked().contains("slow-1") {
            try await Task.sleep(for: backoff / 100)
        }
        #expect(asked().contains("slow-1"), "the message fetch never started")
        fetch.cancel()

        if case .success(let page) = await fetch.result {
            Issue.record("a cancelled older-mail page reported coverage; unmaterialised: \(page.coverage.unmaterialisedIds.sorted())")
        }
        #expect(!asked().contains("ok-2"), "a cancelled page asks for nothing more")
    }
}
