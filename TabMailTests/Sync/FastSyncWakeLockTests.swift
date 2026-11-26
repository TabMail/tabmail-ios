/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Fast Sync's wake lock, driven through its own poll (`FastSyncView.pollKeepAwakeInputs`,
/// real folder rows through `SyncEngine.isFolderWalkComplete`, the real body queues)
/// and decision (`FastSyncView.holdAwake(accounts:…)`). The published progress
/// entries are varied independently: the decision follows the folder rows, never
/// a progress entry (#755).
@Suite("Fast Sync wake lock", .serialized, .processGlobalState)
@MainActor
struct FastSyncWakeLockTests {

    enum Progress: String, CaseIterable, Sendable {
        /// No entry published (a provider not registered yet, or before the first update).
        case missing
        /// An entry published before the walk finished (stale: headers not done).
        case stale
        /// An entry that looks complete.
        case complete
    }

    static func publish(_ progress: Progress, for accounts: [Account]) {
        var map: [String: BackfillProgress] = [:]
        if progress != .missing {
            for account in accounts {
                map[account.id] = BackfillProgress(
                    accountId: account.id, email: account.emailAddress, startedAt: Date(), isPaused: false,
                    headersDone: progress == .complete, totalEmails: 10, ftsIndexed: 10)
            }
        }
        AccountManagerState.shared.backfillProgressByAccount = map
    }

    static func setWalkComplete(_ complete: Bool, accountId: String, path: String, pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE folder SET backfillComplete = ? WHERE id = ?",
                           arguments: [complete, "\(accountId):\(path)"])
        }
    }

    /// Poll then decide, as the screen does.
    static func holdsAwake(_ accounts: [Account]) async -> Bool {
        // Items an earlier test left in the shared queues are not this test's.
        await ActiveBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.emptyForTesting()
        let poll = await FastSyncView.pollKeepAwakeInputs(accounts: accounts, engine: SyncEngine())
        #expect(poll.activeBodyIdle && poll.backfillBodyIdle, "precondition: both body queues are idle")
        #expect(!poll.walkRunning, "precondition: no header walk runs")
        return FastSyncView.holdAwake(accounts: accounts, poll: poll)
    }

    @Test("Every real folder walked and both queues idle: the lock releases whether progress is missing, stale or complete",
          arguments: Progress.allCases)
    func releasesOnTheFolderRows(_ progress: Progress) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AccountManagerState.shared.backfillProgressByAccount = [:]
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        var accounts: [Account] = []
        for id in ["wake-a", "wake-b"] {
            accounts.append(try FolderEpochTestFixture.makeAccount(id: "\(id)-\(progress.rawValue)", provider: .imap, pool: pool))
        }
        for account in accounts {
            for (path, role) in [("INBOX", FolderRole.inbox), ("Archive", .archive)] {
                try FolderEpochTestFixture.insertFolder(accountId: account.id, path: path, role: role, pool: pool)
                try Self.setWalkComplete(true, accountId: account.id, path: path, pool: pool)
            }
        }
        Self.publish(progress, for: accounts)
        #expect(await !Self.holdsAwake(accounts), "the folder rows say the walk is done: the screen may sleep")
    }

    enum Unfinished: String, CaseIterable, Sendable {
        /// One folder of one account has not finished its walk.
        case folderNotWalked
        /// One account has no folder discovered yet.
        case undiscovered
    }

    @Test("One account unfinished or undiscovered keeps the screen awake, even when every progress entry looks complete",
          arguments: Unfinished.allCases)
    func heldByAnUnfinishedAccount(_ unfinished: Unfinished) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AccountManagerState.shared.backfillProgressByAccount = [:]
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let done = try FolderEpochTestFixture.makeAccount(id: "wake-done-\(unfinished.rawValue)", provider: .imap, pool: pool)
        let other = try FolderEpochTestFixture.makeAccount(id: "wake-other-\(unfinished.rawValue)", provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: done.id, path: "INBOX", role: .inbox, pool: pool)
        try Self.setWalkComplete(true, accountId: done.id, path: "INBOX", pool: pool)
        if unfinished == .folderNotWalked {
            try FolderEpochTestFixture.insertFolder(accountId: other.id, path: "INBOX", role: .inbox, pool: pool)
            try Self.setWalkComplete(true, accountId: other.id, path: "INBOX", pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: other.id, path: "Archive", role: .archive, pool: pool)
            try Self.setWalkComplete(false, accountId: other.id, path: "Archive", pool: pool)
        }
        Self.publish(.complete, for: [done, other])
        // The download gate is open, so the unfinished walk can move (a held walk
        // releases the lock, #1098; pinned in FastSyncHeldWorkTests).
        SyncEngine.backfillPowerStateForTesting.withLock {
            $0 = (fastSync: false, lowPowerMode: false, onPower: true, batteryLevel: 1)
        }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil } }
        await DownloadGateHarness.withNetwork(expensive: false) {
            #expect(await Self.holdsAwake([done, other]), "an unfinished or undiscovered account keeps the screen awake")
        }
    }
}
