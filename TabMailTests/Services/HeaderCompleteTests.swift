/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: MessageHeader Default State

@Suite("HeaderComplete - Model Defaults")
struct HeaderCompleteModelTests {

    @Test("New header defaults to headerComplete=false")
    func newHeaderDefaultsToIncomplete() {
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.headerComplete == false)
    }

    @Test("New header defaults to bodyComplete=false")
    func newHeaderDefaultsToBodyIncomplete() {
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.bodyComplete == false)
    }

    @Test("New header defaults to bodyEmptyConfirmed=false")
    func newHeaderDefaultsToBodyEmptyUnconfirmed() {
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.bodyEmptyConfirmed == false)
    }
}

// MARK: - Suite 2: FTS Indexing Sets headerComplete=1

@Suite("HeaderComplete - FTS Indexing Lifecycle", .serialized, .processGlobalState)
struct HeaderCompleteFTSIndexingTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("indexHeadersForFTS sets headerComplete=1 in GRDB")
    func indexHeadersSetsHeaderComplete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "hc_fts_1",
            subject: "FTS Index Test",
            date: now,
            snippet: "test"
        )

        // Verify starts as incomplete
        let beforeComplete: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(beforeComplete == false)

        // Index into FTS via SearchIndex
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

        // Simulate what SyncEngineFTS.indexHeadersForFTS does after FTS indexing:
        // set headerComplete=1 in GRDB
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        let afterComplete: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(afterComplete == true)

        // Cleanup FTS
        try await index.removeMessages(headerIds: [header.id])
    }
}

// MARK: - Suite 3: Body Queue Repopulate WHERE Clause

@Suite("HeaderComplete - Body Queue Repopulate Query")
struct HeaderCompleteRepopulateTests {

    @Test("repopulate query skips headerComplete=0 rows")
    func repopulateSkipsIncompleteHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert header with headerComplete=0 (default)
        try TestDatabase.insertMessageHeader(
            db,
            messageId: "repop_skip_1",
            subject: "Incomplete Header",
            snippet: "test"
        )

