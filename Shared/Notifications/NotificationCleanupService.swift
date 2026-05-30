/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UserNotifications

enum NotificationCleanupConfig {
    static let activeTTLSeconds: TimeInterval = 24 * 60 * 60
    static let passiveTTLSeconds: TimeInterval = 24 * 60 * 60
}

/// Test-friendly snapshot of the bits of `UNNotification` the policy reads.
/// Lets `identifiersToRemove` be a pure function with no system-API dependency.
struct DeliveredNotificationSnapshot: Equatable {
    let identifier: String
    let date: Date
    let interruptionLevel: UNNotificationInterruptionLevel
    let providerTag: String?
    let accountEmail: String?
    let reconnectState: String?
}

enum NotificationCleanupService {

    /// Time-based sweep. Removes:
    ///   - active   notifications older than activeTTLSeconds
    ///   - passive  notifications older than passiveTTLSeconds
    ///   - imap_reconnect failure variants proven stale by PushHealthStore
    /// Idempotent. Safe to call from NSE, silent push, BGAppRefresh.
    static func sweepExpired() async {
        await sweep(passiveAllAges: false)
    }

    /// Foreground sweep. Removes:
    ///   - ALL passive notifications (regardless of age)
    ///   - active notifications older than activeTTLSeconds
    ///   - imap_reconnect failure variants proven stale by PushHealthStore
    static func sweepOnForeground() async {
        await sweep(passiveAllAges: true)
    }

    private static func sweep(passiveAllAges: Bool) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let snaps = delivered.map(snapshot(from:))
        let toRemove = identifiersToRemove(
            snaps,
            now: Date(),
            passiveAllAges: passiveAllAges,
            lastNonReconnectPushAt: PushHealthStore.snapshotAll()
        )
        guard !toRemove.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: toRemove)
    }

    // MARK: - Pure logic (unit-tested)

    static func identifiersToRemove(
        _ snaps: [DeliveredNotificationSnapshot],
        now: Date,
        passiveAllAges: Bool,
        lastNonReconnectPushAt: [String: Date]
    ) -> [String] {
        var out: [String] = []
        for s in snaps {
            guard !shouldExclude(s, lastNonReconnectPushAt: lastNonReconnectPushAt) else { continue }
            let age = now.timeIntervalSince(s.date)
            let isPassive = s.interruptionLevel == .passive
            let expired: Bool = isPassive
                ? (passiveAllAges || age >= NotificationCleanupConfig.passiveTTLSeconds)
                : (age >= NotificationCleanupConfig.activeTTLSeconds)
            if expired { out.append(s.identifier) }
        }
        return out
    }

    /// Exclusion rules:
    ///   - consent_error: ALWAYS excluded — re-auth prompt, must persist until
    ///     user taps or dismisses manually.
    ///   - imap_reconnect with reconnect_state == "ok" (success-ack): NOT
    ///     excluded — informational, ages out as a normal active.
    ///   - imap_reconnect (failure / in-progress variants): excluded UNLESS a
    ///     non-reconnect push for the same account has arrived AFTER this
    ///     notification's delivery date (push proven restored, per-account).
    static func shouldExclude(
        _ s: DeliveredNotificationSnapshot,
        lastNonReconnectPushAt: [String: Date]
    ) -> Bool {
        switch s.providerTag {
        case "consent_error":
            return true
        case "imap_reconnect":
            if s.reconnectState == "ok" { return false }
            guard let acct = s.accountEmail,
                  let lastOK = lastNonReconnectPushAt[acct] else {
                return true
            }
            return lastOK <= s.date
        default:
            return false
        }
    }

    // MARK: - Bridging

    private static func snapshot(from n: UNNotification) -> DeliveredNotificationSnapshot {
        DeliveredNotificationSnapshot(
            identifier: n.request.identifier,
            date: n.date,
            interruptionLevel: n.request.content.interruptionLevel,
            providerTag: n.request.content.userInfo["provider"] as? String,
            accountEmail: n.request.content.userInfo["accountEmail"] as? String,
            reconnectState: n.request.content.userInfo["reconnect_state"] as? String
        )
    }
}
