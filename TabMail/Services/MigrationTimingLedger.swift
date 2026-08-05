/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// Attributes the time GRDB spends **after a migration body returns** to the
/// migration that pays it.
///
/// 🚨 **THE DEFECT THIS EXISTS TO FIX — the old log actively misled.**
/// `registerTimedMigration`'s clock wrapped only `try migrate(db)`, but GRDB runs
/// `PRAGMA foreign_key_check` (on the `.deferred` path) plus the COMMIT and its
/// own `grdb_migrations` bookkeeping *after* the closure returns, inside
/// machinery the closure cannot see. Measured on a 500k-header / 3.4 GB database,
/// that meant the chain-completion line reported ~87,000 ms while the
/// per-migration lines summed to ~19,000 ms — **~68,000 ms unattributed** — and
/// the single most expensive migration in the chain, `v68`, printed
/// `applied in 0ms`. An owner reading that log would conclude `v68` was free and
/// go hunting in `v70`/`v82`. The number was not merely incomplete; it pointed
/// at the wrong migration.
///
/// **How the gap is measured.** The interval between one body RETURNING and the
/// next body STARTING is, by construction, everything GRDB does in between for
/// the first migration: its foreign-key check, its commit, and its bookkeeping.
/// The final migration has no successor, so `finish(on:)` closes it from the
/// chain-completion site.
///
/// **Keyed by `Database` identity, not global.** A `DatabaseWriter` owns exactly
/// one writer `Database` instance, and every migration body in one chain receives
/// that instance — so `ObjectIdentifier(db)` names the chain. Two chains running
/// concurrently (which happens constantly in the parallel test suite, where many
/// suites build their own migrated fixture) therefore cannot contaminate each
/// other's attribution. A global accumulator would interleave and print numbers
/// that are wrong in exactly the way this file exists to prevent.
///
/// Everything here is DEBUG-DIAGNOSTIC ONLY and is reached solely from inside
/// `registerTimedMigration`'s existing `DebugModeManager.isLoggingEnabled()`
/// branch (project rule 12). With logging locked — the release default — no
/// method below is ever called, no clock is read and no dictionary is touched.
final class MigrationTimingLedger: Sendable {
    static let shared = MigrationTimingLedger()
    private init() {}

    /// One migration's attributed cost. `postBodyMs` is nil until the next body
    /// starts (or the chain finishes), which is the only moment the interval it
    /// names has actually elapsed.
    struct Entry: Sendable, Equatable {
        let identifier: String
        /// `"deferred"` or `"immediate"` — the contrast IS the diagnostic. After
        /// the mixed-mode change an `.immediate` migration's gap is commit only
        /// (single-digit ms) while a `.deferred` one's is a whole-database
        /// `PRAGMA foreign_key_check` (seconds). A log that did not label the
        /// mode would make those two look like the same measurement.
        let mode: String
        let bodyMs: Int
        var postBodyMs: Int?
    }

    /// A finished chain, in the shape the reconciliation line renders and the
    /// tests assert on. Exposed so the invariant — *bodies + post-body intervals
    /// account for the whole chain* — is machine-checked rather than eyeballed
    /// in a log.
    struct Report: Sendable {
        var entries: [Entry]
        var chainMs: Int

        var bodyMsTotal: Int { entries.reduce(0) { $0 + $1.bodyMs } }
        var postBodyMsTotal: Int { entries.reduce(0) { $0 + ($1.postBodyMs ?? 0) } }
        /// Whatever the two sums above do NOT explain: GRDB's own setup, the
        /// applied-identifiers read, and integer truncation (each entry rounds
        /// DOWN to whole milliseconds, so a 16-migration chain can shed up to
        /// ~32 ms this way). Printed rather than hidden — an unattributed
        /// remainder that starts growing is the same class of defect as the one
        /// this file fixes, and it should be visible when it happens.
        var unattributedMs: Int { chainMs - bodyMsTotal - postBodyMsTotal }
    }

    private struct Chain {
        let startedAt: ContinuousClock.Instant
        var lastBodyEndedAt: ContinuousClock.Instant?
        var entries: [Entry] = []
    }

    private let chains = Mutex<[ObjectIdentifier: Chain]>([:])

    #if DEBUG
    /// Finished reports, keyed by the same `Database` identity the chain was
    /// recorded under and CONSUMED on read, so a test reads its own chain's
    /// numbers and never another suite's. Compiled out of release builds
    /// entirely — nothing in the app reads a report; the log line is the product.
    private let finished = Mutex<[ObjectIdentifier: Report]>([:])

    /// Test seam. Returns and REMOVES this writer's most recent report.
    func consumeReport(db: Database) -> Report? {
        finished.withLock { $0.removeValue(forKey: ObjectIdentifier(db)) }
    }
    #endif

    // MARK: - Recording

