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

    /// Whether to use APNs sandbox or production — derived from the build's
    /// ACTUAL `aps-environment` entitlement (read once from
    /// `embedded.mobileprovision`), NOT `#if DEBUG`.
    ///
    /// Why not `#if DEBUG`: a Release-config build installed directly on device,
    /// or a development-signed archive, is DEBUG-undefined yet ships
    /// `aps-environment=development` (so iOS hands it a SANDBOX token). Trusting
    /// `#if DEBUG` there reports `false` (production), so the worker sends that
    /// sandbox token to the PRODUCTION APNs host — Apple accepts it (200) but
    /// SILENTLY DROPS delivery and the Push Console shows "device doesn't exist".
    /// That's the class of bug that made smart push never arrive on dev/Release
    /// builds. App Store builds have no embedded profile (Apple strips it) → we
    /// fall back to `#if DEBUG` (release ⇒ production), which is correct there.
    /// TestFlight keeps a profile with `aps-environment=production` → production.
    static let isAPNsSandbox: Bool = {
        if let apsEnv = apsEnvironmentFromEmbeddedProfile() {
            return apsEnv == "development"
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Extract `Entitlements.aps-environment` from the app's embedded
    /// provisioning profile. The file is a CMS-signed blob with the profile
    /// plist embedded as plaintext between `<plist …>` and `</plist>`. Returns
    /// nil when there's no profile (App Store builds) or it can't be parsed.
    private static func apsEnvironmentFromEmbeddedProfile() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // isoLatin1 is byte-preserving, so the binary CMS wrapper doesn't
              // corrupt the ASCII plist region we slice out below.
              let raw = String(data: data, encoding: .isoLatin1),
              let lo = raw.range(of: "<plist"),
              let hi = raw.range(of: "</plist>") else { return nil }
        let plistText = String(raw[lo.lowerBound..<hi.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any],
              let apsEnv = entitlements["aps-environment"] as? String else { return nil }
        return apsEnv
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
