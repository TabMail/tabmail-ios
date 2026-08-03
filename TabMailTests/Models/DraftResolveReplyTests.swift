/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Draft key parsing")
struct DraftKeyParsingTests {

    @Test("draftKey for reply encodes accountId and stableId")
    func replyDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: false, newId: nil)
        #expect(key == "reply:acct1:msg@example.com")
    }

    @Test("draftKey for forward encodes accountId and stableId")
    func forwardDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: true, newId: nil)
        #expect(key == "forward:acct1:msg@example.com")
    }

    @Test("draftKey for new compose uses provided UUID")
    func newDraftKey() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: "test-uuid")
        #expect(key == "new:test-uuid")
    }

    @Test("draftKey for new compose generates UUID when nil")
    func newDraftKeyGenerated() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        #expect(key.hasPrefix("new:"))
        #expect(key.count > "new:".count) // UUID appended
    }

    @Test("draftKey roundtrip: stableId can be extracted from reply key")
    func roundtripReply() {
        let stableKey = "myAccount:some-rfc822@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        // Parse it back
        #expect(key.hasPrefix("reply:"))
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "myAccount")
        #expect(stableId == "some-rfc822@host.com")
    }

    @Test("draftKey roundtrip: stableId with colons preserved")
    func roundtripWithColons() {
        // rfc822 message IDs can contain colons
        let stableKey = "acct:complex:id:with:colons@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "acct")
        #expect(stableId == "complex:id:with:colons@host.com")
    }

    @Test("ActiveAgentTracker.messageStableId parsing matches draftKey format")
    @MainActor func trackerParsingConsistency() {
        // The session key for message-detail is "msg:{accountId}:{stableId}"
        // This should parse correctly via ActiveAgentTracker.messageStableId
        let result = ActiveAgentTracker.messageStableId(from: "msg:acct1:rfc822@example.com")
        #expect(result?.accountId == "acct1")
        #expect(result?.stableId == "rfc822@example.com")
    }
}

@Suite("Locally authored draft reopen authority")
struct LocallyAuthoredDraftOpenAuthorityTests {
    private func draft(
        accountId: String = "acc1",
        epoch: String = "E1",
        serverId: String? = nil,
        status: String? = "pushed"
    ) -> Draft {
        var value = Draft(
            id: "draft-1", accountId: accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: "body", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: serverId, serverPushStatus: status,
            rfc822MessageId: "draft@example.com", attachmentsDirName: nil)
        value.instanceEpoch = epoch
        return value
    }

    @Test("Every locally-authored draft handoff rejects an owner, generation, status, runtime, or native-address replacement")
    func exactHandoffAuthority() {
        let placeholder = PendingOperation.draftPlaceholderMessageId(
            draftId: "draft-1", instanceEpoch: "E1")
        let cases: [(LocallyAuthoredDraftOpenAuthority, Draft)] = [
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .imap,
                address: .placeholder(messageId: placeholder)),
             draft()),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .gmail,
                address: .gmail(resourceId: "gmail-1", containedMessageId: "message-1")),
             draft(serverId: "gmail-1")),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .outlook,
                address: .outlook(graphId: "graph-1")),
             draft(serverId: "graph-1")),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .demo,
                address: .demo(localId: "demo-1")),
             draft(serverId: "demo-1")),
        ]

        for (authority, original) in cases {
            #expect(authority.matches(original, runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(accountId: "acc2", serverId: original.serverDraftId),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(epoch: "E2", serverId: original.serverDraftId),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(serverId: original.serverDraftId, status: "dirty"),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(original, runtimeKind: .unknown))
            // SUBTRACT — v2final's placeholder authority is the local
            // draftId+instanceEpoch owner, not a provider-native address.
            if case .placeholder = authority.address { continue }
            #expect(!authority.matches(
                draft(serverId: original.serverDraftId == nil ? "unexpected" : "replacement"),
                runtimeKind: authority.runtimeKind))
        }
    }
}

