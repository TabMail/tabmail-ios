/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing
@testable import TabMail

/// #1433: the stale-body evict through the HTML-cache pair (`HTMLCachePair`: migration
/// v116 adds its column and triggers, the maintenance pass's deferred step fills it and
/// builds its index) against the evict it replaced, which walked every cached body older than the
/// TTL and read each one's header (#1427), on the proof database (`DBProof`) at about
/// 105,000 and 525,000 headers with a body cache seeded the way a synced phone holds it.
///
/// Three schemas, from one database:
/// - old: the schema before v116, with `messageBody_staleEvict`, as a phone holds it
///   today. The old step runs (`StaleBodyEvictDifferentialTests.legacyEvictPage`), one
///   write per page as it ran.
/// - pair (isInInbox, htmlCachedAt): the same file after the app's migration chain ran
///   v116 on it and the maintenance pass's deferred step ran
///   (`SyncEngine.runRefreshPlannerStatisticsIfStale`: the fill, the index and `ANALYZE`
///   in one write), then without `messageBody_staleEvict` (nothing reads it any more).
///   The production step runs.
/// - pair (htmlCachedAt): the same with the index on the column alone, the other shape
///   the issue left to this measurement.
///
/// Reported per schema: the evict pass (rows visited, statements, pages read, wall
/// time, how long each write holds SQLite's writer); what the triggers and the index add
/// to the writes that touch either table (a body save, re-save and delete, a header
/// merge batch, inbox moves both ways, an IMAP move that carries its body, a message
/// delete, a whole-table wipe and an account removal in both orders, and a UIDVALIDITY
/// reset in both orders); the
/// migration's time, the deferred step's time (whole, and the fill, the index and
/// `ANALYZE` apart, per MB of body pages), the pages the column and each index take;
/// and the plans. Then, at about 105,000 headers only, v116 and the deferred step again
/// with larger HTML (`Config.largerHTMLBytes`), so the report shows whether the step's
/// time per MB of body pages holds as bodies grow.
///
/// Enabled only when `TEST_RUNNER_TABMAIL_DB_PROOF_DIR` is set; writes
/// `<dir>/ios-evict-kept-walk-repeat/report.txt` and removes its database files after
/// each size. Test tooling only.
// `.processGlobalState`: the deferred step holds a process-wide single-flight latch and
// gives up while `DatabaseSuspension.isSuspended`.
@Suite("Stale-body evict: the HTML-cache pair against the body walk, measured (#1433)",
       .enabled(if: DBProof.outputDirectory != nil), .serialized, .processGlobalState)
struct StaleBodyEvictPairProofTests {

    typealias Legacy = StaleBodyEvictDifferentialTests

    static let unit = "ios-evict-kept-walk-repeat"

    enum Config {
        /// The body cache's history (as #1427 measured it): the first sync fetched the
        /// bodies of all older mail, newest first, `initialFetchSpacing` seconds apart;
        /// a later message's body was fetched `arrivalFetchDelay` seconds after it
        /// arrived.
        static let installDaysAgo: Double = 30
        static let initialFetchSpacing: Double = 0.5
        static let arrivalFetchDelay: Double = 30
        /// One whole cycle of a 4,096-byte page's overflow layout (see #1427).
        static let htmlBytes = 4_200..<8_292
        /// The extra data point's HTML: about 32 KB per body, nearer real HTML mail
        /// (newsletters especially) than `htmlBytes`.
        static let largerHTMLBytes = 24_000..<40_000
        static let seed: UInt64 = 0x1433
        /// The last migration before the pair: the old schema.
        static let oldSchemaMigration = "v115_addUserLabelLastUsed"
        /// The deferred indexes a phone on the old schema has: every one but the pair's.
        static let oldDeferredIndexes = SyncEngine.deferredIndexes.filter { $0.name != HTMLCachePair.indexName }
        /// The old step's index (#1354), built by the old maintenance pass.
        static let oldIndexName = "messageBody_staleEvict"
        static let oldIndexSQL = "CREATE INDEX IF NOT EXISTS messageBody_staleEvict ON messageBody(fetchedAt)"
        static let pairIndexName = "messageHeader_htmlCachedAt"
        static let columnOnlyIndexName = "messageHeader_htmlCachedAtOnly"
        static let columnOnlySetupSQL = [
            "DROP INDEX messageHeader_htmlCachedAt",
            "CREATE INDEX messageHeader_htmlCachedAtOnly ON messageHeader(htmlCachedAt)",
        ]
        /// Rows each timed write touches, per kind.
        static let writeBatch = 200
        /// Timed runs of a whole-table wipe or a folder reset (each rewrites much of
        /// the file, so fewer than `DBProof.repeats`).
        static let bulkRepeats = 3
        /// The reset's folder: the IMAP account's inbox (`DBProof.Shape.large`'s second
        /// account), the folder with the most cached bodies an IMAP reset can hit.
        static let resetAccountIndex = 1
        static let resetFolderPath = "INBOX"
        static let movedToFolderPath = "Archive"
    }

    /// `DBProof.Shape.large` (105,000 headers) and the same accounts at five times the size.
    static let databases: [(name: String, shape: DBProof.Shape)] = [
        ("105k", .large),
        ("525k", DBProof.Shape(
            accounts: DBProof.Shape.large.accounts.map {
                DBProof.AccountShape(provider: $0.provider, headers: $0.headers * 5, inboxShare: $0.inboxShare)
            },
            labels: DBProof.Shape.defaultLabels,
            otherFolders: DBProof.Shape.defaultOtherFolders)),
    ]

    enum Schema: String, CaseIterable, Sendable {
        case old
        case pairInboxFirst
        case pairColumnOnly

        var label: String {
            switch self {
            case .old: return "old (body walk, messageBody_staleEvict)"
            case .pairInboxFirst: return "pair, index (isInInbox, htmlCachedAt)"
            case .pairColumnOnly: return "pair, index (htmlCachedAt)"
            }
        }

        var fileTag: String {
            switch self {
            case .old: return "old"
            case .pairInboxFirst: return "pair-a"
            case .pairColumnOnly: return "pair-b"
            }
        }
    }

    // MARK: - The body cache

    struct CacheCensus {
        var inbox = 0
        var folderNewest = 0
        var fresh = 0
        var total: Int { inbox + folderNewest + fresh }
    }

