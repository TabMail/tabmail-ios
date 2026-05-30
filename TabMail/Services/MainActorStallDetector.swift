/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Detects MainActor stalls by scheduling work from a background queue
/// onto the main queue at a regular interval and measuring the delay
/// between schedule time and execution time.
///
/// Under normal operation, the latency is a few milliseconds.
/// When MainActor is blocked (sync GRDB read, heavy computation, priority
/// inversion, UIKit transition hang, etc.), the main queue's async blocks
/// pile up; when MainActor is finally free, the block runs and measures
/// a latency equal to the stall duration.
///
/// Logs via `BackgroundSyncLogger.logInbox` so stalls show up in the
/// same persistent log stream as the inbox lifecycle events — easy to
/// correlate "stall fired at time T, preceded by X, Y, Z events".
///
/// Cost: one background timer tick + one main-queue dispatch every 100ms.
/// Negligible. Only logs when latency exceeds `stallThreshold`.
enum MainActorStallDetector {
    /// Minimum stall duration to log individually. 200ms catches visible UI
    /// hangs (>= 12 dropped display frames at 60fps) without noise from
    /// normal MainActor business.
    private static let stallThreshold: TimeInterval = 0.2

    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Start the detector. Idempotent — safe to call multiple times.
    /// Should be called once at app startup.
    static func start() {
        guard timer == nil else { return }
        let queue = DispatchQueue(label: "tabmail.mainactor.stalldetector", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler {
            let scheduledAt = Date()
            DispatchQueue.main.async {
                let latency = Date().timeIntervalSince(scheduledAt)
                if latency >= stallThreshold {
                    BackgroundSyncLogger.logInbox("[MainStall] \(Int(latency * 1000))ms")
                }
            }
        }
        t.resume()
        timer = t
    }
}
