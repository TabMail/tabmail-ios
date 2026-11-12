/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The IMAP backfill UID walk (`SyncEngine.runBackfill`) while something else
/// moves the folder's walk state under a batch in flight: a user reset (Reset
/// Message Data, the Settings local-index wipe, Smart Reindex — none of which
/// touches UIDVALIDITY, so the walk's epoch guard cannot see them) or a
/// second walker on the same account (the background-processing pass and the
/// persistent worker can run at the same time, on the same `SyncEngine`).
/// The IMAP counterpart of the page walk's race tests, driven against the
/// `FakeIMAPServer` through the walk's checkpoint harness
/// (`SyncEngine.BackfillWalkCheckpointForTesting`, chained with
/// `BackfillPageWalkFixture.atCheckpoint`).
///
/// Checked as properties of the folder, never as the expected outcome of one
/// schedule:
/// - **The walk position never claims missing mail**
///   (`BackfillPageWalkFixture.uidPositionClaimsMissingMail`): a complete
///   folder holds every UID the server lists, and a cursor at C holds every
///   listed UID above C. Checked right after the disturbed walker's call.
/// - **A completed folder carries no walk position.**
/// - **The walk covers everything again**: backfill alone, called until the
///   folder completes, loads every message the server lists.
/// - **An undisturbed walk completes in the call that confirms its last
///   range**, and **a call that landed nothing reports no work**.
///
/// The walk's guard is the folder's row version (`Folder.backfillVersion`),
/// compare-and-set by every write of its position (`SyncEngine.writeUIDWalkPosition`).
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, uses the
/// process-wide walk checkpoint hooks, and binds a listening socket via
/// `FakeIMAPServer`.
@Suite("Backfill UID walk — a sibling walker or a reset racing a batch", .serialized, .processGlobalState)
struct BackfillUIDWalkRaceTests {
    private typealias F = BackfillPageWalkFixture

