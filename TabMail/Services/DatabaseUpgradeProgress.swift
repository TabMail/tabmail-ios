/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The database upgrade's time estimate (ADR-IOS-121, #1583): the notice's "up to N
/// minutes" and the running screen's one bar for both databases, with the minutes
/// left. Pure: the databases' data, their finish times and the time since the start
/// go in; the bar's fraction and what to say come out.
///
/// The time is the data (each database's pages less its empty pages,
/// `DatabaseVacuum.SpaceState.liveBytes`) at `SyncConfig.databaseUpgradeSecondsPerGB`.
/// The bar fills by the time since the start: each database owns a share of it in
/// proportion to its data, and its part fills against its estimate up to
/// `SyncConfig.databaseUpgradeProgressHoldFraction` of the share, holds there past the
/// estimate, and jumps to the share's end when the database finishes, so the bar never
/// goes back. Once a database has finished, the later ones are estimated at the rate
/// the finished ones took.
struct DatabaseUpgradeProgress: Equatable, Sendable {
    /// What the running screen says under the bar.
    enum Remaining: Equatable, Sendable {
        /// "About N minutes remaining", N rounded up.
        case minutes(Int)
        /// "Less than a minute remaining".
        case lessThanAMinute
        /// "Almost done": the last database is past its estimate, or all have finished.
        case almostDone
    }

    /// The bar, 0 to 1.
    let fraction: Double
    let remaining: Remaining

    /// A unit, not a setting.
    private static let secondsPerMinute: Double = 60

    /// One run of the upgrade: the data of each database it rewrites, in the order it
    /// rewrites them, read once at the run's start (a snapshot), its start, and how
    /// long after the start each database finished.
    struct Run: Equatable, Sendable {
        let dataBytes: [Int64]
        let start: ContinuousClock.Instant
        private(set) var finishedAfter: [Duration] = []

        init(dataBytes: [Int64], start: ContinuousClock.Instant) {
            self.dataBytes = dataBytes
            self.start = start
        }

        /// The next database finished at `instant`.
        mutating func finish(at instant: ContinuousClock.Instant) {
            finishedAfter.append(start.duration(to: instant))
        }

        /// The bar and the minutes left at `instant`.
        func progress(at instant: ContinuousClock.Instant) -> DatabaseUpgradeProgress {
            DatabaseUpgradeProgress.at(
                elapsedSeconds: Self.seconds(start.duration(to: instant)),
                dataBytes: dataBytes,
                finishedAfterSeconds: finishedAfter.map(Self.seconds))
        }

        private static func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
    }

    /// The bar and the minutes left `elapsedSeconds` after the start, for databases
    /// holding `dataBytes` (in the order they are rewritten), of which the first
    /// `finishedAfterSeconds.count` finished at those times since the start.
    static func at(
        elapsedSeconds: Double,
        dataBytes: [Int64],
        finishedAfterSeconds: [Double],
        secondsPerGB: Double = SyncConfig.databaseUpgradeSecondsPerGB,
        holdFraction: Double = SyncConfig.databaseUpgradeProgressHoldFraction
    ) -> DatabaseUpgradeProgress {
        let finished = min(finishedAfterSeconds.count, dataBytes.count)
        guard finished < dataBytes.count else { return DatabaseUpgradeProgress(fraction: 1, remaining: .almostDone) }
        let bytes = dataBytes.map { Double(max(0, $0)) }
        let total = bytes.reduce(0, +)
        let shares = total > 0 ? bytes.map { $0 / total } : bytes.map { _ in 1 / Double(bytes.count) }

        // Seconds a byte: what the finished databases took, once one has finished.
        let finishedBytes = bytes[..<finished].reduce(0, +)
        let lastFinish = finished > 0 ? finishedAfterSeconds[finished - 1] : 0
        let rate = finished > 0 && finishedBytes > 0
            ? lastFinish / finishedBytes
            : secondsPerGB / SyncConfig.databaseUpgradeBytesPerGB

        let inCurrent = max(0, elapsedSeconds - lastFinish)
        let expected = bytes[finished] * rate
        let fill = expected > 0 ? min(1, inCurrent / expected) : 1
        let fraction = shares[..<finished].reduce(0, +) + shares[finished] * holdFraction * fill

        let left = max(0, expected - inCurrent) + bytes[(finished + 1)...].reduce(0, +) * rate
        let remaining: Remaining
        if left <= 0 {
            remaining = .almostDone
        } else if left < secondsPerMinute {
            remaining = .lessThanAMinute
        } else {
            remaining = .minutes(Int((left / secondsPerMinute).rounded(.up)))
        }
        return DatabaseUpgradeProgress(fraction: min(1, fraction), remaining: remaining)
    }

    /// The notice's "It can take up to N minutes" for databases holding `dataBytes` in
    /// all: the estimate times `SyncConfig.databaseUpgradeNoticeTimeMargin`, rounded up
    /// to whole minutes, at least `SyncConfig.databaseUpgradeNoticeMinimumMinutes`.
    static func noticeMinutes(dataBytes: Int64) -> Int {
        let seconds = Double(max(0, dataBytes)) / SyncConfig.databaseUpgradeBytesPerGB
            * SyncConfig.databaseUpgradeSecondsPerGB * SyncConfig.databaseUpgradeNoticeTimeMargin
        return max(SyncConfig.databaseUpgradeNoticeMinimumMinutes, Int((seconds / secondsPerMinute).rounded(.up)))
    }
}
