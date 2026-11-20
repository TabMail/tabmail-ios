/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Network
import Observation
import Synchronization
import UIKit

/// The facts of one network path that the Wi-Fi-only download rule reads
/// (`SyncEngine.onUnmeteredWiFi`, #1064): whether the path is satisfied, whether
/// it uses Wi-Fi, and whether iOS marks it expensive. A Personal Hotspot is a
/// satisfied Wi-Fi path that is expensive.
struct NetworkPathFacts: Sendable, Equatable {
    let satisfied: Bool
    let usesWiFi: Bool
    let isExpensive: Bool

    init(satisfied: Bool, usesWiFi: Bool, isExpensive: Bool) {
        self.satisfied = satisfied
        self.usesWiFi = usesWiFi
        self.isExpensive = isExpensive
    }

    init(path: NWPath) {
        self.init(satisfied: path.status == .satisfied, usesWiFi: path.usesInterfaceType(.wifi), isExpensive: path.isExpensive)
    }
}

/// Monitors network connectivity and triggers action queue drain on reconnect.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true
    /// True when on cellular or personal hotspot (metered connection).
    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network-monitor")

    /// Track previous WiFi state to detect WiFi ↔ cellular transitions.
    /// nil = first update (don't trigger reconnect).
    private var wasOnWiFi: Bool?

    /// Mutex-backed values for nonisolated reads from background actors.
    /// Written alongside @Observable properties on MainActor.
    nonisolated private static let connectedMutex = Mutex(true)
    /// The latest path update's expensive flag; nil until the first path update
    /// (an unknown network). Only a started monitor writes it, and only RootView's
    /// `.task` starts it, so a process launched into the background (a background
    /// processing job, a silent push) keeps it unknown (#1064).
    nonisolated private static let expensiveMutex = Mutex<Bool?>(initialExpensive)
    /// The latest path update's facts for the Wi-Fi-only download rule; nil until
    /// the first path update, like `expensiveMutex` (#1064).
    nonisolated private static let pathFactsMutex = Mutex<NetworkPathFacts?>(
        initialExpensive.map { NetworkPathFacts(satisfied: true, usesWiFi: !$0, isExpensive: $0) })

    #if DEBUG
    /// The unit-test host never starts the monitor (no scene reaches RootView's
    /// `.task`), and its suites were written against an unmetered network, so the
    /// test host starts from that known value. Tests of the unknown state set it
    /// explicitly with `setExpensiveForTesting(nil)`.
    nonisolated private static let initialExpensive: Bool? = {
        let environment = ProcessInfo.processInfo.environment
        let isUnitTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        return isUnitTestHost ? false : nil
    }()
    #else
    nonisolated private static let initialExpensive: Bool? = nil
    #endif

    /// Read connectivity from any isolation context without MainActor hop.
    nonisolated static func checkConnected() -> Bool {
        connectedMutex.withLock { $0 }
    }

    #if DEBUG
    /// Scoped native fixtures restore the prior cached value after their drain joins.
    nonisolated static func setConnectedForTesting(_ connected: Bool) {
        connectedMutex.withLock { $0 = connected }
    }

    /// Scoped fixtures set an expensive (cellular) network, or nil for a network
    /// no path update has reported yet, and restore the prior cached value when
    /// they end.
    /// The path facts follow: an expensive network is cellular, a cheap one Wi-Fi.
    /// A test of a metered Wi-Fi path (a Personal Hotspot) uses `setPathFactsForTesting`.
    nonisolated static func setExpensiveForTesting(_ expensive: Bool?) {
        expensiveMutex.withLock { $0 = expensive }
        pathFactsMutex.withLock { $0 = expensive.map { NetworkPathFacts(satisfied: true, usesWiFi: !$0, isExpensive: $0) } }
    }

    /// Sets the path facts (and the expensive flag they carry), or nil for a
    /// network no path update has reported yet.
    nonisolated static func setPathFactsForTesting(_ facts: NetworkPathFacts?) {
        pathFactsMutex.withLock { $0 = facts }
        expensiveMutex.withLock { $0 = facts?.isExpensive }
    }
    #endif

    /// Read expensive-network flag from any isolation context without MainActor hop.
    /// An unknown network (no path update yet) reads as not expensive, as it
    /// always has for these callers; a download gate reads `checkExpensiveIfKnown`.
    nonisolated static func checkExpensive() -> Bool {
        expensiveMutex.withLock { $0 } ?? false
    }

    /// The expensive-network flag, or nil while no path update has reported the
    /// network (the monitor is not started yet).
    nonisolated static func checkExpensiveIfKnown() -> Bool? {
        expensiveMutex.withLock { $0 }
    }

    /// The latest path's facts, or nil while no path update has reported the
    /// network. The older-mail download gate reads them through
    /// `SyncEngine.onUnmeteredWiFi` and holds on nil, as the job's measurement
    /// holds on its timeout (#1064).
    nonisolated static func checkPathFactsIfKnown() -> NetworkPathFacts? {
        pathFactsMutex.withLock { $0 }
    }

    private init() {}

    func start() {
        BackgroundSyncLogger.log("NetworkMonitor: start()")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let wasConnected = self?.isConnected ?? true
                let connected = path.status == .satisfied
                let expensive = path.isExpensive
                self?.isConnected = connected
                self?.isExpensive = expensive
                // Keep Mutex backing in sync for nonisolated readers
                NetworkMonitor.connectedMutex.withLock { $0 = connected }
                NetworkMonitor.expensiveMutex.withLock { $0 = expensive }
                NetworkMonitor.pathFactsMutex.withLock { $0 = NetworkPathFacts(path: path) }

                let isOnWiFi = path.usesInterfaceType(.wifi)
                let interfaceChanged = self?.wasOnWiFi != nil && self?.wasOnWiFi != isOnWiFi
                self?.wasOnWiFi = isOnWiFi

                // Only do heavy work (reconnect, drain) if the app is in foreground.
                // In background, iOS gives very limited execution time for path updates.
                // Foreground return (startForegroundPolling) handles reconnect + drain.
                let isForeground = UIApplication.shared.applicationState == .active

                BackgroundSyncLogger.log("NetworkMonitor: pathUpdate connected=\(connected) wasConnected=\(wasConnected) wifi=\(isOnWiFi) expensive=\(expensive) fg=\(isForeground) interfaceChanged=\(interfaceChanged)")

                if !wasConnected && path.status == .satisfied {
                    // Network restored — schedule BGAppRefresh so IMAP accounts sync soon.
                    // This covers the case where BGAppRefresh was skipped due to no network.
                    // Lightweight: just submits a request to iOS, no heavy work here.
                    BackgroundSyncLogger.log("NetworkMonitor: network RESTORED — scheduling BGAppRefresh")
                    SyncScheduler.shared.scheduleBackgroundSync()

                    if isForeground {
                        BackgroundSyncLogger.logDebug("[NetworkMonitor] Connection restored (foreground) — draining queues")
                        BackgroundSyncLogger.log("NetworkMonitor: network restored (fg) — draining queues")
                        await AccountManager.shared.drainPendingQueue()
                        await AccountManager.shared.drainOutbox()
                        await AccountManager.shared.drainCalendarQueue()
                    }
                }

                // WiFi ↔ cellular transition while still connected: TCP connections
                // (WebSocket, IMAP) are bound to the old interface and effectively dead.
                // Reconnect IMAP providers (has built-in debounce).
                // Skip if not foreground — startForegroundPolling handles reconnect on return.
                if interfaceChanged && path.status == .satisfied && isForeground {
                    BackgroundSyncLogger.logDebug("[NetworkMonitor] Interface changed (wifi=\(isOnWiFi)) — marking all providers dirty")
                    BackgroundSyncLogger.log("NetworkMonitor: interface changed wifi=\(isOnWiFi) (fg) — marking dirty")
                    await AccountManager.shared.markAllProvidersDirty()
                    // Don't drain again — connection-restored block above already drained,
                    // or if wasConnected was true (pure interface switch), drain once.
                    if wasConnected {
                        await AccountManager.shared.drainPendingQueue()
                        await AccountManager.shared.drainOutbox()
                        await AccountManager.shared.drainCalendarQueue()
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
