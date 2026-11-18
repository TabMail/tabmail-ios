/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Every SEARCH caller reads its answer through `ExtendedSearchResult.listed()`
/// (or `listed(within:)`): an answer that reports matches without listing them,
/// or names UIDs outside the request, fails that caller. It never reads as
/// "nothing found". One test per caller, so reverting any one of them to the
/// old empty-set default fails here even while the shared reader is intact.
@Suite("SEARCH answers that list nothing fail every caller", .serialized)
struct SearchAnswerRefusalCallerTests {
    static let capabilities = FakeIMAPServer.defaultCapabilities + ["ESEARCH"]
    static let unlisted = "COUNT 2"

    static func withProvider(
        _ body: (FakeIMAPServer, IMAPProvider) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(capabilities: capabilities,
                                    mailboxes: ["INBOX": [5, 6, 7].map(IMAPChangeReaderTests.message)])
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        try await body(server, provider)
    }

    @Test("searchExistingUIDs over a UID range: an unlisted answer and an answer outside the range both fail; a listed answer inside it is read",
          arguments: ["unlisted", "outOfScope", "control"])
    func rangeOverload(_ answer: String) async throws {
        try await Self.withProvider { server, provider in
            switch answer {
            case "unlisted": server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            case "outOfScope": server.answerNextUIDSearch(in: "INBOX", all: "900")
            default: server.answerNextUIDSearch(in: "INBOX", all: "5:6")
            }
            if answer == "control" {
                let found = try await provider.searchExistingUIDs(folder: "INBOX", from: 1, to: 10)
                #expect(Set(found) == [5, 6])
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.searchExistingUIDs(folder: "INBOX", from: 1, to: 10)
                }
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("searchExistingUIDs over explicit UIDs: an unlisted answer and an answer outside the request both fail; a listed answer inside it is read",
          arguments: ["unlisted", "outOfScope", "control"])
    func uidsOverload(_ answer: String) async throws {
        try await Self.withProvider { server, provider in
            switch answer {
            case "unlisted": server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            case "outOfScope": server.answerNextUIDSearch(in: "INBOX", all: "900")
            default: server.answerNextUIDSearch(in: "INBOX", all: "5")
            }
            if answer == "control" {
                let result = try await provider.searchExistingUIDs(folder: "INBOX", uids: [5, 6])
                #expect(result.found == [5])
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.searchExistingUIDs(folder: "INBOX", uids: [5, 6])
                }
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("App search: an unlisted answer fails the search, never an empty result")
    func appSearch() async throws {
        try await Self.withProvider { server, provider in
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            await #expect(throws: (any Error).self) {
                _ = try await provider.search(query: "anything", folder: "INBOX")
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("Older-mail date lookup: an unlisted answer fails the lookup, with and without a start date",
          arguments: [true, false])
    func olderMailDateLookup(_ withSince: Bool) async throws {
        try await Self.withProvider { server, provider in
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            let since = withSince ? Date().addingTimeInterval(-30 * 86_400) : nil
            await #expect(throws: (any Error).self) {
                _ = try await provider.searchBackfillUIDs(folder: "INBOX", since: since)
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("Message-ID lookup in the app: an unlisted answer fails it, to the bracketed search or (after an empty bracketed answer) to the bare one",
          arguments: ["bracketed", "bare"])
    func appMessageIdLookup(_ which: String) async throws {
        try await Self.withProvider { server, provider in
            if which == "bare" { server.answerNextUIDSearch(in: "INBOX", esearchData: "") }
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            await #expect(throws: (any Error).self) {
                _ = try await provider.currentUIDs(rfc822MessageId: "lookup@example.com", folderPath: "INBOX")
            }
            #expect(server.compactUIDSearchAnswersServed() == (which == "bare" ? 2 : 1),
                    "precondition: every answer under test was served")
        }
    }

    @Test("Message-ID lookup in the notification extension: when neither the bracketed nor the bare answer lists its matches, nothing is fetched")
    func nseMessageIdLookup() async throws {
        let server = FakeIMAPServer(capabilities: Self.capabilities,
                                    mailboxes: ["INBOX": [5].map(IMAPChangeReaderTests.message)])
        try server.start()
        defer { server.stop() }
        server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
        server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
        let result = await NSEIMAPConnection.fetch(
            accountId: "nse-unlisted", host: "127.0.0.1", port: server.port, useTLS: false,
            username: server.username, password: server.password, rfc822MessageId: "lookup@example.com")
        #expect(result == nil, "an unlisted answer is not read as a match or as absence")
        #expect(server.compactUIDSearchAnswersServed() == 2, "precondition: both searches got the answer under test")
    }
}
