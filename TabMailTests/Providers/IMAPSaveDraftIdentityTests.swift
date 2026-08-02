/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// PORT — v2final's strong IMAP tuple behavior, with every RFC-only prior-copy
/// matrix SUBTRACTED. A stale tuple skips cleanup but never skips the APPEND.
@Suite("IMAP draft save uses one exact native prior tuple", .serialized)
struct IMAPSaveDraftIdentityTests {
    private enum PriorMismatch: Sendable { case staleEpoch, mailbox }

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

    private static func draft(_ id: String) -> DraftMessage {
        var draft = DraftMessage(to: ["recipient@example.com"], subject: "Edited", body: "fresh")
        draft.messageId = id
        return draft
    }

    @Test("A live prior IMAP tuple deletes only its UID; a same-RFC sibling survives and the fresh edit lands")
    func livePriorTuple() async throws {
        let shared = "shared-\(UUID().uuidString)@example.com"
        let fresh = "fresh-\(UUID().uuidString)@example.com"
        let epoch = 71_001
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(3, shared), Self.message(4, shared)],
        ])
        server.setUidValidity(epoch, for: "Drafts")
        server.expectMutation(rfc822MessageId: shared)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(fresh),
            existingIdentity: .imap(folder: "Drafts", uidValidity: epoch, uid: 3),
            draftsFolderPath: "Drafts")

        let ids = server.messageIDs(in: "Drafts")
        let uids = server.snapshotMessagesWithFlags(in: "Drafts").map { $0.message.uid }
        #expect(ids.filter { $0 == "<\(shared)>" }.count == 1)
        #expect(ids.contains("<\(fresh)>"))
        #expect(!uids.contains(3))
        #expect(uids.contains(4))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test(
        "A stale or mailbox-mismatched prior IMAP tuple deletes nothing and still APPENDs",
        arguments: [PriorMismatch.staleEpoch, .mailbox])
    private func mismatchedPriorTuple(_ mismatch: PriorMismatch) async throws {
        let prior = "prior-\(UUID().uuidString)@example.com"
        let fresh = "fresh-\(UUID().uuidString)@example.com"
        let epoch = 72_001
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(7, prior)]])
        server.setUidValidity(epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let identity: DraftDeleteIdentity
        switch mismatch {
        case .staleEpoch:
            identity = .imap(folder: "Drafts", uidValidity: epoch - 1, uid: 7)
        case .mailbox:
            identity = .imap(folder: "Other", uidValidity: epoch, uid: 7)
        }
        _ = try await provider.saveDraft(
            Self.draft(fresh), existingIdentity: identity, draftsFolderPath: "Drafts")

        let ids = server.messageIDs(in: "Drafts")
        #expect(ids.contains("<\(prior)>"))
        #expect(ids.contains("<\(fresh)>"))
    }

    @Test("UIDPLUS APPENDUID identifies the new copy without searching an existing exact same-ID sibling")
    func uidPlusAppendUidWinsOverExistingExactSibling() async throws {
        let fresh = "fresh-\(UUID().uuidString)@example.com"
        let epoch = 72_501
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(21, fresh)],
        ])
        server.setUidValidity(epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.saveDraft(
            Self.draft(fresh), existingIdentity: nil, draftsFolderPath: "Drafts")
        guard case .created(.imap(let folder, let validity, let uid)) = outcome else {
            Issue.record("expected APPENDUID-backed IMAP address")
            return
        }
        let snapshot = server.snapshotMessagesWithFlags(in: "Drafts")
        #expect(folder == "Drafts")
        #expect(validity == epoch)
        #expect(uid == 22)
        #expect(snapshot.contains { $0.message.uid == 21 })
        #expect(snapshot.contains { $0.message.uid == uid })
        #expect(snapshot.filter { $0.message.messageID == "<\(fresh)>" }.count == 2)
        #expect(!server.recordedCommands().contains { $0.contains("UID SEARCH") })
    }

    @Test("Non-UIDPLUS APPEND exact-verifies one fresh match and returns its typed IMAP address")
    func nonUidPlusUniqueExactMatch() async throws {
        let fresh = "fresh-\(UUID().uuidString)@example.com"
        let epoch = 73_001
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: ["Drafts": [Self.message(31, "prefix-\(fresh)-suffix")]])
        server.setUidValidity(epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.saveDraft(
            Self.draft(fresh), existingIdentity: nil, draftsFolderPath: "Drafts")
        guard case .created(.imap(let folder, let validity, let uid)) = outcome else {
            Issue.record("expected typed IMAP address")
            return
        }
        #expect(folder == "Drafts")
        #expect(validity == epoch)
        #expect(uid == 32)
        #expect(server.snapshotMessagesWithFlags(in: "Drafts").contains {
            $0.message.uid == uid && $0.message.messageID == "<\(fresh)>"
        })
        #expect(server.recordedCommands().contains { $0.contains("UID SEARCH") })
    }

    @Test("Non-UIDPLUS APPEND with duplicate exact matches returns unaddressable")
    func nonUidPlusDuplicateExactMatch() async throws {
        let fresh = "fresh-\(UUID().uuidString)@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: ["Drafts": [Self.message(41, fresh)]])
        server.setUidValidity(74_001, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.saveDraft(
            Self.draft(fresh), existingIdentity: nil, draftsFolderPath: "Drafts")
        #expect(outcome == .unaddressable)
        #expect(server.messageIDs(in: "Drafts").filter { $0 == "<\(fresh)>" }.count == 2)
    }
}
