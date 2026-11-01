/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
@testable import TabMail

/// The on-device recognizer's lifecycle: an older start, stop or result never touches a newer
/// recording, and every stop releases the microphone (ADR-IOS-085 amendment 2026-10-29).
@MainActor
struct OnDeviceSpeechRecognizerTests {
    /// A microphone whose `start` completes when the test says, like the real queue's. Each start
    /// installs a tap through the real `CaptureRoutes`, and a tap stays installed until the test
    /// lets it go, as the real queue's teardown lags the stop.
    private final class DeferredCapture: AudioCapturing, @unchecked Sendable {
        private struct State {
            var completions: [@Sendable ((any Error)?) -> Void] = []
            var taps: [CaptureRoute] = []
            var isRunning = false
            var stops = 0
        }

        private let routes = CaptureRoutes()
        private let state = Mutex(State())
        var isRunning: Bool { state.withLock { $0.isRunning } }
        var stops: Int { state.withLock { $0.stops } }
        var starts: Int { state.withLock { $0.completions.count } }

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, completion: @escaping @Sendable ((any Error)?) -> Void) {
            let tap = routes.open(onBuffer)
            state.withLock {
                $0.completions.append(completion)
                $0.taps.append(tap)
            }
        }

        func stop() {
            routes.closeCurrent()
            state.withLock { $0.isRunning = false; $0.stops += 1 }
        }

        /// The `index`th start's tap hears `tag`, even when that start has been stopped.
        func hear(_ tag: Int, throughTapOf index: Int) {
            let tap = state.withLock { $0.taps[index] }
            tap.deliver(CaptureRoutesTests.buffer(tag))
        }

