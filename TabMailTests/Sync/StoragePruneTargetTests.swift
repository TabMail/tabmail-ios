/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

extension StorageEstimator.SpaceSource {
    /// A measure that reports `bytes` used throughout: no WAL, no empty pages, none gained.
    static func constant(_ bytes: Int64) -> Self {
        Self(reportedBytes: { bytes }, walBytes: { 0 },
             pageTotals: { StorageEstimator.PageTotals(allBytes: 0, emptyBytes: 0) })
    }

    /// The app's measure on a test's own files: the walk of `directory`, and the
    /// WAL file and page totals of the database `pool`.
    static func folder(_ directory: URL, pool: PrioritizedDatabase) -> Self {
        Self(
            reportedBytes: { Int64(StorageEstimator.allocatedSizeMB(of: directory) * 1024 * 1024) },
            walBytes: { StorageEstimator.walFileBytes(ofDatabaseAt: pool.pool.path) },
            pageTotals: { (try? await pool.read { db in try StorageEstimator.PageTotals.read(db) }) ?? nil })
    }
}

/// #1437: the storage prune under an Email Index Limit counts the space Settings
/// reports less the WAL files and empty pages of the email and search databases. It starts at its
/// gate's percentage of the limit (90% in the background processing job, 95% in the
/// foreground maintenance task), deletes until the space is at or below 80% of it,
/// and sees what each batch freed before it checks again. Until #1437 it ran while
/// the walk of the files in Application Support was over the limit, which a delete
/// never shrinks, so every run trimmed every folder to its floor.
///
/// `.serialized` and `.processGlobalState`: the tests set the limit in the standard
/// defaults, and two of them read and write the shared search index.
@Suite("Storage prune: starts at its gate, stops at the target", .serialized, .processGlobalState, .timeLimit(.minutes(3)))
struct StoragePruneTargetTests {
    private typealias Paging = StoragePrunePagingTests

    static let megabyte: Int64 = 1024 * 1024

    /// The limit the tests with a constant measure run under.
    static let budgetMB = 100

    /// Runs `body` under the Email Index Limit `budgetMB` (none for nil), then puts
    /// the saved limit back.
    static func withLimit<T>(
        isolation: isolated (any Actor)? = #isolation, _ budgetMB: Int?, _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
        defer { UserDefaults.standard.set(saved, forKey: StorageEstimator.storageBudgetKey) }
        if let budgetMB {
            StorageEstimator.budgetMB = budgetMB
        } else {
            UserDefaults.standard.removeObject(forKey: StorageEstimator.storageBudgetKey)
        }
        return try await body()
    }

    /// How many times the injected measure was asked.
    final class Calls: Sendable {
        private let count = Mutex(0)
        func next() -> Int { count.withLock { $0 += 1; return $0 } }
        var total: Int { count.withLock { $0 } }
    }

    /// A value a test changes while the measure reads it.
    final class Box<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    static func counts(_ fixture: Paging.Fixture) throws -> (headers: Int, bodies: Int) {
        try Paging.readNow(fixture) { db in
            (headers: try MessageHeader.fetchCount(db), bodies: try MessageBody.fetchCount(db))
        }
    }

    // MARK: - The gates

    struct GateCase: Sendable, CustomTestStringConvertible {
        /// The space used, as a percentage of the limit; nil runs with no limit set.
        let percent: Int?
        let overnightPrunes: Bool
        let foregroundPrunes: Bool

        var testDescription: String {
            percent.map { "\($0)% of the limit" } ?? "no limit, any space used"
        }
    }

