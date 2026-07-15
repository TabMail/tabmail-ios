/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Provider-boundary coverage for IMAP action identity and move idempotency.
/// The `FakeIMAPServer` is mailbox-aware and stateful: provider actions exercise
/// SELECT/SEARCH/FETCH/STORE/UID MOVE over the same wire path as production.
/// The fake advertises atomic MOVE; SwiftMail's COPY/delete fallback remains an
/// adapter implementation detail and is not claimed by this suite.
///
/// `.serialized` — the fake binds a listening socket; parallel tests would
/// contend on ephemeral port allocation.
@Suite("IMAPProvider RFC action identity", .serialized)
struct IMAPProviderMoveIdempotencyTests {

    enum ActionMutation: CaseIterable, Sendable {
        case read
        case unread
        case flag
        case unflag
        case replied
        case forwarded
        case addLabel
        case removeLabel

        var flag: String {
            switch self {
            case .read, .unread: "\\Seen"
            case .flag, .unflag: "\\Flagged"
            case .replied: "\\Answered"
            case .forwarded: "$Forwarded"
            case .addLabel, .removeLabel: "project_test"
            }
        }

        var removesFlag: Bool {
            switch self {
            case .unread, .unflag, .removeLabel: true
            default: false
            }
        }
    }

    private func rfc822(messageId: String, subject: String = "probe-test") -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: \(subject)\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        probe body.\r

        """
    }

    private func rfc822(rawMessageIdHeader: String?) -> String {
        let messageIdLine = rawMessageIdHeader.map { "Message-ID: \($0)\r\n" } ?? ""
        return """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: legacy-identity-test\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        \(messageIdLine)Content-Type: text/plain; charset=utf-8\r
        \r
        legacy identity body.\r

