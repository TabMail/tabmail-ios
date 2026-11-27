/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
import UIKit
@testable import TabMail

/// ADR-IOS-121 (#1450): both databases use `auto_vacuum = INCREMENTAL`. A new file starts
/// on it; an older file is switched once by the upgrade the user starts
/// (`SyncEngine.runDatabaseUpgrade`, one `VACUUM` per database,
/// `DatabaseVacuum.switchToIncremental`), when the device has room, carrying the planner
/// statistics marker across it and emptying the inbox banner observer's rowid map. The
/// background processing job then gives empty pages back in short steps
/// (`DatabaseVacuum.giveBackEmptyPages`) on upgraded databases only, and stops between
/// steps when the app comes forward. An upgrade's `VACUUM` starts only while the
/// databases are not suspended, checked again on the writer. Every `VACUUM` keeps every
/// row's rowid.
///
/// `.serialized, .processGlobalState`: the email switch takes the planner statistics
/// refresh's process-wide latch, and the suspension test posts the process-wide
/// `Database.suspendNotification`.
@Suite("Giving the databases' empty pages back", .serialized, .processGlobalState)
struct IncrementalVacuumTests {

    /// More free space than any fixture here needs.
    private static let plentyOfSpace: Int64 = 1 << 40
    /// Mail rows seeded, the rows a large delete keeps, and each row's snippet size:
    /// enough empty pages for the file to shrink by most of its size.
    private static let seededMail = 1_500
    private static let keptMail = 50
    private static let snippetBytes = 4_096
    /// Pages per step in the step tests: small, so the empty pages take many steps.
    private static let smallStep = 16
    /// `PRAGMA temp_store` value of MEMORY, which the search database's connections use.
    private static let tempStoreMemory = 2

    // MARK: - Fixtures

    /// Records the SQL of every statement a fixture's connections run, and runs a
    /// one-shot action when a `VACUUM` starts (`onNextVacuum`), on the connection's
    /// thread, before the `VACUUM` does any work.
    private final class StatementLog: Sendable {
        private let statements = Mutex<[String]>([])
        private let vacuumAction = Mutex<(@Sendable () -> Void)?>(nil)
        func record(_ sql: String) {
            statements.withLock { $0.append(sql) }
            guard sql == "VACUUM" else { return }
            let action = vacuumAction.withLock { action in
                defer { action = nil }
                return action
            }
            action?()
        }
        var all: [String] { statements.withLock { $0 } }
        func onNextVacuum(_ action: @escaping @Sendable () -> Void) { vacuumAction.withLock { $0 = action } }
    }

    private struct EmailFixture {
        let pool: DatabasePool
        let directory: URL
        let log: StatementLog
        var path: String { pool.path }
        var background: PrioritizedDatabase { PrioritizedDatabase(pool: pool, priority: .background) }
    }

