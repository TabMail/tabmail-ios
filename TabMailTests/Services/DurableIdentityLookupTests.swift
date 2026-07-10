/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Unit coverage for the shared `DurableIdentityLookup` helper
/// (PLAN_INBOX_UNIFIED_READ.md §2.1a/§4.4 item 1) — the merge's dedup
/// identity, extracted so the NSE merge (`NSEDataBridge.verifyDurable` /
/// `detectStaleByMoveRows` / phase 1 / phase 2) and the upcoming unified
/// inbox reader resolve durable headers identically. Runs against a real
/// temp-file `DatabasePool` migrated via `AppDatabase(dbPool:)` — the helper
/// takes `db` directly, so unlike the VM-level pinning suites there's no need
/// to swap `AppDatabase.shared`.
@Suite("DurableIdentityLookup")
struct DurableIdentityLookupTests {

    // MARK: - Harness

    private func makeTestPool() throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        _ = try AppDatabase(dbPool: pool) // runs schema migrations only (no startup resets)
        try pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        return (pool, dir)
    }

    private func makeHeader(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        rfc822MessageId: String? = nil,
        isInInbox: Bool = true
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: isInInbox
        )
        h.rfc822MessageId = rfc822MessageId
        return h
    }

    // MARK: - (a) primary hit

    @Test("primary (accountId, messageId) hit")
    func primaryHit() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = makeHeader(messageId: "111")
        try pool.write { db in try header.insert(db) }

        // Same folderPath as the durable row — exercises the new step-1
        // exact-folder match, which subsumes the old "primary" behavior.
        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "111", rfc822MessageId: nil
            )
        }
        #expect(ref?.id == header.id)
    }

    // MARK: - (b) rfc822 fallback hit (UID remap)

    @Test("rfc822 fallback hit when primary lookup misses (simulated IMAP UID remap)")
    func rfc822FallbackHitOnUidRemap() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Durable row was written under the OLD UID (messageId "999") but carries
        // the stable rfc822MessageId. A later lookup arrives with a NEW UID
        // ("111", post-MOVE remap) and must find it via the rfc822 fallback.
        let header = makeHeader(messageId: "999", rfc822MessageId: "rfc-abc@example.com")
        try pool.write { db in try header.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "111",
                rfc822MessageId: "rfc-abc@example.com"
            )
        }
        #expect(ref?.id == header.id)
    }

    // MARK: - (c) fallback NOT taken when rfc822 nil

    @Test("fallback is NOT taken when rfc822MessageId is nil")
    func fallbackNotTakenWhenRfc822Nil() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A durable row exists under a different messageId; without an rfc822 to
        // probe with, the lookup must NOT fall back to it.
        let header = makeHeader(messageId: "999", rfc822MessageId: "rfc-abc@example.com")
        try pool.write { db in try header.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "111", rfc822MessageId: nil
            )
        }
        #expect(ref == nil)
    }

    // MARK: - (d) fallback NOT taken when rfc822 empty string

    @Test("fallback is NOT taken when rfc822MessageId is an empty string")
    func fallbackNotTakenWhenRfc822Empty() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = makeHeader(messageId: "999", rfc822MessageId: "rfc-abc@example.com")
        try pool.write { db in try header.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "111", rfc822MessageId: ""
            )
        }
        #expect(ref == nil)
    }

    // MARK: - (e) absent identity

    @Test("absent identity returns nil")
    func absentIdentityReturnsNil() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "does-not-exist", rfc822MessageId: nil
            )
        }
        #expect(ref == nil)
    }

    // MARK: - (f) account scoping

    @Test("account scoping — same messageId on another account does not match")
    func accountScopingExcludesOtherAccounts() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = makeHeader(accountId: "acc2", messageId: "shared-id")
        try pool.write { db in try header.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "shared-id", rfc822MessageId: nil
            )
        }
        #expect(ref == nil)
    }

    // MARK: - (g) returned fields correct

    @Test("returned fields (folderId/folderPath/isInInbox/rfc822MessageId) are correct")
    func returnedFieldsCorrect() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = makeHeader(
            accountId: "acc1", folderPath: "Archive", messageId: "42",
            rfc822MessageId: "r@example.com", isInInbox: false
        )
        try pool.write { db in try header.insert(db) }

        // Matching folderPath — exercises the step-1 exact-folder match.
        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "Archive", messageId: "42", rfc822MessageId: nil
            )
        }
        #expect(ref?.id == header.id)
        #expect(ref?.folderId == header.folderId)
        #expect(ref?.folderPath == "Archive")
        #expect(ref?.isInInbox == false)
        #expect(ref?.rfc822MessageId == "r@example.com")
    }

    // MARK: - (h/e) G3 audit: exact-folder-first precedence

    @Test("exact-folder match takes precedence over a folder-blind hit — same (accountId, messageId) in two folders resolves to the QUERIED folder's row")
    func exactFolderPrecedence() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Same accountId + messageId ("42"), two different folders — a
        // legitimate per-folder IMAP UID collision (not a move).
        let inboxHeader = makeHeader(folderPath: "INBOX", messageId: "42")
        let archiveHeader = makeHeader(folderPath: "Archive", messageId: "42")
        try pool.write { db in
            try inboxHeader.insert(db)
            try archiveHeader.insert(db)
        }

        let refInbox = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "42", rfc822MessageId: nil
            )
        }
        #expect(refInbox?.id == inboxHeader.id)
        #expect(refInbox?.folderPath == "INBOX")

        let refArchive = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "Archive", messageId: "42", rfc822MessageId: nil
            )
        }
        #expect(refArchive?.id == archiveHeader.id)
        #expect(refArchive?.folderPath == "Archive")
    }

    // MARK: - (h/f) G3 audit: cross-folder UID collision, differing rfc822 → rejected

    @Test("cross-folder UID collision with DIFFERING non-nil rfc822MessageId on both sides is rejected — falls through to the rfc822 step, which also misses, → nil")
    func crossFolderCollisionDifferingRfc822Rejected() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A DIFFERENT message living in Archive that happens to share the
        // UID ("88") the caller is probing for in INBOX.
        let archived = makeHeader(folderPath: "Archive", messageId: "88", rfc822MessageId: "rfc-real@example.com")
        try pool.write { db in try archived.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "88",
                rfc822MessageId: "rfc-staged@example.com"
            )
        }
        #expect(ref == nil, "folder-blind false match was not rejected despite disagreeing non-nil rfc822 identities")
    }

    // MARK: - (h/g) G3 audit: cross-folder UID collision, candidate rfc822 nil → retained

    @Test("cross-folder UID collision where the durable candidate's rfc822MessageId is nil → folder-blind match RETAINED (conservative: can't prove a difference)")
    func crossFolderCollisionCandidateRfc822NilRetainsMatch() throws {
        let (pool, dir) = try makeTestPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archived = makeHeader(folderPath: "Archive", messageId: "77", rfc822MessageId: nil)
        try pool.write { db in try archived.insert(db) }

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(
                db: db, accountId: "acc1", folderPath: "INBOX", messageId: "77",
                rfc822MessageId: "rfc-staged@example.com"
            )
        }
        #expect(ref?.id == archived.id, "folder-blind match with no evidence of a difference should be retained")
    }

    // MARK: - (i) `isSameLogicalMessage` — in-memory comparator truth table
    //
    // G3 in-memory-comparator hardening (DECISIONS.md ADR-IOS-055 audit round
    // 3): `isSameLogicalMessage` is the pure IN-MEMORY counterpart of `find`'s
    // step-2 rejection above, shared by `InboxListComposer.isDuplicateIdentity`
    // and `InboxViewModel.insertStagedRows`' inline dedup check. No DB
    // involved — every case below is a direct call.

    @Test("isSameLogicalMessage: different accountId → false")
    func sameLogicalMessageDifferentAccountIsFalse() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "1", rfc822MessageId: "<a@example.com>",
            candidateAccountId: "acc2", candidateMessageId: "1", candidateRfc822MessageId: "<a@example.com>"
        ) == false)
    }

    @Test("isSameLogicalMessage: both rfc822 known and AGREE, DIFFERING messageId → true (UID-remap duplicate)")
    func sameLogicalMessageRfc822AgreeDifferingMessageIdIsTrue() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: "<a@example.com>",
            candidateAccountId: "acc1", candidateMessageId: "999", candidateRfc822MessageId: "<a@example.com>"
        ) == true)
    }

    @Test("isSameLogicalMessage: both rfc822 known and AGREE, EQUAL messageId → true (same-folder redelivery / Gmail dual-label)")
    func sameLogicalMessageRfc822AgreeSameMessageIdIsTrue() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: "<a@example.com>",
            candidateAccountId: "acc1", candidateMessageId: "111", candidateRfc822MessageId: "<a@example.com>"
        ) == true)
    }

    @Test("isSameLogicalMessage: both rfc822 known and DISAGREE, equal messageId → false — the ONLY behavior change vs. the old bare-messageId comparator")
    func sameLogicalMessageRfc822DisagreeSameMessageIdIsFalse() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: "<a@example.com>",
            candidateAccountId: "acc1", candidateMessageId: "111", candidateRfc822MessageId: "<b@example.com>"
        ) == false)
    }

    @Test("isSameLogicalMessage: rfc822 unknown on one side, equal messageId → true (conservative default, unchanged)")
    func sameLogicalMessageOneSideRfc822UnknownSameMessageIdIsTrue() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: nil,
            candidateAccountId: "acc1", candidateMessageId: "111", candidateRfc822MessageId: "<a@example.com>"
        ) == true)
        // Empty string is "unknown" too, same as nil.
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: "<a@example.com>",
            candidateAccountId: "acc1", candidateMessageId: "111", candidateRfc822MessageId: ""
        ) == true)
    }

    @Test("isSameLogicalMessage: rfc822 unknown on both sides, DIFFERING messageId → false")
    func sameLogicalMessageBothRfc822UnknownDifferingMessageIdIsFalse() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "111", rfc822MessageId: nil,
            candidateAccountId: "acc1", candidateMessageId: "222", candidateRfc822MessageId: nil
        ) == false)
    }

    @Test("isSameLogicalMessage: empty messageId never matches, even against an equally-empty candidate messageId (mirrors the old `!row.messageId.isEmpty` guard)")
    func sameLogicalMessageEmptyMessageIdNeverMatches() {
        #expect(DurableIdentityLookup.isSameLogicalMessage(
            accountId: "acc1", messageId: "", rfc822MessageId: nil,
            candidateAccountId: "acc1", candidateMessageId: "", candidateRfc822MessageId: nil
        ) == false)
    }
}
