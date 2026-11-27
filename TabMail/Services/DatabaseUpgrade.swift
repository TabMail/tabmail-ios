/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import UIKit

/// The one-time database upgrade the user starts (ADR-IOS-121, #1450): both
/// databases move to `auto_vacuum = INCREMENTAL`, so the background processing job
/// can give their empty pages back and the storage limits can shrink the files.
///
/// An install from before this change needs one `VACUUM` of each database for it.
/// That holds SQLite's one writer for a minute or so on a large mailbox and cannot
/// be stopped once its copy is written back, so the app never runs it by itself:
///
/// - `needsUpgrade` (either database still on NONE) shows the inbox banner
///   (`DatabaseUpgradeBanner`), whose action opens the notice. It is read at a quiet
///   moment after the inbox has painted (`checkAfterLaunch`), never on the first
///   render: the search database's state read opens the search index, which the
///   app opens only after the first paint (`TabMailApp.deferredSearchIndexInitIfNeeded`).
/// - The notice (`DatabaseUpgradeView`) says what the upgrade does and how long it
///   takes. Upgrade now is off while the device has too little space free right now
///   (`bytesToFree`; space iOS could purge does not count) or the battery is low and
///   not charging (`needsPower`).
/// - It shows by itself once (`checkAfterLaunch`), at that quiet moment; after that
///   only from the banner. Later closes it; the banner stays.
/// - Upgrade now runs `run`: upgrade mode (the full-screen spinner over the app, and
///   the light pause), then the rewrite, email database first, with the screen kept
///   awake. At the end a sync runs at once and the banner goes.
@MainActor
@Observable
final class DatabaseUpgrade {
    static let shared = DatabaseUpgrade()

    /// A database's file path and its mode and pages (nil when unreadable).
    struct DatabaseState: Sendable {
        let path: String
        let state: DatabaseVacuum.SpaceState?
    }

    /// The scheduler whose polling the upgrade pauses and turns back on.
    private let scheduler: SyncScheduler
    /// The rewrite: the app's two databases (`upgradeTheAppsDatabases`).
    private let upgradeDatabases: @Sendable () async -> [SyncEngine.UpgradeStep]
    /// Both databases' states (`readTheAppsStates`).
    private let readStates: @Sendable () async -> [DatabaseState]
    /// The battery's level and state (`theDevicesBattery`).
    private let readBattery: @MainActor () -> (level: Float, state: UIDevice.BatteryState)

    /// The app's upgrade; a test passes its own scheduler, rewrite, states and battery.
    init(
        scheduler: SyncScheduler = .shared,
        upgradeDatabases: @escaping @Sendable () async -> [SyncEngine.UpgradeStep] = DatabaseUpgrade.upgradeTheAppsDatabases,
        readStates: @escaping @Sendable () async -> [DatabaseState] = DatabaseUpgrade.readTheAppsStates,
        readBattery: @escaping @MainActor () -> (level: Float, state: UIDevice.BatteryState) = DatabaseUpgrade.theDevicesBattery
    ) {
        self.scheduler = scheduler
        self.upgradeDatabases = upgradeDatabases
        self.readStates = readStates
        self.readBattery = readBattery
    }

    /// What the upgrade screen shows.
    enum Screen: Equatable {
        /// The notice: what the upgrade does, Upgrade now and Later.
        case notice
        /// The rewrite runs (spinner, screen kept awake).
        case upgrading
        /// Both databases are upgraded.
        case done
        /// A rewrite threw and rolled back; nothing was lost. The banner stays.
        case failed
    }

    /// Either database is still on `auto_vacuum = NONE`. Drives the banner.
    private(set) var needsUpgrade = false
    /// The upgrade screen (notice, progress, result) is up.
    var isPresented = false
    private(set) var screen: Screen = .notice
    /// Bytes the device must free before the upgrade can start; 0 when it has room.
    private(set) var bytesToFree: Int64 = 0
    /// The free space the upgrade needs right now: the largest
    /// `SyncEngine.bytesNeededForUpgrade` of a database still on NONE.
    private(set) var bytesNeeded: Int64 = 0
    /// The last rewrite ran out of disk space although the check found room
    /// (`UpgradeStep.ranOutOfSpace`); it rolled back. Cleared when the next starts.
    private(set) var ranOutOfSpace = false
    /// The battery is under `SyncConfig.databaseUpgradeMinimumBatteryLevel` and the
    /// phone is not charging.
    private(set) var needsPower = false
    /// The rewrite stopped because the databases were suspended (the app's
    /// background time ran out); it starts again when the app is active.
    private(set) var continuesOnReturn = false