        /// Completes the `index`th start; a successful start leaves the microphone running.
        func complete(_ index: Int, error: (any Error)? = nil) {
            let completion = state.withLock { state -> (@Sendable ((any Error)?) -> Void) in
                if error == nil { state.isRunning = true }
                return state.completions[index]
            }
            completion(error)
        }
    }

    private final class FakeRecognition: SpeechRecognition, @unchecked Sendable {
        private let finished = Mutex(false)
        private let heard = Mutex<[Int]>([])
        let handler: @Sendable (String?, Bool) -> Void
        init(handler: @escaping @Sendable (String?, Bool) -> Void) { self.handler = handler }
        var isFinished: Bool { finished.withLock { $0 } }
        /// The tags of the buffers this recognition was given.
        var heardTags: [Int] { heard.withLock { $0 } }
        func append(_ buffer: AVAudioPCMBuffer) { heard.withLock { $0.append(Int(buffer.frameLength)) } }
        func finish() { finished.withLock { $0 = true } }
    }

    private struct Failure: Error {}

    private final class Texts: @unchecked Sendable {
        private let storage = Mutex<[String]>([])
        var all: [String] { storage.withLock { $0 } }
        func add(_ text: String) { storage.withLock { $0.append(text) } }
    }

    /// A permission answer that arrives when the test says.
    private final class PermissionGate: @unchecked Sendable {
        private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
        private let isOpen = Mutex(false)

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if isOpen.withLock({ $0 }) {
                    c.resume()
                } else {
                    waiting.withLock { $0.append(c) }
                }
            }
        }

        func open() {
            isOpen.withLock { $0 = true }
            let all = waiting.withLock { w -> [CheckedContinuation<Void, Never>] in
                defer { w = [] }
                return w
            }
            all.forEach { $0.resume() }
        }
    }

    private final class Harness: @unchecked Sendable {
        let capture = DeferredCapture()
        let gate = PermissionGate()
        /// What the recognizer's permission read sees; a request that is granted flips it, as the system does.
        private let granted: Mutex<Bool>
        private let requests = Mutex(0)
        var permissionRequests: Int { requests.withLock { $0 } }
        func setGranted(_ value: Bool) { granted.withLock { $0 = value } }
        private let created = Mutex<[FakeRecognition]>([])
        var recognizer: OnDeviceSpeechRecognizer!

        var recognitionCount: Int { created.withLock { $0.count } }
        func recognition(_ index: Int) -> FakeRecognition { created.withLock { $0[index] } }

        init(
            permissionsGranted: Bool = true, languageAvailable: Bool = true, permissionsWaitForTheGate: Bool = false,
            alreadyGranted: Bool = true
        ) {
            let gate = gate
            granted = Mutex(alreadyGranted)
            recognizer = MainActor.assumeIsolated {
                OnDeviceSpeechRecognizer(
                    capture: capture,
                    startRecognition: { [unowned self] _, handler in
                        guard languageAvailable else { return nil }
                        let recognition = FakeRecognition(handler: handler)
                        self.created.withLock { $0.append(recognition) }
                        return recognition
                    },
                    requestPermissions: { [unowned self] in
                        self.requests.withLock { $0 += 1 }
                        if permissionsWaitForTheGate { await gate.wait() }
                        if permissionsGranted { self.setGranted(true) }
                        return permissionsGranted
                    },
                    permissionsGranted: { [unowned self] in self.granted.withLock { $0 } })
            }
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func start(_ h: Harness, into texts: Texts, auto: Bool = false) async {
        h.recognizer.start(locale: Locale(identifier: "en_US"), auto: auto) { text in texts.add(text) }
        await settle()
    }

    /// The pill opened with Auto-Enable Dictation on and both permissions already granted: it starts as
    /// a mic tap does.
    @Test func anAutoStartRunsLikeATapWhenBothPermissionsAreGranted() async {
        let h = Harness(alreadyGranted: true)
        let texts = Texts()
        await start(h, into: texts, auto: true)
        #expect(h.recognizer.isStarting)
        #expect(h.recognitionCount == 1)
        #expect(h.capture.starts == 1)
        guard h.recognitionCount == 1, h.capture.starts == 1 else { return }
        h.capture.complete(0)
        await settle()
        #expect(h.recognizer.isRecording)
        h.recognition(0).handler("hello", false)
        await settle()
        #expect(texts.all == ["hello"])
    }

    /// Speech recognition or the microphone still undetermined: an auto-start would raise a prompt
    /// unasked, so it does nothing: no recognition, no capture, no permission request.
    @Test func anAutoStartDoesNothingWhenAPermissionStillNeedsAPrompt() async {
        let h = Harness(alreadyGranted: false)
        let texts = Texts()
        await start(h, into: texts, auto: true)
        #expect(!h.recognizer.isStarting)
        #expect(!h.recognizer.isRecording)
        #expect(h.recognitionCount == 0)
        #expect(h.capture.starts == 0)
    }

    /// The tap is where the prompt is asked: the same undetermined state starts from a tap.
    @Test func aTapStillStartsWhenAPermissionIsUndetermined() async {
        let h = Harness(alreadyGranted: false)
        let texts = Texts()
        await start(h, into: texts)
        #expect(h.recognizer.isStarting)
        #expect(h.capture.starts == 1)
        guard h.capture.starts == 1 else { return }
        h.capture.complete(0)
        await settle()
        #expect(h.recognizer.isRecording)
    }

    /// An auto-start that is refused asks for nothing: no permission request, so no prompt.
    @Test func aRefusedAutoStartMakesNoPermissionRequest() async {
        let h = Harness(alreadyGranted: false)
        await start(h, into: Texts(), auto: true)
        #expect(h.permissionRequests == 0)
    }

    /// The permissions are read at every start, not once: a first tap grants them, the user stops, and the
    /// next auto-start runs without a request of its own.
    @Test func anAutoStartReadsThePermissionsFreshAfterATapGrantedThem() async {
        let h = Harness(permissionsGranted: true, alreadyGranted: false)
        let texts = Texts()
        await start(h, into: texts, auto: true)
        #expect(h.capture.starts == 0)
        await start(h, into: texts)
        #expect(h.permissionRequests == 1)
        #expect(h.capture.starts == 1)
        guard h.capture.starts == 1, h.recognitionCount == 1 else { return }
        h.capture.complete(0)
        await settle()
        #expect(h.recognizer.isRecording)
        h.recognizer.stop()
        await start(h, into: texts, auto: true)
        #expect(h.capture.starts == 2)
        guard h.capture.starts == 2, h.recognitionCount == 2 else { return }
        h.capture.complete(1)
        await settle()
        #expect(h.recognizer.isRecording)
        h.recognition(1).handler("again", false)
        await settle()
        #expect(texts.all == ["again"])
    }

    /// A recognizer built with its production permission reader (only the request, recognition and capture
    /// are faked): where the system statuses are not both granted, an auto-start asks for nothing and
    /// starts nothing, and a tap still dictates. (A host with both granted has no prompt to guard.)
    @Test func theProductionReaderKeepsAnAutoStartFromPromptingWhereAPermissionIsUndecided() async {
        guard !OnDeviceSpeechRecognizer.systemPermissionsGranted() else { return }
        let capture = DeferredCapture()
        let requests = Mutex(0)
        let created = Mutex(0)
        let recognizer = OnDeviceSpeechRecognizer(
            capture: capture,
            startRecognition: { _, handler in
                created.withLock { $0 += 1 }
                return FakeRecognition(handler: handler)
            },
            requestPermissions: {
                requests.withLock { $0 += 1 }
                return true
            })
        let texts = Texts()
        recognizer.start(locale: Locale(identifier: "en_US"), auto: true) { texts.add($0) }
        await settle()
        #expect(requests.withLock { $0 } == 0)
        #expect(created.withLock { $0 } == 0)
        #expect(capture.starts == 0)
        #expect(!recognizer.isStarting)

        recognizer.start(locale: Locale(identifier: "en_US")) { texts.add($0) }
        await settle()
        #expect(requests.withLock { $0 } == 1)
        #expect(capture.starts == 1)
    }

    /// The recognizer's own reader is the system statuses through the same table (a host where both are
    /// granted and one where neither is decided read the same way).
    @Test func theDefaultReaderIsTheSystemStatusesThroughTheTable() {
        #expect(OnDeviceSpeechRecognizer.systemPermissionsGranted() == OnDeviceSpeechRecognizer.permissionsAlreadyGranted(
            speech: SFSpeechRecognizer.authorizationStatus(), microphone: AVAudioApplication.shared.recordPermission))
    }

    /// Which system states need no prompt: only both authorized. Not determined needs one; denied or
    /// restricted already turns the mic off (`OnDeviceReadiness`).
    @Test func onlyBothPermissionsAuthorizedNeedNoPrompt() {
        typealias Speech = SFSpeechRecognizerAuthorizationStatus
        let speechStates: [Speech] = [.authorized, .notDetermined, .denied, .restricted]
        let micStates: [AVAudioApplication.recordPermission] = [.granted, .undetermined, .denied]
        for speech in speechStates {
            for mic in micStates {
                let expected = speech == .authorized && mic == .granted
                #expect(OnDeviceSpeechRecognizer.permissionsAlreadyGranted(speech: speech, microphone: mic) == expected)
            }
        }
    }

    @Test func aStartRecordsOnceTheMicrophoneIsRunning() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        #expect(h.recognizer.isStarting)
        #expect(!h.recognizer.isRecording)
        h.capture.complete(0)
        await settle()
        #expect(h.recognizer.isRecording)
        #expect(!h.recognizer.isStarting)
        h.recognition(0).handler("hello", false)
        await settle()
        #expect(texts.all == ["hello"])
    }

    /// Recording A is stopped and B started; A's late result neither reaches B's input nor ends B.
    @Test func aStaleResultNeverTouchesTheNewerRecording() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.capture.complete(0)
        await settle()
        h.recognizer.stop()
        await start(h, into: texts)
        h.capture.complete(1)
        await settle()
        guard h.capture.starts == 2, h.recognitionCount == 2 else { return }
        #expect(h.recognizer.isRecording)

        h.recognition(0).handler("old words", true)
        await settle()

        #expect(texts.all.isEmpty)
        #expect(h.recognizer.isRecording)
        #expect(!h.recognition(1).isFinished)
        #expect(h.capture.isRunning)
    }

    /// A start that finishes after a stop and a newer start must not mark the newer one recording.
    @Test func aStaleStartCompletionDoesNotMarkTheNewerStartRecording() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.recognizer.stop()
        await start(h, into: texts)
        guard h.capture.starts == 2 else { return }

        h.capture.complete(0)
        await settle()

        #expect(!h.recognizer.isRecording)
        #expect(h.recognizer.isStarting)
        h.capture.complete(1)
        await settle()
        #expect(h.recognizer.isRecording)
    }

    /// Every way out leaves the microphone released: repeated stops, and a start that failed.
    @Test func everyExitReleasesTheMicrophone() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.capture.complete(0)
        await settle()
        h.recognizer.stop()
        h.recognizer.stop()
        #expect(!h.capture.isRunning)
        #expect(h.recognition(0).isFinished)

        await start(h, into: texts)
        h.capture.complete(1, error: Failure())
        await settle()
        #expect(!h.recognizer.isRecording)
        #expect(!h.recognizer.isStarting)
        #expect(!h.capture.isRunning)
        #expect(h.recognition(1).isFinished)
    }

    @Test func aFinalResultEndsTheRecordingAndReleasesTheMicrophone() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.capture.complete(0)
        await settle()
        h.recognition(0).handler("done", true)
        await settle()
        #expect(texts.all == ["done"])
        #expect(!h.recognizer.isRecording)
        #expect(!h.capture.isRunning)
    }

    /// Recording A is stopped and B started while A's tap is still installed: A's audio never
    /// reaches B's recognition, B's own audio does (the tap hears through the capture's routes).
    @Test func aStoppedRecordingsAudioNeverReachesTheNextRecognition() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.capture.complete(0)
        await settle()
        h.capture.hear(1, throughTapOf: 0)
        h.recognizer.stop()
        await start(h, into: texts)
        guard h.capture.starts == 2, h.recognitionCount == 2 else { return }

        h.capture.hear(11, throughTapOf: 0)
        h.capture.complete(1)
        h.capture.hear(22, throughTapOf: 1)

        #expect(h.recognition(0).heardTags == [1])
        #expect(h.recognition(1).heardTags == [22])
    }

    /// A stop alone: the start that completes afterwards does not mark anything recording.
    @Test func aStartCompletingAfterAStopOnlyDoesNotRecord() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.recognizer.stop()
        h.capture.complete(0)
        await settle()
        #expect(!h.recognizer.isRecording)
        #expect(!h.recognizer.isStarting)
    }

    /// An older start's failure cannot stop the newer recording.
    @Test func aStaleCaptureErrorDoesNotEndTheNewerRecording() async {
        let h = Harness()
        let texts = Texts()
        await start(h, into: texts)
        h.recognizer.stop()
        await start(h, into: texts)
        guard h.capture.starts == 2 else { return }
        h.capture.complete(1)
        await settle()
        h.capture.complete(0, error: Failure())
        await settle()
        #expect(h.recognizer.isRecording)
        #expect(h.capture.isRunning)
        #expect(!h.recognition(1).isFinished)
    }

    /// A permission answer that arrives after a stop starts nothing.
    @Test func aPermissionAnsweredAfterAStopStartsNothing() async {
        let h = Harness(permissionsWaitForTheGate: true)
        let texts = Texts()
        await start(h, into: texts)
        #expect(h.recognizer.isStarting)
        h.recognizer.stop()
        h.gate.open()
        await settle()
        #expect(h.capture.starts == 0)
        #expect(h.recognitionCount == 0)
        #expect(!h.recognizer.isStarting)
        #expect(!h.recognizer.isRecording)
    }

    /// A language with no on-device model leaves the microphone off and the start finished.
    @Test func aLanguageWithoutAnOnDeviceModelStartsNothing() async {
        let h = Harness(languageAvailable: false)
        let texts = Texts()
        await start(h, into: texts)
        #expect(!h.recognizer.isStarting)
        #expect(!h.recognizer.isRecording)
        #expect(h.capture.starts == 0)
    }

    @Test func deniedPermissionsStartNothing() async {
        let h = Harness(permissionsGranted: false)
        let texts = Texts()
        await start(h, into: texts)
        #expect(!h.recognizer.isStarting)
        #expect(h.capture.starts == 0)
    }
}
