/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A write chunk of the IMAP backfill insert (`SyncEngine.insertBackfillBatch`,
/// the premised overload) that fails is reported to both of its callers, and
/// neither moves on past the messages it did not write:
/// - the IMAP UID walk keeps its cursor above them, so the walk's position
///   never claims them, and the next call loads them;
/// - self-heal leaves its pass open, so the next sync's self-heal loads them
///   rather than leaving them missing for the rest of the hour.
///
/// The failure is a real one inside the insert's transaction: a test-only
/// trigger aborts every insert of one UID's row, which rolls back the whole
/// write chunk holding it, as a full disk or a suspended database would.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, changes
/// the account's self-heal stamp in `UserDefaults`, and binds a listening
/// socket via `FakeIMAPServer`.
@Suite("Backfill insert — a failed write chunk keeps the IMAP walk's cursor and self-heal's pass open", .serialized, .processGlobalState)
struct BackfillInsertFailureTests {
    private typealias F = BackfillPageWalkFixture

    /// The UIDVALIDITY the server reports and the folder is stamped with.
    private static let epoch = 975_603
    /// The UIDs on the server: two below the walk's cursor, one above it.
    private static let serverUIDs = [3, 7, 20]
    /// Where the walk resumes: UID 20 above it is loaded, 3 and 7 below it are not.
    private static let resumedCursor = 10
    /// The UID whose row's insert fails; UID 3 shares its write chunk.
    private static let failingUID = 7
    /// Backfill calls the convergence check allows.
    private static let convergenceCalls = 3
    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`, as in `BackfillOnlyFolderEpochTests`.
    private static let capabilities = ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func message(uid: Int) -> FakeIMAPServer.Message {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date().addingTimeInterval(-Double(uid) * 3_600))
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: insert failure \(uid)\r
            Date: \(date)\r
            Message-ID: <insert-failure-\(uid)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            insert failure fixture body.\r

            """)
    }

    /// An IMAP account with one folder at `path`, stamped with the server's
    /// epoch, holding the rows of `localUIDs`, on the shared test database, and
    /// a registered engine.
    private struct World {
        let pool: DatabasePool
        let account: Account
        let server: FakeIMAPServer
        let imap: IMAPProvider
        let engine: SyncEngine
        let path: String

        func row() throws -> Folder {
            try #require(try F.folder(account.id, path, pool: pool))
        }

        func local() throws -> Set<Int> {
            Set(try F.messageIds(account.id, path, pool: pool).compactMap { Int($0) })
        }
    }

    private static func makeWorld(
        accountId: String, path: String, role: FolderRole, cursor: Int?, pool: DatabasePool
    ) async throws -> World {
        let server = FakeIMAPServer(
            capabilities: capabilities,
            mailboxes: path == "INBOX"
                ? ["INBOX": serverUIDs.map(message(uid:))]
                : ["INBOX": [], path: serverUIDs.map(message(uid:))])
        server.setUidValidity(epoch, for: path)
        // Each walk range's SEARCH finds only the UIDs in that range, as on a real server.
        server.honorSearchUIDSetCriterion()
        try server.start()
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            var folder = Folder(name: path, path: path, role: role, accountId: accountId)
            folder.isFavorite = false
            folder.backfillComplete = false
            folder.backfillUidCursor = cursor
            folder.lastKnownUidValidity = epoch
            try folder.insert(db)
        }
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: path, uids: serverUIDs.filter { $0 > resumedCursor }, pool: pool)
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return World(pool: pool, account: account, server: server, imap: imap, engine: engine, path: path)
    }

    private static func tearDown(_ world: World) {
        let imap = world.imap
        Task { try? await imap.disconnect() }
        world.server.stop()
    }

    /// Make every insert of the row for `uid` fail inside its transaction.
    private static func failInserts(of uid: Int, pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_failInsert BEFORE INSERT ON messageHeader
                WHEN NEW.messageId = '\(uid)'
                BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
                """)
        }
    }

    private static func stopFailingInserts(pool: DatabasePool) throws {
        try pool.write { db in try db.execute(sql: "DROP TRIGGER test_failInsert") }
    }

    // MARK: - The IMAP UID walk

    @Test("A failed write chunk on the IMAP walk keeps the walk's cursor above it, and the next call loads the messages")
    func walkKeepsItsCursorOverAFailedChunk() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // Custom, not a favourite: ordinary sync never fetches it, so backfill
        // is its only path.
        let world = try await Self.makeWorld(
            accountId: "insert-failure-walk", path: "Receipts", role: .custom, cursor: Self.resumedCursor, pool: pool)
        defer { Self.tearDown(world) }
        try Self.failInserts(of: Self.failingUID, pool: pool)

        _ = await world.engine.runBackfill(account: world.account, deadline: F.deadline())

        let afterFailure = try world.row()
        let claim = F.uidPositionClaimsMissingMail(afterFailure, local: try world.local(), server: Self.serverUIDs)
        #expect(claim == nil, "after the call whose write chunk failed, \(claim ?? "")")
        #expect(!afterFailure.backfillComplete && afterFailure.backfillUidCursor == Self.resumedCursor,
                "the walk's position moved past the failed chunk: complete \(afterFailure.backfillComplete), cursor \(String(describing: afterFailure.backfillUidCursor))")
        #expect(!(try world.local()).contains(Self.failingUID), "precondition: the failing row did not land")

        try Self.stopFailingInserts(pool: pool)
        for _ in 0..<Self.convergenceCalls {
            if try world.row().backfillComplete { break }
            _ = await world.engine.runBackfill(account: world.account, deadline: F.deadline())
        }
        #expect(try world.row().backfillComplete, "the walk never completed once the write worked again")
        let missing = Set(Self.serverUIDs).subtracting(try world.local())
        #expect(missing.isEmpty, "backfill never loaded UIDs \(missing.sorted()) after the failed write")
    }

    // MARK: - Self-heal

    @Test("A failed write chunk in self-heal leaves the pass open, and the next sync's self-heal loads the messages")
    func selfHealKeepsItsPassOpenOverAFailedChunk() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let world = try await Self.makeWorld(
            accountId: "insert-failure-self-heal", path: "INBOX", role: .inbox, cursor: nil, pool: pool)
        defer { Self.tearDown(world) }
        let rateLimitKey = "selfHeal_lastRun_\(world.account.id)"
        let savedStamp = UserDefaults.standard.object(forKey: rateLimitKey)
        defer { UserDefaults.standard.set(savedStamp, forKey: rateLimitKey) }
        UserDefaults.standard.removeObject(forKey: rateLimitKey)
        try Self.failInserts(of: Self.failingUID, pool: pool)

        await world.engine.selfHealRecentMessages(account: world.account)
        #expect(!(try world.local()).contains(Self.failingUID), "precondition: the failing row did not land")

        try Self.stopFailingInserts(pool: pool)
        // The next sync's self-heal, with no hand on the hourly stamp.
        await world.engine.selfHealRecentMessages(account: world.account)

        let missing = Set(Self.serverUIDs).subtracting(try world.local())
        #expect(missing.isEmpty,
                "self-heal never loaded UIDs \(missing.sorted()) after its write failed; they stay missing until the next hourly pass")
    }

    /// The control: a self-heal pass whose writes all landed keeps its hourly
    /// stamp, so the next sync's self-heal does not run again.
    @Test("A self-heal pass whose writes all landed keeps its hourly stamp")
    func selfHealWithoutFailureKeepsItsStamp() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let world = try await Self.makeWorld(
            accountId: "insert-failure-self-heal-control", path: "INBOX", role: .inbox, cursor: nil, pool: pool)
        defer { Self.tearDown(world) }
        let rateLimitKey = "selfHeal_lastRun_\(world.account.id)"
        let savedStamp = UserDefaults.standard.object(forKey: rateLimitKey)
        defer { UserDefaults.standard.set(savedStamp, forKey: rateLimitKey) }
        UserDefaults.standard.removeObject(forKey: rateLimitKey)

        let before = Date().timeIntervalSince1970
        await world.engine.selfHealRecentMessages(account: world.account)

        #expect(Set(Self.serverUIDs).subtracting(try world.local()).isEmpty, "precondition: the pass loaded every message")
        #expect(UserDefaults.standard.double(forKey: rateLimitKey) >= before,
                "the pass's hourly stamp was not kept")
    }
}
