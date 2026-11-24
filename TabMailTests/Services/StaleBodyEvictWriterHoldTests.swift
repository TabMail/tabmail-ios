/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing
@testable import TabMail

/// #1354: tapping Send could spin for 14-16 s before the compose screen closed.
/// Send's writes (the draft save, the queued send, the outbox claim) each waited
/// that long for SQLite's single writer while the stale-body evict step held it:
/// every page of the step searched `messageBody` for its next stale rows INSIDE
/// its write, stepping over every body kept so far (`OFFSET`), so one write held
/// the writer longer the more stale bodies the rules keep, and every run read the
/// whole table.
///
/// Two properties are pinned here, both measured as pages fetched (pager cache
/// hits plus misses), which is deterministic, unlike a wall-clock wait:
/// - what a `.priority` write can wait behind: the writer work of any ONE write of
///   the step. It must not grow with the number of kept stale bodies, nor with
///   the size of their HTML;
/// - what a run costs in disk reads: the pages every connection of the pool
///   fetches during one run. It must not grow with the bodies that are NOT stale,
///   wherever the run reads them (writer or reader), by a ratio or by more than a
///   few pages.
// A run that never ends (a cursor that stops moving) fails here instead of hanging.
@Suite("Stale-body evict: what one write holds and what a run reads", .timeLimit(.minutes(1)))
struct StaleBodyEvictWriterHoldTests {