        """
    }

    private func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private func apply(
        _ action: ActionMutation,
        messageIds: [String],
        provider: IMAPProvider
    ) async throws {
        switch action {
        case .read:
            try await provider.markRead(ids: messageIds, folder: "INBOX")
        case .unread:
            try await provider.markUnread(ids: messageIds, folder: "INBOX")
        case .flag:
            try await provider.markFlagged(ids: messageIds, flagged: true, folder: "INBOX")
        case .unflag:
            try await provider.markFlagged(ids: messageIds, flagged: false, folder: "INBOX")
        case .replied:
            try await provider.markReplied(ids: messageIds, folder: "INBOX")
        case .forwarded:
            try await provider.markForwarded(ids: messageIds, folder: "INBOX")
        case .addLabel:
            try await provider.setUserLabel(
                ids: messageIds,
                labelId: action.flag,
                present: true,
                folder: "INBOX"
            )
        case .removeLabel:
            try await provider.setUserLabel(
                ids: messageIds,
                labelId: action.flag,
                present: false,
                folder: "INBOX"
            )
        }
    }

    @Test("messageExistsInFolder returns true when destination has the Message-ID")
    func probeHit() async throws {
        let msg = FakeIMAPServer.makeMessage(uid: 1, rfc822Text: rfc822(messageId: "probe-hit-1@example.com"))
        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let exists = try await provider.messageExistsInFolder(
            rfc822MessageId: "probe-hit-1@example.com",
            folderPath: "INBOX"
        )
        #expect(exists == true)
    }

    @Test("messageExistsInFolder returns false when destination does NOT have the Message-ID")
    func probeMiss() async throws {
        let msg = FakeIMAPServer.makeMessage(uid: 1, rfc822Text: rfc822(messageId: "someone-else@example.com"))
        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let exists = try await provider.messageExistsInFolder(
            rfc822MessageId: "missing@example.com",
            folderPath: "INBOX"
        )
        #expect(exists == false)
    }

    @Test("messageExistsInFolder normalizes Message-ID (caller passes bare, server stores bare)")
    func probeNormalized() async throws {
        // Commit bbdc4f3 passes the PendingOperation message id straight through
        // to searchByMessageId, which normalizes via EmailFilter.normalizeMessageId.
        // The fake's header matcher strips angle brackets off the quoted SEARCH
        // value. This test proves caller-side formatting (whether or not the
        // caller included "<...>") doesn't change the result.
        let msg = FakeIMAPServer.makeMessage(uid: 1, rfc822Text: rfc822(messageId: "norm-test@example.com"))
        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // Bracketed form — what a caller might receive from IMAP raw headers.
        let existsBracketed = try await provider.messageExistsInFolder(
            rfc822MessageId: "<norm-test@example.com>",
            folderPath: "INBOX"
        )
        // Bare form — what we store in MessageHeader.rfc822MessageId per the
        // RFC 822 normalization rule.
        let existsBare = try await provider.messageExistsInFolder(
            rfc822MessageId: "norm-test@example.com",
            folderPath: "INBOX"
        )
        #expect(existsBracketed == true)
        #expect(existsBare == true)
    }

    @Test("IMAPProvider conforms to MessageExistenceProbe (compile-time guard)")
    func conformanceGuard() {
        // Backfill UID re-resolution consumes this provider capability.
        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: 1,
            username: "u",
            password: "p",
            smtpHost: "127.0.0.1",
            smtpPort: 1,
            useTLS: false
        )
        let probe: any MessageExistenceProbe = provider
        _ = probe
    }

    @Test("stateful fake scopes SEARCH to the selected mailbox")
    func statefulMailboxScope() async throws {
        let messageId = "mailbox-scope@example.com"
        let archived = FakeIMAPServer.makeMessage(
            uid: 7,
            rfc822Text: rfc822(messageId: messageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Archive": [archived]])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(try await provider.messageExistsInFolder(
            rfc822MessageId: messageId,
            folderPath: "INBOX"
        ) == false)
        #expect(try await provider.messageExistsInFolder(
            rfc822MessageId: messageId,
            folderPath: "Archive"
        ) == true)
    }

    @Test("stateful fake applies STORE flags through the public provider")
    func statefulStore() async throws {
        let messageId = "store-state@example.com"
        let message = FakeIMAPServer.makeMessage(
            uid: 11,
            rfc822Text: rfc822(messageId: messageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: [messageId], folder: "INBOX")
        #expect(server.flags(in: "INBOX", uid: 11).contains("\\Seen"))
        #expect(server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("stateful fake moves RFC identity between mailboxes through the public provider")
    func statefulMove() async throws {
        let messageId = "move-state@example.com"
        let message = FakeIMAPServer.makeMessage(
            uid: 13,
            rfc822Text: rfc822(messageId: messageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(ids: [messageId], from: "INBOX", to: "Archive")
        #expect(server.messageIDs(in: "INBOX").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(messageId)>"])
        #expect(server.recordedCommands().contains { $0.contains("UID MOVE") })
    }

    @Test("stateful fake injects one bounded command failure")
    func boundedFailureInjection() async throws {
        let messageId = "failure-state@example.com"
        let message = FakeIMAPServer.makeMessage(
            uid: 17,
            rfc822Text: rfc822(messageId: messageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        server.failNextCommand(containing: "UID SEARCH")
        await #expect(throws: (any Error).self) {
            _ = try await provider.messageExistsInFolder(
                rfc822MessageId: messageId,
                folderPath: "INBOX"
            )
        }
        #expect(try await provider.messageExistsInFolder(
            rfc822MessageId: messageId,
            folderPath: "INBOX"
        ))
    }

    @Test("UID token member resolves only in its recorded source mailbox")
    func tokenMemberResolvesSourceUID() async throws {
        let source = FakeIMAPServer.makeMessage(
            uid: 41,
            rfc822Text: rfc822(rawMessageIdHeader: nil)
        )
        let unrelatedDestination = FakeIMAPServer.makeMessage(
            uid: 41,
            rfc822Text: rfc822(messageId: "different-message@example.com")
        )
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [source],
            "Archive": [unrelatedDestination],
        ])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: ["41"], folder: "INBOX")

        #expect(server.flags(in: "INBOX", uid: 41).contains("\\Seen"),
                "the token member mutates the exact source UID")
        #expect(server.flags(in: "Archive", uid: 41).isEmpty,
                "the numerically identical UID in another mailbox is a DIFFERENT message and must never be touched")
        #expect(!server.recordedCommands().contains { $0.contains("UID SEARCH") },
                "a token member resolves by exact UID FETCH, never by search")
    }

    @Test("a missing source UID token is authoritative stale — a destination UID collision cannot revive it")
    func tokenMemberMissingSourceIsStale() async throws {
        let destination = FakeIMAPServer.makeMessage(
            uid: 43,
            rfc822Text: rfc822(messageId: "destination-only@example.com")
        )
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Archive": [destination],
        ])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // No throw: the empty exact FETCH is authoritative stale — no-op.
        try await provider.markRead(ids: ["43"], folder: "INBOX")

        #expect(server.flags(in: "Archive", uid: 43).isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("SELECT Archive") })
    }

    @Test(
        "a noncanonical UID token is authoritative stale without any STORE",
        arguments: [" ", "op aque", "0", "041", "4294967296"]
    )
    func tokenMemberNoncanonicalUIDIsStale(token: String) async throws {
        let message = FakeIMAPServer.makeMessage(
            uid: 45,
            rfc822Text: rfc822(messageId: "canonical-neighbor@example.com")
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: [token], folder: "INBOX")

        #expect(server.flags(in: "INBOX", uid: 45).isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("contradictory exact UID FETCH responses remain uncertainty")
    func tokenMemberContradictoryFetchThrows() async throws {
        let first = FakeIMAPServer.makeMessage(
            uid: 49,
            rfc822Text: rfc822(messageId: "first-token@example.com")
        )
        let second = FakeIMAPServer.makeMessage(
            uid: 49,
            rfc822Text: rfc822(messageId: "second-token@example.com")
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [first, second]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: (any Error).self) {
            try await provider.markRead(ids: ["49"], folder: "INBOX")
        }
    }

    @Test("token UID FETCH failure remains retryable uncertainty")
    func tokenMemberFetchFailureRetries() async throws {
        let message = FakeIMAPServer.makeMessage(
            uid: 53,
            rfc822Text: rfc822(rawMessageIdHeader: nil)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        server.failNextCommand(containing: "UID FETCH 53")

        await #expect(throws: (any Error).self) {
            try await provider.markRead(ids: ["53"], folder: "INBOX")
        }
        try await provider.markRead(ids: ["53"], folder: "INBOX")
        #expect(server.flags(in: "INBOX", uid: 53).contains("\\Seen"))
    }

    @Test(
        "every flag/keyword action resolves one source-scoped RFC identity",
        arguments: ActionMutation.allCases
    )
    func actionFamilyExactResolution(action: ActionMutation) async throws {
        let messageId = "action-family@example.com"
        let message = FakeIMAPServer.makeMessage(
            uid: 21,
            rfc822Text: rfc822(messageId: messageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        if action.removesFlag {
            server.setFlags([action.flag], in: "INBOX", uid: 21)
        }
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await apply(action, messageIds: [messageId], provider: provider)

        let finalFlags = server.flags(in: "INBOX", uid: 21)
        #expect(finalFlags.contains(action.flag) != action.removesFlag)
    }

    @Test("missing RFC identity is an authoritative action no-op")
    func actionMissingNoOp() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: ["missing-action@example.com"], folder: "INBOX")

        #expect(!server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("duplicate exact RFC identities are ambiguous action no-ops")
    func actionAmbiguousNoOp() async throws {
        let messageId = "ambiguous-action@example.com"
        let first = FakeIMAPServer.makeMessage(uid: 31, rfc822Text: rfc822(messageId: messageId))
        let second = FakeIMAPServer.makeMessage(uid: 32, rfc822Text: rfc822(messageId: messageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [first, second]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: [messageId], folder: "INBOX")

        #expect(server.flags(in: "INBOX", uid: 31).isEmpty)
        #expect(server.flags(in: "INBOX", uid: 32).isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("substring-only IMAP SEARCH hit is not an exact RFC action match")
    func actionSubstringNoOp() async throws {
        let stored = FakeIMAPServer.makeMessage(
            uid: 41,
            rfc822Text: rfc822(messageId: "prefix-target-action@example.com")
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [stored]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: ["target-action@example.com"], folder: "INBOX")

        #expect(server.flags(in: "INBOX", uid: 41).isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("later lookup failure prevents every flag mutation in the batch")
    func actionBatchPreflight() async throws {
        let firstId = "batch-first@example.com"
        let secondId = "batch-second@example.com"
        let first = FakeIMAPServer.makeMessage(uid: 61, rfc822Text: rfc822(messageId: firstId))
        let second = FakeIMAPServer.makeMessage(uid: 62, rfc822Text: rfc822(messageId: secondId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [first, second]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        server.failNextCommand(containing: secondId)

        await #expect(throws: (any Error).self) {
            try await provider.markRead(ids: [firstId, secondId], folder: "INBOX")
        }

        #expect(server.flags(in: "INBOX", uid: 61).isEmpty)
        #expect(server.flags(in: "INBOX", uid: 62).isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID STORE") })
    }

    @Test("exact members execute after missing and ambiguous members finish preflight")
    func actionMixedBatch() async throws {
        let firstId = "mixed-first@example.com"
        let ambiguousId = "mixed-ambiguous@example.com"
        let lastId = "mixed-last@example.com"
        let messages = [
            FakeIMAPServer.makeMessage(uid: 71, rfc822Text: rfc822(messageId: firstId)),
            FakeIMAPServer.makeMessage(uid: 72, rfc822Text: rfc822(messageId: ambiguousId)),
            FakeIMAPServer.makeMessage(uid: 73, rfc822Text: rfc822(messageId: ambiguousId)),
            FakeIMAPServer.makeMessage(uid: 74, rfc822Text: rfc822(messageId: lastId)),
        ]
        let server = FakeIMAPServer(mailboxes: ["INBOX": messages])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(
            ids: [firstId, "mixed-missing@example.com", ambiguousId, lastId],
            folder: "INBOX"
        )

        #expect(server.flags(in: "INBOX", uid: 71).contains("\\Seen"))
        #expect(server.flags(in: "INBOX", uid: 72).isEmpty)
        #expect(server.flags(in: "INBOX", uid: 73).isEmpty)
        #expect(server.flags(in: "INBOX", uid: 74).contains("\\Seen"))
    }

    @Test("duplicate RFC batch member mutates its current UID once")
    func actionBatchDeduplicates() async throws {
        let messageId = "dedupe-action@example.com"
        let message = FakeIMAPServer.makeMessage(uid: 81, rfc822Text: rfc822(messageId: messageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.markRead(ids: [messageId, messageId], folder: "INBOX")

        let stores = server.recordedCommands().filter { $0.contains("UID STORE") }
        #expect(stores.count == 1)
    }

    @Test("later source lookup failure prevents every move in the batch")
    func moveBatchPreflight() async throws {
        let firstId = "move-batch-first@example.com"
        let secondId = "move-batch-second@example.com"
        let first = FakeIMAPServer.makeMessage(uid: 91, rfc822Text: rfc822(messageId: firstId))
        let second = FakeIMAPServer.makeMessage(uid: 92, rfc822Text: rfc822(messageId: secondId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [first, second], "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        server.failNextCommand(containing: secondId)

        await #expect(throws: (any Error).self) {
            try await provider.move(ids: [firstId, secondId], from: "INBOX", to: "Archive")
        }

        #expect(Set(server.messageIDs(in: "INBOX")) == ["<\(firstId)>", "<\(secondId)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID MOVE") })
    }

    @Test("later destination lookup failure prevents every move in the batch")
    func moveDestinationBatchPreflight() async throws {
        let firstId = "move-destination-batch-first@example.com"
        let secondId = "move-destination-batch-second@example.com"
        let first = FakeIMAPServer.makeMessage(
            uid: 93,
            rfc822Text: rfc822(messageId: firstId)
        )
        let second = FakeIMAPServer.makeMessage(
            uid: 94,
            rfc822Text: rfc822(messageId: secondId)
        )
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [first, second],
            "Archive": [],
        ])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        server.failCommand(containing: "UID SEARCH", onMatch: 4)

        await #expect(throws: (any Error).self) {
            try await provider.move(ids: [firstId, secondId], from: "INBOX", to: "Archive")
        }

        #expect(Set(server.messageIDs(in: "INBOX")) == ["<\(firstId)>", "<\(secondId)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID MOVE") })
    }

    @Test("ambiguous destination does not trigger source cleanup")
    func moveAmbiguousDestinationNoOp() async throws {
        let messageId = "move-destination-ambiguous@example.com"
        let source = FakeIMAPServer.makeMessage(uid: 101, rfc822Text: rfc822(messageId: messageId))
        let destinationA = FakeIMAPServer.makeMessage(uid: 201, rfc822Text: rfc822(messageId: messageId))
        let destinationB = FakeIMAPServer.makeMessage(uid: 202, rfc822Text: rfc822(messageId: messageId))
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [source],
            "Archive": [destinationA, destinationB],
        ])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(ids: [messageId], from: "INBOX", to: "Archive")

        #expect(server.messageIDs(in: "INBOX") == ["<\(messageId)>"])
        #expect(server.messageIDs(in: "Archive").count == 2)
    }

    @Test("existing exact destination copy converges by removing the source copy")
    func moveExistingDestinationCleansSource() async throws {
        let messageId = "move-destination-exact@example.com"
        let source = FakeIMAPServer.makeMessage(uid: 105, rfc822Text: rfc822(messageId: messageId))
        let destination = FakeIMAPServer.makeMessage(uid: 205, rfc822Text: rfc822(messageId: messageId))
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [source],
            "Archive": [destination],
        ])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(ids: [messageId], from: "INBOX", to: "Archive")

        #expect(server.messageIDs(in: "INBOX").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(messageId)>"])
    }

    @Test("destination lookup failure propagates before move mutation")
    func moveDestinationFailurePropagates() async throws {
        let messageId = "move-destination-failure@example.com"
        let source = FakeIMAPServer.makeMessage(uid: 111, rfc822Text: rfc822(messageId: messageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [source], "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        server.failCommand(containing: "UID SEARCH", onMatch: 2)

        await #expect(throws: (any Error).self) {
            try await provider.move(ids: [messageId], from: "INBOX", to: "Archive")
        }

        #expect(server.messageIDs(in: "INBOX") == ["<\(messageId)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(!server.recordedCommands().contains { $0.contains("UID MOVE") })
    }
}
