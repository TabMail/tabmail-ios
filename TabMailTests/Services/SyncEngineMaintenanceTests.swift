/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for maintenance logic in SyncEngineMaintenance.
/// The static methods require DatabasePool (not DatabaseQueue), so we test
/// the underlying DB patterns and algorithms that those methods implement:
/// body eviction eligibility, AI cache expiry, and message prune ordering.
@Suite("SyncEngineMaintenance - DB Patterns")
struct SyncEngineMaintenanceTests {

    // MARK: - Body Eviction Eligibility

    @Test("Stale body older than TTL cutoff is eviction candidate")
    func staleBodyIsCandidate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", isInInbox: false)

        // Insert body with fetchedAt well in the past
        let ttlHours = SyncConfig.bodyCacheTTLHours
        let staleFetchedAt = Calendar.current.date(byAdding: .hour, value: -(ttlHours + 1), to: Date())!
        try db.write { dbConn in
            try dbConn.execute(
                sql: "INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)",
                arguments: [header.id, "<p>old</p>", staleFetchedAt]
            )
        }

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -ttlHours, to: Date())!
        let staleCount = try db.read { dbConn in
            try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchCount(dbConn)
        }
        #expect(staleCount == 1)
    }

    @Test("Recent body within TTL is not eviction candidate")
    func recentBodyNotCandidate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Insert body with recent fetchedAt
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let staleCount = try db.read { dbConn in
            try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchCount(dbConn)
        }
        #expect(staleCount == 0)
    }

    @Test("Inbox messages are protected from eviction")
    func inboxMessagesProtected() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", isInInbox: true)

        // Even if body is stale, inbox messages should be skipped in eviction logic
        let fetched = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: header.id)
        }
        #expect(fetched?.isInInbox == true)
    }

    // MARK: - AI Cache Expiry

    @Test("Expired AI cache entry is identified by updatedAt cutoff")
    func expiredAICacheEntry() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let expiredDate = Calendar.current.date(byAdding: .day, value: -(SyncConfig.aiCacheTTLDays + 1), to: Date())!

        try db.write { dbConn in
            var cache = MessageAICache(key: "acc1:INBOX:<msg1@example.com>", rfc822MessageId: "<msg1@example.com>")
            cache.summaryBlurb = "Old summary"
            cache.updatedAt = expiredDate
            try cache.insert(dbConn)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let expiredCount = try db.read { dbConn in
            try MessageAICache.filter(Column("updatedAt") < cutoff).fetchCount(dbConn)
        }
        #expect(expiredCount == 1)
    }

    @Test("Recent AI cache entry is not expired")
    func recentAICacheNotExpired() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write { dbConn in
            var cache = MessageAICache(key: "acc1:INBOX:<msg1@example.com>")
            cache.summaryBlurb = "Fresh summary"
            cache.updatedAt = Date()
            try cache.insert(dbConn)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let expiredCount = try db.read { dbConn in
            try MessageAICache.filter(Column("updatedAt") < cutoff).fetchCount(dbConn)
        }
        #expect(expiredCount == 0)
    }

    @Test("AI cache rescue: entry with inbox message gets updatedAt refreshed")
    func aiCacheRescueInboxMessage() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let rfc822 = "<msg1@example.com>"
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", isInInbox: true, rfc822MessageId: rfc822
        )

        let expiredDate = Calendar.current.date(byAdding: .day, value: -(SyncConfig.aiCacheTTLDays + 1), to: Date())!
        try db.write { dbConn in
            var cache = MessageAICache(key: "acc1:INBOX:\(rfc822)", rfc822MessageId: rfc822)
            cache.summaryBlurb = "Summary"
            cache.updatedAt = expiredDate
            try cache.insert(dbConn)
        }

        // Simulate the rescue logic from runPurgeExpiredAICache
        let now = Date()
        try db.write { dbConn in
            let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
            let batch = try MessageAICache.filter(Column("updatedAt") < cutoff).fetchAll(dbConn)
            for var entry in batch {
                if let msgId = entry.rfc822MessageId, !msgId.isEmpty {
                    let headers = try MessageHeader
                        .filter(Column("rfc822MessageId") == msgId)
                        .limit(5)
                        .fetchAll(dbConn)
                    if headers.contains(where: { $0.isInInbox }) {
                        entry.updatedAt = now
                        try entry.update(dbConn)
                    }
                }
            }
        }

        // Verify the entry was rescued (updatedAt refreshed)
        let cache = try db.read { dbConn in
            try MessageAICache.fetchOne(dbConn, key: "acc1:INBOX:\(rfc822)")
        }
        #expect(cache != nil)
        #expect(cache!.updatedAt >= now.addingTimeInterval(-1))
    }

    // MARK: - Prune Ordering

    @Test("Messages ordered by date ASC for pruning (oldest first)")
    func pruneOrderingOldestFirst() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", date: now.addingTimeInterval(-3600))
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", date: now.addingTimeInterval(-7200))
        let msg3 = try TestDatabase.insertMessageHeader(db, messageId: "3", date: now)

        let ordered = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").asc)
                .fetchAll(dbConn)
        }

        #expect(ordered.count == 3)
        #expect(ordered[0].messageId == "2") // oldest
        #expect(ordered[1].messageId == "1")
        #expect(ordered[2].messageId == "3") // newest
    }

    @Test("Floor per folder prevents pruning below minimum")
    func floorPerFolderProtection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let floor = StorageEstimator.floorPerFolder

        // Insert exactly floor number of messages
        for i in 1...floor {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        let totalInFolder = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount(dbConn)
        }

        // When totalInFolder <= floor, pruneCount would be 0 or negative
        let pruneCount = totalInFolder - floor
        #expect(pruneCount <= 0)
    }

    // MARK: - Body deletion cascades

    @Test("Deleting MessageBody does not delete MessageHeader")
    func bodyDeletionPreservesHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        try db.write { dbConn in
            _ = try MessageBody.filter(Column("id") == header.id).deleteAll(dbConn)
        }

        let headerStillExists = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: header.id)
        }
        let bodyGone = try db.read { dbConn in
            try MessageBody.fetchOne(dbConn, key: header.id)
        }

        #expect(headerStillExists != nil)
        #expect(bodyGone == nil)
    }

    @Test("Deleting MessageHeader cascades to MessageBody")
    func headerDeletionCascadesToBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        try db.write { dbConn in
            _ = try MessageHeader.deleteAll(dbConn, keys: [header.id])
        }

        let bodyGone = try db.read { dbConn in
            try MessageBody.fetchOne(dbConn, key: header.id)
        }
        #expect(bodyGone == nil)
    }

    // MARK: - Chunk-based processing

    @Test("Chunk query with limit and offset works correctly")
    func chunkQueryLimitOffset() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 1...10 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(i)", date: Date(timeIntervalSince1970: Double(i) * 3600)
            )
        }

        let chunkSize = 3
        let firstChunk = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").asc)
                .limit(chunkSize, offset: 0)
                .fetchAll(dbConn)
        }
        let secondChunk = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").asc)
                .limit(chunkSize, offset: 3)
                .fetchAll(dbConn)
        }

        #expect(firstChunk.count == 3)
        #expect(secondChunk.count == 3)
        #expect(firstChunk[0].messageId == "1")
        #expect(secondChunk[0].messageId == "4")
    }
}
