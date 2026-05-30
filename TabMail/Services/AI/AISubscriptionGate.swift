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
/// are false — UI layers should gate the "Start Your Free Trial" banner on
/// `hasCheckedOnce` to avoid flashing the banner on boot before whoami confirms
/// subscription state. Returning subscribers see the last-known state immediately
/// (no flash) and whoami reconfirms asynchronously.
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

    /// Whether AI features are available (subscription active).
    /// When false, AI queue skips dispatch and shimmers are suppressed.
    /// Reads: any actor (SwiftUI body reads from main). Writes: main actor only
    /// (see `openGate` / `closeGate`).
    private(set) var isActive: Bool

    /// Whether whoami has ever authoritatively reported subscription state in
    /// this install. Starts false on first-ever launch, flips true on the first
    /// successful `openGate` or `closeGate`, and stays true thereafter (persisted).
    /// UI should hide the "Start Your Free Trial" banner while this is false —
    /// otherwise the default-closed gate produces a false-positive banner flash
    /// on boot before the backend responds.
    private(set) var hasCheckedOnce: Bool

    private init() {
        let defaults = UserDefaults.standard
        self.isActive = defaults.bool(forKey: Self.lastKnownActiveKey)
        self.hasCheckedOnce = defaults.bool(forKey: Self.hasCheckedOnceKey)
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
    private func stampChecked() {
        guard !hasCheckedOnce else { return }
        hasCheckedOnce = true
        UserDefaults.standard.set(true, forKey: Self.hasCheckedOnceKey)
    }
}
