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
    /// `UNNotificationContent.categoryIdentifier` (empty when none was set).
    var categoryIdentifier: String = ""
    /// Whether `userInfo` carries the `hash` key `ProactiveNotifyService` puts on
    /// its reminder and nudge notifications.
    var hasReminderHash: Bool = false
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

    /// Removes every delivered email banner (`isEmailBanner`), whatever its age.
    /// Run when the user opens the app (`EmailBannerOpenClear`). The badge is not
    /// touched.
    static func removeEmailBanners() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let toRemove = emailBannerIdentifiers(delivered.map(snapshot(from:)))
        guard !toRemove.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: toRemove)
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

    /// The identifiers of the email banners among `snaps`, in order.
    static func emailBannerIdentifiers(_ snaps: [DeliveredNotificationSnapshot]) -> [String] {
        snaps.filter(isEmailBanner).map(\.identifier)
    }

    /// An email banner is a new-email notification, by its content rather than its
    /// identifier: a banner the notification extension delivers keeps the push's
    /// system-assigned identifier (the push sets no collapse id), so only the
    /// banners the app posts itself use `EmailNotificationBuilder.identifier`.
    ///   - Kept: anything with `ProactiveNotifyService`'s `hash` (its reminders and
    ///     nudges, even a nudge built by `EmailNotificationBuilder.fill`).
    ///   - Email: a category `EmailNotificationBuilder.fill` sets (every new-email
    ///     path fills: the extension, its timeout partial, the app's reply banner,
    ///     the background merge).
    ///   - Email: a new-mail push the extension delivered bare, with no fill (its
    ///     `provider` is a new-mail push provider, so not `consent_error` or
    ///     `imap_reconnect`).
    ///   - Everything else is kept.
    static func isEmailBanner(_ s: DeliveredNotificationSnapshot) -> Bool {
        if s.hasReminderHash { return false }
        if EmailNotificationBuilder.categoryIdentifiers.contains(s.categoryIdentifier) { return true }
        guard let provider = s.providerTag else { return false }
        return EmailNotificationBuilder.newMailPushProviders.contains(provider)
    }

    // MARK: - Bridging

    private static func snapshot(from n: UNNotification) -> DeliveredNotificationSnapshot {
        DeliveredNotificationSnapshot(
            identifier: n.request.identifier,
            date: n.date,
            interruptionLevel: n.request.content.interruptionLevel,
            providerTag: n.request.content.userInfo["provider"] as? String,
            accountEmail: n.request.content.userInfo["accountEmail"] as? String,
            reconnectState: n.request.content.userInfo["reconnect_state"] as? String,
            categoryIdentifier: n.request.content.categoryIdentifier,
            hasReminderHash: n.request.content.userInfo["hash"] != nil
        )
    }
}