    /// Set once the notice has shown by itself (`checkAfterLaunch`).
    static let noticeOfferedKey = "DatabaseUpgrade.noticeOffered"

    /// Upgrade now can be tapped.
    var canStart: Bool { bytesToFree == 0 && !needsPower }

    /// The notice asks for space (`DatabaseUpgradeView.spaceMessage`): the device
    /// lacks it, or the last rewrite ran out of it.
    var showsSpaceMessage: Bool { bytesNeeded > 0 && (bytesToFree > 0 || ranOutOfSpace) }

    /// Reads both databases' mode (their headers; no table) and sets `needsUpgrade`.
    /// Settings calls it after a reset, which leaves both databases upgraded, and
    /// `StorageOptimizer` calls it when Settings measures its Optimize Storage row.
    func refresh() async {
        let states = await readStates()
        needsUpgrade = states.contains { $0.state?.autoVacuum == DatabaseVacuum.noneMode }
    }

    /// Opens the notice, its space and battery checks read now.
    func openNotice() async {
        await refreshConditions()
        guard needsUpgrade else { return }
        screen = .notice
        isPresented = true
    }

    /// Later: closes the notice. The banner stays while `needsUpgrade`.
    func later() {
        isPresented = false
    }

    /// Closes the screen after the upgrade ended (done or failed).
    func close() {
        isPresented = false
        screen = .notice
    }

    /// Re-reads the free space and the battery for the notice (and `needsUpgrade`).
    /// The notice calls it when the app comes back (the user may have freed space)
    /// and when the battery changes.
    func refreshConditions() async {
        let states = await readStates()
        needsUpgrade = states.contains { $0.state?.autoVacuum == DatabaseVacuum.noneMode }
        let notUpgraded = states.compactMap { entry -> (path: String, liveBytes: Int64)? in
            guard let state = entry.state, state.autoVacuum == DatabaseVacuum.noneMode else { return nil }
            return (entry.path, state.liveBytes)
        }
        bytesNeeded = notUpgraded.map { SyncEngine.bytesNeededForUpgrade(liveBytes: $0.liveBytes) }.max() ?? 0
        bytesToFree = notUpgraded.compactMap { entry -> Int64? in
            guard let available = SyncEngine.deviceAvailableBytes(forVolumeOf: entry.path) else { return nil }
            return SyncEngine.bytesToFreeForUpgrade(liveBytes: entry.liveBytes, availableBytes: available)
        }.max() ?? 0
        let battery = readBattery()
        needsPower = Self.needsPower(level: battery.level, state: battery.state)
    }