    @Test("The overnight prune starts at 90% of the limit, the foreground one at 95%, and neither runs without a limit",
          arguments: [
            GateCase(percent: 89, overnightPrunes: false, foregroundPrunes: false),
            GateCase(percent: 92, overnightPrunes: true, foregroundPrunes: false),
            GateCase(percent: 96, overnightPrunes: true, foregroundPrunes: true),
            GateCase(percent: nil, overnightPrunes: false, foregroundPrunes: false),
          ])
    func eachGateStartsAtItsPercentage(_ gateCase: GateCase) async throws {
        for (gate, expected) in [(StorageEstimator.PruneGate.overnight, gateCase.overnightPrunes),
                                 (.foreground, gateCase.foregroundPrunes)] {
            let fixture = try Paging.makeFixture()
            defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
            try Paging.seedHeaders(
                fixture, path: "Archive",
                rows: Paging.Shape(mode: .uid, count: 3 * Paging.floor, ties: [], pages: 0).rows())
            try Paging.resetBodies(fixture)
            let before = try Self.counts(fixture)

            // Constant: above the target, so a prune that starts runs to the floor.
            let used: Int64 = gateCase.percent.map { Int64(Self.budgetMB) * Self.megabyte * Int64($0) / 100 } ?? Int64.max
            await Self.withLimit(gateCase.percent == nil ? nil : Self.budgetMB) {
                await SyncEngine.runPruneIfOverBudget(
                    dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid],
                    gate: gate, space: .constant(used))
            }
            let after = try Self.counts(fixture)
            let pruned = after.headers < before.headers || after.bodies < before.bodies
            #expect(pruned == expected,
                    "\(gate) at \(gateCase.testDescription): pruned \(pruned), headers \(before.headers) -> \(after.headers), bodies \(before.bodies) -> \(after.bodies)")
        }
    }

    // MARK: - The target, on the app's measure

    /// A body large enough to sit on overflow pages of its own, so deleting it frees
    /// whole pages and the space used falls by about its size.
    static let bodyHexBytes = 6_000

    @Test("Measured as the space reported less the WAL and the empty pages, a daytime prune deletes bodies until the space is at 80% of the limit and stops there, every header kept; before any VACUUM the next daytime prune does not start, with the WAL truncated after the prune or left untruncated and larger than the gap to 95%",
          arguments: [true, false])
    func thePruneStopsAtTheTargetAndDoesNotStartAgain(walTruncated: Bool) async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let perFolder = 600
        for path in ["Archive", "INBOX"] {
            try Paging.seedHeaders(
                fixture, path: path, rows: Paging.Shape(mode: .uid, count: perFolder, ties: [], pages: 0).rows())
        }
        try await fixture.pool.write { db in
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                SELECT id, hex(zeroblob(?)), NULL, ?, NULL FROM messageHeader
                """, arguments: [Self.bodyHexBytes, Date()])
        }
        // As the app's pool: no automatic checkpoint, and the WAL emptied once (the
        // seeding is not what this test measures).
        try await fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let space = StorageEstimator.SpaceSource.folder(fixture.directory, pool: fixture.database)
        let firstMeter = await StorageEstimator.SpaceMeter.start(space)
        let meter = try #require(firstMeter)
        let startUsed = meter.startBytes
        // A limit the space used is at 97% or more of, so both gates start.
        let budgetMB = Int(Double(startUsed) / 0.97 / Double(Self.megabyte))
        try #require(budgetMB >= 1, "setup: \(startUsed) bytes used")
        let budgetBytes = Double(budgetMB) * Double(Self.megabyte)
        let target = budgetBytes * Double(SyncConfig.storagePruneTargetPercent) / 100
        let foregroundStart = budgetBytes * Double(SyncConfig.storagePruneForegroundStartPercent) / 100
        try #require(Double(startUsed) >= foregroundStart, "setup: \(startUsed) bytes used under a limit of \(budgetMB) MB")

        await Self.withLimit(budgetMB) {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space)
        }
        let measuredEnd = await meter.usedBytes()
        let endUsed = try #require(measuredEnd)
        let afterFirst = try Self.counts(fixture)

        // One body page frees about `pruneChunkSize` bodies; the prune checks after
        // each, so it stops within one page below the target.
        let onePage = Double(SyncConfig.pruneChunkSize * 2 * Self.bodyHexBytes)
        #expect(Double(endUsed) <= target, "used \(endUsed) bytes, above the target \(Int(target))")
        #expect(Double(endUsed) >= target - 2 * onePage,
                "used \(endUsed) bytes, more than two body pages below the target \(Int(target)): the prune went on past it")
        #expect(afterFirst.headers == 2 * perFolder, "the header pass deleted \(2 * perFolder - afterFirst.headers) headers")
        #expect(afterFirst.bodies > 2 * Paging.floor, "only \(afterFirst.bodies) bodies left: the prune ran to the floor")

        // The next daytime run: a new walk of the files, which kept their size, less
        // the WAL and the empty pages the prune left. The WAL counts in the walk until
        // a truncating checkpoint, and the maintenance pass's one after a prune
        // (`checkpointWALThrottled`) is throttled, so the run is checked after one and
        // without one, with a WAL larger than the gap between the space used and 95%:
        // every body left rewritten in place, at the same size, so the WAL holds a copy
        // of each while the pages in use stay the same.
        if walTruncated {
            try await fixture.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        } else {
            try await fixture.pool.write { db in
                try db.execute(sql: "UPDATE messageBody SET htmlContent = replace(htmlContent, '0', '1')")
            }
        }
        let walBytes = StorageEstimator.walFileBytes(ofDatabaseAt: fixture.pool.path)
        try #require(walTruncated || Double(walBytes) > foregroundStart - Double(endUsed),
                     "setup: a WAL of \(walBytes) bytes, within the \(Int(foregroundStart) - Int(endUsed)) bytes between the space used and 95%")
        let secondMeter = await StorageEstimator.SpaceMeter.start(space)
        let next = try #require(secondMeter)
        #expect(walTruncated || next.reportedBytes >= meter.reportedBytes,
                "setup: the files shrank from \(meter.reportedBytes) to \(next.reportedBytes) bytes with no VACUUM")
        #expect(Double(next.startBytes) < foregroundStart,
                "the next run starts at \(next.startBytes) bytes used, at or above 95% of the limit (\(Int(foregroundStart))), with \(walBytes) bytes of WAL")
        await Self.withLimit(budgetMB) {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space)
        }
        let afterSecond = try Self.counts(fixture)
        #expect(afterSecond.headers == afterFirst.headers && afterSecond.bodies == afterFirst.bodies,
                "the next daytime prune deleted \(afterFirst.headers - afterSecond.headers) headers and \(afterFirst.bodies - afterSecond.bodies) bodies")
    }

    // MARK: - Each batch's release, and the limit read once

    @Test("Each header batch's search entries are gone before the next check, so the prune deletes only the batches the target needs; a limit removed mid-prune changes nothing",
          arguments: [false, true])
    func eachBatchIsReleasedBeforeTheNextCheck(limitRemovedMidPrune: Bool) async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let rows = 300
        try Paging.seedHeaders(
            fixture, path: "Archive", rows: Paging.Shape(mode: .uid, count: rows, ties: [], pages: 0).rows())
        let ids = try Paging.readNow(fixture) { db in try String.fetchAll(db, sql: "SELECT id FROM messageHeader") }
        try #require(ids.count == rows)
        let keys = ids.map(ContentKey.init(rawValue:))
        defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: keys) } }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
        let indexed = try await SearchIndex.shared.indexHeaders(ids.map { id in
            FTSHeaderRecord(
                contentKey: ContentKey(rawValue: id), headerId: id, messageId: "m-\(id)",
                subject: "prune target test", from: "a@example.com", to: "b@example.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000), folderId: fixture.folderId("Archive"))
        })
        try #require(indexed == rows, "setup: indexed \(indexed) of \(rows)")

        // One megabyte reported per row, and one empty megabyte for each search entry
        // gone, so only the release of a batch lowers the space used. Under a limit of
        // `rows` megabytes the prune starts at 100% and needs 80%: two batches of 50.
        let calls = Calls()
        let space = StorageEstimator.SpaceSource(
            reportedBytes: { Int64(rows) * Self.megabyte },
            walBytes: { 0 },
            pageTotals: {
                if limitRemovedMidPrune && calls.next() == 2 {
                    UserDefaults.standard.removeObject(forKey: StorageEstimator.storageBudgetKey)
                }
                guard let missing = try? await SearchIndex.shared.contentKeysMissingFromFTS(keys) else { return nil }
                return StorageEstimator.PageTotals(allBytes: 0, emptyBytes: Int64(missing.count) * Self.megabyte)
            })
        await Self.withLimit(rows) {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space)
        }

        let needed = (rows - rows * SyncConfig.storagePruneTargetPercent / 100 + SyncConfig.pruneChunkSize - 1)
            / SyncConfig.pruneChunkSize * SyncConfig.pruneChunkSize
        let left = try Paging.readNow(fixture) { db in try String.fetchAll(db, sql: "SELECT id FROM messageHeader") }
        let missing = Set(try await SearchIndex.shared.contentKeysMissingFromFTS(keys))
        let deleted = Set(ids).subtracting(left)
        let deletedButIndexed = deleted.filter { !missing.contains(ContentKey(rawValue: $0)) }
        #expect(left.count == rows - needed,
                "\(rows - left.count) headers deleted, not the \(needed) the target needs")
        #expect(deletedButIndexed.isEmpty, "\(deletedButIndexed.count) deleted headers still in the search index")
        if limitRemovedMidPrune {
            let checks = calls.total
            #expect(checks > 2, "setup: the prune checked \(checks) times, so the limit was not removed mid-prune")
        }
    }

    // MARK: - The older-mail walk

    @Test("The older-mail walk stops once the space used reaches 80% of the limit, and when the space cannot be measured",
          arguments: [(79, false), (80, true), (95, true)])
    func theWalkStopsAtTheTarget(percent: Int, stops: Bool) async throws {
        let used = Int64(Self.budgetMB) * Self.megabyte * Int64(percent) / 100
        let started = await Self.withLimit(Self.budgetMB) { await StorageEstimator.WalkCheck.start(.constant(used)) }
        let check = try #require(started)
        let reached = await check.reached()
        #expect(reached == stops, "\(percent)% of the limit: the walk stops \(reached)")

        let unreadable = StorageEstimator.SpaceSource(reportedBytes: { 0 }, walBytes: { 0 }, pageTotals: { nil })
        let blindStart = await Self.withLimit(Self.budgetMB) { await StorageEstimator.WalkCheck.start(unreadable) }
        let blind = try #require(blindStart)
        let blindReached = await blind.reached()
        #expect(blindReached, "a walk that cannot measure the space loads on")
    }

    // MARK: - The measure

    @Test("The space used falls as soon as a delete commits, while the files keep their size")
    func theSpaceUsedFallsWhenADeleteCommits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("space.sqlite").path)
        // Large enough that a row is mostly overflow pages of its own.
        let rowBytes = 40_000
        let autoVacuum = try await queue.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }
        try #require(autoVacuum == 0, "setup: auto_vacuum is \(String(describing: autoVacuum)), not NONE")
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE blob (id INTEGER PRIMARY KEY, data BLOB)")
            for _ in 0..<200 {
                try db.execute(sql: "INSERT INTO blob (data) VALUES (zeroblob(?))", arguments: [rowBytes])
            }
        }
        let space = StorageEstimator.SpaceSource(
            reportedBytes: { Int64(StorageEstimator.allocatedSizeMB(of: directory) * 1024 * 1024) },
            walBytes: { StorageEstimator.walFileBytes(ofDatabaseAt: queue.path) },
            pageTotals: { (try? await queue.read { db in try StorageEstimator.PageTotals.read(db) }) ?? nil })
        let started = await StorageEstimator.SpaceMeter.start(space)
        let meter = try #require(started)

        try await queue.write { db in try db.execute(sql: "DELETE FROM blob WHERE id % 2 = 0") }
        let measured = await meter.usedBytes()
        let used = try #require(measured)
        let reportedAfter = space.reportedBytes()

        #expect(meter.startBytes - used >= Int64(100 * rowBytes) * 9 / 10,
                "the space used fell by \(meter.startBytes - used) bytes after deleting 100 rows of \(rowBytes)")
        #expect(reportedAfter == meter.reportedBytes,
                "the files went from \(meter.reportedBytes) to \(reportedAfter) bytes")
    }

    @Test("The measure leaves out the WAL files read at the run's start, and the empty pages read now")
    func theMeasureLeavesOutTheWALAndTheEmptyPages() async throws {
        let mb = Self.megabyte
        let pages = Box(StorageEstimator.PageTotals(allBytes: 50 * mb, emptyBytes: 10 * mb))
        let wal = Box(30 * mb)
        let space = StorageEstimator.SpaceSource(
            reportedBytes: { 100 * mb }, walBytes: { wal.current }, pageTotals: { pages.current })
        let started = await StorageEstimator.SpaceMeter.start(space)
        let meter = try #require(started)
        #expect(meter.startBytes == 60 * mb, "100 MB reported, 30 MB of WAL, 10 MB empty: \(meter.startBytes) bytes")

        // A delete: the WAL grows, more pages are empty. The walk's WAL stays the one subtracted.
        wal.set(45 * mb)
        pages.set(StorageEstimator.PageTotals(allBytes: 50 * mb, emptyBytes: 20 * mb))
        let afterDelete = await meter.usedBytes()
        #expect(afterDelete == 50 * mb, "10 MB more empty: \(String(describing: afterDelete)) bytes")

        // Then 5 MB of new pages: they count, as the walk never saw them.
        pages.set(StorageEstimator.PageTotals(allBytes: 55 * mb, emptyBytes: 20 * mb))
        let afterGrowth = await meter.usedBytes()
        #expect(afterGrowth == 55 * mb, "5 MB of pages gained: \(String(describing: afterGrowth)) bytes")
    }

    @Test("The app's page totals and WAL files are the email database's and the search database's together")
    func theAppCountsBothDatabases() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let measuredEmail = try Paging.readNow(fixture) { db in try StorageEstimator.PageTotals.read(db) }
        let measuredSearch = await SearchIndex.shared.pageTotals()
        let app = StorageEstimator.SpaceSource.app(pool: fixture.database)
        let measuredBoth = await app.pageTotals()
        let email = try #require(measuredEmail)
        let search = try #require(measuredSearch)
        let both = try #require(measuredBoth)
        #expect(search.allBytes > 0 && email.allBytes > 0, "setup: email \(email), search \(search)")
        #expect(both == email + search, "both \(both), email \(email) + search \(search)")

        let emailWAL = StorageEstimator.walFileBytes(ofDatabaseAt: fixture.pool.path)
        let searchWAL = await SearchIndex.shared.walFileBytes()
        let bothWAL = await app.walBytes()
        #expect(emailWAL > 0, "setup: the test database has no WAL file")
        #expect(bothWAL == emailWAL + searchWAL, "both \(bothWAL), email \(emailWAL) + search \(searchWAL)")
    }
}
