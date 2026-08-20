/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// Ephemeral gate that tracks whether the user has an active AI subscription.
/// When closed (402/403 from backend), AI queue processing is skipped and shimmers are hidden.
/// Resets on: successful AI response, sign-in, foreground return, or periodic recheck.
///
/// **Initial value:** hydrated from UserDefaults (last-known state persisted on each
/// `openGate`/`closeGate`). On first-ever launch both `isActive` and `hasCheckedOnce`
/// are false — UI layers should gate the sidebar subscribe banner on
/// `hasCheckedOnce` to avoid flashing the banner on boot before whoami confirms
/// subscription state. Returning subscribers see the last-known state immediately
/// (no flash) and whoami reconfirms asynchronously.
///
/// **Banner wording:** a fresh account now starts on a server-granted free trial,
/// so it is *active* and shows no banner at all. The banner is therefore reached
/// either by a user who never had a trial (generic "Start Your Free Trial" copy)
/// or by one whose trial has run out — `trialHasEnded` distinguishes the two and
/// is stamped from the same authoritative whoami that opens/closes the gate.
///
/// `@Observable`: SwiftUI views that read `isActive` / `hasCheckedOnce` auto-subscribe
/// and re-render on transitions. Mutations must run on MainActor so the observation
/// callback schedules the re-render on the UI actor and the Bool write is race-free
/// (the @Observable registrar is thread-safe internally, but the stored property
/// itself is not).
@Observable
final class AISubscriptionGate: @unchecked Sendable {
    static let shared = AISubscriptionGate()

    /// UserDefaults key for last-known `isActive`. Persisted on each transition so
    /// subsequent launches hydrate the correct state without flashing the banner.
    private static let lastKnownActiveKey = "ai_subscription_last_known_active"
    /// UserDefaults key for `hasCheckedOnce`. Once true, stays true — indicates
    /// we've received at least one authoritative whoami response in this install's
    /// lifetime. UI gates the trial banner on this flag.
    private static let hasCheckedOnceKey = "ai_subscription_has_checked_once"
    /// UserDefaults key for `trialHasEnded`. Persisted for the same reason as
    /// `isActive`: the sidebar banner renders from last-known state on launch,
    /// so an un-persisted flag would show generic copy and then swap wording
    /// once whoami lands.
    private static let trialHasEndedKey = "ai_subscription_trial_has_ended"

    /// Whether AI features are available (subscription active).
    /// When false, AI queue skips dispatch and shimmers are suppressed.
    /// Reads: any actor (SwiftUI body reads from main). Writes: main actor only
    /// (see `openGate` / `closeGate`).
    private(set) var isActive: Bool

    /// Whether whoami has ever authoritatively reported subscription state in
    /// this install. Starts false on first-ever launch, flips true on the first
    /// successful `openGate` or `closeGate`, and stays true thereafter (persisted).
    /// UI should hide the subscribe banner while this is false — otherwise the
    /// default-closed gate produces a false-positive banner flash on boot before
    /// the backend responds.
    private(set) var hasCheckedOnce: Bool

    /// Whether the most recent authoritative whoami described an account whose
    /// free trial has ENDED (no active subscription, trial end date in the past).
    /// Purely a copy selector for the subscribe banner — it never gates access,
    /// and it stays false for every account that has no trial information at all.
    /// Only `apply(_:now:)` writes it; the bare `openGate`/`closeGate` calls made
    /// by AI 402/403 paths leave the last-known value alone (they carry no trial
    /// information, and guessing "not ended" there would flip correct copy back).
    private(set) var trialHasEnded: Bool

    /// Timestamp of the most recent authoritative `/whoami` applied in THIS
    /// process. In-memory only, deliberately NOT persisted: `isActive` /
    /// `hasCheckedOnce` hydrate from UserDefaults so returning users see
    /// last-known UI without a flash, but a ROUTING decision (the
    /// `pending_plan_navigation` latch — see `PendingPlanNavigationLatch`)
    /// must never fire on that hydrated default, because it can describe a
    /// previous session or a previous account. Consumers wait until this is
    /// non-nil before acting on `isActive`.
    ///
    /// Only `apply(_:now:)` writes it: the bare `openGate`/`closeGate`
    /// calls from AI 402/403 paths and the post-purchase
    /// `refreshAfterLocalPurchase` do not carry full whoami authority for
    /// routing. Cleared by `noteSignedOut()` so a subsequent sign-in cannot
    /// inherit the previous account's freshness.
    private(set) var lastAuthoritativeApplyAt: Date?

    /// Monotonic sign-in epoch for this process. Bumped by `noteSignedOut()`.
    /// A `/whoami` fetch belongs to the epoch in which it STARTED; a response
    /// that lands after the user signed out (and possibly after someone else
    /// signed in) must not be applied — the bearer token it carried, and the
    /// entitlement it describes, belong to the previous account. Callers of
    /// the async fetch→apply pipelines capture this value BEFORE the network
    /// await and hand it to `applyIfCurrentEpoch`. In-memory only, like
    /// `lastAuthoritativeApplyAt`.
    private(set) var signInGeneration: Int = 0

