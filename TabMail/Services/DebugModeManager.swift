/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import Synchronization

/// Gates all debug features behind a hidden activation.
/// Tap the version label in TabMail Settings 10 times to unlock.
/// Once unlocked, persists until explicitly locked again.
/// Only allowed user IDs can unlock debug mode.
@MainActor @Observable
final class DebugModeManager {
    static let shared = DebugModeManager()

    private static let unlockedKey = "debug_mode_unlocked"
    private static let requiredTaps = 10

    /// Email domains allowed to unlock debug mode.
    /// Only accounts with these domains can activate debug features + debug logging.
    nonisolated private static let allowedEmailDomain = "tabmail.ai"

    /// Individual emails outside `allowedEmailDomain` allowed to unlock debug
    /// mode (e.g. external team members on personal Gmail used for video
    /// demos). Keep short — every entry bypasses the domain check.
    nonisolated private static let allowedEmails: Set<String> = [
        "tabmail.ai@gmail.com",
    ]

    nonisolated private static func isEmailAllowed(_ email: String) -> Bool {
        if email.hasSuffix("@\(allowedEmailDomain)") { return true }
        return allowedEmails.contains(email.lowercased())
    }

    /// Whether debug features are visible and usable.
    var isUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(isUnlocked, forKey: Self.unlockedKey)
            if !isUnlocked {
                // Reset dev servers to production when locking debug mode
                BackendConfig.useDevServers = false
            }
        }
    }

    /// Tracks consecutive taps on the version label.
    private(set) var tapCount = 0

    /// Remaining taps to show as feedback (nil = no feedback shown).
    var remainingTaps: Int? {
        let remaining = Self.requiredTaps - tapCount
        // Show feedback after 3 taps and before unlock
        if tapCount >= 3 && remaining > 0 {
            return remaining
        }
        return nil
    }

    private init() {
        self.isUnlocked = UserDefaults.standard.bool(forKey: Self.unlockedKey)
    }

    /// Override for tests — bypasses the user ID check when true.
    #if DEBUG
    var allowAllUsersForTesting = false
    #endif

    /// Whether the current logged-in user is allowed to use debug features.
    /// Checks the session email against the allowed domain.
    var isAllowedUser: Bool {
        #if DEBUG
        if allowAllUsersForTesting { return true }
        #endif
        guard let session = TabMailAuthService.getSession() else { return false }
        return Self.isEmailAllowed(session.userEmail)
    }

    /// Memoized result of the keychain-derived half of `isLoggingEnabled()`
    /// (session load + decode + domain check). `nil` = not yet computed.
    ///
    /// The session identity only changes on login/logout, so this is computed
    /// once and reused. Without it, every gated log call did a synchronous
    /// Keychain XPC (`SecItemCopyMatching` → `securityd`). Hit from the
    /// 100 ms main-thread `MainActorStallDetector` timer and once per backfilled
    /// body, that blocking call wedged the main thread while backfill held SQLite
    /// write locks during app suspension → `0xdead10cc` kill (TestFlight
    /// 1.6.16/324, debug-unlocked accounts only). Invalidated via
    /// `invalidateLoggingCache()` from the auth session save/clear sites.
    nonisolated private static let loggingAllowedCache = Mutex<Bool?>(nil)

    /// Whether debug logging should be active (unlocked AND allowed user).
    /// Called from BackgroundSyncLogger to gate file I/O in production.
    /// Static nonisolated so it can be called from any thread without MainActor hop.
    /// Reads UserDefaults (thread-safe) + a cached Keychain-derived flag, so the
    /// per-log-call hot path never blocks on a synchronous Keychain XPC.
    static nonisolated func isLoggingEnabled() -> Bool {
        let unlocked = UserDefaults.standard.bool(forKey: "debug_mode_unlocked")
        guard unlocked else { return false }
        return loggingAllowedCache.withLock { cache in
            if let cached = cache { return cached }
            // Read session directly from Keychain (thread-safe) to avoid MainActor
            // hop. Cached because SecItemCopyMatching is a synchronous XPC to
            // securityd — far too costly to run on every log call.
            let allowed: Bool
            if let data = KeychainHelper.load(key: "tabmail_session"),
               let session = try? JSONDecoder().decode(TabMailSession.self, from: data) {
                allowed = isEmailAllowed(session.userEmail)
            } else {
                allowed = false
            }
            cache = allowed
            return allowed
        }
    }

    /// Invalidate the `isLoggingEnabled()` cache. MUST be called whenever the
    /// stored session changes (login / logout) so the debug-logging gate
    /// re-evaluates against the new identity. Cheap and thread-safe.
    static nonisolated func invalidateLoggingCache() {
        loggingAllowedCache.withLock { $0 = nil }
    }

    /// Call on each version label tap. Returns true when debug mode is freshly unlocked.
    @discardableResult
    func registerTap() -> Bool {
        guard isAllowedUser else {
            tapCount = 0
            return false
        }
        tapCount += 1
        if tapCount >= Self.requiredTaps && !isUnlocked {
            isUnlocked = true
            tapCount = 0
            return true
        }
        return false
    }

    /// Resets the tap counter (e.g. when navigating away).
    func resetTapCount() {
        tapCount = 0
    }
}
