/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// Which usage-throttle banner (if any) the inbox should surface, derived from
/// the most recent `/whoami` response. Foundation-only (no SwiftUI) so the
/// store can compute it; the matching UI lives in `UsageThrottleBanner`.
enum UsageThrottleBannerKind: Equatable {
    /// Basic plan that has exhausted its monthly priority budget — background
    /// AI processing now flows through the slow (throttled) queue. CTA: upgrade
    /// to Pro.
    case upgradeToPro
    /// BYOK plan with no provider key configured. Per ADR-025 a BYOK user with
    /// no own key is permanently on the slow shared queue; once they add a key,
    /// requests route through their own provider (fast). CTA: set up API keys.
    case configureKeys
}

/// Tracks whether the user's background AI processing is being throttled, based
/// on the cached `/whoami` plan/queue state, and decides which (if any) inbox
/// banner to show.
///
/// **Signal source:** `AccountInfo.queueMode` / `quotaPercentage` / `planTier`
/// from `/whoami`. The backend flips a Basic user to the slow queue once they
/// exceed their monthly cost budget (`queue_mode == "slow"` / `quota >= 100`),
/// and reports BYOK as slow whenever the user hasn't supplied their own key
/// (ADR-025). We do NOT introduce a new poll — `update(from:)` is fed from the
/// existing always-on foreground `/whoami` fetch in
/// `RootView.revalidateAISubscriptionGate()`.
///
/// `@Observable`: SwiftUI views that read `banner` auto-subscribe (the computed
/// getter reads the observable stored properties) and re-render on transitions.
/// Mutations run on MainActor (matches `AISubscriptionGate`). `hasCheckedOnce`
/// stays in-memory (not persisted) so the banner never flashes on cold launch
/// before the first authoritative `/whoami` lands.
@Observable
final class UsageThrottleStore: @unchecked Sendable {
    static let shared = UsageThrottleStore()
    private init() {}

    /// Plan tier from the last `/whoami` ("Basic" / "Pro" / "BYOK" / nil).
    private(set) var planTier: String?
    /// Whether the user's priority budget is exhausted (slow queue / quota full).
    private(set) var isThrottled: Bool = false
    /// Whether the user has at least one of their own provider API keys set.
    private(set) var hasOwnAPIKeys: Bool = false
    /// True once `update(from:)` has run at least once this launch. The banner
    /// stays hidden until then to avoid a boot-time flash.
    private(set) var hasCheckedOnce: Bool = false

    /// The banner to show on the inbox, or `nil`. Computed live from the cached
    /// `/whoami` state so any property change re-renders observing views.
    var banner: UsageThrottleBannerKind? {
        guard hasCheckedOnce else { return nil }
        switch planTier {
        case AccountPlanConfig.basicTierKey:
            // Only nudge once they've actually been throttled (exceeded budget).
            return isThrottled ? .upgradeToPro : nil
        case AccountPlanConfig.byokTierKey:
            // BYOK without an own key is permanently on the slow shared queue.
            // With a key, requests route through the user's provider (fast).
            return hasOwnAPIKeys ? nil : .configureKeys
        case AccountPlanConfig.proTierKey:
            // No throttle banner for Pro yet. Placeholder: when Max /
            // pay-as-you-go ship, add the Pro-tier upsell here.
            return nil
        default:
            // Unknown / no subscription — the sidebar subscribe surface
            // (MailNavigationView) covers these users. A free trial also lands
            // here deliberately: it runs on the shared queue for its whole
            // duration, so a throttle nudge would be permanent noise. The
            // account dashboard and plan picker carry that story instead.
            return nil
        }
    }

    /// Refresh the cached throttle state from a fresh `/whoami` result.
    @MainActor
    func update(from info: AccountInfo) {
        planTier = info.planTier
        isThrottled = (info.queueMode == "slow") || ((info.quotaPercentage ?? 0) >= 100)
        hasOwnAPIKeys = AIService.shared.byokBundle != nil
        hasCheckedOnce = true
    }

    /// Re-read just the BYOK key state — used after the user adds/removes a key
    /// so the BYOK banner reacts immediately without waiting for the next
    /// foreground `/whoami`.
    @MainActor
    func refreshKeyState() {
        hasOwnAPIKeys = AIService.shared.byokBundle != nil
    }

    #if DEBUG
    /// Force a banner state for SwiftUI previews — bypasses `/whoami` so the
    /// banner can be rendered in a live `InboxView` canvas without a real
    /// throttled account. DEBUG-only (stripped from release).
    @MainActor
    func previewConfigure(planTier: String?, isThrottled: Bool, hasOwnAPIKeys: Bool) {
        self.planTier = planTier
        self.isThrottled = isThrottled
        self.hasOwnAPIKeys = hasOwnAPIKeys
        self.hasCheckedOnce = true
    }
    #endif
}
