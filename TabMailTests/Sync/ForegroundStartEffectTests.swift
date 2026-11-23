import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Sync timing promises 4, 5 and 6 through the app's real scheduler (#1331, #1327).
/// The production `ForegroundPollStart` calls `SyncScheduler.shared.startForegroundPolling`,
/// and real IMAP accounts connect through `AccountManager.connectAccount` against a fake
/// IMAP server, with no scene-phase change at any point:
/// - a foreground start begins stage 1, then the poll's pass, and installs the poll timer;
/// - every IMAP provider gets IDLE while foreground polling is on, whether it connected
///   before the start or after it (IDLE follows the provider);
/// - a connect while foreground polling is off starts no IDLE;
/// - a provider started twice keeps one IDLE connection.
///
/// Isolation: the scheduler's `foregroundWorkHook` records each piece of work a start
/// begins and takes it instead of running it, so stage 1 and the poll never sync, cancel
/// the shared queues or resubscribe push (their reads are pinned by `SyncFollowUpTests`
/// and `OneSyncAtATimeTests`). The hook also takes the IDLE start of any account that is
/// not this test's, so another suite's connect never starts a real IDLE here. Every test
/// stops the shared scheduler's polling in its teardown.
@MainActor
@Suite("A foreground start begins stage 1, the poll timer and IDLE, and IDLE follows every provider that connects", .serialized)
struct ForegroundStartEffectTests {

    @MainActor final class World {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let server: FakeIMAPServer
        let scheduler = SyncScheduler.shared
        /// Every piece of work offered to the hook, in order, this test's or not.
        var works: [String] = []
        var accounts: [Account] = []
        /// When true, this test's accounts run their real IDLE (the hook does not take it).
        let realIdle: Bool

        init(pool: DatabasePool, dir: URL, previous: AppDatabase?, server: FakeIMAPServer, realIdle: Bool) {
            self.pool = pool
            self.dir = dir
            self.previous = previous
            self.server = server
            self.realIdle = realIdle
        }

        func count(_ work: String) -> Int { works.filter { $0 == work }.count }
        func idleStarts(_ account: Account) -> Int { count("IDLE \(account.id)") }

        func takes(_ work: String) -> Bool {
            works.append(work)
            guard realIdle else { return true }
            return !accounts.contains { work == "IDLE \($0.id)" }
        }

        /// An IMAP account on the fake server, stored and with its password in the
        /// Keychain; connected now through `connectAccount` when `connect` is true.
        func addAccount(connect: Bool) async throws -> Account {
            var account = Account(
                emailAddress: "poll-start-\(UUID().uuidString.prefix(8))@example.com",
                displayName: "Poll start fixture", provider: .imap)
            account.imapHost = "127.0.0.1"
            account.imapPort = server.port
            account.imapUsername = server.username
            let stored = account
            try await pool.write { db in try stored.insert(db) }
            try KeychainHelper.save(server.password, for: KeychainHelper.passwordKey(accountId: account.id))
            accounts.append(account)
            if connect { try await AccountManager.shared.connectAccount(account) }
            return account
        }

        func removeAccount(_ account: Account) async throws {
            await AccountManager.shared.disconnectAccount(account)
            let accountId = account.id
            _ = try await pool.write { db in try Account.deleteOne(db, key: accountId) }
        }
    }

    @MainActor @Observable
    final class ScreenState {
        var phase: ScenePhase = .active
        var accounts: Int
        init(accounts: Int) { self.accounts = accounts }
    }

    private struct Probe: View {
        let state: ScreenState
        let start: @MainActor () -> Void

        var body: some View {
            Text("accounts \(state.accounts)")
                .modifier(ForegroundPollStart(
                    hasAccounts: state.accounts > 0, screenshotMode: false, start: start))
                .environment(\.scenePhase, state.phase)
        }
    }

    // MARK: - The two cases the fix is for

