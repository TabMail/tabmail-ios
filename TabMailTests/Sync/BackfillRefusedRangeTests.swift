/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
import Synchronization
@testable import TabMail

/// One-shot fault for `storedUIDReadFailureLeavesTheRangePending`: while
/// `armed`, every read of `messageHeader.messageId` prepared on a READER
/// connection is denied (the statement fails to prepare). Writers never get the authorizer, so inserts are unaffected.
private let storedUIDReadFault = Mutex((armed: false, refused: 0))

/// The IMAP UID walk and a range it cannot load:
/// - a range whose SEARCH is refused is asked at most once per worker in a
///   walk, the walk moves on and loads every other range, the range is never
///   claimed (the cursor stays above it, the folder does not complete), and
///   the next call asks it again;
/// - a range whose SEARCH drops the connection each time ends the workers
///   that ask it, stays pending, and declines its folder for the rest of the
///   call, so the call ends and the other folders are walked; the next call
///   asks it again;
/// - a range whose FETCH times out (the client's own command timeout, as
///   production meets it) is retried smaller, never at its own size, down to
///   one UID, which is then left for the next call.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, binds a
/// listening socket via `FakeIMAPServer`.
@Suite("Backfill walk — a range that cannot load is left for the next call", .serialized, .processGlobalState)
struct BackfillRefusedRangeTests {
    private typealias F = BackfillPageWalkFixture

