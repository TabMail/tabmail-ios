/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// 🚨 THE SYSTEM PROPERTY: **no mutation lands on a message whose identity
/// differs from the target the gesture named** — here, `saveDraft`'s old-copy
/// delete, whose target is "the server copy carrying the draft's PREVIOUS rfc822
/// Message-ID" and nothing else.
///
/// Not "the code calls `exactMessageIdMatches`" and not "the numeric branch is
/// gone" — those are the fix's mechanism, and a mechanism-pinning test stays
/// green on any later rewrite that reintroduces the wrong-message deletion by
/// another route. The destructive half of every assertion below is delegated to
/// the `FakeIMAPServer` wrong-message wire ORACLE (`expectMutation` /
/// `wrongMessageViolations`), which resolves every UID a mutating command is
/// about to destroy back to its CURRENT occupant and reports each one the test
/// never declared.
///
/// **The defect this pins (confirmed 2026-07-31).** `IMAPProvider.saveDraft`'s
/// old-copy delete destroyed a message it had never identified, by either of two
/// routes:
///
///  * **Numerically.** `existingDraftId` is `Draft.serverDraftId`, a UID persisted
///    at an earlier save. A UID is a mutable ADDRESS: the `Draft` table survives a
///    `UIDVALIDITY` reset but the UID it names does not, so after a renumber that
///    integer names a DIFFERENT message — which this then STORE-`\Deleted`-ed and
///    EXPUNGEd. Destruction of the user's real mail, constraint C3. It bypassed
///    `resolveUID` entirely, so none of the identity guards restored by
///    `071b52751` applied to it.
///  * **By an unverified substring SEARCH.** IMAP `SEARCH HEADER Message-ID` is
///    RFC 3501 SUBSTRING matching, not equality, and the whole hit set was
///    destroyed as a set — so a message whose id merely CONTAINS the target died
///    with it, and two legitimate drafts sharing an id both died. It also searched
///    by the FRESH Message-ID, which the old copy cannot carry
///    (`DraftStore.pushDraftToServer` rotates it every push), so it simultaneously
///    orphaned the copy it was supposed to remove.
///
/// **The fail-safe direction is INVERTED relative to `v2final`'s delete-gesture
/// path, deliberately.** A failed identity VERDICT here skips the delete and still
/// APPENDs — refusing the whole save would drop the user's edit. So every
/// fail-closed case below also asserts the user-intention half: the fresh copy
/// reached the server anyway. `saveDraftDeletesTheOldCopyItCorrectlyIdentified` is
/// the over-refusal control that keeps "skip on failure" from degrading into
/// "never delete".
///
/// `.serialized` — the fake binds a listening socket; parallel suites would
/// contend on ephemeral port allocation.
@Suite("A draft save deletes only the old copy it identified, never an address", .serialized)
struct IMAPSaveDraftIdentityTests {

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: save draft identity\r
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

    /// `FakeIMAPServer.messageIDs(in:)` returns the RFC 2822 header value verbatim,
    /// angle brackets included — this wraps a bare id for comparison.
    private static func bracketed(_ id: String) -> String { "<\(id)>" }

    private static func draft(messageId: String, body: String = "content") -> DraftMessage {
        var d = DraftMessage(to: ["recipient@example.com"], subject: "Edited", body: body)
        d.messageId = messageId
        return d
    }

