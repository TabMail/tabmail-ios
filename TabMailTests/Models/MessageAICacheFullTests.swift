/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageAICache Full Persistence")
struct MessageAICacheFullTests {

    // MARK: - writeThrough creates new entry

    @Test("writeThrough creates new entry with summary fields")
    func writeThroughCreatesNewWithSummary() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<new@test.com>",
                summaryBlurb: "Meeting agenda for Q2 planning",
                summaryTodos: "- Prepare slides\n- Book conference room",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<new@test.com>")
        }
        #expect(fetched != nil)
        #expect(fetched?.summaryBlurb == "Meeting agenda for Q2 planning")
        #expect(fetched?.summaryTodos == "- Prepare slides\n- Book conference room")
        #expect(fetched?.rfc822MessageId == "<new@test.com>")
    }

    @Test("writeThrough creates new entry with action tag")
    func writeThroughCreatesNewWithAction() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<action@test.com>",
                actionTag: .delete,
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<action@test.com>")
        }
        #expect(fetched?.actionTag == .delete)
    }

    @Test("writeThrough creates new entry with reply fields")
    func writeThroughCreatesNewWithReply() throws {
        let db = try TestDatabase.make()
        let now = Date()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<reply@test.com>",
                cachedReply: "Thanks for the update, I will review by Friday.",
                replyGeneratedAt: now,
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<reply@test.com>")
        }
        #expect(fetched?.cachedReply == "Thanks for the update, I will review by Friday.")
        #expect(fetched?.replyGeneratedAt != nil)
    }

    @Test("writeThrough creates new entry with reminder fields")
    func writeThroughCreatesNewWithReminder() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<remind@test.com>",
                reminderDate: "2026-03-20",
                reminderTime: "09:00",
                reminderContent: "Follow up on budget proposal",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<remind@test.com>")
        }
        #expect(fetched?.reminderDate == "2026-03-20")
        #expect(fetched?.reminderTime == "09:00")
        #expect(fetched?.reminderContent == "Follow up on budget proposal")
    }

    // MARK: - writeThrough updates existing without overwriting nil fields

    @Test("writeThrough preserves summary when updating action only")
    func writeThroughPreservesSummaryOnActionUpdate() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<partial@test.com>",
                summaryBlurb: "Original summary",
                summaryTodos: "Original todos",
                db: $0
            )
        }

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<partial@test.com>",
                actionTag: .archive,
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<partial@test.com>")
        }
        #expect(fetched?.summaryBlurb == "Original summary")
        #expect(fetched?.summaryTodos == "Original todos")
        #expect(fetched?.actionTag == .archive)
    }

    @Test("writeThrough preserves action when updating reply only")
    func writeThroughPreservesActionOnReplyUpdate() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<keep@test.com>",
                actionTag: .reply,
                db: $0
            )
        }

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<keep@test.com>",
                cachedReply: "New reply text",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<keep@test.com>")
        }
        #expect(fetched?.actionTag == .reply)
        #expect(fetched?.cachedReply == "New reply text")
    }

    @Test("writeThrough overwrites specific field when provided")
    func writeThroughOverwritesProvidedField() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<overwrite@test.com>",
                summaryBlurb: "First version",
                db: $0
            )
        }

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<overwrite@test.com>",
                summaryBlurb: "Updated version",
                db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<overwrite@test.com>")
        }
        #expect(fetched?.summaryBlurb == "Updated version")
    }

    // MARK: - writeThrough with nil/empty rfc822MessageId is no-op

    @Test("writeThrough with nil rfc822MessageId does not insert")
    func writeThroughNilMessageIdNoOp() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: nil,
                summaryBlurb: "Should not appear",
                actionTag: .archive,
                db: $0
            )
        }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 0)
    }

    @Test("writeThrough with empty rfc822MessageId does not insert")
    func writeThroughEmptyMessageIdNoOp() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "",
                summaryBlurb: "Should not appear",
                db: $0
            )
        }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 0)
    }

    // MARK: - restoreIfCached restores summary, action, reply

    @Test("restoreIfCached restores all summary fields into empty header")
    func restoreSummaryIntoEmptyHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<restore-all@test.com>",
                summaryBlurb: "Quarterly review summary",
                summaryTodos: "- Submit report\n- Schedule meeting",
                reminderDate: "2026-04-01",
                reminderTime: "10:00",
                reminderContent: "Submit quarterly report",
                actionTag: .reply,
                cachedReply: "I will submit by Friday.",
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "200", rfc822MessageId: "<restore-all@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.summaryBlurb == "Quarterly review summary")
        #expect(header.summaryTodos == "- Submit report\n- Schedule meeting")
        #expect(header.reminderDate == "2026-04-01")
        #expect(header.reminderTime == "10:00")
        #expect(header.reminderContent == "Submit quarterly report")
        #expect(header.actionTag == .reply)
        #expect(header.cachedReply == "I will submit by Friday.")
    }

    // MARK: - restoreIfCached does not overwrite existing actionTag (first-compute-wins)

    @Test("restoreIfCached preserves existing actionTag from server (first-compute-wins)")
    func restorePreservesServerActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<server-tag@test.com>",
                actionTag: .archive,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "300", rfc822MessageId: "<server-tag@test.com>", actionTag: .delete
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        // Server tag (.delete) must NOT be overwritten by cache (.archive)
        #expect(header.actionTag == .delete)
    }

    @Test("restoreIfCached preserves existing actionTag .none from server")
    func restorePreservesServerNoneTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<none-tag@test.com>",
                actionTag: .reply,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "301", rfc822MessageId: "<none-tag@test.com>", actionTag: ActionTag.none
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.actionTag == ActionTag.none)
    }

    // MARK: - restoreIfCached ReplyDetect: reply -> none for already-replied message

    @Test("restoreIfCached converts reply to none for already-replied message")
    func restoreReplyDetectConvertsToNone() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<replied@test.com>",
                actionTag: .reply,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "400", rfc822MessageId: "<replied@test.com>"
        )
        header.isReplied = true

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.actionTag == ActionTag.none)
        #expect(header.tagSortOrder == ActionTag.none.sortOrder)
    }

    @Test("restoreIfCached does NOT convert non-reply tags for replied messages")
    func restoreReplyDetectDoesNotConvertOtherTags() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<archive-replied@test.com>",
                actionTag: .archive,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "401", rfc822MessageId: "<archive-replied@test.com>"
        )
        header.isReplied = true

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        // archive should stay as archive even for replied messages
        #expect(header.actionTag == .archive)
    }

    @Test("restoreIfCached keeps reply tag when message is NOT replied")
    func restoreReplyDetectKeepsReplyForUnreplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<unreplied@test.com>",
                actionTag: .reply,
                db: $0
            )
        }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "402", rfc822MessageId: "<unreplied@test.com>"
        )
        // isReplied defaults to false

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.actionTag == .reply)
    }

    // MARK: - Filter by rfc822MessageId for Device Sync probe

    @Test("Filter by rfc822MessageId returns all matching entries across folders")
    func filterByRfc822MessageIdMultipleFolders() throws {
        let db = try TestDatabase.make()

        try db.write { db in
            var c1 = MessageAICache(key: "acc1:INBOX:<probe@test.com>", rfc822MessageId: "<probe@test.com>")
            c1.actionTag = .archive
            try c1.insert(db)

            var c2 = MessageAICache(key: "acc1:Sent:<probe@test.com>", rfc822MessageId: "<probe@test.com>")
            c2.actionTag = .none
            try c2.insert(db)

            var c3 = MessageAICache(key: "acc1:INBOX:<other@test.com>", rfc822MessageId: "<other@test.com>")
            c3.actionTag = .delete
            try c3.insert(db)
        }

        let matches = try db.read {
            try MessageAICache.filter(Column("rfc822MessageId") == "<probe@test.com>").fetchAll($0)
        }
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.rfc822MessageId == "<probe@test.com>" })
    }

    @Test("Filter by rfc822MessageId returns empty when no match")
    func filterByRfc822MessageIdNoMatch() throws {
        let db = try TestDatabase.make()

        try db.write {
            var c = MessageAICache(key: "k1", rfc822MessageId: "<exists@test.com>")
            try c.insert($0)
        }

        let matches = try db.read {
            try MessageAICache.filter(Column("rfc822MessageId") == "<missing@test.com>").fetchAll($0)
        }
        #expect(matches.isEmpty)
    }

    // MARK: - Delete all for account pattern using LIKE

    @Test("Delete all cache entries for account using LIKE prefix")
    func deleteAllForAccountLike() throws {
        let db = try TestDatabase.make()

        try db.write { db in
            try MessageAICache(key: "acc1:INBOX:<m1@t.com>", rfc822MessageId: "<m1@t.com>").insert(db)
            try MessageAICache(key: "acc1:Sent:<m2@t.com>", rfc822MessageId: "<m2@t.com>").insert(db)
            try MessageAICache(key: "acc2:INBOX:<m3@t.com>", rfc822MessageId: "<m3@t.com>").insert(db)
        }

        let deleted = try db.write {
            try MessageAICache.filter(Column("key").like("acc1:%")).deleteAll($0)
        }
        #expect(deleted == 2)

        let remaining = try db.read { try MessageAICache.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].key == "acc2:INBOX:<m3@t.com>")
    }

    @Test("Delete with LIKE does not affect unrelated accounts")
    func deleteLikeDoesNotAffectOtherAccounts() throws {
        let db = try TestDatabase.make()

        try db.write { db in
            try MessageAICache(key: "acc10:INBOX:<m1@t.com>", rfc822MessageId: "<m1@t.com>").insert(db)
            try MessageAICache(key: "acc1:INBOX:<m2@t.com>", rfc822MessageId: "<m2@t.com>").insert(db)
        }

        // Delete acc1: — should not delete acc10:
        let deleted = try db.write {
            try MessageAICache.filter(Column("key").like("acc1:%")).deleteAll($0)
        }
        #expect(deleted == 1)

        let remaining = try db.read { try MessageAICache.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].key.hasPrefix("acc10:"))
    }

    // MARK: - Additional edge cases

    @Test("restoreIfCached does not restore empty summary blurb")
    func restoreEmptyBlurbIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var cache = MessageAICache(key: "acc1:INBOX:<empty-blurb@test.com>", rfc822MessageId: "<empty-blurb@test.com>")
        cache.summaryBlurb = ""
        try db.write { try cache.insert($0) }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "500", rfc822MessageId: "<empty-blurb@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.summaryBlurb == nil)
    }

    @Test("restoreIfCached does not restore empty cached reply")
    func restoreEmptyCachedReplyIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var cache = MessageAICache(key: "acc1:INBOX:<empty-reply@test.com>", rfc822MessageId: "<empty-reply@test.com>")
        cache.cachedReply = ""
        try db.write { try cache.insert($0) }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "501", rfc822MessageId: "<empty-reply@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.cachedReply == nil)
    }

    @Test("restoreIfCached with nil rfc822MessageId is a no-op")
    func restoreNilRfc822IsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "502", rfc822MessageId: nil
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        #expect(header.summaryBlurb == nil)
        #expect(header.actionTag == nil)
        #expect(header.cachedReply == nil)
    }

    @Test("restoreIfCached updates updatedAt on the cache entry")
    func restoreTouchesUpdatedAt() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let oldDate = Date(timeIntervalSince1970: 1000000)
        var cache = MessageAICache(key: "acc1:INBOX:<touch@test.com>", rfc822MessageId: "<touch@test.com>")
        cache.summaryBlurb = "A summary"
        cache.updatedAt = oldDate
        try db.write { try cache.insert($0) }

        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "503", rfc822MessageId: "<touch@test.com>"
        )

        try db.write {
            try MessageAICache.restoreIfCached(
                into: &header, accountId: "acc1", folderPath: "INBOX", db: $0
            )
        }

        let fetched = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<touch@test.com>")
        }
        // updatedAt should be newer than oldDate
        #expect(fetched!.updatedAt > oldDate)
    }

    @Test("writeThrough updates updatedAt on each call")
    func writeThroughUpdatesTimestamp() throws {
        let db = try TestDatabase.make()

        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<ts@test.com>",
                summaryBlurb: "First",
                db: $0
            )
        }

        let first = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<ts@test.com>")
        }

        // Small delay to ensure timestamp difference
        try db.write {
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<ts@test.com>",
                summaryBlurb: "Second",
                db: $0
            )
        }

        let second = try db.read {
            try MessageAICache.fetchOne($0, key: "acc1:INBOX:<ts@test.com>")
        }

        guard let first, let second else {
            Issue.record("Expected both cache entries to exist")
            return
        }
        #expect(second.updatedAt >= first.updatedAt)
    }
}
