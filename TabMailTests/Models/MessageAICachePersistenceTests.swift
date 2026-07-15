/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageAICache Persistence")
struct MessageAICachePersistenceTests {

    // MARK: - Basic GRDB persistence

    @Test("Insert and fetch by key")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        var cache = MessageAICache(key: "acc1:INBOX:<msg@example.com>", rfc822MessageId: "<msg@example.com>")
        cache.summaryBlurb = "Test summary"
        cache.actionTag = .archive

        try db.write { try cache.insert($0) }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@example.com>") }
        #expect(fetched != nil)
        #expect(fetched?.key == "acc1:INBOX:<msg@example.com>")
        #expect(fetched?.rfc822MessageId == "<msg@example.com>")
        #expect(fetched?.summaryBlurb == "Test summary")
        #expect(fetched?.actionTag == .archive)
    }

    @Test("Update existing cache entry")
    func updateEntry() throws {
        let db = try TestDatabase.make()
        var cache = MessageAICache(key: "k1")
        cache.summaryBlurb = "Original"
        try db.write { try cache.insert($0) }

        cache.summaryBlurb = "Updated"
        cache.actionTag = .reply
        try db.write { try cache.update($0) }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "k1") }
        #expect(fetched?.summaryBlurb == "Updated")
        #expect(fetched?.actionTag == .reply)
    }

    @Test("Delete cache entry")
    func deleteEntry() throws {
        let db = try TestDatabase.make()
        let cache = MessageAICache(key: "k1")
        try db.write { try cache.insert($0) }

        _ = try db.write { try cache.delete($0) }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "k1") }
        #expect(fetched == nil)
    }

    @Test("Save performs upsert")
    func saveUpsert() throws {
        let db = try TestDatabase.make()
        var cache = MessageAICache(key: "k1")
        cache.summaryBlurb = "First"
        try db.write { try cache.save($0) }

        cache.summaryBlurb = "Second"
        try db.write { try cache.save($0) }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 1)
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "k1") }
        #expect(fetched?.summaryBlurb == "Second")
    }

    @Test("Fetch all returns multiple entries")
    func fetchAll() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache(key: "k1").insert($0)
            try MessageAICache(key: "k2").insert($0)
            try MessageAICache(key: "k3").insert($0)
        }

        let all = try db.read { try MessageAICache.fetchAll($0) }
        #expect(all.count == 3)
    }

    @Test("All optional fields persist as nil")
    func allNilFields() throws {
        let db = try TestDatabase.make()
        let cache = MessageAICache(key: "k1")
        try db.write { try cache.insert($0) }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "k1") }!
        #expect(fetched.rfc822MessageId == nil)
        #expect(fetched.summaryBlurb == nil)
        #expect(fetched.summaryTodos == nil)
        #expect(fetched.reminderDate == nil)
        #expect(fetched.reminderTime == nil)
        #expect(fetched.reminderContent == nil)
        #expect(fetched.actionTag == nil)
        #expect(fetched.cachedReply == nil)
        #expect(fetched.replyGeneratedAt == nil)
    }

    @Test("All fields persist round-trip")
    func allFieldsRoundTrip() throws {
        let db = try TestDatabase.make()
        let now = Date()
        var cache = MessageAICache(key: "k1", rfc822MessageId: "<msg@test.com>")
        cache.summaryBlurb = "Blurb"
        cache.summaryTodos = "Todo 1"
        cache.reminderDate = "2026-03-15"
        cache.reminderTime = "10:00"
        cache.reminderContent = "Follow up"
        cache.actionTag = .delete
        cache.cachedReply = "Thanks for the update"
        cache.replyGeneratedAt = now
        cache.updatedAt = now
        try db.write { try cache.insert($0) }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "k1") }!
        #expect(fetched.summaryBlurb == "Blurb")
        #expect(fetched.summaryTodos == "Todo 1")
        #expect(fetched.reminderDate == "2026-03-15")
        #expect(fetched.reminderTime == "10:00")
        #expect(fetched.reminderContent == "Follow up")
        #expect(fetched.actionTag == .delete)
        #expect(fetched.cachedReply == "Thanks for the update")
        #expect(fetched.replyGeneratedAt != nil)
    }

    // MARK: - id computed property

    @Test("id returns key")
    func idReturnsKey() {
        let cache = MessageAICache(key: "acc1:Sent:<id@mail.com>")
        #expect(cache.id == "acc1:Sent:<id@mail.com>")
    }

    // MARK: - databaseTableName

    @Test("databaseTableName is messageAICache")
    func tableName() {
        #expect(MessageAICache.databaseTableName == "messageAICache")
    }

    // MARK: - writeThrough

    @Test("writeThrough creates new entry when none exists")
    func writeThroughNew() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "New blurb",
                actionTag: .archive,
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@test.com>")
        }
        #expect(fetched != nil)
        #expect(fetched?.summaryBlurb == "New blurb")
        #expect(fetched?.actionTag == .archive)
        #expect(fetched?.rfc822MessageId == "<msg@test.com>")
    }

    @Test("writeThrough updates existing entry preserving unset fields")
    func writeThroughPreserves() throws {
        let db = try TestDatabase.make()

        // First write: summary + action
        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "Original blurb",
                actionTag: .reply,
                db: $0
            )
        }

        // Second write: only cachedReply — should preserve summaryBlurb and actionTag
        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                cachedReply: "Here is a reply",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@test.com>")
        }
        #expect(fetched?.summaryBlurb == "Original blurb")
        #expect(fetched?.actionTag == .reply)
        #expect(fetched?.cachedReply == "Here is a reply")
    }

    @Test("writeThrough overwrites fields when provided")
    func writeThroughOverwrites() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "First",
                db: $0
            )
        }

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "Second",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@test.com>")
        }
        #expect(fetched?.summaryBlurb == "Second")
    }

    @Test("writeThrough is no-op when rfc822MessageId is nil")
    func writeThroughNilMessageId() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: nil,
                summaryBlurb: "Should not be saved",
                db: $0
            )
        }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 0)
    }

    @Test("writeThrough is no-op when rfc822MessageId is empty")
    func writeThroughEmptyMessageId() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "",
                summaryBlurb: "Should not be saved",
                db: $0
            )
        }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 0)
    }

    @Test("writeThrough sets all summary fields")
    func writeThroughAllSummaryFields() throws {
        let db = try TestDatabase.make()
        let now = Date()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "Meeting notes",
                summaryTodos: "- Review slides\n- Send feedback",
                reminderDate: "2026-03-20",
                reminderTime: "14:00",
                reminderContent: "Review meeting slides",
                actionTag: nil,
                cachedReply: "Will review by Friday",
                replyGeneratedAt: now,
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@test.com>")
        }!
        #expect(fetched.summaryBlurb == "Meeting notes")
        #expect(fetched.summaryTodos == "- Review slides\n- Send feedback")
        #expect(fetched.reminderDate == "2026-03-20")
        #expect(fetched.reminderTime == "14:00")
        #expect(fetched.reminderContent == "Review meeting slides")
        #expect(fetched.actionTag == nil)
        #expect(fetched.cachedReply == "Will review by Friday")
        #expect(fetched.replyGeneratedAt != nil)
    }

    // MARK: - restoreIfCached

    @Test("restoreIfCached restores summary into header with no existing summary")
    func restoreIfCachedSummary() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Pre-populate cache
        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "Cached blurb",
                summaryTodos: "Cached todos",
                reminderDate: "2026-04-01",
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.summaryBlurb == "Cached blurb")
        #expect(header.summaryTodos == "Cached todos")
        #expect(header.reminderDate == "2026-04-01")
    }

    @Test("restoreIfCached does not overwrite existing summary")
    func restoreIfCachedPreservesExistingSummary() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                summaryBlurb: "Cached blurb",
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )
        header.summaryBlurb = "Existing blurb"

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.summaryBlurb == "Existing blurb")
    }

    @Test("restoreIfCached restores actionTag when header has none")
    func restoreIfCachedActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                actionTag: .archive,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.actionTag == .archive)
        #expect(header.tagSortOrder == ActionTag.archive.sortOrder)
    }

    @Test("restoreIfCached does not overwrite existing actionTag from server")
    func restoreIfCachedPreservesServerActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                actionTag: .archive,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>",
            actionTag: .delete
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.actionTag == .delete)
    }

    @Test("restoreIfCached applies ReplyDetect: reply becomes none when already replied")
    func restoreIfCachedReplyDetect() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                actionTag: .reply,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )
        header.isReplied = true

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.actionTag == ActionTag.none)
        #expect(header.tagSortOrder == ActionTag.none.sortOrder)
    }

    @Test("restoreIfCached restores cachedReply")
    func restoreIfCachedReply() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg@test.com>",
                cachedReply: "Cached reply text",
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.cachedReply == "Cached reply text")
    }

    @Test("restoreIfCached is no-op when no cache entry exists")
    func restoreIfCachedNoEntry() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.summaryBlurb == nil)
        #expect(header.actionTag == nil)
        #expect(header.cachedReply == nil)
    }

    @Test("restoreIfCached is no-op when rfc822MessageId is nil")
    func restoreIfCachedNilMessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: nil
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.summaryBlurb == nil)
        #expect(header.actionTag == nil)
    }

    @Test("restoreIfCached does not restore empty cached reply")
    func restoreIfCachedEmptyReply() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Directly insert cache with empty cachedReply
        var cache = MessageAICache(key: "acc1:INBOX:<msg@test.com>", rfc822MessageId: "<msg@test.com>")
        cache.cachedReply = ""
        try db.write { try cache.insert($0) }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        // Empty string should NOT be restored
        #expect(header.cachedReply == nil)
    }

    @Test("restoreIfCached does not restore empty summary blurb")
    func restoreIfCachedEmptyBlurb() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var cache = MessageAICache(key: "acc1:INBOX:<msg@test.com>", rfc822MessageId: "<msg@test.com>")
        cache.summaryBlurb = ""
        try db.write { try cache.insert($0) }

        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            rfc822MessageId: "<msg@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: $0
            )
        }

        #expect(header.summaryBlurb == nil)
    }

    // MARK: - Filter by column

    @Test("Filter by rfc822MessageId column")
    func filterByRfc822MessageId() throws {
        let db = try TestDatabase.make()
        try db.write {
            let c1 = MessageAICache(key: "k1", rfc822MessageId: "<a@test.com>")
            try c1.insert($0)
            let c2 = MessageAICache(key: "k2", rfc822MessageId: "<b@test.com>")
            try c2.insert($0)
            let c3 = MessageAICache(key: "k3", rfc822MessageId: "<a@test.com>")
            try c3.insert($0)
        }

        let matches = try db.read {
            try MessageAICache.filter(Column("rfc822MessageId") == "<a@test.com>").fetchAll($0)
        }
        #expect(matches.count == 2)
    }

    // MARK: - cacheKey with special characters

    @Test("cacheKey with folder path containing special characters")
    func cacheKeySpecialChars() {
        let key = MessageAICache.cacheKey(
            accountId: "acc1",
            folderPath: "INBOX/Sub Folder/Special",
            rfc822MessageId: "<msg+special@example.com>"
        )
        #expect(key == "acc1:INBOX/Sub Folder/Special:<msg+special@example.com>")
    }
}