    private static let path = "Receipts"
    /// The UIDVALIDITY the server reports and the folder is stamped with; no
    /// scenario here turns it over.
    private static let epoch = 975_601
    /// Backfill calls the convergence check allows.
    private static let convergenceCalls = 3
    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`, as in `BackfillOnlyFolderEpochTests`.
    private static let capabilities = ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    // MARK: - Fixture

    private static func message(uid: Int) -> FakeIMAPServer.Message {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date().addingTimeInterval(-Double(uid) * 3_600))
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: walk race \(uid)\r
            Date: \(date)\r
            Message-ID: <uid-walk-race-\(uid)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            uid walk race fixture body.\r

            """)
    }

    /// An IMAP account with one backfill-only folder (custom, not a favourite,
    /// so ordinary sync never fetches it: backfill is its only path), stamped
    /// with the server's epoch, on a fresh database, and a registered engine.
    fileprivate struct Walk: Sendable {
        let pool: DatabasePool
        let account: Account
        let server: FakeIMAPServer
        let imap: IMAPProvider
        let engine: SyncEngine
        /// The UIDs the server's folder holds, kept with every change the test makes.
        let onServer: Locked<[Int]>
        var folderId: String { "\(account.id):\(BackfillUIDWalkRaceTests.path)" }

        func row() throws -> Folder {
            try #require(try F.folder(account.id, BackfillUIDWalkRaceTests.path, pool: pool))
        }

        func local() throws -> Set<Int> {
            Set(try F.messageIds(account.id, BackfillUIDWalkRaceTests.path, pool: pool).compactMap { Int($0) })
        }

        func serverUIDs() -> [Int] { onServer.get() }

        func claim() throws -> String? {
            F.uidPositionClaimsMissingMail(try row(), local: try local(), server: serverUIDs())
        }

        func call() async -> Bool {
            await engine.runBackfill(account: account, deadline: F.deadline())
        }

        func callUntilComplete() async throws {
            for _ in 0..<BackfillUIDWalkRaceTests.convergenceCalls {
                if try row().backfillComplete { return }
                _ = await call()
            }
        }

        /// Add a message to the server's folder (new mail arriving).
        func arrive(uid: Int) {
            let uids = (onServer.get() + [uid]).sorted()
            onServer.set(uids)
            server.setMessages(uids.map(BackfillUIDWalkRaceTests.message(uid:)), in: BackfillUIDWalkRaceTests.path)
        }
    }

    private static func makeWalk(
        accountId: String, serverUIDs: [Int], cursor: Int?, localUIDs: [Int], pool: DatabasePool
    ) async throws -> Walk {
        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: ["INBOX": [], path: serverUIDs.map(message(uid:))])
        server.setUidValidity(epoch, for: path)
        // Each range's SEARCH finds only the UIDs in that range, as on a real server.
        server.honorSearchUIDSetCriterion()
        try server.start()
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            var folder = Folder(name: path, path: path, role: .custom, accountId: accountId)
            folder.isFavorite = false
            folder.backfillComplete = false
            folder.backfillUidCursor = cursor
            folder.lastKnownUidValidity = epoch
            try folder.insert(db)
        }
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: path, uids: localUIDs, pool: pool)
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return Walk(pool: pool, account: account, server: server, imap: imap, engine: engine,
                    onServer: Locked(serverUIDs.sorted()))
    }

    private static func tearDown(_ walk: Walk) {
        let imap = walk.imap
        Task { try? await imap.disconnect() }
        walk.server.stop()
    }

    // MARK: - The three user resets

    enum UserReset: String, CaseIterable, Sendable, CustomStringConvertible {
        /// Reset Message Data on the account (`AccountDetailView.resetMessageDataTxn`).
        case accountReset
        /// Delete All Email Index Data in Settings (`SettingsView.localIndexWipeTxn`).
        case settingsWipe
        /// Smart Reindex (`SyncEngine.resetCrawlState`), after loaded messages
        /// went missing locally: the gap the user is repairing.
        case smartReindex

        var description: String { rawValue }

        /// Run the reset. For Smart Reindex, `missingLocally` are the UIDs that
        /// went missing first.
        fileprivate func run(on walk: Walk, missingLocally: [Int]) async {
            let accountId = walk.account.id
            switch self {
            case .accountReset:
                try? await walk.pool.write { try AccountDetailView.resetMessageDataTxn($0, accountId: accountId) }
            case .settingsWipe:
                try? await walk.pool.write { try SettingsView.localIndexWipeTxn($0) }
            case .smartReindex:
                let folderId = walk.folderId
                let ids = missingLocally.map(String.init)
                try? await walk.pool.write { db in
                    _ = try MessageHeader
                        .filter(Column("folderId") == folderId && ids.contains(Column("messageId")))
                        .deleteAll(db)
                }
                await walk.engine.resetCrawlState()
            }
        }
    }

    /// Smart Reindex clears this process-wide flag; the tests put it back.
    private static let ccBccKey = "ccBccBackfillDone"

    // MARK: - (1) A user reset lands while a walker is mid-batch

    /// The walker resumes mid-walk (cursor 10, UID 12 above it already
    /// loaded) and the reset lands after it fetched the batch below the
    /// cursor, before it inserts it. Before #756 the walker then completed the
    /// folder: the reset had removed UID 12, and a complete folder is never
    /// walked again, so it stayed missing until the next Smart Reindex.
    @Test("A user reset mid-batch: the walk's position never claims missing mail, and the walk covers the folder again",
          arguments: UserReset.allCases)
    func resetMidBatch(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-reset-\(reset)", serverUIDs: [3, 7, 12], cursor: 10, localUIDs: [12], pool: pool)
        defer { Self.tearDown(walk) }

        F.atCheckpoint(1, .beforeInsertingFetchedChunk(folderId: walk.folderId)) {
            await reset.run(on: walk, missingLocally: [12])
        }
        _ = await walk.call()

        let claim = try walk.claim()
        #expect(claim == nil, "\(reset): after the walker that was mid-batch finished its call, \(claim ?? "")")

        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed again after the reset")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty,
                "\(reset): backfill never loaded UIDs \(missing.sorted()) again after the reset; they stay missing until the user runs Smart Reindex")
    }

    // MARK: - (2) A reset, then a sibling re-plants the very cursor the stale walker last wrote

    /// The folder holds mail at the bottom (UID 150) and the top (UID 2500)
    /// of the walk, with empty ranges between, whatever the chunk size. The
    /// walker plants its cursor at 2500. Its top batch (fetched first: the
    /// walk hands out ranges top down and the folder's commands share one
    /// connection) is held before its insert while the bottom batch is
    /// loaded, so the cursor the walker saves stays 2500 (the top range is not
    /// confirmed yet); a precondition checks that order. Then, with the top
    /// batch still not inserted: the reset (which removes UID 150), and a
    /// sibling walker that starts afresh from UIDNEXT — planting exactly 2500
    /// — and is held before inserting anything. The stale walker's cursor
    /// still matches the folder, so only the reset itself can tell it that
    /// what it loaded before is gone. Before #756 it completed the folder
    /// without UID 150.
    @Test("A user reset mid-batch, then a sibling re-plants the same cursor: the stale walker never completes the folder",
          arguments: UserReset.allCases)
    func resetThenSiblingReplantsTheSameCursor(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-replant-\(reset)", serverUIDs: [150, 2500], cursor: nil, localUIDs: [], pool: pool)
        defer { Self.tearDown(walk) }
        let gate = BackfillWalkHandshake()
        let bottomLoadedFirst = Locked<Bool?>(nil)
        let replanted = Locked<Int?>(nil)
        let sibling = Locked<Task<Bool, Never>?>(nil)
        let folderId = walk.folderId
        // The first batch to reach its insert is held; the other one goes
        // through meanwhile. The schedule wants the top batch held (so the
        // cursor the walker saves stays 2500) and the bottom one loaded.
        F.atCheckpoint(1, .beforeInsertingFetchedChunk(folderId: folderId)) {
            var loaded = false
            for _ in 0..<500 {
                if (try? walk.local().contains(150)) == true { loaded = true; break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            bottomLoadedFirst.set(loaded)
            await reset.run(on: walk, missingLocally: [150])
            // The sibling's inserts all wait until the stale walker's call is over.
            SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
                $0[.beforeInsertingFetchedChunk(folderId: folderId)] = {
                    SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
                        $0[.beforeInsertingFetchedChunk(folderId: folderId)] = { await gate.wait("release-sibling") }
                    }
                    gate.signal("sibling-held")
                    await gate.wait("release-sibling")
                }
            }
            sibling.set(Task { await walk.call() })
            await gate.wait("sibling-held")
            // Read while both walkers are still held, before the stale walker
            // writes anything more.
            replanted.set(try? walk.row().backfillUidCursor)
        }

        _ = await walk.call()

        #expect(bottomLoadedFirst.get() == true,
                "\(reset): precondition: the bottom batch was loaded before the reset")
        #expect(replanted.get() == 2500, "\(reset): precondition: the sibling re-planted the cursor at UIDNEXT - 1")
        let claim = try walk.claim()
        #expect(claim == nil,
                "\(reset): after the stale walker's call (the sibling re-planted cursor \(String(describing: replanted.get()))), \(claim ?? "")")

        gate.signal("release-sibling")
        _ = await sibling.get()?.value
        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty, "\(reset): backfill never loaded UIDs \(missing.sorted()) again after the reset")
    }

    // MARK: - (3) Two walkers on one folder

    /// The stale walker read UIDNEXT 13 and is about to plant cursor 12. New
    /// mail (UID 14) arrives; a sibling plants 14 and is held before inserting
    /// it. Before #756 the stale walker planted 12 over the sibling's 14 and
    /// walked on to complete the folder: UID 14 was never loaded.
    @Test("Two walkers: a stale walker never plants its cursor below mail its sibling planted to walk")
    func staleWalkerNeverPlantsBelowItsSibling() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-sibling-plant", serverUIDs: [3, 7, 12], cursor: nil, localUIDs: [], pool: pool)
        defer { Self.tearDown(walk) }

        let gate = BackfillWalkHandshake()
        let sibling = Locked<Task<Bool, Never>?>(nil)
        let siblingPlanted = Locked<Int?>(nil)
        let folderId = walk.folderId
        F.atCheckpoint(1, .beforeFreshBookkeepingWrite(folderId: folderId)) {
            walk.arrive(uid: 14)
            F.atCheckpoint(1, .beforeInsertingFetchedChunk(folderId: folderId)) {
                siblingPlanted.set(try? walk.row().backfillUidCursor)
                gate.signal("sibling-held")
                await gate.wait("release-sibling")
            }
            sibling.set(Task { await walk.call() })
            await gate.wait("sibling-held")
        }

        _ = await walk.call()

        #expect(siblingPlanted.get() == 14, "precondition: the sibling planted its cursor at the new UIDNEXT - 1")
        let claim = try walk.claim()
        #expect(claim == nil, "after the stale walker's call, \(claim ?? "")")

        gate.signal("release-sibling")
        _ = await sibling.get()?.value
        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "the folder's walk never completed")
        let loaded = try walk.local()
        #expect(loaded == Set(walk.serverUIDs()),
                "loaded \(loaded.sorted()), server lists \(walk.serverUIDs())")
    }

    /// The stale walker read UIDNEXT and is about to plant its cursor; a
    /// sibling walks the folder to completion meanwhile. Before #756 the stale
    /// walker planted its cursor onto the completed folder and walked it again.
    @Test("Two walkers: a stale walker never writes a walk position onto the folder its sibling completed")
    func staleWalkerNeverWritesOntoACompletedFolder() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-sibling-complete", serverUIDs: [3, 7, 12], cursor: nil, localUIDs: [], pool: pool)
        defer { Self.tearDown(walk) }

        let siblingCompleted = Locked<Bool>(false)
        let completeWithPosition = Locked<[String]>([])
        let folderId = walk.folderId
        F.atCheckpoint(1, .beforeFreshBookkeepingWrite(folderId: folderId)) {
            _ = await walk.call()
            siblingCompleted.set((try? walk.row().backfillComplete) == true)
            // Sampled whenever the stale walker gets as far as a batch.
            F.atCheckpoint(1, .beforeInsertingFetchedChunk(folderId: folderId)) {
                if let row = try? walk.row(), row.backfillComplete, let cursor = row.backfillUidCursor {
                    completeWithPosition.set(completeWithPosition.get() + ["complete with cursor \(cursor)"])
                }
            }
        }

        _ = await walk.call()

        #expect(siblingCompleted.get(), "precondition: the sibling completed the folder")
        #expect(completeWithPosition.get().isEmpty,
                "the stale walker wrote a walk position onto the folder its sibling completed: \(completeWithPosition.get())")
        let after = try walk.row()
        #expect(after.backfillComplete && after.backfillUidCursor == nil,
                "complete \(after.backfillComplete), cursor \(String(describing: after.backfillUidCursor))")
        let claim = try walk.claim()
        #expect(claim == nil, "\(claim ?? "")")
        let loaded = try walk.local()
        #expect(loaded == Set(walk.serverUIDs()),
                "loaded \(loaded.sorted()), server lists \(walk.serverUIDs())")
    }

    // MARK: - (4) Empty ranges, the empty mailbox, and the work a call reports

    /// A resumed walk's cursor, with every UID below it absent from the
    /// server, so every range the walk covers is empty. Above the largest
    /// chunk any profile uses, so the walk's top range ends here and no other
    /// range does.
    private static let resumedCursor = 4_000
    /// The one message the folder holds, above `resumedCursor`: loaded by an
    /// earlier pass, and gone locally once a reset ran.
    private static let aboveCursor = 5_000
    /// How long the server holds the SEARCH of the walk's top range while the
    /// reset lands. Longer than the walk's progress throttle (1 s), so the
    /// confirm that follows is a progress write whatever the walk confirmed
    /// before.
    private static let searchStallSeconds = 1.5
    /// Bound, in 10 ms polls, on waiting for the walk to send that SEARCH.
    private static let commandWaitPolls = 1_000

    /// Walk the folder of `walk` (resumed at `resumedCursor`) once, with
    /// `reset` landing while the server holds the SEARCH of the walk's top
    /// range, before that range's empty answer is confirmed. Returns the
    /// call's result and whether the reset finished inside the hold.
    private static func resetDuringTopRangeSearch(
        _ walk: Walk, _ reset: UserReset
    ) async -> (didWork: Bool, resetInsideHold: Bool) {
        let topRange = ":\(resumedCursor)"
        walk.server.stallNextCommand(containing: topRange, seconds: searchStallSeconds)
        let call = Task { await walk.call() }
        var sent = false
        for _ in 0..<commandWaitPolls {
            if walk.server.recordedCommands().contains(where: { $0.contains(topRange) }) { sent = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let clock = ContinuousClock()
        let start = clock.now
        await reset.run(on: walk, missingLocally: [aboveCursor])
        let insideHold = sent && clock.now - start < .milliseconds(Int(searchStallSeconds * 1_000))
        return (await call.value, insideHold)
    }

    /// The walker resumes at cursor 4000 with UID 5000 above it already
    /// loaded. The reset (which removes UID 5000) lands while the server holds
    /// the SEARCH of the top range, so the first thing the walker writes after
    /// the reset is the progress write of an empty range. A stale progress
    /// write puts a cursor below 5000 back onto the reset folder; the walk
    /// then resumes from it, and UID 5000 is never loaded again.
    @Test("A reset before an empty range's progress write: the walk's position never claims missing mail",
          arguments: UserReset.allCases)
    func resetBeforeAnEmptyRangeProgressWrite(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-empty-range-\(reset)", serverUIDs: [Self.aboveCursor],
            cursor: Self.resumedCursor, localUIDs: [Self.aboveCursor], pool: pool)
        defer { Self.tearDown(walk) }

        let (_, resetInsideHold) = await Self.resetDuringTopRangeSearch(walk, reset)

        #expect(resetInsideHold, "\(reset): precondition: the reset landed while the top range's SEARCH was held")
        let claim = try walk.claim()
        #expect(claim == nil, "\(reset): after the walker's call, \(claim ?? "")")

        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed again after the reset")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty, "\(reset): backfill never loaded UIDs \(missing.sorted()) again after the reset")
    }

    /// The walker found the mailbox empty (UIDNEXT 1) and is about to mark the
    /// folder complete. Meanwhile UID 1 arrives and the reset runs. A stale
    /// completion marks the reset folder complete without UID 1, and a
    /// complete folder is never walked again.
    @Test("An empty mailbox (UIDNEXT 1): a stale walker never completes the folder after a reset",
          arguments: UserReset.allCases)
    func emptyMailboxCompletionAfterAReset(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-empty-mailbox-\(reset)", serverUIDs: [], cursor: nil, localUIDs: [], pool: pool)
        defer { Self.tearDown(walk) }

        F.atCheckpoint(1, .beforeFreshBookkeepingWrite(folderId: walk.folderId)) {
            walk.arrive(uid: 1)
            await reset.run(on: walk, missingLocally: [])
        }
        _ = await walk.call()

        let claim = try walk.claim()
        #expect(claim == nil, "\(reset): after the walker's call, \(claim ?? "")")

        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed again after the reset")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty, "\(reset): backfill never loaded UIDs \(missing.sorted()) after the reset")
    }

    /// The walker resumes at cursor 4000 with UID 5000 above it already
    /// loaded, and every range below the cursor is empty. It confirms them
    /// all (its first progress write lands), and the reset (which removes UID
    /// 5000) lands after its workers joined, before its final write. That
    /// completion is the first thing it writes after the reset: it is refused,
    /// so the reset folder is not marked complete without UID 5000, and the
    /// call, which loaded nothing and landed nothing, reports no work.
    @Test("A reset between a walk's last range and its completion: the completion is refused and the call reports no work",
          arguments: UserReset.allCases)
    func resetBeforeTheWalkEndWrite(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-walk-end-\(reset)", serverUIDs: [Self.aboveCursor],
            cursor: Self.resumedCursor, localUIDs: [Self.aboveCursor], pool: pool)
        defer { Self.tearDown(walk) }

        let progressCursor = Locked<Int?>(nil)
        F.atCheckpoint(1, .afterWorkersJoinedBeforeFinalBookkeeping(folderId: walk.folderId)) {
            progressCursor.set(try? walk.row().backfillUidCursor)
            await reset.run(on: walk, missingLocally: [Self.aboveCursor])
        }
        let didWork = await walk.call()

        #expect(progressCursor.get().map { $0 < Self.resumedCursor } == true,
                "\(reset): precondition: the walk's own progress write landed before the reset (cursor \(String(describing: progressCursor.get())))")
        let row = try walk.row()
        #expect(!row.backfillComplete, "\(reset): the stale walker completed the reset folder")
        let claim = try walk.claim()
        #expect(claim == nil, "\(reset): after the walker's call, \(claim ?? "")")
        #expect(!didWork, "\(reset): the call's only write after the reset was refused and it loaded nothing, yet it reported work")

        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed again after the reset")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty, "\(reset): backfill never loaded UIDs \(missing.sorted()) again after the reset")
    }

    /// The walker resumes at cursor 4000 (UID 5000 above it already loaded)
    /// over empty ranges, and the commit of its progress write fails: the
    /// transaction rolls back, and with it the folder's version and the
    /// counter that issued it. The reset (which removes UID 5000) then lands
    /// after the workers joined, before the final write, and its bump is the
    /// next one in the database: it reissues the very version the rolled-back
    /// write produced. The walk never takes a version it did not commit for
    /// its own, so it never writes over the reset.
    @Test("A walk-position write whose commit failed never lets the walk write over a later reset",
          arguments: UserReset.allCases)
    func rolledBackPositionWriteNeverOverwritesAReset(_ reset: UserReset) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }
        let savedCcBcc = UserDefaults.standard.object(forKey: Self.ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: Self.ccBccKey) }

        let walk = try await Self.makeWalk(
            accountId: "uid-race-rolled-back-\(reset)", serverUIDs: [Self.aboveCursor],
            cursor: Self.resumedCursor, localUIDs: [Self.aboveCursor], pool: pool)
        defer { Self.tearDown(walk) }

        let failCommits = FailCursorWriteCommits()
        pool.add(transactionObserver: failCommits)
        defer { pool.remove(transactionObserver: failCommits) }
        let counterBefore = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT value FROM backfillVersionCounter WHERE id = 1")
        }
        failCommits.arm(true)
        let resetVersion = Locked<Int?>(nil)
        F.atCheckpoint(1, .afterWorkersJoinedBeforeFinalBookkeeping(folderId: walk.folderId)) {
            failCommits.arm(false)
            await reset.run(on: walk, missingLocally: [Self.aboveCursor])
            resetVersion.set(try? walk.row().backfillVersion)
        }
        _ = await walk.call()

        #expect(failCommits.failed > 0, "\(reset): precondition: the commit of a walk-position write failed")
        #expect(resetVersion.get() != nil && resetVersion.get() == counterBefore.map { $0 + 1 },
                "\(reset): precondition: the reset's version (\(String(describing: resetVersion.get()))) is the one the rolled-back write produced (\(String(describing: counterBefore.map { $0 + 1 })))")
        let row = try walk.row()
        #expect(!row.backfillComplete && row.backfillUidCursor == nil,
                "\(reset): the walk wrote over the reset: complete \(row.backfillComplete), cursor \(String(describing: row.backfillUidCursor))")
        let claim = try walk.claim()
        #expect(claim == nil, "\(reset): after the walker's call, \(claim ?? "")")

        try await walk.callUntilComplete()
        #expect(try walk.row().backfillComplete, "\(reset): the folder's walk never completed again after the reset")
        let missing = Set(walk.serverUIDs()).subtracting(try walk.local())
        #expect(missing.isEmpty, "\(reset): backfill never loaded UIDs \(missing.sorted()) again after the reset")
    }

    /// The walker resumes at a cursor below the smallest chunk any profile
    /// uses, so one empty range is all that is left. Nothing disturbs it.
    /// Its progress write and its completion are both its own, so the call
    /// that confirms the last range completes the folder: the walk never
    /// refuses a write because of a position it wrote itself.
    @Test("An undisturbed walk completes the folder in the call that confirms its last range")
    func undisturbedWalkCompletesInOneCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }

        let lastRangeCursor = BackfillProfile.low.backfillChunkSize / 2
        let walk = try await Self.makeWalk(
            accountId: "uid-race-undisturbed", serverUIDs: [Self.aboveCursor],
            cursor: lastRangeCursor, localUIDs: [Self.aboveCursor], pool: pool)
        defer { Self.tearDown(walk) }

        let didWork = await walk.call()

        let row = try walk.row()
        #expect(row.backfillComplete && row.backfillUidCursor == nil,
                "after one call: complete \(row.backfillComplete), cursor \(String(describing: row.backfillUidCursor))")
        #expect(didWork, "the call completed the folder, yet reported no work")
    }

    /// The walk-position write a call makes, refused because a reset landed.
    enum RefusedWrite: String, CaseIterable, Sendable, CustomStringConvertible {
        /// The completion of a mailbox found empty (UIDNEXT 1).
        case emptyMailboxCompletion
        /// The writes at the end of a resumed walk over empty ranges.
        case walkEndWrite

        var description: String { rawValue }
    }

    /// The reset lands before the call's walk-position writes, and the call
    /// has nothing to load, so nothing it did landed. It must report no work,
    /// or the worker paces the next call as if it had made progress.
    @Test("A call whose walk-position writes were refused, and which loaded nothing, reports no work",
          arguments: RefusedWrite.allCases)
    func refusedWriteIsNoWork(_ write: RefusedWrite) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { F.clearWalkCheckpoints() }

        let didWork: Bool
        let walk: Walk
        switch write {
        case .emptyMailboxCompletion:
            walk = try await Self.makeWalk(
                accountId: "uid-race-no-work-\(write)", serverUIDs: [], cursor: nil, localUIDs: [], pool: pool)
            F.atCheckpoint(1, .beforeFreshBookkeepingWrite(folderId: walk.folderId)) {
                await UserReset.accountReset.run(on: walk, missingLocally: [])
            }
            didWork = await walk.call()
        case .walkEndWrite:
            walk = try await Self.makeWalk(
                accountId: "uid-race-no-work-\(write)", serverUIDs: [Self.aboveCursor],
                cursor: Self.resumedCursor, localUIDs: [Self.aboveCursor], pool: pool)
            let (result, resetInsideHold) = await Self.resetDuringTopRangeSearch(walk, .accountReset)
            #expect(resetInsideHold, "precondition: the reset landed while the top range's SEARCH was held")
            didWork = result
        }
        defer { Self.tearDown(walk) }

        let row = try walk.row()
        let loaded = try walk.local()
        #expect(!row.backfillComplete && row.backfillUidCursor == nil && loaded.isEmpty,
                "\(write): precondition: nothing the call did landed (complete \(row.backfillComplete), cursor \(String(describing: row.backfillUidCursor)), loaded \(loaded.sorted()))")
        #expect(!didWork, "\(write): the call landed nothing, yet reported work")
    }
}

/// While armed, fails the commit of every transaction that wrote a folder's
/// UID cursor: the transaction rolls back after its statements ran, as an I/O
/// error or a full disk at commit would.
private final class FailCursorWriteCommits: TransactionObserver, @unchecked Sendable {
    private let state = Mutex((armed: false, pending: false, failed: 0))
    var failed: Int { state.withLock { $0.failed } }
    func arm(_ armed: Bool) { state.withLock { $0.armed = armed } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .update(let tableName, let columnNames) = eventKind {
            return tableName == "folder" && columnNames.contains("backfillUidCursor")
        }
        return false
    }
    func databaseDidChange(with event: DatabaseEvent) { state.withLock { $0.pending = true } }
    func databaseWillCommit() throws {
        let fail = state.withLock { value -> Bool in
            guard value.armed, value.pending else { return false }
            value.failed += 1
            return true
        }
        if fail { throw NSError(domain: "InjectedCommitFailure", code: 1) }
    }
    func databaseDidCommit(_ db: Database) { state.withLock { $0.pending = false } }
    func databaseDidRollback(_ db: Database) { state.withLock { $0.pending = false } }
}

/// A value a checkpoint hook sets and the test reads afterwards.
private final class Locked<Value: Sendable>: Sendable {
    private let box: Mutex<Value>
    init(_ value: Value) { box = Mutex(value) }
    func set(_ value: Value) { box.withLock { $0 = value } }
    func get() -> Value { box.withLock { $0 } }
}
