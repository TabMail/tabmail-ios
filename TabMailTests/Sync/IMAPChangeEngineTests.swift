/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The engine around the IMAP change reader (ADR-IOS-111, IMAP half), driven
/// through the engine's own entry points against `FakeIMAPServer`, with the work
/// queue the ADR-IOS-051 count walk runs on registered: an untracked folder is
/// re-listed and its ghosts walked away; an armed turnover is re-driven at the
/// pass start; a provider that cannot say which ids exist deletes nothing; a
/// tracked folder gets no count walk and no self-heal. Each case asserts the
/// stored rows (or, for a skip, that the folder was never touched on the wire).
@Suite("IMAP change engine", .serialized, .processGlobalState)
struct IMAPChangeEngineTests {

    static let epoch = 61_200
    static let path = "INBOX"
    static let qresync = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
    static let condstoreOnly = FakeIMAPServer.defaultCapabilities + ["CONDSTORE"]

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let account: Account
        var folderId: String { "\(account.id):\(IMAPChangeEngineTests.path)" }

        func uids() throws -> Set<String> {
            let folderId = folderId
            return Set(try pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            })
        }

        func folder() throws -> Folder {
            let folderId = folderId
            return try #require(try pool.read { db in try Folder.fetchOne(db, key: folderId) })
        }

        /// Commands the server received from `start` on that name the folder.
        func commandsNamingFolder(since start: Int) -> [String] {
            server.recordedCommands().dropFirst(start).filter {
                let upper = $0.uppercased()
                return (upper.contains("SELECT") || upper.contains("EXAMINE") || upper.contains("UID SEARCH"))
                    && upper.contains(IMAPChangeEngineTests.path)
            }
        }
    }

    static func withWorld(
        _ name: String, capabilities: [String], serverUIDs: [Int], localUIDs: [Int],
        serverEpoch: Int = IMAPChangeEngineTests.epoch, storedEpoch: Int? = IMAPChangeEngineTests.epoch,
        tracked: Bool = false,
        _ body: (World) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: [path: serverUIDs.map(IMAPChangeReaderTests.message)])
        server.setUidValidity(serverEpoch, for: path)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let account = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: name, path: path, role: .inbox, pool: pool,
            totalCount: localUIDs.count, lastKnownUidNext: (localUIDs.max() ?? 0) + 1, lastKnownUidValidity: storedEpoch)
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: path, uids: localUIDs, pool: pool)
        if tracked {
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            let encodedState = state.encoded
            let cursor = IMAPChangeCursor(uidValidity: UInt32(serverEpoch), highestModSeq: 1, uidNext: UInt32((serverUIDs.max() ?? 0) + 1)).encoded
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, changeState = ? WHERE id = ?",
                               arguments: [cursor, encodedState, "\(name):\(path)"])
            }
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: name, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        try await body(World(server: server, provider: provider, engine: engine, pool: pool, account: account))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - Untracked folders through the engine

    @Test("Untracked, changed: the change pass re-lists the folder, stores its counters, and walks a ghost away")
    func untrackedChangedFolderIsRelisted() async throws {
        try await Self.withWorld("eng-untracked", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3, 4, 5], localUIDs: [1, 2, 3, 4, 5, 6]) { w in
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            #expect(try w.uids() == ["1", "2", "3", "4", "5"], "the ghost 6 is gone, nothing else")
            let folder = try w.folder()
            #expect(folder.totalCount == 5)
            #expect(folder.lastKnownUidNext == 6)
            #expect(folder.changeCursor == nil)
        }
    }

    @Test("Untracked, unchanged: the change pass reads STATUS only and lists nothing")
    func untrackedUnchangedFolderIsNotListed() async throws {
        try await Self.withWorld("eng-quiet", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { w in
            let start = w.server.recordedCommands().count
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let fetches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("FETCH") }
            #expect(fetches.isEmpty, "an unchanged untracked folder is not listed: \(Array(fetches))")
            #expect(try w.uids() == ["1", "2", "3"])
        }
    }

    // MARK: - Turnover re-drive

    @Test("An armed turnover is re-driven at the start of the change pass: old-epoch rows go, the new epoch is stored, the arm is cleared")
    func armedTurnoverIsRedriven() async throws {
        try await Self.withWorld("eng-redrive", capabilities: Self.condstoreOnly,
                                 serverUIDs: [201, 202], localUIDs: [1, 2, 3],
                                 serverEpoch: Self.epoch + 1, storedEpoch: Self.epoch) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), folderId])
            }
            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performChangePass(account: w.account, provider: w.provider)
            }
            let folder = try w.folder()
            #expect(folder.uidValidityResetPendingAt == nil, "the re-drive completed the reaction")
            #expect(folder.lastKnownUidValidity == Self.epoch + 1)
            #expect(try w.uids().isDisjoint(with: ["1", "2", "3"]), "no old-epoch row survives")
        }
    }

    // MARK: - The count walk's presence answer

    @Test("A provider that cannot say which ids exist: the count walk deletes nothing")
    func noPresenceAnswerDeletesNothing() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let name = "eng-nopresence"
        _ = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: name, path: Self.path, role: .inbox, pool: pool,
                                                totalCount: 3, lastKnownUidNext: 4, lastKnownUidValidity: Self.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: Self.path, uids: [1, 2, 3], pool: pool)
        let mock = MockEmailProvider()
        let engine = SyncEngine()
        await engine.register(accountId: name, provider: mock, workQueue: ProviderWorkQueue(provider: mock, maxConcurrency: 1))
        let folder = try #require(try FolderEpochTestFixture.readFolder(accountId: name, path: Self.path, pool: pool))
        await engine.reconcileExternallyDeletedMessages(folder: folder, provider: mock, expectedGhosts: 3)
        #expect(try FolderEpochTestFixture.headerCount(accountId: name, path: Self.path, pool: pool) == 3,
                "no answer is never read as 'gone'")
    }

    // MARK: - Tracked folders skip the timers

    @Test("The full sync's count walk skips a tracked folder; the same folder untracked is walked")
    func fullSyncCountWalkSkipsTrackedFolder() async throws {
        for tracked in [true, false] {
            try await Self.withWorld("eng-walk-\(tracked)", capabilities: Self.qresync,
                                     serverUIDs: [1, 2, 3, 4, 5], localUIDs: [1, 2, 3, 4, 5, 6], tracked: tracked) { w in
                _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
                let held = try w.uids()
                if tracked {
                    #expect(held.contains("6"), "a tracked folder's removals arrive through the change read, not the walk")
                } else {
                    #expect(!held.contains("6"), "control: the untracked folder's ghost is walked away")
                }
            }
        }
    }

    @Test("Self-heal skips a tracked folder (no command names it); the same folder untracked is healed")
    func selfHealSkipsTrackedFolder() async throws {
        for tracked in [true, false] {
            try await Self.withWorld("eng-heal-\(tracked)", capabilities: Self.qresync,
                                     serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3], tracked: tracked) { w in
                UserDefaults.standard.removeObject(forKey: "selfHeal_lastRun_\(w.account.id)")
                defer { UserDefaults.standard.removeObject(forKey: "selfHeal_lastRun_\(w.account.id)") }
                let start = w.server.recordedCommands().count
                await w.engine.selfHealRecentMessages(account: w.account)
                let touched = w.commandsNamingFolder(since: start)
                if tracked {
                    #expect(touched.isEmpty, "the tracked folder was healed: \(touched)")
                } else {
                    #expect(!touched.isEmpty, "control: the untracked folder is healed")
                }
            }
        }
    }
}
