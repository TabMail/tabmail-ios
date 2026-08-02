/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// PORT — v2final `storeDeletedAndMaybeExpunge`: UIDPLUS purges the target;
/// without UIDPLUS the target is soft-deleted and mailbox-wide EXPUNGE is refused.
@Suite("IMAP draft delete expunge scope", .serialized)
struct IMAPDraftExpungeScopeTests {
    private static let epoch = 92_001

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

    @Test("UIDPLUS draft delete expunges only the addressed UID")
    func uidPlusScope() async throws {
        let target = "target@example.com"
        let bystander = "bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(51, bystander), Self.message(52, target)],
        ])
        server.setFlags(["\\Deleted"], in: "Drafts", uid: 51)
        server.setUidValidity(Self.epoch, for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(
            identity: .imap(folder: "Drafts", uidValidity: Self.epoch, uid: 52))

        #expect(server.messageIDs(in: "Drafts") == ["<\(bystander)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("Non-UIDPLUS draft delete soft-deletes only the addressed UID")
    func nonUidPlusScope() async throws {
        let target = "target-soft@example.com"
        let bystander = "bystander-soft@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: ["Drafts": [Self.message(61, bystander), Self.message(62, target)]])
        server.setFlags(["\\Deleted"], in: "Drafts", uid: 61)
        server.setUidValidity(Self.epoch, for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(
            identity: .imap(folder: "Drafts", uidValidity: Self.epoch, uid: 62))

        #expect(server.messageIDs(in: "Drafts").count == 2)
        #expect(server.flags(in: "Drafts", rfc822MessageId: target)?.contains("\\Deleted") == true)
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
