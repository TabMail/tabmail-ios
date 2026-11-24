/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// #1354: what the stale-body evict step keeps, evicts and retries. The step
/// pages through the stale bodies with a keyset cursor on its own index
/// (`staleBodyPageSQL`), one write per page, and the maintenance pass runs it only
/// once that index exists (`runEvictStaleBodiesIfIndexed`). The cost bounds are
/// in `StaleBodyEvictWriterHoldTests`, whose fixture and seed helpers this suite
/// reuses; here every test checks which bodies are left, so a cursor that skips
/// rows, a rule that stops protecting one, or a run that does not stop where it
/// should shows up as a wrong set of bodies.
@Suite("Stale-body evict: what a run keeps, evicts and retries")
struct StaleBodyEvictRunTests {

    typealias Hold = StaleBodyEvictWriterHoldTests

    static func run(_ fixture: Hold.Fixture, undoProtected: Set<String> = []) {
        SyncEngine.runEvictStaleBodies(
            dbPool: PrioritizedDatabase(pool: fixture.pool, priority: .background),
            undoProtectedBodyIds: undoProtected)
    }

    /// A stale body with no header, under the fixture's live Archive folder.
    static func seedOrphanBody(_ fixture: Hold.Fixture, id: String) throws {
        try fixture.pool.write { db in
            try db.execute(
                sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                arguments: [id, Hold.bodyHTML, Hold.staleFetchedAt])
        }
    }

    /// The task of a run, for a SQL function on the writer to cancel.
    final class RunHandle: Sendable {
        private let task = Mutex<Task<Void, Never>?>(nil)

        func set(_ run: Task<Void, Never>) { task.withLock { $0 = run } }
        func cancel() { task.withLock { $0?.cancel() } }
    }

    static func queryPlan(_ db: Database, sql: String, arguments: StatementArguments) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    // MARK: - The cursor

    /// How a shared `fetchedAt` is stored. GRDB stores a `Date` as text. The app
    /// writes no number to this column today, but the column accepts one, and a
    /// number sorts before every text value whatever time it stands for. The cursor
    /// keeps the value as stored, so it compares in the same storage class; a
    /// cursor re-encoded through `Date` would compare a number against text and end
    /// the run after its first page.
    enum TieStorage: String, CaseIterable, Sendable {
        case text
        case number

        var value: DatabaseValue {
            let stale = Hold.staleFetchedAt
            switch self {
            case .text: return stale.databaseValue
            case .number: return stale.timeIntervalSince1970.databaseValue
            }
        }
    }

