/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Settings' "Smart Dictation": whether a dictation is cleaned up by AI (the backend's cleanup in
/// the transcription request, and a long dictation's polish), at the cost of about a second.
/// Off, the default, appends the transcript as heard (owner, 2026-10-05). As TabMail Voice's
/// `smartDictation` setting.
enum SmartDictation {
    /// UserDefaults key of the Settings toggle.
    static let settingKey = "smartDictation"
    static let defaultValue = false

    /// The Settings choice now.
    static func isOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? defaultValue
    }
}