    @Test("A view that mounts in an active scene starts stage 1, the poll and its timer, and IDLE for a provider connected before the start and one connected after it")
    func coldLaunch() async throws {
        try await withWorld { world in
            let early = try await world.addAccount(connect: true)
            let late = try await world.addAccount(connect: false)
            let earlyIdleBeforeStart = world.idleStarts(early)
            #expect(earlyIdleBeforeStart == 0, "precondition: a connect with polling off starts no IDLE")

            let state = ScreenState(accounts: 2)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }

            let herdDone = await eventually { world.count("poll") == 1 }
            #expect(herdDone, "the start ran the poll's pass")
            let ordered: Bool
            if let stageOne = world.works.firstIndex(of: "stage 1"), let poll = world.works.firstIndex(of: "poll") {
                ordered = stageOne < poll
            } else {
                ordered = false
            }
            #expect(ordered, "stage 1 starts before the poll's pass: \(world.works)")
            #expect(world.scheduler.foregroundPollingIsOn, "the start installed the poll timer")
            let earlyIdle = await eventually { world.idleStarts(early) == 1 }
            #expect(earlyIdle, "the provider connected before the start got IDLE")
            let lateIdleBeforeConnect = world.idleStarts(late)
            #expect(lateIdleBeforeConnect == 0, "precondition: the late provider had not connected")

            try await AccountManager.shared.connectAccount(late)
            let lateIdle = await eventually { world.idleStarts(late) == 1 }
            #expect(lateIdle, "a provider that connects after the foreground start gets IDLE (#1331)")
        }
    }

    @Test("The first account added in an active scene starts stage 1, the poll and its timer, and IDLE once its provider connects")
    func firstAccount() async throws {
        try await withWorld { world in
            let state = ScreenState(accounts: 0)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            await settle()
            let nothingYet = world.count("stage 1") == 0 && !world.scheduler.foregroundPollingIsOn
            #expect(nothingYet, "no account, no start: \(world.works)")

            // Adding an account refreshes the account list before it connects.
            let account = try await world.addAccount(connect: false)
            state.accounts = 1
            let herdDone = await eventually { world.count("poll") == 1 }
            #expect(herdDone, "the first account started stage 1 and the poll's pass (#1327)")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 1)
            #expect(world.scheduler.foregroundPollingIsOn, "the first account installed the poll timer")

            try await AccountManager.shared.connectAccount(account)
            let idle = await eventually { world.idleStarts(account) == 1 }
            #expect(idle, "the first account's provider got IDLE when it connected")
        }
    }

    // MARK: - IDLE follows every provider that connects while polling is on

    @Test("An account added after the last was removed gets stage 1 again and IDLE, with no phase change")
    func reAddAfterTheLastWasRemoved() async throws {
        try await withWorld { world in
            let first = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.count("poll") == 1 && world.idleStarts(first) == 1 }
            try #require(started)

            try await world.removeAccount(first)
            state.accounts = 0
            await settle()
            #expect(world.scheduler.foregroundPollingIsOn, "removing the last account leaves the poll timer on")

            let next = try await world.addAccount(connect: false)
            state.accounts = 1
            let restarted = await eventually { world.count("poll") == 2 }
            #expect(restarted, "the re-added account started stage 1 and the poll's pass again")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 2)
            try await AccountManager.shared.connectAccount(next)
            let idle = await eventually { world.idleStarts(next) == 1 }
            #expect(idle, "the re-added account's provider got IDLE although the timer was already on")
        }
    }

    @Test("A second account added in the open app gets IDLE when it connects, and starts no second stage 1")
    func secondAccount() async throws {
        try await withWorld { world in
            let first = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.count("poll") == 1 && world.idleStarts(first) == 1 }
            try #require(started)

            let second = try await world.addAccount(connect: false)
            state.accounts = 2
            try await AccountManager.shared.connectAccount(second)
            let idle = await eventually { world.idleStarts(second) == 1 }
            #expect(idle, "the second account's provider got IDLE when it connected")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 1, "a second account is not a start: \(world.works)")
        }
    }

    @Test("A reconnect (a re-sign-in or a settings change) gives the new provider IDLE")
    func reconnect() async throws {
        try await withWorld { world in
            let account = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.idleStarts(account) == 1 }
            try #require(started)

            // The re-sign-in and settings paths in AccountManagerSetup: disconnect, then connect.
            await AccountManager.shared.disconnectAccount(account)
            try await AccountManager.shared.connectAccount(account)
            let idle = await eventually { world.idleStarts(account) == 2 }
            #expect(idle, "the reconnected provider got IDLE")
        }
    }

    @Test("A connect while foreground polling is off starts no IDLE, before any start and after the app left")
    func connectWithPollingOffStartsNoIdle() async throws {
        try await withWorld { world in
            #expect(!world.scheduler.foregroundPollingIsOn, "precondition: polling is off")
            let before = try await world.addAccount(connect: true)
            await settle()
            let idleBefore = world.idleStarts(before)
            #expect(idleBefore == 0, "a connect before any foreground start started IDLE")

            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.count("poll") == 1 }
            try #require(started)

            // Going to the background: RootView's scene-phase handler stops polling.
            state.phase = .background
            world.scheduler.stopPolling()
            let after = try await world.addAccount(connect: true)
            await settle()
            let idleAfter = world.idleStarts(after)
            #expect(idleAfter == 0, "a connect after the app left started IDLE")
        }
    }

    // MARK: - One IDLE connection per provider

    @Test("A provider whose IDLE is started twice, while launching and once live, keeps one IDLE connection")
    func oneIdleConnectionPerProvider() async throws {
        try await withWorld(realIdle: true) { world in
            let account = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let on = await eventually { world.scheduler.foregroundPollingIsOn }
            try #require(on)

            // The start's IDLE and a connect's hand-off for the same provider, at once.
            await world.scheduler.accountConnected(account)
            let server = world.server
            let live = await eventually(seconds: 5) {
                server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            }
            #expect(live, "IDLE started on the fake server")

            // And once more while it is live.
            await world.scheduler.accountConnected(account)
            await settle()
            await settle()
            let idleCommands = server.recordedCommands().filter { $0.hasPrefix("IDLE") }.count
            let idleConnections = server.commandLogByConnection.values
                .filter { log in log.contains { $0.hasPrefix("IDLE") } }.count
            #expect(idleCommands == 1, "IDLE was sent \(idleCommands) times")
            #expect(idleConnections == 1, "\(idleConnections) connections ran IDLE")
        }
    }

    // MARK: - Harness

    private func withWorld(realIdle: Bool = false, _ body: (World) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        let manager = AccountManager.shared
        manager.setIMAPUseTLSOverrideForTesting(false)
        let world = World(pool: pool, dir: dir, previous: previous, server: server, realIdle: realIdle)
        let scheduler = world.scheduler
        let saved = (scheduler.applicationStateForTesting, scheduler.foregroundReadinessHook,
                     scheduler.stageTwoHook, scheduler.foregroundWorkHook)
        scheduler.applicationStateForTesting = .active
        scheduler.foregroundReadinessHook = { true }
        scheduler.stageTwoHook = { trigger in world.works.append("stage 2: \(trigger)") }
        scheduler.foregroundWorkHook = { work in world.takes(work) }

        func tearDown() async {
            // A test that starts the shared scheduler's polling stops it, so the
            // IDLE a connect starts cannot reach a later test.
            scheduler.stopPolling()
            for account in world.accounts {
                if let provider = await manager.provider(for: account) as? IMAPProvider {
                    await provider.stopIdle()
                    try? await provider.disconnect()
                }
                await manager.unregisterProviderForTesting(accountId: account.id)
                await manager.syncEngine.remove(accountId: account.id)
                await manager.clearAuthFailed(account.id)
                KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: account.id))
            }
            scheduler.applicationStateForTesting = saved.0
            scheduler.foregroundReadinessHook = saved.1
            scheduler.stageTwoHook = saved.2
            scheduler.foregroundWorkHook = saved.3
            manager.setIMAPUseTLSOverrideForTesting(nil)
            server.stop()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        do {
            try await body(world)
        } catch {
            await tearDown()
            throw error
        }
        await tearDown()
    }

    private static func host(_ state: ScreenState, start: @escaping @MainActor () -> Void) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "a window scene to host the probe")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.rootViewController = UIHostingController(rootView: Probe(state: state, start: start))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Long enough for SwiftUI to apply a state change and for a hand-off to land.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func eventually(seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
