/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Speech
import Testing
@testable import TabMail

struct PillDictationModeTests {
    private func mode(optedOut: Bool, online: Bool = true, onDevice: Bool = true, tutorial: Bool = false) -> PillDictationMode {
        PillDictationMode.resolve(optedOutOfAI: optedOut, isOnline: online, onDevice: onDevice ? .ready : .noModel, tutorialRunning: tutorial)
    }

    /// Not opted out: the backend path, unchanged (needs a connection, ignores the on-device model).
    @Test func notOptedOutUsesTheBackendWhileOnline() {
        #expect(mode(optedOut: false) == .backend)
        #expect(mode(optedOut: false, onDevice: false) == .backend)
        #expect(mode(optedOut: false, online: false) == .off)
    }

    /// Opted out: on this iPhone, offline or not; never the backend; off when the language has no model.
    @Test func optedOutDictatesOnDeviceWithoutAConnection() {
        #expect(mode(optedOut: true) == .onDevice)
        #expect(mode(optedOut: true, online: false) == .onDevice)
        #expect(mode(optedOut: true, onDevice: false) == .off)
        #expect(mode(optedOut: true, online: false, onDevice: false) == .off)
    }

    @Test func theTutorialKeepsTheMicOffEitherWay() {
        #expect(mode(optedOut: false, tutorial: true) == .off)
        #expect(mode(optedOut: true, tutorial: true) == .off)
    }

    /// The Settings dictation language picks the locale; Automatic keeps the iPhone's own.
    @Test func speechLocaleFollowsTheDictationLanguage() {
        let device = Locale(identifier: "en_US")
        #expect(PillDictationMode.speechLocale(dictationLanguage: nil, deviceLocale: device) == device)
        #expect(PillDictationMode.speechLocale(dictationLanguage: "en", deviceLocale: device) == device)
        #expect(PillDictationMode.speechLocale(dictationLanguage: "de", deviceLocale: device) == Locale(identifier: "de"))
    }

    /// A denied or restricted permission turns the mic off with a note; one not yet asked does not
    /// (it is asked at the first tap), and with no model the note is the model's.
    @Test func aBlockedPermissionTurnsTheOptedOutMicOffWithANote() {
        func readiness(_ model: Bool, _ speech: SFSpeechRecognizerAuthorizationStatus, _ mic: AVAudioApplication.recordPermission) -> OnDeviceReadiness {
            OnDeviceReadiness.resolve(modelAvailable: model, speech: speech, microphone: mic)
        }
        #expect(readiness(true, .authorized, .granted) == .ready)
        #expect(readiness(true, .notDetermined, .undetermined) == .ready)
        #expect(readiness(true, .notDetermined, .granted) == .ready)
        #expect(readiness(true, .denied, .granted) == .speechBlocked)
        #expect(readiness(true, .restricted, .undetermined) == .speechBlocked)
        #expect(readiness(true, .authorized, .denied) == .microphoneBlocked)
        #expect(readiness(true, .denied, .denied) == .speechBlocked)
        #expect(readiness(false, .denied, .denied) == .noModel)
        #expect(OnDeviceReadiness.ready.note == nil)
        #expect(OnDeviceReadiness.speechBlocked.note?.contains("Speech Recognition access in Settings") == true)
        #expect(OnDeviceReadiness.microphoneBlocked.note?.contains("Microphone access in Settings") == true)
        #expect(OnDeviceReadiness.noModel.note?.contains("isn't available for this language") == true)
        for blocked in [OnDeviceReadiness.noModel, .speechBlocked, .microphoneBlocked] {
            #expect(PillDictationMode.resolve(optedOutOfAI: true, isOnline: true, onDevice: blocked, tutorialRunning: false) == .off)
        }
        // Not opted out is never affected by the on-device state.
        #expect(PillDictationMode.resolve(optedOutOfAI: false, isOnline: true, onDevice: .speechBlocked, tutorialRunning: false) == .backend)
    }

    /// The audio never leaves the phone: the request demands on-device recognition.
    @Test func theRecognitionRequestRequiresOnDeviceRecognition() {
        let request = OnDeviceSpeechRecognizer.makeRequest()
        #expect(request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
    }

    /// Nothing is sent to TabMail's backend on the opted-out path, and the permission is asked only
    /// from a tap: the recognizer file has no network or backend use, and nothing asks at launch.
    @Test func theOnDeviceRecognizerHasNoBackendUseAndNothingElseAsksForSpeechPermission() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recognizer = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/OnDeviceSpeechRecognizer.swift"), encoding: .utf8)
        #expect(recognizer.contains("requiresOnDeviceRecognition = true"))
        for forbidden in ["URLSession", "BackendClient", "transcribeDictation"] {
            #expect(!recognizer.contains(forbidden), "\(forbidden) must not appear on the on-device path")
        }
        let sources = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("TabMail").path)
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("OnDeviceSpeechRecognizer.swift") }
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent("TabMail/\(path)"), encoding: .utf8)
            #expect(!text.contains("SFSpeechRecognizer.requestAuthorization"), "\(path) asks for speech permission")
        }
        let plist = try String(contentsOf: root.appendingPathComponent("TabMail/Resources/Info.plist"), encoding: .utf8)
        #expect(plist.contains("NSSpeechRecognitionUsageDescription"))
    }

    /// The opted-out DictationController still sends nothing to the backend.
    @Test func thePillRoutesOptedOutDictationOnDeviceAndTheControllerStaysClosed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Inbox/DynamicIslandChatButton.swift"), encoding: .utf8)
        #expect(view.contains("if dictationMode == .onDevice {"))
        // The speech permission is asked by the recognizer's start: only a mic tap may reach it.
        #expect(view.contains("guard !auto, !speech.isRecording, !speech.isStarting else { return }"))
        #expect(view.components(separatedBy: "startDictation(auto: true)").count == 4)
        // Every exit releases the recognizer; a recording keeps the screen awake and blocks send.
        #expect(view.components(separatedBy: "speech.stop()").count == 5)
        #expect(view.contains("dictation.isActive || speech.isRecording)"))
        #expect(view.contains("&& !speech.isRecording\n            && composeReadyToSend"))
        #expect(view.contains("PillDictationMode.resolve("))
        let controller = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/DictationController.swift"), encoding: .utf8)
        #expect(controller.contains("guard canUseAI, !isOptedOutOfAI() else {"))
    }
}
