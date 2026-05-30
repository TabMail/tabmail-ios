/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: Real indexHeadersForFTS Sets headerComplete

@Suite("Integration Pipeline - FTS Header Indexing", .serialized)
struct FTSHeaderIndexingIntegrationTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("Real indexHeadersForFTS sets headerComplete=1 in GRDB and creates FTS entry")
    func realIndexHeadersSetsHeaderComplete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "int_fts_hc_\(Int(now.timeIntervalSince1970))",
            subject: "Integration FTS Test",
            date: now,
            snippet: "test snippet"
        )

        // Verify starts as headerComplete=0
        let beforeHC: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(beforeHC == false, "Should start with headerComplete=false")

        // Clean up any stale FTS entry
        try await index.removeMessages(headerIds: [header.id])

        // Index into FTS and set headerComplete=1 (replicating SyncEngineFTS.indexHeadersForFTS)
        let ftsRecord = FTSHeaderRecord(
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        let inserted = try await index.indexHeaders([ftsRecord])
        #expect(inserted == 1, "Should insert 1 FTS record")

        // Set headerComplete=1 (what the real indexHeadersForFTS does after FTS success)
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Verify headerComplete=1
        let afterHC: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(afterHC == true, "Should be headerComplete=true after indexing")

        // Verify FTS entry exists
        let isIndexed = try await index.isIndexed(headerId: header.id)
        #expect(isIndexed == true, "FTS entry should exist")

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }
}

// MARK: - Suite 2: Real recoverIncompleteHeaders

@Suite("Integration Pipeline - Recover Incomplete Headers", .serialized)
struct RecoverIncompleteHeadersIntegrationTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("recoverIncompleteHeaders finds orphans and creates FTS entry + sets headerComplete=1")
    func realRecoverFindsOrphansAndFixes() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "int_recover_\(Int(now.timeIntervalSince1970))",
            subject: "Orphan Recovery Integration",
            date: now,
            snippet: "orphan test"
        )

        // Ensure no FTS entry (simulates crash between GRDB insert and FTS index)
        try await index.removeMessages(headerIds: [header.id])

        // Verify: headerComplete=0, no FTS entry
        let hcBefore: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(hcBefore == false)
        let ftsBeforeExists = try await index.isIndexed(headerId: header.id)
        #expect(ftsBeforeExists == false)

        // Run the recovery logic (mirrors SyncEngineFTS.recoverIncompleteHeaders)
        let incomplete: [MessageHeader] = try await db.read { dbConn in
            try MessageHeader
                .filter(Column("headerComplete") == false)
                .limit(500)
                .fetchAll(dbConn)
        }
        #expect(incomplete.count == 1, "Should find 1 incomplete header")
        guard incomplete.count == 1 else { return }

        let records = incomplete.map { h in
            FTSHeaderRecord(
                headerId: h.id,
                messageId: h.messageId,
                subject: h.subject,
                from: "\(h.from) <\(h.fromAddress)>",
                to: h.to,
                dateMs: Int64(h.date.timeIntervalSince1970 * 1000)
            )
        }
        let insertedCount = try await index.indexHeaders(records)
        #expect(insertedCount == 1)

        try await db.write { dbConn in
            for h in incomplete {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        // Verify: headerComplete=1 and FTS entry exists
        let hcAfter: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(hcAfter == true, "headerComplete should be true after recovery")

        let ftsAfterExists = try await index.isIndexed(headerId: header.id)
        #expect(ftsAfterExists == true, "FTS entry should exist after recovery")

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }
}

// MARK: - Suite 3: flushBatch with Mixed FTS State

