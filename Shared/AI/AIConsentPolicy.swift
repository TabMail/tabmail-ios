/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The device's AI setting, shared by the app and the notification extension: the AI choice
/// (the AI screen shown after the first account is added) and Settings → Opt Out of AI. Both
/// live in the App Group suite so both processes read the same values. AI is on only when the
/// choice has been made and AI is not opted out; a missing value never turns AI on.
///
/// This is the only file that names the two keys. Every other reader goes through
/// `AIService.isAIOff` (app) or `NSEState.isAIDisabled` (extension), both of which call
/// `isDisabled(in:)`.
enum AIConsentPolicy {
    /// Set to true once the person has answered the AI choice, either way.
    static let completedChoiceKey = "hasSeenAIConsent"
    /// Settings → Opt Out of AI (true: no AI request is sent).
    static let optOutKey = "privacy_opt_out_all_ai"

    /// Whether AI is off: the choice is not made yet, or AI is opted out.
    static func isDisabled(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: completedChoiceKey) || defaults.bool(forKey: optOutKey)
    }

    /// Records the AI choice. The opt-out is written before the choice, so a "no" is never
    /// read as "choice made, AI on" in between.
    static func recordChoice(aiEnabled: Bool, in defaults: UserDefaults) {
        defaults.set(!aiEnabled, forKey: optOutKey)
        defaults.set(true, forKey: completedChoiceKey)
    }

    /// Copies both values from where earlier versions kept them (`legacy`, the app's
    /// `UserDefaults.standard`) into the shared suite. The app runs it as the first step of every
    /// launch. A value already in the shared suite is never overwritten. The opt-out goes first,
    /// so an earlier "no" is in place before the choice reads as made. Only a completed choice is
    /// copied: without one, AI stays off until the person answers. Returns the keys it copied.
    @discardableResult
    static func migrateLegacyValues(from legacy: UserDefaults, to shared: UserDefaults) -> [String] {
        var copied: [String] = []
        if shared.object(forKey: optOutKey) == nil, let optedOut = legacy.object(forKey: optOutKey) as? Bool {
            shared.set(optedOut, forKey: optOutKey)
            copied.append(optOutKey)
        }
        if shared.object(forKey: completedChoiceKey) == nil, legacy.bool(forKey: completedChoiceKey) {
            shared.set(true, forKey: completedChoiceKey)
            copied.append(completedChoiceKey)
        }
        return copied
    }
}
