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

    /// A tenth of a second of digital silence at 48 kHz, as a microphone delivers while it starts.
    static func silence() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
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
    /// The `language` sent with each upload (nil: none).
    let languages = Mutex<[String?]>([])
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
        language: @escaping @MainActor () -> String? = { nil },
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
            dictationLanguage: language,
            transcribe: { wav, language in
                recorded.uploads.withLock { $0.append(wav) }
                recorded.languages.withLock { $0.append(language) }
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

    /// The language is read once, when the dictation starts: the badge and the upload agree, and
    /// a Settings change mid-dictation applies from the next one.
    @Test func theLanguageAtTheStartIsShownAndSent() async {
        let capture = FakeCapture()
        let setting = Mutex<String?>("ko")
        let controller = controller(capture: capture, language: { setting.withLock { $0 } })

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        #expect(controller.language == "ko")
        await waitUntil { controller.isHearing }
        setting.withLock { $0 = "en" }
        controller.finish()
        await waitUntil { controller.phase == .idle }
        #expect(recorded.languages.withLock { $0 } == ["ko"])
        #expect(controller.language == "ko")

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        #expect(controller.language == "en")
        await waitUntil { capture.starts == 2 }
        controller.finish()
        await waitUntil { controller.phase == .idle }
        #expect(recorded.languages.withLock { $0 } == ["ko", "en"])
        #expect(recorded.texts.withLock { $0.count } == 2)
    }

    /// Without a language (no two-letter code), none is sent: the backend's default model.
    @Test func withoutALanguageNoneIsSent() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, language: { nil })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(controller.language == nil)
        #expect(recorded.languages.withLock { $0 } == [nil])
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

    /// Cancelled during the release tail (the mic still open for the last word) and a new
    /// dictation started: the first one's delayed completion never stops, uploads or ends the
    /// second, which records until it is finished and then delivers only its own text.
    @Test func aDictationCancelledInItsReleaseTailNeverTouchesTheNext() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        await dictate(controller, capture: capture)
        #expect(controller.phase == .transcribing)
        controller.cancel()
        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 2 && capture.isRunning }
        #expect(capture.starts == 2)

        // Well past the first dictation's release tail.
        try? await Task.sleep(for: DictationConfig.releaseTailDuration * 3)
        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        #expect(recorded.uploads.withLock { $0.isEmpty })

        controller.finish()
        await waitUntil { controller.phase == .idle }
        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
        #expect(!capture.isRunning)
    }

    /// A start while the last dictation is still transcribing (auto-start on re-expanding the pill
    /// during the upload) is ignored: the dictation in progress is never replaced or dropped.
    @Test func aStartWhileTranscribingNeverReplacesIt() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: {
            try? await Task.sleep(for: .milliseconds(300))
            return "ask jordan about the road map"
        })

        await dictate(controller, capture: capture)
        #expect(controller.phase == .transcribing)
        controller.start(context: context, canUseAI: true) { _ in Issue.record("the ignored start delivers nothing") }
        #expect(controller.phase == .transcribing)
        await waitUntil { controller.phase == .idle }

        #expect(capture.starts == 1)
        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
    }

    /// The warm-up swirl stays until real sound arrives: the microphone's start-up silence shows
    /// no waveform; a voice does.
    @Test func theWaveformWaitsForRealSound() async {
        let silent = FakeCapture(buffer: FakeCapture.silence())
        let quiet = controller(capture: silent)
        quiet.start(context: context, canUseAI: true) { _ in }
        await waitUntil { silent.starts == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(quiet.phase == .listening)
        #expect(!quiet.isHearing)
        #expect(quiet.level == 0)
        quiet.cancel()

        let speaking = FakeCapture()
        let heard = controller(capture: speaking)
        heard.start(context: context, canUseAI: true) { _ in }
        await waitUntil { heard.isHearing }
        #expect(heard.isHearing)
        heard.cancel()
    }

    /// A recording is never longer than the transcription model takes (120 s, backend ADR-022),
    /// and stays under the backend's 10 MiB upload limit.
    @Test func noRecordingOutlastsWhatTheModelTranscribes() {
        #expect(DictationConfig.maxRecordingDuration <= .seconds(120))
        #expect(DictationConfig.maxRecordingDuration > .zero)
        let bytes = Int(DictationConfig.maxRecordingDuration.components.seconds) * Int(DictationConfig.recordingSampleRate) * MemoryLayout<Int16>.size
        #expect(bytes < 10 * 1024 * 1024)
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

/// The production opt-out reader: Settings' "Opt Out of AI" (and declining AI consent) writes the
/// App Group flag, and a controller built without an injected reader must honour it.
@MainActor
@Suite(.serialized, .processGlobalState)
struct DictationOptOutFlagTests {
    @Test func theSettingsOptOutStopsDictationBeforeTheMicrophone() async {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(true)

        let capture = FakeCapture()
        let recorded = Recorded()
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            transcribe: { wav, _ in
                recorded.uploads.withLock { $0.append(wav) }
                return "ask jordan"
            },
            complete: { request in
                recorded.cleanups.withLock { $0.append(request) }
                return CompletionsResponse(assistant: "Ask Jordan.", token_usage: nil, error: nil)
            }
        )

        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { _ in
            Issue.record("no text when opted out")
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.phase == .idle)
        #expect(capture.starts == 0)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
    }
}

/// The chat pill's own wiring of the dictation gates, which the controller tests cannot reach:
/// the pill passes AI access, turns the mic off while offline or opted out, and never lets a
/// recording outlive it.
@Suite struct ChatPillDictationWiringTests {
    private static let pillPath = "TabMail/Views/Inbox/DynamicIslandChatButton.swift"

    private func pillSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(Self.pillPath), encoding: .utf8)
    }

    /// The source between `start` and the next occurrence of `end` after it.
    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    /// AI access is the gate that shows the input bar (a session, then a subscription), so an
    /// auto-start never records behind the sign-in or subscribe bar.
    @Test func dictationStartsWithTheInputBarsAIAccessGate() throws {
        let source = try pillSource()
        let body = try slice(source, from: "if !hasTabMailSession {", to: "expandedInputBar")
        #expect(body.contains("} else if !AISubscriptionGate.shared.isActive {"))

        let start = try slice(source, from: "private func startDictation()", to: "private var canSend: Bool")
        #expect(start.contains("guard canDictate else { return }"))
        #expect(start.contains("let canUseAI = hasTabMailSession && AISubscriptionGate.shared.isActive"))
        #expect(start.contains("dictation.start(context: dictationContext, canUseAI: canUseAI)"))
    }

    /// The mic is off offline and when opted out of AI, reading the same App Group flag Settings
    /// writes; a recording in progress can still be stopped.
    @Test func theMicIsOffOfflineAndWhenOptedOut() throws {
        let source = try pillSource()
        #expect(source.contains("@AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI"))
        let canDictate = try slice(source, from: "private var canDictate: Bool {", to: "}")
        #expect(canDictate.contains("networkMonitor.isConnected && !optOutAllAI"))
        #expect(source.contains(".disabled(isWorking || dictation.phase == .transcribing || (!dictation.isActive && !canDictate))"))
    }

    /// A recording never outlives the pill, and a message can't be sent over a dictation still
    /// on its way into the input.
    @Test func recordingNeverOutlivesThePill() throws {
        let source = try pillSource()
        let disappear = try slice(source, from: ".onDisappear {", to: "// No eager cancellation")
        #expect(disappear.contains("dictation.cancel()"))

        let canSend = try slice(source, from: "private var canSend: Bool {", to: "private func sendMessage()")
        #expect(canSend.contains("&& !dictation.isActive"))

        let collapse = try slice(source, from: "// Collapsing ends the recording", to: "isTextFieldFocused = false")
        #expect(collapse.contains("dictation.finish()"))
    }

    /// The "screen" the cleanup reads (ADR-IOS-085 decision 3): the draft's subject and body, or
    /// the email's sender, subject and snippet, with the chat and the input.
    @Test func theCleanupReadsWhatThePillIsAbout() throws {
        let source = try pillSource()
        let context = try slice(source, from: "private var dictationContext: DictationContext {", to: "private func startDictation()")
        #expect(context.contains(#"[draftSubject.map { "Subject: \($0)" }, draftBody]"#))
        #expect(context.contains(#"["From: \(message.from)", "Subject: \(message.subject)", message.snippet]"#))
        #expect(context.components(separatedBy: "messages: chatMessages, input: inputText").count == 4)
    }

    /// The Settings menu writes the key the controller reads, the listening pill shows the
    /// dictation's language, and the mic points to the menu once a dictation has landed.
    @Test func theLanguageMenuAndItsTipAreWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Settings/TabMailSettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("@AppStorage(DictationLanguage.settingKey) private var dictationLanguage = DictationLanguage.automatic"))
        #expect(settings.contains("Picker(selection: $dictationLanguage)"))
        #expect(settings.contains("ForEach(DictationLanguage.choices(), id: \\.self)"))

        let pill = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Inbox/DictationPillView.swift"), encoding: .utf8)
        #expect(pill.contains("Pill(mode: mode, level: controller.level, language: controller.language)"))
        let waveform = try slice(pill, from: "default:\n                    if let language {", to: "Waveform(level: level)")
        #expect(waveform.contains("LanguageBadge(code: language)"))

        let source = try pillSource()
        #expect(source.contains(".popoverTip(DictationLanguageTip(), arrowEdge: .bottom)"))
        let start = try slice(source, from: "private func startDictation()", to: "private var canSend: Bool")
        #expect(start.contains("DictationLanguageTip.dictationCompleted.donate()"))
    }
}

