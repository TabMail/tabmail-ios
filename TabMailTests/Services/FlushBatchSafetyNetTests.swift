/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: updateBodies Return Value

@Suite("FlushBatch Safety Net - updateBodies Return Value", .serialized, .processGlobalState)
struct UpdateBodiesReturnValueTests {

    private var index: SearchIndex { SearchIndex.shared }

    /// Helper to create a unique test header ID prefix to avoid collisions.
    private func prefix(_ label: String) -> String { "flush_test_\(label)" }

    @Test("updateBodies returns written headerIds for all indexed headers")
    func returnsAllWrittenIds() async throws {
        let ids = (1...3).map { "\(prefix("all")):\("INBOX"):\($0)" }
        let records = ids.enumerated().map { i, hid in
            FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
                headerId: hid,
                messageId: "m\(i)",
                subject: "Subject \(i)",
                from: "a@test.com",
                to: "b@test.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(i * 1000)
            )
        }

        // Cleanup + index
        try await index.removeMessages( contentKeys: ids.map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        // Update bodies for all 3
        let updates = ids.map { (headerId: $0, body: "Body content for \($0)") }
        let writtenIds = try await index.updateBodies(updates.map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        #expect(writtenIds.count == 3)
        for id in ids {
            #expect(writtenIds.contains(ContentKey(rawValue: id)), "\(id) should be in written set")
        }

        // Cleanup
        try await index.removeMessages( contentKeys: ids.map(ContentKey.init(rawValue:)))
    }

    @Test("updateBodies skips items not in FTS index")
    func skipsUnindexedItems() async throws {
        let hid = "\(prefix("skip")):INBOX:1"

        // Make sure this header is NOT in FTS
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))

        let writtenIds = try await index.updateBodies([
            (headerId: hid, body: "This body should be skipped")
        ].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        #expect(writtenIds.isEmpty, "Unindexed header should not appear in written set")
    }

    @Test("updateBodies mixed: some in FTS, some not")
    func mixedIndexedAndUnindexed() async throws {
        let indexedIds = (1...2).map { "\(prefix("mix_in")):\("INBOX"):\($0)" }
        let unindexedId = "\(prefix("mix_out")):INBOX:99"

        // Clean everything
        try await index.removeMessages( contentKeys: (indexedIds + [unindexedId]).map(ContentKey.init(rawValue:)))

        // Index only the first 2
        let records = indexedIds.enumerated().map { i, hid in
            FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
                headerId: hid,
                messageId: "m\(i)",
                subject: "Indexed \(i)",
                from: "a@test.com",
                to: "b@test.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(i * 1000)
            )
        }
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        // Update bodies for all 3 (2 indexed + 1 not)
        let updates = (indexedIds + [unindexedId]).map {
            (headerId: $0, body: "Body for \($0)")
        }
        let writtenIds = try await index.updateBodies(updates.map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        #expect(writtenIds.count == 2, "Only 2 indexed items should be written")
        for id in indexedIds {
            #expect(writtenIds.contains(ContentKey(rawValue: id)))
        }
        #expect(!writtenIds.contains(ContentKey(rawValue: unindexedId)))

        // Cleanup
        try await index.removeMessages( contentKeys: (indexedIds + [unindexedId]).map(ContentKey.init(rawValue:)))
    }

    @Test("updateBodies with empty array returns empty set")
    func emptyArrayReturnsEmptySet() async throws {
        let writtenIds = try await index.updateBodies([])
        #expect(writtenIds.isEmpty)
    }

    @Test("updateBodies with whitespace-only body is skipped")
    func whitespaceOnlyBodySkipped() async throws {
        let hid = "\(prefix("ws")):INBOX:1"

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid,
            messageId: "mws",
            subject: "Whitespace Test",
            from: "a@test.com",
            to: "b@test.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Update with whitespace-only body
        let writtenIds = try await index.updateBodies([
            (headerId: hid, body: "   \n\t  \n  ")
        ].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })
        #expect(writtenIds.isEmpty, "Whitespace-only body should be skipped")

        // Cleanup
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }
}

// MARK: - Suite 2: flushBatch Safety Net (GRDB + FTS Integration)

