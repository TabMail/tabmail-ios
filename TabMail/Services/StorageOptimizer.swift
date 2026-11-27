/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// Settings' Email Index numbers and its Optimize Storage row (#1448, ADR-IOS-121).
///
/// A delete leaves the pages it frees inside the email and search database files as
/// empty pages. The background processing job gives them back each night in short
/// `incremental_vacuum` steps (`SyncEngine.runOvernightSpaceReturn`), on databases the
/// user has upgraded (`DatabaseUpgrade`). The row shows while those empty pages come
/// to at least `SyncConfig.optimizeStorageMinimumGainBytes`, with the size "Email Index
/// Used" can drop to, and a tap gives them back now:
///
/// - Both databases upgraded: the tap runs the same steps now, in the foreground, the
///   one run there (`SyncEngine.optimizeStorageMayRun`). Sync is not paused: the
///   run's writes are at the background tier, and a sync write waits for at most one
///   step, one throttled checkpoint or the final TRUNCATE (ADR-IOS-121 decision 5).
///   The app leaving the foreground, the databases' suspension or `stop` (Settings
///   closed) stops the steps between two; the rest waits for the night.
/// - Either database not upgraded: the row says the upgrade comes first, and the tap
///   opens the upgrade's notice. The upgrade's `VACUUM` gives the empty pages back
///   itself.
///
/// "Email Index Used" (a walk of the storage folder, `StorageEstimator.totalSizeMB`) and
/// the empty pages (`StorageEstimator.PageTotals`, read from both databases' headers)
/// are measured off the main thread when Settings opens and again after a run, an
/// upgrade or a reset (`refresh`).
@MainActor
@Observable
final class StorageOptimizer {
    /// What Settings shows: "Email Index Used" and the two databases' empty pages.
    struct Measure: Equatable, Sendable {
        /// "Email Index Used": the storage folder's allocated size, in bytes.
        let usedBytes: Int64
        /// The email and search databases' empty pages, in bytes; nil when either
        /// database's header cannot be read (e.g. the search database not open yet).
        let emptyBytes: Int64?
    }

    /// The Optimize Storage row.
    enum Row: Equatable, Sendable {
        /// Either database is not upgraded: the tap opens the upgrade's notice.
        case upgradeFirst(canDropToBytes: Int64)
        /// Both are upgraded: the tap gives the empty pages back now. `lastRunFailed`:
        /// the last tap's run had a step that failed (nothing is lost).
        case ready(canDropToBytes: Int64, lastRunFailed: Bool)
        /// The tap's steps are running.
        case optimizing
    }

    /// The last measure; nil until the first one ends.
    private(set) var measure: Measure?
    /// Either database is still on `auto_vacuum = NONE`, read with the measure.
    private(set) var needsUpgrade = false
    /// The tap's steps are running.
    private(set) var isOptimizing = false
    /// The last tap's run had a step that failed.
    private(set) var lastRunFailed = false

    /// The measure (`measureTheApp`).
    private let readMeasure: @Sendable () async -> Measure
    /// Re-reads whether either database still needs the upgrade (`DatabaseUpgrade`).
    private let readNeedsUpgrade: @MainActor () async -> Bool
    /// Opens the upgrade's notice (`DatabaseUpgrade.openNotice`).
    private let openUpgradeNotice: @MainActor () async -> Void
    /// The steps, asking the given check before each step (`giveBackTheAppsEmptyPages`).
    private let giveBack: @Sendable (@escaping @Sendable () -> Bool) async -> [SyncEngine.SpaceReturnStep]
    /// The tap's check, without the stop (`SyncEngine.optimizeStorageMayRun`).
    private let mayRun: @Sendable () -> Bool
    /// The empty pages, in bytes, from which the row shows.
    private let minimumGainBytes: Int64
    /// The running tap's steps; `stop` cancels it.
    private var run: Task<[SyncEngine.SpaceReturnStep], Never>?

