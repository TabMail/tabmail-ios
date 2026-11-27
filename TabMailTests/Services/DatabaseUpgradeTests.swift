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
        /// The databases ("email", "search") a rewrite has upgraded or found upgraded.
        private let upgraded = Mutex<Set<String>>([])
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
        /// The databases ("email", "search") whose mode and pages cannot be read.
        private let unreadable: Set<String>

        /// `userLeaves`: the user leaves the app during the first rewrite.
        /// `emailStartsUpgraded`: only the search database is left to upgrade.
        init(
            answers: [[SyncEngine.UpgradeStep]], databaseBytes: Int64 = 4_096, emptyBytes: Int64 = 0,
            userLeaves: Bool = false, emailStartsUpgraded: Bool = false, unreadable: Set<String> = []
        ) {
            self.answers = Mutex(answers)
            self.databaseBytes = databaseBytes
            self.emptyBytes = emptyBytes
            self.leaves = Mutex(userLeaves)
            self.emailStartsUpgraded = emailStartsUpgraded
            self.unreadable = unreadable
        }

        /// Each database's data, as the upgrade counts it: its pages less its empty pages.
        var liveBytes: Int64 { (databaseBytes / 4_096 - emptyBytes / 4_096) * 4_096 }

        /// The fake rewrite: records whether polling was on, lets the user leave the
        /// app when told, gives its next answer, telling `finished` each of its steps in
        /// turn, and leaves each database a step upgraded or found upgraded on
        /// `auto_vacuum = INCREMENTAL`.
        func rewrite(_ scheduler: SyncScheduler, finished: DatabaseUpgrade.StepFinished) async -> [SyncEngine.UpgradeStep] {
            let pollingOn = await MainActor.run { scheduler.foregroundPollingIsOn }
            pollingDuringRewrite.withLock { $0.append(pollingOn) }
            if leaves.withLock({ leaves in defer { leaves = false }; return leaves }) {
                DatabaseSuspension.setAppActiveForTesting(false)
            }
            let answer = answers.withLock { $0.isEmpty ? [] : $0.removeFirst() }
            for step in answer {
                switch step {
                case .upgraded(let name), .alreadyUpgraded(let name):
                    upgraded.withLock { _ = $0.insert(name) }
                default:
                    break
                }
                await finished(step)
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
            let done = upgraded.withLock { $0 }
            let path = FileManager.default.temporaryDirectory.path
            let databases = [
                (done.contains("email") || emailStartsUpgraded, unreadable.contains("email")),
                (done.contains("search"), unreadable.contains("search")),
            ]
            return databases.map { isUpgraded, isUnreadable in
                DatabaseUpgrade.DatabaseState(
                    path: path,
                    state: isUnreadable ? nil : DatabaseVacuum.SpaceState(
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
            upgradeDatabases: { finished in await databases.rewrite(scheduler, finished: finished) },
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

    @Test("The notice's minutes come from the data of the databases still to upgrade, empty pages not counted; a database that cannot be read leaves them unset (the notice's fallback)")
    func theNoticeMinutesComeFromTheData() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databaseBytes: Int64 = 3_000_000_000
        let emptyBytes: Int64 = 600_000_000
        let both = FakeDatabases(answers: [], databaseBytes: databaseBytes, emptyBytes: emptyBytes)
        let searchOnly = FakeDatabases(answers: [], databaseBytes: databaseBytes, emptyBytes: emptyBytes, emailStartsUpgraded: true)
        let unreadable = FakeDatabases(answers: [], databaseBytes: databaseBytes, emptyBytes: emptyBytes, unreadable: ["search"])

        let bothMinutes = await makeUpgrade(scheduler, both).noticeMinutes
        let searchOnlyMinutes = await makeUpgrade(scheduler, searchOnly).noticeMinutes
        let unreadableUpgrade = await makeUpgrade(scheduler, unreadable)

        #expect(bothMinutes == DatabaseUpgradeProgress.noticeMinutes(dataBytes: 2 * both.liveBytes), "both databases' data: \(String(describing: bothMinutes))")
        #expect(bothMinutes == 10, "4.8 GB of data: up to 10 minutes: \(String(describing: bothMinutes))")
        #expect(searchOnlyMinutes == DatabaseUpgradeProgress.noticeMinutes(dataBytes: searchOnly.liveBytes), "only the database left to upgrade: \(String(describing: searchOnlyMinutes))")
        #expect(searchOnlyMinutes == 5, "2.4 GB of data: up to 5 minutes: \(String(describing: searchOnlyMinutes))")
        #expect(unreadableUpgrade.needsUpgrade, "precondition: the email database still needs the upgrade")
        #expect(unreadableUpgrade.noticeMinutes == nil, "a database that cannot be read: no estimate")
    }

    @Test("The running screen's progress: the data of the databases still on NONE, in order, read for the run; each upgraded database records its finish, so the bar is full at the end; one found upgraded is not counted")
    func theRunRecordsItsProgress() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let both = FakeDatabases(answers: [[.upgraded("email"), .upgraded("search")]], databaseBytes: 8 * 4_096, emptyBytes: 4_096)
        let searchOnly = FakeDatabases(answers: [[.alreadyUpgraded("email"), .upgraded("search")]], databaseBytes: 8 * 4_096, emptyBytes: 4_096, emailStartsUpgraded: true)
        let bothUpgrade = await makeUpgrade(scheduler, both)
        let searchOnlyUpgrade = await makeUpgrade(scheduler, searchOnly)
        let beforeRun = bothUpgrade.progress

        await bothUpgrade.upgradeNow()
        await settle()
        await searchOnlyUpgrade.upgradeNow()

        let bothRun = try #require(bothUpgrade.progress, "the run recorded its progress")
        let searchOnlyRun = try #require(searchOnlyUpgrade.progress, "the run recorded its progress")
        let bothAtTheEnd = bothRun.progress(at: ContinuousClock.now)
        #expect(beforeRun == nil, "no progress before a run")
        #expect(bothRun.dataBytes == [both.liveBytes, both.liveBytes], "both databases' data, email first: \(bothRun.dataBytes)")
        #expect(bothRun.finishedAfter.count == 2, "each upgraded database recorded its finish: \(bothRun.finishedAfter)")
        #expect(bothAtTheEnd == DatabaseUpgradeProgress(fraction: 1, remaining: .almostDone), "the bar is full at the end: \(bothAtTheEnd)")
        #expect(bothUpgrade.screen == .done)
        #expect(searchOnlyRun.dataBytes == [searchOnly.liveBytes], "only the database still on NONE: \(searchOnlyRun.dataBytes)")
        #expect(searchOnlyRun.finishedAfter.count == 1, "the database found upgraded records no finish: \(searchOnlyRun.finishedAfter)")
        #expect(searchOnlyUpgrade.screen == .done)
    }

    @Test("Only an upgraded database fills its share of the bar: one that failed or found too little space records no finish, so the bar is not full")
    func onlyAnUpgradedDatabaseRecordsAFinish() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let failed = FakeDatabases(answers: [[.upgraded("email"), .failed("search")]])
        let shortOfSpace = FakeDatabases(answers: [[.upgraded("email"), .needsSpace("search", bytesToFree: 1)]])
        let failedUpgrade = await makeUpgrade(scheduler, failed)
        let shortOfSpaceUpgrade = await makeUpgrade(scheduler, shortOfSpace)

        await failedUpgrade.upgradeNow()
        await settle()
        await shortOfSpaceUpgrade.upgradeNow()

        let failedRun = try #require(failedUpgrade.progress, "the run recorded its progress")
        let shortOfSpaceRun = try #require(shortOfSpaceUpgrade.progress, "the run recorded its progress")
        let failedBar = failedRun.progress(at: ContinuousClock.now)
        let shortOfSpaceBar = shortOfSpaceRun.progress(at: ContinuousClock.now)
        #expect(failedRun.finishedAfter.count == 1, "only the email database's finish: \(failedRun.finishedAfter)")
        #expect(failedBar.fraction < 1, "the bar is not full: \(failedBar)")
        #expect(failedUpgrade.screen == .failed)
        #expect(shortOfSpaceRun.finishedAfter.count == 1, "only the email database's finish: \(shortOfSpaceRun.finishedAfter)")
        #expect(shortOfSpaceBar.fraction < 1, "the bar is not full: \(shortOfSpaceBar)")
        #expect(shortOfSpaceUpgrade.screen == .notice)
    }

    @Test("A database unreadable at the run's start: the run has no bar, so the email database's finish is never counted as the search database's and the bar never shows the search database done before it is")
    func anUnreadableDatabaseLeavesTheRunWithoutABar() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        // The search step fails, so the bar after the run is the bar as it stood once the
        // email database had finished and the search database was being rewritten.
        let databases = FakeDatabases(answers: [[.upgraded("email"), .failed("search")]], unreadable: ["email"])
        let upgrade = await makeUpgrade(scheduler, databases)
        let canStart = upgrade.canStart && upgrade.needsUpgrade

        await upgrade.upgradeNow()

        let bar = upgrade.progress?.progress(at: ContinuousClock.now)
        let fraction = bar?.fraction ?? 0
        #expect(canStart, "precondition: the search database still needs the upgrade and the device has room")
        #expect(databases.pollingSeenByRewrites == [false], "the rewrite ran: \(databases.pollingSeenByRewrites)")
        #expect(fraction < 1, "the bar does not show the search database done: \(String(describing: bar))")
        #expect(upgrade.progress == nil, "no bar for the run: \(String(describing: upgrade.progress))")
        #expect(upgrade.screen == .failed)
    }

    @Test("A run the suspension stops drops its bar; the run started again on the return reads the databases again, and its bar covers only what is left")
    func aStoppedRunDropsItsBarAndTheNextCoversWhatIsLeft() async throws {
        let works = Works()
        let scheduler = try await makeScheduler(works)
        defer { tearDown(scheduler) }
        let databases = FakeDatabases(
            answers: [[.upgraded("email"), .stopped("search")], [.alreadyUpgraded("email"), .upgraded("search")]], userLeaves: true)
        let upgrade = await makeUpgrade(scheduler, databases)

        await upgrade.upgradeNow()
        let barAfterStop = upgrade.progress
        let continues = upgrade.continuesOnReturn
        await returnToTheApp(scheduler, upgrade, works)

        let resumed = try #require(upgrade.progress, "the run started again recorded its progress")
        #expect(continues, "precondition: the upgrade continues on the app's return")
        #expect(barAfterStop == nil, "the stopped run's bar is dropped: \(String(describing: barAfterStop))")
        #expect(resumed.dataBytes == [databases.liveBytes], "only the search database is left: \(resumed.dataBytes)")
        #expect(resumed.finishedAfter.count == 1, "the search database's finish; the email database, found upgraded, records none: \(resumed.finishedAfter)")
        #expect(databases.pollingSeenByRewrites == [false, false], "both rewrites ran with polling off: \(databases.pollingSeenByRewrites)")
        await expectEverythingBackOn(scheduler, works, starts: 2)
        #expect(upgrade.screen == .done)
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
