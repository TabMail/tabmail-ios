/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-121 (#1450): the one-time database upgrade the user starts pauses polling
/// and the body, AI and embedding queues for its rewrite, and turns everything back on
/// at every exit while the app is active: done, failed, short of space. An exit while
/// the app is in the background (the user left mid-rewrite: done in the background
/// time, or rolled back by a suspension) starts nothing; the return to the app turns
/// everything on through RootView's `ForegroundPollStart` (its `start` calls
/// `startForegroundPolling` on every change to an active scene), which the tests below stand for
/// by calling `startForegroundPolling` on the return, and a rolled-back upgrade then
/// runs again (`appBecameActive`, from the upgrade screen's scene-phase handler). An
/// Upgrade now refused for lack of room or power pauses nothing.
///
/// Isolation: each test drives its own `DatabaseUpgrade` with a test `SyncScheduler`,
/// whose `foregroundWorkHook` records each piece of work a stop or start begins and
/// takes it instead of running it ("stop IDLE" from `stopPolling`; "stage 1", "poll",
/// "background tasks" from `startForegroundPolling`). The poll timer is real and read
/// with `foregroundPollingIsOn`; a start installs it and then starts IDLE in the same
/// call, so a timer that is on means IDLE was started (which IDLE each provider gets is
/// pinned by `ForegroundStartEffectTests`). "stage 1" and "poll" are offered at the entry
/// of `syncStartup` and `poll`, the sync that refills the queues, so a record means the
/// start reached them; each start's work is let finish (`settle`) before the next, so a
/// later start is never folded into a running one. The rewrite and the databases'
/// states are fakes; the app's state is `DatabaseSuspension.setAppActiveForTesting`,
/// set back to active after each test. `.processGlobalState`: the pause empties the
/// app's shared queues, and the tests set the process-wide app state.
///
/// Upgrade now is also refused for low battery when not charging, runs once however
/// often it is tapped, and runs when only one of the two databases is left to upgrade.
/// A rewrite that runs out of disk space (it rolled back) turns everything back on and
/// shows the notice asking for space.
@MainActor
@Suite("The database upgrade pauses polling and the queues, and turns them back on at every exit", .serialized, .processGlobalState)
struct DatabaseUpgradeTests {

    /// The two databases' mode as the fake rewrite leaves it, the rewrite's answers in
    /// turn, and what each rewrite saw of the scheduler.
    final class FakeDatabases: Sendable {
        private let upgraded = Mutex(false)
        private let emailStartsUpgraded: Bool
        private let answers: Mutex<[[SyncEngine.UpgradeStep]]>
        private let pollingDuringRewrite = Mutex<[Bool]>([])
        private let leaves: Mutex<Bool>
        /// State reads that have started, and how many must start before any returns.
        private let heldReads = Mutex<(started: Int, until: Int)>((0, 0))
        /// Each database's size: tiny, so the device always has room, or huge, so it never does.
        let databaseBytes: Int64
        /// How much of each database's size is empty pages.
        let emptyBytes: Int64

        /// `userLeaves`: the user leaves the app during the first rewrite.
        /// `emailStartsUpgraded`: only the search database is left to upgrade.
        init(
            answers: [[SyncEngine.UpgradeStep]], databaseBytes: Int64 = 4_096, emptyBytes: Int64 = 0,
            userLeaves: Bool = false, emailStartsUpgraded: Bool = false
        ) {
            self.answers = Mutex(answers)
            self.databaseBytes = databaseBytes
            self.emptyBytes = emptyBytes
            self.leaves = Mutex(userLeaves)
            self.emailStartsUpgraded = emailStartsUpgraded
        }

        /// The fake rewrite: records whether polling was on, lets the user leave the
        /// app when told, gives its next answer, and upgrades both databases when every
        /// step of that answer upgraded its database or found it upgraded.
        func rewrite(_ scheduler: SyncScheduler) async -> [SyncEngine.UpgradeStep] {
            let pollingOn = await MainActor.run { scheduler.foregroundPollingIsOn }
            pollingDuringRewrite.withLock { $0.append(pollingOn) }
            if leaves.withLock({ leaves in defer { leaves = false }; return leaves }) {
                DatabaseSuspension.setAppActiveForTesting(false)
            }
            let answer = answers.withLock { $0.isEmpty ? [] : $0.removeFirst() }
            let allUpgraded = !answer.isEmpty && answer.allSatisfy {
                switch $0 {
                case .upgraded, .alreadyUpgraded: true
                default: false
                }
            }
            if allUpgraded {
                upgraded.withLock { $0 = true }
            }
            return answer
        }

        /// The next `count` state reads wait until all of them have started.
        func holdTheNextReads(_ count: Int) {
            heldReads.withLock { $0 = (0, count) }
        }

        func states() async -> [DatabaseUpgrade.DatabaseState] {
            let held = heldReads.withLock { reads -> Bool in
                guard reads.started < reads.until else { return false }
                reads.started += 1
                return true
            }
            while held, heldReads.withLock({ $0.started < $0.until }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let all = upgraded.withLock { $0 }
            let path = FileManager.default.temporaryDirectory.path
            return [all || emailStartsUpgraded, all].map { isUpgraded in
                DatabaseUpgrade.DatabaseState(
                    path: path,
                    state: DatabaseVacuum.SpaceState(
                        autoVacuum: isUpgraded ? DatabaseVacuum.incrementalMode : DatabaseVacuum.noneMode,
                        pageCount: databaseBytes / 4_096, freePages: emptyBytes / 4_096, pageSize: 4_096))
            }
        }

        var pollingSeenByRewrites: [Bool] { pollingDuringRewrite.withLock { $0 } }
    }

    /// The work the scheduler's stop and start offered, in order.
    @MainActor final class Works {
        var all: [String] = []
        func count(_ work: String) -> Int { all.filter { $0 == work }.count }
    }

    /// A foreground test scheduler with polling on, as the app has it on the inbox,
    /// whose stop and start record their work instead of running it.
    private func makeScheduler(_ works: Works) async throws -> SyncScheduler {
        let active = DatabaseSuspension.isAppActive
        try #require(active, "precondition: the test host runs in the foreground")
        let scheduler = SyncScheduler(foreground: true, stageTwo: { works.all.append("stage 2: \($0)") })
        scheduler.foregroundWorkHook = { work in
            works.all.append(work)
            return true
        }
        scheduler.startForegroundPolling()
        _ = await eventually { works.count("poll") == 1 }
        await settle()
        works.all.removeAll()
        return scheduler
    }

    /// The upgrade with its notice open. The battery is unknown by default (as on the
    /// simulator), which asks nothing.
    private func makeUpgrade(
        _ scheduler: SyncScheduler, _ databases: FakeDatabases,
        battery: (level: Float, state: UIDevice.BatteryState) = (-1, .unknown)
    ) async -> DatabaseUpgrade {
        let upgrade = DatabaseUpgrade(
            scheduler: scheduler,
            upgradeDatabases: { await databases.rewrite(scheduler) },
            readStates: { await databases.states() },
            readBattery: { battery })
        await upgrade.openNotice()
        return upgrade
    }

    /// After an exit: the timer is on (so IDLE was started), the start ran once,
    /// and it reached stage 1 and the poll.
    private func expectEverythingBackOn(
        _ scheduler: SyncScheduler, _ works: Works, starts: Int = 1, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let reached = await eventually { works.count("stage 1") == starts && works.count("poll") == starts }
        await settle()
        #expect(scheduler.foregroundPollingIsOn, "the poll timer is on, and with it IDLE", sourceLocation: sourceLocation)
        #expect(works.count("background tasks") == starts, "one start per run: \(works.all)", sourceLocation: sourceLocation)
        #expect(reached, "the start reached stage 1 and the poll, which refill the queues: \(works.all)", sourceLocation: sourceLocation)
        #expect(works.count("stop IDLE") == starts, "one stop per run: \(works.all)", sourceLocation: sourceLocation)
    }

    /// After an exit in the background: nothing was started.
    private func expectNothingStarted(
        _ scheduler: SyncScheduler, _ works: Works, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await settle()
        #expect(!scheduler.foregroundPollingIsOn, "the poll timer stays off, and IDLE with it", sourceLocation: sourceLocation)
        #expect(works.all == ["stop IDLE"], "only the pause ran: \(works.all)", sourceLocation: sourceLocation)
    }

    /// The return to the app as RootView's `ForegroundPollStart` makes it.
    private func returnToTheApp(_ scheduler: SyncScheduler, _ upgrade: DatabaseUpgrade, _ works: Works) async {
        DatabaseSuspension.setAppActiveForTesting(true)
        scheduler.startForegroundPolling()
        _ = await eventually { works.count("poll") == works.count("background tasks") }
        await settle()
        await upgrade.appBecameActive()
    }

    private func tearDown(_ scheduler: SyncScheduler) {
        DatabaseSuspension.setAppActiveForTesting(true)
        scheduler.stopPolling()
        scheduler.foregroundWorkHook = nil
    }

    @Test("Done: the rewrite runs with polling off, then polling, IDLE and the queues are back on, the banner goes and the screen says done")
    func doneTurnsEverythingBackOn() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]])
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()

        #expect(databases.pollingSeenByRewrites == [false], "the rewrite ran once, with polling off: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .done)
        #expect(!upgrade.needsUpgrade, "the banner goes")
    }

    @Test("Failed: polling, IDLE and the queues are back on, the banner stays and the screen says it could not finish")
    func failedTurnsEverythingBackOn() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.failed("email")]])
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()

        #expect(databases.pollingSeenByRewrites == [false])
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .failed)
        #expect(upgrade.needsUpgrade, "the banner stays")
    }

    @Test("Short of space once paused: polling, IDLE and the queues are back on and the screen is the notice again")
    func shortOfSpaceTurnsEverythingBackOn() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.needsSpace("email", bytesToFree: 1)]])
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()

        #expect(databases.pollingSeenByRewrites == [false])
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .notice)
        #expect(upgrade.needsUpgrade, "the banner stays")
    }

    @Test("Out of disk space during the rewrite (it rolled back): polling, IDLE and the queues are back on, the notice asks for space and the banner stays; the next Upgrade now runs and clears the request")
    func aFullDiskTurnsEverythingBackOnAndAsksForSpace() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.ranOutOfSpace("email")], [.upgraded("email"), .upgraded("search")]])
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()

        #expect(databases.pollingSeenByRewrites == [false])
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .notice, "the notice again, not the failure")
        #expect(upgrade.showsSpaceMessage, "the notice asks for space although the check finds room")
        #expect(upgrade.bytesNeeded > 0)
        #expect(upgrade.needsUpgrade, "the banner stays")

        await upgrade.upgradeNow()

        #expect(databases.pollingSeenByRewrites == [false, false], "the second rewrite ran, with polling off: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works, starts: 2)
        #expect(upgrade.screen == .done)
        #expect(!upgrade.showsSpaceMessage, "the request is cleared")
    }

    @Test("Rolled back by a suspension after the user left: nothing is started in the background; the return turns polling, IDLE and the queues on, and the upgrade runs again, paused again, and turns everything back on again")
    func aSuspensionInTheBackgroundStartsNothingUntilTheReturn() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.stopped("email")], [.upgraded("email"), .upgraded("search")]], userLeaves: true)
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()
        let continues = upgrade.continuesOnReturn
        let screenAfterStop = upgrade.screen
        await expectNothingStarted(scheduler, works)
        await returnToTheApp(scheduler, upgrade, works)

        #expect(continues, "the upgrade continues on the app's return")
        #expect(screenAfterStop == .upgrading, "the spinner stays up")
        #expect(databases.pollingSeenByRewrites == [false, false], "both rewrites ran with polling off: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works, starts: 2)
        #expect(upgrade.screen == .done)
        #expect(!upgrade.continuesOnReturn)
    }

    @Test("Done after the user left: nothing is started in the background; the return turns polling, IDLE and the queues on, and no rewrite runs again")
    func doneInTheBackgroundStartsNothingUntilTheReturn() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]], userLeaves: true)
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()
        await expectNothingStarted(scheduler, works)
        await returnToTheApp(scheduler, upgrade, works)

        #expect(databases.pollingSeenByRewrites == [false], "one rewrite: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .done)
    }

    @Test("Upgrade now refused for lack of room: nothing is paused and no rewrite runs")
    func aRefusedUpgradePausesNothing() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]], databaseBytes: 1 << 60)
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()

        #expect(upgrade.bytesToFree > 0, "precondition: the device lacks room")
        #expect(upgrade.showsSpaceMessage, "the notice asks for space")
        #expect(!upgrade.canStart)
        #expect(databases.pollingSeenByRewrites.isEmpty, "no rewrite ran")
        #expect(works.all.isEmpty, "nothing was stopped or started: \(works.all)")
        #expect(scheduler.foregroundPollingIsOn, "polling stays on")
        #expect(upgrade.screen == .notice)
    }

    @Test("Upgrade now starts on a device with room for the databases' data although not for twice their files: their empty pages are not counted")
    func emptyPagesDoNotCountAgainstTheRoom() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databaseBytes: Int64 = 1 << 60
        let databases = FakeDatabases(
            answers: [[.upgraded("email"), .upgraded("search")]], databaseBytes: databaseBytes, emptyBytes: databaseBytes - 4_096)
        let upgrade = await makeUpgrade(scheduler, databases)
        let bytesToFreeBefore = upgrade.bytesToFree
        let bytesNeededBefore = upgrade.bytesNeeded

        await upgrade.upgradeNow()

        #expect(bytesNeededBefore == SyncEngine.bytesNeededForUpgrade(liveBytes: 4_096), "the notice asks for what the check needs, the data's, not the file's: \(bytesNeededBefore)")
        #expect(bytesToFreeBefore == 0, "the device has room for one page of data: \(bytesToFreeBefore)")
        #expect(databases.pollingSeenByRewrites == [false], "the rewrite ran: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .done)
    }

    @Test("Upgrade now refused for a low battery not charging: nothing is paused and no rewrite runs")
    func aLowBatteryPausesNothing() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]])
        let low = SyncConfig.databaseUpgradeMinimumBatteryLevel / 2
        let upgrade = await makeUpgrade(scheduler, databases, battery: (low, .unplugged))

        await upgrade.upgradeNow()

        #expect(upgrade.needsPower, "precondition: the battery is low and not charging")
        #expect(upgrade.bytesToFree == 0, "precondition: the device has room")
        #expect(!upgrade.canStart)
        #expect(databases.pollingSeenByRewrites.isEmpty, "no rewrite ran")
        #expect(works.all.isEmpty, "nothing was stopped or started: \(works.all)")
        #expect(scheduler.foregroundPollingIsOn, "polling stays on")
        #expect(upgrade.screen == .notice)
    }

    @Test("Two taps on Upgrade now while the first tap's read runs: one rewrite, one pause and one start")
    func twoTapsRunOneUpgrade() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")], [.alreadyUpgraded("email"), .alreadyUpgraded("search")]])
        let upgrade = await makeUpgrade(scheduler, databases)
        databases.holdTheNextReads(2)

        async let first: Void = upgrade.upgradeNow()
        async let second: Void = upgrade.upgradeNow()
        await first
        await second

        #expect(databases.pollingSeenByRewrites.count == 1, "one rewrite for the two taps: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .done)
        #expect(!upgrade.needsUpgrade, "the banner goes")
    }

    @Test("Only the search database left to upgrade: the banner shows, and Upgrade now upgrades it and turns everything back on")
    func oneDatabaseLeftShowsTheBannerAndUpgrades() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.alreadyUpgraded("email"), .upgraded("search")]], emailStartsUpgraded: true)
        let upgrade = await makeUpgrade(scheduler, databases)
        let bannerShown = upgrade.needsUpgrade
        let noticeOpen = upgrade.isPresented

        await upgrade.upgradeNow()

        #expect(bannerShown, "the banner shows while one database is not upgraded")
        #expect(noticeOpen, "the notice opens")
        #expect(databases.pollingSeenByRewrites == [false], "the rewrite ran once, with polling off: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works)
        #expect(upgrade.screen == .done)
        #expect(!upgrade.needsUpgrade, "the banner goes")
    }

    @Test("A return with no stopped upgrade starts nothing")
    func aReturnWithoutAStoppedUpgradeStartsNothing() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]])
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.appBecameActive()

        #expect(databases.pollingSeenByRewrites.isEmpty, "no rewrite ran")
        #expect(works.all.isEmpty, "nothing was stopped or started: \(works.all)")
    }

    /// Long enough for a start's own task to finish after its last offered work.
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