    /// Seeds `messageBody` as the steady state of a synced phone (as #1427 did): a body
    /// for every complete message (`bodyComplete`) the rules keep (in an inbox, or among
    /// its folder's `SyncConfig.bodyCacheRecentPerFolder` newest), and for every other
    /// complete message that arrived within the TTL. Rows go in in fetch order.
    static func seedBodies(at url: URL, anchor: Date, htmlBytes: Range<Int> = Config.htmlBytes) throws -> CacheCensus {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.write { db in
            let ttlStart = anchor.addingTimeInterval(-Double(SyncConfig.bodyCacheTTLHours) * 3_600)
            let install = anchor.addingTimeInterval(-Config.installDaysAgo * DBProof.Config.secondsPerDay)
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, isInInbox, date, folderRank FROM (
                    SELECT id, isInInbox, bodyComplete, date,
                           row_number() OVER (PARTITION BY folderId ORDER BY date DESC) AS folderRank
                    FROM messageHeader)
                WHERE bodyComplete = 1
                """)
            var census = CacheCensus()
            var firstSync: [(id: String, date: Date)] = []
            var bodies: [(id: String, fetchedAt: Date)] = []
            while let row = try rows.next() {
                let id: String = row["id"]
                let isInInbox: Bool = row["isInInbox"]
                let date: Date = row["date"]
                let folderRank: Int = row["folderRank"]
                if isInInbox {
                    census.inbox += 1
                } else if folderRank <= SyncConfig.bodyCacheRecentPerFolder {
                    census.folderNewest += 1
                } else if date >= ttlStart {
                    census.fresh += 1
                } else {
                    continue
                }
                if date < install {
                    firstSync.append((id, date))
                } else {
                    bodies.append((id, date.addingTimeInterval(Config.arrivalFetchDelay)))
                }
            }
            firstSync.sort { $0.date > $1.date }
            for (position, entry) in firstSync.enumerated() {
                bodies.append((entry.id, install.addingTimeInterval(Double(position) * Config.initialFetchSpacing)))
            }
            bodies.sort { $0.fetchedAt < $1.fetchedAt }
            var rng = DBProof.SeededGenerator(seed: Config.seed)
            let insert = try db.makeStatement(sql: "INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)")
            for body in bodies {
                let size = Int.random(in: htmlBytes, using: &rng)
                try insert.execute(arguments: [body.id, String(Self.filler.prefix(size)), body.fetchedAt])
            }
            return census
        }
    }

    static let filler = String(
        repeating: "<p>Proof body text line.</p>\n", count: Config.largerHTMLBytes.upperBound / 28 + 1)

    // MARK: - The old step, one write per page

    /// The old step as it ran: one write per page, `afterEachPage` between them.
    /// Returns the bodies it evicted.
    static func legacyPass(
        _ dbPool: PrioritizedDatabase, afterEachPage: @Sendable () async -> Void
    ) async throws -> Int {
        let cutoff = Legacy.legacyCutoff()
        var recentCache: [String: Set<String>] = [:]
        var cursor: Legacy.LegacyCursor?
        var evicted = 0
        while true {
            let after = cursor
            let page = try Self.syncWrite(dbPool) { db in
                try Legacy.legacyEvictPage(
                    db, cutoff: cutoff, after: after, recentCache: &recentCache, undoProtectedBodyIds: [])
            }
            guard let last = page.last else { break }
            evicted += page.deleted.count
            cursor = last
            await afterEachPage()
        }
        return evicted
    }

    /// The synchronous write, as the step's own `passThroughWrite` makes it.
    private static func syncWrite<T>(_ dbPool: PrioritizedDatabase, _ updates: (Database) throws -> T) throws -> T {
        try dbPool.write(updates)
    }

    /// Builds the old file's steady state: its index, then one run of the old step,
    /// so every later run starts from the state the step leaves, and no WAL (the
    /// variant files copy the main file only). Returns the bodies it evicted.
    static func settleOld(_ url: URL) async throws -> Int {
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
        try await pool.write { db in try db.execute(sql: Config.oldIndexSQL) }
        let evicted = try await Self.legacyPass(
            PrioritizedDatabase(pool: pool, priority: .background), afterEachPage: {})
        try await pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try pool.close()
        return evicted
    }

    // MARK: - The migration and the deferred step

    struct MigrationCost {
        var wallMs: [Double] = []
        /// The maintenance pass's deferred step, whole, through the production function.
        var stepWallMs: [Double] = []
        /// The WAL file's size when the step's write has committed, read just before the
        /// step's own checkpoint (a TRUNCATE, which empties it): what the step's one
        /// transaction wrote to the WAL.
        var stepWalBytes: [Int] = []
        /// That checkpoint's own time: a second writer hold, after the step's write.
        var stepCheckpointMs: [Double] = []
        /// The step's three statements apart, each run on its own fresh copy.
        var fillMs: [Double] = []
        var indexMs: [Double] = []
        var analyzeMs: [Double] = []
        var pageSize = 0
        var oldPages = 0
        var migratedPages = 0
        var steppedPages = 0
        var bodyPages = 0
        var pairFreePages = 0
        var pairIndexPages = 0
        var columnOnlyIndexPages = 0
        var oldIndexPages = 0
        /// Right after v116, before the step: headers with a cached-at time, and
        /// whether the pair's index exists.
        var filledByMigration = -1
        var indexedByMigration = -1
        var stepResults: [SyncEngine.PlannerStatisticsRefresh] = []
        var headersFilled = 0
        var mismatches = 0
    }

    /// Copies `base` to `url` and runs the app's migration chain on it (v116 only, the
    /// rest is applied) with the production pool configuration. Returns its wall time.
    static func migrate(base: URL, to url: URL) throws -> Double {
        try DBProof.removeDatabaseFiles(at: url)
        try FileManager.default.copyItem(at: base, to: url)
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
        let start = DispatchTime.now().uptimeNanoseconds
        try AppDatabase.runMigrations(on: pool)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try pool.close()
        return Double(elapsed) / 1_000_000
    }

    /// Runs the maintenance pass's deferred step on `url` as the app runs it after the
    /// upgrade (`SyncEngine.runRefreshPlannerStatisticsIfStale`, with a marker of its
    /// own so the app's is untouched). Its checkpoint is the app's
    /// (`checkpointWALThrottled(truncate: true, pool:)`, the step's default, pinned by
    /// `SyncEngineMaintenanceTests.deferredBuildCheckpointsWithTheThrottledTruncate`),
    /// with the WAL file's size read just before it. Returns the step's wall time (its
    /// checkpoint included), its result, that size (-1 when the step built nothing, so
    /// no checkpoint ran) and the checkpoint's own time.
    static func runDeferredStep(_ url: URL) async throws -> (
        wallMs: Double, result: SyncEngine.PlannerStatisticsRefresh, walBytes: Int, checkpointMs: Double
    ) {
        let suiteName = "StaleBodyEvictPairProof.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
        let seen = DeferredCheckpointRecord()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await SyncEngine.runRefreshPlannerStatisticsIfStale(
            dbPool: PrioritizedDatabase(pool: pool, priority: .background),
            defaults: defaults, markerKey: "plannerStatisticsSchemaVersion",
            checkpointWAL: { written in
                let bytes = (try? Self.walFileBytes(url)) ?? -1
                let checkpointStart = DispatchTime.now().uptimeNanoseconds
                await SyncEngine.checkpointWALThrottled(truncate: true, pool: written)
                let checkpointEnd = DispatchTime.now().uptimeNanoseconds
                await seen.record(walBytes: bytes, checkpointMs: Double(checkpointEnd - checkpointStart) / 1_000_000)
            })
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try await pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try pool.close()
        let walBytes = await seen.walBytes
        let checkpointMs = await seen.checkpointMs
        return (Double(elapsed) / 1_000_000, result, walBytes, checkpointMs)
    }

    /// What the deferred step's checkpoint saw: the WAL file's size just before it, and
    /// its own time.
    actor DeferredCheckpointRecord {
        var walBytes = -1
        var checkpointMs = 0.0

        func record(walBytes: Int, checkpointMs: Double) {
            self.walBytes = walBytes
            self.checkpointMs = checkpointMs
        }
    }

    /// The size of `url`'s WAL file, 0 when there is none.
    static func walFileBytes(_ url: URL) throws -> Int {
        let wal = url.path + "-wal"
        guard FileManager.default.fileExists(atPath: wal) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: wal)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The step's statements apart, in one transaction on a migrated copy: the fill,
    /// the index, then `ANALYZE`. Wall times in ms.
    static func timeStepParts(_ url: URL) throws -> (fill: Double, index: Double, analyze: Double) {
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
        defer { try? pool.close() }
        return try pool.write { db in
            func timed(_ sql: String) throws -> Double {
                let start = DispatchTime.now().uptimeNanoseconds
                try db.execute(sql: sql)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            return (try timed(HTMLCachePair.fillSQL), try timed(HTMLCachePair.indexSQL), try timed("ANALYZE"))
        }
    }

    static func pageCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
    }

    /// The pages `drop` frees, after `setup`, in a transaction that is rolled back.
    static func freedPages(_ url: URL, setup: [String] = [], _ drop: String) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.writeWithoutTransaction { db in
            var pages = 0
            try db.inTransaction {
                for sql in setup { try db.execute(sql: sql) }
                let before = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                try db.execute(sql: drop)
                let after = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                pages = after - before
                return .rollback
            }
            return pages
        }
    }

    /// The pages index `name` holds.
    static func indexPages(_ url: URL, _ name: String) throws -> Int {
        try freedPages(url, "DROP INDEX \(name)")
    }

    // The censuses below are synchronous on purpose: inside an `async` function GRDB's
    // `read` and `write` bind their `async` overloads (the synchronous ones are
    // disfavored), so the measuring functions call these instead.

    /// The file's pages and page size.
    static func fileSize(_ url: URL) throws -> (pages: Int, pageSize: Int) {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            (try Self.pageCount(db), try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
        }
    }

    /// Right after v116, before the step: the file's pages, the headers with a
    /// cached-at time, and whether the pair's index exists (1) or not (0).
    static func migratedCensus(_ url: URL) throws -> (pages: Int, filled: Int, indexed: Int) {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            let pages = try Self.pageCount(db)
            let filled = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM messageHeader WHERE htmlCachedAt IS NOT NULL") ?? -1
            let indexed = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: [HTMLCachePair.indexName]) ?? -1
            return (pages, filled, indexed)
        }
    }

    /// After the step, on the kept pair file: its pages, the filled headers and the
    /// pair's mismatches; then it drops the old index, as a phone's file has it, and
    /// gives the free pages that leaves.
    static func steppedCensus(_ url: URL) throws -> (pages: Int, filled: Int, mismatches: Int, freePages: Int) {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.writeWithoutTransaction { db in
            let pages = try Self.pageCount(db)
            let filled = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM messageHeader WHERE htmlCachedAt IS NOT NULL") ?? 0
            let mismatches = try HTMLCachePairTests.mismatches(db).count
            try db.execute(sql: "DROP INDEX \(Config.oldIndexName)")
            let freePages = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            _ = try db.checkpoint(.truncate)
            return (pages, filled, mismatches, freePages)
        }
    }

    /// Times the migration and the deferred step `DBProof.repeats` times each, every
    /// run on a fresh copy of `oldBase`, keeps the first copy as `pairBase`, drops the
    /// old index from it (its pages go to the free list, as on a phone), and measures
    /// what the column and the indexes take. Then times the step's three statements
    /// apart, `DBProof.repeats` times, on further fresh copies. The pair file is not
    /// compacted: it is the old file after the upgrade.
    static func measureMigration(oldBase: URL, pairBase: URL, scratch: URL) async throws -> MigrationCost {
        var cost = MigrationCost()
        cost.oldIndexPages = try Self.indexPages(oldBase, Config.oldIndexName)
        // The body table and its primary key, without the old step's index on it.
        cost.bodyPages = try Self.freedPages(
            oldBase, setup: ["DROP INDEX \(Config.oldIndexName)"], "DROP TABLE messageBody")
        let oldSize = try Self.fileSize(oldBase)
        cost.oldPages = oldSize.pages
        cost.pageSize = oldSize.pageSize

        for run in 0..<DBProof.repeats {
            let file = run == 0 ? pairBase : scratch
            cost.wallMs.append(try Self.migrate(base: oldBase, to: file))
            if run == 0 {
                let migrated = try Self.migratedCensus(file)
                cost.migratedPages = migrated.pages
                cost.filledByMigration = migrated.filled
                cost.indexedByMigration = migrated.indexed
            }
            let step = try await Self.runDeferredStep(file)
            cost.stepWallMs.append(step.wallMs)
            cost.stepWalBytes.append(step.walBytes)
            cost.stepCheckpointMs.append(step.checkpointMs)
            cost.stepResults.append(step.result)
            if run != 0 { try DBProof.removeDatabaseFiles(at: scratch) }
        }
        for _ in 0..<DBProof.repeats {
            cost.wallMs.append(try Self.migrate(base: oldBase, to: scratch))
            let parts = try Self.timeStepParts(scratch)
            cost.fillMs.append(parts.fill)
            cost.indexMs.append(parts.index)
            cost.analyzeMs.append(parts.analyze)
            try DBProof.removeDatabaseFiles(at: scratch)
        }

        cost.pairIndexPages = try Self.indexPages(pairBase, Config.pairIndexName)
        let stepped = try Self.steppedCensus(pairBase)
        cost.steppedPages = stepped.pages
        cost.headersFilled = stepped.filled
        cost.mismatches = stepped.mismatches
        cost.pairFreePages = stepped.freePages
        return cost
    }

    /// The extra data point: v116 and the deferred step at about 105,000 headers, the
    /// same cache model with `Config.largerHTMLBytes` of HTML per body.
    struct LargerHTMLSection {
        let name: String
        let htmlBytes: Range<Int>
        let census: CacheCensus
        let settled: Int
        let migration: MigrationCost
    }

    static func measureLargerHTML(in unitDirectory: URL) async throws -> LargerHTMLSection {
        let name = "105k-larger-html"
        let anchor = Date()
        let oldBase = unitDirectory.appendingPathComponent("\(name)-old-base.sqlite")
        let pairBase = unitDirectory.appendingPathComponent("\(name)-pair-base.sqlite")
        let scratch = unitDirectory.appendingPathComponent("\(name)-scratch.sqlite")
        try DBProof.build(
            at: oldBase, shape: .large, anchor: anchor, migratedUpTo: Config.oldSchemaMigration,
            deferredIndexes: Config.oldDeferredIndexes)
        let census = try Self.seedBodies(at: oldBase, anchor: anchor, htmlBytes: Config.largerHTMLBytes)
        let settled = try await Self.settleOld(oldBase)
        let migration = try await Self.measureMigration(oldBase: oldBase, pairBase: pairBase, scratch: scratch)
        for file in [oldBase, pairBase, scratch] {
            try DBProof.removeDatabaseFiles(at: file)
        }
        return LargerHTMLSection(
            name: "105k", htmlBytes: Config.largerHTMLBytes, census: census, settled: settled, migration: migration)
    }

    // MARK: - The other reads' plans

    /// The statistics and schema states the plan census compares.
    enum PlanState: String, CaseIterable, Sendable {
        /// Before #1433: the old file after a whole-database `ANALYZE`.
        case before
        /// The old file after the upgrade and the deferred step, as a phone has it.
        case after
        /// The control: the old file analyzed, then v116 and the pair's fill and index
        /// with no `ANALYZE` after them, so the index has no statistics row (the index
        /// built in a migration, as #1433 first had it).
        case indexWithoutStatistics
    }

    struct PlanCensusLine {
        let read: String
        let isInboxRead: Bool
        let plans: [PlanState: String]
        var changedAfter: Bool { plans[.before] != plans[.after] }
        var controlOnPairIndex: Bool { plans[.indexWithoutStatistics]?.contains(Config.pairIndexName) == true }
    }

    /// The reads the census plans: #1401's (`BackfillProgressIndexProofTests.probes`) but
    /// the evict's own, which seek the pair's index by design (`plans`), and the chat
    /// pill's reminder count.
    static func censusReads(_ base: URL) throws -> [BackfillProgressIndexProofTests.Probe] {
        let queue = try DatabaseQueue(path: base.path)
        defer { try? queue.close() }
        var reads = try queue.read { db in try BackfillProgressIndexProofTests.probes(db) }
            .filter { !$0.name.hasPrefix("stale-body evict") }
        reads.append(BackfillProgressIndexProofTests.Probe(
            name: "chat pill reminder count", hot: true, sql: ChatPillState.Session.reminderCountSQL, arguments: []))
        return reads
    }

    static func readPlans(_ file: URL, _ reads: [BackfillProgressIndexProofTests.Probe]) throws -> [String] {
        let pool = try DatabasePool(path: file.path, configuration: AppDatabase.makeConfiguration())
        defer { try? pool.close() }
        return try pool.read { db in
            try reads.map { read in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + read.sql, arguments: read.arguments)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: " | ")
            }
        }
    }

    /// A whole-database `ANALYZE` on `url`, as the census's `before` state has it.
    static func analyze(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in try DBProof.apply(.analyzed, to: db) }
    }

    /// The control's schema on `url`: the migration chain, then the pair's fill and
    /// index with no `ANALYZE` after them.
    static func buildPairWithoutStatistics(_ url: URL) throws {
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
        defer { try? pool.close() }
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            try db.execute(sql: HTMLCachePair.fillSQL)
            try db.execute(sql: HTMLCachePair.indexSQL)
        }
    }

    /// Plans every census read in each state, each on its own copy of `oldBase`.
    static func planCensus(oldBase: URL, scratch: URL) async throws -> [PlanCensusLine] {
        let reads = try Self.censusReads(oldBase)
        var plans: [PlanState: [String]] = [:]
        for state in PlanState.allCases {
            switch state {
            case .after:
                _ = try Self.migrate(base: oldBase, to: scratch)
                let step = try await Self.runDeferredStep(scratch)
                #expect(step.result == .refreshed, "setup: the deferred step did not complete: \(step.result)")
            case .before, .indexWithoutStatistics:
                try DBProof.removeDatabaseFiles(at: scratch)
                try FileManager.default.copyItem(at: oldBase, to: scratch)
                try Self.analyze(scratch)
                if state == .indexWithoutStatistics {
                    try Self.buildPairWithoutStatistics(scratch)
                }
            }
            plans[state] = try Self.readPlans(scratch, reads)
            try DBProof.removeDatabaseFiles(at: scratch)
        }
        return reads.enumerated().map { offset, read in
            PlanCensusLine(
                read: read.name, isInboxRead: read.sql.contains("isInInbox = 1"),
                plans: Dictionary(uniqueKeysWithValues: PlanState.allCases.map { ($0, plans[$0]?[offset] ?? "") }))
        }
    }

    // MARK: - Measuring one evict pass

    enum StatementKind: Int, CaseIterable {
        case page, headerLookup, existenceProbe, folderNewest, delete, begin, end, other

        var label: String {
            switch self {
            case .page: return "page reads"
            case .headerLookup: return "header lookups"
            case .existenceProbe: return "header existence probes"
            case .folderNewest: return "folder-newest reads"
            case .delete: return "body deletes"
            case .begin: return "BEGIN"
            case .end: return "COMMIT/ROLLBACK"
            case .other: return "other statements"
            }
        }

        static func of(_ sql: UnsafePointer<CChar>?) -> StatementKind {
            guard let sql else { return .other }
            if strncmp(sql, "BEGIN", 5) == 0 { return .begin }
            if strncmp(sql, "COMMIT", 6) == 0 || strncmp(sql, "ROLLBACK", 8) == 0 { return .end }
            if strstr(sql, "AS bodyRowId") != nil || strstr(sql, "AS headerRowId") != nil { return .page }
            if strncmp(sql, "SELECT * FROM \"messageHeader\" WHERE \"id\" = ?", 44) == 0 { return .headerLookup }
            if strstr(sql, "FROM \"messageHeader\" WHERE \"id\" IN (") != nil { return .existenceProbe }
            if strstr(sql, "ORDER BY \"date\" DESC") != nil { return .folderNewest }
            if strncmp(sql, "DELETE FROM \"messageBody\"", 25) == 0 { return .delete }
            return .other
        }
    }

    /// What the writer connection ran during one pass, from SQLite's statement trace.
    /// Used only on the writer connection's queue: installed and read inside
    /// `writeWithoutTransaction`, fed by the trace while the step's writes run, and read
    /// after the pass has ended; that serial use is why it is `@unchecked Sendable`.
    final class TraceRecorder: @unchecked Sendable {
        let countRows: Bool
        var executions = Array(repeating: 0, count: StatementKind.allCases.count)
        var vmSteps = 0
        var pageRows = 0
        var holdsNs: [UInt64] = []
        var otherSQL: Set<String> = []
        private var openedAt: UInt64?

        init(countRows: Bool) { self.countRows = countRows }

        func handle(event: UInt32, statement: OpaquePointer) {
            let kind = StatementKind.of(sqlite3_sql(statement))
            if event == UInt32(SQLITE_TRACE_ROW) {
                if kind == .page { pageRows += 1 }
                return
            }
            // SQLITE_TRACE_PROFILE: the statement finished one execution.
            let now = DispatchTime.now().uptimeNanoseconds
            executions[kind.rawValue] += 1
            vmSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
            switch kind {
            case .begin:
                openedAt = now
            case .end:
                if let openedAt { holdsNs.append(now - openedAt) }
                openedAt = nil
            case .other:
                if countRows, let sql = sqlite3_sql(statement) { otherSQL.insert(String(cString: sql)) }
            default:
                break
            }
        }
    }

    /// When each page's write call returned, from the step's own `afterEachPage`.
    final class PageClock: Sendable {
        private let marks = Mutex<[UInt64]>([])
        func mark() { marks.withLock { $0.append(DispatchTime.now().uptimeNanoseconds) } }
        var all: [UInt64] { marks.withLock { $0 } }
    }

    struct PassCost {
        var wallMs = 0.0
        var executions: [Int] = []
        var vmSteps = 0
        var pageRows = 0
        var pagesRead = 0
        var pagesFetched = 0
        var holdsMs: [Double] = []
        var pageCallsMs: [Double] = []
        var otherSQL: Set<String> = []

        func count(_ kind: StatementKind) -> Int { executions[kind.rawValue] }
    }

    /// One pass of `schema`'s step on a fresh clone of `file`, on a fresh pool opened
    /// with the app's configuration, at the background pool's tier. `countRows` also
    /// counts the rows every page returned (the rows visited); it adds a callback per
    /// row, so the timed runs leave it off.
    static func measurePass(file: URL, schema: Schema, countRows: Bool) async throws -> PassCost {
        let scratch = file.deletingLastPathComponent()
            .appendingPathComponent("run-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: file, to: scratch)
        defer { try? DBProof.removeDatabaseFiles(at: scratch) }
        let pool = try DatabasePool(path: scratch.path, configuration: AppDatabase.makeConfiguration())
        defer { try? pool.close() }
        let recorder = TraceRecorder(countRows: countRows)
        let mask = UInt32(SQLITE_TRACE_PROFILE) | (countRows ? UInt32(SQLITE_TRACE_ROW) : 0)
        try await pool.writeWithoutTransaction { db in
            guard let handle = db.sqliteConnection else { throw DBProof.DBProofError.noConnection }
            let context = Unmanaged.passUnretained(recorder).toOpaque()
            // Load the schema first, so the counters cover only the step.
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            var current: Int32 = 0
            var highwater: Int32 = 0
            sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &current, &highwater, 1)
            sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &current, &highwater, 1)
            sqlite3_trace_v2(handle, mask, { event, context, statement, _ in
                guard let context, let statement else { return 0 }
                Unmanaged<TraceRecorder>.fromOpaque(context).takeUnretainedValue()
                    .handle(event: event, statement: OpaquePointer(statement))
                return 0
            }, context)
        }
        let clock = PageClock()
        let dbPool = PrioritizedDatabase(pool: pool, priority: .background)
        let start = DispatchTime.now().uptimeNanoseconds
        switch schema {
        case .old:
            _ = try await Self.legacyPass(dbPool, afterEachPage: { clock.mark() })
        case .pairInboxFirst, .pairColumnOnly:
            await SyncEngine.runEvictStaleBodies(
                dbPool: dbPool, undoProtectedBodyIds: [], afterEachPage: { clock.mark() })
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        let (misses, hits) = try await pool.writeWithoutTransaction { db -> (Int32, Int32) in
            guard let handle = db.sqliteConnection else { throw DBProof.DBProofError.noConnection }
            sqlite3_trace_v2(handle, 0, nil, nil)
            var misses: Int32 = 0
            var hits: Int32 = 0
            var highwater: Int32 = 0
            sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &misses, &highwater, 0)
            sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &hits, &highwater, 0)
            return (misses, hits)
        }
        var cost = PassCost()
        cost.pagesRead = Int(misses)
        cost.pagesFetched = Int(misses) + Int(hits)
        withExtendedLifetime(recorder) {
            cost.executions = recorder.executions
            cost.vmSteps = recorder.vmSteps
            cost.pageRows = recorder.pageRows
            cost.holdsMs = recorder.holdsNs.map { Double($0) / 1_000_000 }
            cost.otherSQL = recorder.otherSQL
        }
        cost.wallMs = Double(elapsed) / 1_000_000
        var previous = start
        for mark in clock.all {
            cost.pageCallsMs.append(Double(mark - previous) / 1_000_000)
            previous = mark
        }
        return cost
    }

    /// The query plans of `schema`'s reads on `file`.
    static func plans(_ file: URL, schema: Schema) throws -> [(String, String)] {
        let queue = try DatabaseQueue(path: file.path)
        defer { try? queue.close() }
        return try queue.read { db in
            func plan(_ sql: String, _ arguments: StatementArguments) throws -> String {
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                    .map { $0["detail"] as String? ?? "?" }.joined(separator: " | ")
            }
            let cutoff = Date()
            let chunk = SyncConfig.pruneChunkSize
            let folderNewest = try plan(
                #"SELECT "id" FROM "messageHeader" WHERE "folderId" = ? ORDER BY "date" DESC LIMIT ?"#,
                ["x", SyncConfig.bodyCacheRecentPerFolder])
            switch schema {
            case .old:
                return [
                    ("page (first)", try plan(Legacy.legacyPageSQL(afterCursor: false), [cutoff, chunk])),
                    ("page (after cursor)", try plan(Legacy.legacyPageSQL(afterCursor: true), [cutoff, cutoff, 1, chunk])),
                    ("header lookup", try plan(#"SELECT * FROM "messageHeader" WHERE "id" = ?"#, ["x"])),
                    ("folder newest", folderNewest),
                ]
            case .pairInboxFirst, .pairColumnOnly:
                return [
                    ("page (first)", try plan(HTMLCachePair.evictCandidatesPageSQL(afterCursor: false), [cutoff, chunk])),
                    ("page (after cursor)", try plan(
                        HTMLCachePair.evictCandidatesPageSQL(afterCursor: true), [cutoff, cutoff, 1, chunk])),
                    ("folder newest", folderNewest),
                    ("is cached (HTMLCachePair.isCached)", try plan(
                        "SELECT htmlCachedAt IS NOT NULL FROM messageHeader WHERE id = ?", ["x"])),
                    ("not cached, one inbox state", try plan(
                        "SELECT id FROM messageHeader WHERE isInInbox = ? AND htmlCachedAt IS NULL", [true])),
                ]
            }
        }
    }

    // MARK: - Writes

    /// Ids drawn once from the old file; every schema has the same rows.
    struct WriteSample: Sendable {
        let uncached: [String]
        let cached: [String]
        let inboxCached: [String]
        let otherCached: [String]
        let resetInboxCached: [String]
        let templateId: String
    }

    static func sampleWrites(_ url: URL) throws -> WriteSample {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            var rng = DBProof.SeededGenerator(seed: Config.seed)
            func draw(_ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
                let all = try String.fetchAll(db, sql: sql, arguments: arguments)
                return Array(all.shuffled(using: &rng).prefix(Config.writeBatch))
            }
            let resetAccountId = DBProof.accountId(Config.resetAccountIndex)
            let uncached = try draw("""
                SELECT id FROM messageHeader WHERE isInInbox = 0
                  AND id NOT IN (SELECT id FROM messageBody) ORDER BY rowid
                """)
            return WriteSample(
                uncached: uncached,
                cached: try draw("SELECT id FROM messageBody WHERE id IN (SELECT id FROM messageHeader) ORDER BY rowid"),
                inboxCached: try draw("""
                    SELECT id FROM messageHeader WHERE isInInbox = 1
                      AND id IN (SELECT id FROM messageBody) ORDER BY rowid
                    """),
                otherCached: try draw("""
                    SELECT id FROM messageHeader WHERE isInInbox = 0
                      AND id IN (SELECT id FROM messageBody) ORDER BY rowid
                    """),
                resetInboxCached: try draw("""
                    SELECT id FROM messageHeader WHERE accountId = ? AND folderPath = ?
                      AND id IN (SELECT id FROM messageBody) ORDER BY rowid
                    """, [resetAccountId, Config.resetFolderPath]),
                templateId: uncached.first ?? "")
        }
    }

    struct WriteOperation: Sendable {
        let name: String
        let repeats: Int
        let run: @Sendable (Database) throws -> Int
    }

    static func writeOperations(_ sample: WriteSample) -> [WriteOperation] {
        let html = String(Self.filler.prefix(6_000))
        let resetAccountId = DBProof.accountId(Config.resetAccountIndex)
        let resetFolderPath = Config.resetFolderPath
        let resetFolderId = MessageIdentity.folderId(accountId: resetAccountId, folderPath: resetFolderPath)
        let deleteResetHeaders: @Sendable (Database) throws -> Int = { db in
            try MessageHeader.filter(Column("folderId") == resetFolderId).deleteAll(db)
        }
        // `uidValidityResetPurgeTxn`'s body delete.
        let deleteResetBodies: @Sendable (Database) throws -> Int = { db in
            let range = MessageIdentity.headerIdRange(accountId: resetAccountId, folderPath: resetFolderPath)
            try db.execute(
                sql: """
                    DELETE FROM messageBody
                    WHERE id >= ? AND id < ?
                      AND \(MessageIdentity.headerIdLikeNoDeeperColonSQLFragment(column: "id"))
                    """,
                arguments: [range.lower, range.upper, range.lower])
            return db.changesCount
        }
        let batch = Config.writeBatch
        return [
            WriteOperation(name: "body save: a new body for \(batch) uncached messages", repeats: DBProof.repeats) { db in
                for id in sample.uncached {
                    try MessageBody(contentKey: ContentKey(rawValue: id), htmlContent: html).insert(db)
                }
                return sample.uncached.count
            },
            WriteOperation(name: "body re-save: \(batch) cached bodies fetched again (record update)", repeats: DBProof.repeats) { db in
                var count = 0
                for id in sample.cached {
                    guard var body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: id)) else { continue }
                    body.fetchedAt = Date()
                    try body.update(db)
                    count += 1
                }
                return count
            },
            WriteOperation(name: "body delete: \(batch) cached bodies in one statement (a prune batch)", repeats: DBProof.repeats) { db in
                try MessageBody.filter(sample.cached.contains(Column("id"))).deleteAll(db)
            },
            WriteOperation(name: "header merge: \(batch) cached headers updated and \(batch) new ones inserted (records)", repeats: DBProof.repeats) { db in
                var count = 0
                for id in sample.cached {
                    guard let header = try MessageHeader.fetchOne(db, key: id) else { continue }
                    try header.update(db)
                    count += 1
                }
                guard let template = try MessageHeader.fetchOne(db, key: sample.templateId) else { return count }
                for index in 0..<batch {
                    var header = template
                    header.messageId = "proof-merge-\(index)"
                    header.id = MessageIdentity.headerId(
                        accountId: header.accountId, folderPath: header.folderPath, messageId: header.messageId)
                    header.rfc822MessageId = "<proof-merge-\(index)@example.com>"
                    try header.insert(db)
                    count += 1
                }
                return count
            },
            WriteOperation(name: "inbox moves: \(batch) cached inbox headers out, \(batch) cached others in (records)", repeats: DBProof.repeats) { db in
                var count = 0
                for (ids, isInInbox) in [(sample.inboxCached, false), (sample.otherCached, true)] {
                    for id in ids {
                        guard var header = try MessageHeader.fetchOne(db, key: id) else { continue }
                        header.isInInbox = isInInbox
                        try header.update(db)
                        count += 1
                    }
                }
                return count
            },
            WriteOperation(name: "IMAP move carrying its body (MessageHeaderRekey.apply): \(batch) cached inbox messages to Archive", repeats: DBProof.repeats) { db in
                var count = 0
                for (index, id) in sample.resetInboxCached.enumerated() {
                    guard let old = try MessageHeader.fetchOne(db, key: id) else { continue }
                    var moved = old
                    moved.folderPath = Config.movedToFolderPath
                    moved.folderId = MessageIdentity.folderId(accountId: old.accountId, folderPath: Config.movedToFolderPath)
                    moved.messageId = "proof-move-\(index)"
                    moved.id = MessageIdentity.headerId(
                        accountId: old.accountId, folderPath: Config.movedToFolderPath, messageId: moved.messageId)
                    moved.isInInbox = false
                    if try MessageHeaderRekey.apply(from: old, to: moved, db: db) { count += 1 }
                }
                return count
            },
            WriteOperation(name: "message delete: \(batch) cached messages, header then body", repeats: DBProof.repeats) { db in
                var count = 0
                for id in sample.otherCached {
                    if try MessageHeader.deleteOne(db, key: id) { count += 1 }
                    if try MessageBody.deleteOne(db, key: ContentKey(rawValue: id)) { count += 1 }
                }
                return count
            },
            WriteOperation(name: "whole-table wipe, bodies first (AppDataWiper's order before #1433)", repeats: Config.bulkRepeats) { db in
                try db.execute(sql: "DELETE FROM messageBody")
                var count = db.changesCount
                try db.execute(sql: "DELETE FROM messageHeader")
                count += db.changesCount
                return count
            },
            WriteOperation(name: "whole-table wipe, headers first (AppDataWiper's and the settings reset's order)", repeats: Config.bulkRepeats) { db in
                try db.execute(sql: "DELETE FROM messageHeader")
                var count = db.changesCount
                try db.execute(sql: "DELETE FROM messageBody")
                count += db.changesCount
                return count
            },
            WriteOperation(name: "account removal of the IMAP account (AccountManager.removeAccountRowsTxn: the cascade, then its bodies)", repeats: Config.bulkRepeats) { db in
                // The function's last statement is its body delete: the rows counted.
                try AccountManager.removeAccountRowsTxn(db, accountId: DBProof.accountId(Config.resetAccountIndex), wasPrimary: false)
                return db.changesCount
            },
            WriteOperation(name: "account removal of the IMAP account, bodies first (the order before #1433)", repeats: Config.bulkRepeats) { db in
                let accountId = DBProof.accountId(Config.resetAccountIndex)
                try db.execute(
                    sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
                    arguments: [MessageIdentity.escapeForLike(accountId) + ":%"])
                let count = db.changesCount
                try AccountManager.removeAccountRowsTxn(db, accountId: accountId, wasPrimary: false)
                return count
            },
            WriteOperation(name: "UIDVALIDITY reset of the IMAP inbox, headers then bodies (as built)", repeats: Config.bulkRepeats) { db in
                try deleteResetHeaders(db) + deleteResetBodies(db)
            },
            WriteOperation(name: "UIDVALIDITY reset of the IMAP inbox, bodies then headers", repeats: Config.bulkRepeats) { db in
                try deleteResetBodies(db) + deleteResetHeaders(db)
            },
        ]
    }

    struct WriteCost {
        let operation: String
        let schema: Schema
        let runs: [DBProof.RunCost]
    }

    // MARK: - The proof

    struct EvictSection {
        let statistics: DBProof.Statistics
        let schema: Schema
        let counting: PassCost
        let timed: [PassCost]
        let plans: [(String, String)]
    }

    struct DatabaseSection {
        let name: String
        let headers: Int
        let census: CacheCensus
        let settled: Int
        let migration: MigrationCost
        let planCensus: [PlanCensusLine]
        let evicts: [EvictSection]
        let writes: [WriteCost]
    }

    @Test("the evict, the pair's write costs, its migration and its deferred step, old against new, at about 105,000 and 525,000 headers")
    func measurePair() async throws {
        let directory = try #require(DBProof.outputDirectory)
        let unitDirectory = directory.appendingPathComponent(Self.unit, isDirectory: true)
        try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
        let repeats = DBProof.repeats
        var sections: [DatabaseSection] = []
        for database in Self.databases {
            let anchor = Date()
            let oldBase = unitDirectory.appendingPathComponent("\(database.name)-old-base.sqlite")
            let pairBase = unitDirectory.appendingPathComponent("\(database.name)-pair-base.sqlite")
            let scratch = unitDirectory.appendingPathComponent("\(database.name)-scratch.sqlite")
            try DBProof.build(
                at: oldBase, shape: database.shape, anchor: anchor, migratedUpTo: Config.oldSchemaMigration,
                deferredIndexes: Config.oldDeferredIndexes)
            let census = try Self.seedBodies(at: oldBase, anchor: anchor)
            let settled = try await Self.settleOld(oldBase)
            var migration = try await Self.measureMigration(oldBase: oldBase, pairBase: pairBase, scratch: scratch)
            let planCensus = try await Self.planCensus(oldBase: oldBase, scratch: scratch)
            let sample = try Self.sampleWrites(oldBase)

            var evicts: [EvictSection] = []
            var writes: [WriteCost] = []
            var variantFiles: [URL] = []
            for statistics in [DBProof.Statistics.analyzed, DBProof.Statistics.none] {
                for schema in Schema.allCases {
                    let file = unitDirectory.appendingPathComponent(
                        "\(database.name)-\(schema.fileTag)-\(statistics.rawValue).sqlite")
                    variantFiles.append(file)
                    try DBProof.prepareVariantFile(
                        base: schema == .old ? oldBase : pairBase,
                        setupSQL: schema == .pairColumnOnly ? Config.columnOnlySetupSQL : [],
                        statistics: statistics, at: file)
                    if schema == .pairColumnOnly, statistics == .analyzed {
                        migration.columnOnlyIndexPages = try Self.indexPages(file, Config.columnOnlyIndexName)
                    }
                    let counting = try await Self.measurePass(file: file, schema: schema, countRows: true)
                    var timed: [PassCost] = []
                    for _ in 0..<repeats {
                        timed.append(try await Self.measurePass(file: file, schema: schema, countRows: false))
                    }
                    evicts.append(EvictSection(
                        statistics: statistics, schema: schema, counting: counting, timed: timed,
                        plans: try Self.plans(file, schema: schema)))
                    // The writes seek by primary key or a folder's index; statistics
                    // do not change their plans, so they run on the analyzed files only.
                    guard statistics == .analyzed else { continue }
                    for operation in Self.writeOperations(sample) {
                        var runs: [DBProof.RunCost] = []
                        for _ in 0..<operation.repeats {
                            runs.append(try DBProof.measure(
                                DBProof.Variant(run: operation.run), kind: .write, file: file))
                        }
                        writes.append(WriteCost(operation: operation.name, schema: schema, runs: runs))
                    }
                }
            }
            sections.append(DatabaseSection(
                name: database.name, headers: database.shape.totalHeaders, census: census, settled: settled,
                migration: migration, planCensus: planCensus, evicts: evicts, writes: writes))
            for file in variantFiles + [oldBase, pairBase, scratch] {
                try DBProof.removeDatabaseFiles(at: file)
            }
        }
        let larger = try await Self.measureLargerHTML(in: unitDirectory)
        // The control: with the index and no statistics row for it, an inbox read moves
        // onto it, so the census above can see such a change.
        let flips = sections.flatMap { section in
            section.planCensus.filter { $0.isInboxRead && $0.controlOnPairIndex }.map { "\(section.name) \($0.read)" }
        }
        let report = Self.report(sections, larger: larger, repeats: repeats)
        try report.write(to: unitDirectory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)
        #expect(!flips.isEmpty,
                "the control moved no isInInbox = 1 read onto \(Config.pairIndexName); the census cannot see such a change")
        #expect(larger.migration.filledByMigration == 0, "larger HTML: v116 filled \(larger.migration.filledByMigration) headers")
        #expect(larger.migration.stepResults.allSatisfy { $0 == .refreshed },
                "larger HTML: the deferred step did not complete: \(larger.migration.stepResults)")
        #expect(larger.migration.mismatches == 0, "larger HTML: the deferred step's fill is exact")
        #expect(larger.migration.headersFilled == larger.census.total - larger.settled,
                "larger HTML: one filled header per cached body")

        for section in sections {
            // v116 adds the column and the triggers only: the fill and the index wait
            // for the deferred step.
            #expect(section.migration.filledByMigration == 0, "\(section.name): v116 filled \(section.migration.filledByMigration) headers")
            #expect(section.migration.indexedByMigration == 0, "\(section.name): v116 built \(HTMLCachePair.indexName)")
            #expect(section.migration.stepResults.allSatisfy { $0 == .refreshed },
                    "\(section.name): the deferred step did not complete: \(section.migration.stepResults)")
            #expect(section.migration.mismatches == 0, "\(section.name): the deferred step's fill is exact")
            #expect(section.migration.headersFilled == section.census.total - section.settled,
                    "\(section.name): one filled header per cached body")
            for statistics in [DBProof.Statistics.analyzed, DBProof.Statistics.none] {
                let passes = section.evicts.filter { $0.statistics == statistics }
                guard let old = passes.first(where: { $0.schema == .old })?.counting else { continue }
                // Every body the old pass visits has its header looked up (no undo set,
                // every seeded body has a header), and every write reads one page.
                let oldVisited = old.pageRows
                let oldLookups = old.count(.headerLookup)
                #expect(oldVisited > 0)
                #expect(oldLookups == oldVisited)
                for pair in passes where pair.schema != .old {
                    let visited = pair.counting.pageRows
                    let lookups = pair.counting.count(.headerLookup)
                    let pageReads = pair.counting.count(.page)
                    let writes = pair.counting.count(.begin)
                    #expect(lookups == 0, "\(section.name) \(pair.schema.label): no header lookups")
                    #expect(visited < oldVisited, "\(section.name) \(pair.schema.label): visits fewer rows")
                    #expect(pageReads == writes, "\(section.name) \(pair.schema.label): one page per write")
                }
            }
            // The other reads plan as they did before #1433 once the step has run.
            for line in section.planCensus {
                #expect(!line.changedAfter,
                        "\(section.name) \(line.read): the plan changed after the step: \(line.plans[.before] ?? "") -> \(line.plans[.after] ?? "")")
            }
            for operation in Set(section.writes.map(\.operation)) {
                let rows = section.writes.filter { $0.operation == operation }.map { $0.runs.first?.resultRows ?? -1 }
                let distinct = Set(rows)
                #expect(distinct.count == 1, "\(section.name) \(operation): every schema writes the same rows \(rows)")
            }
        }
    }

    // MARK: - Report

    static func report(_ sections: [DatabaseSection], larger: LargerHTMLSection, repeats: Int) -> String {
        var lines = [
            "Measurement: the stale-body evict through the HTML-cache pair against the body walk (#1433)",
            "Side: simulator (the app's SQLite, production connection configuration, background pool tier)",
            "Old: the schema before v116 with messageBody_staleEvict; the old step (dd9150d13), one write per page",
            "Pair: the old file after the app's migration chain ran v116 and the maintenance pass's deferred step (fill, index, ANALYZE in one write), without messageBody_staleEvict, compacted; the production step",
            "Rules: page size \(SyncConfig.pruneChunkSize), TTL \(SyncConfig.bodyCacheTTLHours) h, \(SyncConfig.bodyCacheRecentPerFolder) newest kept per folder",
            "Cache model: a body for every complete message in an inbox or among its folder's newest, and for other complete mail that arrived within the TTL; first sync \(Int(Config.installDaysAgo)) days ago, newest first; HTML \(Config.htmlBytes.lowerBound)-\(Config.htmlBytes.upperBound) bytes",
            "Evict runs: 1 counting run (rows traced), then \(repeats) timed runs, each on a fresh clone and a fresh connection (empty page cache)",
            "Write runs: \(repeats) per kind (\(Config.bulkRepeats) for wipes, account removals and resets), each on a fresh clone, in one transaction, commit included",
            "",
        ]
        for section in sections {
            let migration = section.migration
            let pageMB = Double(migration.pageSize) / 1_048_576
            func pagesText(_ pages: Int) -> String {
                "\(pages) pages (\(String(format: "%.1f", Double(pages) * pageMB)) MB)"
            }
            let migrationWall = DBProof.Distribution(migration.wallMs)
            let stepWall = DBProof.Distribution(migration.stepWallMs)
            let fill = DBProof.Distribution(migration.fillMs)
            let index = DBProof.Distribution(migration.indexMs)
            let analyze = DBProof.Distribution(migration.analyzeMs)
            let bodyMB = Double(migration.bodyPages) * pageMB
            func perMB(_ value: Double) -> String { bodyMB > 0 ? ms(value / bodyMB) : "n/a" }
            lines.append("== \(section.name): \(section.headers) headers")
            lines.append("cached bodies: \(section.census.total) (inbox \(section.census.inbox), folder newest \(section.census.folderNewest), fresh \(section.census.fresh)); the old step's settle pass evicted \(section.settled)")
            lines.append("migration v116 (column and triggers) on the old file, \(migration.wallMs.count) runs: median \(ms(migrationWall.median)) ms, p10 \(ms(migrationWall.p10)), p90 \(ms(migrationWall.p90)), max \(ms(migrationWall.sorted.last ?? 0))")
            lines.append("  old file \(pagesText(migration.oldPages)); after v116 \(pagesText(migration.migratedPages)) (+\(migration.migratedPages - migration.oldPages)); headers with a cached-at time after v116: \(migration.filledByMigration); \(HTMLCachePair.indexName) after v116: \(migration.indexedByMigration)")
            lines.append("deferred step (fill, index and ANALYZE in one write, runRefreshPlannerStatisticsIfStale), \(migration.stepWallMs.count) runs: median \(ms(stepWall.median)) ms, p10 \(ms(stepWall.p10)), p90 \(ms(stepWall.p90)), max \(ms(stepWall.sorted.last ?? 0)); results \(Set(migration.stepResults.map { "\($0)" }).sorted())")
            lines.append("  WAL file when the step's write commits (before its TRUNCATE checkpoint): \(Self.walText(migration.stepWalBytes))")
            lines.append("  that checkpoint, a second writer hold after the write: \(Self.checkpointText(migration.stepCheckpointMs))")
            lines.append("  its statements apart, \(migration.fillMs.count) runs each: fill median \(ms(fill.median)) ms (p90 \(ms(fill.p90))); index median \(ms(index.median)) (p90 \(ms(index.p90))); ANALYZE median \(ms(analyze.median)) (p90 \(ms(analyze.p90)))")
            lines.append("  body pages (messageBody and its primary key): \(pagesText(migration.bodyPages)); per MB of them: fill \(perMB(fill.median)) ms, step \(perMB(stepWall.median)) ms")
            lines.append("  after the step \(pagesText(migration.steppedPages)) (+\(migration.steppedPages - migration.migratedPages) over v116); free after dropping messageBody_staleEvict \(pagesText(migration.pairFreePages))")
            lines.append("  index messageHeader_htmlCachedAt (isInInbox, htmlCachedAt): \(pagesText(migration.pairIndexPages)); (htmlCachedAt) alone: \(pagesText(migration.columnOnlyIndexPages)); messageBody_staleEvict (old): \(pagesText(migration.oldIndexPages))")
            lines.append("  the column's fill: \(pagesText(migration.steppedPages - migration.migratedPages - migration.pairIndexPages)) (the step's growth less its index, the statistics table included)")
            lines.append("  headers filled: \(migration.headersFilled); pair mismatches after the fill: \(migration.mismatches)")
            lines.append("")
            lines.append("-- the other reads' plans: before #1433 (old file, analyzed), after the upgrade and the deferred step, and the control (v116 with the index built and no ANALYZE after it)")
            for line in section.planCensus {
                let before = line.plans[.before] ?? ""
                let after = line.plans[.after] ?? ""
                let control = line.plans[.indexWithoutStatistics] ?? ""
                lines.append("  \(line.read)\(line.isInboxRead ? " (isInInbox = 1)" : "")")
                lines.append("    before: \(before)")
                lines.append("    after: \(after == before ? "the same" : after)")
                lines.append("    control: \(control == before ? "the same" : control)\(line.controlOnPairIndex ? "  [ON \(Config.pairIndexName)]" : "")")
            }
            lines.append("")
            for statistics in [DBProof.Statistics.analyzed, DBProof.Statistics.none] {
                lines.append("-- evict pass, \(statistics.label)")
                for evict in section.evicts where evict.statistics == statistics {
                    let counting = evict.counting
                    let visited = counting.pageRows
                    let deletes = counting.count(.delete)
                    let wall = DBProof.Distribution(evict.timed.map(\.wallMs))
                    let holds = DBProof.Distribution(evict.timed.flatMap(\.holdsMs))
                    let pagesRead = DBProof.Distribution(evict.timed.map { Double($0.pagesRead) })
                    let pagesFetched = DBProof.Distribution(evict.timed.map { Double($0.pagesFetched) })
                    lines.append("  \(evict.schema.label)")
                    lines.append("    rows visited per pass: \(visited) (kept \(visited - deletes), evicted \(deletes))")
                    lines.append("    statements per pass: " + StatementKind.allCases.map { "\($0.label) \(counting.count($0))" }.joined(separator: ", "))
                    lines.append("    VM steps per pass: \(counting.vmSteps)")
                    lines.append("    pages read per pass (cache misses): median \(Int(pagesRead.median)), min \(Int(pagesRead.sorted.first ?? 0)), max \(Int(pagesRead.sorted.last ?? 0)); fetched (hits + misses) median \(Int(pagesFetched.median))")
                    lines.append("    pass wall ms: median \(ms(wall.median)), p10 \(ms(wall.p10)), p90 \(ms(wall.p90))")
                    lines.append("    writer hold per write (BEGIN to COMMIT), \(holds.sorted.count) writes over \(evict.timed.count) runs: median \(ms(holds.median)), p90 \(ms(holds.p90)), max \(ms(holds.sorted.last ?? 0))")
                    lines.append("    plans:")
                    for (name, plan) in evict.plans { lines.append("      \(name): \(plan)") }
                    if !counting.otherSQL.isEmpty {
                        lines.append("    other statements seen:")
                        for sql in counting.otherSQL.sorted() {
                            lines.append("      " + sql.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        }
                    }
                }
                lines.append("")
            }
            lines.append("-- writes, \(DBProof.Statistics.analyzed.label): wall ms median (p90) / pages written median / VM steps median; rows")
            var operations: [String] = []
            for write in section.writes where !operations.contains(write.operation) { operations.append(write.operation) }
            for operation in operations {
                lines.append("  \(operation)")
                for write in section.writes where write.operation == operation {
                    let sample = DBProof.Sample(runs: write.runs)
                    let wall = sample.wallMs
                    let written = sample.count(\.pagesWritten)
                    let steps = sample.count(\.vmSteps)
                    let rows = sample.count(\.resultRows)
                    lines.append("    \(write.schema.label): \(ms(wall.median)) (\(ms(wall.p90))) / \(written.median)\(written.varied ? "*" : "") / \(steps.median)\(steps.varied ? "*" : ""); rows \(rows.median)")
                }
            }
            lines.append("  (* varied between runs)")
            lines.append("")
        }
        lines.append(contentsOf: Self.largerHTMLReport(larger, against: sections.first { $0.name == larger.name }))
        return lines.joined(separator: "\n")
    }

    /// The extra data point's lines, next to the same figures of the main run at the
    /// same size.
    static func largerHTMLReport(_ larger: LargerHTMLSection, against main: DatabaseSection?) -> [String] {
        func figures(_ migration: MigrationCost) -> (bodyMB: Double, step: Double, fill: Double, index: Double, analyze: Double) {
            let bodyMB = Double(migration.bodyPages) * Double(migration.pageSize) / 1_048_576
            return (bodyMB,
                    DBProof.Distribution(migration.stepWallMs).median,
                    DBProof.Distribution(migration.fillMs).median,
                    DBProof.Distribution(migration.indexMs).median,
                    DBProof.Distribution(migration.analyzeMs).median)
        }
        func line(_ label: String, _ migration: MigrationCost) -> String {
            let f = figures(migration)
            func perMB(_ value: Double) -> String { f.bodyMB > 0 ? ms(value / f.bodyMB) : "n/a" }
            return "  \(label): body pages \(String(format: "%.1f", f.bodyMB)) MB; step median \(ms(f.step)) ms (fill \(ms(f.fill)), index \(ms(f.index)), ANALYZE \(ms(f.analyze))); per MB of body pages: step \(perMB(f.step)) ms, fill \(perMB(f.fill)) ms"
        }
        let migration = larger.migration
        let stepWall = DBProof.Distribution(migration.stepWallMs)
        let migrationWall = DBProof.Distribution(migration.wallMs)
        var lines = [
            "== \(larger.name), larger HTML (\(larger.htmlBytes.lowerBound)-\(larger.htmlBytes.upperBound) bytes per body): v116 and the deferred step only",
            "cached bodies: \(larger.census.total) (inbox \(larger.census.inbox), folder newest \(larger.census.folderNewest), fresh \(larger.census.fresh)); the old step's settle pass evicted \(larger.settled)",
            "migration v116, \(migration.wallMs.count) runs: median \(ms(migrationWall.median)) ms, p90 \(ms(migrationWall.p90))",
            "deferred step, \(migration.stepWallMs.count) runs: median \(ms(stepWall.median)) ms, p10 \(ms(stepWall.p10)), p90 \(ms(stepWall.p90)), max \(ms(stepWall.sorted.last ?? 0)); results \(Set(migration.stepResults.map { "\($0)" }).sorted())",
            "  WAL file when the step's write commits (before its TRUNCATE checkpoint): \(Self.walText(migration.stepWalBytes))",
            "  that checkpoint, a second writer hold after the write: \(Self.checkpointText(migration.stepCheckpointMs))",
            "  headers filled: \(migration.headersFilled); pair mismatches after the fill: \(migration.mismatches)",
            "-- against the main run at the same size",
            line("HTML \(larger.htmlBytes.lowerBound)-\(larger.htmlBytes.upperBound) bytes", migration),
        ]
        if let main {
            lines.append(line("HTML \(Config.htmlBytes.lowerBound)-\(Config.htmlBytes.upperBound) bytes", main.migration))
        }
        lines.append("")
        return lines
    }

    private static func ms(_ value: Double) -> String { String(format: "%.3f", value) }

    /// The step's checkpoint times: median, p90 and max over the runs.
    private static func checkpointText(_ times: [Double]) -> String {
        guard !times.isEmpty else { return "n/a" }
        let distribution = DBProof.Distribution(times)
        return "median \(ms(distribution.median)) ms, p90 \(ms(distribution.p90)), max \(ms(distribution.sorted.last ?? 0)) over \(times.count) runs"
    }

    /// The step's WAL sizes in MB: median and max over the runs.
    private static func walText(_ bytes: [Int]) -> String {
        let sorted = bytes.sorted()
        guard let largest = sorted.last else { return "n/a" }
        func mb(_ value: Int) -> String { String(format: "%.1f", Double(value) / 1_048_576) }
        return "median \(mb(sorted[sorted.count / 2])) MB, max \(mb(largest)) MB over \(sorted.count) runs"
    }
}