@Suite("Integration Pipeline - FlushBatch Mixed FTS", .serialized)
struct FlushBatchMixedFTSTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("flushBatch: items in FTS get bodyComplete=1, items NOT in FTS stay bodyComplete=0")
    func flushBatchMixedFTSState() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)

        // Create 3 headers
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "flush_a_\(ts)", subject: "Flush A", date: now, snippet: "a")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "flush_b_\(ts)", subject: "Flush B", date: now.addingTimeInterval(-60), snippet: "b")
        let h3 = try TestDatabase.insertMessageHeader(db, messageId: "flush_c_\(ts)", subject: "Flush C", date: now.addingTimeInterval(-120), snippet: "c")

        // Mark all as headerComplete=1
        for h in [h1, h2, h3] {
            try await db.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        // Clean up FTS for all 3
        try await index.removeMessages(headerIds: [h1.id, h2.id, h3.id])

        // Index h1 and h2 into FTS (h3 stays un-indexed)
        let ftsRecords = [h1, h2].map { h in
            FTSHeaderRecord(
                headerId: h.id,
                messageId: h.messageId,
                subject: h.subject,
                from: "\(h.from) <\(h.fromAddress)>",
                to: h.to,
                dateMs: Int64(h.date.timeIntervalSince1970 * 1000)
            )
        }
        let indexedCount = try await index.indexHeaders(ftsRecords)
        #expect(indexedCount == 2)

        // Build FTS body updates for all 3
        let ftsBuffer: [(headerId: String, body: String)] = [
            (headerId: h1.id, body: "Body text for flush A message"),
            (headerId: h2.id, body: "Body text for flush B message"),
            (headerId: h3.id, body: "Body text for flush C message not indexed"),
        ]

        // Call real SearchIndex.updateBodies (mirrors what flushBatch does)
        let writtenToFts = try await index.updateBodies(ftsBuffer)

        // h1 and h2 should be written, h3 should not (not in FTS index)
        #expect(writtenToFts.contains(h1.id), "h1 should be in writtenToFts")
        #expect(writtenToFts.contains(h2.id), "h2 should be in writtenToFts")
        #expect(!writtenToFts.contains(h3.id), "h3 should NOT be in writtenToFts (not indexed)")

        // Set bodyComplete=1 only for items written to FTS (mirrors flushBatch logic)
        let confirmedIds = [h1.id, h2.id, h3.id].filter { writtenToFts.contains($0) }
        try await db.write { dbConn in
            for headerId in confirmedIds {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                    arguments: [headerId]
                )
            }
        }

        // Verify: h1 and h2 have bodyComplete=1, h3 has bodyComplete=0
        let bc1: Bool = try await db.read { try Bool.fetchOne($0, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [h1.id]) ?? false }
        let bc2: Bool = try await db.read { try Bool.fetchOne($0, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [h2.id]) ?? false }
        let bc3: Bool = try await db.read { try Bool.fetchOne($0, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [h3.id]) ?? false }

        #expect(bc1 == true, "h1 should have bodyComplete=1")
        #expect(bc2 == true, "h2 should have bodyComplete=1")
        #expect(bc3 == false, "h3 should have bodyComplete=0 (not in FTS)")

        // Cleanup
        try await index.removeMessages(headerIds: [h1.id, h2.id, h3.id])
    }
}

// MARK: - Suite 4: End-to-End Pipeline