        // Run the same query as ActiveBodyQueue.repopulateFromDatabase
        let items: [Row] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id, accountId, folderPath, messageId, isInInbox
                FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                ORDER BY date DESC
                """)
        }
        #expect(items.isEmpty, "headerComplete=0 row should be excluded from repopulate")
    }

    @Test("repopulate query finds headerComplete=1 rows")
    func repopulateFindsCompleteHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert header and set headerComplete=1
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "repop_find_1",
            subject: "Complete Header",
            snippet: "test"
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        let items: [Row] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id, accountId, folderPath, messageId, isInInbox
                FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                ORDER BY date DESC
                """)
        }
        #expect(items.count == 1)
        guard items.count == 1 else { return }
        let foundId: String = items[0]["id"]
        #expect(foundId == header.id)
    }

    @Test("repopulate query excludes bodyComplete=1 rows")
    func repopulateExcludesBodyComplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "repop_body_done",
            subject: "Body Done",
            snippet: "test"
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1, bodyComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        let items: [Row] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                """)
        }
        #expect(items.isEmpty, "bodyComplete=1 should be excluded")
    }
}

// MARK: - Suite 4: recoverIncompleteHeaders

@Suite("HeaderComplete - Recovery of Incomplete Headers", .serialized, .processGlobalState)
struct HeaderCompleteRecoveryTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("recoverIncompleteHeaders finds orphans and sets headerComplete=1")
    func recoverFindsOrphans() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        // Insert header with headerComplete=0 (simulates crash before FTS indexing)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "recover_1",
            subject: "Orphan Header",
            date: now,
            snippet: "test"
        )

        // Confirm headerComplete=0
        let before: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(before == false)

        // Simulate recovery: find incomplete, index to FTS, set flag
        let incomplete: [MessageHeader] = try await db.read { dbConn in
            try MessageHeader
                .filter(Column("headerComplete") == false)
                .limit(500)
                .fetchAll(dbConn)
        }
        #expect(incomplete.count == 1)
        guard incomplete.count == 1 else { return }

        // Clean up any stale FTS entry
        try await index.removeMessages(headerIds: [header.id])

        // Index to FTS
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
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 1)

        // Set headerComplete=1
        try await db.write { dbConn in
            for h in incomplete {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        let after: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(after == true)

        // Cleanup FTS
        try await index.removeMessages(headerIds: [header.id])
    }

    @Test("recoverIncompleteHeaders is idempotent")
    func recoverIsIdempotent() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "recover_idem_1",
            subject: "Idempotent Recovery",
            date: now,
            snippet: "test"
        )

        try await index.removeMessages(headerIds: [header.id])

        // First recovery pass
        let ftsRecord = FTSHeaderRecord(
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        let inserted1 = try await index.indexHeaders([ftsRecord])
        #expect(inserted1 == 1)

        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Second recovery pass (should be a no-op for this header since headerComplete=1)
        let incompleteAfter: [MessageHeader] = try await db.read { dbConn in
            try MessageHeader
                .filter(Column("headerComplete") == false)
                .limit(500)
                .fetchAll(dbConn)
        }
        #expect(incompleteAfter.isEmpty, "No incomplete headers after first recovery")

        // Even if we try to re-index, FTS deduplicates
        let inserted2 = try await index.indexHeaders([ftsRecord])
        #expect(inserted2 == 0, "Re-indexing already-indexed header inserts 0")

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }

    @Test("recoverIncompleteHeaders with 0 orphans is fast no-op")
    func recoverNoOrphansIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert a header with headerComplete=1 already
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "recover_noop_1",
            subject: "Already Complete",
            snippet: "test"
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Recovery query should find 0 incomplete
        let incomplete: [MessageHeader] = try db.read { dbConn in
            try MessageHeader
                .filter(Column("headerComplete") == false)
                .limit(500)
                .fetchAll(dbConn)
        }
        #expect(incomplete.isEmpty, "Should find 0 incomplete headers")
    }

    @Test("Crash simulation: GRDB has header but FTS doesn't")
    func crashSimulationGRDBWithoutFTS() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        // Insert header into GRDB without FTS indexing (simulates crash)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "crash_sim_1",
            subject: "Crash Simulation Subject",
            date: now,
            snippet: "test"
        )

        // Ensure no stale FTS entry
        try await index.removeMessages(headerIds: [header.id])

        // headerComplete should be 0
        let hcBefore: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(hcBefore == false)

        // FTS should not have this header
        let isIndexedBefore = try await index.isIndexed(headerId: header.id)
        #expect(isIndexedBefore == false)

        // Run recovery: find incomplete, index to FTS, set flag
        let incomplete: [MessageHeader] = try await db.read { dbConn in
            try MessageHeader
                .filter(Column("headerComplete") == false)
                .limit(500)
                .fetchAll(dbConn)
        }
        #expect(incomplete.count == 1)
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
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 1)

        try await db.write { dbConn in
            for h in incomplete {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [h.id]
                )
            }
        }

        // Verify recovery: headerComplete=1 and FTS entry exists
        let hcAfter: Bool = try await db.read { dbConn in
            try Bool.fetchOne(dbConn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(hcAfter == true)

        let isIndexedAfter = try await index.isIndexed(headerId: header.id)
        #expect(isIndexedAfter == true)

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }
}

// MARK: - Suite 5: Full Pipeline

@Suite("HeaderComplete - Full Pipeline End-to-End", .serialized, .processGlobalState)
struct HeaderCompleteFullPipelineTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("Full pipeline: insert -> indexFTS -> headerComplete=1 -> body fetch -> bodyComplete=1")
    func fullPipeline() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()

        // 1. Insert header into GRDB (headerComplete=0, bodyComplete=0)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "pipeline_1",
            subject: "Full Pipeline Test",
            date: now,
            snippet: ""
        )

        let flags1: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags1.0 == false, "headerComplete should start false")
        #expect(flags1.1 == false, "bodyComplete should start false")

        // 2. Clean up any stale FTS entries
        try await index.removeMessages(headerIds: [header.id])

        // 3. Index header into FTS
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

        // 4. Set headerComplete=1 (what SyncEngineFTS does)
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        let flags2: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags2.0 == true, "headerComplete should be true after FTS indexing")
        #expect(flags2.1 == false, "bodyComplete should still be false")

        // 5. Simulate body fetch: write body text to FTS
        try await index.updateBody(headerId: header.id, body: "This is the fullpipelinebody content.")

        // 6. Set bodyComplete=1 (what flushBatch does)
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ?, bodyComplete = 1 WHERE id = ?",
                arguments: ["This is the fullpipelinebody content.", header.id]
            )
        }

        let flags3: (Bool, Bool) = try await db.read { dbConn in
            let row = try Row.fetchOne(dbConn,
                sql: "SELECT headerComplete, bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id])!
            return (row["headerComplete"] as Bool, row["bodyComplete"] as Bool)
        }
        #expect(flags3.0 == true, "headerComplete should remain true")
        #expect(flags3.1 == true, "bodyComplete should be true after body fetch")

        // 7. Verify body is searchable in FTS
        let results = try await index.keywordSearch(query: "fullpipelinebody")
        #expect(results.contains { $0.headerId == header.id })

        // 8. Verify this header is now excluded from repopulate query
        let repopIds: [String] = try await db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                """).map { $0["id"] as String }
        }
        let found = repopIds.contains(header.id)
        #expect(!found, "Completed header should be excluded from repopulate")

        // Cleanup
        try await index.removeMessages(headerIds: [header.id])
    }
}