    private static func unique(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())@example.com"
    }

    // MARK: - 1. The invariant

    @Test("A stale numeric serverDraftId never destroys whatever now occupies that UID")
    func saveDraftNeverDeletesByStaleNumericUID() async throws {
        // The old copy is GONE (a reset renumbered the folder and it did not come
        // back under this identity), and an unrelated real message now occupies the
        // UID the Draft row still remembers. The pre-fix numeric leg STORE-\Deleted +
        // EXPUNGEd that UID blind.
        let occupantId = Self.unique("real-mail-now-at-the-stale-uid")
        let previousDraftId = Self.unique("old-draft-that-no-longer-exists")
        let freshDraftId = Self.unique("fresh-draft")
        let staleUID = 7

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: staleUID, id: occupantId)],
        ])
        // The ONLY message this save is entitled to destroy is the old copy, named by
        // its previous rfc822 id. Registering it (rather than nothing) ARMS the
        // oracle — an empty registration set leaves it silent by design.
        server.expectMutation(rfc822MessageId: previousDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: String(staleUID),
            previousRfc822MessageId: previousDraftId,
            draftsFolderPath: "Drafts")

        let violations = server.wrongMessageViolations()
        #expect(violations.isEmpty,
                """
                the save destroyed a message it never identified: \(violations). A stored \
                UID is an ADDRESS, not an identity — after a UIDVALIDITY renumber it names \
                somebody else's mail. The old copy must be resolved by its previous rfc822 \
                Message-ID or not at all.
                """)
        #expect(server.messageIDs(in: "Drafts").contains(Self.bracketed(occupantId)),
                "the unrelated occupant of the stale UID must survive untouched")
        // The user-intention half: a skipped delete must never cost the edit.
        #expect(server.messageIDs(in: "Drafts").contains(Self.bracketed(freshDraftId)),
                "the user's edit must still be APPENDed after the old-copy delete found nothing")
    }

    @Test("After a renumber the old copy is found at its NEW UID, and the remembered UID is left alone")
    func saveDraftFindsRenumberedOldCopyAndSparesTheRememberedUID() async throws {
        // The realistic post-UIDVALIDITY shape, and the one that pins BOTH halves at
        // once: `Draft.serverDraftId` still says 71, but the resync put the old copy
        // at 500 and an unrelated message at 71. The pre-fix numeric leg destroyed 71
        // AND orphaned the old copy. It also kills the "pass the fresh id instead"
        // mutant: the fresh id matches nothing on the server, so the old copy would
        // survive.
        let previousDraftId = Self.unique("old-copy-after-renumber")
        let freshDraftId = Self.unique("fresh-after-renumber")
        let bystanderId = Self.unique("unrelated-mail-renumbered-onto-71")
        let rememberedUID = 71
        let actualOldCopyUID = 500

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: rememberedUID, id: bystanderId),
                Self.message(uid: actualOldCopyUID, id: previousDraftId),
            ],
        ])
        server.expectMutation(rfc822MessageId: previousDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: String(rememberedUID),
            previousRfc822MessageId: previousDraftId,
            draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                "the save mutated a message the gesture never named: \(server.wrongMessageViolations())")
        let remaining = server.messageIDs(in: "Drafts")
        #expect(remaining.contains(Self.bracketed(bystanderId)),
                "the message that now occupies the remembered UID must survive")
        #expect(!remaining.contains(Self.bracketed(previousDraftId)),
                """
                the old copy was orphaned — it must be resolved by its previous rfc822 \
                Message-ID (epoch-immune, so a renumber cannot hide it). Searching by the \
                FRESH id, which no server copy carries yet, leaves exactly this residue.
                """)
        #expect(remaining.contains(Self.bracketed(freshDraftId)), "the fresh copy must be appended")
    }

    @Test("A message whose Message-ID merely CONTAINS the previous id survives; only the exact match dies")
    func saveDraftSubstringImpostorSurvivesOnlyExactMatchDeleted() async throws {
        // RFC 3501 HEADER SEARCH is substring matching (the fake mirrors it), so the
        // raw hit set holds both. Destroying the set — the pre-fix behaviour — kills a
        // message that was never the target. `existingDraftId` is non-numeric here so
        // this exercises the search leg specifically.
        let previousDraftId = Self.unique("old-draft-substring")
        let impostorId = "prefix-\(previousDraftId)-suffix"
        let freshDraftId = Self.unique("fresh-substring")

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 21, id: previousDraftId),
                Self.message(uid: 22, id: impostorId),
            ],
        ])
        server.expectMutation(rfc822MessageId: previousDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: "draft-resource-id-not-a-uid",
            previousRfc822MessageId: previousDraftId,
            draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                """
                a substring-only HEADER SEARCH hit was destroyed: \
                \(server.wrongMessageViolations()). Substring containment is not identity — \
                each hit's own Message-ID must be FETCHed and compared exactly before any \
                destructive command names it.
                """)
        let remaining = server.messageIDs(in: "Drafts")
        #expect(remaining.contains(Self.bracketed(impostorId)),
                "the substring-only impostor must survive untouched")
        #expect(!remaining.contains(Self.bracketed(previousDraftId)),
                "the EXACT match is the target and must still be deleted")
        #expect(remaining.contains(Self.bracketed(freshDraftId)), "the fresh copy must be appended")
    }

    @Test("Two drafts sharing the previous Message-ID both survive — the ambiguous delete fails closed and the save still APPENDs")
    func saveDraftAmbiguousPreviousIdFailsClosedAndStillAppends() async throws {
        // Same-rfc Drafts siblings are legitimate. Destroying the set destroys one of
        // them, and there is no way to tell which is the old copy — so refuse. The
        // refusal must cost only the cleanup, never the user's edit.
        let sharedPreviousId = Self.unique("shared-previous-id")
        let freshDraftId = Self.unique("fresh-after-ambiguity")
        let uid1 = 81
        let uid2 = 82

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: uid1, id: sharedPreviousId),
                Self.message(uid: uid2, id: sharedPreviousId),
            ],
        ])
        // Nothing may be destroyed at all here, but the oracle needs a non-empty
        // registration to be armed — the fresh id names a message that does not exist
        // when any delete would be issued, so every mutation is a violation.
        server.expectMutation(rfc822MessageId: freshDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: String(uid1),
            previousRfc822MessageId: sharedPreviousId,
            draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                """
                an ambiguous old-copy delete destroyed a sibling: \
                \(server.wrongMessageViolations()). With 2+ exact matches the target is \
                unknowable; fail closed.
                """)
        let remaining = server.messageIDs(in: "Drafts")
        #expect(remaining.filter { $0 == Self.bracketed(sharedPreviousId) }.count == 2,
                """
                both siblings sharing the previous Message-ID must survive the refused \
                delete; Drafts holds \(remaining).
                """)
        #expect(remaining.contains(Self.bracketed(freshDraftId)),
                """
                the fresh copy was NOT appended. Refusing the CLEANUP must never refuse the \
                SAVE — the mirror-image bug is a lost edit, which outranks a duplicate.
                """)
    }

    @Test("With no previous Message-ID no delete is attempted — the fresh id is never substituted as a target")
    func saveDraftNilPreviousIdNeverDeletesTheFreshIdResident() async throws {
        // A prior interrupted attempt already APPENDed a copy under the fresh id.
        // Seeding it is what makes this mutant-killing: a "fall back to the fresh id"
        // implementation WOULD find and destroy it, while without the resident such a
        // fallback searches for nothing and the test false-passes.
        let freshDraftId = Self.unique("fresh-resident")
        let residentUID = 91

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: residentUID, id: freshDraftId)],
        ])
        // Nothing is deletable: with no previous id there is no identified old copy.
        // Registering an id no message carries arms the oracle against every mutation.
        server.expectMutation(rfc822MessageId: Self.unique("nothing-may-be-mutated"))
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: String(residentUID),
            previousRfc822MessageId: nil,
            draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                """
                a delete was issued with no identified target: \
                \(server.wrongMessageViolations()).
                """)
        #expect(server.messageIDs(in: "Drafts").filter { $0 == Self.bracketed(freshDraftId) }.count == 2,
                """
                Drafts should hold the untouched resident AND the new APPEND; it holds \
                \(server.messageIDs(in: "Drafts")). One copy means a fresh-id fallback \
                destroyed the resident.
                """)
    }

    // MARK: - 2. Over-refusal control (the mirror image)

    @Test("Control: an old copy that IS correctly identified really is deleted")
    func saveDraftDeletesTheOldCopyItCorrectlyIdentified() async throws {
        // Non-vacuity for every case above. "Skip the delete when verification fails"
        // degrades into "never delete" without this: each re-save would then leave its
        // predecessor behind and the user's Drafts folder would grow one stale copy
        // per keystroke-batch, all of them re-materialising on the next sync.
        let previousDraftId = Self.unique("old-copy-happy-path")
        let freshDraftId = Self.unique("fresh-happy-path")
        let bystanderId = Self.unique("unrelated-draft")
        let oldUID = 3

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: oldUID, id: previousDraftId),
                Self.message(uid: 4, id: bystanderId),
            ],
        ])
        server.expectMutation(rfc822MessageId: previousDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(
            Self.draft(messageId: freshDraftId),
            existingDraftId: String(oldUID),
            previousRfc822MessageId: previousDraftId,
            draftsFolderPath: "Drafts")

        let remaining = server.messageIDs(in: "Drafts")
        #expect(!remaining.contains(Self.bracketed(previousDraftId)),
                """
                the correctly-identified old copy was NOT removed (Drafts holds \(remaining)) \
                — a delete that no-ops is the mirror image of the wrong-delete it was meant \
                to fix.
                """)
        #expect(remaining.contains(Self.bracketed(freshDraftId)), "the fresh copy must be appended")
        #expect(remaining.contains(Self.bracketed(bystanderId)), "the unrelated draft must be untouched")
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
