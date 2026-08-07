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
/// The ATTRIBUTION machinery here is DEBUG-DIAGNOSTIC ONLY and is reached solely
/// from inside `registerTimedMigration`'s existing
/// `DebugModeManager.isLoggingEnabled()` branch (project rule 12). With logging
/// locked — the release default — none of `bodyWillStart` / `bodyDidFinish` /
/// `finish` / `abandon` is ever called, no clock is read and no dictionary is
/// touched.
///
/// ⚠️ ONE EXCEPTION, ADDED 2026-08-06, stated here because the paragraph above
/// used to say *"everything here"* without qualification and that is no longer
/// true. `measureChainScale` / `logChainScale` are **always on**, and they are
/// deliberately outside rule 12's debug gate under its exception (b): a duration
/// with no denominator is not observability. The owner's 27,601 ms chain was
/// unreadable for exactly this reason — nobody could say whether it meant "slow
/// code" or "a very large mailbox", and the two have opposite remedies. The pair
/// runs **at most once per upgrade** (the caller emits it only when the chain has
/// unapplied migrations, so an ordinary launch pays a `grdb_migrations` read and
/// nothing else), and it reports its own measurement cost inline so it can never be
/// mistaken for migration time — see `logChainScale`.
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

    // MARK: - Chain scale (always on, at most once per upgrade)

    /// The size of the thing the chain is about to walk. Returned as a value rather
    /// than logged straight from the measurement so a test can assert on it without
    /// parsing a log line.
    struct ChainScale: Sendable, Equatable {
        /// `nil` when the table does not exist yet — a fresh install measured before
        /// `v1` has run. `nil` and `0` are NOT the same fact ("no schema" vs "empty
        /// mailbox") and are rendered differently, because a calibration line that
        /// prints `0` for both would make a fresh install indistinguishable from a
        /// user who deleted all their mail.
        let messageHeaders: Int?
        let messageBodies: Int?
        let accounts: Int?
        let folders: Int?
        /// `page_count × page_size`. **Not** a filesystem stat: `Database.path` is
        /// internal to GRDB, and the pragmas are the only in-process route. This is
        /// the MAIN database file only and excludes the `-wal` and `-shm` sidecars,
        /// which matters because `v82` alone holds ~300 MB of WAL at profile H.
        let databaseBytes: Int64?
        /// How many registered migrations are about to run.
        let pendingMigrations: Int
        /// What measuring the four counts and the two pragmas cost. Reported because
        /// this measurement runs INSIDE the window the aggregate
        /// *"schema migrations completed in Nms"* line covers, so it inflates the
        /// very number it exists to calibrate. Printing it makes that subtractable
        /// instead of invisible.
        let measurementMs: Int
    }

    /// Counts the four tables whose size actually determines what the chain costs,
    /// plus the database's own page footprint.
    ///
    /// WHY THESE FOUR. `messageHeader` is the table every O(mailbox-size) body walks
    /// and the one a whole-database `PRAGMA foreign_key_check` scans; `messageBody`
    /// is where the BYTES are, and its page count is what made the post-`v68` gate
    /// cost 9.1 s at profile H; `account` and `folder` are the multipliers the owner
    /// actually varies (5 accounts / 78 folders) and are what makes one person's
    /// 27,601 ms another's 3,000 ms at the same header count.
    ///
    /// Every read is individually optional. A missing table on a fresh install must
    /// not throw out of a diagnostic and take the migration chain — and the app's
    /// launch — with it. Failing to measure is a missing number; failing to launch is
    /// a brick.
    static func measureChainScale(_ db: Database, pendingMigrations: Int) -> ChainScale {
        let t0 = CFAbsoluteTimeGetCurrent()
        func count(_ table: String) -> Int? {
            guard (try? db.tableExists(table)) == true else { return nil }
            return try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        }
        let headers = count("messageHeader")
        let bodies = count("messageBody")
        let accounts = count("account")
        let folders = count("folder")
        let bytes: Int64? = {
            guard let pages = try? Int64.fetchOne(db, sql: "PRAGMA page_count"),
                  let pageSize = try? Int64.fetchOne(db, sql: "PRAGMA page_size") else { return nil }
            return pages * pageSize
        }()
        return ChainScale(
            messageHeaders: headers,
            messageBodies: bodies,
            accounts: accounts,
            folders: folders,
            databaseBytes: bytes,
            pendingMigrations: pendingMigrations,
            measurementMs: Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// Emits the calibration line, in the same `BackgroundSyncLogger` idiom and the
    /// same `AppDatabase: …` prefix as the aggregate and attribution lines, so all
    /// three of a single upgrade's lines read as one record.
    static func logChainScale(_ scale: ChainScale) {
        func render(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
        let megabytes = scale.databaseBytes.map { String(format: "%.1fMB", Double($0) / 1_048_576) } ?? "n/a"
        BackgroundSyncLogger.log(
            "AppDatabase: migration chain scale — \(scale.pendingMigrations) pending migration(s) over "
                + "messageHeader \(render(scale.messageHeaders)) rows, "
                + "messageBody \(render(scale.messageBodies)) rows, "
                + "\(render(scale.accounts)) account(s), \(render(scale.folders)) folder(s), "
                + "db \(megabytes) (main file, excl. WAL) "
                + "[measured in \(scale.measurementMs)ms, included in the chain total]")
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
