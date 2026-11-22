/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Every SEARCH caller reads its answer through `ExtendedSearchResult.listed(within:)`, the only public read
/// of a SEARCH answer: an answer that does not list its matches,
/// or names UIDs outside the request, fails that caller. It never reads as
/// "nothing found". One test per caller, so reverting any one of them to the
/// old empty-set default fails here even while the shared reader is intact.
///
/// Every answer here carries what the search asked for (`RETURN (COUNT MIN MAX ALL)`;
/// RFC 4731 section 3.1 requires a requested COUNT always), so SwiftMail accepts it and the app's
/// own reading is what is tested. An answer that leaves out a requested COUNT, or reports
/// matches without ALL, is refused by SwiftMail before the app reads it.
@Suite("SEARCH answers that list nothing fail every caller", .serialized)
struct SearchAnswerRefusalCallerTests {
    static let capabilities = FakeIMAPServer.defaultCapabilities + ["ESEARCH"]
    /// Lists two UIDs but counts three: the list contradicts its own COUNT,
    /// so it does not list the answer's matches.
    static let unlisted = "COUNT 3 MIN 5 MAX 6 ALL 5:6"
    /// Names UID 900, outside every request below.
    static let outOfScope = "COUNT 1 MIN 900 MAX 900 ALL 900"
    /// RFC 4731's answer to a COUNT request that matched nothing.
    static let noMatch = "COUNT 0"
    /// A complete answer listing 5, 6 and 7, every message `withProvider`'s mailbox holds.
    static let allThree = "COUNT 3 MIN 5 MAX 7 ALL 5:7"
    /// A complete answer listing UID 5 alone.
    static let onlyFive = "COUNT 1 MIN 5 MAX 5 ALL 5"

