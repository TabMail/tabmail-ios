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
/// ⚠ **These three cases used to address the delete by a bare numeric UID, and in
/// doing so they BLESSED a second, independent defect** — `deleteDraft` resolving an
/// all-digits `draftId` through `resolveUID`'s numeric short-circuit and issuing the
/// destructive pair against a literal UID, i.e. against an ADDRESS it had never
/// identified. That leg is gone (it now refuses), so each case addresses its target
/// by the rfc822 Message-ID — which is what `MessageHeader.stableId` hands the queue
/// for an IMAP draft anyway. The EXPUNGE-scope property each case pins is unchanged;
/// only the way the target is named is. The identity property itself lives in
/// `IMAPDeleteDraftIdentityTests`.
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

        try await provider.deleteDraft(draftId: targetId, draftsFolderPath: "Drafts")

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

        try await provider.deleteDraft(draftId: targetId, draftsFolderPath: "Drafts")

        #expect(server.messageIDs(in: "Drafts") == ["<\(survivorId)>"],
                """
                the addressed draft was not actually removed (Drafts holds \
                \(server.messageIDs(in: "Drafts"))) — a delete that no-ops is the mirror image \
                of the wrong-delete it was meant to fix.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - 3. The same invariant with NO UIDPLUS to narrow the purge

    @Test("A server WITHOUT UIDPLUS still leaves a Deleted-flagged bystander alone")
    func deleteDraftWithoutUidPlusDoesNotDestroyABystander() async throws {
        // ⚠ THE COVERAGE GAP THAT LET THE DEFECT THROUGH, CLOSED. The invariant case
        // above runs on a UIDPLUS server, where `expunge(messages:)` narrows the purge
        // for free; the old non-UIDPLUS case ran with a mailbox containing NOTHING but
        // the target, so the branch that actually issued the mailbox-wide command was
        // never observed destroying anything. Between them they proved nothing about
        // the only branch where the blast radius exists. This case is the crossing of
        // the two: no UIDPLUS, AND a pre-`\Deleted` bystander the gesture never named.
        //
        // UID EXPUNGE (RFC 4315) is a UIDPLUS extension, so on this server there is no
        // narrower purge to fall back to — only the mailbox-wide one, which takes every
        // `\Deleted` message in Drafts with it. The resolution is to FAIL CLOSED and
        // skip the purge, not to widen it: "never wrong-delete" is unconditional, not
        // UIDPLUS-gated. (Matches `v2final`'s `storeDeletedAndMaybeExpunge`.)
        let targetId = "draft-no-uidplus-target@example.com"
        let bystanderId = "draft-no-uidplus-bystander@example.com"
        let bystanderUID = 7099
        let capabilities = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" }
        #expect(!capabilities.contains("UIDPLUS"), "fixture precondition: UIDPLUS must be absent")

        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: [
                "INBOX": [],
                "Drafts": [
                    Self.message(uid: bystanderUID, id: bystanderId),
                    Self.message(uid: 7100, id: targetId),
                ],
            ])
        // Same residue as the UIDPLUS case: marked \Deleted by an interrupted save or
        // by another client, never expunged, never gestured on here.
        server.setFlags(["\\Deleted"], in: "Drafts", uid: bystanderUID)
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: targetId, draftsFolderPath: "Drafts")

        let violations = server.wrongMessageViolations()
        #expect(violations.isEmpty,
                """
                deleting one draft on a server without UIDPLUS destroyed a message the \
                gesture never named: \(violations). A bare EXPUNGE is mailbox-wide \
                (RFC 3501 §6.4.3) and there is no narrower primitive here, so the purge \
                must be SKIPPED — the \\Deleted STORE has already recorded the deletion \
                intent and a UIDPLUS-capable client or the server's own policy completes \
                it. Widening the blast radius to complete this one delete is the trade \
                the "never wrong-delete" invariant exists to forbid.
                """)
        #expect(server.messageIDs(in: "Drafts").contains("<\(bystanderId)>"),
                """
                the untargeted \\Deleted bystander is gone from Drafts (it holds \
                \(server.messageIDs(in: "Drafts"))) — a message this call never identified \
                was destroyed.
                """)
    }

    @Test("Control: a server WITHOUT UIDPLUS still records the deletion, as a soft delete")
    func deleteDraftWithoutUidPlusStillMarksItsTargetDeleted() async throws {
        // Non-vacuity for the case above, and the mirror-image guard: failing closed on
        // the PURGE must not become failing closed on the DELETE. The user's gesture
        // still has to reach the server — as the `\Deleted` STORE, which is the only
        // durable record of intent such a server can hold. A `deleteDraft` that
        // returned without touching the target at all would satisfy the bystander
        // assertion trivially while silently doing nothing.
        let targetId = "draft-no-uidplus-soft@example.com"
        let capabilities = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" }
        #expect(!capabilities.contains("UIDPLUS"), "fixture precondition: UIDPLUS must be absent")

        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: ["INBOX": [], "Drafts": [Self.message(uid: 7200, id: targetId)]])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: targetId, draftsFolderPath: "Drafts")

        let flags = server.flags(in: "Drafts", rfc822MessageId: targetId)
        #expect(flags?.contains("\\Deleted") == true,
                """
                the addressed draft was not even marked \\Deleted on a server without \
                UIDPLUS (flags: \(flags.map { String(describing: $0) } ?? "message absent")). \
                Skipping the mailbox-wide EXPUNGE is the fix; skipping the STORE too would \
                make the delete a silent no-op — the mirror image.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
