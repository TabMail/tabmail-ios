/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
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
/// | `AccountManager.followUpRun`                  | partial             | never  | never               |
///
/// A poll run that skipped a busy account (`SyncResult.skipped`) is partial, and
/// does not advance "Updated" (`lastSyncCompletedAt`): the follow-up does, once
/// its read completes.
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
        // A test that registered an account with the sync engine (no-op otherwise).
        let engine = await AccountManager.shared.syncEngine
        await engine.remove(accountId: world.accountA.id)
        await engine.remove(accountId: world.accountB.id)
        await AccountManager.shared.unregisterProviderForTesting(accountId: world.accountA.id)
        await AccountManager.shared.unregisterProviderForTesting(accountId: world.accountB.id)
        await AccountManager.shared.clearAuthFailed(world.accountA.id)
        await AccountManager.shared.clearAuthFailed(world.accountB.id)
        let state = AccountManagerState.shared
        // A phase a run left for its holder to clear (a test's synthetic holder
        // never does).
        state.setSyncPhase(nil, forAccount: world.accountA.id)
        state.setSyncPhase(nil, forAccount: world.accountB.id)
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

    // MARK: - A busy account is skipped, never waited for

    /// A poll that finds an account's turn held by another pass returns without
    /// waiting for it (the account gets its follow-up flag). It did not sync
    /// every account, so it never clears the banner, foreground or background.
    /// The follow-up stage 2 reports as a partial run, so it never clears either;
    /// the next run that syncs every account does. RED while a poll waited for a
    /// busy account, and while a skipped account counted as a success.
    ///
    /// Account A is registered with the sync engine here (the other tests leave
    /// the engine out), so its passes take the account's turn and the held turn
    /// makes it busy; its reader answers with no changes. The poll runs in
    /// every form: foreground, background of every account, and background of
    /// the one account a push named.
    @Test("a poll with a busy account returns at once and never clears; nor does the account's follow-up")
    func busyAccountPollNeverClears() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)
            await world.setFailing(false)
            let engine = await AccountManager.shared.syncEngine
            let accountId = world.accountA.id
            try await world.pool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: "100"), Column("lastFullSyncAt").set(to: Date()))
            }
            await world.providerA.setChangeReader { _, request in
                ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil, records: [], removals: [])
                })
            }
            await engine.register(
                accountId: accountId, provider: world.providerA,
                workQueue: ProviderWorkQueue(provider: world.providerA, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            var waitEnd = Date().addingTimeInterval(10)
            while log.snapshot.isEmpty, Date() < waitEnd { try await Task.sleep(for: .milliseconds(10)) }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")

            let completedBefore = Date(timeIntervalSinceNow: -60)
            AccountManagerState.shared.lastSyncCompletedAt = completedBefore
            let runs = Mutex<[AccountManager.SyncResult]>([])
            let emailA = world.accountA.emailAddress
            let polls = Task {
                let foreground = await AccountManager.shared.foregroundPollRun()
                let foregroundBanner = AccountManagerState.shared.syncErrorBanner
                runs.withLock { $0.append(foreground) }
                let background = await AccountManager.shared.backgroundPollRun(accountEmail: nil, inboxOnly: false)
                runs.withLock { $0.append(background) }
                let targeted = await AccountManager.shared.backgroundPollRun(accountEmail: emailA, inboxOnly: false)
                runs.withLock { $0.append(targeted) }
                return foregroundBanner
            }
            waitEnd = Date().addingTimeInterval(10)
            while runs.withLock({ $0.count }) < 3, Date() < waitEnd { try await Task.sleep(for: .milliseconds(10)) }
            let returnedWhileHeld = runs.withLock { $0.count } == 3
            #expect(returnedWhileHeld, "a poll waited for the busy account's turn")
            let readsWhileHeld = await world.providerA.changeRequests.count
            #expect(readsWhileHeld == 0, "a poll read the busy account")
            let bannerAfterPolls = banner
            let completedAfterPolls = AccountManagerState.shared.lastSyncCompletedAt
            #expect(completedAfterPolls == completedBefore,
                    "a poll that skipped the busy account advanced \"Updated\" before anything read it")

            // The account's follow-up stage 2 once the turn is free: the app's
            // scheduler only records its asks, so this call serves the flag. Once
            // the polls have returned, only a follow-up's report sets the
            // completion time.
            AccountManagerState.shared.lastSyncCompletedAt = nil
            release.continuation.yield()
            await holder.value
            let bannerAfterForeground = await polls.value
            let results = runs.withLock { $0 }
            let everyRunSkipped = results.count == 3 && results.allSatisfy(\.skipped)
            #expect(everyRunSkipped, "a run with a busy account did not report it skipped")
            #expect(bannerAfterForeground == InboxErrorBanner.genericMessage, "a foreground poll with a busy account cleared the banner")
            #expect(bannerAfterPolls == InboxErrorBanner.genericMessage, "a background poll with a busy account cleared the banner")

            _ = await AccountManager.shared.followUpRun(world.accountA, mayStart: { true })
            waitEnd = Date().addingTimeInterval(10)
            while AccountManagerState.shared.lastSyncCompletedAt == nil, Date() < waitEnd {
                try await Task.sleep(for: .milliseconds(10))
            }
            let followUpReported = AccountManagerState.shared.lastSyncCompletedAt != nil
            let followUpReads = await world.providerA.changeRequests.count
            let stillWanted = await engine.followUpWanted(accountId: accountId)
            let flagServed = !stillWanted
            #expect(followUpReported, "the follow-up stage 2 never ran to its report")
            #expect(followUpReads == 1, "the follow-up did not read the busy account once: \(followUpReads) reads")
            #expect(flagServed, "the follow-up left the flag set")
            #expect(banner == InboxErrorBanner.genericMessage, "the follow-up, a partial run, cleared the banner")
            // The flag and the release of the still-flagged account asked.
            try await waitForAsks(2, of: accountId, stages)

            _ = await AccountManager.shared.foregroundPollRun()
            #expect(banner == nil, "non-vacuity: a run that syncs every account clears")
        } }
    }

    /// A unified-inbox refresh whose change read finds an account busy (its
    /// follow-up flag set instead) did not read that account: it is a partial
    /// run and never clears the banner, and it still advances "Updated" (it
    /// listed the folders on screen). RED while a busy change read counted as
    /// read, and with a busy refresh left out of the completion stamp. A pass
    /// that queued behind A's listing takes A's turn when the listing ends, so
    /// A's change read, which follows its listing, finds it held. With A free,
    /// the same refresh clears.
    @Test("a unified-inbox refresh whose change read finds an account busy never clears")
    func busyChangeReadRefreshNeverClears() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)
            await world.setFailing(false)
            let engine = await AccountManager.shared.syncEngine
            let accountId = world.accountA.id
            try await world.pool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: "100"), Column("lastFullSyncAt").set(to: Date()))
            }
            await world.providerA.setChangeReader { _, request in
                ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil, records: [], removals: [])
                })
            }
            await engine.register(
                accountId: accountId, provider: world.providerA,
                workQueue: ProviderWorkQueue(provider: world.providerA, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let held = Mutex<Task<Void, Never>?>(nil)
            await world.providerA.setFetchMessagesHook { _ in
                let first = held.withLock { $0 == nil }
                guard first else { return }
                let pass = OneSyncAtATimeTests.heldPass(
                    engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
                held.withLock { $0 = pass }
                // In line behind the listing before the listing ends.
                let inLine = Date().addingTimeInterval(10)
                while await engine.syncPassWaiters[accountId]?.count != 1, Date() < inLine {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            let state = AccountManagerState.shared
            let stampBefore = Date(timeIntervalSinceNow: -3600)
            state.lastSyncCompletedAt = stampBefore
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            await world.providerA.setFetchMessagesHook(nil)
            let heldAfterListing = log.snapshot == ["start held"]
            let readsWhileHeld = await world.providerA.changeRequests.count
            let wanted = await engine.followUpWanted(accountId: accountId)
            let stamped = (state.lastSyncCompletedAt ?? .distantPast) > stampBefore
            #expect(heldAfterListing, "precondition: a pass took A's turn when its listing ended")
            #expect(readsWhileHeld == 0 && wanted, "precondition: A's change read found the account busy")
            #expect(banner == InboxErrorBanner.genericMessage, "a refresh that did not read a busy account cleared the banner")
            #expect(stamped, "a refresh that found an account busy did not advance \"Updated\"")

            // The flag's follow-up (the app's scheduler only records its asks),
            // then the same refresh with A free.
            release.continuation.yield()
            if let pass = held.withLock({ $0 }) { await pass.value }
            _ = await AccountManager.shared.followUpRun(world.accountA, mayStart: { true })
            let settle = Date().addingTimeInterval(10)
            while await engine.syncPassRunning.contains(accountId), Date() < settle {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await waitForAsks(2, of: accountId, stages)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == nil, "non-vacuity: the same refresh with A free clears")
        } }
    }

    /// When the follow-up stage 2 read, the inbox reloads, as after a push's own
    /// read: the trigger that set the flag reloaded before this read. The
    /// reload finds what the read stored (the account's new cursor). A read
    /// that found no changes does not mirror the extension's cursors. RED
    /// without the reload: what the follow-up read stayed off screen until the
    /// next reload; with the reload moved before the read; and with the mirror
    /// run after every read. Driven through the scheduler's own follow-up
    /// (`SyncScheduler.runSyncFollowUp`, in the foreground); the app's scheduler
    /// only records its asks.
    @Test("the follow-up stage 2 reloads the inbox once it read")
    func followUpReloadsTheInbox() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = await AccountManager.shared.syncEngine
            let accountId = world.accountA.id
            try await world.pool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: "100"), Column("lastFullSyncAt").set(to: Date()))
            }
            let events = Events()
            await world.providerA.setChangeReader { _, request in
                events.append("read")
                return ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil, records: [], removals: [])
                })
            }
            await engine.register(
                accountId: accountId, provider: world.providerA,
                workQueue: ProviderWorkQueue(provider: world.providerA, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            var waitEnd = Date().addingTimeInterval(10)
            while log.snapshot.isEmpty, Date() < waitEnd { try await Task.sleep(for: .milliseconds(10)) }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")

            let pool = world.pool
            let observer = NotificationCenter.default.addObserver(forName: .inboxDataDidChange, object: nil, queue: nil) { _ in
                let stored = try? pool.read { db in try Account.fetchOne(db, key: accountId) }
                events.append("reload \(stored?.lastHistoryId ?? "none")")
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let key = "nse.lastHistoryIds"
            let suite = UserDefaults(suiteName: "group.ai.tabmail")
            let savedMirror = suite?.string(forKey: key)
            let sentinel = "{\"mirror-sentinel\":\"1\"}"
            suite?.set(sentinel, forKey: key)
            defer {
                if let savedMirror { suite?.set(savedMirror, forKey: key) } else { suite?.removeObject(forKey: key) }
            }
            release.continuation.yield()
            await holder.value
            await SyncScheduler(foreground: true).runSyncFollowUp(accountId: accountId)
            waitEnd = Date().addingTimeInterval(10)
            while !events.snapshot.contains(where: { $0.hasPrefix("reload") }), Date() < waitEnd {
                try await Task.sleep(for: .milliseconds(10))
            }
            let followUpReads = await world.providerA.changeRequests.count
            let seen = events.snapshot
            let firstRead = seen.firstIndex(of: "read")
            let firstReload = seen.firstIndex { $0.hasPrefix("reload") }
            #expect(followUpReads == 1, "precondition: the follow-up read the account once: \(followUpReads) reads")
            #expect(firstReload != nil, "the follow-up read, and the inbox did not reload")
            #expect(firstRead != nil && firstReload != nil && firstRead! < firstReload!,
                    "the inbox reloaded before the follow-up's read: \(seen)")
            let firstReloadEvent = firstReload.map { seen[$0] }
            let mirror = suite?.string(forKey: key)
            #expect(firstReloadEvent == "reload 200", "the inbox reloaded before the follow-up's read was stored: \(seen)")
            #expect(mirror == sentinel, "a follow-up that found no changes mirrored the extension's cursors")
            try await waitForAsks(2, of: accountId, stages)
        } }
    }

    /// What a test saw, in order, from any thread.
    final class Events: Sendable {
        private let events = Mutex<[String]>([])
        func append(_ event: String) { events.withLock { $0.append(event) } }
        var snapshot: [String] { events.withLock { $0 } }
    }

    /// Registers account A with the app's engine, its reader answering `reader`
    /// (no changes when nil), its full sync not due; the other tests leave the
    /// engine out.
    private func registerA(
        _ world: World,
        reader: (@Sendable (ChangeCursor, ChangeRequest) async throws -> ChangeSet?)? = nil
    ) async throws -> SyncEngine {
        try await register(world.accountA, world.providerA, world, reader: reader)
    }

    /// `registerA` for either account.
    private func register(
        _ account: Account, _ provider: MockEmailProvider, _ world: World,
        reader: (@Sendable (ChangeCursor, ChangeRequest) async throws -> ChangeSet?)? = nil
    ) async throws -> SyncEngine {
        let engine = await AccountManager.shared.syncEngine
        let accountId = account.id
        try await world.pool.write { db in
            _ = try Account.filter(Column("id") == accountId)
                .updateAll(db, Column("lastHistoryId").set(to: "100"), Column("lastFullSyncAt").set(to: Date()))
        }
        if let reader {
            await provider.setChangeReader(reader)
        } else {
            await provider.setChangeReader { _, request in
                ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil, records: [], removals: [])
                })
            }
        }
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    /// Runs `body` with the app's scheduler recording the follow-ups the app's
    /// engine asks for instead of running them, so only the follow-up a test
    /// runs itself serves a flag, then restores the scheduler. A test waits for
    /// the asks it expects (`waitForAsks`) before it ends, so none reaches the
    /// restored scheduler.
    private func withAppSchedulerRecording(_ body: (SyncFollowUpTests.Stages) async throws -> Void) async throws {
        let scheduler = SyncScheduler.shared
        let saved = (scheduler.applicationStateForTesting, scheduler.foregroundReadinessHook, scheduler.stageTwoHook)
        let stages = SyncFollowUpTests.Stages()
        scheduler.applicationStateForTesting = .active
        scheduler.foregroundReadinessHook = { true }
        scheduler.stageTwoHook = { stages.triggers.append($0) }
        defer {
            scheduler.applicationStateForTesting = saved.0
            scheduler.foregroundReadinessHook = saved.1
            scheduler.stageTwoHook = saved.2
        }
        try await body(stages)
    }

    /// Waits until the app's scheduler recorded `count` asks for the account's
    /// follow-up, then until no pass of the account runs and an ask already on
    /// its way to the main actor has landed, and expects exactly that many.
    private func waitForAsks(_ count: Int, of accountId: String, _ stages: SyncFollowUpTests.Stages) async throws {
        let ask = "follow-up \(accountId)"
        try await waitUntil { stages.triggers.filter { $0 == ask }.count >= count }
        let engine = await AccountManager.shared.syncEngine
        try await waitUntil { await !engine.syncPassRunning.contains(accountId) }
        try await Task.sleep(for: .milliseconds(200))
        let asks = stages.triggers.filter { $0 == ask }.count
        #expect(asks == count, "the app's scheduler was asked \(asks) times for the follow-up, not \(count)")
    }

    /// Bounded wait on the main actor.
    private func waitUntil(seconds: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while await !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - The scheduler's own wiring

    /// The app's engine asks the app's scheduler: a trigger that finds an account
    /// busy on `AccountManager.shared.syncEngine` reaches
    /// `SyncScheduler.shared.runSyncFollowUp` (the engine's `syncFollowUp`
    /// callback), and so does the release of an account still flagged. RED with
    /// the callback left a no-op: nothing asked for the stage 2.
    @Test("a busy trigger on the app's engine asks the app's scheduler for its follow-up")
    func busyTriggerAsksTheAppScheduler() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = try await registerA(world)
            let accountId = world.accountA.id
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")

            // Only this account's asks count: an earlier test's follow-up on the
            // app's scheduler can still be waiting for the first paint.
            let ask = "follow-up \(accountId)"
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")
            try await waitUntil { stages.triggers.contains(ask) }
            #expect(stages.triggers.filter { $0 == ask }.count == 1, "the busy trigger's flag did not reach the app's scheduler")

            // The scheduler recorded its stage 2 instead of running it, so the
            // flag is still set: the release asks again.
            release.continuation.yield()
            await holder.value
            try await waitUntil { stages.triggers.filter { $0 == ask }.count >= 2 }
            #expect(stages.triggers.filter { $0 == ask }.count == 2,
                    "the release of a flagged account did not ask the app's scheduler again")
        } }
    }

    /// A poll tick that lands during a poll runs the real stage 2 for every
    /// account (`SyncScheduler.stageTwoForEveryAccount` ->
    /// `AccountManager.foregroundPollRun`): a free account reads now, and a busy
    /// one gets its follow-up flag without the tick waiting for it. RED with
    /// that call removed: the tick read nothing (#1313); and while the tick
    /// waited for the busy account.
    @Test("a poll tick during a poll reads a free account now and flags a busy one")
    func pollTickDuringAPollReadsAFreeAccount() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            _ = try await registerA(world)
            let engine = try await register(world.accountB, world.providerB, world)
            let accountB = world.accountB.id
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountB, name: "held B", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start held B"], "precondition: account B's turn is held")

            let done = Events()
            let tick = Task {
                await SyncScheduler(foreground: true, pollActive: true).poll()
                done.append("tick")
            }
            try await waitUntil { !done.snapshot.isEmpty }
            let returnedWhileHeld = !done.snapshot.isEmpty
            let readsA = await world.providerA.changeRequests.count
            let readsB = await world.providerB.changeRequests.count
            let flaggedB = await engine.followUpWanted(accountId: accountB)
            #expect(returnedWhileHeld, "the tick waited for the busy account")
            #expect(readsA == 1, "the tick did not read the free account: \(readsA) reads")
            #expect(readsB == 0, "the tick read the busy account")
            #expect(flaggedB, "the tick left the busy account without its follow-up flag")

            release.continuation.yield()
            await holder.value
            await tick.value
            try await waitForAsks(2, of: accountB, stages)
        } }
    }

    /// A follow-up whose read found changes mirrors the cursors the notification
    /// extension reads (`NSEDataBridge.mirrorLastHistoryIds`), as the trigger's
    /// own read did (`SyncScheduler.backgroundPoll`). RED without it: the
    /// extension kept the cursor from before the follow-up's read.
    @Test("a follow-up that found changes mirrors the extension's cursors")
    func followUpWithChangesMirrorsTheCursors() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let accountId = world.accountA.id
            let inboxId = world.inboxA.id
            try await world.pool.write { db in
                var header = MessageHeader(
                    messageId: "1", subject: "mirror fixture", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(), snippet: "mirror fixture",
                    folderId: inboxId, accountId: accountId, folderPath: "INBOX",
                    isInInbox: true
                )
                header.rfc822MessageId = "mirror-fixture-1@example.com"
                header.headerComplete = true
                header.isRead = false
                try header.insert(db)
            }
            let engine = try await registerA(world, reader: { _, request in
                var record = ChangeRecord(messageId: "1")
                record.isRead = true
                return ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil,
                                  records: $0.id == inboxId ? [record] : [], removals: [])
                })
            })
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")

            let key = "nse.lastHistoryIds"
            let suite = UserDefaults(suiteName: "group.ai.tabmail")
            let savedMirror = suite?.string(forKey: key)
            suite?.removeObject(forKey: key)
            defer {
                if let savedMirror { suite?.set(savedMirror, forKey: key) } else { suite?.removeObject(forKey: key) }
            }
            release.continuation.yield()
            await holder.value
            await SyncScheduler(foreground: true).runSyncFollowUp(accountId: accountId)
            let expected = "\"\(accountId)\":\"200\""
            try await waitUntil { (suite?.string(forKey: key) ?? "").contains(expected) }
            let reads = await world.providerA.changeRequests.count
            let mirrored = suite?.string(forKey: key) ?? ""
            #expect(reads == 1, "precondition: the follow-up read the account once: \(reads) reads")
            #expect(mirrored.contains(expected), "the follow-up's changes left the extension's cursors as before: \(mirrored)")
            try await waitForAsks(2, of: accountId, stages)
        } }
    }

    /// A follow-up asked for when no stage 2 is owed (an earlier one served the
    /// flag) does nothing: no connection check or other provider call, no report,
    /// no reload. RED without `followUpRun`'s first check: its connection check
    /// reached the provider (it also showed "Checking" and then cleared the
    /// account's phase). The phase is not read here: the shown phase is one value
    /// summed over every account on shared state, and other suites' sync engines
    /// publish and clear their own accounts' phases on it while this test runs.
    @Test("a follow-up asked for with no stage 2 owed does nothing")
    func followUpWithNothingOwedDoesNothing() async throws {
        try await withWorld { world in
            let accountId = world.accountA.id
            let state = AccountManagerState.shared
            let completedBefore = Date(timeIntervalSinceNow: -60)
            state.lastSyncCompletedAt = completedBefore
            let events = Events()
            let observer = NotificationCenter.default.addObserver(forName: .inboxDataDidChange, object: nil, queue: nil) { _ in
                events.append("reload")
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let callsBefore = await world.providerA.callLog.count
            // The connection check, the report and the reload all finish before
            // the runner returns.
            await SyncScheduler(foreground: true).runSyncFollowUp(accountId: accountId)
            let calls = await Array(world.providerA.callLog.dropFirst(callsBefore))
            #expect(calls.isEmpty, "a follow-up with nothing owed reached the provider: \(calls)")
            #expect(state.lastSyncCompletedAt == completedBefore, "a follow-up with nothing owed reported a run")
            #expect(events.snapshot.isEmpty, "a follow-up with nothing owed reloaded the inbox")
        }
    }

    /// The follow-up waits for the first paint before it asks for the account's
    /// turn, as the opening's reads did: while it waits, the turn stays free for
    /// other work, and its change read's deadline starts only at its turn. RED
    /// with the paint wait moved inside the turn: the other pass waited for the
    /// paint.
    @Test("the follow-up's first-paint wait holds no account turn")
    func followUpPaintWaitHoldsNoTurn() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = try await registerA(world)
            let accountId = world.accountA.id
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")
            release.continuation.yield()
            await holder.value

            let gate = Events()
            let painted = AsyncStream<Bool>.makeStream()
            defer { painted.continuation.finish() }
            let scheduler = SyncScheduler(foreground: true, foregroundReady: {
                gate.append("reached")
                for await ready in painted.stream { return ready }
                return false
            })
            let followUp = Task { await scheduler.runSyncFollowUp(accountId: accountId) }
            try await waitUntil { !gate.snapshot.isEmpty }
            #expect(!gate.snapshot.isEmpty, "precondition: the follow-up reached the first-paint gate")

            let other = AsyncStream<Void>.makeStream()
            defer { other.continuation.finish() }
            let otherPass = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "other", log: log, release: other.stream)
            try await waitUntil(seconds: 3) { log.snapshot.contains("start other") }
            let otherStarted = log.snapshot.contains("start other")
            let readsBeforePaint = await world.providerA.changeRequests.count
            #expect(otherStarted, "another pass of the account waited for the follow-up's first paint")
            #expect(readsBeforePaint == 0, "the follow-up read before the inbox painted")

            // Painted: the follow-up asks for the turn and waits in line behind
            // the other pass, which then ends.
            painted.continuation.yield(true)
            try await waitUntil { await engine.syncPassWaiters[accountId]?.count == 1 }
            let inLine = await engine.syncPassWaiters[accountId]?.count == 1
            #expect(inLine, "precondition: after the paint the follow-up waits in line behind the other pass")
            other.continuation.yield()
            await otherPass.value
            await followUp.value
            let reads = await world.providerA.changeRequests.count
            #expect(reads == 1, "the follow-up did not read once after the paint: \(reads) reads")
            try await waitForAsks(2, of: accountId, stages)
        } }
    }

    /// Fast Sync in the foreground: catch-up slices hold the account's turn back
    /// to back. A push that finds the account busy flags it, and its follow-up
    /// waits for the running slice and reads before the next one (Fast Sync never
    /// held back the push's own read), not at the next poll after Fast Sync. RED with Fast Sync
    /// in the follow-up's gate: it started nothing, and the read waited.
    @Test("during Fast Sync a push's follow-up reads between two catch-up slices")
    func followUpReadsBetweenFastSyncSlices() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let state = AccountManagerState.shared
            let savedFastSync = state.fastSyncModeActive
            state.fastSyncModeActive = true
            defer { state.fastSyncModeActive = savedFastSync }
            let log = OneSyncAtATimeTests.PassLog()
            let engine = try await registerA(world, reader: { _, request in
                log.append("read")
                return ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil, records: [], removals: [])
                })
            })
            let accountId = world.accountA.id
            let slice1 = AsyncStream<Void>.makeStream()
            let slice2 = AsyncStream<Void>.makeStream()
            defer {
                slice1.continuation.finish()
                slice2.continuation.finish()
            }
            let first = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "slice 1", log: log, release: slice1.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start slice 1"], "precondition: a catch-up slice holds the turn")

            // The push: its read finds the slice running and flags the account.
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the push found the account busy")
            let followUp = Task { await SyncScheduler(foreground: true).runSyncFollowUp(accountId: accountId) }
            try await waitUntil { await engine.syncPassWaiters[accountId]?.count == 1 }
            let inLine = await engine.syncPassWaiters[accountId]?.count == 1
            #expect(inLine, "the follow-up did not wait for the running slice during Fast Sync")

            // The catch-up's next slice asks for the turn behind it.
            let second = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "slice 2", log: log, release: slice2.stream)
            try await waitUntil { await engine.syncPassWaiters[accountId]?.count == 2 }
            let bothInLine = await engine.syncPassWaiters[accountId]?.count == 2
            #expect(bothInLine, "precondition: the next slice waits in line behind the follow-up")
            slice1.continuation.yield()
            await first.value
            try await waitUntil { log.snapshot.contains("start slice 2") }
            #expect(log.snapshot == ["start slice 1", "end slice 1", "read", "start slice 2"],
                    "the push's follow-up did not read between the two slices: \(log.snapshot)")
            slice2.continuation.yield()
            await second.value
            await followUp.value
            try await waitForAsks(1, of: accountId, stages)
        } }
    }

    /// What changes while the scheduler's follow-up waits for its turn.
    enum GateFlip: String, CaseIterable, Sendable {
        /// The app leaves the foreground.
        case background
        /// Demo mode starts.
        case demo
    }

    /// The scheduler's own follow-up across a change of the app's state: admitted
    /// in the foreground, it waits in line; the app leaves, or demo mode starts,
    /// before its turn. At its turn the scheduler's gate (`followUpMayStart`, the
    /// `mayStart` it hands the engine) refuses: nothing reads and the flag stays
    /// set. The next foreground follow-up reads. RED with the scheduler's
    /// `mayStart` always true: the follow-up read in the background and cleared
    /// the flag; and with it checking the foreground alone: it read the real
    /// account under demo mode.
    @Test("the scheduler's follow-up whose app leaves, or enters demo mode, before its turn reads nothing and keeps the flag",
          arguments: GateFlip.allCases)
    func schedulerFollowUpAcrossAGateFlip(flip: GateFlip) async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = try await registerA(world)
            let accountId = world.accountA.id
            let demo = DemoModeStore.shared
            let savedDemo = demo.isActive
            defer { demo.isActive = savedDemo }
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")

            let scheduler = SyncScheduler(foreground: true)
            let followUp = Task { await scheduler.runSyncFollowUp(accountId: accountId) }
            try await waitUntil { await engine.syncPassWaiters[accountId]?.count == 1 }
            let inLine = await engine.syncPassWaiters[accountId]?.count == 1
            #expect(inLine, "precondition: the follow-up waits in line")

            let state = AccountManagerState.shared
            let completedBefore = Date(timeIntervalSinceNow: -60)
            state.lastSyncCompletedAt = completedBefore
            let events = Events()
            let observer = NotificationCenter.default.addObserver(forName: .inboxDataDidChange, object: nil, queue: nil) { _ in
                events.append("reload")
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            switch flip {
            case .background: scheduler.applicationStateForTesting = .background
            case .demo: demo.isActive = true
            }
            release.continuation.yield()
            await holder.value
            await followUp.value
            let readsAway = await world.providerA.changeRequests.count
            let wantedAway = await engine.followUpWanted(accountId: accountId)
            #expect(readsAway == 0, "the follow-up read after the gate closed (\(flip.rawValue))")
            #expect(wantedAway, "the follow-up cleared the flag with nothing read (\(flip.rawValue))")
            #expect(state.lastSyncCompletedAt == completedBefore,
                    "the follow-up refused at its turn advanced \"Updated\" with nothing read (\(flip.rawValue))")
            #expect(events.snapshot.isEmpty, "the follow-up refused at its turn reloaded the inbox (\(flip.rawValue))")
            // The flag, and the release of the still-flagged account. Under demo
            // mode the app's scheduler refuses that release's ask at its own
            // gate, before it records it: the ask lands while demo mode is on.
            switch flip {
            case .background:
                try await waitForAsks(2, of: accountId, stages)
            case .demo:
                try await waitForAsks(1, of: accountId, stages)
                demo.isActive = savedDemo
            }

            scheduler.applicationStateForTesting = .active
            await scheduler.runSyncFollowUp(accountId: accountId)
            let reads = await world.providerA.changeRequests.count
            let wanted = await engine.followUpWanted(accountId: accountId)
            let advanced = state.lastSyncCompletedAt.map { $0 > completedBefore } == true
            #expect(reads == 1, "the next foreground follow-up did not read once: \(reads) reads")
            #expect(!wanted, "the next foreground follow-up left the flag set")
            #expect(advanced, "non-vacuity: the next foreground follow-up did not advance \"Updated\"")
            #expect(events.snapshot == ["reload"], "non-vacuity: the next foreground follow-up did not reload the inbox once: \(events.snapshot)")
        } }
    }

    /// A follow-up whose read fails (here a lost connection whose retry fails
    /// too, with no full sync due) reports a failed run: it does not advance
    /// "Updated". It took the turn, so the flag is served; the next trigger
    /// reads. RED with the follow-up's run always reported as completed:
    /// "Updated" moved with nothing read.
    @Test("a follow-up whose read fails does not advance \"Updated\"")
    func failedFollowUpDoesNotAdvanceUpdated() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = try await registerA(world, reader: { _, _ in throw ProviderError.notConnected })
            let accountId = world.accountA.id
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")

            let state = AccountManagerState.shared
            let completedBefore = Date(timeIntervalSinceNow: -60)
            state.lastSyncCompletedAt = completedBefore
            release.continuation.yield()
            await holder.value
            await SyncScheduler(foreground: true).runSyncFollowUp(accountId: accountId)
            let reads = await world.providerA.changeRequests.count
            let wanted = await engine.followUpWanted(accountId: accountId)
            #expect(reads > 0, "precondition: the follow-up tried to read the account")
            #expect(!wanted, "precondition: the follow-up took the turn and served the flag")
            #expect(state.lastSyncCompletedAt == completedBefore, "a follow-up whose read failed advanced \"Updated\"")
            // The flag, and the release of the still-flagged account.
            try await waitForAsks(2, of: accountId, stages)
        } }
    }

    /// The follow-up of an account that is turned off reads nothing and keeps
    /// the flag; once the account is on again, the next follow-up reads. RED
    /// without the scheduler's check of the account: the follow-up read an
    /// account that is off.
    @Test("the follow-up of an inactive account reads nothing and keeps the flag")
    func inactiveAccountFollowUpReadsNothing() async throws {
        try await withWorld { world in try await withAppSchedulerRecording { stages in
            let engine = try await registerA(world)
            let accountId = world.accountA.id
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            try await waitUntil { !log.snapshot.isEmpty }
            #expect(log.snapshot == ["start held"], "precondition: account A's turn is held")
            let busy = try await engine.backgroundDeltaSync(account: world.accountA)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")
            release.continuation.yield()
            await holder.value

            try await world.pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db, Column("isActive").set(to: false))
            }
            let scheduler = SyncScheduler(foreground: true)
            await scheduler.runSyncFollowUp(accountId: accountId)
            let readsOff = await world.providerA.changeRequests.count
            let wantedOff = await engine.followUpWanted(accountId: accountId)
            #expect(readsOff == 0, "the follow-up read an inactive account")
            #expect(wantedOff, "the follow-up of an inactive account cleared the flag")
            // The flag, and the release of the still-flagged account.
            try await waitForAsks(2, of: accountId, stages)

            try await world.pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db, Column("isActive").set(to: true))
            }
            await scheduler.runSyncFollowUp(accountId: accountId)
            let reads = await world.providerA.changeRequests.count
            let wanted = await engine.followUpWanted(accountId: accountId)
            #expect(reads == 1, "non-vacuity: the follow-up of the account on again did not read once: \(reads) reads")
            #expect(!wanted, "non-vacuity: the follow-up of the account on again left the flag set")
        } }
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

    // MARK: - What a failed refresh raises

    @Test("an offline refresh shows no banner")
    func offlineRefreshShowsNoBanner() async throws {
        try await withWorld { world in
            let offline = URLError(.notConnectedToInternet)
            await world.providerA.setConnectThrows(offline)
            await world.providerA.setFetchMessagesThrows(offline)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == nil, "an offline refresh raised the banner")

            // Offline is a failed refresh that does not count: it must not clear either.
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)
            await world.providerA.setConnectThrows(offline)
            await world.providerA.setFetchMessagesThrows(offline)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == InboxErrorBanner.genericMessage, "an offline refresh cleared the banner")
        }
    }

    @Test("a refresh failing only with a temporary refusal leaves a raised banner up")
    func temporaryRefusalRefreshKeepsBanner() async throws {
        try await withWorld { world in
            await raiseThroughRefresh(world)
            #expect(banner == InboxErrorBanner.genericMessage)
            let refusal = ProviderTemporaryRefusal(underlying: NSError(domain: "com.example.test", code: 9))
            await world.providerA.setConnectThrows(refusal)
            await world.providerA.setFetchMessagesThrows(refusal)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == InboxErrorBanner.genericMessage, "a temporary refusal cleared the banner")
        }
    }

    @Test("a marked account's non-sign-in failure on a refresh raises the generic banner")
    func markedAccountOtherFailureOnRefreshRaises() async throws {
        try await withWorld { world in
            await AccountManager.shared.markAuthFailed(world.accountA.id)
            await world.setFailing(true)
            await InboxViewModel(folders: [world.inboxA, world.inboxB]).refreshSync()
            #expect(banner == InboxErrorBanner.genericMessage,
                    "a refresh cannot attribute its error, so a marked account's other failure must raise")
        }
    }
}
