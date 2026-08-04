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

    /// ⚠️ RE-SCOPED (B1, ADR-IOS-068/D4). Previous display name:
    /// *"Non-UIDPLUS APPEND exact-verifies one fresh match and returns its typed
    /// IMAP address"*. It asserted the opposite of what D4 requires — that the
    /// sole exact `SEARCH` survivor's UID becomes this draft's mutation address —
    /// and so BLESSED the defect this test now pins. The fixture is unchanged
    /// (uid 31 is a substring decoy the exact-verify used to reject, uid 32 the
    /// appended copy); only the expected outcome moved, because no `SEARCH`
    /// result may become a mutation target however well verified.
    ///
    /// This is the "the guards would all have passed" cell: the appended copy IS
    /// present and IS the unique exact match, so cardinality, exact-verify and a
    /// positive epoch all succeed — and the address is still refused, because
    /// nothing correlates any hit with THIS attempt.
    @Test("Without APPENDUID no address is minted, even when exactly one exact match would verify")
    func noAppendUidRefusesTheUniqueExactMatch() async throws {
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

        #expect(outcome == .unaddressable)
        // The user's content still reached the server — failing closed withholds
        // the ADDRESS, never the draft.
        #expect(server.snapshotMessagesWithFlags(in: "Drafts").contains {
            $0.message.uid == 32 && $0.message.messageID == "<\(fresh)>"
        })
        // D4's stated property, asserted on the wire: nothing searches.
        #expect(!server.recordedCommands().contains { $0.contains("UID SEARCH") })
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
        // B1 — this outcome is now UNCONDITIONAL on the no-APPENDUID arm; the
        // match count no longer participates in it. Kept as the duplicate-sibling
        // cell of that closure, not as evidence that cardinality is what decides.
        #expect(outcome == .unaddressable)
        #expect(server.messageIDs(in: "Drafts").filter { $0 == "<\(fresh)>" }.count == 2)
    }

    /// **The C3 pin (B1, ADR-IOS-068/D4).** The invariant: *no mutation may land
    /// on a message whose identity differs from the one this attempt created.*
    ///
    /// The reachable wrong-message path, on a CONFORMANT server: the mailbox is
    /// one RFC 4315 §3 exempts from `APPENDUID` (`UIDNOTSTICKY`, or
    /// APPEND-but-not-SELECT) while UIDPLUS — and therefore `UID EXPUNGE` — stays
    /// available. Between the APPEND's tagged OK and the next command another
    /// IMAP actor removes the appended copy, leaving exactly one same-Message-ID
    /// sibling. Every guard the old arm relied on then passes ON THE SIBLING:
    /// one `SEARCH` candidate, one exact Message-ID match, a positive epoch, a
    /// positive UID. Its address is minted as this draft's, and production's very
    /// next step on a draft address — `deleteDraft` → `deleteDraftStrong` →
    /// STORE `\Deleted` → `expungeScopedToTargets` → `UID EXPUNGE` — destroys it.
    /// That is the one delete in this app that is not a move to Trash.
    ///
    /// ⚠️ The RFC-keyed `wrongMessageViolations()` oracle is STRUCTURALLY BLIND
    /// here and is asserted only as a non-regression: the bystander and the draft
    /// share one Message-ID by construction (that IS the defect), so an oracle
    /// that discriminates by Message-ID cannot tell them apart. The load-bearing
    /// assertions are therefore the physical wire state and the command log.
    @Test("A same-Message-ID bystander is never adopted or mutated when APPENDUID is withheld")
    func withheldAppendUidNeverAdoptsASameMessageIdBystander() async throws {
        let shared = "shared-\(UUID().uuidString)@example.com"
        let epoch = 75_001
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(51, shared)]])
        server.setUidValidity(epoch, for: "Drafts")
        server.withholdAppendUID(in: "Drafts")
        server.vanishAppendedMessages(in: "Drafts")
        server.expectMutation(rfc822MessageId: shared)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.saveDraft(
            Self.draft(shared), existingIdentity: nil, draftsFolderPath: "Drafts")

        // 1. No identity is minted from anything this attempt did not create.
        #expect(outcome == .unaddressable)

        // 2. If one ever is again, make the cost visible rather than latent:
        //    drive the exact next call production makes on a draft address.
        if case .created(.imap(let folder, let validity, let uid)) = outcome {
            try? await provider.deleteDraft(
                identity: .imap(folder: folder, uidValidity: validity, uid: uid))
        }

        // 3. The bystander is untouched ON THE WIRE — present, and not even
        //    soft-deleted.
        let survivors = server.snapshotMessagesWithFlags(in: "Drafts")
        #expect(survivors.contains { $0.message.uid == 51 })
        #expect(survivors.first { $0.message.uid == 51 }?.flags.contains("\\Deleted") != true)

        // 4. No command capable of mutating it was ever issued, and nothing
        //    searched for it in the first place.
        let commands = server.recordedCommands()
        #expect(!commands.contains { $0.contains("UID SEARCH") })
        #expect(!commands.contains { $0.contains("UID STORE") })
        #expect(!commands.contains { $0.contains("EXPUNGE") })
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
