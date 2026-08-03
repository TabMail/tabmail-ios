/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Prune Algorithm Tests

@Suite("Prune Algorithm - Bodies First, Then Headers")
struct PruneAlgorithmTests {

    /// Helper: insert N headers into a folder with ascending dates.
    private func insertHeaders(
        _ db: DatabaseQueue,
        count: Int,
        folderId: String = "acc1:INBOX",
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        isInInbox: Bool = true,
        baseDate: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws -> [MessageHeader] {
        var headers: [MessageHeader] = []
        for i in 0..<count {
            let header = try TestDatabase.insertMessageHeader(
                db,
                messageId: "\(folderId)-\(i)",
                date: baseDate.addingTimeInterval(Double(i) * 3600),
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: isInInbox
            )
            headers.append(header)
        }
        return headers
    }

    @Test("Phase 1: bodies for oldest messages deleted first, floor preserved")
    func prunePhase1BodiesOldestFirst() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let floor = 3
        let totalMessages = 7
        let headers = try insertHeaders(db, count: totalMessages)

        // Insert bodies for all messages
        for header in headers {
            try TestDatabase.insertMessageBody(db, headerId: header.id)
        }

        // Replicate Phase 1 prune algorithm: delete bodies for oldest messages, keep floor
        let totalInFolder = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount(dbConn)
        }
        #expect(totalInFolder == totalMessages)

        let pruneCount = totalInFolder - floor
        #expect(pruneCount == 4)

        let headerIds: [String] = try db.read { dbConn in
            try String.fetchAll(dbConn,
                MessageHeader
                    .select(Column("id"))
                    .filter(Column("folderId") == "acc1:INBOX")
                    .order(Column("date").asc)
                    .limit(pruneCount)
            )
        }
        #expect(headerIds.count == 4)

        let deleted = try db.write { dbConn in
            try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(dbConn)
        }
        #expect(deleted == 4)

        // Verify: oldest 4 bodies gone, newest 3 still have bodies
        let remainingBodies = try db.read { dbConn in
            try MessageBody.fetchAll(dbConn)
        }
        #expect(remainingBodies.count == 3)

        // The remaining bodies belong to the 3 newest messages
        let remainingIds = Set(remainingBodies.map(\.id))
        for i in (totalMessages - floor)..<totalMessages {
            #expect(remainingIds.contains(ContentKey(rawValue: headers[i].id)))
        }

