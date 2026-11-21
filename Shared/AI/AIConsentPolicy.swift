/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The device's AI setting, shared by the app and the notification extension: the AI choice
/// (the AI screen) and Settings → Opt Out of AI. Both
/// live in the App Group suite so both processes read the same values. AI is on only when the
/// choice has been made and AI is not opted out; a missing value never turns AI on.
///
/// This is the only file that names the two keys and the only place that knows the rule. Every
/// other reader goes through `AIService.isAIOff` (app) or `NSEState.isAIDisabled` (extension),
/// both of which call `isDisabled(in:)`. A view that observes the two values itself (to repaint
/// when either changes) passes them to `isDisabled(choiceMade:optedOut:)`.
enum AIConsentPolicy {
    /// Set to true once the person has answered the AI choice, either way.
    static let completedChoiceKey = "hasSeenAIConsent"
    /// Settings → Opt Out of AI (true: no AI request is sent).
    static let optOutKey = "privacy_opt_out_all_ai"

    /// Whether AI is off: the choice is not made yet, or AI is opted out.
    static func isDisabled(in defaults: UserDefaults) -> Bool {
        isDisabled(choiceMade: defaults.bool(forKey: completedChoiceKey), optedOut: defaults.bool(forKey: optOutKey))
    }

    /// The rule itself, on values already read: AI is off unless the choice is made and AI is not
    /// opted out.
    static func isDisabled(choiceMade: Bool, optedOut: Bool) -> Bool {
        !choiceMade || optedOut
    }

    /// Records the AI choice. The opt-out is written before the choice, so a "no" is never
    /// read as "choice made, AI on" in between.
    static func recordChoice(aiEnabled: Bool, in defaults: UserDefaults) {
        defaults.set(!aiEnabled, forKey: optOutKey)
        defaults.set(true, forKey: completedChoiceKey)
    }

    /// Removes the answer: the choice first, so AI reads as off from the first removal on, then
    /// the opt-out. Used at a sign-in on a device with no mail account.
    static func clearChoice(in defaults: UserDefaults) {
        defaults.removeObject(forKey: completedChoiceKey)
        defaults.removeObject(forKey: optOutKey)
    }

    /// Moves both values from where earlier versions kept them (`legacy`, the app's
    /// `UserDefaults.standard`) into the shared suite. The app runs it as the first step of every
    /// launch. A value already in the shared suite is never overwritten. The opt-out goes first,
    /// so an earlier "no" is in place before the choice reads as made. Only a completed choice is
    /// copied: without one, AI stays off until the person answers. Both earlier values are then
    /// removed, so the move happens once and a later clear of the shared suite stays cleared.
    /// Returns the keys it copied.
    @discardableResult
    static func migrateLegacyValues(from legacy: UserDefaults, to shared: UserDefaults) -> [String] {
        let legacyOptOut = legacy.object(forKey: optOutKey) as? Bool
        let legacyChoice = legacy.bool(forKey: completedChoiceKey)
        var copied: [String] = []
        if shared.object(forKey: optOutKey) == nil, let legacyOptOut {
            shared.set(legacyOptOut, forKey: optOutKey)
            copied.append(optOutKey)
        }
        if shared.object(forKey: completedChoiceKey) == nil, legacyChoice {
            shared.set(true, forKey: completedChoiceKey)
            copied.append(completedChoiceKey)
        }
        // Removed only after the copy: stopped in between, the next launch copies again into
        // the still-empty keys or skips the ones already filled.
        legacy.removeObject(forKey: completedChoiceKey)
        legacy.removeObject(forKey: optOutKey)
        return copied
    }
}