    private static func temporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A migrated email database in a temporary folder, created as every install before
    /// ADR-IOS-121 was: on `auto_vacuum = NONE`. Every connection keeps temporary data in
    /// memory, as the search database's do, so a test can see the switch restore that
    /// setting, and records its statements. Like the app's pools, it is suspended by
    /// `Database.suspendNotification`.
    private func makeEmailFixture() throws -> EmailFixture {
        let directory = try Self.temporaryDirectory("incremental-vacuum")
        let log = StatementLog()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in log.record(event.expandedDescription) }
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        return EmailFixture(pool: pool, directory: directory, log: log)
    }

    /// `seededMail` inbox headers with large snippets, dated back from now.
    private func seedMail(_ pool: DatabasePool) throws {
        let now = Date()
        let snippet = String(repeating: "x", count: Self.snippetBytes)
        try pool.write { db in
            var account = Account(emailAddress: "vacuum@example.com", displayName: "Vacuum", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            for n in 0..<Self.seededMail {
                try Self.header(messageId: String(n + 1), date: now.addingTimeInterval(-60 * Double(n)), snippet: snippet)
                    .insert(db)
            }
        }
    }

    /// A large delete that keeps `keptMail` of the seeded headers, every
    /// (seededMail / keptMail)th, so the kept rows' rowids have gaps a renumbering
    /// would close.
    private func deleteMost(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM messageHeader WHERE CAST(messageId AS INTEGER) % ? != 0",
                arguments: [Self.seededMail / Self.keptMail])
        }
    }

    private func seedMailThenDeleteMost(_ pool: DatabasePool) throws {
        try seedMail(pool)
        try deleteMost(pool)
    }

    private static func header(messageId: String, date: Date, snippet: String) -> MessageHeader {
        MessageHeader(
            messageId: messageId,
            subject: "Message \(messageId)",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: date,
            snippet: snippet,
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
    }

    /// The seeded email fixture upgraded to INCREMENTAL, then the large delete, so it
    /// holds many empty pages to give back.
    private func makeIncrementalEmailWithEmptyPages() async throws -> EmailFixture {
        let email = try makeEmailFixture()
        try seedMail(email.pool)
        let upgraded = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: Self.markerKey(), inboxObserver: nil)],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true })
        #expect(upgraded == [.upgraded("email")], "precondition: the fixture upgraded: \(upgraded)")
        try deleteMost(email.pool)
        return email
    }

    /// The search database's file, created as every install before ADR-IOS-121 was: on
    /// `auto_vacuum = NONE`, in WAL mode, with one table, so the index opens an existing
    /// file.
    private static func makeOldSearchFile(in directory: URL) throws {
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE fixture_older_install (x INTEGER)")
        }
        try queue.close()
    }

    /// A search index in a temporary folder: on an older install's file when `oldFile`,
    /// else on a new file. It holds `seededMail` emails with large subjects and their
    /// vectors, then all but `keptMail` are removed, so its file holds mostly empty pages.
    private func makeSearchIndex(oldFile: Bool) async throws -> (index: SearchIndex, directory: URL) {
        let directory = try Self.temporaryDirectory("incremental-vacuum-search")
        if oldFile { try Self.makeOldSearchFile(in: directory) }
        let index = SearchIndex(directoryForTesting: directory, statementTraceForTesting: { _ in })
        try await index.initialize()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let words = (0..<(Self.snippetBytes / 8)).map { "word\($0)" }.joined(separator: " ")
        let records = (0..<Self.seededMail).map { n in
            FTSHeaderRecord(
                contentKey: ContentKey(rawValue: "acc1:INBOX:\(n + 1)"), headerId: "acc1:INBOX:\(n + 1)",
                messageId: "\(n + 1)", subject: "Message term\(n + 1)end \(words)",
                from: "sender@example.com", to: "recipient@example.com",
                dateMs: nowMs - Int64(n) * 60_000, folderId: "acc1:INBOX")
        }
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == Self.seededMail, "precondition: every email was indexed (\(inserted))")
        try await index.storeEmbeddings((1...Self.seededMail).map {
            (contentKey: ContentKey(rawValue: "acc1:INBOX:\($0)"), embedding: Self.embedding($0))
        })
        let every = Self.seededMail / Self.keptMail
        let removed = (1...Self.seededMail).filter { $0 % every != 0 }.map { ContentKey(rawValue: "acc1:INBOX:\($0)") }
        try await index.removeMessages(contentKeys: removed)
        return (index, directory)
    }

    /// A distinct vector for email `n`: no other email's vector points the same way,
    /// so an email's own vector is its nearest.
    private static func embedding(_ n: Int) -> [Float] {
        (0..<SearchConfig.embeddingDims).map { i in Float((n * (i + 3) * 7_919 + i * 31) % 1_009) / 1_009 - 0.5 }
    }

    /// The search database's email ids by rowid, read on a connection of its own, and
    /// how many of them join their metadata row by rowid and id (the join every search
    /// and removal makes).
    private static func searchIdRows(_ path: String) throws -> (ids: [String: Int64], joined: Int) {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            var ids: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT headerId, rowid FROM message_ids") {
                let headerId: String = row["headerId"]
                let rowid: Int64 = row["rowid"]
                ids[headerId] = rowid
            }
            let joined = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_ids mi
                JOIN message_meta meta ON meta.rowid = mi.rowid AND meta.headerId = mi.headerId
                """) ?? 0
            return (ids, joined)
        }
    }

    private static func headerRowids(_ pool: DatabasePool) throws -> [String: Int64] {
        try pool.read { db in
            var byId: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, rowid FROM messageHeader") {
                let id: String = row["id"]
                let rowid: Int64 = row["rowid"]
                byId[id] = rowid
            }
            return byId
        }
    }

    private static func spaceState(_ pool: DatabasePool) throws -> DatabaseVacuum.SpaceState? {
        try pool.read { db in try DatabaseVacuum.SpaceState.read(db) }
    }

    private static func schemaVersion(_ pool: DatabasePool) throws -> Int? {
        try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
    }

    /// The writer connection's `temp_store`.
    private static func writerTempStore(_ pool: DatabasePool) throws -> Int? {
        try pool.write { db in try Int.fetchOne(db, sql: "PRAGMA temp_store") }
    }

    private static func walBytes(_ path: String) -> Int {
        (try? URL(fileURLWithPath: path + "-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
    }

    /// The size of the WAL index (`-shm`) file.
    private static func shmBytes(_ path: String) -> Int {
        (try? URL(fileURLWithPath: path + "-shm").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
    }

    private static func markerKey() -> String { "incrementalVacuumMarker-\(UUID().uuidString)" }

    // MARK: - New files

    @Test("A new email database and a new search database start on INCREMENTAL, and their read-only readers open")
    func newDatabasesStartIncremental() async throws {
        let directory = try Self.temporaryDirectory("incremental-vacuum-new")
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("tabmail.sqlite").path, configuration: AppDatabase.makeConfiguration())
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory) }
        try AppDatabase.runMigrations(on: pool)
        let emailMode = try await pool.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }
        let journal = try await pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }

        let searchDirectory = try Self.temporaryDirectory("incremental-vacuum-new-search")
        defer { try? FileManager.default.removeItem(at: searchDirectory) }
        let index = SearchIndex(directoryForTesting: searchDirectory, statementTraceForTesting: { _ in })
        try await index.initialize()
        let searchState = await index.spaceState()
        let hits = try await index.keywordSearch(query: "nothing")
        await index.closeForNuke()

        #expect(emailMode == DatabaseVacuum.incrementalMode, "the email database is INCREMENTAL: \(String(describing: emailMode))")
        #expect(journal == "wal", "and still in WAL mode: \(String(describing: journal))")
        #expect(searchState?.autoVacuum == DatabaseVacuum.incrementalMode, "the search database is INCREMENTAL: \(String(describing: searchState))")
        #expect(hits.isEmpty, "a search reads the new search database")
    }

    @Test("An existing database file keeps its mode when the app opens it")
    func anExistingFileKeepsItsMode() throws {
        let directory = try Self.temporaryDirectory("incremental-vacuum-existing")
        let path = directory.appendingPathComponent("tabmail.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE fixture_older_install (x INTEGER)") }
        try queue.close()
        let pool = try DatabasePool(path: path, configuration: AppDatabase.makeConfiguration())
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory) }
        let mode = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }
        #expect(mode == DatabaseVacuum.noneMode, "an older install's file stays on NONE until its upgrade: \(String(describing: mode))")
    }

    // MARK: - The one-time upgrade

    @Test("The email upgrade: INCREMENTAL, no empty page left, a smaller file, every row and rowid kept, temp_store FILE for the VACUUM then restored, the WAL truncated")
    func theEmailUpgrade() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let beforeRead = try Self.spaceState(email.pool)
        let before = try #require(beforeRead)
        let rowidsBefore = try Self.headerRowids(email.pool)
        let fileBefore = StorageEstimator.databaseFileBytes(ofDatabaseAt: email.path)
        let logStart = email.log.all.count

        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: Self.markerKey(), inboxObserver: nil)],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true })
        let afterRead = try Self.spaceState(email.pool)
        let after = try #require(afterRead)
        let rowidsAfter = try Self.headerRowids(email.pool)
        let fileAfter = StorageEstimator.databaseFileBytes(ofDatabaseAt: email.path)
        let wal = Self.walBytes(email.path)
        let tempStore = try Self.writerTempStore(email.pool)
        let statements = Array(email.log.all[logStart...])
        let fileStore = statements.firstIndex(of: "PRAGMA temp_store = FILE")
        let vacuum = statements.firstIndex(of: "VACUUM")
        let restore = statements.lastIndex(of: "PRAGMA temp_store = \(Self.tempStoreMemory)")
        let fileAroundVacuum: Bool = {
            guard let fileStore, let vacuum, let restore else { return false }
            return fileStore < vacuum && vacuum < restore
        }()
        let contiguous = Set(1...Int64(Self.keptMail))

        #expect(before.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's database (\(before))")
        #expect(before.freePages > before.pageCount / 2, "precondition: the delete left mostly empty pages (\(before))")
        #expect(Set(rowidsBefore.values) != contiguous, "precondition: the kept rowids have gaps a renumbering would close")
        #expect(steps == [.upgraded("email")], "upgraded: \(steps)")
        #expect(after.autoVacuum == DatabaseVacuum.incrementalMode, "now INCREMENTAL (\(after))")
        #expect(after.freePages == 0, "no empty page left (\(after))")
        #expect(after.pageCount < before.pageCount, "fewer pages: \(before.pageCount) -> \(after.pageCount)")
        #expect(fileAfter < fileBefore, "the files shrank on disk: \(fileBefore) -> \(fileAfter)")
        #expect(rowidsAfter == rowidsBefore, "every header keeps its rowid")
        #expect(fileAroundVacuum, "temp_store is FILE for the VACUUM and restored after it: \(statements)")
        #expect(tempStore == Self.tempStoreMemory, "the writer connection's temp_store is restored (\(String(describing: tempStore)))")
        #expect(wal == 0, "the TRUNCATE checkpoint emptied the WAL (\(wal) bytes)")
    }

    @Test("The search upgrade keeps every email's rowid, its metadata join, its search result and the vector search")
    func theSearchUpgradeKeepsLiveRows() async throws {
        let (index, directory) = try await makeSearchIndex(oldFile: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathRead = await index.databasePath()
        let path = try #require(pathRead)
        let targetRead = await SyncEngine.SpaceReturnTarget.search(index)
        let target = try #require(targetRead)
        let every = Self.seededMail / Self.keptMail
        let before = try Self.searchIdRows(path)
        let stateBeforeRead = await index.spaceState()
        let stateBefore = try #require(stateBeforeRead)
        let probe = Self.embedding(every)
        let nearestBefore = try await index.knnCandidates(
            queryEmbedding: probe, limit: Self.keptMail, fromDateMs: nil, toDateMs: nil,
            eligible: nil, demoActive: false, alwaysScoped: false
        ).map { $0.0 }

        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [target], availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true })
        let after = try Self.searchIdRows(path)
        let stateAfterRead = await index.spaceState()
        let stateAfter = try #require(stateAfterRead)
        let keptHits = try await index.keywordSearch(query: "term\(every)end")
        let removedHits = try await index.keywordSearch(query: "term1end")
        let nearestAfter = try await index.knnCandidates(
            queryEmbedding: probe, limit: Self.keptMail, fromDateMs: nil, toDateMs: nil,
            eligible: nil, demoActive: false, alwaysScoped: false
        ).map { $0.0 }
        let wal = Self.walBytes(path)
        await index.closeForNuke()
        let keptKeys = keptHits.map { $0.contentKey.rawValue }
        let removedKeys = removedHits.map { $0.contentKey.rawValue }
        let contiguous = Set(1...Int64(Self.keptMail))

        #expect(stateBefore.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's search database (\(stateBefore))")
        #expect(stateBefore.freePages > 0, "precondition: the removal left empty pages (\(stateBefore))")
        #expect(before.ids.count == Self.keptMail, "precondition: the kept emails (\(before.ids.count))")
        #expect(Set(before.ids.values) != contiguous, "precondition: the kept rowids have gaps a renumbering would close")
        #expect(before.joined == Self.keptMail, "precondition: every kept id joins its metadata row (\(before.joined))")
        #expect(Set(nearestBefore) == Set(before.ids.values), "precondition: every kept email has its vector")
        #expect(steps == [.upgraded("search")], "upgraded: \(steps)")
        #expect(stateAfter.autoVacuum == DatabaseVacuum.incrementalMode, "now INCREMENTAL (\(stateAfter))")
        #expect(stateAfter.freePages == 0, "no empty page left (\(stateAfter))")
        #expect(stateAfter.pageCount < stateBefore.pageCount, "fewer pages: \(stateBefore.pageCount) -> \(stateAfter.pageCount)")
        #expect(after.ids == before.ids, "every email keeps its rowid")
        #expect(after.joined == Self.keptMail, "every id still joins its metadata row by rowid (\(after.joined))")
        #expect(keptKeys == ["acc1:INBOX:\(every)"], "a kept email's own term finds that email: \(keptKeys)")
        #expect(removedKeys.isEmpty, "a removed email's term finds nothing: \(removedKeys)")
        #expect(nearestAfter == nearestBefore, "the vector search finds the same emails in the same order")
        #expect(wal == 0, "the TRUNCATE checkpoint emptied the WAL (\(wal) bytes)")
    }

    @Test("One byte too little free space: the upgrade asks for that byte, ends, and changes neither database")
    func tooLittleSpaceAsksForSpaceAndChangesNothing() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let (index, searchDirectory) = try await makeSearchIndex(oldFile: true)
        defer { try? FileManager.default.removeItem(at: searchDirectory) }
        let searchTargetRead = await SyncEngine.SpaceReturnTarget.search(index)
        let searchTarget = try #require(searchTargetRead)
        let emailBeforeRead = try Self.spaceState(email.pool)
        let emailBefore = try #require(emailBeforeRead)
        let searchBefore = await index.spaceState()
        let versionBefore = try Self.schemaVersion(email.pool)
        // One byte short of the email database's need.
        let short = SyncEngine.bytesNeededForUpgrade(liveBytes: emailBefore.liveBytes) - 1

        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: Self.markerKey(), inboxObserver: nil), searchTarget],
            availableBytes: { _ in short }, shouldRun: { true })
        let emailAfter = try Self.spaceState(email.pool)
        let searchAfter = await index.spaceState()
        let versionAfter = try Self.schemaVersion(email.pool)
        await index.closeForNuke()

        #expect(steps == [.needsSpace("email", bytesToFree: 1)], "the email database asks for one byte, and the upgrade ends there: \(steps)")
        #expect(emailAfter == emailBefore, "the email database is unchanged")
        #expect(searchAfter == searchBefore, "the search database is unchanged")
        #expect(versionAfter == versionBefore, "no VACUUM ran on the email database")
    }

    @Test("Exactly the need free: an older install's email database of mostly empty pages upgrades with room for about twice its data, far less than twice its file")
    func roomForTheDataIsEnough() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let beforeRead = try Self.spaceState(email.pool)
        let before = try #require(beforeRead)
        let available = SyncEngine.bytesNeededForUpgrade(liveBytes: before.liveBytes)

        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: Self.markerKey(), inboxObserver: nil)],
            availableBytes: { _ in available }, shouldRun: { true })
        let afterRead = try Self.spaceState(email.pool)
        let after = try #require(afterRead)

        #expect(before.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's database (\(before))")
        #expect(available < before.allBytes, "precondition: the room is less than the file's own size (\(available) free, \(before))")
        #expect(steps == [.upgraded("email")], "upgraded: \(steps)")
        #expect(after.autoVacuum == DatabaseVacuum.incrementalMode, "now INCREMENTAL (\(after))")
    }

    /// The most the need may ask above what the rewrite writes: a few percent of margin,
    /// so a phone with room for the rewrite is not asked for much more (#1449).
    private static let needOverWrittenAtMost = 1.05

    /// One switch of the email fixture, from an empty WAL: its space state before and
    /// after, the WAL before, and the bytes the `VACUUM` wrote: its temporary copy (the
    /// rewritten file's size, its pointer-map pages included), the WAL the copy passed
    /// through and the WAL index's growth.
    private static func measureSwitch(_ email: EmailFixture) throws -> (
        before: DatabaseVacuum.SpaceState, after: DatabaseVacuum.SpaceState, walBefore: Int, walAfter: Int, written: Int64
    ) {
        try email.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        let walBefore = walBytes(email.path)
        let shmBefore = shmBytes(email.path)
        let beforeRead = try spaceState(email.pool)
        let before = try #require(beforeRead)
        try email.pool.writeWithoutTransaction { db in try DatabaseVacuum.switchToIncremental(db) }
        let walAfter = walBytes(email.path)
        let shmAfter = shmBytes(email.path)
        let afterRead = try spaceState(email.pool)
        let after = try #require(afterRead)
        return (before, after, walBefore, walAfter, after.allBytes + Int64(walAfter) + Int64(shmAfter - shmBefore))
    }

    @Test("On a packed older-install database, the need covers what the VACUUM writes (its temporary copy with its pointer-map pages, the WAL the copy passes through and the WAL index's growth), and asks at most a few percent more")
    func theNeedCoversTheCopyAndItsWAL() throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMail(email.pool)
        // A plain VACUUM, still on NONE, packs the pages, so the switch copies about
        // as much as the data it is measured from: the case where the need is tightest.
        try email.pool.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        let measured = try Self.measureSwitch(email)
        let need = SyncEngine.bytesNeededForUpgrade(liveBytes: measured.before.liveBytes)

        #expect(measured.walBefore == 0, "precondition: an empty WAL, so it measures the VACUUM alone (\(measured.walBefore) bytes)")
        #expect(measured.before.autoVacuum == DatabaseVacuum.noneMode && measured.before.freePages == 0, "precondition: a packed older-install database (\(measured.before))")
        #expect(measured.after.autoVacuum == DatabaseVacuum.incrementalMode, "the switch ran (\(measured.after))")
        #expect(measured.walAfter >= measured.after.allBytes, "the rewritten file passed through the WAL: \(measured.walAfter) bytes for \(measured.after)")
        #expect(need >= measured.written,
                "the need of \(measured.before.liveBytes) bytes of data covers the copy, the WAL and the WAL index, \(measured.written) bytes")
        #expect(Double(need) <= Double(measured.written) * Self.needOverWrittenAtMost,
                "the need asks at most a few percent more than the rewrite writes: \(need) for \(measured.written)")
    }

    @Test("On an older-install database of mostly empty pages, the VACUUM writes less than the file's own size, and the need covers it")
    func aMostlyEmptyDatabaseWritesLessThanItsFile() throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let measured = try Self.measureSwitch(email)
        let need = SyncEngine.bytesNeededForUpgrade(liveBytes: measured.before.liveBytes)

        #expect(measured.walBefore == 0, "precondition: an empty WAL, so it measures the VACUUM alone (\(measured.walBefore) bytes)")
        #expect(measured.before.autoVacuum == DatabaseVacuum.noneMode && measured.before.freePages > measured.before.pageCount / 2,
                "precondition: an older-install database of mostly empty pages (\(measured.before))")
        #expect(measured.after.autoVacuum == DatabaseVacuum.incrementalMode, "the switch ran (\(measured.after))")
        #expect(measured.written < measured.before.allBytes,
                "the copy and its WAL, \(measured.written) bytes, are less than the file's own \(measured.before.allBytes): twice the file asks for far more")
        #expect(need >= measured.written, "the need \(need) covers the \(measured.written) bytes written")
    }

    @Test("The bytes to free: none with the need free or more, the shortfall below it, rounded up; the need covers the copy of the data with its pointer-map pages, the WAL frames of that copy, the WAL's header and the WAL index's growth, and asks at most a few percent more")
    func bytesToFreeLine() {
        let pageSize: Int64 = 4_096
        /// SQLite's header on each WAL frame, on the WAL file, and the WAL index's bytes per frame.
        let walFrameHeaderBytes: Int64 = 24
        let walHeaderBytes: Int64 = 32
        let walIndexBytesPerFrame: Int64 = 8
        /// Pages one pointer-map page covers: five bytes an entry (SQLite's file format).
        let pagesPerPointerMapPage = pageSize / 5
        let liveBytes = 251 * pageSize
        let needed = SyncEngine.bytesNeededForUpgrade(liveBytes: liveBytes)
        let exact = Double(liveBytes) * SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple
        #expect(SyncEngine.bytesToFreeForUpgrade(liveBytes: liveBytes, availableBytes: needed) == 0)
        #expect(SyncEngine.bytesToFreeForUpgrade(liveBytes: liveBytes, availableBytes: needed + 1) == 0)
        #expect(SyncEngine.bytesToFreeForUpgrade(liveBytes: liveBytes, availableBytes: needed - 1) == 1)
        #expect(SyncEngine.bytesToFreeForUpgrade(liveBytes: liveBytes, availableBytes: 0) == needed)
        #expect(Double(needed) >= exact && Double(needed - 1) < exact, "rounded up, never down: \(needed) for \(exact)")
        for livePages: Int64 in [251, 100_000] {
            let copyPages = livePages + (livePages + pagesPerPointerMapPage - 1) / pagesPerPointerMapPage
            let written = copyPages * pageSize + walHeaderBytes
                + copyPages * (pageSize + walFrameHeaderBytes + walIndexBytesPerFrame)
            let need = SyncEngine.bytesNeededForUpgrade(liveBytes: livePages * pageSize)
            #expect(need >= written, "\(livePages) pages of data: the need \(need) covers \(written) bytes written")
            #expect(Double(need) <= Double(written) * Self.needOverWrittenAtMost,
                    "\(livePages) pages of data: the need \(need) asks at most a few percent more than \(written) bytes written")
        }
    }

    @Test("Upgrade now asks for power only below the minimum battery level while not charging; an unknown level asks nothing")
    func needsPowerLine() {
        let line = SyncConfig.databaseUpgradeMinimumBatteryLevel
        let below = line - 0.01
        #expect(DatabaseUpgrade.needsPower(level: below, state: .unplugged), "below the line, unplugged")
        #expect(!DatabaseUpgrade.needsPower(level: line, state: .unplugged), "at the line")
        #expect(!DatabaseUpgrade.needsPower(level: below, state: .charging), "charging")
        #expect(!DatabaseUpgrade.needsPower(level: below, state: .full), "full")
        #expect(!DatabaseUpgrade.needsPower(level: -1, state: .unknown), "battery monitoring off or the simulator")
        #expect(!DatabaseUpgrade.needsPower(level: -1, state: .unplugged), "an unknown level")
    }

    @Test("Every VACUUM the app runs leaves the database on INCREMENTAL")
    func everyAppVacuumLeavesItIncremental() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        let before = try Self.spaceState(email.pool)?.autoVacuum
        try await email.pool.writeWithoutTransaction { db in try DatabaseVacuum.vacuum(db) }
        let after = try Self.spaceState(email.pool)?.autoVacuum

        let (index, directory) = try await makeSearchIndex(oldFile: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchBefore = await index.spaceState()?.autoVacuum
        try await index.vacuum()
        let searchAfter = await index.spaceState()?.autoVacuum
        await index.closeForNuke()

        #expect(before == DatabaseVacuum.noneMode, "precondition: the email database starts on NONE")
        #expect(after == DatabaseVacuum.incrementalMode, "the email VACUUM switched it: \(String(describing: after))")
        #expect(searchBefore == DatabaseVacuum.noneMode, "precondition: the search database starts on NONE")
        #expect(searchAfter == DatabaseVacuum.incrementalMode, "the search VACUUM switched it: \(String(describing: searchAfter))")
    }

    // MARK: - The planner statistics marker

    @Test("The email switch carries a fresh statistics marker: the next maintenance pass finds the statistics fresh")
    func theSwitchCarriesAFreshMarker() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let first = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)
        let versionBefore = try Self.schemaVersion(email.pool)
        let markerBefore = UserDefaults.standard.object(forKey: key) as? Int

        try await SyncEngine.switchEmailDatabaseToIncremental(email.background, markerKey: key, inboxObserver: nil, shouldRun: { true })
        let versionAfter = try Self.schemaVersion(email.pool)
        let markerAfter = UserDefaults.standard.object(forKey: key) as? Int
        let next = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)

        #expect(first == .refreshed, "precondition: the first pass analyzes and records the marker")
        #expect(markerBefore == versionBefore, "precondition: the marker is fresh")
        #expect(versionAfter != versionBefore, "the VACUUM moved schema_version, the reason for the carry")
        #expect(markerAfter == versionAfter, "the marker moved with schema_version")
        #expect(next == .alreadyFresh, "the next pass runs no ANALYZE after the switch: \(next)")
    }

    @Test("A statistics marker that was stale before the switch stays stale")
    func aStaleMarkerStaysStale() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // A first pass builds the deferred indexes, so the next pass's ANALYZE can
        // come only from the marker.
        let first = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)
        let versionBeforeRead = try Self.schemaVersion(email.pool)
        let versionBefore = try #require(versionBeforeRead)
        let stale = versionBefore - 1
        UserDefaults.standard.set(stale, forKey: key)

        try await SyncEngine.switchEmailDatabaseToIncremental(email.background, markerKey: key, inboxObserver: nil, shouldRun: { true })
        let versionAfter = try Self.schemaVersion(email.pool)
        let markerAfter = UserDefaults.standard.object(forKey: key) as? Int
        let next = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)

        #expect(first == .refreshed, "precondition: the first pass analyzes")
        #expect(versionAfter != versionBefore, "precondition: the switch ran")
        #expect(markerAfter == stale, "a stale marker is left as it was")
        #expect(next == .refreshed, "so the next pass still analyzes: \(next)")
    }

    /// A statistics refresh that holds its latch until the upgrade's `endsAt`th check,
    /// and records the email database's mode just before it ends.
    private final class RefreshEndsAtCheck: Sendable {
        private let count = Mutex(0)
        private let modeAtEnd = Mutex<Int?>(nil)
        private let endsAt: Int
        private let pool: DatabasePool
        init(endsAt: Int, pool: DatabasePool) {
            self.endsAt = endsAt
            self.pool = pool
        }
        func check() -> Bool {
            let call = count.withLock { $0 += 1; return $0 }
            if call == endsAt {
                let mode = (try? IncrementalVacuumTests.spaceState(pool))?.autoVacuum
                modeAtEnd.withLock { $0 = mode }
                SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 = false }
            }
            return true
        }
        var calls: Int { count.withLock { $0 } }
        var modeBeforeTheEnd: Int? { modeAtEnd.withLock { $0 } }
    }

    @Test("While a statistics refresh holds its latch the email switch does not start; the upgrade waits for the refresh to end, then upgrades")
    func theUpgradeWaitsForTheStatisticsLatch() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 = true }
        defer { SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 = false } }
        // Check 1 before the email database; checks 2 and 3 after the latch was found
        // held twice; the refresh ends at check 3; check 4 on the writer.
        let refresh = RefreshEndsAtCheck(endsAt: 3, pool: email.pool)

        await #expect(throws: SyncEngine.SpaceReturnDeferred.statisticsRefreshRunning) {
            try await SyncEngine.switchEmailDatabaseToIncremental(email.background, markerKey: key, inboxObserver: nil, shouldRun: { true })
        }
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: key, inboxObserver: nil)],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { refresh.check() })
        let after = try Self.spaceState(email.pool)
        let latchHeld = SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 }

        #expect(refresh.modeBeforeTheEnd == DatabaseVacuum.noneMode, "nothing was switched while the refresh held its latch: \(String(describing: refresh.modeBeforeTheEnd))")
        #expect(steps == [.upgraded("email")], "after the refresh ended the upgrade ran: \(steps)")
        #expect(refresh.calls == 4, "it waited twice, then checked again on the writer: \(refresh.calls)")
        #expect(after?.autoVacuum == DatabaseVacuum.incrementalMode, "now INCREMENTAL (\(String(describing: after)))")
        #expect(!latchHeld, "the switch released the latch it took")
    }

    @Test("A suspension while the upgrade waits for the statistics latch ends the upgrade; the latch stays with its holder")
    func aSuspensionWhileWaitingForTheLatchStops() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let before = try Self.spaceState(email.pool)
        SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 = true }
        defer { SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 = false } }
        // Yes before the email database, no after the latch was found held.
        let checks = Checks(yes: 1)

        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: key, inboxObserver: nil)],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { checks.next() })
        let after = try Self.spaceState(email.pool)
        let latchHeld = SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 }

        #expect(steps == [.stopped("email")], "the upgrade stopped: \(steps)")
        #expect(checks.calls == 2, "no wait after the stop: \(checks.calls)")
        #expect(after == before, "nothing was switched")
        #expect(latchHeld, "the latch stays with the refresh that holds it")
    }

    // MARK: - The inbox banner observer

    /// Records the banners the inbox observer clears, as "account:messageId".
    private final class ClearRecorder: Sendable {
        private let cleared = Mutex<[String]>([])
        func record(_ accountId: String, _ messageId: String) {
            cleared.withLock { $0.append("\(accountId):\(messageId)") }
        }
        var all: [String] { cleared.withLock { $0 } }
    }

    private func insertInboxHeader(_ pool: DatabasePool, messageId: String) throws {
        try pool.write { db in
            try Self.header(messageId: messageId, date: Date(), snippet: "snippet").insert(db)
        }
    }

    private func moveOutOfTheInbox(_ pool: DatabasePool, messageId: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE messageId = ?", arguments: [messageId])
        }
    }

    @Test("After the email switch the inbox banner observer clears a banner only for a message that left the inbox, as an observer that starts at a fresh launch does")
    func theSwitchEmptiesTheInboxObserversMap() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let cleared = ClearRecorder()
        let observer = InboxNotificationObserver(clear: { cleared.record($0, $1) })
        email.pool.add(transactionObserver: observer)
        try insertInboxHeader(email.pool, messageId: "9001")
        try insertInboxHeader(email.pool, messageId: "9003")

        try await SyncEngine.switchEmailDatabaseToIncremental(email.background, markerKey: key, inboxObserver: observer, shouldRun: { true })
        let freshCleared = ClearRecorder()
        let fresh = InboxNotificationObserver(clear: { freshCleared.record($0, $1) })
        email.pool.add(transactionObserver: fresh)
        try insertInboxHeader(email.pool, messageId: "9002")
        try insertInboxHeader(email.pool, messageId: "9004")
        try moveOutOfTheInbox(email.pool, messageId: "9001")
        try moveOutOfTheInbox(email.pool, messageId: "9002")
        withExtendedLifetime((observer, fresh)) {}

        let leftTheInbox: Set<String> = ["acc1:9001", "acc1:9002"]
        #expect(Set(cleared.all).isSubset(of: leftTheInbox), "every clear names a message that left the inbox: \(cleared.all)")
        #expect(cleared.all.contains("acc1:9002"), "a message written after the switch is learned and its banner cleared: \(cleared.all)")
        #expect(cleared.all == freshCleared.all, "the same clears as an observer that starts at a fresh launch: \(cleared.all) vs \(freshCleared.all)")
    }

    // MARK: - The upgrade starts no VACUUM on suspended databases

    @Test("An upgrade whose write waited until the databases were suspended does not start: no VACUUM, both databases still NONE, the upgrade stopped, the latch free")
    func theUpgradeAsksTheCheckAgainOnTheWriter() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let (index, searchDirectory) = try await makeSearchIndex(oldFile: true)
        defer { try? FileManager.default.removeItem(at: searchDirectory) }
        let searchTargetRead = await SyncEngine.SpaceReturnTarget.search(index)
        let searchTarget = try #require(searchTargetRead)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let emailBefore = try Self.spaceState(email.pool)
        let searchBefore = await index.spaceState()
        let logStart = email.log.all.count
        // Yes at the upgrade's own check, no once the switch's write has the writer:
        // the databases were suspended while the write waited its turn.
        let emailChecks = Checks(yes: 1)
        let searchChecks = Checks(yes: 1)

        let emailSteps = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: key, inboxObserver: nil)],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { emailChecks.next() })
        let searchSteps = await SyncEngine.runDatabaseUpgrade(
            targets: [searchTarget],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { searchChecks.next() })
        let emailAfter = try Self.spaceState(email.pool)
        let searchAfter = await index.spaceState()
        let vacuumRan = email.log.all[logStart...].contains("VACUUM")
        let latchHeld = SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 }
        await index.closeForNuke()

        #expect(emailBefore?.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's email database (\(String(describing: emailBefore)))")
        #expect(searchBefore?.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's search database (\(String(describing: searchBefore)))")
        #expect(emailSteps == [.stopped("email")], "the email switch did not start: \(emailSteps)")
        #expect(searchSteps == [.stopped("search")], "the search switch did not start: \(searchSteps)")
        #expect(!vacuumRan, "no VACUUM ran on the email database")
        #expect(emailAfter == emailBefore, "the email database is unchanged")
        #expect(searchAfter == searchBefore, "the search database is unchanged")
        #expect(emailChecks.calls == 2, "the email check was asked again on the writer: \(emailChecks.calls)")
        #expect(searchChecks.calls == 2, "the search check was asked again on the writer: \(searchChecks.calls)")
        #expect(!latchHeld, "the statistics latch is free again")
    }

    // MARK: - A suspension during the upgrade

    /// The suspension as the app sends it when its background time runs out:
    /// `Database.suspendNotification`, which GRDB turns into an interrupt of the running
    /// `VACUUM`, posted as the `VACUUM` starts building its copy. The upgrade's default
    /// check reads the suspension (`DatabaseSuspension.isSuspended`). Not covered,
    /// because no test can reach it: a suspension once the `VACUUM` writes its copy
    /// back, which no interrupt stops (ADR-IOS-121).
    @Test("When the databases are suspended during the email upgrade, it rolls back and stops: still NONE, rows, rowids, empty pages, schema_version and the marker as before, temp_store restored, the latch free, the observer's map kept; a later upgrade upgrades")
    func aSuspensionRollsTheUpgradeBack() async throws {
        let email = try makeEmailFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        try seedMailThenDeleteMost(email.pool)
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        DatabaseSuspension.installSuspensionStateObserver()
        try #require(!DatabaseSuspension.isSuspended, "precondition: the databases are not suspended")
        let first = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)
        let cleared = ClearRecorder()
        let observer = InboxNotificationObserver(clear: { cleared.record($0, $1) })
        email.pool.add(transactionObserver: observer)
        try insertInboxHeader(email.pool, messageId: "9001")
        let before = try Self.spaceState(email.pool)
        let rowidsBefore = try Self.headerRowids(email.pool)
        let versionBefore = try Self.schemaVersion(email.pool)
        let markerBefore = UserDefaults.standard.object(forKey: key) as? Int
        // The app's background time runs out: it suspends the databases.
        email.log.onNextVacuum { NotificationCenter.default.post(name: Database.suspendNotification, object: nil) }
        defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }

        let ended = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: key, inboxObserver: observer)],
            availableBytes: { _ in Self.plentyOfSpace })
        // The app's return resumes them.
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        let afterEnd = try Self.spaceState(email.pool)
        let rowidsAfterEnd = try Self.headerRowids(email.pool)
        let versionAfterEnd = try Self.schemaVersion(email.pool)
        let markerAfterEnd = UserDefaults.standard.object(forKey: key) as? Int
        let tempStore = try Self.writerTempStore(email.pool)
        let latchHeld = SyncEngine.plannerStatisticsRefreshInFlight.withLock { $0 }
        try moveOutOfTheInbox(email.pool, messageId: "9001")
        let clearedAfterEnd = cleared.all
        let later = await SyncEngine.runDatabaseUpgrade(
            targets: [.email(email.background, markerKey: key, inboxObserver: observer)],
            availableBytes: { _ in Self.plentyOfSpace })
        let afterLater = try Self.spaceState(email.pool)
        let rowidsAfterLater = try Self.headerRowids(email.pool)
        withExtendedLifetime(observer) {}

        #expect(first == .refreshed, "precondition: the marker is recorded")
        #expect(markerBefore == versionBefore, "precondition: the marker is fresh")
        #expect(before?.autoVacuum == DatabaseVacuum.noneMode, "precondition: an older install's database (\(String(describing: before)))")
        #expect((before?.freePages ?? 0) > 0, "precondition: the delete left empty pages")
        #expect(ended == [.stopped("email")], "the suspended upgrade reports stopped, to start again on the app's return: \(ended)")
        #expect(afterEnd == before, "mode and pages as before: \(String(describing: before)) -> \(String(describing: afterEnd))")
        #expect(rowidsAfterEnd == rowidsBefore, "every row and rowid as before")
        #expect(versionAfterEnd == versionBefore, "schema_version as before")
        #expect(markerAfterEnd == markerBefore, "the marker as before")
        #expect(tempStore == Self.tempStoreMemory, "the writer connection's temp_store is restored (\(String(describing: tempStore)))")
        #expect(!latchHeld, "the statistics latch is free again")
        #expect(clearedAfterEnd == ["acc1:9001"], "the observer still knows the row it learned before: \(clearedAfterEnd)")
        #expect(later == [.upgraded("email")], "a later upgrade upgrades: \(later)")
        #expect(afterLater?.autoVacuum == DatabaseVacuum.incrementalMode, "now INCREMENTAL (\(String(describing: afterLater)))")
        #expect(rowidsAfterLater == rowidsAfterEnd, "the later upgrade keeps every rowid")
    }

    // MARK: - The nightly steps

    /// Records each step's pages freed, the TRUNCATE checkpoints, and a fake
    /// database's switches.
    private final class StepLog: Sendable {
        private let freed = Mutex<[Int]>([])
        private let truncates = Mutex(0)
        private let switches = Mutex(0)
        func step(_ pages: Int) { freed.withLock { $0.append(pages) } }
        func truncate() { truncates.withLock { $0 += 1 } }
        func switched() { switches.withLock { $0 += 1 } }
        var steps: [Int] { freed.withLock { $0 } }
        var truncateCount: Int { truncates.withLock { $0 } }
        var switchCount: Int { switches.withLock { $0 } }
    }

    /// Counts the calls of a closure.
    private final class CallCount: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// `target`, with each step and TRUNCATE recorded in `log`.
    private static func recording(_ target: SyncEngine.SpaceReturnTarget, _ log: StepLog) -> SyncEngine.SpaceReturnTarget {
        SyncEngine.SpaceReturnTarget(
            name: target.name, path: target.path, state: target.state,
            switchToIncremental: target.switchToIncremental,
            giveBack: { pages in
                let before = await target.state()?.freePages ?? 0
                let left = try await target.giveBack(pages)
                log.step(Int(before) - left)
                return left
            },
            truncateWAL: {
                log.truncate()
                await target.truncateWAL()
            })
    }

    @Test("On INCREMENTAL a run gives every empty page back in bounded steps, each followed by the throttled checkpoint, keeps every rowid and schema_version, leaves a fresh marker fresh, then truncates the WAL")
    func stepsGiveEveryEmptyPageBack() async throws {
        let email = try await makeIncrementalEmailWithEmptyPages()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let first = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)
        let beforeRead = try Self.spaceState(email.pool)
        let before = try #require(beforeRead)
        let rowidsBefore = try Self.headerRowids(email.pool)
        let versionBefore = try Self.schemaVersion(email.pool)
        let fileBefore = StorageEstimator.databaseFileBytes(ofDatabaseAt: email.path)
        let log = StepLog()
        // The app's checkpoint, counted.
        let checkpoints = CallCount()
        let target = SyncEngine.SpaceReturnTarget.email(
            email.background, markerKey: key, inboxObserver: nil,
            checkpoint: { pool in
                checkpoints.add()
                await SyncEngine.checkpointWALThrottled(pool: pool)
            })

        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [Self.recording(target, log)],
            stepPages: Self.smallStep, shouldRun: { true })
        let afterRead = try Self.spaceState(email.pool)
        let after = try #require(afterRead)
        let rowidsAfter = try Self.headerRowids(email.pool)
        let versionAfter = try Self.schemaVersion(email.pool)
        let fileAfter = StorageEstimator.databaseFileBytes(ofDatabaseAt: email.path)
        let wal = Self.walBytes(email.path)
        let next = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: email.background, markerKey: key)
        let eachStepBounded = log.steps.allSatisfy { $0 > 0 && $0 <= Self.smallStep }

        #expect(first == .refreshed, "precondition: the statistics are fresh before the steps")
        #expect(before.autoVacuum == DatabaseVacuum.incrementalMode, "precondition: INCREMENTAL (\(before))")
        #expect(before.freePages > Int64(Self.smallStep * 2), "precondition: empty pages for several steps (\(before))")
        #expect(steps == [.gaveBack("email")], "gave back: \(steps)")
        #expect(log.steps.count >= 2, "in several steps: \(log.steps)")
        #expect(eachStepBounded, "each step frees at most its pages: \(log.steps)")
        #expect(checkpoints.value == log.steps.count, "one throttled checkpoint after each step: \(checkpoints.value) for \(log.steps.count) steps")
        #expect(log.steps.reduce(0, +) == Int(before.freePages), "the steps freed every empty page: \(log.steps)")
        #expect(after.freePages == 0, "no empty page left (\(after))")
        // At least its empty pages: the pointer-map pages an INCREMENTAL file keeps go
        // with the end of the file too.
        #expect(before.pageCount - after.pageCount >= before.freePages, "the file lost at least its empty pages: \(before) -> \(after)")
        #expect(fileAfter < fileBefore, "the files shrank on disk: \(fileBefore) -> \(fileAfter)")
        #expect(rowidsAfter == rowidsBefore, "every header keeps its rowid")
        #expect(versionAfter == versionBefore, "the steps leave schema_version as it was")
        #expect(next == .alreadyFresh, "so the statistics stay fresh: \(next)")
        #expect(log.truncateCount == 1, "one TRUNCATE at the end: \(log.truncateCount)")
        #expect(wal == 0, "the WAL is empty (\(wal) bytes)")
    }

    @Test("On a new search database a run gives every empty page back in bounded steps, keeps every email's rowid, its metadata join and its search result, then truncates the WAL")
    func searchStepsGiveEveryEmptyPageBack() async throws {
        let (index, directory) = try await makeSearchIndex(oldFile: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathRead = await index.databasePath()
        let path = try #require(pathRead)
        let targetRead = await SyncEngine.SpaceReturnTarget.search(index)
        let target = try #require(targetRead)
        let every = Self.seededMail / Self.keptMail
        let idsBefore = try Self.searchIdRows(path)
        let beforeRead = await index.spaceState()
        let before = try #require(beforeRead)
        let log = StepLog()

        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [Self.recording(target, log)],
            stepPages: Self.smallStep, shouldRun: { true })
        let afterRead = await index.spaceState()
        let after = try #require(afterRead)
        let idsAfter = try Self.searchIdRows(path)
        let keptHits = try await index.keywordSearch(query: "term\(every)end")
        let wal = Self.walBytes(path)
        await index.closeForNuke()
        let keptKeys = keptHits.map { $0.contentKey.rawValue }
        let eachStepBounded = log.steps.allSatisfy { $0 > 0 && $0 <= Self.smallStep }

        #expect(before.autoVacuum == DatabaseVacuum.incrementalMode, "precondition: a new search database is INCREMENTAL (\(before))")
        #expect(before.freePages > Int64(Self.smallStep * 2), "precondition: empty pages for several steps (\(before))")
        #expect(idsBefore.ids.count == Self.keptMail, "precondition: the kept emails (\(idsBefore.ids.count))")
        #expect(steps == [.gaveBack("search")], "gave back: \(steps)")
        #expect(log.steps.count >= 2, "in several steps: \(log.steps)")
        #expect(eachStepBounded, "each step frees at most its pages: \(log.steps)")
        #expect(log.steps.reduce(0, +) == Int(before.freePages), "the steps freed every empty page: \(log.steps)")
        #expect(after.freePages == 0, "no empty page left (\(after))")
        #expect(before.pageCount - after.pageCount >= before.freePages, "the file lost at least its empty pages: \(before) -> \(after)")
        #expect(idsAfter.ids == idsBefore.ids, "every email keeps its rowid")
        #expect(idsAfter.joined == Self.keptMail, "every id still joins its metadata row by rowid (\(idsAfter.joined))")
        #expect(keptKeys == ["acc1:INBOX:\(every)"], "a kept email's own term finds that email: \(keptKeys)")
        #expect(log.truncateCount == 1, "one TRUNCATE at the end: \(log.truncateCount)")
        #expect(wal == 0, "the WAL is empty (\(wal) bytes)")
    }

    /// `shouldRun` answers yes `yes` times, then no.
    private final class Checks: Sendable {
        private let count = Mutex(0)
        private let yes: Int
        init(yes: Int) { self.yes = yes }
        func next() -> Bool { count.withLock { $0 += 1; return $0 <= yes } }
        var calls: Int { count.withLock { $0 } }
    }

    @Test("A stop between two steps ends the run: no further step, no TRUNCATE, and the next database is not touched")
    func aStopBetweenStepsEndsTheRun() async throws {
        let email = try await makeIncrementalEmailWithEmptyPages()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        let beforeRead = try Self.spaceState(email.pool)
        let before = try #require(beforeRead)
        let log = StepLog()
        let otherLog = StepLog()
        let other = Self.fakeTarget("search", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: otherLog)
        // Yes for the email target, its first step and its second step; then no.
        let checks = Checks(yes: 3)

        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [Self.recording(.email(email.background, markerKey: Self.markerKey(), inboxObserver: nil), log), other],
            stepPages: Self.smallStep, shouldRun: { checks.next() })
        let afterRead = try Self.spaceState(email.pool)
        let after = try #require(afterRead)

        #expect(steps == [.stopped("email")], "the stop ends the run: \(steps)")
        #expect(log.steps.count == 2, "two steps ran: \(log.steps)")
        #expect(after.freePages == before.freePages - Int64(log.steps.reduce(0, +)), "the two steps' pages were given back, the rest kept: \(before) -> \(after)")
        #expect(log.truncateCount == 0, "no TRUNCATE after a stop")
        #expect(otherLog.steps.isEmpty && otherLog.truncateCount == 0, "the next database is not touched")
        #expect(checks.calls == 4, "no check after the stop: \(checks.calls)")
    }

    // MARK: - The order and checks (fake databases)

    /// A fake database's mode and empty pages.
    private final class FakeDatabase: Sendable {
        let mode: Mutex<Int>
        let free: Mutex<Int64>
        init(mode: Int, free: Int64) {
            self.mode = Mutex(mode)
            self.free = Mutex(free)
        }
    }

    /// The error a fake database's switch throws when told to.
    private struct FakeSwitchError: Error {}

    /// The lines a closure recorded, in order.
    private final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    /// Every fake database's pages, of 4,096 bytes each, the empty ones included.
    private static let fakePageCount: Int64 = 1_000

    /// A fake database's pages less its `freePages` empty ones, in bytes: what its
    /// upgrade's free-space check measures.
    private static func fakeLiveBytes(freePages: Int64) -> Int64 { (fakePageCount - freePages) * 4_096 }

    /// A database that records its switch, steps and TRUNCATE; each step frees up to
    /// its pages. With `switchThrows` its switch throws and changes nothing; with
    /// `switchFillsTheDisk` it throws SQLite's disk-full error, as a `VACUUM` that ran
    /// out of space and rolled back.
    private static func fakeTarget(
        _ name: String, autoVacuum: Int, freePages: Int64, log: StepLog, stepFrees: Bool = true,
        switchThrows: Bool = false, switchFillsTheDisk: Bool = false
    ) -> SyncEngine.SpaceReturnTarget {
        let database = FakeDatabase(mode: autoVacuum, free: freePages)
        return SyncEngine.SpaceReturnTarget(
            name: name, path: "/\(name)",
            state: {
                DatabaseVacuum.SpaceState(
                    autoVacuum: database.mode.withLock { $0 }, pageCount: Self.fakePageCount,
                    freePages: database.free.withLock { $0 }, pageSize: 4_096)
            },
            switchToIncremental: { _ in
                if switchThrows { throw FakeSwitchError() }
                if switchFillsTheDisk { throw DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full") }
                log.switched()
                database.mode.withLock { $0 = DatabaseVacuum.incrementalMode }
                database.free.withLock { $0 = 0 }
            },
            giveBack: { pages in
                database.free.withLock { left in
                    let freed = stepFrees ? min(Int64(pages), left) : 0
                    left -= freed
                    log.step(Int(freed))
                    return Int(left)
                }
            },
            truncateWAL: { log.truncate() })
    }

    // The background job's steps

    @Test("With the app in the foreground or the databases suspended, the background job starts nothing")
    func nothingStartsWhenTheJobMayNotRun() async {
        let log = StepLog()
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: log),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: log),
            ],
            shouldRun: { false })
        #expect(steps == [.stopped("email")], "the run ends at once: \(steps)")
        #expect(log.steps.isEmpty && log.truncateCount == 0, "nothing ran")
    }

    @Test("A stop after the last step skips the TRUNCATE and ends the run")
    func aStopBeforeTheTruncateSkipsIt() async {
        let log = StepLog()
        let otherLog = StepLog()
        // Yes for the target, its first step and its second step, which frees its last
        // empty pages; then no, before the TRUNCATE.
        let checks = Checks(yes: 3)
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 32, log: log),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: otherLog),
            ],
            stepPages: 16, shouldRun: { checks.next() })
        #expect(steps == [.stopped("email")], "the stop ends the run: \(steps)")
        #expect(log.steps == [16, 16], "both steps ran: \(log.steps)")
        #expect(log.truncateCount == 0, "no TRUNCATE once the check says no")
        #expect(otherLog.steps.isEmpty && otherLog.truncateCount == 0, "the next database is not touched")
        #expect(checks.calls == 4, "the last check was before the TRUNCATE: \(checks.calls)")
    }

    @Test("The app's check runs the background steps only in the background with the databases not suspended")
    func theAppsCheckNeedsTheBackgroundAndNoSuspension() {
        let background = SyncEngine.spaceReturnMayRun(isSuspended: false, isAppActive: false)
        let suspended = SyncEngine.spaceReturnMayRun(isSuspended: true, isAppActive: false)
        let foreground = SyncEngine.spaceReturnMayRun(isSuspended: false, isAppActive: true)
        let both = SyncEngine.spaceReturnMayRun(isSuspended: true, isAppActive: true)
        #expect(background, "in the background, not suspended: it runs")
        #expect(!suspended, "suspended, the job has ended: it does not run")
        #expect(!foreground, "in the foreground: it does not run")
        #expect(!both, "suspended in the foreground: it does not run")
    }

    @Test("The Optimize Storage tap's check runs the steps only in the foreground with the databases not suspended")
    func theTapsCheckNeedsTheForegroundAndNoSuspension() {
        let foreground = SyncEngine.optimizeStorageMayRun(isSuspended: false, isAppActive: true)
        let suspended = SyncEngine.optimizeStorageMayRun(isSuspended: true, isAppActive: true)
        let background = SyncEngine.optimizeStorageMayRun(isSuspended: false, isAppActive: false)
        let both = SyncEngine.optimizeStorageMayRun(isSuspended: true, isAppActive: false)
        #expect(foreground, "in the foreground, not suspended: it runs")
        #expect(!suspended, "suspended: it does not run")
        #expect(!background, "the app left the foreground: it does not run, the rest waits for the background job")
        #expect(!both, "suspended in the background: it does not run")
    }

    /// One Optimize Storage tap with `readMeasure`'s measure and `giveBack`'s steps, the
    /// tap's check in the foreground with the databases not suspended, and a threshold
    /// of one byte (a test database's empty pages are far under the app's): the row
    /// before the tap, and the row and the space used after it.
    @MainActor
    private static func tapOnce(
        readMeasure: @escaping @Sendable () async -> StorageOptimizer.Measure,
        giveBack: @escaping @Sendable (@escaping @Sendable () -> Bool) async -> [SyncEngine.SpaceReturnStep]
    ) async -> (before: StorageOptimizer.Row?, after: StorageOptimizer.Row?, usedAfter: Int64?) {
        let optimizer = StorageOptimizer(
            readMeasure: readMeasure, readNeedsUpgrade: { false }, openUpgradeNotice: {},
            giveBack: giveBack,
            mayRun: { SyncEngine.optimizeStorageMayRun(isSuspended: false, isAppActive: true) },
            minimumGainBytes: 1)
        await optimizer.refresh()
        let before = optimizer.row
        await optimizer.tap()
        return (before, optimizer.row, optimizer.measure?.usedBytes)
    }

    @Test("An Optimize Storage tap on a real upgraded email database brings the database and its WAL down to the size its row promised, and the row goes")
    func theTapReachesTheSizeItsRowPromised() async throws {
        let email = try await makeIncrementalEmailWithEmptyPages()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: email.pool, directory: email.directory) }
        let key = Self.markerKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let pool = email.pool
        let path = email.path
        let target = SyncEngine.SpaceReturnTarget.email(email.background, markerKey: key, inboxObserver: nil)
        let stepPages = Self.smallStep
        let beforeRead = try Self.spaceState(email.pool)
        let before = try #require(beforeRead)

        let outcome = await Self.tapOnce(
            readMeasure: {
                // The row's measure, on this database alone: the files on disk and the empty pages.
                let pages = try? await pool.read { db in try StorageEstimator.PageTotals.read(db) }
                return StorageOptimizer.Measure(
                    usedBytes: StorageEstimator.databaseFileBytes(ofDatabaseAt: path), emptyBytes: pages?.emptyBytes)
            },
            giveBack: { shouldRun in
                await SyncEngine.runOvernightSpaceReturn(targets: [target], stepPages: stepPages, shouldRun: shouldRun)
            })
        let promised: Int64? = {
            guard case .ready(let bytes, false)? = outcome.before else { return nil }
            return bytes
        }()
        let usedAfter = outcome.usedAfter ?? .max
        let wal = Self.walBytes(path)

        #expect(before.freePages > Int64(stepPages * 2), "precondition: empty pages for several steps (\(before))")
        #expect(promised != nil, "precondition: the row offers the tap (\(String(describing: outcome.before)))")
        #expect(usedAfter <= (promised ?? 0), "the database and its WAL take no more than the row promised: \(usedAfter) for \(String(describing: promised))")
        #expect(outcome.after == nil, "no empty page left, so no row: \(String(describing: outcome.after))")
        #expect(wal == 0, "the WAL is empty (\(wal) bytes)")
    }

    @Test("The background job's default check starts no step while the app is in the foreground")
    func theDefaultCheckStartsNothingInTheForeground() async throws {
        let active = DatabaseSuspension.isAppActive
        try #require(active, "precondition: the test host runs in the foreground")
        let log = StepLog()
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: log)])
        #expect(steps == [.stopped("email")], "nothing starts in the foreground: \(steps)")
        #expect(log.steps.isEmpty && log.truncateCount == 0)
    }

    @Test("The background job gives a database still on NONE no step and no switch, and the next database still steps")
    func theJobLeavesADatabaseNotUpgradedAlone() async {
        let emailLog = StepLog()
        let searchLog = StepLog()
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 40, log: searchLog),
            ],
            stepPages: 16, shouldRun: { true })
        #expect(steps == [.notUpgraded("email"), .gaveBack("search")], "email left for the upgrade, search stepped: \(steps)")
        #expect(emailLog.switchCount == 0, "the background job never switches a database")
        #expect(emailLog.steps.isEmpty && emailLog.truncateCount == 0, "the database not upgraded is not touched")
        #expect(searchLog.steps == [16, 16, 8], "the search database gave its pages back in steps: \(searchLog.steps)")
        #expect(searchLog.truncateCount == 1)
    }

    @Test("An INCREMENTAL database with no empty page is left alone, and the next one still steps")
    func aCompactDatabaseIsLeftAlone() async {
        let emailLog = StepLog()
        let searchLog = StepLog()
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 0, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: searchLog),
            ],
            stepPages: 16, shouldRun: { true })
        #expect(steps == [.alreadyCompact("email"), .gaveBack("search")], "\(steps)")
        #expect(emailLog.steps.isEmpty && emailLog.truncateCount == 0, "a compact database is not touched")
        #expect(searchLog.steps == [10], "\(searchLog.steps)")
    }

    @Test("A step that frees nothing ends that database's steps")
    func aStepThatFreesNothingEnds() async {
        let log = StepLog()
        let steps = await SyncEngine.runOvernightSpaceReturn(
            targets: [Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 40, log: log, stepFrees: false)],
            stepPages: 16, shouldRun: { true })
        #expect(steps == [.gaveBack("email")], "\(steps)")
        #expect(log.steps == [0], "one step, then no more: \(log.steps)")
        #expect(log.truncateCount == 1)
    }

    // The upgrade

    @Test("The upgrade's check needs only the databases not suspended: it runs in the foreground")
    func theUpgradesCheckNeedsOnlyNoSuspension() {
        #expect(SyncEngine.upgradeMayRun(isSuspended: false), "not suspended: it runs")
        #expect(!SyncEngine.upgradeMayRun(isSuspended: true), "suspended: it does not run")
    }

    @Test("With the upgrade's default check, an upgrade the user starts runs in the foreground")
    func theUpgradesDefaultCheckRunsInTheForeground() async throws {
        DatabaseSuspension.installSuspensionStateObserver()
        let active = DatabaseSuspension.isAppActive
        let suspended = DatabaseSuspension.isSuspended
        try #require(active && !suspended, "precondition: the test host runs in the foreground, not suspended")
        let log = StepLog()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: log)],
            availableBytes: { _ in Self.plentyOfSpace })
        #expect(steps == [.upgraded("email")], "\(steps)")
        #expect(log.switchCount == 1 && log.truncateCount == 1)
    }

    @Test("The upgrade starts nothing while the databases are suspended")
    func theUpgradeStartsNothingWhenSuspended() async {
        let log = StepLog()
        let asked = Lines()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: log),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: log),
            ],
            availableBytes: { asked.add($0); return Self.plentyOfSpace }, shouldRun: { false })
        #expect(steps == [.stopped("email")], "the upgrade ends at once: \(steps)")
        #expect(log.switchCount == 0 && log.truncateCount == 0, "nothing ran")
        #expect(asked.all.isEmpty, "no free space read: \(asked.all)")
    }

    @Test("The upgrade goes email database first; each database's free space is read after the one before it was rewritten; each switch truncates its WAL and takes no step")
    func theUpgradeGoesEmailFirst() async {
        let emailLog = StepLog()
        let searchLog = StepLog()
        let asked = Lines()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: searchLog),
            ],
            availableBytes: { path in
                asked.add("\(path) after \(emailLog.switchCount) email switch")
                return Self.plentyOfSpace
            },
            shouldRun: { true })
        #expect(steps == [.upgraded("email"), .upgraded("search")], "\(steps)")
        #expect(asked.all == ["/email after 0 email switch", "/search after 1 email switch"], "\(asked.all)")
        #expect(emailLog.switchCount == 1 && searchLog.switchCount == 1)
        #expect(emailLog.truncateCount == 1 && searchLog.truncateCount == 1, "each switch's WAL is truncated")
        #expect(emailLog.steps.isEmpty && searchLog.steps.isEmpty, "the upgrade takes no step")
    }

    /// The upgrade screen's bar (#1583) learns of each database's end from the loop
    /// itself, not from a read of the databases.
    @Test("Each database's step is told as soon as it ends, before the next database starts, the step that ends the upgrade included")
    func eachStepIsToldAsItEnds() async {
        let emailLog = StepLog()
        let searchLog = StepLog()
        let told = Lines()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: searchLog),
            ],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true },
            finished: { step in told.add("\(step): email \(emailLog.switchCount), search \(searchLog.switchCount)") })
        let shortLog = StepLog()
        let toldShort = Lines()
        let short = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: StepLog()),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: shortLog),
            ],
            availableBytes: { _ in 0 }, shouldRun: { true },
            finished: { step in toldShort.add("\(step)") })
        let shortSteps = short.map { "\($0)" }

        #expect(steps == [.upgraded("email"), .upgraded("search")], "\(steps)")
        #expect(told.all == [
            "\(SyncEngine.UpgradeStep.upgraded("email")): email 1, search 0",
            "\(SyncEngine.UpgradeStep.upgraded("search")): email 1, search 1",
        ], "each step told once, after its own switch and before the next: \(told.all)")
        #expect(toldShort.all == shortSteps, "every step told, in order, the one that ends the upgrade included: \(toldShort.all)")
        #expect(short.count == 2, "precondition: one step for each database: \(short)")
    }

    @Test("A database already upgraded is left alone, its free space not read, and the next one is upgraded")
    func anUpgradedDatabaseIsLeftAlone() async {
        let emailLog = StepLog()
        let searchLog = StepLog()
        let asked = Lines()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.incrementalMode, freePages: 10, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: searchLog),
            ],
            availableBytes: { asked.add($0); return Self.plentyOfSpace }, shouldRun: { true })
        #expect(steps == [.alreadyUpgraded("email"), .upgraded("search")], "\(steps)")
        #expect(emailLog.switchCount == 0 && emailLog.truncateCount == 0 && emailLog.steps.isEmpty, "the upgraded database is not touched")
        #expect(searchLog.switchCount == 1)
        #expect(asked.all == ["/search"], "\(asked.all)")
    }

    @Test("The first database short of space ends the upgrade with the bytes to free; the later one is not touched")
    func theFirstDatabaseShortOfSpaceEndsTheUpgrade() async {
        let needed = SyncEngine.bytesToFreeForUpgrade(liveBytes: Self.fakeLiveBytes(freePages: 10), availableBytes: 0)
        let emailLog = StepLog()
        let searchLog = StepLog()
        let emailShort = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: emailLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: searchLog),
            ],
            availableBytes: { _ in needed - 100 }, shouldRun: { true })
        let laterLog = StepLog()
        let shortLog = StepLog()
        let searchShort = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: laterLog),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: shortLog),
            ],
            availableBytes: { $0 == "/search" ? 0 : Self.plentyOfSpace }, shouldRun: { true })

        #expect(emailShort == [.needsSpace("email", bytesToFree: 100)], "\(emailShort)")
        #expect(emailLog.switchCount == 0 && emailLog.truncateCount == 0, "the short database is not touched")
        #expect(searchLog.switchCount == 0 && searchLog.truncateCount == 0, "the later database is not touched")
        #expect(searchShort == [.upgraded("email"), .needsSpace("search", bytesToFree: needed)], "\(searchShort)")
        #expect(laterLog.switchCount == 1, "the email database was upgraded before")
        #expect(shortLog.switchCount == 0 && shortLog.truncateCount == 0, "the short database is not touched")
    }

    @Test("A switch that runs out of disk space although the check found room ends the upgrade as out of space, not failed: its WAL is truncated (giving the rolled-back copy's space back), the later database not touched")
    func aFullDiskEndsTheUpgradeAsOutOfSpace() async {
        let fullLog = StepLog()
        let laterLog = StepLog()
        let steps = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: fullLog, switchFillsTheDisk: true),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: laterLog),
            ],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true })

        #expect(steps == [.ranOutOfSpace("email")], "\(steps)")
        #expect(fullLog.truncateCount == 1, "one TRUNCATE gives the WAL's space back after the rolled-back switch")
        #expect(laterLog.switchCount == 0 && laterLog.truncateCount == 0, "the later database is not touched")
    }

    @Test("A switch that fails, or free space that cannot be read, ends the upgrade as failed; the later database is not touched")
    func aFailureEndsTheUpgrade() async {
        let failingLog = StepLog()
        let laterLog = StepLog()
        let failed = await SyncEngine.runDatabaseUpgrade(
            targets: [
                Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: failingLog, switchThrows: true),
                Self.fakeTarget("search", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: laterLog),
            ],
            availableBytes: { _ in Self.plentyOfSpace }, shouldRun: { true })
        let unreadableLog = StepLog()
        let unreadable = await SyncEngine.runDatabaseUpgrade(
            targets: [Self.fakeTarget("email", autoVacuum: DatabaseVacuum.noneMode, freePages: 10, log: unreadableLog)],
            availableBytes: { _ in nil }, shouldRun: { true })

        #expect(failed == [.failed("email")], "\(failed)")
        #expect(failingLog.truncateCount == 0, "no TRUNCATE after a failed switch")
        #expect(laterLog.switchCount == 0 && laterLog.truncateCount == 0, "the later database is not touched")
        #expect(unreadable == [.failed("email")], "\(unreadable)")
        #expect(unreadableLog.switchCount == 0, "no switch without a free space reading")
    }

    /// `PRAGMA incremental_vacuum(N)` with N of 0 or less frees every empty page in
    /// one write, which the steps exist to avoid, and that write does not stop when
    /// the app comes forward.
    @Test("The background step size is at least one page")
    func theStepSizeIsAtLeastOnePage() {
        #expect(SyncConfig.incrementalVacuumStepPages >= 1, "\(SyncConfig.incrementalVacuumStepPages)")
    }

    // MARK: - Source fences

    @Test("Every VACUUM, auto_vacuum setting and incremental_vacuum step in the app is in DatabaseVacuum")
    func everyVacuumStatementIsInDatabaseVacuum() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let sites = lines
            .filter {
                $0.code.contains("execute(sql: \"VACUUM") || $0.code.contains("auto_vacuum =")
                    || $0.code.contains("incremental_vacuum(")
            }
            .map { "\($0.file): \($0.code)" }
            .sorted()
        let expected = [
            "DatabaseVacuum.swift: try db.execute(sql: \"PRAGMA auto_vacuum = INCREMENTAL\")",
            "DatabaseVacuum.swift: try db.execute(sql: \"PRAGMA auto_vacuum = INCREMENTAL\")",
            "DatabaseVacuum.swift: try db.execute(sql: \"PRAGMA incremental_vacuum(\\(pages))\")",
            "DatabaseVacuum.swift: try db.execute(sql: \"VACUUM\")",
        ].sorted()
        #expect(sites == expected, "\(sites)")
    }

    /// The steps test passes its own counting checkpoint, so only the source shows
    /// that the app's email target bounds its WAL with the app's checkpoint.
    @Test("In production each email step is followed by the app's throttled checkpoint: the default checkpoint argument, called after each step, and no production target passes its own")
    func theEmailStepsUseTheAppsCheckpoint() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let vacuum = lines.filter { $0.file == "SyncEngineIncrementalVacuum.swift" }.map { $0.code }
        let defaultCheckpoint = vacuum.filter { $0.hasPrefix("checkpoint: @escaping") }
        let step = vacuum.firstIndex(of: "try DatabaseVacuum.giveBackEmptyPages(db, upTo: pages)")
        let called = vacuum.firstIndex(of: "await checkpoint(pool)")
        let afterTheStep: Bool = {
            guard let step, let called else { return false }
            return step < called
        }()
        let emailTargets = lines
            .filter { $0.code.contains("SpaceReturnTarget.email(") && !$0.code.contains("func ") }
            .map { "\($0.file): \($0.code)" }

        #expect(defaultCheckpoint == ["checkpoint: @escaping @Sendable (PrioritizedDatabase) async -> Void = { await SyncEngine.checkpointWALThrottled(pool: $0) }"], "the default is the app's throttled PASSIVE checkpoint on the target's pool: \(defaultCheckpoint)")
        #expect(afterTheStep, "the checkpoint is called after the step (step \(String(describing: step)), checkpoint \(String(describing: called)))")
        #expect(emailTargets == ["SyncEngineIncrementalVacuum.swift: var targets = [SpaceReturnTarget.email(emailPool, inboxObserver: inboxObserver)]"], "the app's only email target takes the default: \(emailTargets)")
    }

    /// Every production call of the background steps, the upgrade and their targets:
    /// the background job's two lines, `DatabaseUpgrade`'s run and state read, and the
    /// Optimize Storage tap's two lines.
    private static func spaceReturnCalls(_ lines: [(file: String, code: String)]) -> [String] {
        lines
            .filter {
                ($0.code.contains("runOvernightSpaceReturn(") || $0.code.contains("runDatabaseUpgrade(")
                    || $0.code.contains("appSpaceReturnTargets("))
                    && !$0.code.contains("func ")
            }
            .map { "\($0.file): \($0.code)" }
            .sorted()
    }

    private static let expectedSpaceReturnCalls = [
        "DatabaseUpgrade.swift: let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.dbPool)",
        "DatabaseUpgrade.swift: let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.dbPool)",
        "DatabaseUpgrade.swift: return await SyncEngine.runDatabaseUpgrade(targets: targets, finished: finished)",
        "StorageOptimizer.swift: let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.backgroundPool)",
        "StorageOptimizer.swift: return await SyncEngine.runOvernightSpaceReturn(targets: targets, shouldRun: shouldRun)",
        "SyncScheduler.swift: await SyncEngine.runOvernightSpaceReturn(targets: targets)",
        "SyncScheduler.swift: let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.backgroundPool)",
    ].sorted()

    /// The tests above pass their own targets and checks, and `DatabaseUpgradeTests`
    /// its own scheduler and rewrite, so only the source shows what production runs.
    @Test("Production runs the upgrade only from DatabaseUpgrade's run, with the app's targets and the default checks: polling stops, the one exit that turns it back on while the app is active is set at once, the queues are emptied, then the rewrite; no sync turn is held")
    func theUpgradeRunsOnlyInUpgradeMode() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let calls = Self.spaceReturnCalls(lines)
        let upgrade = lines.filter { $0.file == "DatabaseUpgrade.swift" }.map { $0.code }
        let run = upgrade.firstIndex(of: "private func run() async {")
        let stop = upgrade.firstIndex(of: "scheduler.stopPolling()")
        let resume = upgrade.firstIndex(of: "defer { if DatabaseSuspension.isAppActive { scheduler.startForegroundPolling() } }")
        let queues = upgrade.firstIndex(of: "await SyncScheduler.cancelAllInFlightQueues(inboxOnly: false)")
        let rewrite = upgrade.firstIndex(of: "let steps = await upgradeDatabases { step in await self.databaseFinished(step) }")
        // The progress bar's data (#1583): read once paused, just before the rewrite.
        let sizes: Int? = {
            guard let run else { return nil }
            return upgrade[run...].firstIndex(of: "let states = await readStates()")
        }()
        let inOrder: Bool = {
            guard let run, let stop, let resume, let queues, let sizes, let rewrite else { return false }
            return run < stop && stop + 1 == resume && resume < queues && queues < sizes && sizes < rewrite
        }()
        let otherFunction: [String] = {
            guard let run, let rewrite, run < rewrite else { return ["(not found)"] }
            return upgrade[(run + 1)..<rewrite].filter { $0.contains("func ") }
        }()
        let appDefaults = [
            "static let shared = DatabaseUpgrade()",
            "scheduler: SyncScheduler = .shared,",
            "upgradeDatabases: @escaping @Sendable (StepFinished) async -> [SyncEngine.UpgradeStep] = DatabaseUpgrade.upgradeTheAppsDatabases,",
            "readStates: @escaping @Sendable () async -> [DatabaseState] = DatabaseUpgrade.readTheAppsStates,",
            "readBattery: @escaping @MainActor () -> (level: Float, state: UIDevice.BatteryState) = DatabaseUpgrade.theDevicesBattery",
        ].filter { !upgrade.contains($0) }
        let pollingCalls = upgrade.filter { $0.contains("stopPolling(") || $0.contains("startForegroundPolling(") }
        let turns = upgrade.filter { $0.contains("withSyncTurns") || $0.contains("oneSyncAtATime") }
        let persisted = upgrade.filter { $0.contains("UserDefaults.standard.set(") }

        #expect(calls == Self.expectedSpaceReturnCalls, "the production callers, with the app's targets and the default checks: \(calls)")
        #expect(inOrder, "stop polling, set the exit that starts it, empty the queues, read the data for the progress, upgrade (run \(String(describing: run)), stop \(String(describing: stop)), exit \(String(describing: resume)), queues \(String(describing: queues)), data \(String(describing: sizes)), upgrade \(String(describing: rewrite)))")
        #expect(otherFunction.isEmpty, "inside run's own function: \(otherFunction)")
        #expect(appDefaults.isEmpty, "the shared upgrade uses the app's scheduler, rewrite and states: missing \(appDefaults)")
        #expect(pollingCalls == ["scheduler.stopPolling()", "defer { if DatabaseSuspension.isAppActive { scheduler.startForegroundPolling() } }"], "one stop, and one exit that turns polling back on while the app is active: \(pollingCalls)")
        #expect(turns.isEmpty, "no sync turn is held: \(turns)")
        #expect(persisted == ["UserDefaults.standard.set(true, forKey: Self.noticeOfferedKey)"], "the pause is not persisted; only the notice's shown-once flag is: \(persisted)")
    }

    /// The search database's state read opens the search index (`SearchIndex.databasePath`
    /// calls `ensureReady`), which the app opens only after the first paint
    /// (`TabMailApp.deferredSearchIndexInitIfNeeded`). `DatabaseUpgradeTests` passes its
    /// own states, and the launch gate and the presentation read the app's state, so
    /// only the source shows when the inbox's check reads and presents.
    @Test("The inbox's upgrade check reads the databases only after the launch gate and the quiet delay, then checks and presents the notice with no wait between; RootView starts no other read when the inbox appears")
    func theUpgradeCheckReadsAfterTheLaunch() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let upgrade = lines.filter { $0.file == "DatabaseUpgrade.swift" }.map { $0.code }
        let body: [String] = {
            guard let start = upgrade.firstIndex(of: "func checkAfterLaunch() async {"),
                  let end = upgrade[start...].firstIndex(of: "}") else { return [] }
            return Array(upgrade[(start + 1)..<end])
        }()
        let gate = body.firstIndex(of: "guard await AppStartup.shared.awaitLaunchReady(background: false) else { return }")
        let quiet = body.firstIndex(of: "try await Task.sleep(for: .seconds(SyncConfig.databaseUpgradeNoticeQuietDelaySeconds))")
        let read = body.firstIndex(of: "await refreshConditions()")
        let flag = body.firstIndex(of: "UserDefaults.standard.set(true, forKey: Self.noticeOfferedKey)")
        let present = body.firstIndex(of: "isPresented = true")
        let inOrder: Bool = {
            guard let gate, let quiet, let read, let flag, let present else { return false }
            return gate < quiet && quiet < read && read < flag && flag < present
        }()
        let readsBeforeTheGate: [String] = {
            guard let gate else { return ["(no gate)"] }
            return body[..<gate].filter { $0.contains("refresh") || $0.contains("readStates") || $0.contains("openNotice") }
        }()
        let waitsAfterTheRead: [String] = {
            guard let read, let present, read < present else { return ["(not found)"] }
            return body[(read + 1)..<present].filter { $0.contains("await") }
        }()
        let rootView = lines.filter { $0.file == "RootView.swift" }.map { $0.code }
        let tasks = rootView.filter { $0.contains(".task") && $0.contains("databaseUpgrade") }
        let reads = rootView.filter { $0.contains("databaseUpgrade.refresh") || $0.contains("databaseUpgrade.readStates") }

        #expect(inOrder, "launch gate, quiet delay, read, flag, presentation: \(body)")
        #expect(readsBeforeTheGate.isEmpty, "no read before the launch gate: \(readsBeforeTheGate)")
        #expect(waitsAfterTheRead.isEmpty, "no wait between the read and the presentation: \(waitsAfterTheRead)")
        #expect(tasks == [".task { await databaseUpgrade.checkAfterLaunch() }", ".task { await databaseUpgrade.checkAfterLaunch() }"], "the inbox's only upgrade work at appearance is the check: \(tasks)")
        #expect(reads.isEmpty, "RootView reads the databases only through the check: \(reads)")
    }

    /// The tests above pass their own targets and checks, so only the source shows
    /// what production runs.
    @Test("Production runs the steps as the background processing job's last step, after the full sync and the tokenizer rebuild, with the app's targets and the default check, and otherwise only from the Optimize Storage tap")
    func theStepsRunOnlyFromTheBackgroundJobAndTheTap() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let calls = Self.spaceReturnCalls(lines)
        let expected = Self.expectedSpaceReturnCalls
        let scheduler = lines.filter { $0.file == "SyncScheduler.swift" }.map { $0.code }
        let job = scheduler.firstIndex(of: "private func performBackgroundProcessingWork() async {")
        let fullSync = scheduler.firstIndex(of: "await self.syncStartup(inboxOnly: false, drain: .full)")
        let rebuild = scheduler.firstIndex(of: "await SearchIndex.shared.rebuildStaleTokenizerShards()")
        let run = scheduler.firstIndex(of: "await SyncEngine.runOvernightSpaceReturn(targets: targets)")
        let inOrder: Bool = {
            guard let job, let fullSync, let rebuild, let run else { return false }
            return job < fullSync && fullSync < rebuild && rebuild < run
        }()
        let otherFunction: [String] = {
            guard let job, let run, job < run else { return ["(not found)"] }
            return scheduler[(job + 1)..<run].filter { $0.contains("func ") }
        }()

        #expect(calls == expected, "the production callers, with the app's targets and the default checks: \(calls)")
        #expect(inOrder, "after the full sync and the tokenizer rebuild (job \(String(describing: job)), sync \(String(describing: fullSync)), rebuild \(String(describing: rebuild)), run \(String(describing: run)))")
        #expect(otherFunction.isEmpty, "inside the job's own function: \(otherFunction)")
    }

    /// `StorageOptimizerTests` passes its own measure, upgrade state, notice, steps and
    /// check, and calls `stop` itself, so only the source shows what the app's tap runs,
    /// what the app's row measures, and that Settings stops the run when it goes.
    @Test("The Optimize Storage tap runs the app's steps on the email database's background pool with the tap's check, the row measures both databases, and Settings measures on opening and stops the run when it goes")
    func theTapRunsTheAppsStepsWithItsCheck() {
        let lines = SyncEngineMaintenanceTests.productionCodeLines()
        let optimizer = lines.filter { $0.file == "StorageOptimizer.swift" }.map { $0.code }
        let appDefaults = [
            "readMeasure: @escaping @Sendable () async -> Measure = StorageOptimizer.measureTheApp,",
            "readNeedsUpgrade: @escaping @MainActor () async -> Bool = StorageOptimizer.theAppNeedsUpgrade,",
            "openUpgradeNotice: @escaping @MainActor () async -> Void = { await DatabaseUpgrade.shared.openNotice() },",
            "giveBack: @escaping @Sendable (@escaping @Sendable () -> Bool) async -> [SyncEngine.SpaceReturnStep] = StorageOptimizer.giveBackTheAppsEmptyPages,",
            "mayRun: @escaping @Sendable () -> Bool = { SyncEngine.optimizeStorageMayRun() },",
            "minimumGainBytes: Int64 = SyncConfig.optimizeStorageMinimumGainBytes",
            "await giveBack { mayRun() && !Task.isCancelled }",
            "let source = StorageEstimator.SpaceSource.app(pool: AppDatabase.dbPool)",
            "let used = source.reportedBytes()",
            "let pages = await source.pageTotals()",
            "return Measure(usedBytes: used, emptyBytes: pages?.emptyBytes)",
            "await DatabaseUpgrade.shared.refresh()",
            "return DatabaseUpgrade.shared.needsUpgrade",
        ].filter { !optimizer.contains($0) }
        let settings = lines.filter { $0.file == "SettingsView.swift" }.map { $0.code }
        let settingsCalls = [
            ".task { await optimizer.refresh() }",
            ".onDisappear { optimizer.stop() }",
            "if !isPresented { Task { await optimizer.refresh() } }",
        ].filter { !settings.contains($0) }
        let optimizers = lines
            .filter { $0.code.contains("StorageOptimizer(") && !$0.code.contains("func ") }
            .map { "\($0.file): \($0.code)" }

        #expect(appDefaults.isEmpty, "the app's optimizer measures both databases and runs the app's steps with the tap's check and its stop: missing \(appDefaults)")
        #expect(settingsCalls.isEmpty, "Settings measures on opening and after the upgrade's screen closes, and stops the run when it goes: missing \(settingsCalls)")
        #expect(optimizers == ["SettingsView.swift: @State private var optimizer = StorageOptimizer()"], "Settings alone makes one, with the app's defaults: \(optimizers)")
    }
}
