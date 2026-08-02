/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// T2.8 wire proof. Provider-ID action authority means an epochless IMAP
/// action entry point may never turn an RFC Message-ID into mutation authority.
@Suite("T2.8 — IMAP RFC action refusal", .serialized)
struct IMAPRFCActionRefusalTests {
    private enum Surface: CaseIterable {
        case read, unread, flag, move, replied, forwarded, userLabel
    }

    private func rfc822(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: refusal\r
        Date: Thu, 01 Jan 2020 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        refusal body\r

        """
    }

    @Test("IMAP action entry points reject RFC identities before SEARCH or mutation")
    func rfcIdentitiesAreRejectedBeforeWireMutation() async throws {
        for surface in Surface.allCases {
            let identity = "refusal-\(surface)@example.com"
            let message = FakeIMAPServer.makeMessage(
                uid: 41,
                rfc822Text: rfc822(messageId: identity))
            let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
            try server.start()
            defer { server.stop() }

            let provider = IMAPProvider(
                host: "127.0.0.1", port: server.port,
                username: server.username, password: server.password,
                smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
            try await provider.connect()

            do {
                switch surface {
                case .read:
                    try await provider.markRead(ids: [identity], folder: "INBOX")
                case .unread:
                    try await provider.markUnread(ids: [identity], folder: "INBOX")
                case .flag:
                    try await provider.markFlagged(ids: [identity], flagged: true, folder: "INBOX")
                case .move:
                    try await provider.move(ids: [identity], from: "INBOX", to: "Archive")
                case .replied:
                    try await provider.markReplied(ids: [identity], folder: "INBOX")
                case .forwarded:
                    try await provider.markForwarded(ids: [identity], folder: "INBOX")
                case .userLabel:
                    try await provider.setUserLabel(
                        messageId: identity, keyword: "test-label", add: true, folder: "INBOX")
                }
                Issue.record("\(surface) accepted an epochless RFC identity")
            } catch ProviderError.actionIdentityResolutionFailed {
                // Expected typed, pre-wire refusal.
            } catch {
                Issue.record("\(surface) refused with the wrong error: \(error)")
            }

            let forbidden = server.recordedCommands().filter { command in
                let upper = command.uppercased()
                return upper.contains("SEARCH") || upper.contains("STORE")
                    || upper.contains(" MOVE ") || upper.contains("EXPUNGE")
            }
            #expect(forbidden.isEmpty, "\(surface) reached forbidden IMAP wire commands: \(forbidden)")

            try? await provider.disconnect()
        }
    }

    @Test("Sent duplicate detection keeps its exact Message-ID SEARCH and skips APPEND")
    func sentDuplicateSearchRemainsNonActionAuthority() async throws {
        let identity = "sent-dedup@example.com"
        let existing = FakeIMAPServer.makeMessage(
            uid: 91,
            rfc822Text: rfc822(messageId: identity))
        let server = FakeIMAPServer(mailboxes: ["Sent": [existing]])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var draft = DraftMessage(to: ["recipient@example.com"], subject: "Already sent", body: "body")
        draft.messageId = "<\(identity)>"
        let succeeded = try await provider.appendToSentFolder(
            draft: draft,
            sentFolderPath: "Sent",
            messageId: "<\(identity)>")

        let commands = server.recordedCommands().map { $0.uppercased() }
        #expect(succeeded)
        #expect(commands.contains { $0.contains("SEARCH") })
        #expect(!commands.contains { $0.contains(" APPEND ") },
                "dedup found an existing exact Message-ID but still APPENDed: \(commands)")
    }
}