    /// The app's; a test passes its own measure, upgrade state, notice, steps, check
    /// and, for a small database, threshold.
    init(
        readMeasure: @escaping @Sendable () async -> Measure = StorageOptimizer.measureTheApp,
        readNeedsUpgrade: @escaping @MainActor () async -> Bool = StorageOptimizer.theAppNeedsUpgrade,
        openUpgradeNotice: @escaping @MainActor () async -> Void = { await DatabaseUpgrade.shared.openNotice() },
        giveBack: @escaping @Sendable (@escaping @Sendable () -> Bool) async -> [SyncEngine.SpaceReturnStep] = StorageOptimizer.giveBackTheAppsEmptyPages,
        mayRun: @escaping @Sendable () -> Bool = { SyncEngine.optimizeStorageMayRun() },
        minimumGainBytes: Int64 = SyncConfig.optimizeStorageMinimumGainBytes
    ) {
        self.readMeasure = readMeasure
        self.readNeedsUpgrade = readNeedsUpgrade
        self.openUpgradeNotice = openUpgradeNotice
        self.giveBack = giveBack
        self.mayRun = mayRun
        self.minimumGainBytes = minimumGainBytes
    }

    /// The row, or nil when there is less than `minimumGainBytes`
    /// (`SyncConfig.optimizeStorageMinimumGainBytes`) to gain or nothing has been measured.
    var row: Row? {
        if isOptimizing { return .optimizing }
        guard let measure, let empty = measure.emptyBytes, empty >= minimumGainBytes else { return nil }
        let canDropTo = max(0, measure.usedBytes - empty)
        if needsUpgrade { return .upgradeFirst(canDropToBytes: canDropTo) }
        return .ready(canDropToBytes: canDropTo, lastRunFailed: lastRunFailed)
    }

    /// Measures again, and re-reads whether either database still needs the upgrade.
    func refresh() async {
        let measured = await readMeasure()
        needsUpgrade = await readNeedsUpgrade()
        measure = measured
    }

    /// The row's tap: the upgrade's notice, or the steps now. Nothing while the steps run.
    func tap() async {
        switch row {
        case .upgradeFirst: await openUpgradeNotice()
        case .ready: await optimize()
        case .optimizing, nil: return
        }
    }

    /// Stops the tap's steps between two (Settings closed, or a page opened over it).
    /// The rest waits for the night.
    func stop() {
        run?.cancel()
    }

    /// Runs the steps now, detached (the email database's state read is synchronous),
    /// then measures again. `isOptimizing` is set before the first wait, so a second
    /// tap finds the row `.optimizing` and starts nothing.
    private func optimize() async {
        isOptimizing = true
        lastRunFailed = false
        let giveBack = self.giveBack
        let mayRun = self.mayRun
        let work = Task.detached(priority: .userInitiated) {
            await giveBack { mayRun() && !Task.isCancelled }
        }
        run = work
        let steps = await work.value
        let stopped = work.isCancelled
        run = nil
        BackgroundSyncLogger.logDebug("[OptimizeStorage] ended\(stopped ? " (stopped)" : ""): \(steps)")
        // A stop is not a failure: a step it cut short rolled back, and the rest
        // waits for the night.
        lastRunFailed = !stopped && steps.contains { if case .failed = $0 { true } else { false } }
        await refresh()
        isOptimizing = false
    }

    /// The app's measure, off the main thread: the walk Settings reports and both
    /// databases' empty pages, through the storage limit's own source
    /// (`StorageEstimator.SpaceSource.app`).
    nonisolated static func measureTheApp() async -> Measure {
        await Task.detached(priority: .userInitiated) {
            let source = StorageEstimator.SpaceSource.app(pool: AppDatabase.dbPool)
            let used = source.reportedBytes()
            let pages = await source.pageTotals()
            return Measure(usedBytes: used, emptyBytes: pages?.emptyBytes)
        }.value
    }

    /// Whether either of the app's databases still needs the upgrade, read from
    /// their headers (`DatabaseUpgrade.refresh`, which also keeps the inbox banner).
    static func theAppNeedsUpgrade() async -> Bool {
        await DatabaseUpgrade.shared.refresh()
        return DatabaseUpgrade.shared.needsUpgrade
    }

    /// The tap's steps on the app's two databases, with `shouldRun` asked before each
    /// step. The email database's writes queue at the background tier, as the
    /// background job's do, so a sync or user write waiting for the writer goes first.
    nonisolated static func giveBackTheAppsEmptyPages(
        shouldRun: @escaping @Sendable () -> Bool
    ) async -> [SyncEngine.SpaceReturnStep] {
        let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.backgroundPool)
        return await SyncEngine.runOvernightSpaceReturn(targets: targets, shouldRun: shouldRun)
    }
}
