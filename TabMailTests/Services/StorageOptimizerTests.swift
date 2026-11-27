/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// How often, a millisecond apart, a test looks for the steps to start. At file scope:
/// the fake steps, which are not on the main actor, read it.
private let startPolls = 5_000

/// #1448: Settings' Optimize Storage row. It shows while the email and search databases'
/// empty pages come to at least `SyncConfig.optimizeStorageMinimumGainBytes`, with the
/// size "Email Index Used" can drop to (the space used less those empty pages). On
/// databases not yet upgraded a tap opens the upgrade's notice; on upgraded ones it runs
/// the background job's steps now, once however often it is tapped, with the tap's
/// check, and Settings closing stops them between two. A step that fails shows that
/// nothing was lost; a stop does not.
///
/// Each test drives its own `StorageOptimizer` with a fake measure, upgrade state and
/// steps. That the app's optimizer runs the app's steps with the app's check is pinned
/// by `IncrementalVacuumTests` (source fence and a real database). A run the fakes hold
/// that never ends fails at the time limit instead of hanging the run.
@MainActor
@Suite("Settings' Optimize Storage row", .timeLimit(.minutes(1)))
struct StorageOptimizerTests {

    private static let megabyte: Int64 = 1024 * 1024
    /// "Email Index Used" in the fake measures.
    private static let used: Int64 = 400 * megabyte
    private static let minimum = SyncConfig.optimizeStorageMinimumGainBytes
    /// Empty pages well over the threshold.
    private static let lots: Int64 = 120 * megabyte

    /// The measures in turn; the last repeats.
    final class Measures: Sendable {
        private let queue: Mutex<[StorageOptimizer.Measure]>
        private let reads = Mutex(0)

        init(_ measures: [StorageOptimizer.Measure]) {
            queue = Mutex(measures)
        }

        func next() -> StorageOptimizer.Measure {
            reads.withLock { $0 += 1 }
            return queue.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }

        var readCount: Int { reads.withLock { $0 } }
    }

    /// The upgrade's state and its notice.
    @MainActor final class Upgrade {
        var needsUpgrade: Bool
        var noticeOpens = 0

        init(needsUpgrade: Bool) {
            self.needsUpgrade = needsUpgrade
        }
    }

    /// The steps: each run gives its answer in turn (the last repeats) and records every
    /// answer of the check it was given. A holding run keeps asking the check, a
    /// millisecond apart, until the check says no or the test releases it.
    final class Steps: Sendable {
        private let answers: Mutex<[[SyncEngine.SpaceReturnStep]]>
        private let holds: Bool
        private let released = Mutex(false)
        private let runs = Mutex(0)
        private let checks = Mutex<[Bool]>([])

        init(_ answers: [[SyncEngine.SpaceReturnStep]], holds: Bool = false) {
            self.answers = Mutex(answers)
            self.holds = holds
        }

