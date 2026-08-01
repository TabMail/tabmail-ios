/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// 🚨 THE SYSTEM PROPERTY: **no mutation lands on a message whose identity
/// differs from the gesture's target.**
///
/// Not "the code calls `expunge(messages:)`" — that is the fix's mechanism, and a
/// mechanism-pinning test would stay green on any later rewrite that reintroduced
/// the wrong-message deletion by another route. The assertion is delegated to the
/// `FakeIMAPServer` wrong-message wire ORACLE (`expectMutation` /
/// `wrongMessageViolations`), which resolves every UID a mutating command is about
/// to destroy back to its CURRENT occupant and reports each one the test never
/// declared. Extending the existing harness is deliberate — a hand-written
/// `messageIDs(in:)` assertion is exactly the one-off this oracle replaced.
///
/// **The defect this pins (confirmed 2026-07-31).** `IMAPProvider.deleteDraft`
/// resolved the target UID set, STORE'd `\Deleted` on it, and then issued a BARE
/// `expunge()`. A bare EXPUNGE is mailbox-WIDE (RFC 3501 §6.4.3): it names no UID
/// and removes EVERY `\Deleted` message in the selected mailbox. In Drafts that is
/// not a hypothetical population — `saveDraft`'s old-copy delete marks messages
/// `\Deleted` with both the STORE and the EXPUNGE `try?`-swallowed, so a failed or
/// interrupted save leaves exactly this residue behind, and another client's
/// soft-deleted drafts qualify too. Deleting one draft destroyed all of them. This
/// is independent of any UIDVALIDITY question: it wrong-deletes on a perfectly
/// healthy mailbox.
///
/// `.serialized` — the fake binds a listening socket; parallel suites would
/// contend on ephemeral port allocation.
@Suite("A draft delete purges only its own UID, never the mailbox", .serialized)
struct IMAPDraftExpungeScopeTests {

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: draft expunge scope\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        draft body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
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

    // MARK: - 1. The invariant

    @Test("Deleting one draft leaves a co-resident Deleted-flagged draft alone")
    func deleteDraftDoesNotExpungeTheRestOfTheMailbox() async throws {
        let targetId = "draft-expunge-target@example.com"
        let bystanderId = "draft-expunge-bystander@example.com"
        let targetUID = 5150
        let bystanderUID = 5149

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: bystanderUID, id: bystanderId),
                Self.message(uid: targetUID, id: targetId),
            ],
        ])
        // The residue a `try?`-swallowed `saveDraft` old-copy delete leaves behind:
        // marked \Deleted, never expunged. The user never gestured on it here.
        server.setFlags(["\\Deleted"], in: "Drafts", uid: bystanderUID)
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: "\(targetUID)", draftsFolderPath: "Drafts")

        let violations = server.wrongMessageViolations()
        #expect(violations.isEmpty,
                """
                deleting one draft destroyed a message the gesture never named: \(violations). \
                A bare EXPUNGE is mailbox-wide (RFC 3501 §6.4.3) and takes every \\Deleted \
                message in Drafts with it — including the residue `saveDraft` leaves when its \
                own `try?`-swallowed expunge fails, and another client's soft-deleted drafts. \
                The purge must name the UID(s) actually being deleted (UID EXPUNGE, RFC 4315), \
                exactly as `IMAPProvider.idempotentMove` already does.
                """)
        #expect(server.messageIDs(in: "Drafts") == ["<\(bystanderId)>"],
                """
                Drafts should hold exactly the bystander after the delete; it holds \
                \(server.messageIDs(in: "Drafts")).
                """)
    }

    // MARK: - 2. Over-refusal controls (the mirror image)

    @Test("Control: the addressed draft really is gone on a UIDPLUS server")
    func deleteDraftStillRemovesItsOwnTarget() async throws {
        // Non-vacuity for the case above: the scoped purge must still PURGE. A
        // `deleteDraft` that quietly stopped removing anything would satisfy the
        // oracle trivially while leaving every draft the user deleted on the server,
        // to reappear on the next sync.
        let targetId = "draft-scoped-target@example.com"
        let survivorId = "draft-untouched-survivor@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 6100, id: targetId),
                Self.message(uid: 6101, id: survivorId),
            ],
        ])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: "6100", draftsFolderPath: "Drafts")

        #expect(server.messageIDs(in: "Drafts") == ["<\(survivorId)>"],
                """
                the addressed draft was not actually removed (Drafts holds \
                \(server.messageIDs(in: "Drafts"))) — a delete that no-ops is the mirror image \
                of the wrong-delete it was meant to fix.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("Control: a server WITHOUT UIDPLUS still gets its draft deleted")
    func deleteDraftWorksOnAServerWithoutUidPlus() async throws {
        // UID EXPUNGE (RFC 4315) is a UIDPLUS extension. The narrowing above is
        // therefore conditional, and the fallback must remain the mailbox-wide
        // command — `IMAPProvider.idempotentMove`'s established in-repo precedent
        // for the same decision, and the only server-side purge such a server
        // offers. Bricking draft deletion on non-UIDPLUS servers to buy a narrower
        // blast radius would be a strictly worse trade: the draft would come back
        // on the very next sync, forever.
        //
        // ⚑ This is a DELIBERATE deviation from `v2final`, whose
        // `storeDeletedAndMaybeExpunge` fails closed here (soft delete only). That
        // tree carried draft-side reconciliation this one does not.
        let targetId = "draft-no-uidplus-target@example.com"
        let capabilities = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" }
        #expect(!capabilities.contains("UIDPLUS"), "fixture precondition: UIDPLUS must be absent")

        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: ["INBOX": [], "Drafts": [Self.message(uid: 7100, id: targetId)]])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: "7100", draftsFolderPath: "Drafts")

        #expect(server.messageIDs(in: "Drafts").isEmpty,
                """
                a draft delete against a server with no UIDPLUS left the draft in place \
                (Drafts holds \(server.messageIDs(in: "Drafts"))). The scoping must degrade to \
                the mailbox-wide EXPUNGE, not refuse.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
