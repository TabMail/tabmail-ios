/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The database upgrade's time estimate (#1583, ADR-IOS-121): the notice's "up to N
/// minutes" and the running screen's one bar for both databases with the minutes
/// left. `DatabaseUpgradeProgress` is pure, so each case gives it the databases' data,
/// the finish times and the time since the start. The data are the iPhone measurement
/// in `SyncConfig.databaseUpgradeSecondsPerGB`: 1.00 GB of email data, 3.80 GB of
/// search data, so at 40 s a gigabyte the email database's estimate is 40 s and the
/// search database's 152 s.
@Suite("The database upgrade's notice minutes, progress bar and minutes left")
struct DatabaseUpgradeProgressTests {
    private static let email: Int64 = 1_000_000_000
    private static let search: Int64 = 3_800_000_000
    private static let data = [email, search]
    private static let secondsPerByte = SyncConfig.databaseUpgradeSecondsPerGB / SyncConfig.databaseUpgradeBytesPerGB
    private static let hold = SyncConfig.databaseUpgradeProgressHoldFraction
    private static let emailShare = Double(email) / Double(email + search)
    private static let searchShare = Double(search) / Double(email + search)
    private static let emailEstimate = Double(email) * secondsPerByte
    private static let searchEstimate = Double(search) * secondsPerByte