        func run(_ shouldRun: @escaping @Sendable () -> Bool) async -> [SyncEngine.SpaceReturnStep] {
            runs.withLock { $0 += 1 }
            while true {
                let yes = shouldRun()
                checks.withLock { $0.append(yes) }
                guard yes, holds, !released.withLock({ $0 }) else { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }

        func release() { released.withLock { $0 = true } }

        /// Waits until a run has started; false if none did.
        func waitUntilRunning() async -> Bool {
            for _ in 0..<startPolls {
                if runs.withLock({ $0 }) > 0 { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }

        var runCount: Int { runs.withLock { $0 } }
        var checkAnswers: [Bool] { checks.withLock { $0 } }
    }

    private static func measure(empty: Int64?) -> StorageOptimizer.Measure {
        StorageOptimizer.Measure(usedBytes: used, emptyBytes: empty)
    }

    private func makeOptimizer(
        _ measures: Measures, _ upgrade: Upgrade, _ steps: Steps,
        mayRun: @escaping @Sendable () -> Bool = { true }
    ) -> StorageOptimizer {
        StorageOptimizer(
            readMeasure: { measures.next() },
            readNeedsUpgrade: { upgrade.needsUpgrade },
            openUpgradeNotice: { upgrade.noticeOpens += 1 },
            giveBack: { shouldRun in await steps.run(shouldRun) },
            mayRun: mayRun)
    }

    @Test("The row shows from 50 MB of empty pages, with the space used less them; below that, unread or not yet measured, there is no row")
    func theRowShowsFromTheThreshold() async {
        let upgrade = Upgrade(needsUpgrade: false)
        let steps = Steps([[]])
        let atTheThreshold = makeOptimizer(Measures([Self.measure(empty: Self.minimum)]), upgrade, steps)
        let notMeasured = atTheThreshold.row
        await atTheThreshold.refresh()
        let below = makeOptimizer(Measures([Self.measure(empty: Self.minimum - 1)]), upgrade, steps)
        await below.refresh()
        let unread = makeOptimizer(Measures([Self.measure(empty: nil)]), upgrade, steps)
        await unread.refresh()
        let atRow = atTheThreshold.row
        let belowRow = below.row
        let unreadRow = unread.row

        #expect(Self.minimum == 50 * Self.megabyte, "\(Self.minimum)")
        #expect(notMeasured == nil, "nothing measured yet: \(String(describing: notMeasured))")
        #expect(atRow == .ready(canDropToBytes: Self.used - Self.minimum, lastRunFailed: false), "\(String(describing: atRow))")
        #expect(belowRow == nil, "\(String(describing: belowRow))")
        #expect(unreadRow == nil, "\(String(describing: unreadRow))")
        #expect(steps.runCount == 0, "showing the row runs nothing")
    }

    @Test("Not upgraded: the row says the upgrade comes first, a tap opens the upgrade's notice and runs no step, and after the upgrade the row goes")
    func notUpgradedOpensTheUpgradesNotice() async throws {
        let upgrade = Upgrade(needsUpgrade: true)
        let steps = Steps([[]])
        let measures = Measures([Self.measure(empty: Self.lots), Self.measure(empty: 0)])
        let optimizer = makeOptimizer(measures, upgrade, steps)
        await optimizer.refresh()
        let before = optimizer.row
        let row = try #require(before)
        let line = OptimizeStorageRow.line(for: row)

        await optimizer.tap()
        let opens = upgrade.noticeOpens
        // The upgrade's VACUUM gives the empty pages back; Settings measures again.
        upgrade.needsUpgrade = false
        await optimizer.refresh()
        let after = optimizer.row

        #expect(before == .upgradeFirst(canDropToBytes: Self.used - Self.lots), "\(String(describing: before))")
        #expect(line == OptimizeStorageRow.upgradeFirstLine, "\(String(describing: line))")
        #expect(opens == 1, "the tap opened the notice: \(opens)")
        #expect(steps.runCount == 0, "and ran no step")
        #expect(after == nil, "\(String(describing: after))")
    }

    @Test("Upgraded: a tap runs the steps once with the tap's check, shows Optimizing while they run, then measures again; with the empty pages given back the row goes")
    func aTapRunsTheStepsThenMeasuresAgain() async {
        let upgrade = Upgrade(needsUpgrade: false)
        let steps = Steps([[.gaveBack("email"), .gaveBack("search")]], holds: true)
        let measures = Measures([Self.measure(empty: Self.lots), Self.measure(empty: 0)])
        let optimizer = makeOptimizer(measures, upgrade, steps)
        await optimizer.refresh()
        let before = optimizer.row
        let beforeLine = before.flatMap(OptimizeStorageRow.line(for:))

        let tap = Task { await optimizer.tap() }
        let started = await steps.waitUntilRunning()
        let during = optimizer.row
        let duringLine = during.flatMap(OptimizeStorageRow.line(for:))
        let readsDuring = measures.readCount
        steps.release()
        await tap.value
        let after = optimizer.row

        #expect(before == .ready(canDropToBytes: Self.used - Self.lots, lastRunFailed: false), "\(String(describing: before))")
        #expect(beforeLine == OptimizeStorageRow.overnightLine, "\(String(describing: beforeLine))")
        #expect(started, "the tap started the steps")
        #expect(during == .optimizing, "\(String(describing: during))")
        #expect(duringLine == nil, "no line while the steps run: \(String(describing: duringLine))")
        #expect(readsDuring == 1, "no measure while the steps run: \(readsDuring)")
        #expect(steps.runCount == 1, "\(steps.runCount)")
        #expect(steps.checkAnswers.first == true, "the check let the steps run: \(steps.checkAnswers)")
        #expect(measures.readCount == 2, "measured again after the steps: \(measures.readCount)")
        #expect(after == nil, "\(String(describing: after))")
    }

    @Test("A step that fails: the row says the run could not finish and nothing was lost; the next tap's run clears it")
    func aFailedStepShowsThenClears() async {
        let upgrade = Upgrade(needsUpgrade: false)
        let steps = Steps([[.failed("email"), .gaveBack("search")], [.gaveBack("email"), .alreadyCompact("search")]])
        let measures = Measures([Self.measure(empty: Self.lots)])
        let optimizer = makeOptimizer(measures, upgrade, steps)
        await optimizer.refresh()

        await optimizer.tap()
        let failed = optimizer.row
        let failedLine = failed.flatMap(OptimizeStorageRow.line(for:))
        await optimizer.tap()
        let next = optimizer.row

        #expect(failed == .ready(canDropToBytes: Self.used - Self.lots, lastRunFailed: true), "\(String(describing: failed))")
        #expect(failedLine == OptimizeStorageRow.failedLine, "\(String(describing: failedLine))")
        #expect(next == .ready(canDropToBytes: Self.used - Self.lots, lastRunFailed: false), "\(String(describing: next))")
        #expect(steps.runCount == 2, "\(steps.runCount)")
    }

    @Test("Settings closing stops the steps between two: the check says no from then on, and a stop is not shown as a failure")
    func stopEndsTheStepsWithoutAFailure() async {
        let upgrade = Upgrade(needsUpgrade: false)
        // A step cut short by the stop fails and rolls back.
        let steps = Steps([[.failed("email")]], holds: true)
        let measures = Measures([Self.measure(empty: Self.lots)])
        let optimizer = makeOptimizer(measures, upgrade, steps)
        await optimizer.refresh()

        let tap = Task { await optimizer.tap() }
        let started = await steps.waitUntilRunning()
        optimizer.stop()
        await tap.value
        let after = optimizer.row
        let checks = steps.checkAnswers

        #expect(started, "the tap started the steps")
        #expect(checks.first == true, "the check let the steps run: \(checks)")
        #expect(checks.last == false, "after the stop the check says no: \(checks)")
        #expect(after == .ready(canDropToBytes: Self.used - Self.lots, lastRunFailed: false), "\(String(describing: after))")
    }

    @Test("Two taps run the steps once")
    func twoTapsRunOnce() async {
        let upgrade = Upgrade(needsUpgrade: false)
        let steps = Steps([[.gaveBack("email"), .gaveBack("search")]], holds: true)
        let measures = Measures([Self.measure(empty: Self.lots)])
        let optimizer = makeOptimizer(measures, upgrade, steps)
        await optimizer.refresh()

        let first = Task { await optimizer.tap() }
        let started = await steps.waitUntilRunning()
        await optimizer.tap()
        let runsAfterTheSecondTap = steps.runCount
        steps.release()
        await first.value

        #expect(started, "the first tap started the steps")
        #expect(runsAfterTheSecondTap == 1, "the second tap started nothing: \(runsAfterTheSecondTap)")
        #expect(steps.runCount == 1, "\(steps.runCount)")
    }

    @Test("The tap's check says no while the app may not run the steps, and that stop is not a failure")
    func theCheckSaysNoWhenTheAppMayNotRun() async {
        let upgrade = Upgrade(needsUpgrade: false)
        let steps = Steps([[.stopped("email")]])
        let measures = Measures([Self.measure(empty: Self.lots)])
        let optimizer = makeOptimizer(measures, upgrade, steps, mayRun: { false })
        await optimizer.refresh()

        await optimizer.tap()
        let after = optimizer.row

        #expect(steps.checkAnswers == [false], "\(steps.checkAnswers)")
        #expect(after == .ready(canDropToBytes: Self.used - Self.lots, lastRunFailed: false), "\(String(describing: after))")
    }

    @Test("The row's copy")
    func theRowsCopy() {
        let canDropTo = OptimizeStorageRow.canDropTo("1.2 GB")
        let ready = OptimizeStorageRow.line(for: .ready(canDropToBytes: 1, lastRunFailed: false))
        let failed = OptimizeStorageRow.line(for: .ready(canDropToBytes: 1, lastRunFailed: true))
        let upgradeFirst = OptimizeStorageRow.line(for: .upgradeFirst(canDropToBytes: 1))
        let optimizing = OptimizeStorageRow.line(for: .optimizing)

        #expect(OptimizeStorageRow.title == "Optimize")
        #expect(canDropTo == "Can drop to 1.2 GB")
        #expect(ready == "TabMail does this overnight. Tap to do it now.")
        #expect(failed == "Could not finish now. Nothing was lost. TabMail will try again overnight.")
        #expect(upgradeFirst == "Needs a one-time database update first. Tap to start.")
        #expect(optimizing == nil)
        #expect(OptimizeStorageRow.optimizingTitle == "Optimizing…")
    }
}