/// The Settings choice, as the controller reads it by default: `DictationLanguage.settingKey` in
/// the standard defaults, which Settings' Dictation Language menu writes.
@MainActor
@Suite(.serialized, .processGlobalState)
struct DictationLanguageSettingTests {
    private func withSetting(_ value: String?, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DictationLanguage.settingKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: DictationLanguage.settingKey)
            } else {
                defaults.removeObject(forKey: DictationLanguage.settingKey)
            }
        }
        if let value {
            defaults.set(value, forKey: DictationLanguage.settingKey)
        } else {
            defaults.removeObject(forKey: DictationLanguage.settingKey)
        }
        await body()
    }

    @Test func theChosenLanguageIsSentWithTheRecording() async {
        await withSetting("ko") {
            let capture = FakeCapture()
            let languages = Mutex<[String?]>([])
            let controller = DictationController(
                capture: capture,
                requestMicrophoneAccess: { true },
                isOnline: { true },
                isOptedOutOfAI: { false },
                transcribe: { _, language in
                    languages.withLock { $0.append(language) }
                    return "annyeong"
                },
                complete: { _ in CompletionsResponse(assistant: "Annyeong.", token_usage: nil, error: nil) }
            )

            controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { _ in }
            #expect(controller.language == "ko")
            let deadline = ContinuousClock.now + .seconds(5)
            while capture.starts == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            controller.finish()
            while controller.phase != .idle, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

            #expect(languages.withLock { $0 } == ["ko"])
        }
    }

    @Test func automaticIsTheIPhonesLanguage() async {
        await withSetting(nil) {
            #expect(DictationLanguage.current() == DictationLanguage.code(forPreferredLanguages: Locale.preferredLanguages))
        }
        await withSetting(DictationLanguage.automatic) {
            #expect(DictationLanguage.current() == DictationLanguage.code(forPreferredLanguages: Locale.preferredLanguages))
        }
        await withSetting("th") {
            #expect(DictationLanguage.current() == "th")
        }
    }
}

