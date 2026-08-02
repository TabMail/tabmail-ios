/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Keeper coverage for `MessageExistenceProbe`, the RFC corroboration surface
/// used by backfill UID-remap handling after RFC action resolution is removed.
///
/// `.serialized` — the fake binds a listening socket; parallel tests would
/// contend on ephemeral port allocation.
@Suite("IMAPProvider MessageExistenceProbe", .serialized)
struct IMAPProviderMoveIdempotencyTests {

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
        // Same server but searching for a Message-ID that doesn't exist.
        // A clean miss remains the backfill probe's confirmed-absent signal.
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
        // currentUIDs normalizes through searchByMessageId.
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

    @Test("IMAPProvider remains a MessageExistenceProbe after action RFC resolution is removed")
    func conformanceGuard() {
        // Backfill UID-remap recovery depends on this conformance. If a
        // refactor drops it, this test stops compiling.
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
}
