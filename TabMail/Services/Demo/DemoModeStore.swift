/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// Demo Mode runtime state. See `DECISIONS.md` (ADR-IOS-038).
///
/// Lifecycle:
/// - `isActive` is in-memory only (no persistence across launches).
/// - `callsConsumed` persists per-install in UserDefaults under
///   `demo.callsConsumed`. Survives app restart, demo exit, and re-entry.
/// - `startInProgress` gates the "Try the demo" button so user can't double-tap
///   while the JWT mint is in flight.
/// - `aiEnabled` mirrors what the user picked on the AI consent gate during
///   demo entry. Demo-specific — never read by production code paths.
///
/// All public mutations happen on the main actor. Counter consumes use a
/// dedicated `consumeCall` / `refundCall` API so the refund matrix is
/// expressed at one site, not duplicated at every chokepoint.
@MainActor
@Observable
final class DemoModeStore {
    static let shared = DemoModeStore()

    /// User-visible call budget for the demo.
    static let totalCallBudget = 50

    /// UserDefaults keys (per-install). Cleared only by uninstall.
    private enum Keys {
        static let callsConsumed = "demo.callsConsumed"
        static let hasCompletedConsentGate = "demo.hasCompletedConsentGate"
        static let hasSeenAIConsent = "demo.hasSeenAIConsent"
        static let aiEnabled = "demo.aiEnabled"
    }

    /// Whether demo mode is currently active for this app session.
    var isActive: Bool = false

    /// Mid-flight JWT mint flag. Login button disables while true.
    var startInProgress: Bool = false

    /// Persistent counter — number of LLM calls consumed across all demo
    /// sessions on this install.
    private(set) var callsConsumed: Int = UserDefaults.standard.integer(forKey: Keys.callsConsumed)

    /// Number of calls remaining in the budget.
    var callsRemaining: Int { max(0, Self.totalCallBudget - callsConsumed) }

    /// True when the user is at the budget cap. UI layer surfaces this as
    /// "AI call limit reached"; counter consumption short-circuits.
    var isCallBudgetExhausted: Bool { callsRemaining == 0 }

    private init() {}

    // MARK: - Persistent flags

    var hasCompletedConsentGate: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasCompletedConsentGate) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasCompletedConsentGate) }
    }

    var hasSeenAIConsent: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasSeenAIConsent) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasSeenAIConsent) }
    }

    /// Whether the user accepted AI on the demo's AI consent gate. Drives the
    /// AI-disabled rendering path.
    var aiEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.aiEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.aiEnabled) }
    }

    // MARK: - Counter API

    /// Consume one call from the demo budget. Caller MUST check
    /// `isCallBudgetExhausted` first; this method does not throw.
    ///
    /// Counter persists synchronously to UserDefaults so a crash mid-flight
    /// can't grant a double credit.
    func consumeCall() {
        callsConsumed += 1
        UserDefaults.standard.set(callsConsumed, forKey: Keys.callsConsumed)
        NotificationCenter.default.post(name: .demoCallsRemainingChanged, object: nil)
    }

    /// Refund a previously-consumed call. Used on transient errors:
    /// network drop, timeout, cancel, 5xx, demo-token 429. NOT refunded on
    /// 4xx (other than demo-throttle), parse failures, malformed requests.
    ///
    /// Refund is a hard floor at 0 — never goes negative.
    func refundCall() {
        guard callsConsumed > 0 else { return }
        callsConsumed -= 1
        UserDefaults.standard.set(callsConsumed, forKey: Keys.callsConsumed)
        NotificationCenter.default.post(name: .demoCallsRemainingChanged, object: nil)
    }

    /// Decide whether an error should refund the counter.
    /// Pure function — safe to call off the main actor.
    nonisolated static func shouldRefund(for error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cancelled, .networkConnectionLost,
                 .resourceUnavailable, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        // String-match for HTTPError: refund on 5xx and demo_token 429.
        // Project HTTPError stringifies as "HTTP <status>" or similar.
        let desc = String(describing: error)
        if desc.contains("5") && (desc.contains("503") || desc.contains("502") || desc.contains("500") || desc.contains("504")) {
            return true
        }
        if desc.contains("demo_token") {
            return true
        }
        return false
    }

    // MARK: - Test helpers

    /// Test-only — reset counter and flags. Not exposed to release UI.
    func _resetForTests() {
        callsConsumed = 0
        UserDefaults.standard.set(0, forKey: Keys.callsConsumed)
        UserDefaults.standard.set(false, forKey: Keys.hasCompletedConsentGate)
        UserDefaults.standard.set(false, forKey: Keys.hasSeenAIConsent)
        UserDefaults.standard.set(false, forKey: Keys.aiEnabled)
        isActive = false
        startInProgress = false
    }
}

extension Notification.Name {
    static let demoCallsRemainingChanged = Notification.Name("demoCallsRemainingChanged")
    static let demoModeDidExit = Notification.Name("demoModeDidExit")
}

/// Errors thrown from the demo entry / call paths.
enum DemoError: Error, LocalizedError {
    case callBudgetExhausted
    case startFailed(String)
    case notInDemo

    var errorDescription: String? {
        switch self {
        case .callBudgetExhausted:
            return "Demo AI call limit reached. Sign up to keep going."
        case .startFailed(let reason):
            return "Could not start demo: \(reason)"
        case .notInDemo:
            return "Not in demo mode."
        }
    }
}
