/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The inbox sync banner, driven through the REAL run entry points:
///
/// | Entry point                                   | Coverage            | Raises | Clears              |
/// |-----------------------------------------------|---------------------|--------|---------------------|
/// | `InboxViewModel.refreshSync` (unified inbox)  | full                | on a counted failure | on success; never when it failed |
/// | `InboxViewModel.refreshSync` (some accounts)  | partial             | on a counted failure | never               |
/// | `AccountManager.foregroundPollRun`            | full                | never  | when no account failed |
/// | `AccountManager.backgroundPollRun(nil)`       | full                | never  | when no account failed |
/// | `AccountManager.backgroundPollRun(email)`     | partial             | never  | never               |
///
/// "Failed" above means counted (`InboxErrorBanner.countsAsFailure`): for a poll,
/// an account marked sign-in-needed never counts. A refresh judges the one error
/// it sees (`AccountManagerState.finishSyncRun`).
///
/// Two accounts: A and B, each failing while set to, healthy otherwise. Both run
/// against `MockEmailProvider`s registered on `AccountManager.shared`.
@Suite("Inbox sync banner through the real run entry points", .serialized, .processGlobalState,
       .timeLimit(.minutes(2)))
@MainActor
struct SyncRunBannerEntryPointTests {

    private struct World {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let accountA: Account
        let accountB: Account
        let inboxA: Folder
        let inboxB: Folder
        let providerA: MockEmailProvider
        let providerB: MockEmailProvider

        /// Make account A fail every sync (connect and folder listing), or recover.
        func setFailing(_ failing: Bool) async {
            let error: Error? = failing ? NSError(domain: "com.example.test", code: 7) : nil
            await providerA.setConnectThrows(error)
            await providerA.setFetchMessagesThrows(error)
        }

        /// The same for account B.
        func setBFailing(_ failing: Bool) async {
            let error: Error? = failing ? NSError(domain: "com.example.test", code: 8) : nil
            await providerB.setConnectThrows(error)
            await providerB.setFetchMessagesThrows(error)
        }
    }

    private func withWorld(_ body: (World) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let suffix = UUID().uuidString.prefix(8)
        let accountA = try FolderEpochTestFixture.makeAccount(id: "banner-a-\(suffix)", provider: .gmail, pool: pool)
        let accountB = try FolderEpochTestFixture.makeAccount(id: "banner-b-\(suffix)", provider: .gmail, pool: pool)
        for account in [accountA, accountB] {
            try FolderEpochTestFixture.insertFolder(accountId: account.id, path: "INBOX", role: .inbox, pool: pool)
        }
        let inboxA = try #require(try FolderEpochTestFixture.readFolder(accountId: accountA.id, path: "INBOX", pool: pool))
        let inboxB = try #require(try FolderEpochTestFixture.readFolder(accountId: accountB.id, path: "INBOX", pool: pool))
        let providerA = MockEmailProvider()
        let providerB = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountA.id, provider: providerA)
        await AccountManager.shared.registerProviderForTesting(accountId: accountB.id, provider: providerB)

