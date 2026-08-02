/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// PORT — v2final `deleteDraftStrong`; RFC-only and compatibility matrices are
/// SUBTRACTED because the forward-port admits only a complete native tuple.
@Suite("IMAP STRONG draft delete", .serialized)
struct IMAPDeleteDraftIdentityTests {
    private static let epoch = 81_001

    private static func message(_ uid: Int, _ id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: draft\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain\r
        \r
        body\r

        """)
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    @Test("STRONG delete removes exactly the recorded UID and leaves a same-RFC sibling")
    func exactUidOnly() async throws {
        let shared = "shared-\(UUID().uuidString)@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(3, shared), Self.message(4, shared)],
        ])
        server.setUidValidity(Self.epoch, for: "Drafts")
        server.expectMutation(rfc822MessageId: shared)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(
            identity: .imap(folder: "Drafts", uidValidity: Self.epoch, uid: 3))

        #expect(server.messageIDs(in: "Drafts") == ["<\(shared)>"])
        let uids = server.snapshotMessagesWithFlags(in: "Drafts").map { $0.message.uid }
        #expect(!uids.contains(3))
        #expect(uids.contains(4))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("STRONG delete refuses a UIDVALIDITY mismatch without rebinding")
    func staleEpoch() async throws {
        let occupant = "occupant-\(UUID().uuidString)@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(7, occupant)]])
        server.setUidValidity(Self.epoch + 1, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.deleteDraft(
                identity: .imap(folder: "Drafts", uidValidity: Self.epoch, uid: 7))
        }
        #expect(server.messageIDs(in: "Drafts") == ["<\(occupant)>"])
    }

    @Test("STRONG delete treats an absent recorded UID as already gone")
    func absentUid() async throws {
        let sibling = "sibling-\(UUID().uuidString)@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(12, sibling)]])
        server.setUidValidity(Self.epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(
            identity: .imap(folder: "Drafts", uidValidity: Self.epoch, uid: 11))
        #expect(server.messageIDs(in: "Drafts") == ["<\(sibling)>"])
    }

    @Test("STRONG delete rejects zero or malformed coordinates before mutation")
    func malformedCoordinates() async throws {
        let target = "target-\(UUID().uuidString)@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(21, target)]])
        server.setUidValidity(Self.epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let commandsBefore = server.recordedCommands()
        for (validity, uid) in [(0, 21), (Self.epoch, 0), (Self.epoch, -1), (Self.epoch, Int.max)] {
            await #expect(throws: ProviderError.self) {
                try await provider.deleteDraft(
                    identity: .imap(folder: "Drafts", uidValidity: validity, uid: uid))
            }
        }
        #expect(server.messageIDs(in: "Drafts") == ["<\(target)>"])
        #expect(server.recordedCommands() == commandsBefore)
    }
}