    private init() {
        let defaults = UserDefaults.standard
        self.isActive = defaults.bool(forKey: Self.lastKnownActiveKey)
        self.hasCheckedOnce = defaults.bool(forKey: Self.hasCheckedOnceKey)
        self.trialHasEnded = defaults.bool(forKey: Self.trialHasEndedKey)
    }

    /// Apply an authoritative `/whoami` result: open or close the gate, and
    /// record whether the account's free trial has ended. Single seam so the
    /// two signals can never disagree about the same response.
    ///
    /// - Parameter now: injected for tests; production callers use the default.
    @MainActor
    func apply(_ info: AccountInfo, now: Date = Date()) {
        if info.hasSubscription == true {
            openGate()
        } else {
            closeGate()
        }
        setTrialHasEnded(info.trialState(now: now) == .ended)
        lastAuthoritativeApplyAt = now
    }

    /// Forget this process's authoritative-whoami freshness marker. Called on
    /// sign-out: whatever `/whoami` said about the outgoing account must not
    /// vouch for the next one, or a latch consumer could route the new user
    /// on the old user's entitlement. Leaves `isActive` / `hasCheckedOnce` /
    /// `trialHasEnded` untouched — last-known UI state deliberately follows
    /// the most recently signed-in account (see the trial-derivation memory
    /// topic's "GLOBAL, not account-scoped" decision).
    @MainActor
    func noteSignedOut() {
        lastAuthoritativeApplyAt = nil
        signInGeneration &+= 1
    }

    /// Apply an authoritative `/whoami` result ONLY if it was fetched in the
    /// current sign-in epoch. The guard closes the cross-account seam: a
    /// revalidation fetch started for account A can complete after A signed
    /// out (and after account B signed in); applying it would stamp
    /// `lastAuthoritativeApplyAt` — and set `isActive` — from A's
    /// entitlement, which the plan-picker latch consumer would then treat as
    /// authoritative for B (routing an active B to the paywall, or silently
    /// clearing an unentitled B's latch). Delegates to `apply(_:now:)`, which
    /// remains the single authoritative seam.
    ///
    /// - Parameters:
    ///   - generation: the value of `signInGeneration` read BEFORE the fetch
    ///     began.
    ///   - now: injected for tests; production callers use the default.
    @MainActor
    func applyIfCurrentEpoch(_ info: AccountInfo, fetchedInGeneration generation: Int, now: Date = Date()) {
        guard generation == signInGeneration else { return }
        apply(info, now: now)
    }

    /// Refresh from a `/whoami` body fetched immediately after a LOCAL StoreKit
    /// purchase or restore has already `openGate()`d. Unlike `apply`, this seam
    /// can only ever OPEN the gate, never close it: the body it receives races
    /// the detached backend verification (`verifyPurchaseWithBackend`) and may
    /// still describe the pre-purchase account (`has_subscription:false`), so
    /// closing on it would slam shut the gate the user just paid to open. Local
    /// StoreKit entitlement is authoritative for a just-completed purchase; the
    /// next authoritative whoami (foreground/sign-in revalidation, once the
    /// backend write has landed) reconciles through `apply` as usual.
    ///
    /// Opens the gate and stamps the trial-ended flag (always `false` in this
    /// branch — an active subscription has no ended trial) only when the body
    /// already confirms the subscription; otherwise it is a no-op that touches
    /// nothing, leaving the locally-opened gate — and the last-known trial copy —
    /// exactly as they were.
    ///
    /// - Parameter now: injected for tests; production callers use the default.
    @MainActor
    func refreshAfterLocalPurchase(_ info: AccountInfo, now: Date = Date()) {
        guard info.hasSubscription == true else { return }
        openGate()
        setTrialHasEnded(info.trialState(now: now) == .ended)
    }

    /// Close the gate — called when AI backend returns 402 or 403, or when
    /// whoami reports no active subscription. Idempotent re: value, but always
    /// stamps `hasCheckedOnce` (whoami has authoritatively responded, even if
    /// the value didn't change).
    @MainActor
    func closeGate() {
        stampChecked()
        guard isActive else { return }
        isActive = false
        UserDefaults.standard.set(false, forKey: Self.lastKnownActiveKey)
        print("[AISubscriptionGate] Gate CLOSED — subscription required")
    }

    /// Reopen the gate — called on successful AI response or whoami confirming subscription.
    @MainActor
    func openGate() {
        stampChecked()
        guard !isActive else { return }
        isActive = true
        UserDefaults.standard.set(true, forKey: Self.lastKnownActiveKey)
        print("[AISubscriptionGate] Gate OPENED — subscription confirmed")
    }

    @MainActor
    private func setTrialHasEnded(_ ended: Bool) {
        guard trialHasEnded != ended else { return }
        trialHasEnded = ended
        UserDefaults.standard.set(ended, forKey: Self.trialHasEndedKey)
    }

    @MainActor
    private func stampChecked() {
        guard !hasCheckedOnce else { return }
        hasCheckedOnce = true
        UserDefaults.standard.set(true, forKey: Self.hasCheckedOnceKey)
    }
}