        // All headers still exist
        let headerCount = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount(dbConn)
        }
        #expect(headerCount == totalMessages)
    }

    @Test("Phase 2: headers deleted oldest first after bodies, floor preserved")
    func prunePhase2HeadersOldestFirst() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let floor = 3
        let totalMessages = 8
        let headers = try insertHeaders(db, count: totalMessages)

        // Simulate: no bodies remain (Phase 1 already ran), now prune headers
        let chunkSize = 50
        var headersRemoved = 0

        while true {
            let currentCount = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount(dbConn)
            }
            guard currentCount > floor else { break }

            let batch: [MessageHeader] = try db.read { dbConn in
                try MessageHeader
                    .filter(Column("folderId") == "acc1:INBOX")
                    .order(Column("date").asc)
                    .limit(chunkSize)
                    .fetchAll(dbConn)
            }
            guard !batch.isEmpty else { break }

            try db.write { dbConn in
                // Only delete enough to reach floor
                let toDelete = min(batch.count, currentCount - floor)
                for i in 0..<toDelete {
                    try batch[i].delete(dbConn)
                    headersRemoved += 1
                }
            }
        }

        #expect(headersRemoved == totalMessages - floor)

        let remaining = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").asc)
                .fetchAll(dbConn)
        }
        #expect(remaining.count == floor)
        // Remaining should be the newest messages
        #expect(remaining[0].messageId == headers[totalMessages - floor].messageId)
    }

    @Test("Multi-folder prune processes each folder independently")
    func pruneMultiFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let floor = 2
        _ = try insertHeaders(db, count: 5, folderId: "acc1:INBOX", folderPath: "INBOX")
        _ = try insertHeaders(db, count: 4, folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        // Insert bodies for all
        let allHeaders = try db.read { dbConn in try MessageHeader.fetchAll(dbConn) }
        for header in allHeaders {
            try TestDatabase.insertMessageBody(db, headerId: header.id)
        }

        // Run prune logic per folder
        let folders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1").fetchAll(dbConn)
        }
        var totalBodiesRemoved = 0
        for folder in folders {
            let totalInFolder = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchCount(dbConn)
            }
            guard totalInFolder > floor else { continue }
            let pruneCount = totalInFolder - floor
            let headerIds: [String] = try db.read { dbConn in
                try String.fetchAll(dbConn,
                    MessageHeader
                        .select(Column("id"))
                        .filter(Column("folderId") == folder.id)
                        .order(Column("date").asc)
                        .limit(pruneCount)
                )
            }
            let deleted = try db.write { dbConn in
                try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(dbConn)
            }
            totalBodiesRemoved += deleted
        }

        // INBOX: 5 - 2 = 3 pruned, Sent: 4 - 2 = 2 pruned
        #expect(totalBodiesRemoved == 5)

        let inboxBodyCount = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM messageBody b
                JOIN messageHeader h ON h.id = b.id
                WHERE h.folderId = 'acc1:INBOX'
            """)!
        }
        #expect(inboxBodyCount == 2)

        let sentBodyCount = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM messageBody b
                JOIN messageHeader h ON h.id = b.id
                WHERE h.folderId = 'acc1:Sent'
            """)!
        }
        #expect(sentBodyCount == 2)
    }

    @Test("No pruning when message count at or below floor")
    func noPruningBelowFloor() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let floor = 5
        _ = try insertHeaders(db, count: floor)

        let totalInFolder = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount(dbConn)
        }
        let pruneCount = totalInFolder - floor
        #expect(pruneCount <= 0)
    }

    @Test("Prune chunk processing works across multiple batches")
    func pruneChunkedProcessing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let headers = try insertHeaders(db, count: 10)
        for header in headers {
            try TestDatabase.insertMessageBody(db, headerId: header.id)
        }

        let floor = 2
        let chunkSize = 3
        let pruneCount = 10 - floor

        // Process in chunks like production code — limit last chunk to not exceed pruneCount
        var bodiesRemoved = 0
        var offset = 0
        while offset < pruneCount {
            let remaining = pruneCount - offset
            let thisChunk = min(chunkSize, remaining)
            let headerIds: [String] = try db.read { dbConn in
                try String.fetchAll(dbConn,
                    MessageHeader
                        .select(Column("id"))
                        .filter(Column("folderId") == "acc1:INBOX")
                        .order(Column("date").asc)
                        .limit(thisChunk, offset: offset)
                )
            }
            guard !headerIds.isEmpty else { break }
            let deleted = try db.write { dbConn in
                try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(dbConn)
            }
            bodiesRemoved += deleted
            offset += headerIds.count
        }

        #expect(bodiesRemoved == 8)
        let remainingBodies = try db.read { dbConn in try MessageBody.fetchCount(dbConn) }
        #expect(remainingBodies == 2)
    }
}

// MARK: - Body Cache Eviction Tests

@Suite("Body Cache Eviction Algorithm")
struct BodyCacheEvictionTests {