// MARK: - T5.8 — a reply's quoted body must belong to the message the user replied to
//
// The SYSTEM PROPERTY under test, stated once: whatever a reply/forward draft
// quotes, attributes, or forwards attachments from must be the message the USER
// replied to — never whatever row happens to occupy the mutable `replyToId`
// primary key at reopen time. `replyToId` is `accountId:folderPath:messageId`; a
// folder move re-keys it and a UIDVALIDITY reset + purge-and-resync can seat a
// DIFFERENT physical message at the identical key.
//
// These tests assert that property (what comes back), never the mechanism (which
// column was consulted).

/// The pure address baseline. No database — these pin the three-valued verdict
/// itself, in particular that "cannot tell" is NOT "different".
@Suite("Reply-target address verdict (T5.8)")
struct ReplyTargetAddressVerdictTests {

    @Test("A UIDVALIDITY turnover at the same UID is a proven mismatch")
    func epochTurnoverAtSameUidIsMismatch() {
        // The reset case: the mailbox re-numbered, so UID 42 now addresses a
        // DIFFERENT message. The provider id alone still compares equal — only the
        // epoch disagrees, which is exactly why the epoch is stored.
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: 100,
            hitProviderMessageId: "42", hitUidValidity: 200,
            isEpochAddressed: true) == .mismatch)
    }

    @Test("A different provider id is a proven mismatch")
    func differentProviderIdIsMismatch() {
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: 100,
            hitProviderMessageId: "43", hitUidValidity: 100,
            isEpochAddressed: true) == .mismatch)
    }

    @Test("The same address under the same epoch is confirmed")
    func sameAddressSameEpochIsConfirmed() {
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: 100,
            hitProviderMessageId: "42", hitUidValidity: 100,
            isEpochAddressed: true) == .confirmed)
    }

    @Test("A stable-provider-id account, which has no epoch at all, is confirmed")
    func stableProviderIdWithNoEpochIsConfirmed() {
        // Gmail/Graph never observe a UIDVALIDITY, so both sides are nil forever.
        // Treating that as unverifiable would refuse every Gmail reply quote.
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "18c9abc", expectedUidValidity: nil,
            hitProviderMessageId: "18c9abc", hitUidValidity: nil,
            isEpochAddressed: false) == .confirmed)
    }

    /// 🚨 AUDIT ROUND 1 / C-2. The SAME (nil, nil) input on a RENUMBERABLE id space
    /// is not proof of anything: a bare UID names a slot, and two absences do not
    /// establish that the slot still holds the same message. This cell returned
    /// `.confirmed` for every provider before the fix, which is what let an
    /// unstamped IMAP reply target be accepted purely for sitting at the same UID.
    @Test("The same bare UID with no epoch on either side is NOT confirmed on a renumberable id space")
    func bareUidWithNoEpochOnEitherSideIsNotConfirmed() {
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: nil,
            hitProviderMessageId: "42", hitUidValidity: nil,
            isEpochAddressed: true) == .unverifiable)
    }

    @Test("A one-sided unknown epoch is unverifiable, never a mismatch")
    func oneSidedUnknownEpochIsUnverifiable() {
        // "We could not determine the answer" must never be laundered into a
        // positive disagreement, in either direction.
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: 100,
            hitProviderMessageId: "42", hitUidValidity: nil,
            isEpochAddressed: true) == .unverifiable)
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: "42", expectedUidValidity: nil,
            hitProviderMessageId: "42", hitUidValidity: 100,
            isEpochAddressed: true) == .unverifiable)
    }

    @Test("An absent address stamp is unverifiable, never a mismatch")
    func absentStampIsUnverifiable() {
        // Every pre-v80 draft row. Absence of a stamp is absence of evidence.
        #expect(Draft.replyTargetAddressVerdict(
            expectedProviderMessageId: nil, expectedUidValidity: nil,
            hitProviderMessageId: "42", hitUidValidity: 200,
            isEpochAddressed: true) == .unverifiable)
    }
}

/// The end-to-end property, over a real migrated database.
@Suite("Reply quote identity (T5.8)")
struct ReplyQuoteIdentityTests {

    /// Content markers deliberately unmistakable in a failure message.
    private static let foreignMarker = "CONFIDENTIAL-FOREIGN-BODY-MUST-NEVER-BE-QUOTED"
    private static let genuineMarker = "GENUINE-REPLY-TARGET-BODY"

