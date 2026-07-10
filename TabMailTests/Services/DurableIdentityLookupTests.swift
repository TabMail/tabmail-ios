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

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(db: db, accountId: "acc1", messageId: "111", rfc822MessageId: nil)
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
                db: db, accountId: "acc1", messageId: "111", rfc822MessageId: "rfc-abc@example.com"
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
            try DurableIdentityLookup.find(db: db, accountId: "acc1", messageId: "111", rfc822MessageId: nil)
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
            try DurableIdentityLookup.find(db: db, accountId: "acc1", messageId: "111", rfc822MessageId: "")
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
                db: db, accountId: "acc1", messageId: "does-not-exist", rfc822MessageId: nil
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
            try DurableIdentityLookup.find(db: db, accountId: "acc1", messageId: "shared-id", rfc822MessageId: nil)
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

        let ref = try pool.read { db in
            try DurableIdentityLookup.find(db: db, accountId: "acc1", messageId: "42", rfc822MessageId: nil)
        }
        #expect(ref?.id == header.id)
        #expect(ref?.folderId == header.folderId)
        #expect(ref?.folderPath == "Archive")
        #expect(ref?.isInInbox == false)
        #expect(ref?.rfc822MessageId == "r@example.com")
    }
}
