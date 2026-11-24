/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

extension StorageEstimator.SpaceSource {
    /// A measure that reports `bytes` used throughout: no database files, no pages.
    static func constant(_ bytes: Int64) -> Self {
        Self(reportedBytes: { bytes }, databaseFileBytes: { 0 },
             pageTotals: { StorageEstimator.PageTotals(allBytes: 0, emptyBytes: 0) })
    }

    /// The app's measure on a test's own files: the walk of `directory`, and the
    /// database and WAL files and page totals of the database `pool`.
    static func folder(_ directory: URL, pool: PrioritizedDatabase) -> Self {
        Self(
            reportedBytes: { Int64(StorageEstimator.allocatedSizeMB(of: directory) * 1024 * 1024) },
            databaseFileBytes: { StorageEstimator.databaseFileBytes(ofDatabaseAt: pool.pool.path) },
            pageTotals: { (try? await pool.read { db in try StorageEstimator.PageTotals.read(db) }) ?? nil })
    }

    /// A measure that counts what it is asked: the folder walks (`reported`), and
    /// every read of the database files and page totals (`reads`).
    static func counting(
        _ bytes: Int64, reported: StoragePruneTargetTests.Calls, reads: StoragePruneTargetTests.Calls
    ) -> Self {
        Self(reportedBytes: { _ = reported.next(); return bytes },
             databaseFileBytes: { _ = reads.next(); return 0 },
             pageTotals: { _ = reads.next(); return StorageEstimator.PageTotals(allBytes: 0, emptyBytes: 0) })
    }
}

/// The size on disk of the file at `path`; 0 when there is none.
private func allocatedBytes(_ path: String) -> Int64 {
    let allocated = try? URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
    return Int64(allocated ?? 0)
}

/// The size on disk of the WAL file of the database at `path`; 0 when there is none.
private func walFileBytes(ofDatabaseAt path: String) -> Int64 {
    allocatedBytes(path + "-wal")
}

