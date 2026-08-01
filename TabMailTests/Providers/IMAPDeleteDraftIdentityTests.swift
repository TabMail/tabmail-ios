/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// 🚨 THE SYSTEM PROPERTY: **no mutation lands on a message whose identity differs
/// from the target the gesture named** — here the user's DELETE gesture, whose
/// target is "the draft carrying this rfc822 Message-ID" and nothing else.
///
/// Not "the code calls `exactMessageIdMatches`", and not "the numeric branch is
/// gone" — those are the fix's mechanism, and a mechanism-pinning test stays green
/// on any later rewrite that reintroduces the wrong-message deletion by another
/// route. The destructive half of every assertion below is delegated to the
/// `FakeIMAPServer` wrong-message wire ORACLE (`expectMutation` /
/// `wrongMessageViolations`), which resolves every UID a mutating command is about
/// to destroy back to its CURRENT occupant and reports each one the test never
/// declared. Extending that harness is deliberate: it is the generic oracle for
/// this whole bug class, and a hand-written `messageIDs(in:)` assertion is exactly
/// the one-off it replaced.
///
/// **The defect this pins (confirmed 2026-08-01).** `IMAPProvider.deleteDraft`
/// destroyed a message it had never identified, by either of two routes — the same
/// pair `saveDraft` lost in `68298e534`, still live on the delete gesture:
///
///  * **Numerically.** `resolveUID` SHORT-CIRCUITS an all-digits `draftId` straight
///    to `UIDSet(UID(value))` — no SEARCH, no FETCH, no identity — and the STORE
///    `\Deleted` + EXPUNGE that followed destroyed whatever occupied that integer. A
///    UID is a mutable ADDRESS: the `Draft` row and the `PendingOperation` survive a
///    `UIDVALIDITY` reset, the UID they name does not, so after a renumber that
///    integer names a DIFFERENT message and the user's delete destroyed their real
///    mail (constraint C3).
///  * **By an unverified substring SEARCH.** IMAP `SEARCH HEADER Message-ID` is RFC
///    3501 SUBSTRING matching, not equality (the fake mirrors it), and the whole raw
///    hit set was destroyed as a set — so a message whose id merely CONTAINS the
///    target died with it, and two legitimate same-rfc Drafts siblings both died.
///
/// **The fail-safe direction is the OPPOSITE of `saveDraft`'s, deliberately.** A
/// failed identity VERDICT there skips the cleanup and still APPENDs, because
/// refusing would drop the user's edit. Here refusing costs the user nothing — the
/// draft simply remains and the gesture can be re-issued — so every failed verdict
/// THROWS rather than silently completing an op whose server draft survived.
/// `deleteDraftRemovesTheDraftItIdentifiedAfterARenumber` and
/// `deleteDraftRemovesACorrectlyIdentifiedDraft` are the over-refusal controls that
/// keep "refuse when unsure" from degrading into "never delete".
///
/// `.serialized` — the fake binds a listening socket; parallel suites would contend
/// on ephemeral port allocation.
@Suite("A draft delete destroys only the identity the gesture named", .serialized)
struct IMAPDeleteDraftIdentityTests {

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: delete draft identity\r
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

