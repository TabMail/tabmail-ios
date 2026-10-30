/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The on-device recognizer's lifecycle: an older start, stop or result never touches a newer
/// recording, and every stop releases the microphone (ADR-IOS-085 amendment 2026-10-29).
@MainActor
struct OnDeviceSpeechRecognizerTests {
    /// A microphone whose `start` completes when the test says, like the real queue's.
    private final class DeferredCapture: AudioCapturing, @unchecked Sendable {
        private struct State {
            var completions: [@Sendable ((any Error)?) -> Void] = []
            var isRunning = false
            var stops = 0
        }

        private let state = Mutex(State())
        var isRunning: Bool { state.withLock { $0.isRunning } }
        var stops: Int { state.withLock { $0.stops } }
        var starts: Int { state.withLock { $0.completions.count } }

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, completion: @escaping @Sendable ((any Error)?) -> Void) {
            state.withLock { $0.completions.append(completion) }
        }

        func stop() { state.withLock { $0.isRunning = false; $0.stops += 1 } }

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
        let handler: @Sendable (String?, Bool) -> Void
        init(handler: @escaping @Sendable (String?, Bool) -> Void) { self.handler = handler }
        var isFinished: Bool { finished.withLock { $0 } }
        func append(_ buffer: AVAudioPCMBuffer) {}
        func finish() { finished.withLock { $0 = true } }
    }

    private struct Failure: Error {}

    private final class Texts: @unchecked Sendable {
        private let storage = Mutex<[String]>([])
        var all: [String] { storage.withLock { $0 } }
        func add(_ text: String) { storage.withLock { $0.append(text) } }
    }

    private final class Harness: @unchecked Sendable {
        let capture = DeferredCapture()
        private let created = Mutex<[FakeRecognition]>([])
        var recognizer: OnDeviceSpeechRecognizer!

        var recognitionCount: Int { created.withLock { $0.count } }
        func recognition(_ index: Int) -> FakeRecognition { created.withLock { $0[index] } }

        init(permissionsGranted: Bool = true) {
            recognizer = MainActor.assumeIsolated {
                OnDeviceSpeechRecognizer(
                    capture: capture,
                    startRecognition: { [unowned self] _, handler in
                        let recognition = FakeRecognition(handler: handler)
                        self.created.withLock { $0.append(recognition) }
                        return recognition
                    },
                    requestPermissions: { permissionsGranted })
            }
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func start(_ h: Harness, into texts: Texts) async {
        h.recognizer.start(locale: Locale(identifier: "en_US")) { text in texts.add(text) }
        await settle()
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

    @Test func deniedPermissionsStartNothing() async {
        let h = Harness(permissionsGranted: false)
        let texts = Texts()
        await start(h, into: texts)
        #expect(!h.recognizer.isStarting)
        #expect(h.capture.starts == 0)
    }
}
