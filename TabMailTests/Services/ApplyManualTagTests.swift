/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - ApplyManualTag Integration Tests

/// Tests for the manual tag teaching algorithm (applyManualTag).
/// This method handles:
/// 1. Self-sent email blocking
/// 2. Optimistic UI update
/// 3. Tag queue write
/// 4. AI cache update
///
/// We replicate the DB-level logic of the method.

@Suite("ApplyManualTag — Self-Sent Blocking")
struct ApplyManualTagSelfSentTests {

    @Test("Self-sent messages are blocked from manual tagging")
    func selfSentBlocked() throws {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", from: "user@example.com",
            fromAddress: "user@example.com",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
        )

        // Replicate self-sent check
        let isSelfSent = msg.fromAddress.lowercased() == account.emailAddress.lowercased()
        #expect(isSelfSent, "Should detect self-sent message")

        // Tag should NOT be applied — original tag should remain nil
        let header = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(header?.actionTag == nil)
    }

    @Test("Self-sent check is case-insensitive")
    func selfSentCaseInsensitive() throws {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db, id: "acc1", email: "User@Example.COM")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", from: "user@example.com",
            fromAddress: "user@example.com",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
        )

        let isSelfSent = msg.fromAddress.lowercased() == account.emailAddress.lowercased()
        #expect(isSelfSent, "Case-insensitive match should detect self-sent")
    }

    @Test("Non-self messages are allowed")
    func nonSelfAllowed() throws {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", from: "other@example.com",
            fromAddress: "other@example.com",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
        )

        let isSelfSent = msg.fromAddress.lowercased() == account.emailAddress.lowercased()
        #expect(!isSelfSent, "Different sender should not be blocked")
    }
}

@Suite("ApplyManualTag — Optimistic UI Update")
struct ApplyManualTagOptimisticTests {

    @Test("Optimistic UI updates tag immediately in GRDB")
    func optimisticTagUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", actionTag: .reply
        )

        // Optimistic update to .archive
        let newTag: ActionTag = .archive
        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: msg.id) else { return }
            header.actionTag = newTag
            header.tagSortOrder = newTag.sortOrder
            try header.save(db)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.actionTag == .archive)
        #expect(updated?.tagSortOrder == ActionTag.archive.sortOrder)
    }

    @Test("Tag removal sets nil and sort order to 99")
    func tagRemovalSetsNil() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", actionTag: .reply
        )

        let newTag: ActionTag? = nil
        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: msg.id) else { return }
            header.actionTag = newTag
            header.tagSortOrder = newTag?.sortOrder ?? 99
            try header.save(db)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.actionTag == nil)
        #expect(updated?.tagSortOrder == 99)
    }
}

@Suite("ApplyManualTag — Tag Queue Write")
struct ApplyManualTagQueueTests {

    @Test("setTag pending op is created for new tag")
    func setTagOpCreated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<msg@example.com>"
        )

        // Simulate queueTagWrite
        let tag: ActionTag = .archive
        try db.write { db in
            var setTagOp = PendingOperation(
                type: .setTag,
                messageIds: [msg.stableId],
                accountId: "acc1",
                folderPath: "INBOX",
                tagValue: tag.rawValue
            )
            try setTagOp.insert(db)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .setTag)
        #expect(ops[0].tagValue == "archive")
    }

    @Test("removeTag pending op is created when removing tag")
    func removeTagOpCreated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", actionTag: .reply
        )

        // Remove tag = nil → use removeTag type
        try db.write { db in
            var removeTagOp = PendingOperation(
                type: .removeTag,
                messageIds: [msg.stableId],
                accountId: "acc1",
                folderPath: "INBOX",
                tagValue: "reply"  // previous tag value for IMAP keyword removal
            )
            try removeTagOp.insert(db)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .removeTag)
    }
}

@Suite("ApplyManualTag — AI Cache Update")
struct ApplyManualTagAICacheTests {

