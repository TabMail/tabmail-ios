/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Settings' "Smart Dictation": whether a dictation is cleaned up by AI (the backend's cleanup in
/// the transcription request, and a long dictation's polish), at the cost of about a second.
/// On by default, since AI cleanup fixes most typos (owner, 2026-10-29; it was off by default
/// from 2026-10-05); a user who turned it off keeps it off, because only a stored choice
/// overrides the default. Off appends the transcript as heard. As TabMail Voice's
/// `smartDictation` setting.
enum SmartDictation {
    /// UserDefaults key of the Settings toggle.
    static let settingKey = "smartDictation"
    static let defaultValue = true

    /// The Settings choice now.
    static func isOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? defaultValue
    }
}
