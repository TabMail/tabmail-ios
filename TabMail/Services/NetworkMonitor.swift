/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Network
import Observation
import Synchronization
import UIKit

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
    nonisolated private static let expensiveMutex = Mutex(false)

    /// Read connectivity from any isolation context without MainActor hop.
    nonisolated static func checkConnected() -> Bool {
        connectedMutex.withLock { $0 }
    }

    /// Read expensive-network flag from any isolation context without MainActor hop.
    nonisolated static func checkExpensive() -> Bool {
        expensiveMutex.withLock { $0 }
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
                        print("[NetworkMonitor] Connection restored (foreground) — draining queues")
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
                    print("[NetworkMonitor] Interface changed (wifi=\(isOnWiFi)) — marking all providers dirty")
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
