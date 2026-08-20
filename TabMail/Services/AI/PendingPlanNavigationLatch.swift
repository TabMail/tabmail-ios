/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Single owner of the `pending_plan_navigation` UserDefaults latch.
///
/// The latch records "route this user to the plan picker once we know they
/// need one". It is armed while entitlement is UNKNOWABLE — by the
/// signed-out sidebar subscribe banner (before sign-in) and by the
/// AI-consent onboarding screen (before the post-sign-in `/whoami` has
/// necessarily landed) — so the CONSUMER is where entitlement must be
/// enforced. Pre-fix (issue #56), the consumer navigated on a bare
/// `bool(forKey:)` read plus a 100 ms sleep, which deterministically sent
/// active subscribers to the paywall: the latch outlived the state it was
/// recorded under, and nothing between arming and navigation ever asked
/// the backend.
///
/// The consume rule, in one sentence: **navigate only on an authoritative
/// gate that is closed; on an authoritative gate that is open, clear the
/// latch silently; on a gate that has not been authoritatively applied
/// this process, keep the latch and wait.** "Authoritative" means
/// `AISubscriptionGate.lastAuthoritativeApplyAt != nil` — a real `/whoami`
/// body went through `AISubscriptionGate.apply` in this process — not the
/// UserDefaults-hydrated `isActive` default, and not merely
/// `hasCheckedOnce` (which persists across launches and accounts, so it
/// cannot vouch for THIS sign-in).
///
/// `MailNavigationView` invokes `consume` from an
/// `.onChange(of: gate.lastAuthoritativeApplyAt, initial: true)` observer,
/// so consumption is event-driven: it runs at mount (covering an apply
/// that landed before the view appeared) and again on every later apply
/// (covering the whoami that is still in flight at mount). No timed yield.
enum PendingPlanNavigationLatch {

    /// The UserDefaults key. Private on purpose — every reader and writer
    /// in the app routes through this type so the consume rule above
    /// cannot be bypassed by a stray `bool(forKey:)`.
    private static let key = "pending_plan_navigation"

    /// What a consume attempt decided. `noLatch` and
    /// `clearedWithoutNavigation` are distinct so the caller can restore
    /// its suppressed initial selection ONLY when a latch was actually
    /// consumed — an ordinary foreground revalidation with no latch
    /// pending must not touch navigation state at all.
    enum ConsumeOutcome: Equatable {
        /// Nothing pending — do nothing.
        case noLatch
        /// A latch is pending but no authoritative `/whoami` has been
        /// applied this process — latch kept, try again on the next apply.
        case waitForAuthoritativeGate
        /// Latch cleared; the gate is authoritatively closed and AI is
        /// enabled — navigate to the plan picker.
        case navigateToPlanPicker
        /// Latch cleared with no navigation: the gate is authoritatively
        /// open (active entitlement — the paywall would be wrong), or the
        /// user has opted out of AI entirely.
        case clearedWithoutNavigation
    }

    static func isSet(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// Arm the latch. Caller: the signed-out sidebar subscribe banner,
    /// immediately before presenting the sign-in sheet.
    static func set(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// Disarm the latch. Writes an explicit `false` rather than removing
    /// the key: a removed key falls through `UserDefaults(suiteName:)`
    /// isolation to `.standard` in tests, and an explicit value cannot.
    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: key)
    }

    /// Writer decision for the AI-consent onboarding screen's completion.
    /// Pre-fix this site set the latch when the gate was inactive and FELL
    /// THROUGH for an active subscriber with AI enabled, leaving any stale
    /// `true` armed — now every arm writes an explicit value:
    /// - AI declined → clear (the plan picker is an AI purchase).
    /// - Gate AUTHORITATIVELY open → clear (active entitlement; nothing to
    ///   buy). Authority matters: `isActive` hydrates from UserDefaults, so
    ///   a `true` left by a previous subscriber (previous launch or previous
    ///   account on this device) must count as UNKNOWN here, not as "open" —
    ///   clearing on it would silently deny a genuinely unentitled user the
    ///   plan picker forever, because the later authoritative closed
    ///   `/whoami` would find nothing to consume.
    /// - Otherwise → arm. The gate may merely be UNCHECKED here (fresh
    ///   device, whoami still in flight, or hydrated-active-unverified) —
    ///   that is fine, because `consume` is entitlement-aware and will clear
    ///   without navigating once the authoritative response reports an
    ///   active subscription.
    static func recordAfterAIConsent(
        aiEnabled: Bool,
        gateIsActive: Bool,
        gateIsAuthoritative: Bool,
        defaults: UserDefaults = .standard
    ) {
        if aiEnabled && !(gateIsActive && gateIsAuthoritative) {
            set(defaults)
        } else {
            clear(defaults)
        }
    }

    /// Consume the latch against the current gate state. Pure decision +
    /// the latch write; navigation itself stays with the caller.
    ///
    /// - Parameters:
    ///   - gateHasAuthoritativeState: `lastAuthoritativeApplyAt != nil` —
    ///     a `/whoami` body was applied in this process.
    ///   - gateIsActive: `AISubscriptionGate.isActive` at consume time.
    ///   - aiOptedOut: the global AI opt-out flag; an opted-out user never
    ///     navigates, but their latch is still cleared (matching the
    ///     pre-existing consumer's clear-then-check ordering).
    static func consume(
        gateHasAuthoritativeState: Bool,
        gateIsActive: Bool,
        aiOptedOut: Bool,
        defaults: UserDefaults = .standard
    ) -> ConsumeOutcome {
        guard isSet(defaults) else { return .noLatch }
        guard gateHasAuthoritativeState else { return .waitForAuthoritativeGate }
        clear(defaults)
        if aiOptedOut { return .clearedWithoutNavigation }
        return gateIsActive ? .clearedWithoutNavigation : .navigateToPlanPicker
    }
}
