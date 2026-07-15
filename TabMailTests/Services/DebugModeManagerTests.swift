/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DebugModeManager", .serialized, .processGlobalState)
@MainActor
struct DebugModeManagerTests {

    private let unlockedKey = "debug_mode_unlocked"
    private let devServersKey = "debug_use_dev_servers"

    private struct PreservedState {
        let unlockedDefault: Any?
        let devServersDefault: Any?
        let managerUnlocked: Bool
        let tapCount: Int
        let allowAllUsersForTesting: Bool
    }

    /// Install the clean singleton/default state each test requires while
    /// retaining the process state that must be restored before the suite's
    /// process-global lease is released.
    private func setUpCleanState() -> PreservedState {
        let manager = DebugModeManager.shared
        let state = PreservedState(
            unlockedDefault: UserDefaults.standard.object(forKey: unlockedKey),
            devServersDefault: UserDefaults.standard.object(forKey: devServersKey),
            managerUnlocked: manager.isUnlocked,
            tapCount: manager.tapCount,
            allowAllUsersForTesting: manager.allowAllUsersForTesting
        )

        manager.isUnlocked = false
        manager.resetTapCount()
        manager.allowAllUsersForTesting = true
        UserDefaults.standard.removeObject(forKey: unlockedKey)
        UserDefaults.standard.removeObject(forKey: devServersKey)
        DebugModeManager.invalidateLoggingCache()
        return state
    }

    private func restore(_ state: PreservedState) {
        let manager = DebugModeManager.shared

        // Reconstruct the private tap counter under the test bypass before
        // restoring the bypass itself. `tapCount` can only be 0...9 because
        // the tenth tap unlocks and resets it.
        manager.resetTapCount()
        manager.allowAllUsersForTesting = true
        manager.isUnlocked = false
        for _ in 0..<state.tapCount {
            _ = manager.registerTap()
        }
        manager.isUnlocked = state.managerUnlocked
        manager.allowAllUsersForTesting = state.allowAllUsersForTesting

        if let value = state.unlockedDefault {
            UserDefaults.standard.set(value, forKey: unlockedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: unlockedKey)
        }
        if let value = state.devServersDefault {
            UserDefaults.standard.set(value, forKey: devServersKey)
        } else {
            UserDefaults.standard.removeObject(forKey: devServersKey)
        }
        DebugModeManager.invalidateLoggingCache()
    }

    // MARK: - Tap counting

    @Test("Tapping fewer than 10 times does not unlock")
    func tapsBelow10DoNotUnlock() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<9 {
            let unlocked = mgr.registerTap()
            #expect(!unlocked)
        }
        #expect(!mgr.isUnlocked)
    }

    @Test("Exactly 10 taps unlocks and returns true")
    func tenTapsUnlocks() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<9 {
            _ = mgr.registerTap()
        }
        let unlocked = mgr.registerTap()
        #expect(unlocked)
        #expect(mgr.isUnlocked)
    }

    @Test("Tap counter resets after unlock")
    func tapCounterResetsOnUnlock() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<10 {
            _ = mgr.registerTap()
        }
        #expect(mgr.tapCount == 0)
    }

    @Test("registerTap returns false when already unlocked")
    func alreadyUnlockedReturnsFalse() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        mgr.isUnlocked = true
        for _ in 0..<15 {
            let result = mgr.registerTap()
            #expect(!result)
        }
    }

    @Test("resetTapCount clears counter")
    func resetClearsCounter() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<5 {
            _ = mgr.registerTap()
        }
        #expect(mgr.tapCount == 5)
        mgr.resetTapCount()
        #expect(mgr.tapCount == 0)
    }

    // MARK: - remainingTaps feedback

    @Test("remainingTaps is nil before 3 taps")
    func remainingTapsNilBeforeThreshold() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        #expect(mgr.remainingTaps == nil) // 0 taps
        _ = mgr.registerTap()
        #expect(mgr.remainingTaps == nil) // 1 tap
        _ = mgr.registerTap()
        #expect(mgr.remainingTaps == nil) // 2 taps
    }

    @Test("remainingTaps shows countdown from tap 3 onward")
    func remainingTapsShowsCountdown() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<3 { _ = mgr.registerTap() }
        #expect(mgr.remainingTaps == 7) // 10 - 3

        _ = mgr.registerTap()
        #expect(mgr.remainingTaps == 6) // 10 - 4

        for _ in 0..<5 { _ = mgr.registerTap() }
        #expect(mgr.remainingTaps == 1) // 10 - 9
    }

    @Test("remainingTaps is nil after unlock (counter reset)")
    func remainingTapsNilAfterUnlock() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        for _ in 0..<10 { _ = mgr.registerTap() }
        #expect(mgr.isUnlocked)
        #expect(mgr.remainingTaps == nil)
    }

    // MARK: - Persistence

    @Test("Unlock state persists to UserDefaults")
    func unlockPersistsToUserDefaults() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        mgr.isUnlocked = true
        #expect(UserDefaults.standard.bool(forKey: unlockedKey) == true)
        mgr.isUnlocked = false
        #expect(UserDefaults.standard.bool(forKey: unlockedKey) == false)
    }

    // MARK: - Locking resets dev servers

    @Test("Locking debug mode resets dev servers to false")
    func lockingResetsDevServers() {
        let state = setUpCleanState()
        defer { restore(state) }
        let mgr = DebugModeManager.shared
        mgr.isUnlocked = true
        BackendConfig.useDevServers = true
        #expect(BackendConfig.useDevServers == true)
        mgr.isUnlocked = false
        #expect(UserDefaults.standard.object(forKey: devServersKey) as? Bool == false)
    }

    // MARK: - BackendConfig gating

    @Test("BackendConfig.useDevServers returns false when debug mode locked")
    func devServersLockedReturnsFalse() {
        let state = setUpCleanState()
        defer { restore(state) }
        // Even if the raw UserDefaults value is true, locked mode forces false
        UserDefaults.standard.set(true, forKey: devServersKey)
        UserDefaults.standard.set(false, forKey: unlockedKey)
        #expect(BackendConfig.useDevServers == false)
    }

    @Test("BackendConfig.useDevServers respects stored value when debug mode unlocked")
    func devServersUnlockedRespectsValue() {
        let state = setUpCleanState()
        defer { restore(state) }
        UserDefaults.standard.set(true, forKey: unlockedKey)
        UserDefaults.standard.set(true, forKey: devServersKey)
        #expect(BackendConfig.useDevServers == true)

        UserDefaults.standard.set(false, forKey: devServersKey)
        #expect(BackendConfig.useDevServers == false)
    }

    @Test("BackendConfig URLs use production when debug mode locked")
    func urlsUseProductionWhenLocked() {
        let state = setUpCleanState()
        defer { restore(state) }
        UserDefaults.standard.set(false, forKey: unlockedKey)
        UserDefaults.standard.set(true, forKey: devServersKey) // would be dev, but locked
        #expect(BackendConfig.apiBaseURL.absoluteString == "https://api.tabmail.ai")
        #expect(BackendConfig.syncBaseURL == "https://sync.tabmail.ai")
        #expect(BackendConfig.syncWebSocketURL == "wss://sync.tabmail.ai/ws")
        #expect(BackendConfig.templatesBaseURL.absoluteString == "https://templates.tabmail.ai")
        #expect(BackendConfig.billingBaseURL.absoluteString == "https://billing.tabmail.ai")
    }
}

