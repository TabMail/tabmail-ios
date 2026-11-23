import Foundation
import GRDB
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// Sync timing promises 4, 5 and 6 through the app's real scheduler (#1331, #1327).
/// The production `ForegroundPollStart` calls `SyncScheduler.shared.startForegroundPolling`,
/// and real IMAP accounts go live through the app's own entry points against a fake IMAP
/// server (`connectAccount` as RootView's connect loop calls it, `addIMAPAccount` as the
/// add screen calls it, `updatePassword` as the re-sign-in prompt calls it), with no
/// scene-phase change at any point:
/// - a foreground start begins stage 1, then the poll's pass, and installs the poll timer;
/// - every IMAP provider gets IDLE while foreground polling is on, whether it went live
///   before the start or after it (IDLE follows the provider);
/// - a connect while foreground polling is off starts no IDLE;
/// - a cold launch's first connect that fails for now still gets IDLE, which comes up
///   once the server answers; a refused password gets none;
/// - a password refused while the app is open gets one IDLE sign-in and no retry, a
///   return skips that account while a working one keeps IDLE, and the password update
///   brings its IDLE back; a refusal for now keeps IDLE's 10 s retry, also when it
///   refuses the sign-in SwiftMail repeats inside a command on a dropped connection,
///   and a refusal of the password there stops IDLE too (#1349);
/// - a provider started twice keeps one IDLE connection;
/// - an IDLE event reads now: EXISTS reads the new message, VANISHED deletes the one it
///   names (the event handler `startIdle(for:)` installs);
/// - every place that makes a connected mail provider live hands it to the scheduler.
///
/// Isolation: the scheduler's `foregroundWorkHook` records each piece of work a start
/// begins and takes it instead of running it, so stage 1 and the poll never sync, cancel
/// the shared queues or resubscribe push (their reads are pinned by `SyncFollowUpTests`
/// and `OneSyncAtATimeTests`). "stage 1" and "poll" are offered at the entry of
/// `syncStartup` and `poll`, so a record means the start reached them. The hook also takes
/// the IDLE start of any account that is not this test's, so another suite's connect never
/// starts a real IDLE here. `.processGlobalState`: the suite installs its own app
/// database and sets the shared scheduler's hooks and the IMAP TLS override. Every test
/// stops the shared scheduler's polling in its teardown.
@MainActor
@Suite("A foreground start begins stage 1, the poll timer and IDLE, and IDLE follows every provider that goes live", .serialized, .processGlobalState)
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

        /// An IMAP account on the fake server added the way the add screen adds one:
        /// `addIMAPAccount` connects it, stores it and makes its provider live.
        func addThroughSetup() async throws -> Account {
            let account = try await AccountManager.shared.addIMAPAccount(
                displayName: "Poll start fixture",
                email: "poll-start-\(UUID().uuidString.prefix(8))@example.com",
                username: server.username, password: server.password,
                imapHost: "127.0.0.1", imapPort: server.port,
                smtpHost: "127.0.0.1", smtpPort: server.port)
            accounts.append(account)
            return account
        }

        func removeAccount(_ account: Account) async throws {
            await AccountManager.shared.disconnectAccount(account)
            let accountId = account.id
            _ = try await pool.write { db in try Account.deleteOne(db, key: accountId) }
        }

        /// The UIDs of the account's stored inbox rows.
        func inboxUIDs(_ account: Account) -> Set<String> {
            let uids = try? pool.read { db -> [String] in
                guard let inbox = try Folder
                    .filter(Column("accountId") == account.id && Column("role") == FolderRole.inbox.rawValue)
                    .fetchOne(db) else { return [] }
                return try MessageHeader.filter(Column("folderId") == inbox.id).fetchAll(db).map(\.messageId)
            }
            return Set(uids ?? [])
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

    @Test("The first account added in an active scene starts stage 1, the poll and its timer, and IDLE for its provider")
    func firstAccount() async throws {
        try await withWorld { world in
            let state = ScreenState(accounts: 0)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            await settle()
            let nothingYet = world.count("stage 1") == 0 && !world.scheduler.foregroundPollingIsOn
            #expect(nothingYet, "no account, no start: \(world.works)")

            // The add screen's add makes the provider live, then the account list
            // refreshes (`.backgroundDataDidChange`) and the screen sees an account.
            let account = try await world.addThroughSetup()
            state.accounts = 1
            let herdDone = await eventually { world.count("poll") == 1 }
            #expect(herdDone, "the first account started stage 1 and the poll's pass (#1327)")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 1)
            #expect(world.scheduler.foregroundPollingIsOn, "the first account installed the poll timer")
            let idle = await eventually { world.idleStarts(account) == 1 }
            #expect(idle, "the first account's provider got IDLE")
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

            // The timer is already on, so the start returns before its own IDLE
            // start: the add's hand-off is what gives the new provider IDLE.
            let next = try await world.addThroughSetup()
            state.accounts = 1
            let restarted = await eventually { world.count("poll") == 2 }
            #expect(restarted, "the re-added account started stage 1 and the poll's pass again")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 2)
            let idle = await eventually { world.idleStarts(next) == 1 }
            #expect(idle, "the re-added account's provider got IDLE although the timer was already on")
        }
    }

    @Test("A second account added in the open app gets IDLE, and starts no second stage 1")
    func secondAccount() async throws {
        try await withWorld { world in
            let first = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.count("poll") == 1 && world.idleStarts(first) == 1 }
            try #require(started)

            let second = try await world.addThroughSetup()
            state.accounts = 2
            let idle = await eventually { world.idleStarts(second) == 1 }
            #expect(idle, "the second account's provider got IDLE when the add made it live")
            let stageOnes = world.count("stage 1")
            #expect(stageOnes == 1, "a second account is not a start: \(world.works)")
        }
    }

    @Test("A password update (the re-sign-in prompt) gives the provider it makes live IDLE")
    func passwordUpdate() async throws {
        try await withWorld { world in
            let account = try await world.addAccount(connect: true)
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let started = await eventually { world.idleStarts(account) == 1 }
            try #require(started)

            let replaced = await AccountManager.shared.provider(for: account)
            try await AccountManager.shared.updatePassword(world.server.password, for: account)
            let idle = await eventually { world.idleStarts(account) == 2 }
            #expect(idle, "the provider the password update made live got IDLE")
            try? await replaced?.disconnect()
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

    @Test("A cold launch whose first connect fails for now still gets IDLE once the server answers; one whose password is refused gets none")
    func failedFirstConnect() async throws {
        try await withWorld(realIdle: true) { world in
            let server = world.server
            let manager = AccountManager.shared
            // A cold launch whose start looked for providers before RootView's
            // connect loop installed them.
            let forNow = try await world.addAccount(connect: false)
            let refused = try await world.addAccount(connect: false)
            let state = ScreenState(accounts: 2)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let on = await eventually { world.scheduler.foregroundPollingIsOn }
            try #require(on)
            await settle()
            let sweptNone = world.idleStarts(forNow) == 0 && world.idleStarts(refused) == 0
            #expect(sweptNone, "precondition: the start's IDLE found no provider")

            // Refused for now, twice: the account's connect, then IDLE's first launch.
            // The provider stays installed, and IDLE's own launch retry brings it up
            // once the server answers.
            server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Try again later")
            server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Try again later")
            var failedForNow = false
            do { try await manager.connectAccount(forNow) } catch { failedForNow = true }
            #expect(failedForNow, "precondition: the first connect was refused for now")
            let forNowMarked = await manager.authFailedAccounts.contains(forNow.id)
            #expect(!forNowMarked, "precondition: a refusal for now is not a refused sign-in")
            let launchRefused = await eventually(seconds: 5) { server.consumedInjectedFailureCount() == 2 }
            #expect(launchRefused, "precondition: IDLE's first launch was refused as well")
            let notLiveYet = !server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            #expect(notLiveYet, "precondition: IDLE was not live after its first launch failed")
            let live = await eventually(seconds: 20) {
                server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            }
            #expect(live, "IDLE's own retry brought it up once the server answered, with no return to the app")
            let forNowIdle = world.idleStarts(forNow)
            #expect(forNowIdle == 1)

            // A refused password: nothing is handed off, so IDLE never retries it.
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var refusedSignIn = false
            do { try await manager.connectAccount(refused) } catch { refusedSignIn = true }
            #expect(refusedSignIn, "precondition: the sign-in was refused")
            let refusedMarked = await manager.authFailedAccounts.contains(refused.id)
            #expect(refusedMarked, "precondition: the refusal reached the sign-in record")
            await settle()
            await settle()
            let refusedIdle = world.idleStarts(refused)
            #expect(refusedIdle == 0, "a refused sign-in started IDLE, which would retry the refused password")
        }
    }

    // MARK: - A refused password never keeps IDLE signing in (#1349)

    /// A password the server refuses while the app is open: IDLE's sign-in is refused
    /// once and IDLE stops, with no retry every 10 s; a return to the app starts IDLE
    /// for the account whose password works and skips the refused one; the password
    /// update brings the refused account's IDLE back.
    @Test("A refused password gets one IDLE sign-in and no retry, a return skips it while a working account keeps IDLE, and a password update brings its IDLE back")
    func refusedPasswordStopsIdle() async throws {
        try await withWorld(realIdle: true) { world in
            let server = world.server
            let manager = AccountManager.shared
            func logins() -> Int { server.recordedCommands().filter { $0.hasPrefix("LOGIN") }.count }
            func idleCommands() -> Int { server.recordedCommands().filter { $0.hasPrefix("IDLE") }.count }
            // The refused account connected while its password worked; the working
            // one connects after the start.
            let refused = try await world.addAccount(connect: true)
            let working = try await world.addAccount(connect: false)

            // The password stops working before IDLE signs in: the start's IDLE
            // sign-in is refused.
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            let state = ScreenState(accounts: 2)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let refusedOnce = await eventually(seconds: 5) { server.consumedInjectedFailureCount() == 1 }
            try #require(refusedOnce, "precondition: IDLE's sign-in was refused")
            await settle()
            let marked = await manager.authFailedAccounts.contains(refused.id)
            #expect(marked, "the refusal reached the sign-in record")
            let loginsAfterRefusal = logins()

            // Past IDLE's 10 s retry: no second sign-in with the refused password.
            try? await Task.sleep(for: .seconds(12))
            let retried = logins() - loginsAfterRefusal
            #expect(retried == 0, "IDLE signed in \(retried) more time(s) with the refused password")
            let liveOnRefused = idleCommands()
            #expect(liveOnRefused == 0, "IDLE went live after its sign-in was refused")

            // IDLE is no longer wanted: the teardown of a return to the app
            // (`markDirty`), which relaunches a wanted IDLE, starts nothing.
            let installed = await manager.provider(for: refused) as? IMAPProvider
            let refusedProvider = try #require(installed, "precondition: the refused account's provider stayed installed")
            await refusedProvider.markDirty()
            try? await Task.sleep(for: .seconds(1))
            let loginsAfterTeardown = logins() - loginsAfterRefusal
            #expect(loginsAfterTeardown == 0, "a teardown relaunched IDLE with the refused password")
            let liveAfterTeardown = idleCommands()
            #expect(liveAfterTeardown == 0, "a teardown brought IDLE back for the refused account")

            // The working account goes live in the open app and gets IDLE.
            try await manager.connectAccount(working)
            let workingLive = await eventually(seconds: 5) { idleCommands() == 1 }
            #expect(workingLive, "the working account's IDLE went live")

            // A return to the app: the start's IDLE covers the working account and
            // skips the refused one.
            world.scheduler.stopPolling()
            await settle()
            world.scheduler.startForegroundPolling()
            let workingAgain = await eventually(seconds: 5) { world.idleStarts(working) == 2 }
            #expect(workingAgain, "the return started the working account's IDLE")
            await settle()
            let refusedStarts = world.idleStarts(refused)
            #expect(refusedStarts == 1, "the return started IDLE for the refused account (\(refusedStarts) starts)")

            // The password update: the refused account's IDLE comes back.
            let replaced = await manager.provider(for: refused)
            try await manager.updatePassword(server.password, for: refused)
            let back = await eventually(seconds: 5) { idleCommands() == 2 }
            #expect(back, "the password update brought the refused account's IDLE back")
            let refusedStartsAfterUpdate = world.idleStarts(refused)
            #expect(refusedStartsAfterUpdate == 2)
            try? await replaced?.disconnect()
        }
    }

    @Test("IDLE whose sign-in is refused for now keeps its 10 s retry until the server answers")
    func refusedForNowKeepsRetrying() async throws {
        try await withWorld(realIdle: true) { world in
            let server = world.server
            let account = try await world.addAccount(connect: true)
            // IDLE's first two sign-ins are refused for now.
            server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Try again later")
            server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Try again later")
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let first = await eventually(seconds: 5) { server.consumedInjectedFailureCount() == 1 }
            try #require(first, "precondition: IDLE's first sign-in was refused for now")
            let firstAt = ContinuousClock.now
            let second = await eventually(seconds: 15) { server.consumedInjectedFailureCount() == 2 }
            #expect(second, "IDLE retried after its first refusal for now")
            let secondAt = ContinuousClock.now
            let live = await eventually(seconds: 15) {
                server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            }
            #expect(live, "IDLE kept retrying until the server answered")
            let liveAt = ContinuousClock.now
            // Each retry waits its 10 s: none comes early.
            let firstGap = secondAt - firstAt
            #expect(firstGap >= .seconds(9), "IDLE retried \(firstGap) after the first refusal for now")
            let secondGap = liveAt - secondAt
            #expect(secondGap >= .seconds(9), "IDLE retried \(secondGap) after the second refusal for now")
            let marked = await AccountManager.shared.authFailedAccounts.contains(account.id)
            #expect(!marked, "a refusal for now is not a refused sign-in")
            let starts = world.idleStarts(account)
            #expect(starts == 1, "the retries are IDLE's own, not new starts")
        }
    }

    /// The sign-in SwiftMail repeats inside a command, when it reopens a connection that
    /// dropped, can be refused for now too. That refusal arrives as a raw `loginFailed`,
    /// not as `createServer`'s `ProviderTemporaryRefusal`, and must keep IDLE's retry
    /// like any other refusal for now.
    @Test("IDLE whose connection drops before its INBOX select, and whose repeated sign-in is refused for now, retries and comes up")
    func reconnectRefusedForNowKeepsRetrying() async throws {
        try await withWorld(realIdle: true) { world in
            let server = world.server
            let account = try await world.addAccount(connect: true)
            let installed = await AccountManager.shared.provider(for: account) as? IMAPProvider
            let provider = try #require(installed, "precondition: the account's provider is installed")
            // IDLE's first launch: once its sign-in is accepted, the server refuses the
            // next sign-in for now and drops the connection before the INBOX select, so
            // the select reopens it and signs in again.
            let launches = Mutex(0)
            await provider.setIdleLaunchPlantRaceTestHookForTesting {
                let first = launches.withLock { (n: inout Int) -> Bool in n += 1; return n == 1 }
                guard first else { return }
                server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Try again later")
                server.dropLastLoggedInSession()
                // Long enough for the client to see the connection closed.
                try? await Task.sleep(for: .milliseconds(500))
            }
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let refused = await eventually(seconds: 5) { server.consumedInjectedFailureCount() == 1 }
            try #require(refused, "precondition: the repeated sign-in inside the select was refused for now")
            let refusedAt = ContinuousClock.now
            let notLiveYet = !server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            #expect(notLiveYet, "precondition: IDLE was not live after its select failed")
            let live = await eventually(seconds: 15) {
                server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            }
            #expect(live, "IDLE stopped after a refusal for now of its repeated sign-in")
            let gap = ContinuousClock.now - refusedAt
            #expect(gap >= .seconds(9), "IDLE came back \(gap) after the refusal, before its 10 s retry")
            let marked = await AccountManager.shared.authFailedAccounts.contains(account.id)
            #expect(!marked, "a refusal for now is not a refused sign-in")
            let starts = world.idleStarts(account)
            #expect(starts == 1, "the retry is IDLE's own, not a new start")
            await provider.setIdleLaunchPlantRaceTestHookForTesting(nil)
        }
    }

    /// The same repeated sign-in, refused for the password: it arrives after IDLE's
    /// launch claimed its connection, and stops IDLE as a refusal at the first sign-in
    /// does.
    @Test("IDLE whose connection drops before its INBOX select, and whose repeated sign-in is refused for the password, stops with no retry")
    func reconnectRefusedPasswordStopsIdle() async throws {
        try await withWorld(realIdle: true) { world in
            let server = world.server
            func logins() -> Int { server.recordedCommands().filter { $0.hasPrefix("LOGIN") }.count }
            func idleCommands() -> Int { server.recordedCommands().filter { $0.hasPrefix("IDLE") }.count }
            let account = try await world.addAccount(connect: true)
            let installed = await AccountManager.shared.provider(for: account) as? IMAPProvider
            let provider = try #require(installed, "precondition: the account's provider is installed")
            // IDLE's first launch: once its sign-in is accepted, the server refuses the
            // next sign-in for the password and drops the connection before the INBOX
            // select, so the select reopens it and signs in again.
            let launches = Mutex(0)
            await provider.setIdleLaunchPlantRaceTestHookForTesting {
                let first = launches.withLock { (n: inout Int) -> Bool in n += 1; return n == 1 }
                guard first else { return }
                server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
                server.dropLastLoggedInSession()
                // Long enough for the client to see the connection closed.
                try? await Task.sleep(for: .milliseconds(500))
            }
            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let refused = await eventually(seconds: 5) { server.consumedInjectedFailureCount() == 1 }
            try #require(refused, "precondition: the repeated sign-in inside the select was refused")
            await settle()
            await settle()
            let slotCleared = await provider.currentIdleServerForTesting() == nil
            #expect(slotCleared, "the claimed IDLE connection stayed in its slot after the refusal")
            let loginsAfterRefusal = logins()

            // Past IDLE's 10 s retry: no further sign-in, and IDLE never goes live.
            try? await Task.sleep(for: .seconds(12))
            let retried = logins() - loginsAfterRefusal
            #expect(retried == 0, "IDLE signed in \(retried) more time(s) after the password was refused")
            let live = idleCommands()
            #expect(live == 0, "IDLE went live after its repeated sign-in was refused")

            // IDLE is no longer wanted: a teardown (`markDirty`) starts nothing.
            await provider.markDirty()
            try? await Task.sleep(for: .seconds(1))
            let loginsAfterTeardown = logins() - loginsAfterRefusal
            #expect(loginsAfterTeardown == 0, "a teardown relaunched IDLE after the password was refused")
            let liveAfterTeardown = idleCommands()
            #expect(liveAfterTeardown == 0, "a teardown brought IDLE back after the password was refused")
            let starts = world.idleStarts(account)
            #expect(starts == 1)
            await provider.setIdleLaunchPlantRaceTestHookForTesting(nil)
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

    // MARK: - An IDLE event reads now

    /// The event handler the scheduler gives IDLE (`startIdle(for:)`), with a real
    /// IDLE session on the fake server: a new message (EXISTS) is read at once, not at
    /// the next poll; a VANISHED deletes the messages it names even while another pass
    /// holds the account, and its read then asks for the follow-up (promises 1 and 6).
    @Test("An IDLE event reads now: EXISTS reads the new message; VANISHED deletes the one it names and, with the account busy, asks for a follow-up")
    func idleEventsRead() async throws {
        try await withWorld(realIdle: true) { world in
            let wasConnected = NetworkMonitor.checkConnected()
            NetworkMonitor.setConnectedForTesting(true)
            defer { NetworkMonitor.setConnectedForTesting(wasConnected) }
            let server = world.server
            server.setMessages([Self.message(uid: 1)], in: "INBOX")
            let account = try await world.addThroughSetup()
            let synced = await eventually(seconds: 15) { world.inboxUIDs(account) == ["1"] }
            try #require(synced, "precondition: the add's initial sync read the inbox")
            // The initial sync's turn ends before the events below, so the EXISTS
            // read finds the account free.
            await AccountManager.shared.syncEngine.oneSyncAtATime(accountId: account.id) { @Sendable in }
            // That sync ended by starting the account's older-mail worker
            // (`startBackfill`), whose catch-up also lists the inbox and would read
            // the new message below on its own: stop it, so only the event can.
            await AccountManager.shared.syncEngine.stopBackfillWorkerForTesting(accountId: account.id)

            let state = ScreenState(accounts: 1)
            let window = try Self.host(state, start: { world.scheduler.startForegroundPolling() })
            defer { Self.close(window) }
            let idling = await eventually(seconds: 10) {
                server.recordedCommands().contains { $0.hasPrefix("IDLE") }
            }
            try #require(idling, "precondition: the start's IDLE is live on the fake server")

            // A new message. The start's own poll pass was taken, the older-mail
            // worker is stopped and the timer's next tick is 300 s away, so only the
            // event's read brings it in.
            server.setMessages(server.messages(in: "INBOX") + [Self.message(uid: 2)], in: "INBOX")
            let toldExists = server.notifyIdleSessions("* 2 EXISTS")
            #expect(toldExists == 1)
            let read = await eventually(seconds: 15) { world.inboxUIDs(account).contains("2") }
            #expect(read, "the EXISTS event read the new message now (#1331)")

            // A deletion while another pass holds the account: the event's read can
            // only ask for a follow-up, so a row gone now was deleted by the event.
            let followUp = "stage 2: follow-up \(account.id)"
            let followUpsBefore = world.count(followUp)
            let (entered, enter) = AsyncStream<Void>.makeStream()
            let (release, open) = AsyncStream<Void>.makeStream()
            let holder = Task {
                await AccountManager.shared.syncEngine.oneSyncAtATime(accountId: account.id) { @Sendable in
                    enter.yield()
                    for await _ in release { break }
                }
            }
            for await _ in entered { break }
            server.setMessages(server.messages(in: "INBOX").filter { $0.uid != 1 }, in: "INBOX")
            let toldVanished = server.notifyIdleSessions("* VANISHED 1")
            #expect(toldVanished == 1)
            let deleted = await eventually(seconds: 10) { !world.inboxUIDs(account).contains("1") }
            #expect(deleted, "the VANISHED event deleted the message it named while the account was busy")
            let flagged = await eventually(seconds: 10) { world.count(followUp) == followUpsBefore + 1 }
            #expect(flagged, "the VANISHED event's read found the account busy and asked for a follow-up")
            open.yield()
            open.finish()
            await holder.value
        }
    }

    /// A plain message for the fake server's inbox, dated relative to now.
    private static func message(uid: Int) -> FakeIMAPServer.Message {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date().addingTimeInterval(-Double(10 - uid) * 60))
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: idle event \(uid)\r
            Date: \(date)\r
            Message-ID: <idle-event-\(uid)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            idle event fixture body.\r

            """)
    }

    // MARK: - Every live install hands off

    /// IDLE follows the provider: every place that makes a connected mail provider
    /// the account's live one (writes `providers[...]`, or installs an accepted
    /// password probe) calls `liveProviderConnected`. A new install site that skips
    /// it fails here. Exempt: the demo providers (no IMAP) and the test seams.
    @Test("Every place that makes a connected mail provider live hands it to the scheduler")
    func everyLiveInstallHandsOff() throws {
        let exempt: Set<String> = [
            "registerDemoProviders", "registerProviderForTesting", "connectProviderForTesting",
            // Its callers are checked instead (it installs; they hand off).
            "installAcceptedPasswordProbeAsLive",
        ]
        let install = try Regex(#"providers\[[^\]]+\]\s*=[^=]|installAcceptedPasswordProbeAsLive\("#)
        let memberFunc = try Regex(#"^    (?:[A-Za-z@][A-Za-z()]* )*func ([A-Za-z0-9_]+)"#)
        var installers: [String: Bool] = [:]
        let dir = Self.projectRoot.appendingPathComponent("TabMail/Services/Account")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
            var current: (name: String, body: [String])?
            func recordCurrent() {
                guard let current else { return }
                let body = current.body.joined(separator: "\n")
                guard !exempt.contains(current.name), body.contains(install) else { return }
                installers[current.name] = body.contains("liveProviderConnected(")
            }
            for line in lines {
                if let match = line.firstMatch(of: memberFunc), let funcName = match.output[1].substring {
                    recordCurrent()
                    current = (String(funcName), [])
                } else {
                    current?.body.append(line)
                }
            }
            recordCurrent()
        }
        let known: Set<String> = ["connectAccount", "addIMAPAccount", "addICloudAccount", "updatePassword"]
        let found = Set(installers.keys)
        #expect(known.isSubset(of: found), "the scan found the install sites: \(installers)")
        let skipping = installers.filter { !$0.value }.map(\.key).sorted()
        #expect(skipping.isEmpty, "these make a provider live without handing it to the scheduler: \(skipping)")
    }

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
                // `addIMAPAccount` starts the account's initial sync; taking the
                // account's turn waits for it to end before the account goes.
                await manager.syncEngine.oneSyncAtATime(accountId: account.id) { @Sendable in }
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