    /// A message whose Message-ID header holds the id without angle brackets, as some
    /// senders write it: a search for the bracketed form does not match it, the bare form does.
    static func bareIdMessage(_ uid: Int) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: change fixture \(uid)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -uid))\r
        Message-ID: change-\(uid)@example.com\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// The mailbox holds 5, 6 and 7 (dated 5, 6 and 7 days ago, Message-ID `<change-N@example.com>`),
    /// or `messages` when given.
    static func withProvider(
        messages: [FakeIMAPServer.Message] = [5, 6, 7].map(IMAPChangeReaderTests.message),
        _ body: (FakeIMAPServer, IMAPProvider) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: ["INBOX": messages])
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
            case "outOfScope": server.answerNextUIDSearch(in: "INBOX", esearchData: Self.outOfScope)
            // The mailbox holds 5, 6 and 7, all inside 1...10: the control's answer lists them all.
            default: server.answerNextUIDSearch(in: "INBOX", esearchData: Self.allThree)
            }
            if answer == "control" {
                let found = try await provider.searchExistingUIDs(folder: "INBOX", from: 1, to: 10)
                #expect(Set(found) == [5, 6, 7])
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
            // A consistent answer naming 7, which lies between the requested 5 and 8 but was not
            // asked for: only the request itself, never its lowest-to-highest span, is the scope.
            case "outOfScope": server.answerNextUIDSearch(in: "INBOX", esearchData: "COUNT 2 MIN 5 MAX 7 ALL 5,7")
            // Of 5, 6 and 8 the mailbox holds 5 and 6: the control's answer lists those, 8 is missing.
            default: server.answerNextUIDSearch(in: "INBOX", esearchData: "COUNT 2 MIN 5 MAX 6 ALL 5:6")
            }
            if answer == "control" {
                let result = try await provider.searchExistingUIDs(folder: "INBOX", uids: [5, 6, 8])
                #expect(result.found == [5, 6])
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.searchExistingUIDs(folder: "INBOX", uids: [5, 6, 8])
                }
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("App search: an unlisted answer fails the search, never an empty result; a complete answer is read",
          arguments: [false, true])
    func appSearch(_ control: Bool) async throws {
        try await Self.withProvider { server, provider in
            // "change fixture" is in every message's subject: the control's answer lists all three.
            server.answerNextUIDSearch(in: "INBOX", esearchData: control ? Self.allThree : Self.unlisted)
            if control {
                let found = try await provider.search(query: "change fixture", folder: "INBOX")
                let ids = Set(found.map(\.messageId))
                #expect(ids == ["5", "6", "7"], "the complete answer's matches are the search's result")
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.search(query: "change fixture", folder: "INBOX")
                }
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("Older-mail date lookup: an unlisted answer fails the lookup, with and without a start date; a complete answer is read",
          arguments: [(true, false), (false, false), (true, true), (false, true)])
    func olderMailDateLookup(_ withSince: Bool, _ control: Bool) async throws {
        try await Self.withProvider { server, provider in
            // The messages are 5 to 7 days old: inside the last 30 days and before today, so
            // both searches' complete answers list all three.
            server.answerNextUIDSearch(in: "INBOX", esearchData: control ? Self.allThree : Self.unlisted)
            let since = withSince ? Date().addingTimeInterval(-30 * 86_400) : nil
            if control {
                let found = try await provider.searchBackfillUIDs(folder: "INBOX", since: since)
                #expect(Set(found) == [5, 6, 7], "the complete answer's matches are the lookup's result")
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.searchBackfillUIDs(folder: "INBOX", since: since)
                }
            }
            #expect(server.compactUIDSearchAnswersServed() == 1, "precondition: the answer under test was served")
        }
    }

    @Test("Message-ID lookup in the app: an unlisted answer fails it, to the bracketed search or (after an empty bracketed answer) to the bare one; a bracketed or bare answer that lists its match is read",
          arguments: ["bracketed", "bracketedMatch", "bare", "bareMatch"])
    func appMessageIdLookup(_ which: String) async throws {
        let bracketedFirst = which.hasPrefix("bracketed")
        // UID 5's own Message-ID. Where the bracketed search finds nothing, UID 5's header holds
        // the id without brackets, so that empty answer is the mailbox's own (RFC 9051 6.4.4).
        let messages = bracketedFirst
            ? [5, 6, 7].map(IMAPChangeReaderTests.message)
            : [Self.bareIdMessage(5)] + [6, 7].map(IMAPChangeReaderTests.message)
        try await Self.withProvider(messages: messages) { server, provider in
            let messageId = "change-5@example.com"
            if !bracketedFirst { server.answerNextUIDSearch(in: "INBOX", esearchData: Self.noMatch) }
            server.answerNextUIDSearch(in: "INBOX", esearchData: which.hasSuffix("Match") ? Self.onlyFive : Self.unlisted)
            if which.hasSuffix("Match") {
                let found = try await provider.currentUIDs(rfc822MessageId: messageId, folderPath: "INBOX")
                #expect(found == ["5"], "the listed match is the lookup's result")
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await provider.currentUIDs(rfc822MessageId: messageId, folderPath: "INBOX")
                }
            }
            let searchCount = bracketedFirst ? 1 : 2
            #expect(server.compactUIDSearchAnswersServed() == searchCount, "precondition: every answer under test was served")
            // The answers above are served whatever a search asks, so each search's own Message-ID is checked.
            let searches = server.recordedCommands().filter { $0.uppercased().contains("UID SEARCH") }
            #expect(searches.count == searchCount)
            guard searches.count == searchCount else { return }
            #expect(searches[0].contains("<\(messageId)>"), "the first search asks for the bracketed Message-ID: \(searches[0])")
            if searchCount == 2 {
                #expect(searches[1].contains(messageId) && !searches[1].contains("<\(messageId)>"),
                        "the second asks for the bare one: \(searches[1])")
            }
        }
    }

    @Test("Message-ID lookup in the notification extension: when neither the bracketed nor the bare answer lists its matches, nothing is fetched; a bracketed or (after an empty bracketed answer) bare answer that lists its match fetches that message",
          arguments: ["unlisted", "bracketedMatch", "bareMatch"])
    func nseMessageIdLookup(_ which: String) async throws {
        // Where the bracketed search finds nothing, UID 5's header holds the id without brackets.
        let message = which == "bareMatch" ? Self.bareIdMessage(5) : IMAPChangeReaderTests.message(5)
        let server = FakeIMAPServer(capabilities: Self.capabilities, mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }
        let messageId = which == "unlisted" ? "lookup@example.com" : "change-5@example.com"
        switch which {
        case "unlisted":
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.unlisted)
        case "bracketedMatch":
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.onlyFive)
        default:
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.noMatch)
            server.answerNextUIDSearch(in: "INBOX", esearchData: Self.onlyFive)
        }
        let result = await NSEIMAPConnection.fetch(
            accountId: "nse-\(which)", host: "127.0.0.1", port: server.port, useTLS: false,
            username: server.username, password: server.password, rfc822MessageId: messageId)
        let searchCount = which == "bracketedMatch" ? 1 : 2
        #expect(server.compactUIDSearchAnswersServed() == searchCount, "precondition: every answer under test was served")
        // The answers above are served whatever a search asks, so each search's own Message-ID is checked.
        let searches = server.recordedCommands().filter { $0.uppercased().contains("UID SEARCH") }
        #expect(searches.count == searchCount)
        if searches.count == searchCount {
            #expect(searches[0].contains("<\(messageId)>"), "the first search asks for the bracketed Message-ID: \(searches[0])")
            if searchCount == 2 {
                #expect(searches[1].contains(messageId) && !searches[1].contains("<\(messageId)>"),
                        "the second asks for the bare one: \(searches[1])")
            }
        }
        let fetches = server.recordedCommands().filter { $0.uppercased().contains("UID FETCH") }
        if which == "unlisted" {
            #expect(result == nil, "an unlisted answer is not read as a match or as absence")
            #expect(fetches.isEmpty, "nothing is fetched on an answer that lists nothing: \(fetches)")
        } else {
            #expect(result?.metadata.messageId == "5", "the listed match is the message fetched")
            #expect(!fetches.isEmpty, "the listed match is fetched")
        }
    }
}
