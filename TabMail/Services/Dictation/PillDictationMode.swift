/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Speech

/// How the chat pill's mic dictates (ADR-IOS-085 amendment 2026-10-29). Not opted out of AI: the
/// backend's transcription (`DictationController`), which needs a connection. Opted out: Apple's
/// speech recognition on this iPhone only (`OnDeviceSpeechRecognizer`), which needs no connection
/// and sends nothing to TabMail; without an on-device model for the language the mic is off.
enum PillDictationMode: Equatable {
    case backend
    case onDevice
    case off

    static func resolve(optedOutOfAI: Bool, isOnline: Bool, onDevice: OnDeviceReadiness, tutorialRunning: Bool) -> PillDictationMode {
        // Off in the guided tutorial: it would ask for the microphone.
        if tutorialRunning { return .off }
        if optedOutOfAI { return onDevice == .ready ? .onDevice : .off }
        return isOnline ? .backend : .off
    }

    /// The locale the on-device recognizer uses: the Settings dictation language, or the iPhone's
    /// own locale on Automatic.
    static func speechLocale(dictationLanguage: String?, deviceLocale: Locale = .current) -> Locale {
        guard let code = dictationLanguage, code != deviceLocale.language.languageCode?.identifier else { return deviceLocale }
        return Locale(identifier: code)
    }
}

/// Whether an opted-out user's mic can dictate on this iPhone, and if not, why: the pill's placeholder
/// says so. A permission not yet asked is `ready` (it is asked at the first tap); only a denied or
/// restricted one blocks.
enum OnDeviceReadiness: Equatable {
    case ready
    case noModel
    case speechBlocked
    case microphoneBlocked

    static func resolve(
        modelAvailable: Bool, speech: SFSpeechRecognizerAuthorizationStatus, microphone: AVAudioApplication.recordPermission
    ) -> OnDeviceReadiness {
        if !modelAvailable { return .noModel }
        if speech == .denied || speech == .restricted { return .speechBlocked }
        if microphone == .denied { return .microphoneBlocked }
        return .ready
    }

    /// The placeholder while the mic is off for this reason.
    var note: String? {
        switch self {
        case .ready: return nil
        case .noModel: return "Type... (on-device dictation isn't available for this language)"
        case .speechBlocked: return "Type... (dictation needs Speech Recognition access in Settings)"
        case .microphoneBlocked: return "Type... (dictation needs Microphone access in Settings)"
        }
    }
}
