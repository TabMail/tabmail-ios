/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The IMAP UID walk and a range the server refuses:
/// - a range whose SEARCH is refused is asked at most once per worker in a
///   walk, the walk moves on and loads every other range, the range is never
///   claimed (the cursor stays above it, the folder does not complete), and
///   the next call asks it again;
/// - a range whose FETCH times out is retried smaller, never at its own size,
///   down to one UID, which is then left for the next call;
/// - while the cc/bcc fill is done, a walk does not FETCH a UID the folder
///   already stores under the walk's epoch; while it is due, it does (the
///   FETCH fills the stored rows' cc/bcc), and the choice is read once per walk.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, writes
/// the `ccBccBackfillDone` default, binds a listening socket via `FakeIMAPServer`.
@Suite("Backfill walk — a refused range is left for the next call, and stored UIDs are not fetched again", .serialized, .processGlobalState)
struct BackfillRefusedRangeTests {
    private typealias F = BackfillPageWalkFixture

    private static let epoch = 718_204
    /// Ranges the walk covers below its starting cursor.
    private static let rangeCount = 6
    /// The range (counted from the top, 0-based) the server refuses.
    private static let refusedRange = 2
    /// How long a call may take before the test calls it a spin.
    private static let spinBoundSeconds: TimeInterval = 15
    private static let ccFlagKey = "ccBccBackfillDone"
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
        func local() throws -> Set<Int> {
            Set(try F.messageIds(account.id, path, pool: pool).compactMap { Int($0) })
        }
    }

    private static func makeWorld(accountId: String, pool: DatabasePool) async throws -> World {
        let path = "Receipts"
        let engine = SyncEngine()
        let chunk = await engine.getBackfillProfile().backfillChunkSize
        let uids = serverUIDs(chunk: chunk)
        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: ["INBOX": [], path: uids.map(message(uid:))])
        server.setUidValidity(epoch, for: path)
        server.honorSearchUIDSetCriterion()
        try server.start()
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            var folder = Folder(name: path, path: path, role: .custom, accountId: accountId)
            folder.isFavorite = false
            folder.backfillComplete = false
            folder.backfillUidCursor = rangeCount * chunk
            folder.lastKnownUidValidity = epoch
            try folder.insert(db)
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

    /// Run one backfill call; false when it had not ended by `spinBoundSeconds`
    /// (it is then cancelled, so the test can report the spin and go on).
    private static func callEnds(_ world: World) async -> Bool {
        let engine = world.engine, account = world.account
        let call = Task { _ = await engine.runBackfill(account: account, deadline: F.deadline()) }
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await call.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(spinBoundSeconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !ended { call.cancel(); await call.value }
        return ended
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

    private static func withCcFlag<T>(_ value: Bool, _ body: () async throws -> T) async rethrows -> T {
        let saved = UserDefaults.standard.object(forKey: ccFlagKey)
        defer { UserDefaults.standard.set(saved, forKey: ccFlagKey) }
        UserDefaults.standard.set(value, forKey: ccFlagKey)
        return try await body()
    }

    // MARK: - A refused SEARCH

    @Test("A range whose SEARCH is always refused is left for the next call; every other range loads")
    func refusedSearchRangeIsLeftForTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "refused-search", pool: pool)
            defer { Self.tearDown(world) }
            let refused = Self.range(Self.refusedRange, chunk: world.chunk)
            world.server.failEveryCommand(
                containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: "SEARCH refused by the fixture")

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
    }

    @Test("A range whose SEARCH is refused once loads on the next call")
    func searchRefusedOnceLoadsOnTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "refused-search-once", pool: pool)
            defer { Self.tearDown(world) }
            let refused = Self.range(Self.refusedRange, chunk: world.chunk)
            world.server.failNextCommand(
                containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: "SEARCH refused by the fixture")

            #expect(await Self.callEnds(world))
            #expect(!(try world.row()).backfillComplete, "precondition: the first call left the refused range")
            #expect(await Self.callEnds(world))
            #expect(try world.row().backfillComplete, "the folder did not complete once the range answered")
            let missing = Set(world.uids).subtracting(try world.local())
            #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
        }
    }

    // MARK: - A FETCH that times out

    @Test("A range whose FETCH always times out shrinks to its one UID, which is left pending; the rest loads")
    func timedOutFetchShrinksToOneUID() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "fetch-timeout", pool: pool)
            defer { Self.tearDown(world) }
            let failing = Self.range(Self.refusedRange, chunk: world.chunk).lowerBound + world.chunk / 2
            world.server.failEveryCommand(containing: "UID FETCH \(failing) ", message: "operation timed out")

            #expect(await Self.callEnds(world), "the call did not end: the walk kept retrying the range")
            // Halving from the chunk to one UID takes log2(chunk) steps; each
            // range in between is asked at most once per worker.
            let workers = await world.imap.poolMaxConnections()
            let steps = Int(log2(Double(world.chunk)).rounded(.up)) + 1
            let tries = Self.fetches(world.server.recordedCommands()[...]).filter { $0.contains(failing) }.count
            #expect(tries >= steps && tries <= steps * workers,
                    "the failing UID was fetched \(tries) times; halving needs \(steps)")
            let missing = Set(world.uids.filter { $0 != failing }).subtracting(try world.local())
            #expect(missing.isEmpty, "UIDs \(missing.sorted()) did not load")
            let row = try world.row()
            #expect(!row.backfillComplete, "the folder completed over a message that never loaded")
            #expect(row.backfillUidCursor == failing,
                    "only the failing UID should stay pending: cursor \(String(describing: row.backfillUidCursor)), UID \(failing)")
        }
    }

    @Test("A range whose FETCH times out once loads when retried smaller")
    func fetchTimedOutOnceLoadsSmaller() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "fetch-timeout-once", pool: pool)
            defer { Self.tearDown(world) }
            let failing = Self.range(Self.refusedRange, chunk: world.chunk).lowerBound + world.chunk / 2
            world.server.failNextCommand(containing: "UID FETCH \(failing) ", message: "operation timed out")

            #expect(await Self.callEnds(world))
            #expect(try world.row().backfillComplete, "the folder did not complete after one timeout")
            let missing = Set(world.uids).subtracting(try world.local())
            #expect(missing.isEmpty, "UIDs \(missing.sorted()) never loaded")
        }
    }

    // MARK: - Stored UIDs

    /// A first call with the refused range loads the ranges below it; returns
    /// the UIDs below the refused range.
    private static func firstCallBelowRefusedRange(_ world: World) async throws -> [Int] {
        let refused = range(refusedRange, chunk: world.chunk)
        world.server.failEveryCommand(
            containing: "UID \(refused.lowerBound):\(refused.upperBound)", message: "SEARCH refused by the fixture")
        #expect(await callEnds(world))
        let below = world.uids.filter { $0 < refused.lowerBound }
        #expect(Set(below).isSubset(of: try world.local()), "precondition: the ranges below loaded")
        return below
    }

    @Test("While the cc/bcc fill is done, the next call fetches no UID it already stores; a missing one is fetched alone")
    func nextCallFetchesOnlyMissingUIDs() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "stored-uids", pool: pool)
            defer { Self.tearDown(world) }
            let below = try await Self.firstCallBelowRefusedRange(world)

            // Second call: everything below is stored, so nothing is fetched.
            var before = world.server.recordedCommands().count
            #expect(await Self.callEnds(world))
            let fetched = Self.fetches(world.server.recordedCommands().dropFirst(before)).reduce(into: Set<Int>()) { $0.formUnion($1) }
            #expect(fetched.isEmpty, "the call fetched stored UIDs \(fetched.sorted())")

            // Control: one row goes missing; the next call fetches exactly it.
            let gone = try #require(below.first)
            let folderId = world.folderId
            _ = try await pool.write { db in
                try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "\(gone)").deleteAll(db)
            }
            before = world.server.recordedCommands().count
            #expect(await Self.callEnds(world))
            let refetched = Self.fetches(world.server.recordedCommands().dropFirst(before)).reduce(into: Set<Int>()) { $0.formUnion($1) }
            #expect(refetched == [gone], "the call fetched \(refetched.sorted()); only \(gone) was missing")
            #expect(try world.local().contains(gone))
        }
    }

    @Test("While the cc/bcc fill is due, the walk fetches stored rows and fills their cc in the database and the search index")
    func ccFillStillFetchesStoredRows() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(false) {
            let world = try await Self.makeWorld(accountId: "cc-fill", pool: pool)
            defer { Self.tearDown(world) }
            // Stored rows with no cc, as an older build left them, indexed with none.
            let stored = world.uids
            try FolderEpochTestFixture.insertHeaders(accountId: world.account.id, path: world.path, uids: stored, pool: pool)
            let keys = stored.map { ContentKey(rawValue: "\(world.folderId):\($0)") }
            let records = stored.map { uid in
                FTSHeaderRecord(contentKey: ContentKey(rawValue: "\(world.folderId):\(uid)"),
                                headerId: "\(world.folderId):\(uid)", messageId: "\(uid)", subject: "cc fill \(uid)",
                                from: "sender@example.com", to: "recipient@example.com", cc: "", bcc: "",
                                dateMs: Int64(Date().timeIntervalSince1970 * 1000))
            }
            defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: keys) } }
            _ = try await SearchIndex.shared.indexHeaders(records)

            #expect(await Self.callEnds(world))
            let ccs = try await pool.read { db in
                try MessageHeader.filter(Column("folderId") == world.folderId).fetchAll(db)
            }.reduce(into: [Int: String]()) { $0[Int($1.messageId) ?? 0] = $1.cc }
            for uid in stored {
                #expect((ccs[uid] ?? "").contains("copied-\(uid)@example.com"), "UID \(uid): cc not filled in the database")
                let indexed = try await SearchIndex.shared.testCc(ContentKey(rawValue: "\(world.folderId):\(uid)"))
                #expect((indexed ?? "").contains("copied-\(uid)@example.com"), "UID \(uid): cc not filled in the search index")
            }
        }
    }

    @Test("The stored-UID choice is read once per walk: the flag flipping mid-walk does not change it")
    func storedUIDChoiceIsSnapshotAtWalkStart() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.withCcFlag(true) {
            let world = try await Self.makeWorld(accountId: "stored-uids-snapshot", pool: pool)
            defer { Self.tearDown(world) }
            let below = try await Self.firstCallBelowRefusedRange(world)

            // One row below goes missing, so the second walk fetches it; the
            // flag flips to "due" just before that fetch lands, mid-walk.
            let gone = try #require(below.last)
            let folderId = world.folderId
            _ = try await pool.write { db in
                try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "\(gone)").deleteAll(db)
            }
            let key = Self.ccFlagKey
            SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
                $0[.beforeInsertingFetchedChunk(folderId: folderId)] = { UserDefaults.standard.set(false, forKey: key) }
            }
            defer { _ = SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeValue(forKey: .beforeInsertingFetchedChunk(folderId: folderId)) } }
            let before = world.server.recordedCommands().count
            #expect(await Self.callEnds(world))
            let fetched = Self.fetches(world.server.recordedCommands().dropFirst(before)).reduce(into: Set<Int>()) { $0.formUnion($1) }
            #expect(fetched == [gone], "the walk fetched \(fetched.sorted()); the flag flipped mid-walk changed its choice")
        }
    }
}