    /// The device's battery level and state, as `UIDevice` reports them.
    static func theDevicesBattery() -> (level: Float, state: UIDevice.BatteryState) {
        (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
    }

    /// Below `SyncConfig.databaseUpgradeMinimumBatteryLevel` and not charging. An
    /// unknown level (-1: battery monitoring off, or the simulator) asks nothing.
    nonisolated static func needsPower(level: Float, state: UIDevice.BatteryState) -> Bool {
        guard state != .charging, state != .full, level >= 0 else { return false }
        return level < SyncConfig.databaseUpgradeMinimumBatteryLevel
    }

    /// Upgrade now: starts the upgrade while the device has room and power. The
    /// screen is checked after the read: a second tap (or a repeated VoiceOver
    /// activation) while the first tap's read runs finds the upgrade under way
    /// (`run` sets `.upgrading` before its first wait) and starts nothing.
    func upgradeNow() async {
        await refreshConditions()
        guard screen == .notice, canStart, needsUpgrade else { return }
        await run()
    }

    /// The app is active again: an upgrade the suspension stopped starts again.
    /// Called from the upgrade screen's scene-phase handler in a `Task`, so the
    /// return's own start (`ForegroundPollStart`, called synchronously in the same
    /// change) runs first; this run's pause then stops polling again, and its exit
    /// turns it back on.
    func appBecameActive() async {
        guard continuesOnReturn, isPresented else { return }
        await run()
    }

    /// The upgrade in upgrade mode: the full-screen spinner keeps
    /// the user out of the app, and the light pause quiets the database, so the
    /// rewrite runs faster and its final TRUNCATE can empty the WAL (which then holds
    /// a second copy of the database). The pause is the two stops the app already
    /// makes on going to the background, and adds no gate, queue or layer:
    ///
    /// 1. `SyncScheduler.stopPolling`: the poll timer, IMAP IDLE and the
    ///    foreground maintenance pass.
    /// 2. `SyncScheduler.cancelAllInFlightQueues(inboxOnly: false)`: every body, AI
    ///    and embedding queue is emptied and its running tasks cancelled.
    ///
    /// Nothing else is held, the accounts' sync turns included. Anything else that
    /// starts meanwhile (a push, a network change, the outbox, action and calendar
    /// drains, the extension's staged-mail merge, a return to the app) waits behind
    /// SQLite's writer and catches up after. While the upgrade runs, the foreground
    /// sync timing promises wait for it: the one-time exception (ADR-IOS-121).
    ///
    /// Everything is turned back on at every exit: the one
    /// `defer` after the stop runs `SyncScheduler.startForegroundPolling` (a sync at
    /// once, the poll timer, IDLE, and the sync refills the queues) when the
    /// upgrade is done, failed, short of space (found before the rewrite, or the disk
    /// filled during it and it rolled back), or rolled back by a suspension,
    /// while the app is active (`DatabaseSuspension.isAppActive`). An exit while the
    /// app is in the background starts nothing: going to the background has just
    /// stopped polling, and a foreground timer left on could fire in a later
    /// background wake. The return to the app turns everything back on through the
    /// app's own `ForegroundPollStart` in `RootView` (every change to an active
    /// scene starts foreground polling). The pause lives only in memory, so a
    /// relaunch after the app is killed starts with everything on.
    ///
    /// When the databases are suspended mid-rewrite (the app left, its background
    /// time ran out), the rewrite rolls back while it builds its copy, and the
    /// upgrade starts again when the app is active (`appBecameActive`).
    private func run() async {
        screen = .upgrading
        continuesOnReturn = false
        ranOutOfSpace = false
        scheduler.stopPolling()
        defer { if DatabaseSuspension.isAppActive { scheduler.startForegroundPolling() } }
        await SyncScheduler.cancelAllInFlightQueues(inboxOnly: false)
        let steps = await upgradeDatabases()
        BackgroundSyncLogger.logDebug("[DatabaseUpgrade] ended: \(steps)")
        if steps.contains(where: { if case .stopped = $0 { true } else { false } }) {
            continuesOnReturn = true
            return
        }
        await refreshConditions()
        ranOutOfSpace = steps.contains { if case .ranOutOfSpace = $0 { true } else { false } }
        if ranOutOfSpace || steps.contains(where: { if case .needsSpace = $0 { true } else { false } }) {
            screen = .notice
        } else if steps.contains(where: { if case .failed = $0 { true } else { false } }) || needsUpgrade {
            screen = .failed
        } else {
            screen = .done
        }
    }

    /// The inbox is shown (RootView's `.task`): once the launch is ready and
    /// `SyncConfig.databaseUpgradeNoticeQuietDelaySeconds` after the inbox has painted,
    /// reads both databases for the banner, then shows the notice by itself, once per
    /// install, only while the app is active and nothing else is presented over the
    /// inbox. Any of those not met: it does not show now and is offered again at the
    /// next launch. After it has shown, only the banner opens it.
    ///
    /// The read comes after the launch gate and the quiet delay, never on the first
    /// render: the search database's read opens the search index, which the app opens
    /// only after the first paint (`TabMailApp.deferredSearchIndexInitIfNeeded`). The
    /// check and the presentation follow the read with no wait between them, so the
    /// notice never opens over a sheet that appeared while the read ran.
    func checkAfterLaunch() async {
        guard await AppStartup.shared.awaitLaunchReady(background: false) else { return }
        do {
            try await Task.sleep(for: .seconds(SyncConfig.databaseUpgradeNoticeQuietDelaySeconds))
        } catch { return }
        await refreshConditions()
        guard needsUpgrade, !UserDefaults.standard.bool(forKey: Self.noticeOfferedKey),
              UIApplication.shared.applicationState == .active, !isPresented, !Self.somethingIsPresented() else { return }
        UserDefaults.standard.set(true, forKey: Self.noticeOfferedKey)
        screen = .notice
        isPresented = true
    }

    /// A sheet or full-screen cover is up over the app's root view.
    private static func somethingIsPresented() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }

    /// The rewrite of the app's two databases, with the app's free-space reading
    /// and suspension check.
    nonisolated static func upgradeTheAppsDatabases() async -> [SyncEngine.UpgradeStep] {
        let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.dbPool)
        return await SyncEngine.runDatabaseUpgrade(targets: targets)
    }

    /// The app's two databases' paths and states, read off the main thread: the
    /// email database's read is synchronous.
    nonisolated static func readTheAppsStates() async -> [DatabaseState] {
        await Task.detached(priority: .medium) {
            let targets = await SyncEngine.appSpaceReturnTargets(emailPool: AppDatabase.dbPool)
            var states: [DatabaseState] = []
            for target in targets {
                states.append(DatabaseState(path: target.path, state: await target.state()))
            }
            return states
        }.value
    }
}