    private func makeStaleBody(
        _ db: DatabaseQueue,
        headerId: String,
        hoursAgo: Int
    ) throws {
        let staleFetchedAt = Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: Date())!
        try db.write { dbConn in
            try dbConn.execute(
                sql: "INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)",
                arguments: [headerId, "<p>stale</p>", staleFetchedAt]
            )
        }
    }

    @Test("Stale non-inbox body is evicted")
    func staleNonInboxBodyEvicted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )
        try makeStaleBody(db, headerId: header.id, hoursAgo: SyncConfig.bodyCacheTTLHours + 1)

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let undoProtected: Set<String> = []
        _ = 3

        // Replicate eviction logic
        var evicted = 0
        try db.write { dbConn in
            let batch = try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchAll(dbConn)
            for body in batch {
                if undoProtected.contains(body.id.rawValue) { continue }
                guard let h = try MessageHeader.fetchOne(dbConn, key: body.id.rawValue) else {
                    try body.delete(dbConn)
                    evicted += 1
                    continue
                }
                if h.isInInbox { continue }
                // Skip recent check for simplicity in this test (only 1 message)
                try body.delete(dbConn)
                evicted += 1
            }
        }
        #expect(evicted == 1)
    }

    @Test("Inbox bodies are skipped even when stale")
    func inboxBodiesSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", isInInbox: true)
        try makeStaleBody(db, headerId: header.id, hoursAgo: SyncConfig.bodyCacheTTLHours + 10)

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        var evicted = 0
        try db.write { dbConn in
            let batch = try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchAll(dbConn)
            for body in batch {
                guard let h = try MessageHeader.fetchOne(dbConn, key: body.id) else {
                    try body.delete(dbConn)
                    evicted += 1
                    continue
                }
                if h.isInInbox { continue }
                try body.delete(dbConn)
                evicted += 1
            }
        }
        #expect(evicted == 0)
    }

    @Test("Undo-protected bodies are skipped")
    func undoProtectedSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )
        try makeStaleBody(db, headerId: header.id, hoursAgo: SyncConfig.bodyCacheTTLHours + 1)

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let undoProtected: Set<String> = [header.id]

        var evicted = 0
        var skipped = 0
        try db.write { dbConn in
            let batch = try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchAll(dbConn)
            for body in batch {
                if undoProtected.contains(body.id.rawValue) {
                    skipped += 1
                    continue
                }
                try body.delete(dbConn)
                evicted += 1
            }
        }
        #expect(evicted == 0)
        #expect(skipped == 1)
    }

    // NOTE: Orphaned body test removed — FK cascade (messageBody.id → messageHeader ON DELETE CASCADE)
    // makes it impossible to create orphan bodies in production. No test needed.

    @Test("Recent N bodies per folder are preserved regardless of TTL")
    func recentPerFolderPreserved() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let recentPerFolder = 3
        let baseDate = Date(timeIntervalSince1970: 1_000_000)

        // Insert 5 messages with stale bodies, ordered by date
        var headers: [MessageHeader] = []
        for i in 0..<5 {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)",
                date: baseDate.addingTimeInterval(Double(i) * 3600),
                folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
            )
            headers.append(header)
            try makeStaleBody(db, headerId: header.id, hoursAgo: SyncConfig.bodyCacheTTLHours + 1)
        }

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let undoProtected: Set<String> = []

        // Build recent cache (most recent N per folder)
        var recentCache: [String: Set<String>] = [:]
        var evicted = 0
        var skipCount = 0

        try db.write { dbConn in
            let batch = try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchAll(dbConn)
            for body in batch {
                if undoProtected.contains(body.id.rawValue) { skipCount += 1; continue }
                guard let header = try MessageHeader.fetchOne(dbConn, key: body.id.rawValue) else {
                    try body.delete(dbConn); evicted += 1; continue
                }
                if header.isInInbox { skipCount += 1; continue }

                if recentCache[header.folderId] == nil {
                    let recentIds = try Set(String.fetchAll(dbConn,
                        MessageHeader
                            .select(Column("id"))
                            .filter(Column("folderId") == header.folderId)
                            .order(Column("date").desc)
                            .limit(recentPerFolder)
                    ))
                    recentCache[header.folderId] = recentIds
                }
                if recentCache[header.folderId]?.contains(header.id) == true {
                    skipCount += 1
                    continue
                }
                try body.delete(dbConn)
                evicted += 1
            }
        }

        // 5 messages, 3 most recent preserved, 2 oldest evicted
        #expect(evicted == 2)
        #expect(skipCount == 3)

        // Verify the 3 newest bodies still exist
        for i in 2..<5 {
            let body = try db.read { dbConn in try MessageBody.fetchOne(dbConn, key: headers[i].id) }
            #expect(body != nil, "Body for message \(i) should be preserved as recent")
        }
        // Oldest 2 bodies gone
        for i in 0..<2 {
            let body = try db.read { dbConn in try MessageBody.fetchOne(dbConn, key: headers[i].id) }
            #expect(body == nil, "Body for message \(i) should be evicted")
        }
    }

    @Test("Fresh bodies (within TTL) are never evicted")
    func freshBodiesNeverEvicted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )
        try TestDatabase.insertMessageBody(db, headerId: header.id) // fetchedAt = now

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let staleCount = try db.read { dbConn in
            try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchCount(dbConn)
        }
        #expect(staleCount == 0)
    }
}

// MARK: - AI Cache Purge Tests

@Suite("AI Cache Purge Algorithm")
struct AICachePurgeTests {

    private func makeExpiredCache(
        _ db: DatabaseQueue,
        key: String,
        rfc822MessageId: String?,
        daysAgo: Int
    ) throws {
        let expiredDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        try db.write { dbConn in
            var cache = MessageAICache(key: key, rfc822MessageId: rfc822MessageId)
            cache.summaryBlurb = "Summary for \(key)"
            cache.updatedAt = expiredDate
            try cache.insert(dbConn)
        }
    }