    /// Every body shares one `fetchedAt`, so only the `rowid` half of the cursor
    /// moves it. The pages are 30 inbox bodies and the 20 newest archive bodies
    /// (all kept); 30 kept archive bodies and 20 victims; 30 victims. A cursor on
    /// `fetchedAt` alone ends after the first page and leaves every victim.
    @Test("Bodies sharing one fetchedAt across three pages: every victim is evicted and every keeper kept",
          arguments: TieStorage.allCases)
    func aTieAcrossThreePages(_ storage: TieStorage) throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let chunk = SyncConfig.pruneChunkSize
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let inboxKept = 30
        let victims = 50
        let tie = storage.value
        try Hold.seedKeptInboxBodies(fixture, uids: 1..<(inboxKept + 1), fetchedAt: tie)
        let archived = try Hold.seedArchiveBodies(fixture, count: recent + victims, fetchedAt: tie)
        let seeded = try Hold.bodyIds(fixture)
        let storedAs = try fixture.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT typeof(fetchedAt) FROM messageBody"))
        }
        let distinctTimes = try fixture.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT fetchedAt) FROM messageBody") ?? 0
        }

        Self.run(fixture)
        let after = try Hold.bodyIds(fixture)

        // Non-vacuous: one shared value, stored in the class under test, over
        // three pages.
        #expect(distinctTimes == 1, "the bodies do not share one fetchedAt: \(distinctTimes)")
        switch storage {
        case .text: #expect(storedAs == ["text"], "stored as \(storedAs)")
        case .number: #expect(storedAs == ["real"] || storedAs == ["integer"], "stored as \(storedAs)")
        }
        #expect(seeded.count > 2 * chunk, "the tie spans \(seeded.count) bodies, under three pages of \(chunk)")

        let keepers = seeded.subtracting(archived.suffix(victims))
        #expect(after == keepers,
                "evicted \(seeded.subtracting(after).count) of \(victims) victims; kept victims: \(after.subtracting(keepers).count), lost keepers: \(keepers.subtracting(after).count)")
    }

    /// The plan the writer uses on a database like a device's: populated, with
    /// statistics. The page after the cursor must seek the full `(fetchedAt, rowid)`
    /// lower bound in the index; a seek on `fetchedAt` alone would visit every row
    /// sharing the cursor's time again on each page.
    @Test("On a populated, analyzed database the page after the cursor seeks (fetchedAt, rowid) in its index")
    func thePageAfterTheCursorSeeksItsFullKeyOnAnAnalyzedDatabase() throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let chunk = SyncConfig.pruneChunkSize
        try Hold.seedKeptInboxBodies(fixture, uids: 1..<(3 * chunk + 1))
        try Hold.seedFreshBodies(fixture, ids: 0..<2_000)
        let cutoff = Date().addingTimeInterval(-Double(SyncConfig.bodyCacheTTLHours) * 3600)

        // The writer runs the page in production, so the plan is read there, right
        // after its own `ANALYZE`.
        let reading = try fixture.pool.write { db -> (statistics: Int, firstPageRows: Int, first: String, afterCursor: String) in
            try db.execute(sql: "ANALYZE")
            let statistics = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sqlite_stat1 WHERE idx = ?",
                arguments: [SyncEngine.staleBodyIndexName]) ?? 0
            let firstArguments: StatementArguments = [cutoff, chunk]
            let firstPage = try Row.fetchAll(
                db, sql: SyncEngine.staleBodyPageSQL(afterCursor: false), arguments: firstArguments)
            let first = try Self.queryPlan(
                db, sql: SyncEngine.staleBodyPageSQL(afterCursor: false), arguments: firstArguments)
            guard let last = firstPage.last else {
                return (statistics, 0, first, "")
            }
            let cursorFetchedAt: DatabaseValue = last["fetchedAt"]
            let cursorRowId: Int64 = last["bodyRowId"]
            let afterCursor = try Self.queryPlan(
                db, sql: SyncEngine.staleBodyPageSQL(afterCursor: true),
                arguments: [cutoff, cursorFetchedAt, cursorRowId, chunk])
            return (statistics, firstPage.count, first, afterCursor)
        }

        #expect(reading.statistics == 1, "ANALYZE recorded no statistics for \(SyncEngine.staleBodyIndexName)")
        #expect(reading.firstPageRows == chunk, "the cursor comes from a full first page: \(reading.firstPageRows)")
        for (name, plan) in [("first page", reading.first), ("after the cursor", reading.afterCursor)] {
            #expect(plan.contains("USING INDEX \(SyncEngine.staleBodyIndexName)"), "\(name): no seek on the index: \(plan)")
            #expect(!plan.contains("SCAN"), "\(name): the page reads the whole table: \(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "\(name): the page sorts: \(plan)")
        }
        #expect(reading.afterCursor.contains("(fetchedAt,rowid)>(?,?)"),
                "after the cursor: the seek does not use the full (fetchedAt, rowid) bound: \(reading.afterCursor)")
    }

    // MARK: - The maintenance pass

    /// The real pass, not its helpers. The first pass after an upgrade finds no
    /// index: it keeps every body, then builds the index and refreshes the planner
    /// statistics over it. The next pass evicts by the unchanged rules.
    /// `.processGlobalState`: the build and the statistics refresh give up while
    /// `DatabaseSuspension.isSuspended`, and the refresh holds a process-wide
    /// single-flight latch and a process-wide marker.
    @Test("The maintenance pass keeps every body, builds the index and its statistics, and the next pass evicts",
          .processGlobalState)
    func theMaintenancePassBuildsTheIndexThenTheNextPassEvicts() async throws {
        let fixture = try Hold.makeFixture(buildsDeferredIndexes: false)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        // The statistics marker is the `schema_version` of the last `ANALYZE`, kept
        // in `UserDefaults.standard`. A fresh database's version can equal one an
        // earlier run recorded, which would skip the refresh, so the marker is
        // cleared for this test and put back after it.
        let defaults = UserDefaults.standard
        let markerKey = SyncEngine.plannerStatisticsSchemaVersionKey
        let savedMarker = defaults.object(forKey: markerKey) as? Int
        defaults.removeObject(forKey: markerKey)
        defer {
            if let savedMarker {
                defaults.set(savedMarker, forKey: markerKey)
            } else {
                defaults.removeObject(forKey: markerKey)
            }
        }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try Hold.seedArchiveBodies(fixture, count: recent + 3)
        let indexName = SyncEngine.staleBodyIndexName

        await SyncEngine.runWALMaintenance(
            dbPool: dbPool, includePrune: false, undoProtectedBodyIds: [], pruneOrder: [:])
        let afterFirstPass = try Hold.bodyIds(fixture)
        let built = try fixture.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: [indexName]) ?? 0
        }
        let statistics = try fixture.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_stat1 WHERE idx = ?", arguments: [indexName]) ?? 0
        }
        #expect(afterFirstPass == Set(archived), "the first pass evicted with no index to seek")
        #expect(built == 1, "the first pass did not build \(indexName)")
        #expect(statistics == 1, "the first pass's statistics do not cover \(indexName)")

        await SyncEngine.runWALMaintenance(
            dbPool: dbPool, includePrune: false, undoProtectedBodyIds: [], pruneOrder: [:])
        let afterSecondPass = try Hold.bodyIds(fixture)
        #expect(afterSecondPass == Set(archived.prefix(recent)),
                "the next pass evicts the archive bodies past the newest \(recent), and only them")
    }

    // MARK: - The rules a page applies

    /// A body the user can still undo onto is kept even when the rules would evict
    /// it. Evicting a body leaves its header as it was: `bodyComplete` stays set,
    /// and the body is fetched again when it is opened.
    @Test("An undo-protected body is kept, and an evicted body's header keeps bodyComplete")
    func anUndoProtectedBodyIsKeptAndHeadersKeepBodyComplete() throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try Hold.seedArchiveBodies(fixture, count: recent + 2)
        #expect(archived.count == recent + 2)
        guard archived.count == recent + 2 else { return }
        let protectedVictim = archived[recent]
        let evictedVictim = archived[recent + 1]
        try fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id IN (?, ?)",
                arguments: [protectedVictim, evictedVictim])
        }

        Self.run(fixture, undoProtected: [protectedVictim])
        let after = try Hold.bodyIds(fixture)
        let complete = try fixture.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM messageHeader WHERE bodyComplete = 1"))
        }

        #expect(after == Set(archived.prefix(recent)).union([protectedVictim]),
                "the undo-protected body must stay and the other victim must go")
        #expect(complete == [protectedVictim, evictedVictim],
                "evicting a body must leave its header's bodyComplete as it was: \(complete)")
    }

    /// A body with no header is evicted only when the account and folder roster
    /// says nothing owns it. When the roster cannot be read the page keeps every
    /// such body, and still applies the ordinary rules to the bodies that have a
    /// header. Once the roster reads again the next run evicts the orphan.
    @Test("An unreadable roster keeps the page's orphan but still evicts its header-backed victim")
    func anUnreadableRosterKeepsTheOrphanOnly() throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let recent = SyncConfig.bodyCacheRecentPerFolder
        // First in page order: the orphan, then the oldest archive body, the
        // page's one header-backed victim.
        let orphan = "\(fixture.accountId):Archive:777777"
        try Self.seedOrphanBody(fixture, id: orphan)
        let archived = try Hold.seedArchiveBodies(fixture, count: recent + 1, oldestFirst: true)
        #expect(archived.count == recent + 1)
        guard archived.count == recent + 1 else { return }
        let kept = Set(archived.dropFirst())

        try fixture.pool.write { db in try db.execute(sql: "ALTER TABLE account RENAME TO account_unreadable") }
        Self.run(fixture)
        let whileUnreadable = try Hold.bodyIds(fixture)
        try fixture.pool.write { db in try db.execute(sql: "ALTER TABLE account_unreadable RENAME TO account") }
        Self.run(fixture)
        let afterRestore = try Hold.bodyIds(fixture)

        #expect(whileUnreadable == kept.union([orphan]),
                "with the roster unreadable the orphan must stay and the header-backed victim must go")
        #expect(afterRestore == kept, "once the roster reads, the orphan nothing owns must go")
    }

    // MARK: - Failure and cancellation

    /// Each page is its own write. A page that fails rolls back whole, including
    /// the deletes it made before the failing row, while the pages before it stay
    /// committed; the run stops, and the next run evicts the page again.
    @Test("A page that fails rolls back alone, and the next run evicts it")
    func aFailedPageRollsBackAloneAndTheNextRunRetriesIt() throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let chunk = SyncConfig.pruneChunkSize
        let recent = SyncConfig.bodyCacheRecentPerFolder
        // Oldest first, so the first two pages are all victims and the newest
        // `recent` come last.
        let archived = try Hold.seedArchiveBodies(fixture, count: 2 * chunk + recent, oldestFirst: true)
        #expect(archived.count == 2 * chunk + recent)
        guard archived.count == 2 * chunk + recent else { return }
        let pageTwo = Set(archived[chunk..<(2 * chunk)])
        let keepers = Set(archived[(2 * chunk)...])
        // A page-two row with page-two victims deleted before it.
        let failing = archived[chunk + chunk / 5]
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER evictFailsOnPageTwo BEFORE DELETE ON messageBody
                WHEN old.id = '\(failing)'
                BEGIN SELECT RAISE(ABORT, 'page two fails'); END
                """)
        }

        Self.run(fixture)
        let afterFailure = try Hold.bodyIds(fixture)
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER temp.evictFailsOnPageTwo")
        }
        Self.run(fixture)
        let afterRetry = try Hold.bodyIds(fixture)

        #expect(afterFailure == pageTwo.union(keepers),
                "page one must stay evicted and page two must be rolled back whole")
        #expect(afterRetry == keepers, "the next run must evict page two")
    }

    /// Cancellation is checked between pages: a run cancelled while it writes a
    /// page finishes that page and starts no other. The cancel comes from inside
    /// the page's write, from a trigger on one of its deletes, so it lands at a
    /// known row.
    @Test("A cancelled run finishes the page it is writing and starts no other")
    func aCancelledRunFinishesItsPageAndStartsNoOther() async throws {
        let fixture = try Hold.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let chunk = SyncConfig.pruneChunkSize
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let archived = try Hold.seedArchiveBodies(fixture, count: 2 * chunk + recent, oldestFirst: true)
        #expect(archived.count == 2 * chunk + recent)
        guard archived.count == 2 * chunk + recent else { return }
        let pageTwo = Set(archived[chunk..<(2 * chunk)])
        let keepers = Set(archived[(2 * chunk)...])
        // A page-one row with page-one victims after it.
        let cancelledOn = archived[chunk / 5]

        let runner = RunHandle()
        try fixture.pool.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction("cancelEvictRunForTest", argumentCount: 0, pure: false) { _ in
                runner.cancel()
                return nil
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER cancelEvictOnPageOne AFTER DELETE ON messageBody
                WHEN old.id = '\(cancelledOn)'
                BEGIN SELECT cancelEvictRunForTest(); END
                """)
        }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        // The run waits for its own handle to be in place before it starts, so the
        // trigger always has a task to cancel.
        let (start, startNow) = AsyncStream<Void>.makeStream()
        let evictRun = Task.detached {
            for await _ in start { break }
            SyncEngine.runEvictStaleBodies(dbPool: dbPool, undoProtectedBodyIds: [])
        }
        runner.set(evictRun)
        startNow.yield(())
        startNow.finish()
        await evictRun.value
        let wasCancelled = evictRun.isCancelled
        let afterCancel = try Hold.bodyIds(fixture)

        Self.run(fixture)
        let afterNextRun = try Hold.bodyIds(fixture)

        #expect(wasCancelled, "the trigger did not cancel the run")
        #expect(afterCancel == pageTwo.union(keepers),
                "the cancelled run must finish page one and leave page two untouched")
        #expect(afterNextRun == keepers, "a run that is not cancelled must evict page two")
    }
}