/// #1437: the storage prune under an Email Index Limit counts the space Settings
/// reports with the email and search databases counted by the data they hold: the
/// space reported less their files and WAL files on disk, plus their pages less
/// their empty pages. It starts at its
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

    /// The same counts from inside a run's callback; nil if the read fails.
    static func counts(_ pool: DatabasePool) async -> (headers: Int, bodies: Int)? {
        try? await pool.read { db in
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

    @Test("The overnight prune starts at 90% of the limit, the foreground one at 95%, and neither runs, nor measures, without a limit",
          arguments: [
            GateCase(percent: 89, overnightPrunes: false, foregroundPrunes: false),
            GateCase(percent: 90, overnightPrunes: true, foregroundPrunes: false),
            GateCase(percent: 92, overnightPrunes: true, foregroundPrunes: false),
            GateCase(percent: 94, overnightPrunes: true, foregroundPrunes: false),
            GateCase(percent: 95, overnightPrunes: true, foregroundPrunes: true),
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
                    gate: gate, space: .constant(used), afterEachBatch: {})
            }
            let after = try Self.counts(fixture)
            let pruned = after.headers < before.headers || after.bodies < before.bodies
            #expect(pruned == expected,
                    "\(gate) at \(gateCase.testDescription): pruned \(pruned), headers \(before.headers) -> \(after.headers), bodies \(before.bodies) -> \(after.bodies)")
        }
    }

    @Test("With no limit set, neither the prune nor the older-mail walk's check measures anything")
    func nothingIsMeasuredWithoutALimit() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let walks = Calls(), reads = Calls()
        let space = StorageEstimator.SpaceSource.counting(Int64.max, reported: walks, reads: reads)
        let check = await Self.withLimit(nil) { () -> StorageEstimator.WalkCheck? in
            for gate in [StorageEstimator.PruneGate.overnight, .foreground] {
                await SyncEngine.runPruneIfOverBudget(
                    dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: gate, space: space,
                    afterEachBatch: {})
            }
            return await StorageEstimator.WalkCheck.start(space)
        }
        #expect(check == nil, "the walk has a storage check with no limit set")
        #expect(walks.total == 0 && reads.total == 0,
                "\(walks.total) walks of the storage folder and \(reads.total) database reads with no limit set")
    }

    // MARK: - Between batches

    /// What the run does after each batch: the counts of headers and bodies each
    /// time it calls `afterEachBatch`.
    final class Batches: Sendable {
        private let marks = Mutex<[(headers: Int, bodies: Int)]>([])
        func mark(_ counts: (headers: Int, bodies: Int)) { marks.withLock { $0.append(counts) } }
        var all: [(headers: Int, bodies: Int)] { marks.withLock { $0 } }
    }

    @Test("The prune calls its checkpoint after every page of bodies and every batch of headers, and writes nothing after the last call")
    func thePruneCheckpointsAfterEachBatch() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        try Paging.seedHeaders(
            fixture, path: "Archive", rows: Paging.Shape(mode: .uid, count: 3 * Paging.floor, ties: [], pages: 0).rows())
        try Paging.resetBodies(fixture)
        let before = try Self.counts(fixture)
        let batches = Batches()
        let pool = fixture.pool
        await Self.withLimit(Self.budgetMB) {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground,
                space: .constant(Int64.max),
                afterEachBatch: { if let counts = await Self.counts(pool) { batches.mark(counts) } })
        }
        let after = try Self.counts(fixture)
        let marks = batches.all
        let chunk = SyncConfig.pruneChunkSize
        #expect(after.headers < before.headers && after.bodies < before.bodies,
                "setup: the prune ran to the floor: headers \(before.headers) -> \(after.headers), bodies \(before.bodies) -> \(after.bodies)")
        #expect(marks.count >= 2, "the prune called its checkpoint \(marks.count) times")
        guard let last = marks.last else { return }
        #expect(last.headers == after.headers && last.bodies == after.bodies,
                "the prune wrote after its last checkpoint: \(last) then \(after)")
        // Between two calls, at most one batch: a page of bodies, or a batch of
        // headers with their bodies.
        var previous = before
        for (index, mark) in marks.enumerated() {
            let headersGone = previous.headers - mark.headers, bodiesGone = previous.bodies - mark.bodies
            #expect(headersGone <= chunk && bodiesGone <= chunk,
                    "call \(index + 1): \(headersGone) headers and \(bodiesGone) bodies deleted since the call before, more than one batch of \(chunk)")
            previous = mark
        }
    }

    @Test("A prune cancelled after its first batch deletes no further batch")
    func aCancelledPruneStopsAfterTheBatchInHand() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        try Paging.seedHeaders(
            fixture, path: "Archive", rows: Paging.Shape(mode: .uid, count: 3 * Paging.floor, ties: [], pages: 0).rows())
        try Paging.resetBodies(fixture)
        let before = try Self.counts(fixture)
        let batches = Batches()
        let pool = fixture.pool
        let database = fixture.database, accountId = fixture.accountId
        // Its own task, so the cancel in the callback stops the prune and not the test.
        let prune = Task {
            await Self.withLimit(Self.budgetMB) {
                await SyncEngine.runPruneIfOverBudget(
                    dbPool: database, pruneOrder: [accountId: .uid], gate: .foreground,
                    space: .constant(Int64.max),
                    afterEachBatch: {
                        if let counts = await Self.counts(pool) { batches.mark(counts) }
                        withUnsafeCurrentTask { $0?.cancel() }
                    })
            }
        }
        await prune.value
        let after = try Self.counts(fixture)
        let marks = batches.all
        #expect(marks.count == 1, "the cancelled prune went on to \(marks.count) batches")
        #expect(before.bodies - after.bodies <= SyncConfig.pruneChunkSize && after.headers == before.headers,
                "the cancelled prune deleted \(before.bodies - after.bodies) bodies and \(before.headers - after.headers) headers")
    }

    // MARK: - The target, on the app's measure

    /// A body large enough to sit on overflow pages of its own, so deleting it frees
    /// whole pages and the space used falls by about its size.
    static let bodyHexBytes = 6_000

    @Test("Measured as the space reported with each database counted by the data it holds, a daytime prune deletes bodies until the space is at 80% of the limit and stops there, every header kept; before any VACUUM the next daytime prune does not start, with the WAL truncated after the prune or left untruncated and larger than the gap to 95%",
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
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space,
                afterEachBatch: {})
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
        // the database and WAL files, plus the data the database holds. The WAL counts
        // in the walk until a truncating checkpoint, which the app's throttled
        // checkpoints rarely are, so the run is checked after one and without one,
        // with a WAL larger than the gap between the space used and 95%: every body
        // left rewritten in place, at the same size, so the WAL holds a copy of each
        // while the pages in use stay the same.
        if walTruncated {
            try await fixture.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        } else {
            try await fixture.pool.write { db in
                try db.execute(sql: "UPDATE messageBody SET htmlContent = replace(htmlContent, '0', '1')")
            }
        }
        let walBytes = walFileBytes(ofDatabaseAt: fixture.pool.path)
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
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space,
                afterEachBatch: {})
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
        // The shared search index: entries a failed run left are removed here, and
        // this run's at its end, awaited, so the next test never overlaps it.
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
        let walks = Calls()
        let space = StorageEstimator.SpaceSource(
            reportedBytes: { _ = walks.next(); return Int64(rows) * Self.megabyte },
            databaseFileBytes: { 0 },
            pageTotals: {
                if limitRemovedMidPrune && calls.next() == 2 {
                    UserDefaults.standard.removeObject(forKey: StorageEstimator.storageBudgetKey)
                }
                guard let missing = try? await SearchIndex.shared.contentKeysMissingFromFTS(keys) else { return nil }
                return StorageEstimator.PageTotals(allBytes: 0, emptyBytes: Int64(missing.count) * Self.megabyte)
            })
        await Self.withLimit(rows) {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: .uid], gate: .foreground, space: space,
                afterEachBatch: {})
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
        let checks = calls.total
        if limitRemovedMidPrune {
            #expect(checks > 2, "setup: the prune checked \(checks) times, so the limit was not removed mid-prune")
        }
        #expect(walks.total == 1, "the prune walked the storage folder \(walks.total) times in one run, with \(checks) checks")
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
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

        let unreadable = StorageEstimator.SpaceSource(reportedBytes: { 0 }, databaseFileBytes: { 0 }, pageTotals: { nil })
        let blindStart = await Self.withLimit(Self.budgetMB) { await StorageEstimator.WalkCheck.start(unreadable) }
        let blind = try #require(blindStart)
        let blindReached = await blind.reached()
        #expect(blindReached, "a walk that cannot measure the space loads on")
    }

    struct WalkCase: Sendable, CustomTestStringConvertible {
        /// The space used, as a percentage of the limit; nil runs with no limit set.
        let percent: Int?
        let loads: Bool

        var testDescription: String {
            percent.map { "\($0)% of the limit" } ?? "no limit"
        }
    }

    @Test("The older-mail walk loads mail with the space used below 80% of the limit and none from 80%, measuring once per run, and nothing with no limit",
          arguments: [WalkCase(percent: 79, loads: true), WalkCase(percent: 80, loads: false), WalkCase(percent: nil, loads: true)])
    func theWalkLoadsMailOnlyBelowTheTarget(_ walkCase: WalkCase) async throws {
        typealias F = BackfillPageWalkFixture
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "storage-walk"
        let server = StatefulGmailActionServer(messages: [
            F.gmailSeed("w1", label: "INBOX", daysAgo: 1),
            F.gmailSeed("w2", label: "INBOX", daysAgo: 2),
            F.gmailSeed("w3", label: "INBOX", daysAgo: 3),
        ])
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        let used = walkCase.percent.map { Int64(Self.budgetMB) * Self.megabyte * Int64($0) / 100 } ?? Int64.max
        let walks = Calls(), reads = Calls()
        await Self.withLimit(walkCase.percent == nil ? nil : Self.budgetMB) {
            _ = await engine.runBackfillWalk(
                account: account, deadline: F.deadline(),
                space: .counting(used, reported: walks, reads: reads))
        }

        let loaded = try F.messageIds(accountId, "INBOX", pool: pool)
        let expected: Set<String> = walkCase.loads ? ["w1", "w2", "w3"] : []
        #expect(loaded == expected,
                "\(walkCase.testDescription): the walk loaded \(loaded.sorted())")
        let walked = walks.total, measured = reads.total
        if walkCase.percent == nil {
            #expect(walked == 0 && measured == 0,
                    "no limit: \(walked) walks of the storage folder and \(measured) database reads")
        } else {
            #expect(walked == 1, "\(walkCase.testDescription): \(walked) walks of the storage folder in one run")
        }
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
            databaseFileBytes: { StorageEstimator.databaseFileBytes(ofDatabaseAt: queue.path) },
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

    @Test("The measure is the space reported less the database files read at the run's start, plus the data the databases hold now: a delete lowers it, new pages raise it, a VACUUM leaves it")
    func theMeasureCountsTheDataTheDatabasesHold() async throws {
        let mb = Self.megabyte
        // 100 MB reported: 30 MB of other files, a 50 MB database file and a 20 MB
        // WAL. The database holds 50 MB of pages, 10 MB of them empty.
        let pages = Box(StorageEstimator.PageTotals(allBytes: 50 * mb, emptyBytes: 10 * mb))
        let files = Box(70 * mb)
        let space = StorageEstimator.SpaceSource(
            reportedBytes: { 100 * mb }, databaseFileBytes: { files.current }, pageTotals: { pages.current })
        let started = await StorageEstimator.SpaceMeter.start(space)
        let meter = try #require(started)
        #expect(meter.startBytes == 70 * mb, "30 MB of other files and 40 MB of data: \(meter.startBytes) bytes")

        // A delete: the WAL grows, 10 MB more pages are empty. The files read at the
        // start stay the ones subtracted.
        files.set(85 * mb)
        pages.set(StorageEstimator.PageTotals(allBytes: 50 * mb, emptyBytes: 20 * mb))
        let afterDelete = await meter.usedBytes()
        #expect(afterDelete == 60 * mb, "10 MB more empty: \(String(describing: afterDelete)) bytes")

        // Then 5 MB of new pages: they count.
        pages.set(StorageEstimator.PageTotals(allBytes: 55 * mb, emptyBytes: 20 * mb))
        let afterGrowth = await meter.usedBytes()
        #expect(afterGrowth == 65 * mb, "5 MB of pages gained: \(String(describing: afterGrowth)) bytes")

        // A VACUUM: the empty pages are gone and the database is 35 MB of pages, the
        // same data. The measure stays where it was, whatever size the files are.
        files.set(120 * mb)
        pages.set(StorageEstimator.PageTotals(allBytes: 35 * mb, emptyBytes: 0))
        let afterVacuum = await meter.usedBytes()
        #expect(afterVacuum == 65 * mb, "the same data after a VACUUM: \(String(describing: afterVacuum)) bytes")
    }

    @Test("A database's files are its database file and its WAL file on disk")
    func aDatabasesFilesAreItsFileAndItsWAL() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let path = fixture.pool.path
        let wal = walFileBytes(ofDatabaseAt: path)
        #expect(wal > 0, "setup: the test database has no WAL file")
        #expect(StorageEstimator.databaseFileBytes(ofDatabaseAt: path) == allocatedBytes(path) + wal,
                "database file \(allocatedBytes(path)) bytes, WAL \(wal) bytes")
    }

    @Test("The app's page totals and database files are the email database's and the search database's together")
    func theAppCountsBothDatabases() async throws {
        let fixture = try Paging.makeFixture()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let app = StorageEstimator.SpaceSource.app(pool: fixture.database)
        // The search database is the app's own, which another suite can write while
        // this one reads it: what the app counts for it must lie between a read
        // before and a read after (one value when nothing wrote it meanwhile).
        let measuredEmail = try Paging.readNow(fixture) { db in try StorageEstimator.PageTotals.read(db) }
        let measuredSearchBefore = await SearchIndex.shared.pageTotals()
        let measuredBoth = await app.pageTotals()
        let measuredSearchAfter = await SearchIndex.shared.pageTotals()
        let email = try #require(measuredEmail)
        let searchBefore = try #require(measuredSearchBefore)
        let both = try #require(measuredBoth)
        let searchAfter = try #require(measuredSearchAfter)
        #expect(searchBefore.allBytes > 0 && email.allBytes > 0, "setup: email \(email), search \(searchBefore)")
        #expect(Self.between(both.allBytes - email.allBytes, searchBefore.allBytes, searchAfter.allBytes)
                    && Self.between(both.emptyBytes - email.emptyBytes, searchBefore.emptyBytes, searchAfter.emptyBytes),
                "both \(both), email \(email), search \(searchBefore) then \(searchAfter)")

        let emailFiles = StorageEstimator.databaseFileBytes(ofDatabaseAt: fixture.pool.path)
        let searchFilesBefore = await SearchIndex.shared.databaseFileBytes()
        let bothFiles = await app.databaseFileBytes()
        let searchFilesAfter = await SearchIndex.shared.databaseFileBytes()
        #expect(emailFiles > 0 && searchFilesBefore > 0, "setup: email \(emailFiles), search \(searchFilesBefore) bytes")
        #expect(Self.between(bothFiles - emailFiles, searchFilesBefore, searchFilesAfter),
                "both \(bothFiles), email \(emailFiles), search \(searchFilesBefore) then \(searchFilesAfter)")
    }

    private static func between(_ value: Int64, _ first: Int64, _ second: Int64) -> Bool {
        min(first, second) <= value && value <= max(first, second)
    }
}