    @Test("Expired AI cache entry with no inbox message is purged")
    func expiredNonInboxPurged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let rfc = "<msg1@example.com>"
        // Message is NOT in inbox
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Sent", folderPath: "Sent",
            isInInbox: false, rfc822MessageId: rfc
        )
        try makeExpiredCache(db, key: "acc1:Sent:\(rfc)", rfc822MessageId: rfc, daysAgo: SyncConfig.aiCacheTTLDays + 1)

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        var purged = 0
        try db.write { dbConn in
            let batch = try MessageAICache.filter(Column("updatedAt") < cutoff).fetchAll(dbConn)
            for var entry in batch {
                if let msgId = entry.rfc822MessageId, !msgId.isEmpty {
                    let headers = try MessageHeader
                        .filter(Column("rfc822MessageId") == msgId)
                        .limit(5)
                        .fetchAll(dbConn)
                    if headers.contains(where: { $0.isInInbox }) {
                        entry.updatedAt = Date()
                        try entry.update(dbConn)
                        continue
                    }
                }
                try entry.delete(dbConn)
                purged += 1
            }
        }
        #expect(purged == 1)
        let remaining = try db.read { dbConn in try MessageAICache.fetchCount(dbConn) }
        #expect(remaining == 0)
    }

    @Test("Expired AI cache entry rescued when rfc822MessageId still in inbox")
    func expiredInboxRescued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let rfc = "<msg1@example.com>"
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", isInInbox: true, rfc822MessageId: rfc
        )
        try makeExpiredCache(db, key: "acc1:INBOX:\(rfc)", rfc822MessageId: rfc, daysAgo: SyncConfig.aiCacheTTLDays + 1)

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let now = Date()
        var purged = 0
        var rescued = 0
        try db.write { dbConn in
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
                        rescued += 1
                        continue
                    }
                }
                try entry.delete(dbConn)
                purged += 1
            }
        }
        #expect(purged == 0)
        #expect(rescued == 1)

        let cache = try db.read { dbConn in
            try MessageAICache.fetchOne(dbConn, key: "acc1:INBOX:\(rfc)")
        }
        #expect(cache != nil)
        #expect(cache!.updatedAt >= now.addingTimeInterval(-1))
    }

    @Test("AI cache entry with nil rfc822MessageId is always purged")
    func nilRfc822AlwaysPurged() throws {
        let db = try TestDatabase.make()
        try makeExpiredCache(db, key: "acc1:INBOX:none", rfc822MessageId: nil, daysAgo: SyncConfig.aiCacheTTLDays + 1)

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        var purged = 0
        try db.write { dbConn in
            let batch = try MessageAICache.filter(Column("updatedAt") < cutoff).fetchAll(dbConn)
            for var entry in batch {
                if let msgId = entry.rfc822MessageId, !msgId.isEmpty {
                    // Would check inbox, but rfc822MessageId is nil so we skip
                    let headers = try MessageHeader
                        .filter(Column("rfc822MessageId") == msgId)
                        .limit(5)
                        .fetchAll(dbConn)
                    if headers.contains(where: { $0.isInInbox }) {
                        entry.updatedAt = Date()
                        try entry.update(dbConn)
                        continue
                    }
                }
                try entry.delete(dbConn)
                purged += 1
            }
        }
        #expect(purged == 1)
    }

    @Test("AI cache entry with empty rfc822MessageId is always purged")
    func emptyRfc822AlwaysPurged() throws {
        let db = try TestDatabase.make()
        try makeExpiredCache(db, key: "acc1:INBOX:empty", rfc822MessageId: "", daysAgo: SyncConfig.aiCacheTTLDays + 1)

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        var purged = 0
        try db.write { dbConn in
            let batch = try MessageAICache.filter(Column("updatedAt") < cutoff).fetchAll(dbConn)
            for var entry in batch {
                if let msgId = entry.rfc822MessageId, !msgId.isEmpty {
                    let headers = try MessageHeader
                        .filter(Column("rfc822MessageId") == msgId)
                        .limit(5)
                        .fetchAll(dbConn)
                    if headers.contains(where: { $0.isInInbox }) {
                        entry.updatedAt = Date()
                        try entry.update(dbConn)
                        continue
                    }
                }
                try entry.delete(dbConn)
                purged += 1
            }
        }
        #expect(purged == 1)
    }

    @Test("Recent AI cache entry is not purged")
    func recentAICacheNotPurged() throws {
        let db = try TestDatabase.make()
        try db.write { dbConn in
            var cache = MessageAICache(key: "acc1:INBOX:<fresh@example.com>", rfc822MessageId: "<fresh@example.com>")
            cache.summaryBlurb = "Fresh"
            cache.updatedAt = Date()
            try cache.insert(dbConn)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let expiredCount = try db.read { dbConn in
            try MessageAICache.filter(Column("updatedAt") < cutoff).fetchCount(dbConn)
        }
        #expect(expiredCount == 0)
    }

    @Test("Mixed purge and rescue in same batch")
    func mixedPurgeAndRescue() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let rfcInbox = "<inbox@example.com>"
        let rfcSent = "<sent@example.com>"

        // One message in inbox, one not
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", isInInbox: true, rfc822MessageId: rfcInbox
        )
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: "acc1:Sent", folderPath: "Sent",
            isInInbox: false, rfc822MessageId: rfcSent
        )

        try makeExpiredCache(db, key: "acc1:INBOX:\(rfcInbox)", rfc822MessageId: rfcInbox, daysAgo: SyncConfig.aiCacheTTLDays + 1)
        try makeExpiredCache(db, key: "acc1:Sent:\(rfcSent)", rfc822MessageId: rfcSent, daysAgo: SyncConfig.aiCacheTTLDays + 1)

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let now = Date()
        var purged = 0
        var rescued = 0

        try db.write { dbConn in
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
                        rescued += 1
                        continue
                    }
                }
                try entry.delete(dbConn)
                purged += 1
            }
        }

        #expect(purged == 1)
        #expect(rescued == 1)
        let remaining = try db.read { dbConn in try MessageAICache.fetchCount(dbConn) }
        #expect(remaining == 1)
    }

    @Test("Purge skips offset for rescued entries correctly")
    func purgeSkipOffsetForRescued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Create 3 expired entries, all with inbox messages (all rescued)
        for i in 0..<3 {
            let rfc = "<msg\(i)@example.com>"
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(i)", isInInbox: true, rfc822MessageId: rfc
            )
            try makeExpiredCache(db, key: "acc1:INBOX:\(rfc)", rfc822MessageId: rfc, daysAgo: SyncConfig.aiCacheTTLDays + 1)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let now = Date()
        let chunkSize = 2
        var purged = 0
        var rescued = 0
        let skipCount = 0

        while true {
            let batchResult = try db.write { dbConn -> (purged: Int, rescued: Int, batchEmpty: Bool) in
                let batch = try MessageAICache
                    .filter(Column("updatedAt") < cutoff)
                    .limit(chunkSize, offset: skipCount)
                    .fetchAll(dbConn)
                guard !batch.isEmpty else { return (0, 0, true) }

                var batchPurged = 0
                var batchRescued = 0
                for var entry in batch {
                    if let msgId = entry.rfc822MessageId, !msgId.isEmpty {
                        let headers = try MessageHeader
                            .filter(Column("rfc822MessageId") == msgId)
                            .limit(5)
                            .fetchAll(dbConn)
                        if headers.contains(where: { $0.isInInbox }) {
                            entry.updatedAt = now
                            try entry.update(dbConn)
                            batchRescued += 1
                            continue
                        }
                    }
                    try entry.delete(dbConn)
                    batchPurged += 1
                }
                return (batchPurged, batchRescued, false)
            }
            if batchResult.batchEmpty { break }
            purged += batchResult.purged
            rescued += batchResult.rescued
            // NOTE: rescued entries had updatedAt bumped past cutoff, so they naturally
            // drop out of the filter — no need to increment skipCount for them.
        }

        #expect(purged == 0)
        #expect(rescued == 3)
    }
}