    private func at(_ elapsed: Double, finished: [Double] = [], data: [Int64] = Self.data) -> DatabaseUpgradeProgress {
        DatabaseUpgradeProgress.at(elapsedSeconds: elapsed, dataBytes: data, finishedAfterSeconds: finished)
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test("Preconditions: the configured rate gives the email database 40 s and the search database 152 s, and the hold is below the share's end")
    func preconditions() {
        #expect(near(Self.emailEstimate, 40), "\(Self.emailEstimate)")
        #expect(near(Self.searchEstimate, 152), "\(Self.searchEstimate)")
        #expect(Self.hold > 0 && Self.hold < 1, "\(Self.hold)")
    }

    @Test("At the start the bar is empty and the minutes left are the whole estimate with no margin, rounded up")
    func theStart() {
        let start = at(0)
        #expect(start.fraction == 0, "\(start.fraction)")
        #expect(start.remaining == .minutes(4), "192 s is about 4 minutes: \(start.remaining)")
    }

    @Test("The bar fills by the time since the start against the running database's estimate, within its share")
    func theBarFillsByTime() {
        let halfway = at(Self.emailEstimate / 2)
        #expect(near(halfway.fraction, Self.emailShare * Self.hold * 0.5), "\(halfway.fraction)")
        #expect(halfway.remaining == .minutes(3), "172 s left: \(halfway.remaining)")
    }

    @Test("The bar never goes back, however the databases' finishes fall against their estimates")
    func theBarNeverGoesBack() {
        let finishes: [[Double]] = [
            [40, 192],    // on time
            [20, 60],     // both early
            [55, 330],    // both late
            [25, 400],    // email early, search late
            [90, 120],    // email late, search early
        ]
        for finished in finishes {
            var previous = -1.0
            var t = 0.0
            var backwards: [String] = []
            while t <= 450 {
                let progress = at(t, finished: finished.filter { $0 <= t })
                if progress.fraction < previous || progress.fraction > 1 {
                    backwards.append("t \(t): \(previous) to \(progress.fraction)")
                }
                previous = progress.fraction
                t += 0.25
            }
            #expect(backwards.isEmpty, "finishes \(finished): \(backwards.prefix(5))")
            #expect(previous == 1, "full once both have finished: \(previous)")
        }
    }

    @Test("When a database finishes, the bar jumps to the end of its share, from below it")
    func theShareJump() {
        let justBefore = at(30)
        let atTheFinish = at(30, finished: [30])
        #expect(justBefore.fraction < Self.emailShare, "\(justBefore.fraction)")
        #expect(near(atTheFinish.fraction, Self.emailShare), "the email database's share is full: \(atTheFinish.fraction) for \(Self.emailShare)")
        let lateFinish = at(70, finished: [70])
        #expect(near(lateFinish.fraction, Self.emailShare), "from its hold, too: \(lateFinish.fraction)")
    }

    @Test("After the first database finishes, the second is estimated at the rate the first took")
    func theReEstimate() {
        // The email database took 80 s, twice its estimate: the search database's
        // estimate becomes 304 s, not the configured 152 s.
        let slow = at(80, finished: [80])
        #expect(slow.remaining == .minutes(6), "304 s is about 6 minutes: \(slow.remaining)")
        let atTheConfiguredEstimate = at(80 + Self.searchEstimate, finished: [80])
        #expect(near(atTheConfiguredEstimate.fraction, Self.emailShare + Self.searchShare * Self.hold * 0.5), "half way through the new estimate: \(atTheConfiguredEstimate.fraction)")
        #expect(atTheConfiguredEstimate.remaining == .minutes(3), "152 s of the 304 left: \(atTheConfiguredEstimate.remaining)")
        // It took 20 s, half its estimate: 76 s for the search database.
        let fast = at(20, finished: [20])
        #expect(fast.remaining == .minutes(2), "76 s is about 2 minutes: \(fast.remaining)")
    }

    @Test("Past the last database's estimate the bar holds at its share's hold point and says Almost done")
    func theHoldAndAlmostDone() {
        let held = Self.emailShare + Self.searchShare * Self.hold
        for t in [40 + Self.searchEstimate + 0.5, 40 + Self.searchEstimate + 100, 40 + Self.searchEstimate + 10_000] {
            let progress = at(t, finished: [40])
            #expect(near(progress.fraction, held), "t \(t): \(progress.fraction) for \(held)")
            #expect(progress.remaining == .almostDone, "t \(t): \(progress.remaining)")
        }
        let notYet = at(40 + Self.searchEstimate - 1, finished: [40])
        #expect(notYet.remaining == .lessThanAMinute, "a second before the estimate: \(notYet.remaining)")
    }

    @Test("An earlier database past its estimate holds its part of the bar and shows the later databases' minutes, not Almost done")
    func anEarlierOverrun() {
        let progress = at(100)
        #expect(near(progress.fraction, Self.emailShare * Self.hold), "\(progress.fraction)")
        #expect(progress.remaining == .minutes(3), "the search database's 152 s: \(progress.remaining)")
    }

    @Test("Once every database has finished, the bar is full")
    func fullAtTheEnd() {
        for t in [192.0, 500] {
            #expect(at(t, finished: [40, 192]) == DatabaseUpgradeProgress(fraction: 1, remaining: .almostDone), "t \(t)")
        }
        #expect(at(10, finished: [5]).fraction < 1, "precondition: one finish of two is not the end")
        #expect(at(1, finished: [1], data: [Self.email]).fraction == 1, "one database")
    }

    @Test("The minutes left round up; under a minute says so")
    func roundingAndUnderAMinute() {
        // One database with a 125 s estimate.
        let data: [Int64] = [3_125_000_000]
        let cases: [(elapsed: Double, remaining: DatabaseUpgradeProgress.Remaining)] = [
            (4.5, .minutes(3)),          // 120.5 s
            (5.5, .minutes(2)),          // 119.5 s
            (64.5, .minutes(2)),         // 60.5 s
            (65.5, .lessThanAMinute),    // 59.5 s
            (124.5, .lessThanAMinute),   // 0.5 s
            (125.5, .almostDone),        // past it
        ]
        let wrong = cases.compactMap { item -> String? in
            let remaining = at(item.elapsed, data: data).remaining
            return remaining == item.remaining ? nil : "t \(item.elapsed): \(remaining), wanted \(item.remaining)"
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("The notice's minutes: the data at the configured rate times the margin, rounded up, at least the minimum")
    func theNoticeMinutes() {
        let cases: [(bytes: Int64, minutes: Int)] = [
            (Self.email + Self.search, 10),   // 576 s, 9.6 minutes
            (1_000_000_000, 2),               // 120 s
            (1_010_000_000, 3),               // 121.2 s
            (1_000_000, SyncConfig.databaseUpgradeNoticeMinimumMinutes),
            (0, SyncConfig.databaseUpgradeNoticeMinimumMinutes),
        ]
        let wrong = cases.compactMap { item -> String? in
            let minutes = DatabaseUpgradeProgress.noticeMinutes(dataBytes: item.bytes)
            return minutes == item.minutes ? nil : "\(item.bytes) bytes: \(minutes), wanted \(item.minutes)"
        }
        #expect(wrong.isEmpty, "\(wrong)")
        #expect(SyncConfig.databaseUpgradeNoticeMinimumMinutes == 1)
    }

    @Test("Databases with no data share the bar equally and the estimate never divides by zero")
    func noData() {
        let progress = at(0, data: [0, 0])
        #expect(near(progress.fraction, 0.5 * Self.hold), "\(progress.fraction)")
        #expect(progress.remaining == .almostDone, "\(progress.remaining)")
        #expect(near(at(0, finished: [0], data: [0, 0]).fraction, 0.5 + 0.5 * Self.hold))
    }

    @Test("A run counts its time from its start on the continuous clock, and each finish from the same start")
    func aRun() {
        let start = ContinuousClock.now
        var run = DatabaseUpgradeProgress.Run(dataBytes: Self.data, start: start)
        let before = run.progress(at: start + .milliseconds(20_500))
        run.finish(at: start + .seconds(40))
        let after = run.progress(at: start + .seconds(100))

        #expect(before == at(20.5), "\(before)")
        #expect(run.finishedAfter == [.seconds(40)], "\(run.finishedAfter)")
        #expect(after == at(100, finished: [40]), "\(after)")
    }
}