    /// Pages a connection has fetched so far (cumulative, never reset, so the
    /// per-write meter and the per-run total can both read it).
    static func pagesSoFar(_ handle: OpaquePointer) -> Int {
        var hits: Int32 = 0
        var misses: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &hits, &highwater, 0)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &misses, &highwater, 0)
        return Int(hits) + Int(misses)
    }

    /// Pages fetched by the writer connection in each transaction it ends.
    /// GRDB notifies an observer of every commit, an empty deferred one included
    /// (a transaction that only read), so a page whose bodies are all kept counts.
    final class WriterWorkMeter: TransactionObserver, Sendable {
        struct Reading {
            var transactions = 0
            var mostPagesInOneTransaction = 0
        }

        private struct State {
            var reading = Reading()
            var pagesAtLastEnd = 0
        }

        private let state = Mutex(State())

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseDidCommit(_ db: Database) { endTransaction(db) }
        func databaseDidRollback(_ db: Database) { endTransaction(db) }

        private func endTransaction(_ db: Database) {
            guard let handle = db.sqliteConnection else { return }
            let now = StaleBodyEvictWriterHoldTests.pagesSoFar(handle)
            state.withLock {
                $0.reading.transactions += 1
                $0.reading.mostPagesInOneTransaction = max(
                    $0.reading.mostPagesInOneTransaction, now - $0.pagesAtLastEnd)
                $0.pagesAtLastEnd = now
            }
        }

        /// Starts a new measurement. Must run on the writer connection.
        func start(_ db: Database) {
            let now = db.sqliteConnection.map(StaleBodyEvictWriterHoldTests.pagesSoFar) ?? 0
            state.withLock { $0 = State(reading: Reading(), pagesAtLastEnd: now) }
        }

        var current: Reading { state.withLock { $0.reading } }
    }

    /// Every connection the pool opens, the writer and each reader, registered as
    /// it opens (`Configuration.prepareDatabase`). The fixture keeps read-only
    /// connections open and turns automatic memory management off, so no reader is
    /// closed while a test holds its handle, and the counters are read only before
    /// and after a run, while every connection is idle.
    final class ConnectionRegistry: Sendable {
        private let handles = Mutex<[UInt]>([])

        func register(_ db: Database) {
            guard let handle = db.sqliteConnection else { return }
            handles.withLock { $0.append(UInt(bitPattern: handle)) }
        }

        /// Pages fetched so far by every connection the pool has opened.
        var pagesSoFar: Int {
            handles.withLock { $0 }.reduce(0) { total, bits in
                guard let handle = OpaquePointer(bitPattern: bits) else { return total }
                return total + StaleBodyEvictWriterHoldTests.pagesSoFar(handle)
            }
        }
    }

    struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let connections: ConnectionRegistry
        let accountId = "evict-hold"
        var inboxFolderId: String { MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX") }
        var archiveFolderId: String { MessageIdentity.folderId(accountId: accountId, folderPath: "Archive") }
    }

    /// A migrated pool with one account, an INBOX and an Archive. The evict step
    /// runs only once its deferred index exists (`runEvictStaleBodiesIfIndexed`),
    /// so the fixture builds the deferred indexes through the production DDL unless
    /// a test is about their absence. With `readersFail`, no reader connection can
    /// open, so every read fails while the writer works.
    static func makeFixture(buildsDeferredIndexes: Bool = true, readersFail: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connections = ConnectionRegistry()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.automaticMemoryManagement = false
        configuration.persistentReadOnlyConnections = true
        configuration.prepareDatabase { db in
            // A pool opens its readers read-only and its writer read-write.
            if readersFail && db.configuration.readonly {
                throw DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "the fixture's readers cannot open")
            }
            connections.register(db)
        }
        let pool: DatabasePool
        do {
            pool = try DatabasePool(
                path: directory.appendingPathComponent("test.sqlite").path,
                configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let fixture = Fixture(pool: pool, directory: directory, connections: connections)
        do {
            try AppDatabase.runMigrations(on: pool)
            try pool.write { db in
                var account = Account(
                    emailAddress: "\(fixture.accountId)@example.com", displayName: "T", provider: .imap)
                account.id = fixture.accountId
                try account.insert(db)
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: fixture.accountId).insert(db)
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: fixture.accountId).insert(db)
                if buildsDeferredIndexes {
                    try SyncEngine.createDeferredIndexes(db)
                }
            }
        } catch {
            // A setup that fails leaves no pool open and no directory behind.
            TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory)
            throw error
        }
        return fixture
    }

    /// A body cached longer ago than the TTL, relative to now (no fixed dates).
    static var staleFetchedAt: Date {
        Date().addingTimeInterval(-Double(SyncConfig.bodyCacheTTLHours + 1) * 3600)
    }

    /// Large enough to be stored on overflow pages, as a real email's HTML is:
    /// `fetchedAt` is stored after it, so reading `fetchedAt` from the row reads them.
    static let bodyHTML = "<p>" + String(repeating: "x", count: 16_000) + "</p>"

    /// Inbox messages with a stale body: the rules keep every one of them.
    /// `fetchedAt` is stored as given (a shared value makes a tie); by default each
    /// body gets a stale time of its own, in insertion order.
    static func seedKeptInboxBodies(
        _ fixture: Fixture, uids: Range<Int>, html: String = bodyHTML, fetchedAt: DatabaseValue? = nil
    ) throws {
        try fixture.pool.write { db in
            for uid in uids {
                let header = MessageHeader(
                    messageId: String(uid), subject: "Kept \(uid)", from: "sender@example.com",
                    fromAddress: "sender@example.com", to: "user@example.com",
                    date: Date().addingTimeInterval(-Double(uid) * 60), snippet: "",
                    folderId: fixture.inboxFolderId, accountId: fixture.accountId, folderPath: "INBOX",
                    isInInbox: true)
                try header.insert(db)
                let stored: DatabaseValue = fetchedAt ?? staleFetchedAt.databaseValue
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: [header.id, html, stored])
            }
        }
    }

    /// Archive messages with a stale body, a day apart: the newest
    /// `bodyCacheRecentPerFolder` keep theirs, the older ones are evicted.
    /// Returns their ids in insertion order, which is also the evict step's page
    /// order unless `fetchedAt` is given: newest first, or oldest first with
    /// `oldestFirst`. `from` continues an earlier call: its messages are older than
    /// every one that call seeded. `folderPath` names another non-inbox folder the
    /// test has added.
    static func seedArchiveBodies(
        _ fixture: Fixture, count: Int, from: Int = 0, fetchedAt: DatabaseValue? = nil, oldestFirst: Bool = false,
        folderPath: String = "Archive"
    ) throws -> [String] {
        try fixture.pool.write { db -> [String] in
            var ids: [String] = []
            for index in 0..<count {
                let age = oldestFirst ? from + count - index : from + index + 1
                let header = MessageHeader(
                    messageId: String(900_000 + from + index), subject: "Archived \(from + index)",
                    from: "sender@example.com",
                    fromAddress: "sender@example.com", to: "user@example.com",
                    date: Date().addingTimeInterval(-Double(age) * 86_400), snippet: "",
                    folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: folderPath),
                    accountId: fixture.accountId, folderPath: folderPath,
                    isInInbox: false)
                try header.insert(db)
                let stored: DatabaseValue = fetchedAt ?? staleFetchedAt.databaseValue
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: [header.id, bodyHTML, stored])
                ids.append(header.id)
            }
            return ids
        }
    }

    /// Bodies cached just now: no run may read them. Small, so a large table
    /// stays quick to build; a full read still grows with their number.
    static func seedFreshBodies(_ fixture: Fixture, ids: Range<Int>) throws {
        let html = "<p>" + String(repeating: "y", count: 1_000) + "</p>"
        try fixture.pool.write { db in
            for index in ids {
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: ["fresh-\(index)", html, Date()])
            }
        }
    }

    static func bodyIds(_ fixture: Fixture) throws -> Set<String> {
        try fixture.pool.read { db in try Set(String.fetchAll(db, sql: "SELECT id FROM messageBody")) }
    }

    /// What reading every body costs: a scan that reads each row to its last
    /// column, and the number of rows it read.
    static func wholeTableRead(_ fixture: Fixture) throws -> (pages: Int, rows: Int) {
        let before = fixture.connections.pagesSoFar
        let rows = try fixture.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody NOT INDEXED WHERE icsText IS NULL") ?? 0
        }
        return (fixture.connections.pagesSoFar - before, rows)
    }

    /// One evict run as the maintenance pass runs it, through its index gate
    /// (`runEvictStaleBodiesIfIndexed`): the writer's per-write reading, and the
    /// pages every connection of the pool fetched from before the gate's check to
    /// the run's end, so a read the gate adds counts as the run's.
    static func measuredRun(
        _ fixture: Fixture, meter: WriterWorkMeter
    ) throws -> (writes: WriterWorkMeter.Reading, pagesRead: Int) {
        fixture.pool.writeWithoutTransaction { db in meter.start(db) }
        let run = gatedRun(fixture)
        #expect(run.ran, "the gated step did not run, though the fixture built its index")
        return (meter.current, run.pagesRead)
    }

    /// The gate and whatever it runs, as the maintenance pass calls it: whether the
    /// step ran, and the pages every connection of the pool fetched from before the
    /// gate's check to the end.
    static func gatedRun(_ fixture: Fixture) -> (ran: Bool, pagesRead: Int) {
        let before = fixture.connections.pagesSoFar
        let ran = SyncEngine.runEvictStaleBodiesIfIndexed(
            dbPool: PrioritizedDatabase(pool: fixture.pool, priority: .background), undoProtectedBodyIds: [])
        return (ran, fixture.connections.pagesSoFar - before)
    }

    static func observedFixture(
        _ meter: WriterWorkMeter
    ) throws -> Fixture {
        let fixture = try makeFixture()
        fixture.pool.writeWithoutTransaction { db in
            db.add(transactionObserver: meter, extent: .observerLifetime)
        }
        return fixture
    }

    @Test("One write of the evict step holds the writer no longer with five times the kept stale bodies")
    func oneWriteDoesNotGrowWithTheKeptStaleBodies() throws {
        let meter = WriterWorkMeter()
        let fixture = try Self.observedFixture(meter)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let fewKept = 300
        let manyKept = 5 * fewKept
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let olderArchived = 20
        try Self.seedKeptInboxBodies(fixture, uids: 1..<(fewKept + 1))
        let archived = try Self.seedArchiveBodies(fixture, count: recent + olderArchived)

        let few = try Self.measuredRun(fixture, meter: meter).writes

        let afterFirstRun = try Self.bodyIds(fixture)
        let evictedArchive = archived.filter { !afterFirstRun.contains($0) }
        #expect(evictedArchive == Array(archived.suffix(olderArchived)),
                "the archive bodies past the newest \(recent) are evicted, and only they")
        #expect(afterFirstRun.count == fewKept + recent, "every kept body stays")
        let tableFew = try Self.wholeTableRead(fixture)

        try Self.seedKeptInboxBodies(fixture, uids: (fewKept + 1)..<(manyKept + 1))
        // Victims cached after every kept body, so they come last in the run's page
        // order, behind more pages of kept bodies than the first run had in all: a
        // run that stopped after a fixed number of pages would never reach them.
        let lateVictims = try Self.seedArchiveBodies(fixture, count: olderArchived, from: recent + olderArchived)
        let many = try Self.measuredRun(fixture, meter: meter).writes
        let afterSecondRun = try Self.bodyIds(fixture)
        #expect(afterSecondRun.count == manyKept + recent, "every kept body stays")
        #expect(afterSecondRun.isDisjoint(with: lateVictims),
                "the archive bodies behind the \(manyKept) kept ones are evicted")
        let tableMany = try Self.wholeTableRead(fixture)

        // Non-vacuous, and independent of the code under test: reading the kept
        // bodies costs over twice the pages the second time, so a write that read
        // them would break the bound below.
        #expect(tableFew.rows == fewKept + recent && tableMany.rows == manyKept + recent,
                "the control read every body: \(tableFew.rows), \(tableMany.rows)")
        #expect(tableMany.pages > 2 * tableFew.pages,
                "reading the table cost \(tableFew.pages) then \(tableMany.pages) pages; the fixture does not grow it enough to discriminate")

        // Non-vacuous: each run wrote once per page of its stale bodies.
        let pagesFew = fewKept / SyncConfig.pruneChunkSize
        let pagesMany = manyKept / SyncConfig.pruneChunkSize
        #expect(few.transactions >= pagesFew, "the first run's writes were measured: \(few.transactions)")
        #expect(many.transactions >= pagesMany, "the second run's writes were measured: \(many.transactions)")
        #expect(few.mostPagesInOneTransaction > 0)

        // The property: what a priority write can wait behind does not grow with
        // the kept stale bodies (with the search inside the write it grows about
        // five times here).
        let ratio = Double(many.mostPagesInOneTransaction) / Double(max(few.mostPagesInOneTransaction, 1))
        #expect(ratio < 2,
                "one write's writer work grew \(ratio)x with 5x the kept stale bodies (\(few.mostPagesInOneTransaction) -> \(many.mostPagesInOneTransaction) pages)")
    }

    /// Moves each of these bodies' `fetchedAt` by `hours`, each keeping a time of its own.
    static func shiftFetchedAt(_ fixture: Fixture, of ids: Set<String>, byHours hours: Int) throws {
        try fixture.pool.write { db in
            for id in ids {
                guard let fetchedAt = try Date.fetchOne(
                    db, sql: "SELECT fetchedAt FROM messageBody WHERE id = ?", arguments: [id]) else { continue }
                try db.execute(
                    sql: "UPDATE messageBody SET fetchedAt = ? WHERE id = ?",
                    arguments: [fetchedAt.addingTimeInterval(Double(hours) * 3600), id])
            }
        }
    }

    /// What counting every stale body through the evict step's index costs (a
    /// walk of its stale range), and how many it counted.
    static func staleRangeRead(_ fixture: Fixture) throws -> (pages: Int, rows: Int) {
        let cutoff = Date().addingTimeInterval(-Double(SyncConfig.bodyCacheTTLHours) * 3600)
        let before = fixture.connections.pagesSoFar
        let rows = try fixture.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messageBody INDEXED BY \(SyncEngine.staleBodyIndexName) WHERE fetchedAt < ?",
                arguments: [cutoff]) ?? 0
        }
        return (fixture.connections.pagesSoFar - before, rows)
    }

    /// How many more pages the largest write of the second run below may fetch
    /// than the first run's. The two runs see the same tables, row for row, so a
    /// page of the step costs the same in both; only which bodies are stale differs.
    /// Counting the stale bodies through the index in each write adds several
    /// times this at the second run's size.
    static let writeGrowthSlackPages = 20

    @Test("One write of the evict step holds the writer no longer when forty times the bodies are stale")
    func oneWriteDoesNotGrowWithTheStaleBodies() throws {
        let meter = WriterWorkMeter()
        let fixture = try Self.observedFixture(meter)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let fewStale = 300
        let allBodies = 40 * fewStale
        // Inbox bodies, all kept by the rules, small so the table is quick to build.
        let html = "<p>" + String(repeating: "s", count: 100) + "</p>"
        try Self.seedKeptInboxBodies(fixture, uids: 1..<(fewStale + 1), html: html)
        let firstStale = try Self.bodyIds(fixture)
        try Self.seedKeptInboxBodies(fixture, uids: (fewStale + 1)..<(allBodies + 1), html: html)
        let restOfThem = try Self.bodyIds(fixture).subtracting(firstStale)
        #expect(firstStale.count == fewStale && restOfThem.count == allBodies - fewStale)
        // The rest are cached later than the TTL for the first run, then moved back.
        let freshForHours = SyncConfig.bodyCacheTTLHours + 2
        try Self.shiftFetchedAt(fixture, of: restOfThem, byHours: freshForHours)

        let few = try Self.measuredRun(fixture, meter: meter).writes
        let staleFew = try Self.staleRangeRead(fixture)
        let afterFirstRun = try Self.bodyIds(fixture)
        #expect(afterFirstRun.count == allBodies, "every kept body stays")

        try Self.shiftFetchedAt(fixture, of: restOfThem, byHours: -freshForHours)
        let many = try Self.measuredRun(fixture, meter: meter).writes
        let staleMany = try Self.staleRangeRead(fixture)
        let afterSecondRun = try Self.bodyIds(fixture)
        #expect(afterSecondRun.count == allBodies, "every kept body stays")

        // Non-vacuous: each run wrote once per page of its stale bodies, and
        // counting the stale bodies through the index (independent of the code under
        // test) costs more than twice the slack at the second size, so a write that
        // counted them could not pass the bound below.
        #expect(staleFew.rows == fewStale && staleMany.rows == allBodies,
                "the control found the stale bodies: \(staleFew.rows), \(staleMany.rows)")
        #expect(few.transactions >= fewStale / SyncConfig.pruneChunkSize,
                "the first run's writes were measured: \(few.transactions)")
        #expect(many.transactions >= allBodies / SyncConfig.pruneChunkSize,
                "the second run's writes were measured: \(many.transactions)")
        #expect(few.mostPagesInOneTransaction > 0)
        #expect(staleMany.pages - staleFew.pages > 2 * Self.writeGrowthSlackPages,
                "counting the stale bodies cost \(staleFew.pages) then \(staleMany.pages) pages; the fixture does not grow it enough to discriminate")

        // The property: what a priority write can wait behind does not grow with
        // the number of stale bodies.
        #expect(many.mostPagesInOneTransaction - few.mostPagesInOneTransaction <= Self.writeGrowthSlackPages,
                "one write's writer work grew from \(few.mostPagesInOneTransaction) to \(many.mostPagesInOneTransaction) pages with 40x the stale bodies; the slack is \(Self.writeGrowthSlackPages)")
    }

    /// What reading every body's HTML to its end costs, and the number of rows
    /// whose HTML it read.
    static func wholeHTMLRead(_ fixture: Fixture) throws -> (pages: Int, rows: Int) {
        let before = fixture.connections.pagesSoFar
        let rows = try fixture.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody NOT INDEXED WHERE htmlContent LIKE '%</p>'") ?? 0
        }
        return (fixture.connections.pagesSoFar - before, rows)
    }

    @Test("One write of the evict step holds the writer no longer when the kept bodies are 64 times wider")
    func oneWriteDoesNotGrowWithTheKeptBodiesWidth() throws {
        let meter = WriterWorkMeter()
        let fixture = try Self.observedFixture(meter)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let kept = 300
        let narrowHTML = "<p>" + String(repeating: "n", count: 1_000) + "</p>"
        let wideHTML = "<p>" + String(repeating: "w", count: 64_000) + "</p>"
        // The wide HTML lives on overflow pages, and SQLite reads an overflow page
        // straight from the database file, past the page cache and so past both
        // counters here, once a checkpoint has moved it out of the WAL. The wide
        // update writes far more than the automatic checkpoint's 1,000 pages, so
        // with it on the HTML would be checkpointed at once and every read of it,
        // the step's or the control's, would go uncounted. With it off the HTML
        // stays in the WAL, where every read goes through the page cache. The
        // control below is read after the run, so it shows that held throughout.
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        }
        try Self.seedKeptInboxBodies(fixture, uids: 1..<(kept + 1), html: narrowHTML)

        let narrow = try Self.measuredRun(fixture, meter: meter).writes
        let afterNarrowRun = try Self.bodyIds(fixture)
        #expect(afterNarrowRun.count == kept, "every kept body stays")
        let narrowRead = try Self.wholeHTMLRead(fixture)

        // Same rows, same `fetchedAt`, 64 times the HTML.
        try fixture.pool.write { db in
            try db.execute(sql: "UPDATE messageBody SET htmlContent = ?", arguments: [wideHTML])
        }
        let wide = try Self.measuredRun(fixture, meter: meter).writes
        let afterWideRun = try Self.bodyIds(fixture)
        #expect(afterWideRun.count == kept, "every kept body stays")
        let wideRead = try Self.wholeHTMLRead(fixture)

        // Non-vacuous: each run wrote once per page of its stale bodies, and
        // reading the kept HTML (independent of the code under test) costs over four
        // times the pages at the second width, so a write that read it could not
        // pass the ratio below.
        let pages = kept / SyncConfig.pruneChunkSize
        #expect(narrow.transactions >= pages, "the first run's writes were measured: \(narrow.transactions)")
        #expect(wide.transactions >= pages, "the second run's writes were measured: \(wide.transactions)")
        #expect(narrow.mostPagesInOneTransaction > 0)
        #expect(narrowRead.rows == kept && wideRead.rows == kept,
                "the control read every kept body's HTML: \(narrowRead.rows), \(wideRead.rows)")
        #expect(wideRead.pages > 4 * narrowRead.pages,
                "reading the kept HTML cost \(narrowRead.pages) then \(wideRead.pages) pages; the fixture does not widen it enough to discriminate")

        // The property: what a priority write can wait behind does not grow with
        // the width of the kept bodies.
        let ratio = Double(wide.mostPagesInOneTransaction) / Double(max(narrow.mostPagesInOneTransaction, 1))
        #expect(ratio < 2,
                "one write's writer work grew \(ratio)x with 64x wider kept bodies (\(narrow.mostPagesInOneTransaction) -> \(wide.mostPagesInOneTransaction) pages)")
    }

    /// How many more pages the second run below may read than the first. The two
    /// runs read the same number of stale bodies and evict the same number, so
    /// only a deeper B-tree under ten times the rows separates them (a few pages).
    /// Walking even a compact index of the whole table (a `COUNT(*)`) adds several
    /// times this at these sizes, which the ratio alone would let through.
    static let runGrowthSlackPages = 20

    @Test("A run reads no more with ten times the bodies that are not stale")
    func aRunReadsOnlyTheStaleBodies() throws {
        let meter = WriterWorkMeter()
        let fixture = try Self.observedFixture(meter)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let kept = 30
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let victimsPerRun = 5
        let fewFresh = 1_000
        let manyFresh = 10 * fewFresh
        try Self.seedKeptInboxBodies(fixture, uids: 1..<(kept + 1))
        // The newest `recent` archive bodies are kept by every run; the older ones
        // are each run's victims, so each run is seen to evict.
        let archived = try Self.seedArchiveBodies(fixture, count: recent + victimsPerRun)
        try Self.seedFreshBodies(fixture, ids: 0..<fewFresh)
        let keptIds = try Self.bodyIds(fixture).subtracting(archived.suffix(victimsPerRun))

        let few = try Self.measuredRun(fixture, meter: meter).pagesRead
        let afterFirstRun = try Self.bodyIds(fixture)
        #expect(afterFirstRun == keptIds,
                "the run evicts the \(victimsPerRun) older archive bodies and keeps the rest; fresh ones are not stale")
        let tableFew = try Self.wholeTableRead(fixture)

        let secondVictims = try Self.seedArchiveBodies(fixture, count: victimsPerRun, from: recent + victimsPerRun)
        try Self.seedFreshBodies(fixture, ids: fewFresh..<manyFresh)
        let keptAfterGrowth = try Self.bodyIds(fixture).subtracting(secondVictims)
        let many = try Self.measuredRun(fixture, meter: meter).pagesRead
        let afterSecondRun = try Self.bodyIds(fixture)
        #expect(afterSecondRun == keptAfterGrowth,
                "the run evicts the \(victimsPerRun) new older archive bodies and keeps the rest; fresh ones are not stale")
        #expect(afterSecondRun.count == kept + recent + manyFresh)
        let tableMany = try Self.wholeTableRead(fixture)

        // Non-vacuous, and independent of the code under test: reading the table
        // costs over four times the pages at the second size, so a run that read
        // it could not pass the bounds below.
        let tableRowsFew = kept + recent + fewFresh
        let tableRowsMany = kept + recent + manyFresh
        #expect(tableFew.rows == tableRowsFew && tableMany.rows == tableRowsMany,
                "the control read every body: \(tableFew.rows), \(tableMany.rows)")
        #expect(tableMany.pages > 4 * tableFew.pages,
                "reading the table cost \(tableFew.pages) then \(tableMany.pages) pages; the fixture does not grow it enough to discriminate")

        // The property: the pages a run reads, on any connection, stay with the
        // stale bodies (with the search walking the table they grow about ten
        // times here, and walking a compact index of it still adds more than the
        // slack).
        let ratio = Double(many) / Double(max(few, 1))
        #expect(ratio < 2,
                "a run read \(ratio)x the pages with 10x the fresh bodies (\(few) -> \(many) pages)")
        #expect(many - few <= Self.runGrowthSlackPages,
                "a run read \(many - few) more pages with 10x the fresh bodies (\(few) -> \(many)); the slack is \(Self.runGrowthSlackPages)")
    }

    /// The same bound where the run has nothing to evict: with the index built and
    /// no body stale, the step runs and finds an empty first page; with no index,
    /// the gate holds the step back. Neither may read the table, on any connection.
    @Test("A run with nothing stale, or one its gate holds back, reads no more with ten times the bodies",
          arguments: [true, false])
    func aRunWithNothingToEvictReadsNoMore(indexed: Bool) throws {
        let fixture = try Self.makeFixture(buildsDeferredIndexes: indexed)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let fewFresh = 1_000
        let manyFresh = 10 * fewFresh
        try Self.seedFreshBodies(fixture, ids: 0..<fewFresh)
        // A read before the first measured run, so a reader's first look at the
        // schema after the migrations is not counted in it.
        let seeded = try Self.bodyIds(fixture)
        #expect(seeded.count == fewFresh)
        let few = Self.gatedRun(fixture)
        let afterFirstRun = try Self.bodyIds(fixture)
        let tableFew = try Self.wholeTableRead(fixture)

        try Self.seedFreshBodies(fixture, ids: fewFresh..<manyFresh)
        let many = Self.gatedRun(fixture)
        let afterSecondRun = try Self.bodyIds(fixture)
        let tableMany = try Self.wholeTableRead(fixture)

        #expect(few.ran == indexed && many.ran == indexed,
                "the gate let the step run \(few.ran), \(many.ran); its index is built: \(indexed)")
        #expect(afterFirstRun.count == fewFresh && afterSecondRun.count == manyFresh, "every body stays")
        // Non-vacuous, and independent of the code under test: reading the table
        // costs over four times the pages at the second size.
        #expect(tableFew.rows == fewFresh && tableMany.rows == manyFresh,
                "the control read every body: \(tableFew.rows), \(tableMany.rows)")
        #expect(tableMany.pages > 4 * tableFew.pages,
                "reading the table cost \(tableFew.pages) then \(tableMany.pages) pages; the fixture does not grow it enough to discriminate")

        // The property: such a run reads no more as the table grows (a count of
        // the table, even through a compact index, adds more than the slack).
        #expect(many.pagesRead - few.pagesRead <= Self.runGrowthSlackPages,
                "a run read \(few.pagesRead) then \(many.pagesRead) pages with 10x the bodies; the slack is \(Self.runGrowthSlackPages)")
    }
}
