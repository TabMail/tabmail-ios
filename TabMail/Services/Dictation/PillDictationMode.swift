/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How the chat pill's mic dictates (ADR-IOS-085 amendment 2026-10-29). Not opted out of AI: the
/// backend's transcription (`DictationController`), which needs a connection. Opted out: Apple's
/// speech recognition on this iPhone only (`OnDeviceSpeechRecognizer`), which needs no connection
/// and sends nothing to TabMail; without an on-device model for the language the mic is off.
enum PillDictationMode: Equatable {
    case backend
    case onDevice
    case off

    static func resolve(optedOutOfAI: Bool, isOnline: Bool, onDeviceAvailable: Bool, tutorialRunning: Bool) -> PillDictationMode {
        // Off in the guided tutorial: it would ask for the microphone.
        if tutorialRunning { return .off }
        if optedOutOfAI { return onDeviceAvailable ? .onDevice : .off }
        return isOnline ? .backend : .off
    }

    /// The pill's placeholder when the mic is off only because the language has no on-device model.
    static let onDeviceUnavailableNote = "Type... (on-device dictation isn't available for this language)"

    /// The locale the on-device recognizer uses: the Settings dictation language, or the iPhone's
    /// own locale on Automatic.
    static func speechLocale(dictationLanguage: String?, deviceLocale: Locale = .current) -> Locale {
        guard let code = dictationLanguage, code != deviceLocale.language.languageCode?.identifier else { return deviceLocale }
        return Locale(identifier: code)
    }
}