        let state = AccountManagerState.shared
        let saved = (state.syncErrorBanner, state.lastSyncCompletedAt, state.lastSyncFailed)
        state.syncErrorBanner = nil
        let world = World(pool: pool, dir: dir, previous: previous, accountA: accountA, accountB: accountB,
                          inboxA: inboxA, inboxB: inboxB, providerA: providerA, providerB: providerB)
        do {
            try await body(world)
        } catch {
            await tearDown(world, saved)
            throw error
        }
        await tearDown(world, saved)
    }

    private func tearDown(_ world: World, _ saved: (String?, Date?, Bool)) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: world.accountA.id)
        await AccountManager.shared.unregisterProviderForTesting(accountId: world.accountB.id)
        await AccountManager.shared.clearAuthFailed(world.accountA.id)
        await AccountManager.shared.clearAuthFailed(world.accountB.id)
        let state = AccountManagerState.shared
        state.syncErrorBanner = saved.0
        state.lastSyncCompletedAt = saved.1
        state.lastSyncFailed = saved.2
        InstalledTestDatabaseLifetime.finish(previous: world.previous, pool: world.pool, directory: world.dir)
    }

    private var banner: String? { AccountManagerState.shared.syncErrorBanner }

    /// A user-started refresh of the unified inbox where account A fails.
    private func raiseThroughRefresh(_ world: World) async {
        await world.setFailing(true)
        let vm = InboxViewModel(folders: [world.inboxA, world.inboxB])
        await vm.refreshSync()
    }

    // MARK: - The steady-banner sequence

    @Test("a refresh raises; ten background runs with A failing keep it; a full clean run clears it")
    func tenRunSequence() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage, "the unified-inbox refresh did not raise")

            for run in 1...10 {
                _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
                #expect(banner == InboxErrorBanner.genericMessage, "banner gone after background run \(run)")
            }

            await world.setFailing(false)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == nil, "a full run with every account succeeding did not clear")
        }
    }

    // MARK: - One test per census row

    @Test("unified-inbox refresh (full): raises on failure, clears on success")
    func fullRefreshRaisesAndClears() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)
            await world.setFailing(false)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == nil)
        }
    }

    @Test("refresh of some accounts (partial): succeeding leaves the banner up")
    func partialRefreshNeverClears() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            await InboxViewModel(folders: [world.inboxB]).refreshSync()
            #expect(banner == InboxErrorBanner.genericMessage, "a one-account refresh cleared the banner")
        }
    }

    @Test("refresh of some accounts (partial): its own failure raises, as before")
    func partialRefreshRaisesOnItsOwnFailure() async throws {
        try await withWorld { world in
            await world.setFailing(true)
            await InboxViewModel(folders: [world.inboxA]).refreshSync()
            #expect(banner == InboxErrorBanner.genericMessage)
        }
    }

    @Test("foreground poll (full): never raises; clears when no account failed")
    func foregroundPollNeverRaises() async throws {
        try await withWorld { world in
            await world.setFailing(true)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == nil, "a scheduler run raised the banner")

            await raiseThroughRefresh(world)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == InboxErrorBanner.genericMessage, "a run where A failed cleared the banner")

            await world.setFailing(false)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == nil)
        }
    }

    @Test("background poll of every account (full): never raises; clears when no account failed")
    func fullBackgroundPollNeverRaises() async throws {
        try await withWorld { world in
            await world.setFailing(true)
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            #expect(banner == nil, "a background run raised the banner")

            await raiseThroughRefresh(world)
            await world.setFailing(false)
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            #expect(banner == nil, "a full clean background run did not clear")
        }
    }

    @Test("background poll of one account (partial): never raises, never clears")
    func singleAccountBackgroundPollNeverClears() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: world.accountB.emailAddress, inboxOnly: false)
            #expect(banner == InboxErrorBanner.genericMessage, "a one-account background run cleared the banner")

            AccountManagerState.shared.syncErrorBanner = nil
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: world.accountA.emailAddress, inboxOnly: false)
            #expect(banner == nil, "a one-account background run raised the banner")
        }
    }

    // MARK: - Accounts marked sign-in-needed never count

    @Test("A recovers while B is marked sign-in-needed and failing: the next full run clears")
    func markedFailingAccountDoesNotHoldTheBanner() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)

            await AccountManager.shared.markAuthFailed(world.accountB.id)
            await world.setBFailing(true)
            await world.setFailing(false)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == nil, "a marked account's failure kept the generic banner up")
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            #expect(banner == nil)
        }
    }

    @Test("A recovers while B fails and is not marked: the banner stays")
    func unmarkedFailingAccountKeepsTheBanner() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            await world.setBFailing(true)
            await world.setFailing(false)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == InboxErrorBanner.genericMessage, "an unmarked failing account let a full run clear")
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            #expect(banner == InboxErrorBanner.genericMessage, "an unmarked failing account let a background run clear")
        }
    }

    @Test("a foreground poll where every account fails neither clears nor completes")
    func allFailedForegroundPollDoesNotClear() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            let completedBefore = Date(timeIntervalSinceNow: -60)
            AccountManagerState.shared.lastSyncCompletedAt = completedBefore
            await world.setBFailing(true)
            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == InboxErrorBanner.genericMessage, "an all-failed poll cleared the banner")
            #expect(AccountManagerState.shared.lastSyncCompletedAt == completedBefore,
                    "an all-failed poll advanced lastSyncCompletedAt")
            #expect(AccountManagerState.shared.lastSyncFailed)
        }
    }

    // MARK: - A failed refresh never clears

    @Test("a full refresh where a marked and an unmarked account both fail never clears, in either order")
    func failedRefreshWithMarkedAndUnmarkedNeverClears() async throws {
        for markA in [true, false] {
            for foldersFirstA in [true, false] {
                try await withWorld { world in
                    await raiseThroughRefresh(world)
                    #expect(banner == InboxErrorBanner.genericMessage)
                    await world.setBFailing(true)
                    await AccountManager.shared.markAuthFailed(markA ? world.accountA.id : world.accountB.id)
                    let folders = foldersFirstA ? [world.inboxA, world.inboxB] : [world.inboxB, world.inboxA]
                    for refresh in 1...3 {
                        await InboxViewModel(folders: folders).refreshSync()
                        #expect(banner == InboxErrorBanner.genericMessage,
                                "a failed refresh cleared (marked \(markA ? "A" : "B"), A first: \(foldersFirstA), refresh \(refresh))")
                    }
                }
            }
        }
    }

    @Test("a background poll where an account is temporarily refused still clears")
    func temporaryRefusalLetsBackgroundPollClear() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            let refusal = ProviderTemporaryRefusal(underlying: NSError(domain: "com.example.test", code: 9))
            await world.providerA.setConnectThrows(refusal)
            await world.providerA.setFetchMessagesThrows(refusal)
            _ = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            #expect(banner == nil, "a temporary refusal blocked the clear")
        }
    }

    @Test("a poll that cannot load its accounts counts as failed and cannot clear")
    func accountLoadFailureCannotClear() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            await world.setFailing(false)
            try await world.pool.write { db in try db.execute(sql: "ALTER TABLE account RENAME TO account_hidden") }
            let background = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
            let foreground = await AccountManager.shared.foregroundPollRun()
            try await world.pool.write { db in try db.execute(sql: "ALTER TABLE account_hidden RENAME TO account") }
            #expect(background.countedFailure && foreground.countedFailure)
            #expect(banner == InboxErrorBanner.genericMessage, "a poll that loaded no accounts cleared the banner")
        }
    }
}
