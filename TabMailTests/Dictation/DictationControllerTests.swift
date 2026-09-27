/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// A microphone that delivers one prepared buffer (or none) when started. Tracks whether it is
/// running, so tests can pin that every dictation releases it.
private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    private struct State {
        var starts = 0
        var isRunning = false
    }

    private let state = Mutex(State())
    let buffer: AVAudioPCMBuffer?
    let startError: (any Error)?

    init(buffer: AVAudioPCMBuffer? = FakeCapture.speech(), startError: (any Error)? = nil) {
        self.buffer = buffer
        self.startError = startError
    }

    var starts: Int { state.withLock { $0.starts } }
    var isRunning: Bool { state.withLock { $0.isRunning } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, completion: @escaping @Sendable ((any Error)?) -> Void) {
        state.withLock { $0.starts += 1 }
        if let startError {
            completion(startError)
            return
        }
        state.withLock { $0.isRunning = true }
        if let buffer { onBuffer(buffer) }
        completion(nil)
    }

    func stop() {
        state.withLock { $0.isRunning = false }
    }

    /// Audio at a sample rate no converter accepts: the recording fails.
    static func unconvertible() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 1, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        return buffer
    }

    /// A tenth of a second of a 440 Hz tone at 48 kHz, as a microphone delivers it.
    static func speech() -> AVAudioPCMBuffer {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate / 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            data[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        return buffer
    }
}

/// What the dictations in one test uploaded, sent for cleanup, and appended.
private final class Recorded: Sendable {
    let uploads = Mutex<[Data]>([])
    let cleanups = Mutex<[CompletionsRequest]>([])
    let texts = Mutex<[String]>([])
}

/// A microphone whose first start is slow and completes only when `failFirst` is called (a
/// device that takes long to fail); later starts run as `FakeCapture`'s do.
private final class LateFailCapture: AudioCapturing, @unchecked Sendable {
    private struct State {
        var starts = 0
        var isRunning = false
        var firstCompletion: (@Sendable ((any Error)?) -> Void)?
    }

    private let state = Mutex(State())

    var starts: Int { state.withLock { $0.starts } }
    var isRunning: Bool { state.withLock { $0.isRunning } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let isFirst = state.withLock { state in
            state.starts += 1
            if state.starts == 1 { state.firstCompletion = completion }
            return state.starts == 1
        }
        guard !isFirst else { return }
        state.withLock { $0.isRunning = true }
        onBuffer(FakeCapture.speech())
        completion(nil)
    }

    func stop() {
        state.withLock { $0.isRunning = false }
    }

    func failFirst(_ error: any Error) {
        let completion = state.withLock { state in
            defer { state.firstCompletion = nil }
            return state.firstCompletion
        }
        completion?(error)
    }
}

@MainActor
struct DictationControllerTests {
    private let context = DictationContext(windowTitle: "Chat", screenText: "Me: hi\n» ‸")
    private let recorded = Recorded()

    private func controller(
        capture: any AudioCapturing = FakeCapture(),
        online: Bool = true,
        optedOut: @escaping @MainActor () -> Bool = { false },
        microphoneAccess: @escaping @MainActor () async -> Bool = { true },
        transcript: @escaping @Sendable () async throws -> String = { "ask jordan about the road map" },
        cleaned: @escaping @Sendable () async throws -> CompletionsResponse = {
            CompletionsResponse(assistant: "Ask Jordan about the roadmap.", token_usage: nil, error: nil)
        },
        maxRecordingDuration: Duration = DictationConfig.maxRecordingDuration
    ) -> DictationController {
        let recorded = recorded
        return DictationController(
            capture: capture,
            requestMicrophoneAccess: microphoneAccess,
            isOnline: { online },
            isOptedOutOfAI: optedOut,
            transcribe: { wav in
                recorded.uploads.withLock { $0.append(wav) }
                return try await transcript()
            },
            complete: { request in
                recorded.cleanups.withLock { $0.append(request) }
                return try await cleaned()
            },
            maxRecordingDuration: maxRecordingDuration
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Starts, waits for the microphone, and taps stop.
    private func dictate(_ controller: DictationController, capture: FakeCapture) async {
        let recorded = recorded
        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }
        controller.finish()
    }

    @Test func appendsTheCleanedUpDictation() async throws {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        #expect(controller.phase == .listening)
        await waitUntil { controller.isHearing }
        controller.finish()
        #expect(controller.phase == .transcribing)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
        #expect(!capture.isRunning)
        // The upload is a WAV of what was recorded.
        let wav = try #require(recorded.uploads.withLock { $0.first })
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(wav.count > WAVEncoder.headerSize)
        // The cleanup got the transcript and what was on screen when the dictation started.
        let message = try #require(recorded.cleanups.withLock { $0.first?.messages.first })
        let vars = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: String]
        #expect(vars?["dictation"] == "ask jordan about the road map")
        #expect(vars?["screen_text"] == "Me: hi\n» ‸")
    }