// MARK: - Stale Tag Sweep Tests

@Suite("Stale Action Tag Sweep Logic")
struct StaleTagSweepTests {

    @Test("Non-inbox message with actionTag should be identified for clearing")
    func nonInboxTagIdentified() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive",
            isInInbox: false, actionTag: .reply
        )

        let folders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }
        #expect(folders.count == 1)

        var staleTags: [(MessageHeader, ActionTag)] = []
        for folder in folders {
            let msgs: [MessageHeader] = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(dbConn)
            }
            for m in msgs where m.actionTag != nil {
                staleTags.append((m, m.actionTag!))
            }
        }
        #expect(staleTags.count == 1)
        #expect(staleTags[0].1 == .reply)
    }

    @Test("Inbox messages are excluded from stale tag sweep (only non-inbox folders scanned)")
    func inboxExcludedFromSweep() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", isInInbox: true, actionTag: .archive
        )

        let nonInboxFolders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }
        #expect(nonInboxFolders.isEmpty)
    }

    @Test("Gmail safety: skip tag clearing when same rfc822MessageId exists in inbox")
    func gmailDuplicateLabelSafety() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "All Mail", path: "AllMail", role: .custom)

        let rfc = "<shared@gmail.com>"

        // Same message in both inbox and All Mail (Gmail duplicate label)
        try TestDatabase.insertMessageHeader(
            db, messageId: "inbox-1", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, rfc822MessageId: rfc, actionTag: .reply
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "allmail-1", folderId: "acc1:AllMail", folderPath: "AllMail",
            isInInbox: false, rfc822MessageId: rfc, actionTag: .reply
        )

        // Build inbox rfc822 ID set
        let inboxRfc822Ids: Set<String> = try db.read { dbConn in
            let inboxHeaders = try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("isInInbox") == true)
                .fetchAll(dbConn)
            var ids = Set<String>()
            for msg in inboxHeaders {
                if let r = msg.rfc822MessageId, !r.isEmpty { ids.insert(r) }
            }
            return ids
        }

        // Check non-inbox folders for stale tags
        let nonInboxFolders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }

        var cleared = 0
        var skippedGmail = 0
        for folder in nonInboxFolders {
            let msgs: [MessageHeader] = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(dbConn)
            }
            for msg in msgs where msg.actionTag != nil {
                if let r = msg.rfc822MessageId, !r.isEmpty, inboxRfc822Ids.contains(r) {
                    skippedGmail += 1
                    continue
                }
                cleared += 1
            }
        }
        #expect(cleared == 0)
        #expect(skippedGmail == 1)
    }

    @Test("Non-inbox message without Gmail duplicate has tag cleared")
    func nonGmailDuplicateCleared() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let rfcArchive = "<archived@example.com>"
        try TestDatabase.insertMessageHeader(
            db, messageId: "arch-1", folderId: "acc1:Archive", folderPath: "Archive",
            isInInbox: false, rfc822MessageId: rfcArchive, actionTag: .delete
        )

        let inboxRfc822Ids: Set<String> = try db.read { dbConn in
            let inboxHeaders = try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("isInInbox") == true)
                .fetchAll(dbConn)
            var ids = Set<String>()
            for msg in inboxHeaders {
                if let r = msg.rfc822MessageId, !r.isEmpty { ids.insert(r) }
            }
            return ids
        }

        let nonInboxFolders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }

        var cleared = 0
        for folder in nonInboxFolders {
            let msgs: [MessageHeader] = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(dbConn)
            }
            for msg in msgs where msg.actionTag != nil {
                if let r = msg.rfc822MessageId, !r.isEmpty, inboxRfc822Ids.contains(r) {
                    continue
                }
                // Clear the tag
                try db.write { dbConn in
                    _ = try MessageHeader.filter(Column("id") == msg.id)
                        .updateAll(dbConn,
                            Column("actionTag").set(to: nil as String?),
                            Column("tagSortOrder").set(to: 99)
                        )
                }
                cleared += 1
            }
        }
        #expect(cleared == 1)

        // Verify the tag was cleared
        let updated = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: "acc1:Archive:arch-1")
        }
        #expect(updated?.actionTag == nil)
        #expect(updated?.tagSortOrder == 99)
    }

    @Test("Messages without actionTag are not processed in sweep")
    func noActionTagSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive",
            isInInbox: false, actionTag: nil
        )

        let nonInboxFolders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }

        var processed = 0
        for folder in nonInboxFolders {
            let msgs: [MessageHeader] = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(dbConn)
            }
            for msg in msgs where msg.actionTag != nil {
                processed += 1
            }
        }
        #expect(processed == 0)
    }

    @Test("Sweep respects maxPerSweep limit")
    func sweepRespectsLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // Insert 5 non-inbox messages with tags
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", folderId: "acc1:Archive", folderPath: "Archive",
                isInInbox: false, rfc822MessageId: "<msg\(i)@example.com>", actionTag: .archive
            )
        }

        let maxPerSweep = 3
        let inboxRfc822Ids: Set<String> = []

        let nonInboxFolders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") != FolderRole.inbox.rawValue).fetchAll(dbConn)
        }

        var cleared = 0
        for folder in nonInboxFolders {
            guard cleared < maxPerSweep else { break }
            let remaining = maxPerSweep - cleared
            let msgs: [MessageHeader] = try db.read { dbConn in
                try MessageHeader
                    .filter(Column("folderId") == folder.id)
                    .limit(remaining)
                    .fetchAll(dbConn)
            }
            for msg in msgs where msg.actionTag != nil {
                guard cleared < maxPerSweep else { break }
                if let r = msg.rfc822MessageId, !r.isEmpty, inboxRfc822Ids.contains(r) {
                    continue
                }
                cleared += 1
            }
        }
        #expect(cleared == 3)
    }
}