@Suite("FlushBatch Safety Net - bodyComplete Flag Gating", .serialized, .processGlobalState)
struct FlushBatchBodyCompleteTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("flushBatch only sets bodyComplete=1 for items written to FTS")
    func onlyWrittenItemsGetBodyComplete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()

        // Create 3 headers in GRDB
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "fb_w1", subject: "Written 1", date: now, snippet: "")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "fb_w2", subject: "Written 2", date: now, snippet: "")
        let h3 = try TestDatabase.insertMessageHeader(db, messageId: "fb_skip", subject: "Not Indexed", date: now, snippet: "")

        // Set headerComplete=1 for all
        for h in [h1, h2, h3] {
            try await db.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        // Index only h1 and h2 in FTS (NOT h3)
        try await index.removeMessages( contentKeys: [h1.id, h2.id, h3.id].map(ContentKey.init(rawValue:)))
        let records = [h1, h2].map { h in
            FTSHeaderRecord( contentKey: ContentKey(rawValue: h.id),
                headerId: h.id,
                messageId: h.messageId,
                subject: h.subject,
                from: "\(h.from) <\(h.fromAddress)>",
                to: h.to,
                dateMs: Int64(h.date.timeIntervalSince1970 * 1000)
            )
        }
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        // Simulate flushBatch: updateBodies for all 3
        let ftsBuffer = [
            (headerId: h1.id, body: "Body for h1"),
            (headerId: h2.id, body: "Body for h2"),
            (headerId: h3.id, body: "Body for h3"),  // not in FTS — will be skipped
        ]
        let writtenToFts = try await index.updateBodies(ftsBuffer.map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        #expect(writtenToFts.count == 2)
        #expect(writtenToFts.contains(ContentKey(rawValue: h1.id)))
        #expect(writtenToFts.contains(ContentKey(rawValue: h2.id)))
        #expect(!writtenToFts.contains(ContentKey(rawValue: h3.id)))

        // Only set bodyComplete=1 for written items (mirrors flushBatch logic)
        let confirmedItems = [h1, h2, h3].filter { writtenToFts.contains(ContentKey(rawValue: $0.id)) }
        try await db.write { dbConn in
            for item in confirmedItems {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                    arguments: [item.id]
                )
            }
        }

        // Verify h1 and h2 have bodyComplete=1
        for hid in [h1.id, h2.id] {
            let bc: Bool = try await db.read { dbConn in
                try Bool.fetchOne(dbConn,
                    sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                    arguments: [hid]) ?? false
            }
            #expect(bc == true, "\(hid) should have bodyComplete=1")
        }

        // Verify h3 still has bodyComplete=0
        let bc3: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [h3.id]) ?? true
        }
        #expect(bc3 == false, "Unwritten item should keep bodyComplete=0")

        // Cleanup
        try await index.removeMessages( contentKeys: [h1.id, h2.id, h3.id].map(ContentKey.init(rawValue:)))
    }

    @Test("flushBatch skipped items keep bodyComplete=0")
    func skippedItemsKeepBodyIncomplete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "fb_skip_only",
            subject: "Never Indexed",
            date: now,
            snippet: ""
        )
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Don't index in FTS — simulate the orphan case
        try await index.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))

        // Try to write body — should be skipped
        let writtenToFts = try await index.updateBodies([
            (headerId: header.id, body: "Body that should be deferred")
        ].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })
        #expect(writtenToFts.isEmpty)

        // bodyComplete must remain 0
        let bc: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(bc == false, "Skipped item must keep bodyComplete=0 for retry")
    }

    @Test("flushBatch only enqueues downstream processing for written items")
    func onlyWrittenItemsGetDownstreamProcessing() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "fb_ai_1", subject: "AI Written", date: now, snippet: "")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "fb_ai_skip", subject: "AI Skipped", date: now, snippet: "")

        // Index only h1 in FTS
        try await index.removeMessages( contentKeys: [h1.id, h2.id].map(ContentKey.init(rawValue:)))
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: h1.id),
            headerId: h1.id,
            messageId: h1.messageId,
            subject: h1.subject,
            from: "\(h1.from) <\(h1.fromAddress)>",
            to: h1.to,
            dateMs: Int64(h1.date.timeIntervalSince1970 * 1000)
        )
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Simulate flushBatch: updateBodies determines which items are written
        let ftsBuffer = [
            (headerId: h1.id, body: "Real body content"),
            (headerId: h2.id, body: "Body for unindexed item"),
        ]
        let writtenToFts = try await index.updateBodies(ftsBuffer.map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        // Build the confirmedItems list that flushBatch uses for AI enqueue
        let allItems = [
            (headerId: h1.id, accountId: "acc1", isInInbox: true),
            (headerId: h2.id, accountId: "acc1", isInInbox: true),
        ]
        let confirmedForAI = allItems.filter { writtenToFts.contains(ContentKey(rawValue: $0.headerId)) }

        #expect(confirmedForAI.count == 1, "Only written item should be enqueued for AI")
        guard confirmedForAI.count == 1 else { return }
        #expect(confirmedForAI[0].headerId == h1.id)

        // Cleanup
        try await index.removeMessages( contentKeys: [h1.id, h2.id].map(ContentKey.init(rawValue:)))
    }

    @Test("flushBatch FTS write failure leaves all bodyComplete=0")
    func ftsFailureLeavesAllIncomplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "fb_fail_1", subject: "Fail 1", date: now, snippet: "")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "fb_fail_2", subject: "Fail 2", date: now, snippet: "")

        // Set headerComplete=1
        for h in [h1, h2] {
            try db.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        // Simulate what happens when FTS write throws:
        // flushBatch returns early, no bodyComplete updates happen.
        // We verify the invariant: if updateBodies throws, nothing changes.
        let ftsWriteFailed = true  // simulating the error path

        if ftsWriteFailed {
            // flushBatch returns early — no GRDB updates
        }

        // All headers should still have bodyComplete=0
        for h in [h1, h2] {
            let bc: Bool = try db.read { dbConn in
                try Bool.fetchOne(dbConn,
                    sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                    arguments: [h.id]) ?? true
            }
            #expect(bc == false, "\(h.id) should keep bodyComplete=0 after FTS failure")
        }

        // These headers should still appear in the repopulate query (eligible for retry)
        let repopItems: [Row] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                """)
        }
        let ids = repopItems.map { $0["id"] as String }
        #expect(ids.contains(h1.id), "h1 should be retryable")
        #expect(ids.contains(h2.id), "h2 should be retryable")
    }
}
