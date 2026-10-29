/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Speech
import Testing
@testable import TabMail

struct PillDictationModeTests {
    private func mode(optedOut: Bool, online: Bool = true, onDevice: Bool = true, tutorial: Bool = false) -> PillDictationMode {
        PillDictationMode.resolve(optedOutOfAI: optedOut, isOnline: online, onDeviceAvailable: onDevice, tutorialRunning: tutorial)
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