    @discardableResult
    private static func insertHeader(
        _ db: DatabaseQueue,
        messageId: String,
        folderPath: String = "INBOX",
        accountId: String = "acc1",
        rfc822MessageId: String?,
        observedUidValidity: Int?,
        from: String = "sender@example.com",
        snippet: String = "snippet",
        subject: String = "Original subject",
        // Explicit so a test can give two rows the SAME timestamp. Two `Date()` calls
        // differ by microseconds, and `date` was the third component of the round-2
        // identity witness — so genuine copies of one message must be inserted with one
        // shared value, the way production stores them (both parsed from the same
        // RFC822 Date header). Round 3 withdrew that witness and Strategy 2 is back on
        // its cardinality guard, but the parameter stays load-bearing: reproducing
        // witness agreement is exactly what
        // `witnessAgreeingRowsWithDifferentBodiesResolveToNothing` has to do to show
        // the witness was not sufficient.
        date: Date = Date()
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: from,
            fromAddress: from,
            to: "user@example.com",
            date: date,
            snippet: snippet,
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.rfc822MessageId = rfc822MessageId
        header.observedUidValidity = observedUidValidity
        try db.write { try header.insert($0) }
        return header
    }

    private static func insertReplyDraft(
        _ db: DatabaseQueue,
        draftKey: String,
        replyToId: String?,
        stampProviderMessageId: String?,
        stampUidValidity: Int?,
        accountId: String = "acc1"
    ) throws -> Draft {
        var draft = Draft(
            id: draftKey,
            accountId: accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Re: Original subject",
            body: "the words the user actually typed",
            replyToId: replyToId,
            isForward: false,
            editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970
        )
        draft.replyToProviderMessageId = stampProviderMessageId
        draft.replyToUidValidity = stampUidValidity
        try db.write { try draft.insert($0) }
        return draft
    }

    private static func resolve(_ db: DatabaseQueue, _ draft: Draft) throws -> Draft.ReplyQuote? {
        try db.read { conn in
            try Draft.resolveReplyQuote(
                draftKey: draft.id, replyToId: draft.replyToId, isForward: draft.isForward,
                expectedProviderMessageId: draft.replyToProviderMessageId,
                expectedUidValidity: draft.replyToUidValidity,
                db: conn)
        }
    }

    // MARK: - The headline property