    /// Dictation is transcribed on the backend: offline, nothing is recorded.
    @Test func offlineItDoesNotStart() {
        let capture = FakeCapture()
        let controller = controller(capture: capture, online: false)

        controller.start(context: context, canUseAI: true) { _ in Issue.record("no text offline") }

        #expect(controller.phase == .failed(DictationController.offlineMessage))
        #expect(capture.starts == 0)
    }

    /// Without AI access the pill shows sign-in or subscribe, not the waveform: an auto-start must
    /// not record unseen, and nothing is uploaded.
    @Test func withoutAIAccessNothingIsRecorded() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: false) { _ in Issue.record("no text without AI access") }
        #expect(controller.phase == .idle)
        #expect(!controller.isActive)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(capture.starts == 0)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        // The same controller records once AI access is there.
        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        #expect(capture.starts == 1)
        controller.cancel()
    }

    /// Opted out of AI (Settings, or AI consent declined): nothing is recorded, and neither the
    /// audio nor the screen text is sent.
    @Test func optedOutOfAINothingIsRecordedOrSent() async {
        let capture = FakeCapture()
        let optedOut = Mutex(true)
        let controller = controller(capture: capture, optedOut: { optedOut.withLock { $0 } })

        controller.start(context: context, canUseAI: true) { _ in Issue.record("no text when opted out") }
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(capture.starts == 0)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
        // The same controller records once the opt-out is cleared.
        optedOut.withLock { $0 = false }
        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        #expect(capture.starts == 1)
        controller.cancel()
    }

    @Test func withoutMicrophoneAccessNothingIsRecorded() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, microphoneAccess: { false })

        controller.start(context: context, canUseAI: true) { _ in Issue.record("no text without the microphone") }
        await waitUntil { controller.phase != .listening }

        #expect(controller.phase == .failed(DictationController.microphoneDeniedMessage))
        #expect(capture.starts == 0)
    }

    /// Tapping stop while the access prompt is still up records nothing and uploads nothing.
    @Test func stoppingBeforeMicrophoneAccessDiscards() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, microphoneAccess: {
            try? await Task.sleep(for: .milliseconds(200))
            return true
        })

        controller.start(context: context, canUseAI: true) { _ in Issue.record("nothing was recorded") }
        controller.finish()
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(capture.starts == 0)
        #expect(controller.phase == .idle)
    }

    @Test func aMicrophoneThatFailsToStartIsReleased() async {
        let capture = FakeCapture(startError: MicrophoneCapture.CaptureError.noInputDevice)
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: true) { _ in Issue.record("no text without audio") }
        await waitUntil { controller.phase != .listening }

        #expect(controller.phase == .failed(DictationController.microphoneFailedMessage))
        #expect(!capture.isRunning)
    }

    @Test func noAudioIsNotUploaded() async {
        let capture = FakeCapture(buffer: nil)
        let controller = controller(capture: capture)

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .failed(DictationController.nothingHeardMessage))
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!capture.isRunning)
    }

    @Test func anEmptyTranscriptIsNotAppended() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { " \n" })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .failed(DictationController.nothingHeardMessage))
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
    }

    @Test(arguments: [
        (DictationError.subscriptionRequired as any Error, "Dictation needs an active TabMail subscription."),
        (DictationError(status: 400, code: "audio_too_large") as any Error, "That recording was too long to transcribe."),
        (DictationError(status: 500, code: nil) as any Error, DictationController.failedMessage),
        (URLError(.notConnectedToInternet) as any Error, DictationController.offlineMessage),
        (URLError(.networkConnectionLost) as any Error, DictationController.offlineMessage),
        (URLError(.dataNotAllowed) as any Error, DictationController.offlineMessage),
        (URLError(.timedOut) as any Error, DictationController.failedMessage),
    ])
    func aFailedTranscriptionSaysWhy(error: any Error, message: String) async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { throw error })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .failed(message))
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!capture.isRunning)
    }

    /// A failed cleanup never costs the dictation: the transcript is appended as heard.
    @Test func aFailedCleanupAppendsTheTranscriptAsHeard() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, cleaned: { throw BackendError.requestFailed(statusCode: 0) })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["ask jordan about the road map"])
    }

    /// Cancelled while transcribing (the pill went away): the late transcript goes nowhere.
    @Test func aCancelledDictationAppendsNothing() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: {
            try? await Task.sleep(for: .milliseconds(300))
            return "too late"
        })

        await dictate(controller, capture: capture)
        await waitUntil { recorded.uploads.withLock { !$0.isEmpty } }
        controller.cancel()
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(600))

        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
        #expect(controller.phase == .idle)
        #expect(!capture.isRunning)
    }

    @Test func anotherDictationCanStartAfterAFailure() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { " " })
        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }
        #expect(controller.phase == .failed(DictationController.nothingHeardMessage))

        controller.start(context: context, canUseAI: true) { _ in }

        #expect(controller.phase == .listening)
        controller.cancel()
    }

    /// Cancelled while listening (the pill went away): the microphone and its audio session are
    /// released and nothing is sent.
    @Test func cancellingWhileListeningReleasesTheMicrophone() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: true) { _ in Issue.record("nothing is appended after a cancel") }
        await waitUntil { capture.isRunning }
        #expect(capture.isRunning)
        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(!capture.isRunning)
        try? await Task.sleep(for: DictationConfig.releaseTailDuration * 2)
        #expect(recorded.uploads.withLock { $0.isEmpty })
    }

    /// An auto-start racing a tap: the second start is ignored, so only one microphone runs.
    @Test func aSecondStartWhileListeningIsIgnored() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        controller.start(context: context, canUseAI: true) { _ in Issue.record("the second start never records") }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(capture.starts == 1)
        #expect(controller.phase == .listening)
        controller.cancel()
    }

    /// A dictation cancelled during its cleanup never lands in the one started after it: an older
    /// dictation must not append to, or end, a newer one.
    @Test func aSupersededCleanupNeverLandsInTheNextDictation() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, cleaned: {
            try? await Task.sleep(for: .milliseconds(300))
            return CompletionsResponse(assistant: "Too late.", token_usage: nil, error: nil)
        })

        await dictate(controller, capture: capture)
        await waitUntil { recorded.cleanups.withLock { !$0.isEmpty } }
        controller.cancel()
        controller.start(context: context, canUseAI: true) { _ in Issue.record("the second dictation was not finished") }
        await waitUntil { capture.starts == 2 }
        try? await Task.sleep(for: .milliseconds(600))

        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        controller.cancel()
    }

    /// At the upload cap the recording is sent rather than dropped. (Whole seconds: the recorder,
    /// copied from TabMail Voice, sizes its cap from the duration's seconds component.)
    @Test func theMaximumDurationSendsTheRecording() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, maxRecordingDuration: .seconds(1))

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { controller.phase == .transcribing }
        #expect(controller.phase == .transcribing)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(!capture.isRunning)
    }

    @Test func audioThatCannotBeRecordedFailsAndReleasesTheMicrophone() async {
        let capture = FakeCapture(buffer: FakeCapture.unconvertible())
        let controller = controller(capture: capture)

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .failed(DictationController.recordingFailedMessage))
        #expect(!capture.isRunning)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.texts.withLock { $0.isEmpty })
    }

    /// A transcription cancelled by the user throws (URLSession does on cancel); its late error
    /// must not end or fail the dictation started after it.
    @Test func aCancelledTranscriptionsErrorNeverEndsTheNextDictation() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: {
            try await Task.sleep(for: .milliseconds(500))
            return "too late"
        })

        await dictate(controller, capture: capture)
        await waitUntil { recorded.uploads.withLock { !$0.isEmpty } }
        controller.cancel()
        controller.start(context: context, canUseAI: true) { _ in Issue.record("the second dictation was not finished") }
        await waitUntil { capture.starts == 2 }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        controller.cancel()
    }

    /// A superseded start's late microphone failure must not end the dictation started after it.
    @Test func aStaleMicrophoneFailureNeverEndsTheNextDictation() async {
        let capture = LateFailCapture()
        let controller = controller(capture: capture)

        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        controller.cancel()
        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 2 }
        capture.failFirst(MicrophoneCapture.CaptureError.noInputDevice)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        controller.cancel()
    }

    /// The microphone is off while the recording uploads, not held open for the whole request.
    @Test func theMicrophoneIsReleasedBeforeTheUpload() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: {
            try? await Task.sleep(for: .milliseconds(300))
            return "hello"
        })

        await dictate(controller, capture: capture)
        await waitUntil { recorded.uploads.withLock { !$0.isEmpty } }

        #expect(!capture.isRunning)
        await waitUntil { controller.phase == .idle }
    }

    /// A failure message clears after `errorDisplayDuration`, giving the text field back.
    @Test func aFailureMessageClearsAndGivesTheFieldBack() async {
        let controller = controller(online: false)

        controller.start(context: context, canUseAI: true) { _ in }
        #expect(controller.phase == .failed(DictationController.offlineMessage))
        await waitUntil { controller.phase == .idle }

        #expect(controller.phase == .idle)
    }

    @Test func appendsToTheEndOfTheInputASpaceApart() {
        #expect(DictationController.appending("Hello there.", to: "") == "Hello there.")
        #expect(DictationController.appending("Hello there.", to: " \n") == "Hello there.")
        #expect(DictationController.appending("see you then", to: "Thanks, ") == "Thanks, see you then")
        #expect(DictationController.appending("second line", to: "first line\n") == "first line second line")
    }
}
