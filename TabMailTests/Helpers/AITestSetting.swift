/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// Sets the real AI setting (the App Group values `AIService.isAIOff` reads) for a test: the AI
/// choice made, and Opt Out of AI as given. Suites that send through the real setting use this
/// rather than writing the keys themselves.
enum AITestSetting {
    private static let keys = [AIService.aiChoiceMadeKey, AIService.optOutAllAIKey]

    /// The choice made, AI opted out (`aiOff`) or not.
    static func set(aiOff: Bool) {
        AIConsentPolicy.recordChoice(aiEnabled: !aiOff, in: AIService.optOutStore)
    }

    /// Removes both values: the state before the AI choice is made, as after an install.
    static func clear() {
        for key in keys { AIService.optOutStore.removeObject(forKey: key) }
    }

    /// Saves both values; the returned closure puts them back (removing a value that was absent).
    static func save() -> () -> Void {
        let store = AIService.optOutStore
        let saved = keys.map { ($0, store.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
            }
        }
    }

    /// Runs `body` with the setting as given, then restores both values.
    static func with<T>(aiOff: Bool, _ body: () async throws -> T) async rethrows -> T {
        let restore = save()
        defer { restore() }
        set(aiOff: aiOff)
        return try await body()
    }
}

/// The subscription gate as a test found it: `AISubscriptionGate.shared`'s open state and checked
/// bit, and both values it stores. Create it before the test touches the gate and call `restore()`
/// in a `defer`, so every way out puts all four back (a value that was absent is removed again).
/// `openGate`/`closeGate` alone cannot do this: both set the checked bit and store it.
@MainActor
struct AIGateTestState {
    private static let keys = ["ai_subscription_last_known_active", "ai_subscription_has_checked_once"]

    private let isActive = AISubscriptionGate.shared.isActive
    private let hasCheckedOnce = AISubscriptionGate.shared.hasCheckedOnce
    private let stored: [(key: String, value: Any?)] = AIGateTestState.keys.map {
        (key: $0, value: UserDefaults.standard.object(forKey: $0))
    }

    func restore() {
        AISubscriptionGate.shared.restoreForTesting(isActive: isActive, hasCheckedOnce: hasCheckedOnce)
        for entry in stored {
            if let value = entry.value {
                UserDefaults.standard.set(value, forKey: entry.key)
            } else {
                UserDefaults.standard.removeObject(forKey: entry.key)
            }
        }
    }
}