    @Test("A substituted PK yields no quote, never a foreign body")
    func substitutedPrimaryKeyYieldsNoQuoteNeverAForeignBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        // The user replied to <original@example.com>, which lived at UID 42 under
        // UIDVALIDITY 100. The server then re-numbered the mailbox and a resync put
        // a DIFFERENT correspondent's message at the very same UID 42.
        let impostorId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "impostor@domain.com",
            observedUidValidity: 200, from: "someone-else@domain.com",
            snippet: "impostor snippet")
        try TestDatabase.insertMessageBody(
            db, headerId: impostorId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:original@example.com", replyToId: impostorId,
            stampProviderMessageId: "42", stampUidValidity: 100)

        // NON-VACUITY: the hazard really was reachable — the foreign body IS sitting
        // at the exact key the pre-fix code fetched from.
        let planted = try db.read { conn in
            try MessageBody.fetchOne(conn, key: impostorId)?.htmlContent
        }
        #expect(planted?.contains(Self.foreignMarker) == true)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
        #expect(quote?.header.id != impostorId)
    }

    @Test("An ordinary reopen still quotes the message the user replied to")
    func ordinaryReopenStillQuotesTheGenuineTarget() throws {
        // The two-sided twin of the headline test: a guard that refuses everything
        // would pass that one and fail this one.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        let targetId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "original@example.com",
            observedUidValidity: 100)
        try TestDatabase.insertMessageBody(
            db, headerId: targetId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:original@example.com", replyToId: targetId,
            stampProviderMessageId: "42", stampUidValidity: 100)

        let quote = try Self.resolve(db, draft)

        #expect(quote?.header.id == targetId)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) == true)
    }

    @Test("After a folder move the quote follows the message, not the stale PK")
    func folderMoveStillQuotesTheMovedMessage() throws {
        // The address stamp must not over-refuse: an IMAP MOVE gives the SAME
        // message a new UID in a new mailbox, so the stamped address legitimately
        // stops matching and the account+RFC lookup is what recovers it.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let movedId = "acc1:Archive:77"
        try Self.insertHeader(
            db, messageId: "77", folderPath: "Archive",
            rfc822MessageId: "original@example.com", observedUidValidity: 900)
        try TestDatabase.insertMessageBody(
            db, headerId: movedId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        // The draft still names the pre-move address, which no longer exists.
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:original@example.com", replyToId: "acc1:INBOX:42",
            stampProviderMessageId: "42", stampUidValidity: 100)

        let quote = try Self.resolve(db, draft)

        #expect(quote?.header.id == movedId)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) == true)
    }

    // MARK: - Pre-v80 (legacy) rows: neither a permanent casualty nor a laundered pass

    @Test("A legacy draft with no address stamp still refuses an RFC-mismatched PK hit")
    func legacyDraftStillRefusesAnImpostorAtItsPrimaryKey() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        let impostorId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "impostor@domain.com",
            observedUidValidity: 200, from: "someone-else@domain.com")
        try TestDatabase.insertMessageBody(
            db, headerId: impostorId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        // nil stamp = every row written before v80 (no backfill, on purpose).
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:original@example.com", replyToId: impostorId,
            stampProviderMessageId: nil, stampUidValidity: nil)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
    }

    @Test("A legacy draft with no address stamp still quotes its genuine reply target")
    func legacyDraftStillQuotesItsGenuineTarget() throws {
        // The other half of the legacy rule: an unstamped row must not lose its
        // quote forever just because it predates v80.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        let targetId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "original@example.com",
            observedUidValidity: 100)
        try TestDatabase.insertMessageBody(
            db, headerId: targetId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:original@example.com", replyToId: targetId,
            stampProviderMessageId: nil, stampUidValidity: nil)

        let quote = try Self.resolve(db, draft)

        #expect(quote?.header.id == targetId)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) == true)
    }

    @Test("A stable-provider-id draft with no RFC baseline and no stamp still quotes its target")
    func stableProviderIdDraftWithNeitherBaselineStillResolves() throws {
        // Gmail/Graph: the draft key's stableId is the PROVIDER id, which yields no
        // RFC baseline, and a pre-v80 row has no stamp. Those ids are stable and
        // never reused, so there is no hazard here and refusing would be pure loss.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .gmail)
        try TestDatabase.insertFolder(db)

        let targetId = "acc1:INBOX:18c9abc"
        try Self.insertHeader(
            db, messageId: "18c9abc", rfc822MessageId: nil, observedUidValidity: nil)
        try TestDatabase.insertMessageBody(
            db, headerId: targetId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:18c9abc", replyToId: targetId,
            stampProviderMessageId: nil, stampUidValidity: nil)

        let quote = try Self.resolve(db, draft)

        #expect(quote?.header.id == targetId)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) == true)
    }

    // MARK: - AUDIT ROUND 1 / C-2 — silence from BOTH baselines is not identity

    /// 🚨 The disclosure this whole mechanism exists to prevent, in the one shape
    /// that used to slip through: an RFC-less IMAP message. Its draft key carries
    /// the bare UID (`MessageHeader.stableId` falls back to `messageId` when there
    /// is no RFC id), so `expectedReplyToRfc` recovers NO baseline; and the draft's
    /// epoch stamp is nil because the row's address was never proven. The old
    /// predicate accepted on `.unverifiable` + no RFC baseline, so the message that
    /// took over UID 42 supplied the attribution, the body and the attachments of
    /// the user's OUTGOING reply.
    ///
    /// The property asserted is the end state — no foreign content in the quote —
    /// not which column decided.
    @Test("An RFC-less IMAP reply target whose UID was taken over yields no quote, never the new occupant's body")
    func rfcLessTargetWithUnprovenEpochYieldsNoForeignQuote() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        // UID 42 now holds a DIFFERENT correspondent's message under a new epoch.
        let occupantId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: nil, observedUidValidity: 200,
            from: "someone-else@domain.com", snippet: "occupant snippet")
        try TestDatabase.insertMessageBody(
            db, headerId: occupantId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        // The draft the user is still composing: it names UID 42, and its epoch was
        // never proven (nil), which is the ordinary state after an optimistic move
        // or a delta-sync re-key.
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:42", replyToId: occupantId,
            stampProviderMessageId: "42", stampUidValidity: nil)

        // NON-VACUITY: the foreign body really is sitting at the exact key the
        // pre-fix resolver returned, so `nil` below is a refusal, not an empty DB.
        let planted = try db.read { conn in
            try MessageBody.fetchOne(conn, key: occupantId)?.htmlContent
        }
        #expect(planted?.contains(Self.foreignMarker) == true)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil,
                """
                a reply target was accepted with NOTHING proving it is the copy the user replied to — \
                no RFC baseline and no epoch on either side, only a matching bare UID. On a renumberable \
                id space that is an address match, not an identity.
                """)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true,
                "another correspondent's body would have been quoted into the user's outgoing reply")
    }

    /// The same hazard through the OTHER unproven cell: neither side carries an
    /// epoch at all. That pair used to read as `.confirmed` — two absences
    /// laundered into positive per-copy identity.
    @Test("An RFC-less IMAP reply target with no epoch on either side yields no quote")
    func rfcLessTargetWithNoEpochAnywhereYieldsNoQuote() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        let occupantId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: nil, observedUidValidity: nil,
            from: "someone-else@domain.com", snippet: "occupant snippet")
        try TestDatabase.insertMessageBody(
            db, headerId: occupantId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:42", replyToId: occupantId,
            stampProviderMessageId: "42", stampUidValidity: nil)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
    }

    /// The two-sided control for both tests above: an RFC-less IMAP target is NOT
    /// permanently unquotable. When the epoch IS proven on both sides the address
    /// baseline confirms the exact copy on its own, and the quote must land.
    @Test("An RFC-less IMAP reply target with a PROVEN epoch on both sides still quotes")
    func rfcLessTargetWithProvenEpochStillQuotes() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        let targetId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: nil, observedUidValidity: 100)
        try TestDatabase.insertMessageBody(
            db, headerId: targetId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:42", replyToId: targetId,
            stampProviderMessageId: "42", stampUidValidity: 100)

        let quote = try Self.resolve(db, draft)

        #expect(quote?.header.id == targetId,
                "a proven (UID, UIDVALIDITY) pair IS positive per-copy identity — refusing it is pure loss")
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) == true)
    }

    // MARK: - The account+RFC recovery must not itself resolve to an arbitrary row

    /// 🚨 AUDIT ROUND 1 / C-2. `(accountId, rfc822MessageId)` carries no uniqueness
    /// constraint, and Strategy 2 used a bare `fetchOne` — so with two matching rows
    /// SQLite's arbitrary choice decided which correspondent's body, attribution and
    /// attachments went into the outgoing reply.
    ///
    /// ⚠ RE-SCOPED (audit round 2), still GREEN and still load-bearing — and it
    /// survived round 3's revert UNCHANGED, which is the point of keeping this note.
    /// Round 1 made this pass via a cardinality guard (`count == 1`); round 2 swapped
    /// that for identity AGREEMENT on a `(fromAddress, subject, date)` witness; round 3
    /// withdrew the witness as unsound in both directions and restored the cardinality
    /// guard. This case refuses under ALL THREE predicates, so it pins a property the
    /// resolver must hold however the guard is spelled. The two rows here differ in
    /// `fromAddress` ("sender@example.com" vs "someone-else@domain.com"), so they are a
    /// genuine Message-ID COLLISION: two different messages under one identity, which
    /// is precisely what must fail closed.
    ///
    /// Its two siblings pin the rest of the space at the current tree state:
    /// `severalCopiesOfOneMessageFailTheReplyTargetClosed` covers rows that agree on
    /// everything a copy shares (the restored guard refuses those too — an accepted
    /// cost, not a proof of difference), and
    /// `witnessAgreeingRowsWithDifferentBodiesResolveToNothing` covers rows that agree
    /// on the whole round-2 witness while carrying different bodies, which is why that
    /// witness could not stand. The draft's own authored body is untouched either way.
    @Test("Two rows sharing one RFC identity yield no reply target, never an arbitrary one")
    func ambiguousRfcIdentityResolvesToNothing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let firstId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "collision@example.com",
            observedUidValidity: 100)
        try TestDatabase.insertMessageBody(
            db, headerId: firstId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let secondId = "acc1:Archive:77"
        try Self.insertHeader(
            db, messageId: "77", folderPath: "Archive",
            rfc822MessageId: "collision@example.com", observedUidValidity: 900,
            from: "someone-else@domain.com")
        try TestDatabase.insertMessageBody(
            db, headerId: secondId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        // Strategy 1 cannot answer: the PK the draft names no longer exists, which
        // is precisely when Strategy 2 runs.
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:collision@example.com", replyToId: "acc1:INBOX:999",
            stampProviderMessageId: nil, stampUidValidity: nil)

        // NON-VACUITY: BOTH rows really are there and really do share the identity,
        // so the refusal below is about ambiguity and not about an empty result.
        let matching = try db.read { conn in
            try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("rfc822MessageId") == "collision@example.com")
                .fetchCount(conn)
        }
        #expect(matching == 2)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil,
                """
                one of two indistinguishable rows was picked to supply the reply target. Which one is \
                SQLite's choice, so a colliding Message-ID silently substitutes another message's \
                attribution, body and attachments into the user's reply.
                """)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) != true)
    }

    /// 🚨 **AUDIT ROUND 3 — INVERTED. THIS WAS A BLESSING TEST.** It used to assert
    /// that two rows sharing an RFC identity and agreeing on `(fromAddress, subject,
    /// date)` DO resolve, on the reasoning that such rows are copies of one message
    /// and therefore interchangeable. Both fixtures carried the same
    /// `genuineMarker`, so an arbitrary representative was undetectable and the test
    /// could not have failed however wrong the choice was.
    ///
    /// The witness it blessed is wrong in BOTH directions. It omits everything the
    /// resolver consumes — body, attachments, `replyTo` — so two DIFFERENT messages
    /// sharing a Message-ID can satisfy it and the user forwards content they never
    /// selected (C3; see `witnessAgreeingRowsWithDifferentBodiesResolveToNothing`,
    /// which is this test's other half). And its `date` is INTERNALDATE, which
    /// RFC 3501 §6.4.7 makes a SHOULD-not-MUST to preserve across a COPY, so genuine
    /// copies can disagree on it. The resolver is back on the fail-closed
    /// cardinality guard.
    ///
    /// THE PROPERTY NOW PINNED, and it is a COST, stated rather than hidden: when a
    /// message is legitimately present in several folders, Strategy 2 refuses and
    /// the reply ships WITHOUT its quoted body and attribution. The user's authored
    /// text is untouched and the send still works. This is accepted — C3 says
    /// failing closed is always acceptable — and shipped `07a4bb703` was WORSE here
    /// (a bare `.fetchOne`, i.e. an arbitrary row), so this is not a regression to
    /// the release but an improvement the round-2 witness gave away.
    ///
    /// RED PROOF (recorded): against the witness resolver this fails at
    /// `quote == nil` — two agreeing copies resolve to a representative.
    @Test("Several copies of one message fail the reply-target resolution closed")
    func severalCopiesOfOneMessageFailTheReplyTargetClosed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // ONE message, two folder copies: identical sender, subject and timestamp,
        // differing only in the things a copy legitimately differs in — folder, UID,
        // headerId and observed epoch.
        let sharedDate = Date(timeIntervalSince1970: 1_760_000_000)
        let inboxId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "shared@example.com",
            observedUidValidity: 100, date: sharedDate)
        try TestDatabase.insertMessageBody(
            db, headerId: inboxId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let archiveId = "acc1:Archive:77"
        try Self.insertHeader(
            db, messageId: "77", folderPath: "Archive",
            rfc822MessageId: "shared@example.com", observedUidValidity: 900,
            date: sharedDate)
        try TestDatabase.insertMessageBody(
            db, headerId: archiveId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        // Strategy 1 cannot answer: the PK the draft names no longer exists, which is
        // precisely when Strategy 2 runs.
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:shared@example.com", replyToId: "acc1:INBOX:999",
            stampProviderMessageId: nil, stampUidValidity: nil)

        // NON-VACUITY: both copies really are present, so a resolution below is the
        // multi-row case being ADMITTED and not a single-row query trivially passing.
        let matching = try db.read { conn in
            try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("rfc822MessageId") == "shared@example.com")
                .fetchCount(conn)
        }
        #expect(matching == 2)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil,
                """
                a representative was chosen from several rows sharing one RFC identity. Which one \
                is SQLite's choice, and the rows are indistinguishable only on the fields the \
                witness happened to compare — not on the body or attachments this quote carries \
                into the user's outgoing mail.
                """)
        // The accepted cost, asserted so it cannot be lost silently: no quote at all,
        // rather than a quote from an unproven copy.
        #expect(quote?.bodyHTML == nil)
    }

    /// 🚨 AUDIT ROUND 3 / C3 — the defect the `(fromAddress, subject, date)` witness
    /// admitted, pinned as a SYSTEM PROPERTY rather than as the guard's shape.
    ///
    /// The witness compares exactly three header fields and omits every field the
    /// resolver actually consumes. Two DIFFERENT messages that collide on a
    /// Message-ID — a buggy sender, a list rewriter, an alias fan-out — and happen to
    /// share sender, subject and timestamp therefore AGREE on it, and
    /// `resolveReplyToHeader` hands back an arbitrary representative whose body and
    /// attachments `resolveReplyQuote` then loads into the user's outgoing reply or
    /// forward. Content the user never selected leaves the device.
    ///
    /// Note what this test does NOT assert: it does not check which row was picked,
    /// or that any particular field is compared. Either would inherit the witness's
    /// own spec error. It asserts the end state — nothing resolves, so nothing
    /// foreign can be carried.
    ///
    /// RED PROOF (recorded): against the witness resolver this fails at
    /// `quote == nil`, and the resolved body is one of the two markers.
    @Test("Rows agreeing on the identity witness but differing in body resolve to nothing")
    func witnessAgreeingRowsWithDifferentBodiesResolveToNothing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // Two rows that AGREE on sender, subject and timestamp — every field the
        // round-2 witness compared — and carry DIFFERENT bodies. Nothing in the
        // witness can tell them apart, which is the point.
        let sharedDate = Date(timeIntervalSince1970: 1_760_000_000)
        let firstId = "acc1:INBOX:42"
        try Self.insertHeader(
            db, messageId: "42", rfc822MessageId: "witness@example.com",
            observedUidValidity: 100, date: sharedDate)
        try TestDatabase.insertMessageBody(
            db, headerId: firstId, htmlContent: "<p>\(Self.genuineMarker)</p>")

        let secondId = "acc1:Archive:77"
        try Self.insertHeader(
            db, messageId: "77", folderPath: "Archive",
            rfc822MessageId: "witness@example.com", observedUidValidity: 900,
            date: sharedDate)
        try TestDatabase.insertMessageBody(
            db, headerId: secondId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        // Strategy 1 cannot answer: the PK the draft names no longer exists, which is
        // precisely when Strategy 2 runs.
        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:witness@example.com", replyToId: "acc1:INBOX:999",
            stampProviderMessageId: nil, stampUidValidity: nil)

        // NON-VACUITY: both rows really are present and really do share the identity,
        // so the refusal below is about ambiguity and not an empty candidate set.
        let matching = try db.read { conn in
            try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("rfc822MessageId") == "witness@example.com")
                .fetchCount(conn)
        }
        #expect(matching == 2)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil,
                """
                a reply target was resolved from two rows that are indistinguishable on sender, \
                subject and date but carry DIFFERENT bodies. Whichever was picked, the user's \
                outgoing mail can now quote and attach content from a message they never selected.
                """)
        // Neither body may reach the draft — including the "right-looking" one, since
        // nothing here proves which row the user meant.
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
        #expect(quote?.bodyHTML?.contains(Self.genuineMarker) != true)
    }

    @Test("A draft key with an empty stableId resolves to no reply target")
    func emptyStableIdInDraftKeyResolvesToNothing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db)

        // A header carrying an EMPTY rfc822MessageId — what an empty normalized
        // stableId would otherwise compare equal to.
        let unrelatedId = "acc1:INBOX:9"
        try Self.insertHeader(
            db, messageId: "9", rfc822MessageId: "", observedUidValidity: 300,
            from: "someone-else@domain.com")
        try TestDatabase.insertMessageBody(
            db, headerId: unrelatedId, htmlContent: "<p>\(Self.foreignMarker)</p>")

        let draft = try Self.insertReplyDraft(
            db, draftKey: "reply:acc1:", replyToId: nil,
            stampProviderMessageId: nil, stampUidValidity: nil)

        let quote = try Self.resolve(db, draft)

        #expect(quote == nil)
        #expect(quote?.bodyHTML?.contains(Self.foreignMarker) != true)
    }

    // MARK: - The outbound-quote seam

    @Test("An unconfirmed reply target contributes no snippet to the outbound quote")
    func unconfirmedTargetContributesNoSnippetToTheOutboundQuote() {
        // A snippet is a cached preview of whatever row the PK named, so it bypasses
        // the identity guard entirely. No confirmed body ⇒ no quote at all.
        #expect(ComposeDraftGuards.outboundQuoteBody(
            confirmedBodyHTML: nil,
            capturedSnippet: Self.foreignMarker) == nil)
    }

    @Test("A confirmed body does populate the outbound quote")
    func confirmedBodyDoesPopulateTheOutboundQuote() {
        #expect(ComposeDraftGuards.outboundQuoteBody(
            confirmedBodyHTML: "<p>\(Self.genuineMarker)</p>",
            capturedSnippet: "unused") == "<p>\(Self.genuineMarker)</p>")
    }
}