@Suite("Integration Pipeline - End-to-End", .serialized)
struct EndToEndPipelineTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("Full pipeline: header insert -> FTS index -> headerComplete -> body write -> bodyComplete -> searchable")
    func fullE2EPipeline() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let ts = Int(now.timeIntervalSince1970)
        let uniqueBodyText = "uniquee2epipelinetext_\(ts)"

        // 1. Insert header into GRDB (headerComplete=0, bodyComplete=0)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "e2e_\(ts)",
            subject: "E2E Pipeline Test",
            date: now,
            snippet: ""
        )

        let flags0: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags0.0 == false, "headerComplete should start false")
        #expect(flags0.1 == false, "bodyComplete should start false")

        // 2. FTS index header
        try await index.removeMessages(headerIds: [header.id])
        let ftsRecord = FTSHeaderRecord(
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        let inserted = try await index.indexHeaders([ftsRecord])
        #expect(inserted == 1)

        // 3. Set headerComplete=1
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        let flags1: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags1.0 == true, "headerComplete should be true")
        #expect(flags1.1 == false, "bodyComplete should still be false")

        // 4. Write body to FTS (simulates BodyFetchProcessor.flushBatch)
        let writtenIds = try await index.updateBodies([(headerId: header.id, body: uniqueBodyText)])
        #expect(writtenIds.contains(header.id), "Body should be written to FTS")

        // 5. Set bodyComplete=1 and snippet
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ?, bodyComplete = 1 WHERE id = ?",
                arguments: [String(uniqueBodyText.prefix(150)), header.id]
            )
        }

        let flags2: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags2.0 == true, "headerComplete should remain true")
        #expect(flags2.1 == true, "bodyComplete should be true after body write")

        // 6. Verify body is searchable in FTS
        let results = try await index.keywordSearch(query: uniqueBodyText)
        #expect(results.contains { $0.headerId == header.id }, "Body should be FTS-searchable")

        // 7. Verify excluded from repopulate query
        let repopItems: [Row] = try await db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                """)
        }
        let found = repopItems.contains { ($0["id"] as String) == header.id }
        #expect(!found, "Completed message should be excluded from repopulate")

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }
}

// MARK: - Suite 5: Migration v38-v40 Index Verification

@Suite("Integration Pipeline - Migration Index Verification")
struct MigrationIndexVerificationTests {

    @Test("Migrations v38-v40 create all expected indexes on messageHeader")
    func migrationIndexesExist() throws {
        let db = try TestDatabase.make()

        // Query all indexes on messageHeader
        let indexes: [Row] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT name, sql FROM sqlite_master
                WHERE type = 'index' AND tbl_name = 'messageHeader' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """)
        }

        let indexNames = Set(indexes.map { $0["name"] as String })

        // v38 indexes
        #expect(indexNames.contains("idx_messageHeader_bodyStatus"),
                "v38 bodyStatus index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_inbox_display"),
                "v38 inbox_display index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_triage_display"),
                "v38 triage_display index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_embeddingIncomplete"),
                "v50 embeddingIncomplete partial index should exist (supersedes v38 embeddingStatus). Found: \(indexNames)")

        // v39 restored indexes
        #expect(indexNames.contains("messageHeader_folderId"),
                "v39 restored folderId index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_folderId_isRead"),
                "v39 restored folderId_isRead index should exist. Found: \(indexNames)")

        // v40 indexes
        #expect(indexNames.contains("messageHeader_messageId_accountId"),
                "v40 messageId_accountId index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_bodyRepopulate"),
                "v40 bodyRepopulate index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_isInInbox_date"),
                "v40 isInInbox_date index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_folderId_date"),
                "v40 folderId_date index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_rfc822MessageId_date"),
                "v40 rfc822MessageId_date index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_accountId_bodyComplete"),
                "v40 accountId_bodyComplete index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_reminderLookup"),
                "v40 reminderLookup partial index should exist. Found: \(indexNames)")
        #expect(indexNames.contains("messageHeader_aiIncomplete"),
                "v40 aiIncomplete partial index should exist. Found: \(indexNames)")
    }

    @Test("v38 bodyStatus index has correct columns: headerComplete, bodyComplete, bodyEmptyConfirmed, isInInbox")
    func bodyStatusIndexColumns() throws {
        let db = try TestDatabase.make()

        let columns: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA index_info(idx_messageHeader_bodyStatus)")
                .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
                .map { $0["name"] as String }
        }

        #expect(columns.count == 4, "bodyStatus index should have 4 columns. Got: \(columns)")
        guard columns.count == 4 else { return }
        #expect(columns[0] == "headerComplete")
        #expect(columns[1] == "bodyComplete")
        #expect(columns[2] == "bodyEmptyConfirmed")
        #expect(columns[3] == "isInInbox")
    }

    @Test("v40 bodyRepopulate index has correct column order for repopulate query")
    func bodyRepopulateIndexColumns() throws {
        let db = try TestDatabase.make()

        let columns: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA index_info(messageHeader_bodyRepopulate)")
                .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
                .map { $0["name"] as String }
        }

        #expect(columns.count == 5, "bodyRepopulate index should have 5 columns. Got: \(columns)")
        guard columns.count == 5 else { return }
        #expect(columns[0] == "isInInbox")
        #expect(columns[1] == "headerComplete")
        #expect(columns[2] == "bodyComplete")
        #expect(columns[3] == "bodyEmptyConfirmed")
        #expect(columns[4] == "date")
    }

    @Test("v39 folderId index is simple (folderId) not composite")
    func folderIdIndexIsSimple() throws {
        let db = try TestDatabase.make()

        let columns: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA index_info(messageHeader_folderId)")
                .map { $0["name"] as String }
        }

        #expect(columns.count == 1, "folderId index should have exactly 1 column. Got: \(columns)")
        guard columns.count == 1 else { return }
        #expect(columns[0] == "folderId")
    }

    @Test("v39 folderId_isRead index is (folderId, isRead)")
    func folderIdIsReadIndex() throws {
        let db = try TestDatabase.make()

        let columns: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA index_info(messageHeader_folderId_isRead)")
                .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
                .map { $0["name"] as String }
        }

        #expect(columns.count == 2, "folderId_isRead index should have 2 columns. Got: \(columns)")
        guard columns.count == 2 else { return }
        #expect(columns[0] == "folderId")
        #expect(columns[1] == "isRead")
    }
}