/// Tests for `isLoggingEnabled()` caching + invalidation (the `0xdead10cc`
/// fix: the keychain-derived gate is memoized so it no longer does a
/// synchronous Keychain XPC on every log call). `.serialized` prevents sibling
/// overlap; `.processGlobalState` excludes other suites while the memoized
/// flag, shared `tabmail_session`, and debug default are replaced.
@Suite("DebugModeManager.isLoggingEnabled", .serialized, .processGlobalState)
@MainActor
struct DebugModeLoggingGateTests {

    private let unlockedKey = "debug_mode_unlocked"
    private let sessionKey = "tabmail_session"

    /// Encode a session blob the way the auth flow stores it (Supabase shape),
    /// so `isLoggingEnabled()` can decode it back from the keychain.
    private func sessionData(email: String) throws -> Data {
        let json = "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at\":0,"
            + "\"user\":{\"id\":\"u\",\"email\":\"\(email)\"}}"
        let session = try JSONDecoder().decode(TabMailSession.self, from: Data(json.utf8))
        return try JSONEncoder().encode(session)
    }

    /// Run `body` with the real keychain session + unlock flag backed up and
    /// restored afterward, so a signed-in simulator is never disturbed.
    private func withPreservedState(_ body: () throws -> Void) rethrows {
        let savedSession = KeychainHelper.load(key: sessionKey)
        let savedUnlock = UserDefaults.standard.object(forKey: unlockedKey)
        defer {
            if let savedSession {
                try? KeychainHelper.save(savedSession, for: sessionKey)
            } else {
                KeychainHelper.delete(key: sessionKey)
            }
            if let savedUnlock {
                UserDefaults.standard.set(savedUnlock, forKey: unlockedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: unlockedKey)
            }
            DebugModeManager.invalidateLoggingCache()
        }
        try body()
    }

    @Test("Returns false when debug mode is locked, regardless of session")
    func lockedShortCircuitsToFalse() throws {
        try withPreservedState {
            UserDefaults.standard.set(false, forKey: unlockedKey)
            try KeychainHelper.save(sessionData(email: "qa@tabmail.ai"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == false)
        }
    }

    @Test("True for an unlocked + allowed-domain session")
    func unlockedAllowedUserIsTrue() throws {
        try withPreservedState {
            UserDefaults.standard.set(true, forKey: unlockedKey)
            try KeychainHelper.save(sessionData(email: "qa@tabmail.ai"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == true)
            // Stable across repeated (now-cached) reads.
            #expect(DebugModeManager.isLoggingEnabled() == true)
        }
    }

    @Test("False for an unlocked session whose email is not allowed")
    func unlockedDisallowedUserIsFalse() throws {
        try withPreservedState {
            UserDefaults.standard.set(true, forKey: unlockedKey)
            try KeychainHelper.save(sessionData(email: "qa@example.com"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == false)
        }
    }

    @Test("clearSession() invalidates the cache — no stale 'true' after logout")
    func logoutInvalidatesCache() throws {
        try withPreservedState {
            UserDefaults.standard.set(true, forKey: unlockedKey)
            try KeychainHelper.save(sessionData(email: "qa@tabmail.ai"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == true) // cache now holds `true`

            // Logout must drop the memoized `true`; otherwise the gate stays
            // on for the next (signed-out) user.
            TabMailAuthService.clearSession()
            #expect(DebugModeManager.isLoggingEnabled() == false)
        }
    }

    @Test("Cache picks up a new identity after re-evaluation")
    func cacheReflectsIdentityChange() throws {
        try withPreservedState {
            UserDefaults.standard.set(true, forKey: unlockedKey)

            try KeychainHelper.save(sessionData(email: "qa@example.com"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == false) // cache holds `false`

            // Simulate logging in as an allowed user (save + invalidate, as the
            // auth save sites now do).
            try KeychainHelper.save(sessionData(email: "qa@tabmail.ai"), for: sessionKey)
            DebugModeManager.invalidateLoggingCache()
            #expect(DebugModeManager.isLoggingEnabled() == true)
        }
    }
}
