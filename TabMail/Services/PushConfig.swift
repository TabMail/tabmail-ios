/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum PushConfig {
    /// Base URL for push notification worker API.
    /// Always production — Gmail Pub/Sub delivers to a single endpoint (push.tabmail.ai),
    /// so device registrations must be in the same KV that the prod webhook handler reads.
    /// The apnsSandbox flag handles APNs environment routing (sandbox vs production).
    /// Same rationale as CLAUDE.md rules #9 (single KV_ENTITLEMENTS) and #10 (single Stripe).
    static let baseURL = "https://push.tabmail.ai"

    /// Whether to use APNs sandbox or production.
    /// Only Xcode debug builds use sandbox APNs. Both TestFlight and App Store
    /// use production APNs (distribution provisioning profile sets aps-environment=production).
    /// NOTE: StoreKit's AppTransaction.environment returns .sandbox for TestFlight,
    /// but that's the StoreKit environment — APNs environment is independent and always
    /// production for any build signed with a distribution profile.
    static var isAPNsSandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - UserDefaults Keys

    /// Stable device identifier (UUID, generated once).
    static let deviceIdKey = "push_device_id"

    /// Last registered APNs device token (hex string).
    static let lastDeviceTokenKey = "push_last_device_token"

    /// List of account emails currently registered with the push worker.
    static let registeredEmailsKey = "push_registered_emails"

    /// Whether push notifications are enabled (user-facing setting).
    /// Default: true. When disabled, the push worker registration still happens
    /// but the NSE suppresses all non-error notifications.
    static let pushNotificationsEnabledKey = "push_notifications_enabled"

    /// Whether the NSE filtering entitlement is active (Apple-approved).
    /// When true, the NSE can fully suppress notifications (return empty content).
    /// When false, non-actionable pushes are delivered as passive "Inbox updated".
    /// Flip this to true once Apple grants com.apple.developer.usernotifications.filtering.
    static let nseFilteringApproved = false

    // MARK: - Constants

    /// Maximum time (seconds) to spend processing a silent push before returning.
    /// iOS kills the app after ~30s — we return early at 25s to leave headroom.
    static let silentPushDeadlineSeconds: TimeInterval = 25

    /// Per-account timeout for the foreground consent-status scan. Cold-launch
    /// RTT (DNS + TLS + server warm-up) regularly exceeds 3s, so the prior
    /// 3s budget produced false-positive "needs re-consent" flashes on the
    /// first scan at app boot. 10s leaves headroom without making the
    /// foreground scan feel laggy (runs in parallel across accounts anyway).
    static let consentStatusCheckTimeoutSeconds: TimeInterval = 10
}