struct DictationLanguageTests {
    @Test(arguments: [
        (["ko-KR", "en-US"], "ko"),
        (["en-US"], "en"),
        (["zh-Hans-CN"], "zh"),
        (["pt_BR"], "pt"),
        (["EN"], "en"),
        (["yue-Hant-HK", "en-US"], nil),
        (["fil-PH"], nil),
        ([], nil),
    ] as [([String], String?)])
    func theFirstPreferredLanguageIsReducedToItsTwoLetterCode(languages: [String], expected: String?) {
        #expect(DictationLanguage.code(forPreferredLanguages: languages) == expected)
    }

    @Test func automaticFollowsThePreferredLanguagesAndAChoiceOverridesThem() {
        #expect(DictationLanguage.resolve(setting: DictationLanguage.automatic, preferredLanguages: ["ko-KR"]) == "ko")
        #expect(DictationLanguage.resolve(setting: DictationLanguage.automatic, preferredLanguages: ["yue-HK"]) == nil)
        #expect(DictationLanguage.resolve(setting: "ru", preferredLanguages: ["ko-KR"]) == "ru")
    }

    /// Settings offers exactly the backend's languages (backend ADR-024), each once, by name.
    @Test func settingsOffersTheBackendsLanguagesByName() {
        let locale = Locale(identifier: "en_US")
        let choices = DictationLanguage.choices(locale: locale)
        #expect(choices.count == 30)
        #expect(Set(choices) == Set(DictationConfig.dictationLanguages))
        #expect(Set(choices).count == choices.count)
        #expect(choices.allSatisfy { $0.count == 2 && $0 == $0.lowercased() })
        #expect(Set(["en", "ko", "ja", "ru", "th"]).isSubset(of: Set(choices)))
        let names = choices.map { DictationLanguage.name(of: $0, locale: locale) }
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(DictationLanguage.name(of: "ko", locale: locale) == "Korean")
    }
}