@Suite("Draft reply-target address migration (v80)")
struct DraftReplyTargetAddressMigrationTests {

    @Test("v80 adds nullable reply-target address columns without backfilling existing drafts")
    func v80AddsNullableReplyTargetAddressWithoutBackfill() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var beforeMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &beforeMigrator)
        try beforeMigrator.migrate(db, upTo: "v79_addDraftLastTouchedSeq")
        try TestDatabase.insertAccount(db)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO draft
                    (id, accountId, toJSON, ccJSON, bccJSON, subject, body,
                     replyToId, isForward, editHistoryJSON, createdAt, updatedAt)
                VALUES ('reply:acc1:original@example.com', 'acc1', '[]', '[]', '[]',
                        'Re: Original subject', 'authored body',
                        'acc1:INBOX:42', 0, NULL, 1, 2)
                """)
        }

        var afterMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &afterMigrator)
        try afterMigrator.migrate(db, upTo: "v80_addDraftReplyTargetAddress")

        let columns = try db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(draft)") }
        let providerColumn = try #require(
            columns.first { ($0["name"] as String) == "replyToProviderMessageId" })
        let epochColumn = try #require(
            columns.first { ($0["name"] as String) == "replyToUidValidity" })
        #expect((providerColumn["notnull"] as Int) == 0)
        #expect((epochColumn["notnull"] as Int) == 0)

        // NON-VACUITY: the pre-v80 row really did survive the migration, so the two
        // nil assertions below are about a row that exists, not about no rows.
        let surviving = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM draft WHERE id = ?",
                             arguments: ["reply:acc1:original@example.com"])
        }
        #expect(surviving == 1)

        // NO BACKFILL, deliberately: adopting whatever row sits at `replyToId` today
        // would bless an already-substituted impostor as "the expected identity".
        let stampedProviderId: String? = try db.read {
            try String.fetchOne($0, sql: """
                SELECT replyToProviderMessageId FROM draft WHERE id = ?
                """, arguments: ["reply:acc1:original@example.com"])
        }
        #expect(stampedProviderId == nil)
        let stampedEpoch: Int? = try db.read {
            try Int.fetchOne($0, sql: """
                SELECT replyToUidValidity FROM draft WHERE id = ?
                """, arguments: ["reply:acc1:original@example.com"])
        }
        #expect(stampedEpoch == nil)
    }
}