    private static func unique(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())@example.com"
    }

    // MARK: - 1. The invariant

    @Test("A stale numeric serverDraftId never destroys whatever now occupies that UID")
    func deleteDraftNeverDestroysTheOccupantOfAStaleNumericUID() async throws {
        // The realistic post-UIDVALIDITY shape for the delete gesture: the queued op
        // still carries `Draft.serverDraftId`, a UID persisted at an earlier save, and
        // a renumber has since put an unrelated real message there. The pre-fix numeric
        // leg STORE-`\Deleted` + EXPUNGEd that UID blind.
        let occupantId = Self.unique("real-mail-now-at-the-stale-uid")
        let deletedDraftId = Self.unique("the-draft-the-user-deleted")
        let staleUID = 5150

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: staleUID, id: occupantId)],
        ])
        // The ONLY message this gesture is entitled to destroy is the draft it named.
        // Registering it (rather than nothing) ARMS the oracle — an empty registration
        // set leaves it silent by design — and no message here carries that id, so any
        // mutation at all is a violation.
        server.expectMutation(rfc822MessageId: deletedDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.deleteDraft(draftId: String(staleUID), rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")
        }

        let violations = server.wrongMessageViolations()
        #expect(violations.isEmpty,
                """
                the delete destroyed a message it never identified: \(violations). A stored \
                UID is an ADDRESS, not an identity — after a UIDVALIDITY renumber it names \
                somebody else's mail. The draft must be resolved by its rfc822 Message-ID or \
                not at all.
                """)
        #expect(server.messageIDs(in: "Drafts") == [Self.bracketed(occupantId)],
                """
                the unrelated occupant of the stale UID must survive untouched; Drafts holds \
                \(server.messageIDs(in: "Drafts")).
                """)
    }

    @Test("A message whose Message-ID merely CONTAINS the target survives; only the exact match dies")
    func deleteDraftSubstringImpostorSurvivesOnlyExactMatchDeleted() async throws {
        // RFC 3501 HEADER SEARCH is substring matching (the fake mirrors it), so the raw
        // hit set holds both. Destroying the set — the pre-fix behaviour — kills a
        // message that was never the target.
        let targetId = Self.unique("draft-substring-target")
        let impostorId = "prefix-\(targetId)-suffix"

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 21, id: targetId),
                Self.message(uid: 22, id: impostorId),
            ],
        ])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: targetId, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                """
                a substring-only HEADER SEARCH hit was destroyed: \
                \(server.wrongMessageViolations()). Substring containment is not identity — \
                each hit's own Message-ID must be FETCHed and compared exactly before any \
                destructive command names it.
                """)
        let remaining = server.messageIDs(in: "Drafts")
        #expect(remaining.contains(Self.bracketed(impostorId)),
                "the substring-only impostor must survive untouched; Drafts holds \(remaining)")
        #expect(!remaining.contains(Self.bracketed(targetId)),
                "the EXACT match is the target and must still be deleted; Drafts holds \(remaining)")
    }

    @Test("Two drafts sharing the Message-ID both survive — the ambiguous delete fails closed")
    func deleteDraftAmbiguousIdFailsClosedAndDestroysNeitherSibling() async throws {
        // Same-rfc Drafts siblings are legitimate. Destroying the set destroys one that
        // the gesture never named, and there is no way to tell which is which — so
        // refuse. Sync reconciles the survivor; the user can re-issue.
        let sharedId = Self.unique("shared-draft-id")

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 81, id: sharedId),
                Self.message(uid: 82, id: sharedId),
            ],
        ])
        // Nothing may be destroyed at all here, but the oracle needs a non-empty
        // registration to be armed — registering an id no message carries makes every
        // mutation a violation.
        server.expectMutation(rfc822MessageId: Self.unique("nothing-may-be-mutated"))
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.deleteDraft(draftId: sharedId, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")
        }

        #expect(server.wrongMessageViolations().isEmpty,
                """
                an ambiguous delete destroyed a sibling: \(server.wrongMessageViolations()). \
                With 2+ exact matches the target is unknowable; fail closed.
                """)
        let remaining = server.messageIDs(in: "Drafts")
        #expect(remaining.filter { $0 == Self.bracketed(sharedId) }.count == 2,
                """
                both siblings sharing the Message-ID must survive the refused delete; Drafts \
                holds \(remaining).
                """)
    }

    @Test("A draftId that is not a usable Message-ID is refused before any destructive command")
    func deleteDraftMalformedIdentityNeverReachesADestructiveCommand() async throws {
        // The third failed VERDICT alongside "none exact" and "more than one": the id
        // itself does not canonicalize. Seeding a resident whose id CONTAINS the
        // malformed value is what makes this mutant-killing — an implementation that
        // searched anyway and acted on the raw hit set would destroy it.
        let malformed = "not-a-message-id"
        let residentId = "\(malformed)-but-a-real-draft@example.com"

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: 31, id: residentId)],
        ])
        server.expectMutation(rfc822MessageId: Self.unique("nothing-may-be-mutated"))
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.deleteDraft(draftId: malformed, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")
        }

        #expect(server.wrongMessageViolations().isEmpty,
                """
                a destructive command was issued for an identity that never resolved: \
                \(server.wrongMessageViolations()).
                """)
        #expect(server.messageIDs(in: "Drafts") == [Self.bracketed(residentId)],
                """
                the resident whose Message-ID merely CONTAINS the malformed value must \
                survive; Drafts holds \(server.messageIDs(in: "Drafts")).
                """)
    }

    // MARK: - 2. Over-refusal controls (the mirror image)

    @Test("Control: after a renumber the draft is found at its NEW UID and the remembered one is spared")
    func deleteDraftRemovesTheDraftItIdentifiedAfterARenumber() async throws {
        // The positive half of case 1, and the reason a bare UID is not merely unsafe
        // but unnecessary: a Message-ID SEARCH is epoch-IMMUNE, so it finds the draft
        // wherever the renumber put it while the message that inherited the remembered
        // UID is never touched. Without this case a never-delete mutant passes the whole
        // suite.
        let draftId = Self.unique("draft-after-renumber")
        let bystanderId = Self.unique("unrelated-mail-renumbered-onto-71")
        let rememberedUID = 71
        let actualDraftUID = 500

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: rememberedUID, id: bystanderId),
                Self.message(uid: actualDraftUID, id: draftId),
            ],
        ])
        server.expectMutation(rfc822MessageId: draftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: draftId, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                "the delete mutated a message the gesture never named: \(server.wrongMessageViolations())")
        #expect(server.messageIDs(in: "Drafts") == [Self.bracketed(bystanderId)],
                """
                the draft must be removed at its CURRENT UID and the occupant of the \
                remembered UID left alone; Drafts holds \(server.messageIDs(in: "Drafts")).
                """)
    }

    @Test("Control: a draft whose Message-ID carries a colon is still delete-verified")
    func deleteDraftVerifiesAColonBearingServerMessageId() async throws {
        // 🚨 THE §3 DECISION, EXECUTABLE. Both sides of this comparison are
        // SERVER-ORIGINATED Message-IDs, and RFC 5322 permits a colon inside a
        // `no-fold-literal` domain. `MessageIdentity.usableRfc822Tail` REJECTS such an
        // id — a `v3`-only term that exists for CONTENT-KEY folder scoping and answers
        // a different question entirely — so verifying through it would return zero
        // exact matches for a message that plainly IS the target, and under the
        // fail-closed rule above this draft's delete would throw FOREVER: the user
        // deletes it, it comes back on the next sync, every time. Hence
        // `MessageIdComparison.identityOnly` /
        // `MessageIdentity.comparableRfc822Identity` (= `v2final`'s
        // `durableActionRFC822MessageId`) on this path only.
        let colonDraftId = "draft-\(UUID().uuidString.lowercased())@[IPv6:2001:db8::1]"
        let bystanderId = Self.unique("unrelated-draft")
        #expect(MessageIdentity.usableRfc822Tail(colonDraftId) == nil,
                "fixture precondition: the content-key normalizer must REJECT this id")
        #expect(MessageIdentity.comparableRfc822Identity(colonDraftId) == colonDraftId,
                "fixture precondition: the identity normalizer must ACCEPT this id unchanged")

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 41, id: colonDraftId),
                Self.message(uid: 42, id: bystanderId),
            ],
        ])
        server.expectMutation(rfc822MessageId: colonDraftId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: colonDraftId, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")

        #expect(server.wrongMessageViolations().isEmpty,
                "the delete mutated a message the gesture never named: \(server.wrongMessageViolations())")
        #expect(server.messageIDs(in: "Drafts") == [Self.bracketed(bystanderId)],
                """
                a colon-bearing (but perfectly legal) server Message-ID was not \
                delete-verified — Drafts holds \(server.messageIDs(in: "Drafts")). Refusing \
                it forever is the mirror-image bug: the draft returns on every sync.
                """)
    }

    @Test("Control: an ordinary correctly-identified draft really is deleted")
    func deleteDraftRemovesACorrectlyIdentifiedDraft() async throws {
        // Plain non-vacuity, with no renumber and no colon in sight: the simplest
        // possible happy path, so the refusals above can never be satisfied by a
        // `deleteDraft` that quietly stopped deleting anything.
        let targetId = Self.unique("draft-happy-path")
        let bystanderId = Self.unique("unrelated-draft")

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: 3, id: targetId),
                Self.message(uid: 4, id: bystanderId),
            ],
        ])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(draftId: targetId, rfc822MessageId: nil, uidValidity: nil, draftsFolderPath: "Drafts")

        #expect(server.messageIDs(in: "Drafts") == [Self.bracketed(bystanderId)],
                """
                the correctly-identified draft was NOT removed (Drafts holds \
                \(server.messageIDs(in: "Drafts"))) — a delete that no-ops is the mirror image \
                of the wrong-delete it was meant to fix.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
