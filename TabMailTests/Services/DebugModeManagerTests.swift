/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DebugModeManager")
@MainActor
struct DebugModeManagerTests {

    private let unlockedKey = "debug_mode_unlocked"
    private let devServersKey = "debug_use_dev_servers"

    /// Reset UserDefaults state before each test.
    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: unlockedKey)
        UserDefaults.standard.removeObject(forKey: devServersKey)
        // Re-sync singleton from UserDefaults
        DebugModeManager.shared.isUnlocked = false
        DebugModeManager.shared.resetTapCount()
        DebugModeManager.shared.allowAllUsersForTesting = true
    }

    // MARK: - Tap counting

    @Test("Tapping fewer than 10 times does not unlock")
    func tapsBelow10DoNotUnlock() {
        cleanUp()
        let mgr = DebugModeManager.shared
        for _ in 0..<9 {
            let unlocked = mgr.registerTap()
            #expect(!unlocked)
        }
        #expect(!mgr.isUnlocked)
    }

    @Test("Exactly 10 taps unlocks and returns true")
    func tenTapsUnlocks() {
        cleanUp()
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
        cleanUp()
        let mgr = DebugModeManager.shared
        for _ in 0..<10 {
            _ = mgr.registerTap()
        }
        #expect(mgr.tapCount == 0)
    }

    @Test("registerTap returns false when already unlocked")
    func alreadyUnlockedReturnsFalse() {
        cleanUp()
        let mgr = DebugModeManager.shared
        mgr.isUnlocked = true
        for _ in 0..<15 {
            let result = mgr.registerTap()
            #expect(!result)
        }
    }

    @Test("resetTapCount clears counter")
    func resetClearsCounter() {
        cleanUp()
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
        cleanUp()
        let mgr = DebugModeManager.shared
        #expect(mgr.remainingTaps == nil) // 0 taps
        _ = mgr.registerTap()
        #expect(mgr.remainingTaps == nil) // 1 tap
        _ = mgr.registerTap()
        #expect(mgr.remainingTaps == nil) // 2 taps
    }

    @Test("remainingTaps shows countdown from tap 3 onward")
    func remainingTapsShowsCountdown() {
        cleanUp()
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
        cleanUp()
        let mgr = DebugModeManager.shared
        for _ in 0..<10 { _ = mgr.registerTap() }
        #expect(mgr.isUnlocked)
        #expect(mgr.remainingTaps == nil)
    }

    // MARK: - Persistence

    @Test("Unlock state persists to UserDefaults")
    func unlockPersistsToUserDefaults() {
        cleanUp()
        let mgr = DebugModeManager.shared
        mgr.isUnlocked = true
        #expect(UserDefaults.standard.bool(forKey: unlockedKey) == true)
        mgr.isUnlocked = false
        #expect(UserDefaults.standard.bool(forKey: unlockedKey) == false)
    }

    // MARK: - Locking resets dev servers

    @Test("Locking debug mode resets dev servers to false")
    func lockingResetsDevServers() {
        cleanUp()
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
        cleanUp()
        // Even if the raw UserDefaults value is true, locked mode forces false
        UserDefaults.standard.set(true, forKey: devServersKey)
        UserDefaults.standard.set(false, forKey: unlockedKey)
        #expect(BackendConfig.useDevServers == false)
    }

    @Test("BackendConfig.useDevServers respects stored value when debug mode unlocked")
    func devServersUnlockedRespectsValue() {
        cleanUp()
        UserDefaults.standard.set(true, forKey: unlockedKey)
        UserDefaults.standard.set(true, forKey: devServersKey)
        #expect(BackendConfig.useDevServers == true)

        UserDefaults.standard.set(false, forKey: devServersKey)
        #expect(BackendConfig.useDevServers == false)
    }

    @Test("BackendConfig URLs use production when debug mode locked")
    func urlsUseProductionWhenLocked() {
        cleanUp()
        UserDefaults.standard.set(false, forKey: unlockedKey)
        UserDefaults.standard.set(true, forKey: devServersKey) // would be dev, but locked
        #expect(BackendConfig.apiBaseURL.absoluteString == "https://api.tabmail.ai")
        #expect(BackendConfig.syncBaseURL == "https://sync.tabmail.ai")
        #expect(BackendConfig.syncWebSocketURL == "wss://sync.tabmail.ai/ws")
        #expect(BackendConfig.templatesBaseURL.absoluteString == "https://templates.tabmail.ai")
        #expect(BackendConfig.billingBaseURL.absoluteString == "https://billing.tabmail.ai")
    }
}