    private static let epoch = 718_204
    /// Ranges the walk covers below its starting cursor.
    private static let rangeCount = 6
    /// The range (counted from the top, 0-based) the server refuses.
    private static let refusedRange = 2
    /// How long a call may take before the test calls it a spin.
    private static let spinBoundSeconds: TimeInterval = 15
    /// SwiftMail's deadline for a header FETCH (`FetchMessageInfoCommand.timeoutSeconds`):
    /// the time each FETCH timeout in these tests costs.
    private static let fetchTimeoutSeconds: TimeInterval = 10
    /// A refusal whose words read like a connection error, as some servers word it.
    private static let refusalText = "command failed: search timed out"
    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`, as in `BackfillInsertFailureTests`.
    private static let capabilities = ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    /// The walk's ranges for `chunk`: range i (from the top) is
    /// `(rangeCount-1-i)*chunk+1 ... (rangeCount-i)*chunk`.
    private static func range(_ i: Int, chunk: Int) -> ClosedRange<Int> {
        let top = (rangeCount - i) * chunk
        return (top - chunk + 1)...top
    }

    /// One UID in the middle of each range, plus a second one in the lowest range.
    private static func serverUIDs(chunk: Int) -> [Int] {
        var uids = (0..<rangeCount).map { range($0, chunk: chunk).lowerBound + chunk / 2 }
        uids.append(range(rangeCount - 1, chunk: chunk).lowerBound + 1)
        return uids.sorted()
    }

    private static func message(uid: Int) -> FakeIMAPServer.Message {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date().addingTimeInterval(-Double(uid) * 60))
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Cc: Copied <copied-\(uid)@example.com>\r
            Subject: refused range \(uid)\r
            Date: \(date)\r
            Message-ID: <refused-range-\(uid)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            refused range fixture body.\r

            """)
    }

    private struct World {
        let pool: DatabasePool
        let account: Account
        let server: FakeIMAPServer
        let imap: IMAPProvider
        let engine: SyncEngine
        let path: String
        let chunk: Int
        let uids: [Int]

        var folderId: String { "\(account.id):\(path)" }
        func row() throws -> Folder { try #require(try F.folder(account.id, path, pool: pool)) }
        func row(_ path: String) throws -> Folder { try #require(try F.folder(account.id, path, pool: pool)) }
        func local() throws -> Set<Int> { try local(path) }
        func local(_ path: String) throws -> Set<Int> {
            Set(try F.messageIds(account.id, path, pool: pool).compactMap { Int($0) })
        }
    }

    /// A stamped, non-favourite folder the walk resumes at `cursor`.
    private static func insertWalkFolder(_ db: Database, path: String, accountId: String, cursor: Int,
                                         role: FolderRole = .custom) throws {
        var folder = Folder(name: path, path: path, role: role, accountId: accountId)
        folder.isFavorite = false
        folder.backfillComplete = false
        folder.backfillUidCursor = cursor
        folder.lastKnownUidValidity = epoch
        try folder.insert(db)
    }

    /// The walked folder holds `uids` (default: `serverUIDs`) and resumes at
    /// `startCursor` (default: the top of `rangeCount` ranges). `otherFolder`,
    /// when given, is a second walked folder with its own UIDs, resumed at its
    /// highest UID.
    private static func makeWorld(
        accountId: String, pool: DatabasePool,
        uids custom: [Int]? = nil, startCursor: Int? = nil,
        otherFolder: (path: String, uids: [Int])? = nil,
        role: FolderRole = .custom
    ) async throws -> World {
        let path = "Receipts"
        let engine = SyncEngine()
        let chunk = await engine.getBackfillProfile().backfillChunkSize
        let uids = custom ?? serverUIDs(chunk: chunk)
        var mailboxes: [String: [FakeIMAPServer.Message]] = ["INBOX": [], path: uids.map(message(uid:))]
        if let otherFolder { mailboxes[otherFolder.path] = otherFolder.uids.map(message(uid:)) }
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: mailboxes)
        server.setUidValidity(epoch, for: path)
        if let otherFolder { server.setUidValidity(epoch, for: otherFolder.path) }
        server.honorSearchUIDSetCriterion()
        try server.start()
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            try Self.insertWalkFolder(db, path: path, accountId: accountId, cursor: startCursor ?? rangeCount * chunk,
                                      role: role)
            if let otherFolder {
                try Self.insertWalkFolder(db, path: otherFolder.path, accountId: accountId,
                                          cursor: otherFolder.uids.max() ?? 0)
            }
        }
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return World(pool: pool, account: account, server: server, imap: imap, engine: engine,
                     path: path, chunk: chunk, uids: uids)
    }

    private static func tearDown(_ world: World) {
        let imap = world.imap
        Task { try? await imap.disconnect() }
        world.server.stop()
    }

    /// Run one backfill call; false when it had not ended by `bound` seconds
    /// (it is then cancelled, so the test can report the spin and go on).
    private static func callEnds(_ world: World, bound: TimeInterval = spinBoundSeconds) async -> Bool {
        let engine = world.engine, account = world.account
        let call = Task { await engine.runBackfillWalk(account: account, deadline: F.deadline()) }
        return await callEnds(call, bound: bound)
    }

    /// Whether `call` ended by itself within `bound` seconds. When the timer
    /// wins, the walk is cancelled INSIDE the group (its workers stop on
    /// cancellation), so the group can drain and the test reports the spin.
    private static func callEnds(_ call: Task<Bool, Never>, bound: TimeInterval = spinBoundSeconds) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await call.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(bound))
                call.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            for await _ in group {}
            return first
        }
    }

    /// One walk call's own result (`runBackfillWalk`: did it do work), or nil
    /// when it did not end within `spinBoundSeconds`.
    private static func walkResult(_ world: World) async -> Bool? {
        let engine = world.engine, account = world.account
        let call = Task { await engine.runBackfillWalk(account: account, deadline: F.deadline()) }
        guard await callEnds(call) else { return nil }
        return await call.value
    }

    private static func isSearch(_ command: String, of r: ClosedRange<Int>) -> Bool {
        let upper = command.uppercased()
        return upper.contains("UID SEARCH") && upper.contains("UID \(r.lowerBound):\(r.upperBound)")
    }

    /// The UIDs a `UID FETCH` command names.
    private static func fetchedUIDs(_ command: String) -> Set<Int> {
        let words = command.split(separator: " ")
        guard let at = words.firstIndex(where: { $0.uppercased() == "FETCH" }), at > 0,
              words[at - 1].uppercased() == "UID", at + 1 < words.count else { return [] }
        var uids = Set<Int>()
        for item in words[at + 1].split(separator: ",") {
            let bounds = item.split(separator: ":").compactMap { Int($0) }
            guard let low = bounds.min(), let high = bounds.max() else { continue }
            uids.formUnion(low...high)
        }
        return uids
    }

    private static func fetches(_ commands: ArraySlice<String>) -> [Set<Int>] {
        commands.map(fetchedUIDs).filter { !$0.isEmpty }
    }

    // MARK: - A refused SEARCH

    @Test("A range whose SEARCH is always refused is left for the next call; every other range loads")
    func refusedSearchRangeIsLeftForTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let world = try await Self.makeWorld(accountId: "refused-search", pool: pool)
        defer { Self.tearDown(world) }
        let refused = Self.range(Self.refusedRange, chunk: world.chunk)
        world.server.failEveryCommand(
            containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: Self.refusalText)

        let ended = await Self.callEnds(world)
        #expect(ended, "the call did not end: the walk kept asking the refused range")
        let workers = await world.imap.poolMaxConnections()
        let asked = world.server.recordedCommands().filter { Self.isSearch($0, of: refused) }.count
        #expect(asked >= 1 && asked <= workers,
                "the call asked the refused range \(asked) times with \(workers) workers")

        let outside = world.uids.filter { !refused.contains($0) }
        let missing = Set(outside).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) outside the refused range did not load")
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a range that never loaded")
        #expect((row.backfillUidCursor ?? 0) >= refused.upperBound,
                "the cursor \(String(describing: row.backfillUidCursor)) moved past the refused range")
        let claim = F.uidPositionClaimsMissingMail(row, local: try world.local(), server: world.uids)
        #expect(claim == nil, "\(claim ?? "")")

        // The next call asks it again, and it is still not claimed.
        let before = world.server.recordedCommands().count
        #expect(await Self.callEnds(world), "the second call did not end")
        let askedAgain = world.server.recordedCommands().dropFirst(before).filter { Self.isSearch($0, of: refused) }.count
        #expect(askedAgain >= 1, "the next call did not ask the refused range again")
        #expect(!(try world.row()).backfillComplete)
    }

    @Test("A range whose SEARCH is refused once loads on the next call")
    func searchRefusedOnceLoadsOnTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let world = try await Self.makeWorld(accountId: "refused-search-once", pool: pool)
        defer { Self.tearDown(world) }
        let refused = Self.range(Self.refusedRange, chunk: world.chunk)
        world.server.failNextCommand(
            containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: Self.refusalText)

        #expect(await Self.callEnds(world))
        #expect(!(try world.row()).backfillComplete, "precondition: the first call left the refused range")
        #expect(await Self.callEnds(world))
        #expect(try world.row().backfillComplete, "the folder did not complete once the range answered")
        let missing = Set(world.uids).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
    }

    // MARK: - A SEARCH that drops the connection

    @Test("A range whose SEARCH drops the connection every time is left pending; the call ends, the other folder loads, and the next call asks again")
    func searchThatDropsTheConnectionIsLeftForTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        // The other folder's one range (1...3) is far below the dropped one,
        // so the drop never matches its SEARCH; its UIDs (and so its
        // Message-IDs) are none of the walked folder's.
        let other = (path: "Invoices", uids: [1, 3])
        let world = try await Self.makeWorld(accountId: "dropped-search", pool: pool, otherFolder: other)
        defer { Self.tearDown(world) }
        let dropped = Self.range(Self.refusedRange, chunk: world.chunk)
        world.server.killConnectionOnEveryCommand(containing: "UID \(dropped.lowerBound):\(dropped.upperBound)")

        #expect(await Self.callEnds(world), "the call did not end: it kept walking the folder whose range drops the connection")
        let workers = await world.imap.poolMaxConnections()
        let asked = world.server.recordedCommands().filter { Self.isSearch($0, of: dropped) }.count
        #expect(asked >= 1 && asked <= workers,
                "the call asked the dropped range \(asked) times with \(workers) workers")

        // The other folder was walked in the same call.
        #expect(try world.local(other.path) == Set(other.uids), "the other folder did not load")
        #expect(try world.row(other.path).backfillComplete, "the other folder did not complete")

        // Nothing was skipped: the folder stands above the dropped range.
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a range that never loaded")
        #expect((row.backfillUidCursor ?? 0) >= dropped.upperBound,
                "the cursor \(String(describing: row.backfillUidCursor)) moved past the dropped range")
        let claim = F.uidPositionClaimsMissingMail(row, local: try world.local(), server: world.uids)
        #expect(claim == nil, "\(claim ?? "")")

        // The next call asks it again.
        let before = world.server.recordedCommands().count
        #expect(await Self.callEnds(world), "the second call did not end")
        let askedAgain = world.server.recordedCommands().dropFirst(before).filter { Self.isSearch($0, of: dropped) }.count
        #expect(askedAgain >= 1, "the next call did not ask the dropped range again")
        #expect(!(try world.row()).backfillComplete)

        // Once the link holds, the folder completes.
        world.server.stopFailingCommands(containing: "UID \(dropped.lowerBound):\(dropped.upperBound)")
        #expect(await Self.callEnds(world))
        #expect(try world.row().backfillComplete, "the folder did not complete once the range answered")
        let missing = Set(world.uids).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
    }

    // MARK: - A FETCH that fails after its SEARCH answered

    /// How a range's FETCH fails in `fetchFailureIsLeftForTheNextCall`.
    enum FetchFailure: String, CaseIterable, Sendable {
        /// The server closes the connection on the FETCH.
        case dropsConnection
        /// The server answers the FETCH with a tagged NO whose words are
        /// neither a timeout, a payload error nor a connection error.
        case otherError
    }

    /// Words for the tagged NO: none of `isConnectionError`'s, `isSelectFailedError`'s,
    /// the timeout's or the payload split's.
    private static let fetchRefusalText = "message temporarily unavailable"

    @Test("A range whose FETCH keeps failing after its SEARCH answered is left pending; the folder is declined for the call, the other folder loads, the next call asks again",
          arguments: FetchFailure.allCases)
    func fetchFailureIsLeftForTheNextCall(_ failure: FetchFailure) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        // The other folder's UIDs are none of the failing range's, so its
        // FETCH never matches the injected fragment.
        let other = (path: "Invoices", uids: [1, 3])
        let world = try await Self.makeWorld(accountId: "fetch-\(failure.rawValue)", pool: pool, otherFolder: other)
        defer { Self.tearDown(world) }
        let failing = Self.range(Self.refusedRange, chunk: world.chunk)
        let inRange = world.uids.filter { failing.contains($0) }
        try #require(inRange.count == 1)
        let uid = inRange[0]
        // SEARCH of the range answers (it names the range, not the UID); only
        // the FETCH of its one UID fails.
        let fragment = "FETCH \(uid) "
        switch failure {
        case .dropsConnection: world.server.killConnectionOnEveryCommand(containing: fragment)
        case .otherError: world.server.failEveryCommand(containing: fragment, message: Self.fetchRefusalText)
        }

        #expect(await Self.callEnds(world), "the call did not end: it kept walking the folder whose FETCH fails")
        let commands = world.server.recordedCommands()
        #expect(commands.contains { Self.isSearch($0, of: failing) }, "precondition: the range's SEARCH was sent")
        let workers = await world.imap.poolMaxConnections()
        let tries = Self.fetches(commands[...]).filter { $0.contains(uid) }.count
        #expect(tries >= 1 && tries <= workers, "the call fetched the failing UID \(tries) times with \(workers) workers")

        // The other folder was walked in the same call.
        #expect(try world.local(other.path) == Set(other.uids), "the other folder did not load")
        #expect(try world.row(other.path).backfillComplete, "the other folder did not complete")

        // Nothing was skipped: the folder stands above the failing range.
        #expect(!(try world.local()).contains(uid), "precondition: the failing UID did not load")
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a range that never loaded")
        #expect((row.backfillUidCursor ?? 0) >= failing.upperBound,
                "the cursor \(String(describing: row.backfillUidCursor)) moved past the failing range")
        let claim = F.uidPositionClaimsMissingMail(row, local: try world.local(), server: world.uids)
        #expect(claim == nil, "\(claim ?? "")")

        // The next call asks it again.
        let before = world.server.recordedCommands().count
        #expect(await Self.callEnds(world), "the second call did not end")
        let againTries = Self.fetches(world.server.recordedCommands().dropFirst(before)).filter { $0.contains(uid) }.count
        #expect(againTries >= 1, "the next call did not fetch the failing UID again")
        #expect(!(try world.row()).backfillComplete)

        // Once the FETCH answers, the folder completes.
        world.server.stopFailingCommands(containing: fragment)
        #expect(await Self.callEnds(world))
        #expect(try world.row().backfillComplete, "the folder did not complete once the FETCH answered")
        let missing = Set(world.uids).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
    }

    // MARK: - A FETCH that times out

    /// Two UIDs in one range of two: a FETCH timeout splits it into two
    /// one-UID ranges, the upper first. Small on purpose: every timeout costs
    /// the client's full FETCH deadline.
    private static let timeoutUIDs = [1, 2]
    /// The highest of `timeoutUIDs`: the walk's start cursor, and the UID that
    /// keeps timing out (the upper half is asked first).
    private static let timeoutTop = 2

    /// Hold the answer to `count` FETCHes naming `uid` past the client's
    /// deadline, so the client's own command timeout (`IMAPError.timeout`)
    /// ends each one: the first is the whole range's FETCH (its set written
    /// `low:high` or `low,high`; both are held), the rest name `uid` alone.
    private static func holdFetches(of uid: Int, count: Int, on server: FakeIMAPServer) {
        let hold = fetchTimeoutSeconds * 2
        let (low, high) = (timeoutUIDs.min() ?? uid, timeoutUIDs.max() ?? uid)
        for fragment in ["FETCH \(low):\(high) ", "FETCH \(low),\(high) "] {
            server.stallNextCommandWatchingClient(containing: fragment, seconds: hold)
        }
        for _ in 1..<count {
            server.stallNextCommandWatchingClient(containing: "FETCH \(uid) ", seconds: hold)
        }
    }

    @Test("A range whose FETCH always times out shrinks to its one UID, which is left pending; the rest loads")
    func timedOutFetchShrinksToOneUID() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let uids = Self.timeoutUIDs
        let world = try await Self.makeWorld(
            accountId: "fetch-timeout", pool: pool, uids: uids, startCursor: Self.timeoutTop)
        defer { Self.tearDown(world) }
        let failing = Self.timeoutTop
        // Halving the range of two to one UID: two FETCHes name the failing UID.
        let steps = Int(log2(Double(uids.count)).rounded(.up)) + 1
        Self.holdFetches(of: failing, count: steps, on: world.server)

        #expect(await Self.callEnds(world, bound: Double(steps) * Self.fetchTimeoutSeconds + Self.spinBoundSeconds),
                "the call did not end: the walk kept retrying the range")
        let tries = Self.fetches(world.server.recordedCommands()[...]).filter { $0.contains(failing) }.count
        #expect(tries == steps, "the failing UID was fetched \(tries) times; halving needs \(steps)")
        #expect(try world.local() == Set(uids.filter { $0 != failing }), "the UID that did not time out did not load")
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a message that never loaded")
        #expect(row.backfillUidCursor == failing,
                "only the failing UID should stay pending: cursor \(String(describing: row.backfillUidCursor)), UID \(failing)")
    }

    @Test("A range whose FETCH times out once loads when retried smaller")
    func fetchTimedOutOnceLoadsSmaller() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let uids = Self.timeoutUIDs
        let world = try await Self.makeWorld(
            accountId: "fetch-timeout-once", pool: pool, uids: uids, startCursor: Self.timeoutTop)
        defer { Self.tearDown(world) }
        Self.holdFetches(of: Self.timeoutTop, count: 1, on: world.server)

        #expect(await Self.callEnds(world, bound: Self.fetchTimeoutSeconds + Self.spinBoundSeconds))
        let rangeFetches = Self.fetches(world.server.recordedCommands()[...]).filter { $0 == Set(uids) }.count
        #expect(rangeFetches == 1, "precondition: the range's FETCH was sent once and timed out (sent \(rangeFetches) times)")
        #expect(try world.row().backfillComplete, "the folder did not complete after one timeout")
        let missing = Set(uids).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
    }

    // MARK: - Several refused ranges, and no work reported for none done

    @Test("With two refused ranges, the cursor stays above the higher one; a call with nothing new reports no work")
    func twoRefusedRangesAndAnIdleCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let world = try await Self.makeWorld(accountId: "two-refused", pool: pool)
        defer { Self.tearDown(world) }
        let high = Self.range(1, chunk: world.chunk), low = Self.range(3, chunk: world.chunk)
        for r in [high, low] {
            world.server.failEveryCommand(containing: "UID \(r.lowerBound):\(r.upperBound)", message: Self.refusalText)
        }
        let first = await Self.walkResult(world)
        #expect(first == true, "the first call did work (it loaded the healthy ranges)")
        let outside = world.uids.filter { !high.contains($0) && !low.contains($0) }
        let missing = Set(outside).subtracting(try world.local())
        #expect(missing.isEmpty, "UIDs \(missing.sorted()) outside the refused ranges did not load")
        let row = try world.row()
        #expect(!row.backfillComplete)
        #expect((row.backfillUidCursor ?? 0) >= high.upperBound,
                "the cursor \(String(describing: row.backfillUidCursor)) is below the higher refused range")

        // Nothing new: the same ranges are refused, everything else is stored.
        let second = await Self.walkResult(world)
        #expect(second == false, "a call that loaded nothing and kept the cursor reported work")
    }

    // MARK: - A FETCH that is too large

    @Test("A range whose FETCH is too large is split; the half that loads loads, its one-UID rest is left pending and loads later")
    func payloadTooLargeSplitsAndLeavesOneUID() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let world = try await Self.makeWorld(accountId: "payload", pool: pool)
        defer { Self.tearDown(world) }
        // The lowest range holds two UIDs, in different halves of it.
        let lowest = Self.range(Self.rangeCount - 1, chunk: world.chunk)
        let inRange = world.uids.filter { lowest.contains($0) }.sorted()
        try #require(inRange.count == 2)
        let (kept, tooLarge) = (inRange[0], inRange[1])
        let message = "PayloadTooLargeError from the fixture"
        world.server.failEveryCommand(containing: ",\(tooLarge) ", message: message)
        world.server.failEveryCommand(containing: "FETCH \(tooLarge) ", message: message)

        #expect(await Self.callEnds(world), "the call did not end")
        #expect(try world.local().contains(kept), "the half without the large message did not load")
        #expect(!(try world.local()).contains(tooLarge), "precondition: the large message did not load")
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a message that never loaded (confirm-and-skip)")
        #expect(row.backfillUidCursor == tooLarge, "cursor \(String(describing: row.backfillUidCursor)), expected \(tooLarge)")

        world.server.stopFailingCommands(containing: ",\(tooLarge) ")
        world.server.stopFailingCommands(containing: "FETCH \(tooLarge) ")
        #expect(await Self.callEnds(world))
        #expect(try world.row().backfillComplete, "the folder did not complete once the message loaded")
        #expect(try world.local().contains(tooLarge))
    }

    // MARK: - Stored headers below a pending range

    /// A range left pending holds the cursor above it, so every later call
    /// walks again each range below it. Those ranges' messages are stored:
    /// their headers must not be downloaded again. Inbox and Sent, and with
    /// the old cc/bcc fill key on and off (the key must not matter).
    @Test("Stored headers below a pending range are not fetched again; a new message there is the only one fetched",
          arguments: [FolderRole.inbox, FolderRole.sent], [true, false])
    func storedHeadersAreNotFetchedAgainBelowAPendingRange(_ role: FolderRole, _ ccBccFlag: Bool) async throws {
        let ccBccKey = "ccBccBackfillDone"
        let saved = UserDefaults.standard.object(forKey: ccBccKey)
        defer { UserDefaults.standard.set(saved, forKey: ccBccKey) }
        UserDefaults.standard.set(ccBccFlag, forKey: ccBccKey)
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let world = try await Self.makeWorld(accountId: "stored-below-\(role.rawValue)-\(ccBccFlag)", pool: pool, role: role)
        defer { Self.tearDown(world) }
        let refused = Self.range(0, chunk: world.chunk)
        world.server.failEveryCommand(
            containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: Self.refusalText)

        #expect(await Self.callEnds(world))
        let below = Set(world.uids.filter { !refused.contains($0) })
        let loaded = try world.local()
        #expect(loaded == below, "precondition: the ranges below the refused one loaded (\(loaded.sorted()))")
        #expect(!(try world.row()).backfillComplete, "precondition: the refused range is pending")

        let mark = world.server.recordedCommands().count
        #expect(await Self.callEnds(world))
        #expect(await Self.callEnds(world))
        let refetched = Self.fetches(world.server.recordedCommands().dropFirst(mark)).reduce(Set<Int>()) { $0.union($1) }
        #expect(refetched.isEmpty, "stored headers were downloaded again: \(refetched.sorted())")
        #expect(try world.local() == loaded)

        // A new message inside a lower range is the only one fetched.
        let lower = Self.range(Self.rangeCount - 2, chunk: world.chunk)
        let newUID = try #require(lower.first { !world.uids.contains($0) })
        world.server.setMessages(world.server.messages(in: world.path) + [Self.message(uid: newUID)], in: world.path)
        let mark2 = world.server.recordedCommands().count
        #expect(await Self.callEnds(world))
        let fetchedNow = Self.fetches(world.server.recordedCommands().dropFirst(mark2)).reduce(Set<Int>()) { $0.union($1) }
        #expect(fetchedNow == [newUID], "fetched \(fetchedNow.sorted()), expected only the new UID \(newUID)")
        #expect(try world.local() == loaded.union([newUID]))
    }

    // MARK: - The stored-UID read fails

    /// The read of which SEARCHed UIDs the folder stores (before the FETCH)
    /// fails for the whole call: nothing is FETCHed or confirmed, the folder
    /// does not complete, the walk's position claims no missing mail, and the
    /// next call loads everything. (Denying only the first read let another
    /// worker reload the failed range in the same call.)
    @Test("A failed stored-UID read leaves its range unfetched and pending; the next call loads it")
    func storedUIDReadFailureLeavesTheRangePending() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            guard db.configuration.readonly, let conn = db.sqliteConnection else { return }
            sqlite3_set_authorizer(conn, { _, action, table, column, _, _ in
                guard action == SQLITE_READ, let table, let column,
                      String(cString: table) == "messageHeader", String(cString: column) == "messageId"
                else { return SQLITE_OK }
                return storedUIDReadFault.withLock { state in
                    guard state.armed else { return SQLITE_OK }
                    state.refused += 1
                    return SQLITE_DENY
                }
            }, nil)
        }
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { storedUIDReadFault.withLock { $0 = (false, 0) } }
        let world = try await Self.makeWorld(accountId: "stored-read-fails", pool: pool)
        defer { Self.tearDown(world) }
        storedUIDReadFault.withLock { $0 = (true, 0) }

        #expect(await Self.callEnds(world))
        storedUIDReadFault.withLock { $0.armed = false }
        #expect(storedUIDReadFault.withLock { $0.refused } >= 1, "precondition: the stored-UID read failed")
        let fetched = Self.fetches(world.server.recordedCommands()[...]).reduce(Set<Int>()) { $0.union($1) }
        #expect(fetched.isEmpty, "a range whose stored-UID read failed was FETCHed: \(fetched.sorted())")
        let row = try world.row()
        #expect(!row.backfillComplete, "the folder completed over a range that never loaded")
        let claim = F.uidPositionClaimsMissingMail(row, local: try world.local(), server: world.uids)
        #expect(claim == nil, "\(claim ?? "")")

        #expect(await Self.callEnds(world))
        #expect(try world.local() == Set(world.uids), "the next call did not load the range")
        #expect(try world.row().backfillComplete)
    }
}

