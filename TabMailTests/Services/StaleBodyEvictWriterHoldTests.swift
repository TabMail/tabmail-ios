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
///   the step. It must not grow with the number of kept stale bodies;
/// - what a run costs in disk reads: the pages every connection of the pool
///   fetches during one run. It must not grow with the bodies that are NOT stale,
///   wherever the run reads them (writer or reader).
@Suite("Stale-body evict: what one write holds and what a run reads")
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
    /// a test is about their absence.
    static func makeFixture(buildsDeferredIndexes: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connections = ConnectionRegistry()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.automaticMemoryManagement = false
        configuration.persistentReadOnlyConnections = true
        configuration.prepareDatabase { db in connections.register(db) }
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
    static func seedKeptInboxBodies(_ fixture: Fixture, uids: Range<Int>) throws {
        try fixture.pool.write { db in
            for uid in uids {
                let header = MessageHeader(
                    messageId: String(uid), subject: "Kept \(uid)", from: "sender@example.com",
                    fromAddress: "sender@example.com", to: "user@example.com",
                    date: Date().addingTimeInterval(-Double(uid) * 60), snippet: "",
                    folderId: fixture.inboxFolderId, accountId: fixture.accountId, folderPath: "INBOX",
                    isInInbox: true)
                try header.insert(db)
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: [header.id, bodyHTML, staleFetchedAt])
            }
        }
    }

    /// Archive messages with a stale body, a day apart: the newest
    /// `bodyCacheRecentPerFolder` keep theirs, the older ones are evicted.
    /// Returns their ids, newest first.
    static func seedArchiveBodies(_ fixture: Fixture, count: Int) throws -> [String] {
        try fixture.pool.write { db -> [String] in
            var ids: [String] = []
            for index in 0..<count {
                let header = MessageHeader(
                    messageId: String(900_000 + index), subject: "Archived \(index)", from: "sender@example.com",
                    fromAddress: "sender@example.com", to: "user@example.com",
                    date: Date().addingTimeInterval(-Double(index + 1) * 86_400), snippet: "",
                    folderId: fixture.archiveFolderId, accountId: fixture.accountId, folderPath: "Archive",
                    isInInbox: false)
                try header.insert(db)
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: [header.id, bodyHTML, staleFetchedAt])
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

    /// One evict run: the writer's per-write reading, and the pages every
    /// connection of the pool fetched during it.
    static func measuredRun(
        _ fixture: Fixture, meter: WriterWorkMeter
    ) throws -> (writes: WriterWorkMeter.Reading, pagesRead: Int) {
        fixture.pool.writeWithoutTransaction { db in meter.start(db) }
        let before = fixture.connections.pagesSoFar
        SyncEngine.runEvictStaleBodies(
            dbPool: PrioritizedDatabase(pool: fixture.pool, priority: .background), undoProtectedBodyIds: [])
        let after = fixture.connections.pagesSoFar
        return (meter.current, after - before)
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

        try Self.seedKeptInboxBodies(fixture, uids: (fewKept + 1)..<(manyKept + 1))
        let many = try Self.measuredRun(fixture, meter: meter).writes
        let afterSecondRun = try Self.bodyIds(fixture)
        #expect(afterSecondRun.count == manyKept + recent, "every kept body stays")

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

    @Test("A run reads no more with ten times the bodies that are not stale")
    func aRunReadsOnlyTheStaleBodies() throws {
        let meter = WriterWorkMeter()
        let fixture = try Self.observedFixture(meter)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let kept = 30
        let fewFresh = 1_000
        let manyFresh = 10 * fewFresh
        try Self.seedKeptInboxBodies(fixture, uids: 1..<(kept + 1))
        try Self.seedFreshBodies(fixture, ids: 0..<fewFresh)

        let few = try Self.measuredRun(fixture, meter: meter).pagesRead
        let afterFirstRun = try Self.bodyIds(fixture)
        #expect(afterFirstRun.count == kept + fewFresh, "the rules keep every stale inbox body; fresh ones are not stale")
        let tableFew = try Self.wholeTableRead(fixture)

        try Self.seedFreshBodies(fixture, ids: fewFresh..<manyFresh)
        let many = try Self.measuredRun(fixture, meter: meter).pagesRead
        let afterSecondRun = try Self.bodyIds(fixture)
        #expect(afterSecondRun.count == kept + manyFresh, "the rules keep every stale inbox body; fresh ones are not stale")
        let tableMany = try Self.wholeTableRead(fixture)

        // Non-vacuous, and independent of the code under test: reading the table
        // costs over four times the pages at the second size, so a run that read
        // it could not pass the ratio below.
        #expect(tableFew.rows == kept + fewFresh && tableMany.rows == kept + manyFresh,
                "the control read every body: \(tableFew.rows), \(tableMany.rows)")
        #expect(tableMany.pages > 4 * tableFew.pages,
                "reading the table cost \(tableFew.pages) then \(tableMany.pages) pages; the fixture does not grow it enough to discriminate")

        // The property: the pages a run reads, on any connection, stay with the
        // stale bodies (with the search walking the table they grow about ten
        // times here).
        let ratio = Double(many) / Double(max(few, 1))
        #expect(ratio < 2,
                "a run read \(ratio)x the pages with 10x the fresh bodies (\(few) -> \(many) pages)")
    }
}