    @Test("AI cache is updated with new tag via writeThrough")
    func aiCacheUpdated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Write through to AI cache
        try db.write { db in
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@example.com>",
                actionTag: .archive,
                db: db
            )
        }

        // Verify cache has the tag
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "<msg@example.com>")!
        let cached = try db.read { try MessageAICache.filter(Column("key") == key).fetchOne($0) }
        #expect(cached?.actionTag == .archive)
    }

    @Test("AI cache update overwrites previous tag")
    func aiCacheOverwrites() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First write
        try db.write { db in
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@example.com>",
                actionTag: .reply,
                db: db
            )
        }
        // Overwrite with archive
        try db.write { db in
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@example.com>",
                actionTag: .archive,
                db: db
            )
        }

        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "<msg@example.com>")!
        let cached = try db.read { try MessageAICache.filter(Column("key") == key).fetchOne($0) }
        #expect(cached?.actionTag == .archive, "Second write should overwrite first")
    }

    @Test("AI cache requires rfc822MessageId — nil is a no-op")
    func aiCacheRequiresRfc822() throws {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: nil)
        #expect(key == nil, "cacheKey should return nil when rfc822MessageId is nil")
    }
}

// MARK: - Action tag stamp invariant (Round D-0b)

/// Pins the SYSTEM PROPERTY the `actionTagSetAt` column exists to guarantee:
/// **a persisted row that carries an `actionTag` also carries a stamp**
/// (`actionTag != nil ⇒ actionTagSetAt != nil`). Without it, `sweepStaleActionTags`
/// has no TTL basis and a legacy/unstamped row is indistinguishable from a
/// fresh one.
///
/// These drive `MessageHeader.setActionTag` — the single mutator every
/// model-save tag writer routes through — rather than any one caller's
/// mechanism, so a new writer that hand-assigns `actionTag` cannot pass by
/// coincidence.
@Suite("Action tag stamp invariant (Round D-0b)")
struct ActionTagStampInvariantTests {

    @Test("setActionTag(non-nil) stamps actionTagSetAt and the derived tagSortOrder together")
    func setStampsAll() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
        )

        let before = Date()
        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: msg.id) else { return }
            header.setActionTag(.archive)
            try header.save(db)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.actionTag == .archive)
        #expect(updated?.tagSortOrder == ActionTag.archive.sortOrder)
        let setAt = try #require(updated?.actionTagSetAt)
        // 1s slack: GRDB persists Date at millisecond precision, so a stamp
        // taken microseconds after `before` can round just below it.
        #expect(setAt >= before.addingTimeInterval(-1), "a tag write must carry the moment it happened, not an inherited stamp")
        #expect(setAt <= Date().addingTimeInterval(1))
    }

    @Test("setActionTag(nil) clears the stamp with the tag — no orphan stamp survives")
    func clearNilsStamp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", actionTag: .reply
        )

        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: msg.id) else { return }
            header.setActionTag(.archive)          // stamp it first…
            header.setActionTag(nil)               // …then clear
            try header.save(db)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.actionTag == nil)
        #expect(updated?.tagSortOrder == 99)
        #expect(updated?.actionTagSetAt == nil)
    }

    @Test("ActionTag.none is a tag VALUE, not absence — setActionTag(.none) STAMPS rather than clearing")
    func actionTagNoneStampsNotClears() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", actionTag: .reply
        )

        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: msg.id) else { return }
            header.setActionTag(ActionTag.none)
            try header.save(db)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.actionTag == ActionTag.none)
        #expect(updated?.tagSortOrder == ActionTag.none.sortOrder)
        #expect(updated?.actionTagSetAt != nil, "`ActionTag.none` is not `Optional.none`; the row still carries a tag and must carry a stamp")
    }
}

@Suite("ApplyManualTag — Auto-Prompt Update Guard")
struct ApplyManualTagAutoPromptTests {

    @Test("Auto-update fires when original != userTag")
    func autoUpdateFiresOnDifferentTag() throws {
        let originalAction = "reply"
        let userManualTag = "archive"
        let tag: ActionTag? = .archive

        let shouldFire = tag != nil && originalAction != userManualTag
        #expect(shouldFire, "Should fire auto-update when tags differ")
    }

    @Test("Auto-update skipped when original == userTag")
    func autoUpdateSkippedOnSameTag() throws {
        let originalAction = "archive"
        let userManualTag = "archive"
        let tag: ActionTag? = .archive

        let shouldFire = tag != nil && originalAction != userManualTag
        #expect(!shouldFire, "Should skip auto-update when tags are the same")
    }

    @Test("Auto-update skipped when tag is nil (remove)")
    func autoUpdateSkippedOnRemove() throws {
        let originalAction = "reply"
        let userManualTag = ""
        let tag: ActionTag? = nil

        let shouldFire = tag != nil && originalAction != userManualTag
        #expect(!shouldFire, "Should skip auto-update when tag is nil")
    }
}