    /// Called at the TOP of every timed migration body. Closes and logs the
    /// PREVIOUS migration's post-body interval, because that interval ends here.
    func bodyWillStart(db: Database) {
        let key = ObjectIdentifier(db)
        let now = ContinuousClock.now
        let closed: Entry? = chains.withLock { chains in
            guard var chain = chains[key] else {
                chains[key] = Chain(startedAt: now)
                return nil
            }
            guard let lastEnd = chain.lastBodyEndedAt, !chain.entries.isEmpty else { return nil }
            let gap = Self.wholeMilliseconds(lastEnd.duration(to: now))
            chain.entries[chain.entries.count - 1].postBodyMs = gap
            chain.lastBodyEndedAt = nil
            chains[key] = chain
            return chain.entries[chain.entries.count - 1]
        }
        if let closed { log(closed) }
    }

    /// Called when a migration body returns successfully.
    func bodyDidFinish(db: Database, identifier: String, mode: String, bodyMs: Int) {
        let key = ObjectIdentifier(db)
        let now = ContinuousClock.now
        chains.withLock { chains in
            var chain = chains[key] ?? Chain(startedAt: now)
            chain.entries.append(
                Entry(identifier: identifier, mode: mode, bodyMs: bodyMs, postBodyMs: nil))
            chain.lastBodyEndedAt = now
            chains[key] = chain
        }
    }

    /// Called once, from the chain-completion site, after `migrator.migrate`
    /// returns. Closes the LAST migration's post-body interval — the one no
    /// successor body can close — and emits the reconciliation line.
    ///
    /// A no-op when this writer ran no timed migration body (an already-migrated
    /// database, which is the overwhelmingly common case at launch), so an
    /// up-to-date app pays nothing and logs nothing.
    @discardableResult
    func finish(db: Database) -> Report? {
        let key = ObjectIdentifier(db)
        let now = ContinuousClock.now
        let outcome: (closed: Entry?, report: Report)? = chains.withLock { chains in
            guard var chain = chains.removeValue(forKey: key), !chain.entries.isEmpty else {
                return nil
            }
            var closed: Entry?
            if let lastEnd = chain.lastBodyEndedAt {
                let gap = Self.wholeMilliseconds(lastEnd.duration(to: now))
                chain.entries[chain.entries.count - 1].postBodyMs = gap
                closed = chain.entries[chain.entries.count - 1]
            }
            let report = Report(
                entries: chain.entries,
                chainMs: Self.wholeMilliseconds(chain.startedAt.duration(to: now)))
            return (closed, report)
        }
        guard let outcome else { return nil }
        if let closed = outcome.closed { log(closed) }
        let report = outcome.report
        #if DEBUG
        finished.withLock { $0[key] = report }
        #endif
        BackgroundSyncLogger.log(
            "AppDatabase: migration chain attribution — chain \(report.chainMs)ms = "
                + "bodies \(report.bodyMsTotal)ms + fkCheck/commit \(report.postBodyMsTotal)ms "
                + "+ unattributed \(report.unattributedMs)ms across \(report.entries.count) migration(s)")
        return report
    }

    /// Drop any half-recorded chain for this writer without logging. Used when a
    /// migration THREW: the failing migration already logged its own FAILED line,
    /// and a reconciliation over a chain that did not complete would be a number
    /// that does not mean what it says.
    func abandon(db: Database) {
        _ = chains.withLock { $0.removeValue(forKey: ObjectIdentifier(db)) }
    }

    /// `Duration.components` splits into (seconds, attoseconds), so rendering the
    /// fractional part in milliseconds needs these unit factors. Not tunables:
    /// 1 s = 1e3 ms and 1 ms = 1e-3 s = 1e15 as.
    private static let millisecondsPerSecond: Int64 = 1_000
    private static let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000

    /// Whole elapsed milliseconds, matching the aggregate line's `Nms` format.
    /// Truncates DOWN, which is why `Report.unattributedMs` carries a few ms of
    /// slack on a long chain rather than being exactly zero.
    static func wholeMilliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * millisecondsPerSecond + attoseconds / attosecondsPerMillisecond)
    }

    private func log(_ entry: Entry) {
        let post = entry.postBodyMs ?? 0
        BackgroundSyncLogger.log(
            "AppDatabase: migration \(entry.identifier) total \(entry.bodyMs + post)ms = "
                + "body \(entry.bodyMs)ms + fkCheck/commit \(post)ms "
                + "[foreignKeyChecks=.\(entry.mode)]")
    }
}

/// The recording gate, split out so the production predicate stays EXACTLY what
/// it was — one `DebugModeManager.isLoggingEnabled()` read — while tests can
/// exercise the attribution without unlocking debug mode process-wide (which
/// would also switch on file logging for every concurrently-running suite).
///
/// ⚠️ The override is `#if DEBUG` ONLY, so a release build compiles this down to
/// the single `isLoggingEnabled()` call it was before. Fail-SAFE by construction:
/// the override defaults to `false`, so a dropped injection yields the production
/// answer (off), never accidental production logging.
enum MigrationTimingGate {
    #if DEBUG
    /// Test-only. Mirrors `DebugModeManager.allowAllUsersForTesting`'s shape.
    nonisolated static let forcedForTesting = Mutex<Bool>(false)
    #endif

    static var isRecording: Bool {
        if DebugModeManager.isLoggingEnabled() { return true }
        #if DEBUG
        return forcedForTesting.withLock { $0 }
        #else
        return false
        #endif
    }
}
