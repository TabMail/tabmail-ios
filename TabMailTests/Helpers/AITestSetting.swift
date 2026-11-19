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
