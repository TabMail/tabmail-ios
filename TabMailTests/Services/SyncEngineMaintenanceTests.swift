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

    // MARK: - Prune Ordering

    @Test("Messages ordered by date ASC for pruning (oldest first)")
    func pruneOrderingOldestFirst() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        _ = try TestDatabase.insertMessageHeader(db, messageId: "1", date: now.addingTimeInterval(-3600))
        _ = try TestDatabase.insertMessageHeader(db, messageId: "2", date: now.addingTimeInterval(-7200))
        _ = try TestDatabase.insertMessageHeader(db, messageId: "3", date: now)

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

    /// The maintenance sweeps reclaim bodies EXPLICITLY as of Stage D
    /// (`v70_dropMessageBodyHeaderFK`): `pruneOldMessages` routes its header ids
    /// through `MessageContentStore.releaseUnowned(…, stores: [.searchIndex,
    /// .body])`. Since #1433 `runEvictStaleBodies` reads only bodies whose header
    /// exists, so a body this leaves behind stays (#1446). Nothing depends on a
    /// cascade any more, and the cascade had to go — it deletes content below the
    /// application layer, where the ownership gate cannot veto it once N headers
    /// can share one content key.
    @Test("Deleting MessageHeader no longer cascades to MessageBody")
    func headerDeletionLeavesBodyToTheSweeps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        try db.write { dbConn in
            _ = try MessageHeader.deleteAll(dbConn, keys: [header.id])
        }

        let body = try db.read { dbConn in
            try MessageBody.fetchOne(dbConn, key: header.id)
        }
        #expect(body != nil, "the schema must not delete cached content as a side effect")
    }

    // MARK: - Stale-body evict page (#1354, #1433)

    /// The evict step's page must seek its own index and come out in that index's
    /// order, for the first page and for every page after the cursor: a `SCAN`
    /// reads every header, and a `TEMP B-TREE` sorts the whole candidate set once
    /// per page. The index is built through the production DDL
    /// (`createDeferredIndexes`), never re-typed here.
    @Test("The stale-body page seeks its index in index order, first page and after the cursor")
    func staleBodyPageSeeksItsIndex() throws {
        let db = try TestDatabase.make()
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        let cutoff = Date()
        let cursorCachedAt = cutoff.addingTimeInterval(-86_400)
        for afterCursor in [false, true] {
            let sql = "EXPLAIN QUERY PLAN " + HTMLCachePair.evictCandidatesPageSQL(afterCursor: afterCursor)
            let arguments: StatementArguments
            if afterCursor {
                arguments = [cutoff, cursorCachedAt, 1, SyncConfig.pruneChunkSize]
            } else {
                arguments = [cutoff, SyncConfig.pruneChunkSize]
            }
            let plan: String = try db.read { dbConn in
                try Row.fetchAll(dbConn, sql: sql, arguments: arguments)
                    .map { $0["detail"] as String }
                    .joined(separator: " | ")
            }
            #expect(plan.contains("USING INDEX \(HTMLCachePair.indexName) (isInInbox=?"),
                    "afterCursor \(afterCursor): the page does not seek its index: \(plan)")
            #expect(!plan.contains("SCAN"), "afterCursor \(afterCursor): the page reads the whole table: \(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "afterCursor \(afterCursor): the page sorts: \(plan)")
        }
    }

    /// The maintenance pass runs the evict step only once its deferred index
    /// exists: without it every page would scan and sort the table inside its
    /// write. The first pass after an upgrade skips the step and builds the index
    /// (inside `runRefreshPlannerStatisticsIfStale`'s write, later in the same
    /// pass); the next pass evicts by the unchanged rules.
    /// `.processGlobalState`: the build gives up while
    /// `DatabaseSuspension.isSuspended`, which `DatabaseSuspensionTests` holds, and
    /// the refresh carries a process-wide single-flight latch.
    @Test("The evict step waits for its index, then evicts", .processGlobalState)
    func evictStepWaitsForItsIndex() async throws {
        let fixture = try StaleBodyEvictWriterHoldTests.makeFixture(buildsDeferredIndexes: false)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try StaleBodyEvictWriterHoldTests.seedArchiveBodies(fixture, count: recent + 1)
        let markerKey = "analyzeMarker-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: markerKey) }

        let ranWithoutIndex = await SyncEngine.runEvictStaleBodiesIfIndexed(dbPool: dbPool, undoProtectedBodyIds: [])
        let beforeIndex = try StaleBodyEvictWriterHoldTests.bodyIds(fixture)
        #expect(!ranWithoutIndex, "the step ran with no index to seek")
        #expect(beforeIndex == Set(archived), "a body was evicted before the index existed")

        let build = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: dbPool, markerKey: markerKey)
        #expect(build == .refreshed)
        let ranWithIndex = await SyncEngine.runEvictStaleBodiesIfIndexed(dbPool: dbPool, undoProtectedBodyIds: [])
        let afterIndex = try StaleBodyEvictWriterHoldTests.bodyIds(fixture)
        #expect(ranWithIndex, "the step did not run once its index existed")
        #expect(afterIndex == Set(archived.prefix(recent)),
                "the archive body past the newest \(recent) is evicted, and only it")
    }

    /// The gate waits for the evict step's own index and no other: with that index
    /// built and every other deferred index still missing, the step runs.
    /// `.processGlobalState`: the gate runs production's checkpoint between pages,
    /// which writes the app's database.
    @Test("The evict step runs once its own index exists, whatever the other deferred indexes", .processGlobalState)
    func evictStepNeedsOnlyItsOwnIndex() async throws {
        let fixture = try StaleBodyEvictWriterHoldTests.makeFixture(buildsDeferredIndexes: false)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try StaleBodyEvictWriterHoldTests.seedArchiveBodies(fixture, count: recent + 1)
        let ownIndex = SyncEngine.deferredIndexes.filter { $0.name == HTMLCachePair.indexName }
        let otherNames = SyncEngine.deferredIndexes.map(\.name).filter { $0 != HTMLCachePair.indexName }
        #expect(ownIndex.count == 1, "the evict step's index is a deferred index")
        #expect(!otherNames.isEmpty, "setup: another deferred index exists to leave missing")
        // The production DDL of the step's index alone, with its fill.
        try await fixture.pool.write { db in try SyncEngine.createDeferredIndexes(db, ownIndex) }
        let present = try await fixture.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        let othersPresent = otherNames.filter { present.contains($0) }
        #expect(present.contains(HTMLCachePair.indexName), "setup: the step's index exists")
        #expect(othersPresent.isEmpty, "setup: every other deferred index is missing: \(othersPresent)")

        let ran = await SyncEngine.runEvictStaleBodiesIfIndexed(dbPool: dbPool, undoProtectedBodyIds: [])
        let after = try StaleBodyEvictWriterHoldTests.bodyIds(fixture)
        #expect(ran, "the step waited for an index other than its own")
        #expect(after == Set(archived.prefix(recent)),
                "the archive body past the newest \(recent) is evicted, and only it")
    }

    /// A schema that cannot be read is unknown, not present: the gate does not run
    /// the step, which without its index would scan the table inside its writes.
    /// No reader can open, so reading the catalog fails, while the writer works:
    /// a step the gate let through would evict.
    /// `.processGlobalState`: a gate that let the step through would run
    /// production's checkpoint between pages, which writes the app's database.
    @Test("The evict step does not run when its index cannot be checked", .processGlobalState)
    func evictStepWaitsWhenItsIndexCannotBeChecked() async throws {
        let fixture = try StaleBodyEvictWriterHoldTests.makeFixture(readersFail: true)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try StaleBodyEvictWriterHoldTests.seedArchiveBodies(fixture, count: recent + 1)
        // Read on the writer: no reader opens.
        func bodyIds() throws -> Set<String> {
            try fixture.pool.write { db in try Set(String.fetchAll(db, sql: "SELECT id FROM messageBody")) }
        }
        let catalogRead = Result {
            try fixture.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0 }
        }
        var catalogReadFailed = false
        if case .failure = catalogRead { catalogReadFailed = true }
        #expect(catalogReadFailed, "setup: the catalog cannot be read")

        let ran = await SyncEngine.runEvictStaleBodiesIfIndexed(dbPool: dbPool, undoProtectedBodyIds: [])
        let afterGate = try bodyIds()
        #expect(!ran, "the step ran though its index could not be checked")
        #expect(afterGate == Set(archived), "a body was evicted though the index could not be checked")

        // Positive control: the writer works, so the step itself evicts here.
        await SyncEngine.runEvictStaleBodies(dbPool: dbPool, undoProtectedBodyIds: [], afterEachPage: StaleBodyEvictWriterHoldTests.noCheckpoint)
        let afterStep = try bodyIds()
        #expect(afterStep == Set(archived.prefix(recent)),
                "setup: the step evicts on this database, so the gate is what held it back")
    }

    /// Production reaches the evict step only through its index gate: a call of
    /// `runEvictStaleBodies` anywhere but inside `runEvictStaleBodiesIfIndexed`
    /// would run its page with no index on a device that has not built it yet.
    /// Call sites are discovered by walking the production tree, never listed.
    @Test("Production runs the evict step only through its index gate")
    func evictStepIsReachedOnlyThroughItsGate() throws {
        var gatedCalls: [String] = []
        var directCalls: [String] = []
        for line in Self.productionCodeLines() where !line.code.contains("func runEvictStaleBodies") {
            if line.code.contains("runEvictStaleBodiesIfIndexed(") {
                gatedCalls.append(line.file)
            } else if line.code.contains("runEvictStaleBodies(") {
                directCalls.append(line.file)
            }
        }
        #expect(gatedCalls == ["SyncEngine.swift"],
                "the maintenance pass must call the gated step, once: \(gatedCalls)")
        #expect(directCalls == ["SyncEngineMaintenance.swift"],
                "the only direct call is the gate's own: \(directCalls)")
    }

    /// Production's checkpoint between the evict's pages (#1354) is the throttled
    /// `PASSIVE` one, `checkpointWALThrottled()` with no `truncate`, the step's
    /// default, and no production caller passes another. One that
    /// did nothing would let a long run grow the WAL by all of its pages again; a
    /// `TRUNCATE`, or a checkpoint past the throttle, can wait on readers while it
    /// holds the writer. The tests that call the step pass their own, and the
    /// default writes the app's database, so only the source shows which one
    /// production runs. Every production line that names `afterEachPage` is
    /// discovered by walking the production tree.
    @Test("Production's evict step checkpoints between pages with the throttled PASSIVE checkpoint, its default, and no caller passes another")
    func evictStepCheckpointsWithTheThrottledCheckpoint() {
        let uses = Self.productionCodeLines()
            .filter { $0.code.contains("afterEachPage") }
            .map { "\($0.file): \($0.code)" }
        let expected = [
            "SyncEngineMaintenance.swift: afterEachPage: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() }",
            "SyncEngineMaintenance.swift: await afterEachPage()",
        ]
        #expect(uses == expected,
                "the step's parameter with its default and its one call, and no caller passing another: \(uses)")
    }

    /// Every line of production code under `TabMail/`, trimmed, with its file's
    /// name. Comment lines are left out.
    static func productionCodeLines() -> [(file: String, code: String)] {
        // …/tabmail-ios/TabMailTests/Services/<this file>
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = projectRoot.appendingPathComponent("TabMail")
        var lines: [(file: String, code: String)] = []
        let walker = FileManager.default.enumerator(at: productionRoot, includingPropertiesForKeys: nil)
        while let entry = walker?.nextObject() as? URL {
            guard entry.pathExtension == "swift",
                  let source = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            for line in source.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                lines.append((entry.lastPathComponent, code))
            }
        }
        return lines
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