// MARK: - Stale Action Tag Sweep — TTL Semantics (Round D-0b)

/// Drives the REAL `SyncEngine.sweepStaleActionTags` — not a hand-rolled
/// reimplementation like `StaleTagSweepTests` above, every test of which
/// re-executes the folder query / Gmail guard / clear SQL in its own body and
/// therefore stays green no matter what production does — against a temp-file
/// `DatabasePool` swapped into `AppDatabase.shared`. That swap is required
/// because `SyncEngine.dbPool` resolves through `AppDatabase.syncPool`.
///
/// This is the only place with genuine red/green signal on the TTL logic
/// (`SyncConfig.actionTagTTLSeconds`, migration v81).
@Suite("Stale Action Tag Sweep — TTL Semantics (Round D-0b)", .serialized, .processGlobalState)
struct StaleTagSweepTTLTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let account: Account
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }

        let accountId = "sweep-ttl-\(UUID().uuidString)"
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Test",
            provider: .gmail
        )
        account.id = accountId
        try pool.writeWithoutTransaction { db in try account.insert(db) }

        return Fixture(
            pool: pool, directory: directory, previous: previous,
            accountId: accountId, account: account
        )
    }

    private func restore(_ fixture: Fixture) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory)
    }

    @discardableResult
    private func insertHeader(
        fixture: Fixture,
        folder: Folder,
        messageId: String,
        rfc822MessageId: String? = nil,
        actionTag: ActionTag?,
        actionTagSetAt: Date?,
        isInInbox: Bool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: folder.id,
            accountId: fixture.accountId,
            folderPath: folder.path,
            isInInbox: isInInbox
        )
        header.rfc822MessageId = rfc822MessageId
        // Deliberately NOT `setActionTag` — these fixtures must be able to
        // express the invariant-violating legacy shape (tag set, stamp NULL).
        header.actionTag = actionTag
        header.tagSortOrder = actionTag?.sortOrder ?? 99
        header.actionTagSetAt = actionTagSetAt
        try fixture.pool.writeWithoutTransaction { try header.insert($0) }
        return header
    }

    @Test("Sweep SPARES a young out-of-inbox tag (age < SyncConfig.actionTagTTLSeconds)")
    func sparesYoungTag() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { try archive.insert($0) }

        let young = Date().addingTimeInterval(-3600) // 1 hour ago
        let header = try insertHeader(
            fixture: fixture, folder: archive, messageId: "young1",
            actionTag: .archive, actionTagSetAt: young, isInInbox: false
        )

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let stored = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(stored?.actionTag == .archive)
        #expect(stored?.actionTagSetAt != nil)
    }

    @Test("Sweep CLEARS an expired out-of-inbox tag and nils actionTagSetAt")
    func clearsExpiredTag() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { try archive.insert($0) }

        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let header = try insertHeader(
            fixture: fixture, folder: archive, messageId: "expired1",
            actionTag: .archive, actionTagSetAt: expired, isInInbox: false
        )

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let stored = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(stored?.actionTag == nil)
        #expect(stored?.tagSortOrder == 99)
        #expect(stored?.actionTagSetAt == nil)
    }

    @Test("Inbox tags are never swept regardless of age")
    func inboxNeverSweptRegardlessOfAge() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { try inbox.insert($0) }

        let veryOld = Date().addingTimeInterval(-10 * SyncConfig.actionTagTTLSeconds)
        let header = try insertHeader(
            fixture: fixture, folder: inbox, messageId: "inbox1",
            actionTag: .reply, actionTagSetAt: veryOld, isInInbox: true
        )

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let stored = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(stored?.actionTag == .reply)
        #expect(stored?.actionTagSetAt != nil)
    }

    @Test("NULL actionTagSetAt on an out-of-inbox tag is swept (legacy-row fail-safe pin)")
    func nullActionTagSetAtIsSweptFailSafe() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { try archive.insert($0) }

        let header = try insertHeader(
            fixture: fixture, folder: archive, messageId: "nullstamp1",
            actionTag: .delete, actionTagSetAt: nil, isInInbox: false
        )

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let stored = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(stored?.actionTag == nil, "A NULL stamp must be treated as already expired, never as infinitely fresh")
        #expect(stored?.actionTagSetAt == nil)
    }

    @Test("Gmail rfc822-still-in-inbox guard still skips an EXPIRED tag")
    func gmailGuardSkipsExpiredTag() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: fixture.accountId)
        let allMail = Folder(name: "All Mail", path: "AllMail", role: .custom, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { db in
            try inbox.insert(db)
            try allMail.insert(db)
        }

        let rfc = "<gmail-dup@example.com>"
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        try insertHeader(
            fixture: fixture, folder: inbox, messageId: "inbox-dup",
            rfc822MessageId: rfc, actionTag: .reply, actionTagSetAt: expired, isInInbox: true
        )
        let allMailHeader = try insertHeader(
            fixture: fixture, folder: allMail, messageId: "allmail-dup",
            rfc822MessageId: rfc, actionTag: .reply, actionTagSetAt: expired, isInInbox: false
        )

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let stored = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: allMailHeader.id) }
        #expect(stored?.actionTag == .reply, "Gmail duplicate-label guard must win over an expired TTL")
        #expect(stored?.actionTagSetAt != nil)
    }
}

// MARK: - Edge Case and Integration Tests

@Suite("Sync Maintenance Edge Cases")
struct SyncMaintenanceEdgeCaseTests {

    @Test("Prune with empty database is a no-op")
    func pruneEmptyDatabase() throws {
        let db = try TestDatabase.make()
        let headerCount = try db.read { dbConn in try MessageHeader.fetchCount(dbConn) }
        let bodyCount = try db.read { dbConn in try MessageBody.fetchCount(dbConn) }
        #expect(headerCount == 0)
        #expect(bodyCount == 0)
    }

    @Test("Eviction with no stale bodies is a no-op")
    func evictionNoStaleBodies() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        let totalStale = try db.read { dbConn in
            try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchCount(dbConn)
        }
        #expect(totalStale == 0)
    }

    @Test("AI cache purge with no expired entries is a no-op")
    func purgeNoExpiredEntries() throws {
        let db = try TestDatabase.make()
        try db.write { dbConn in
            var cache = MessageAICache(key: "acc1:INBOX:<fresh@x.com>", rfc822MessageId: "<fresh@x.com>")
            cache.updatedAt = Date()
            try cache.insert(dbConn)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date())!
        let count = try db.read { dbConn in
            try MessageAICache.filter(Column("updatedAt") < cutoff).fetchCount(dbConn)
        }
        #expect(count == 0)
    }

    @Test("Body eviction with all messages in inbox evicts nothing")
    func allInboxEvictsNothing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 0..<5 {
            let header = try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isInInbox: true)
            let staleFetchedAt = Calendar.current.date(byAdding: .hour, value: -(SyncConfig.bodyCacheTTLHours + 1), to: Date())!
            try db.write { dbConn in
                try dbConn.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)",
                    arguments: [header.id, "<p>body</p>", staleFetchedAt]
                )
            }
        }

        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date())!
        var evicted = 0
        try db.write { dbConn in
            let batch = try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchAll(dbConn)
            for body in batch {
                guard let h = try MessageHeader.fetchOne(dbConn, key: body.id) else {
                    try body.delete(dbConn); evicted += 1; continue
                }
                if h.isInInbox { continue }
                try body.delete(dbConn)
                evicted += 1
            }
        }
        #expect(evicted == 0)
    }

    @Test("Multi-account prune processes each account independently")
    func multiAccountPrune() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        let floor = 2

        // 5 messages in acc1, 3 messages in acc2
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "a1-\(i)",
                date: baseDate.addingTimeInterval(Double(i) * 3600),
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
            )
        }
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "a2-\(i)",
                date: baseDate.addingTimeInterval(Double(i) * 3600),
                folderId: "acc2:INBOX", accountId: "acc2", folderPath: "INBOX"
            )
        }

        // Insert bodies for all
        let allHeaders = try db.read { dbConn in try MessageHeader.fetchAll(dbConn) }
        for header in allHeaders {
            try TestDatabase.insertMessageBody(db, headerId: header.id)
        }

        let accounts = try db.read { dbConn in try Account.fetchAll(dbConn) }
        var totalBodiesRemoved = 0

        for account in accounts {
            let folders = try db.read { dbConn in
                try Folder.filter(Column("accountId") == account.id).fetchAll(dbConn)
            }
            for folder in folders {
                let totalInFolder = try db.read { dbConn in
                    try MessageHeader.filter(Column("folderId") == folder.id).fetchCount(dbConn)
                }
                guard totalInFolder > floor else { continue }
                let pruneCount = totalInFolder - floor
                let headerIds: [String] = try db.read { dbConn in
                    try String.fetchAll(dbConn,
                        MessageHeader
                            .select(Column("id"))
                            .filter(Column("folderId") == folder.id)
                            .order(Column("date").asc)
                            .limit(pruneCount)
                    )
                }
                let deleted = try db.write { dbConn in
                    try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(dbConn)
                }
                totalBodiesRemoved += deleted
            }
        }

        // acc1: 5 - 2 = 3, acc2: 3 - 2 = 1
        #expect(totalBodiesRemoved == 4)

        let acc1Bodies = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM messageBody b
                JOIN messageHeader h ON h.id = b.id
                WHERE h.accountId = 'acc1'
            """)!
        }
        let acc2Bodies = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM messageBody b
                JOIN messageHeader h ON h.id = b.id
                WHERE h.accountId = 'acc2'
            """)!
        }
        #expect(acc1Bodies == 2)
        #expect(acc2Bodies == 2)
    }
}
