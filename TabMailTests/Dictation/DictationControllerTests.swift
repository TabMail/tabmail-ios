/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import GRDB
import Synchronization
import SwiftUI
import Testing
@testable import TabMail

/// A microphone that delivers prepared buffers (or none), in order, when started. Tracks whether
/// it is running, so tests can pin that every dictation releases it.
private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    private struct State {
        var starts = 0
        var isRunning = false
    }

    private let state = Mutex(State())
    let buffers: [AVAudioPCMBuffer]
    let startError: (any Error)?

    convenience init(buffer: AVAudioPCMBuffer? = FakeCapture.speech(), startError: (any Error)? = nil) {
        self.init(buffers: buffer.map { [$0] } ?? [], startError: startError)
    }

    init(buffers: [AVAudioPCMBuffer], startError: (any Error)? = nil) {
        self.buffers = buffers
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
        for buffer in buffers { onBuffer(buffer) }
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

    /// `seconds` of a 440 Hz tone at 16 kHz, in one buffer. Quiet (`amplitude` 0.01, about
    /// −43 dB), it plays a room's noise.
    static func tone(seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            data[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
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

/// The controller under test, for a transcription stub that reads or cancels it.
@MainActor
private final class ControllerRef {
    weak var controller: DictationController?
}

/// What the dictations in one test uploaded, sent with it for the cleanup, and appended.
private final class Recorded: Sendable {
    let uploads = Mutex<[Data]>([])
    /// The `language` sent with each upload (nil: none).
    let languages = Mutex<[String?]>([])
    /// The words sent to spell as given with each upload (ADR-IOS-086).
    let vocabularies = Mutex<[[String]]>([])
    /// The cleanup's variables sent with each upload (backend ADR-027).
    let cleanups = Mutex<[[String: String]]>([])
    let texts = Mutex<[String]>([])
    /// The texts each dictation marked the dictionary's words used in (`DictationDictionary.use`).
    let used = Mutex<[[String]]>([])
    /// Warm-ups sent (`DictationController.WarmUp`).
    let warmUps = Mutex(0)
}

/// Hears speech in the buffers `hears` accepts, calling back at once as the classifier would.
/// `finish` reports whether it heard any, or, `hearsWhenFlushed`, a word the classifier only
/// catches in its last window.
private final class FakeSpeechDetector: SpeechDetecting, @unchecked Sendable {
    private let heard = Mutex(false)
    private let hears: @Sendable (AVAudioPCMBuffer) -> Bool
    private let hearsWhenFlushed: Bool
    private let onSpeech: @Sendable () -> Void

    private init(hears: @escaping @Sendable (AVAudioPCMBuffer) -> Bool, hearsWhenFlushed: Bool, onSpeech: @escaping @Sendable () -> Void) {
        self.hears = hears
        self.hearsWhenFlushed = hearsWhenFlushed
        self.onSpeech = onSpeech
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard hears(buffer) else { return }
        let isFirst = heard.withLock { heard in
            defer { heard = true }
            return !heard
        }
        if isFirst { onSpeech() }
    }

    func finish() async -> Bool {
        if hearsWhenFlushed { heard.withLock { $0 = true } }
        return heard.withLock { $0 }
    }

    static func make(
        hearsWhenFlushed: Bool = false,
        hears: @escaping @Sendable (AVAudioPCMBuffer) -> Bool
    ) -> DictationController.MakeSpeechDetector {
        { onSpeech, _ in FakeSpeechDetector(hears: hears, hearsWhenFlushed: hearsWhenFlushed, onSpeech: onSpeech) }
    }

    /// Hears any buffer louder than a room (the tests' `speech()` and full tones).
    static func hearing() -> DictationController.MakeSpeechDetector {
        make { MicrophoneCapture.decibels(of: $0) > roomDecibels }
    }

    /// Never hears speech: someone who says nothing.
    static func deaf() -> DictationController.MakeSpeechDetector {
        make { _ in false }
    }

    /// Louder than `FakeCapture.tone(amplitude: 0.01)`, quieter than any voice the tests play.
    static let roomDecibels: Float = -30
}

/// A speech detector that can't run: it fails on the first buffer.
private final class BrokenSpeechDetector: SpeechDetecting, @unchecked Sendable {
    private let onFailure: @Sendable (any Error) -> Void

    init(onFailure: @escaping @Sendable (any Error) -> Void) {
        self.onFailure = onFailure
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        onFailure(URLError(.cannotDecodeRawData))
    }

    func finish() async -> Bool { false }
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

/// The chat pill's input field, as the tests edit it.
@MainActor
private final class InputField {
    var text = ""
}

/// The words a correction watch learned, one list per learning.
@MainActor
private final class LearnedWords {
    var words: [[String]] = []
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
        /// The backend's `cleaned_text`: `""` when its cleanup failed, nil from a backend without it.
        cleaned: @escaping @Sendable () async -> String? = { "Ask Jordan about the roadmap." },
        maxRecordingDuration: Duration = DictationConfig.maxRecordingDuration,
        speechDetector: @escaping DictationController.MakeSpeechDetector = FakeSpeechDetector.hearing(),
        dictionary: @escaping @MainActor () -> DictationDictionary.Snapshot = { .init(words: [], learnsWords: false) },
        emailBody: @escaping DictationController.EmailBody = { _ in nil },
        corrections: DictationCorrectionWatch? = nil,
        warmUp: DictationController.WarmUp? = nil,
        retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1)]
    ) -> DictationController {
        let recorded = recorded
        return DictationController(
            capture: capture,
            requestMicrophoneAccess: microphoneAccess,
            isOnline: { online },
            isOptedOutOfAI: optedOut,
            dictationLanguage: language,
            dictionary: dictionary,
            emailBody: emailBody,
            corrections: corrections,
            useWords: { texts in recorded.used.withLock { $0.append(texts) } },
            transcribe: { flac, language, vocabulary, cleanup in
                recorded.uploads.withLock { $0.append(flac) }
                recorded.languages.withLock { $0.append(language) }
                recorded.vocabularies.withLock { $0.append(vocabulary) }
                recorded.cleanups.withLock { $0.append(cleanup) }
                return DictationTranscription(text: try await transcript(), cleanedText: await cleaned())
            },
            warmUp: warmUp ?? { recorded.warmUps.withLock { $0 += 1 } },
            transcriptionRetryDelays: retryDelays,
            speechDetector: speechDetector,
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
        await waitUntil { controller.hasHeardSpeech }
        controller.finish()
        #expect(controller.phase == .transcribing)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
        #expect(!capture.isRunning)
        // The upload is a FLAC of what was recorded, peak-normalised: its loudest sample at −3 dBFS.
        let flac = try #require(recorded.uploads.withLock { $0.first })
        let decoded = try FLACTestDecoder.decode(flac)
        #expect(decoded.sampleRate == Int(DictationConfig.recordingSampleRate))
        #expect(decoded.totalSamples > 0)
        var uploaded = [Int16](repeating: 0, count: decoded.pcm.count / 2)
        _ = uploaded.withUnsafeMutableBytes { decoded.pcm.copyBytes(to: $0) }
        #expect(uploaded.reduce(0) { max($0, abs(Int($1))) } == Int((Double(Int16.max) * pow(10, DictationConfig.normalizedPeakDecibels / 20)).rounded()))
        // One request: the recording went with what was on screen when the dictation started, for
        // the cleanup the backend runs on its transcript.
        #expect(recorded.cleanups.withLock { $0 } == [[
            "app_name": "TabMail",
            "web_host": "",
            "terminal_program": "",
            "window_title": "Chat",
            "screen_text": "Me: hi\n» ‸",
            "dictionary": "",
        ]])
    }

    /// Dictation is transcribed on the backend: offline, nothing is recorded.
    @Test func offlineItDoesNotStart() {
        let capture = FakeCapture()
        let controller = controller(capture: capture, online: false)

        controller.start(context: context, canUseAI: true) { _ in Issue.record("no text offline") }

        #expect(controller.phase == .idle)
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

    /// The language is read once, when the dictation starts: a Settings change mid-dictation
    /// applies from the next one.
    @Test func theLanguageAtTheStartIsShownAndSent() async {
        let capture = FakeCapture()
        let setting = Mutex<String?>("ko")
        let controller = controller(capture: capture, language: { setting.withLock { $0 } })

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        #expect(controller.language == "ko")
        await waitUntil { controller.hasHeardSpeech }
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

        #expect(controller.phase == .idle)
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

        #expect(controller.phase == .idle)
        #expect(!capture.isRunning)
    }

    @Test func noAudioIsNotUploaded() async {
        let capture = FakeCapture(buffer: nil)
        let controller = controller(capture: capture)

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .idle)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!capture.isRunning)
    }

    /// The text arrives with the dictation already over, so the pill's send-after-dictation can
    /// send it from the callback (sending is refused while a dictation is active).
    @Test func theTextArrivesOnceTheDictationHasEnded() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture)
        var activeAtDelivery: [Bool] = []

        controller.start(context: context, canUseAI: true) { _ in
            activeAtDelivery.append(controller.isActive)
        }
        await waitUntil { capture.starts == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(activeAtDelivery == [false])
    }

    @Test func anEmptyTranscriptIsNotAppended() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { " \n" })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .idle)
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(recorded.used.withLock { $0.isEmpty })
    }

    /// A failed transcription shows nothing: the input field comes back as it was. Refused by the
    /// backend (signed out, no subscription, over quota, a bad request) or timed out, here or at the
    /// backend (its 504: it already waited for the speech model), it is not tried again.
    @Test(arguments: [
        DictationError.unauthorized as any Error,
        DictationError.subscriptionRequired as any Error,
        DictationError(status: 429, code: "rate_limited") as any Error,
        DictationError(status: 400, code: "audio_too_large") as any Error,
        DictationError(status: 400, code: "invalid_request") as any Error,
        DictationError.invalidResponse as any Error,
        URLError(.timedOut) as any Error,
        DictationError(status: 504, code: "transcription_timeout") as any Error,
    ])
    func aFailedTranscriptionEndsQuietly(error: any Error) async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { throw error })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }

        #expect(controller.phase == .idle)
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(!controller.isRetrying)
        #expect(!capture.isRunning)
    }

    // MARK: Server errors are tried again (TabMail Voice ADR-DESK-039)

    /// A transcription the server failed (a 5xx) or whose connection dropped is sent again, the
    /// same recording, the field saying so meanwhile; the retry's text is appended.
    @Test(arguments: [
        DictationError(status: 500, code: nil) as any Error,
        DictationError(status: 502, code: "transcription_failed") as any Error,
        DictationError(status: 503, code: "transcription_unavailable") as any Error,
        URLError(.networkConnectionLost) as any Error,
        URLError(.notConnectedToInternet) as any Error,
    ])
    func aServerErrorIsTriedAgain(error: any Error) async throws {
        let capture = FakeCapture()
        let attempts = Mutex(0)
        let retryingSeen = Mutex<[Bool]>([])
        let ref = ControllerRef()
        let controller = controller(capture: capture, transcript: {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            let retrying = await MainActor.run { ref.controller?.isRetrying ?? false }
            retryingSeen.withLock { $0.append(retrying) }
            if attempt == 1 { throw error }
            return "ask jordan about the road map"
        })
        ref.controller = controller
        let recorded = recorded
        let retryingAtInsert = Mutex<[Bool]>([])

        controller.start(context: context, canUseAI: true) { text in
            retryingAtInsert.withLock { $0.append(controller.isRetrying) }
            recorded.texts.withLock { $0.append(text) }
        }
        await waitUntil { capture.starts == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
        // Nothing is being tried again while the text goes in.
        #expect(retryingAtInsert.withLock { $0 } == [false])
        let uploads = recorded.uploads.withLock { $0 }
        #expect(uploads.count == 2)
        guard uploads.count == 2 else { return }
        #expect(uploads[1] == uploads[0])
        // The retry was sent while the field said so; once it answered, the note went away.
        #expect(retryingSeen.withLock { $0 } == [false, true])
        #expect(!controller.isRetrying)
    }

    @Test func aTranscriptionFailingEveryRetryEndsQuietly() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { throw DictationError(status: 502, code: "transcription_failed") })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(controller.phase == .idle)
        #expect(recorded.uploads.withLock { $0.count } == 1 + DictationConfig.transcriptionRetryDelays.count)
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!controller.isRetrying)
    }

    @Test func eachRetryWaitsItsDelay() async {
        let capture = FakeCapture()
        let times = Mutex<[ContinuousClock.Instant]>([])
        let controller = controller(capture: capture, transcript: {
            times.withLock { $0.append(.now) }
            throw DictationError(status: 503, code: nil)
        }, retryDelays: [.milliseconds(150), .milliseconds(300)])

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        let sent = times.withLock { $0 }
        #expect(sent.count == 3)
        guard sent.count == 3 else { return }
        #expect(sent[1] - sent[0] >= .milliseconds(150))
        #expect(sent[2] - sent[1] >= .milliseconds(300))
    }

    /// Cancelled while it waits to try again: nothing more is sent or appended.
    @Test func aDictationCancelledWhileItWaitsToRetrySendsNothingMore() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { throw DictationError(status: 502, code: nil) }, retryDelays: [.milliseconds(300)])

        await dictate(controller, capture: capture)
        await waitUntil { controller.isRetrying }
        #expect(controller.isRetrying)
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(600))

        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(controller.phase == .idle)
        #expect(!controller.isRetrying)
    }

    /// The server's error can still arrive after the dictation was cancelled: it is not tried again,
    /// and the field never says it is.
    @Test func aServerErrorAnsweredAfterACancelIsNotTriedAgain() async {
        let capture = FakeCapture()
        let retryingSeen = Mutex(false)
        let ref = ControllerRef()
        let controller = controller(capture: capture, transcript: {
            await MainActor.run { ref.controller?.cancel() }
            throw DictationError(status: 502, code: nil)
        })
        ref.controller = controller

        await dictate(controller, capture: capture)
        await waitUntil { recorded.uploads.withLock { !$0.isEmpty } && controller.phase == .idle }
        // A retry would be sent after its 1 ms delay: watch well past it.
        for _ in 0..<20 {
            if controller.isRetrying { retryingSeen.withLock { $0 = true } }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!retryingSeen.withLock { $0 })
        #expect(!controller.isRetrying)
        #expect(controller.phase == .idle)
    }

    nonisolated static let serverErrors: [(any Error, Bool)] = [
        (DictationError(status: 500, code: nil), true),
        (DictationError(status: 599, code: nil), true),
        (DictationError(status: 503, code: nil), true),
        (DictationError(status: 504, code: "transcription_timeout"), false),
        (DictationError(status: 499, code: nil), false),
        (DictationError.rateLimited, false),
        (DictationError.unauthorized, false),
        (DictationError.invalidResponse, false),
        (URLError(.networkConnectionLost), true),
        (URLError(.cannotConnectToHost), true),
        (URLError(.timedOut), false),
        (URLError(.cancelled), false),
        (CancellationError(), false),
    ]

    @Test(arguments: serverErrors)
    func whatCountsAsAServerError(error: any Error, retried: Bool) {
        #expect(DictationController.isServerError(error) == retried)
    }

    // MARK: The warm-up (TabMail Voice ADR-DESK-039)

    /// The mic's tap warms the backend at once, before the recording is sent, once per dictation.
    @Test func theWarmUpIsSentWhenListeningStarts() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: {
            #expect(self.recorded.warmUps.withLock { $0 } == 1)
            return "ask jordan about the road map"
        })

        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { recorded.warmUps.withLock { $0 } == 1 }
        #expect(recorded.warmUps.withLock { $0 } == 1)
        await waitUntil { capture.starts == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(recorded.warmUps.withLock { $0 } == 1)
        #expect(recorded.uploads.withLock { $0.count } == 1)
    }

    /// Not started (offline, no AI access, opted out of AI): nothing is warmed.
    @Test(arguments: [(false, true, false), (true, false, false), (true, true, true)])
    func aDictationThatDoesNotStartWarmsNothing(online: Bool, canUseAI: Bool, optedOut: Bool) async {
        let controller = controller(online: online, optedOut: { optedOut })

        controller.start(context: context, canUseAI: canUseAI) { _ in }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(controller.phase == .idle)
        #expect(recorded.warmUps.withLock { $0 } == 0)
    }

    /// The dictation never waits for the warm-up: one that never answers leaves it as it was.
    @Test func aWarmUpThatNeverAnswersHoldsNothingUp() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, warmUp: { try? await Task.sleep(for: .seconds(60)) })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
    }

    /// A failed cleanup never costs the dictation: the transcript is appended as heard. The backend
    /// answers `""` when its cleanup failed or ran past its deadline; one without the cleanup
    /// (backend ADR-027 not deployed) answers no `cleaned_text`.
    @Test(arguments: ["", " \n", nil] as [String?])
    func aFailedCleanupAppendsTheTranscriptAsHeard(cleaned: String?) async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, cleaned: { cleaned })

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

    /// The waveform lies flat until speech is heard: neither the microphone's start-up silence
    /// nor the room's noise moves it; a voice does.
    @Test func theWaveformLiesFlatUntilSpeechIsHeard() async {
        // A room whose noise rises: it would move an ungated waveform.
        let room = FakeCapture(buffers: [FakeCapture.silence(), FakeCapture.tone(seconds: 0.5, amplitude: 0.005), FakeCapture.tone(seconds: 0.5, amplitude: 0.01)])
        let waiting = controller(capture: room)
        waiting.start(context: context, canUseAI: true) { _ in }
        await waitUntil { room.starts == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(waiting.phase == .listening)
        #expect(!waiting.hasHeardSpeech)
        #expect(waiting.level == 0)
        waiting.cancel()

        let speaking = FakeCapture(buffers: [FakeCapture.tone(seconds: 1, amplitude: 0.01), FakeCapture.speech(), FakeCapture.speech()])
        let heard = controller(capture: speaking)
        heard.start(context: context, canUseAI: true) { _ in }
        await waitUntil { heard.level > 0 }
        #expect(heard.hasHeardSpeech)
        #expect(heard.level > 0)
        heard.cancel()
    }

    /// Someone who says nothing sends nothing: stopping a dictation that never heard speech
    /// uploads nothing, appends nothing, and releases the microphone.
    @Test func nothingIsSentWithoutSpeech() async {
        let capture = FakeCapture(buffer: FakeCapture.tone(seconds: 1, amplitude: 0.01))
        let controller = controller(capture: capture, speechDetector: FakeSpeechDetector.deaf())

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(controller.phase == .idle)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(!capture.isRunning)
    }

    /// Waiting for speech has no time limit: the recording cap only starts once someone speaks,
    /// so background noise never uses it up (owner, 2026-09-28).
    @Test func aDictationWaitsForSpeechWithoutALimit() async {
        let capture = FakeCapture(buffer: FakeCapture.tone(seconds: 1, amplitude: 0.01))
        let controller = controller(capture: capture, maxRecordingDuration: .seconds(1), speechDetector: FakeSpeechDetector.deaf())

        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        try? await Task.sleep(for: .milliseconds(1_500))

        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        controller.cancel()
    }

    /// A word said just before stop, too late for the classifier to call it while listening, is
    /// still heard in its last window and sent.
    @Test func aWordJustBeforeStopIsStillSent() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, speechDetector: FakeSpeechDetector.make(hearsWhenFlushed: true) { _ in false })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(recorded.texts.withLock { $0 } == ["Ask Jordan about the roadmap."])
    }

    /// The moment before speech is recorded, so the first word isn't clipped, and counts toward
    /// the recording cap.
    @Test func theMomentBeforeSpeechIsKeptAndCounted() async throws {
        let capture = FakeCapture(buffers: [FakeCapture.tone(seconds: 5, amplitude: 0.01), FakeCapture.speech()])
        let controller = controller(capture: capture, maxRecordingDuration: .seconds(3))

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }
        let heard = ContinuousClock.now
        await waitUntil { controller.phase != .listening }
        // The cap's remaining second, not all three.
        #expect(ContinuousClock.now - heard < .milliseconds(2_500))
        await waitUntil { controller.phase == .idle }

        let flac = try #require(recorded.uploads.withLock { $0.first })
        let seconds = Double(try FLACTestDecoder.decode(flac).totalSamples) / DictationConfig.recordingSampleRate
        // The two seconds held before the voice, then the voice's tenth of a second.
        #expect(abs(seconds - 2.1) < 0.02)
    }

    /// A speech detector that can't run ends the dictation quietly, releasing the microphone.
    @Test func aSpeechDetectorThatCannotRunEndsTheDictation() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, speechDetector: { _, onFailure in BrokenSpeechDetector(onFailure: onFailure) })

        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { controller.phase == .idle }

        #expect(controller.phase == .idle)
        #expect(!capture.isRunning)
        #expect(recorded.uploads.withLock { $0.isEmpty })
    }

    /// A recording is never longer than the transcription model takes (120 s, backend ADR-022),
    /// and stays under the backend's 10 MiB upload limit.
    @Test func noRecordingOutlastsWhatTheModelTranscribes() {
        #expect(DictationConfig.maxRecordingDuration <= .seconds(120))
        #expect(DictationConfig.maxRecordingDuration > .zero)
        let bytes = Int(DictationConfig.maxRecordingDuration.components.seconds) * Int(DictationConfig.recordingSampleRate) * MemoryLayout<Int16>.size
        #expect(bytes < 10 * 1024 * 1024)
    }

    /// A controller built as the app builds it (no cap passed in) sends at most 120 s of audio,
    /// however long the microphone ran, and still delivers the text.
    @Test func theAppsControllerSendsAtMostWhatTheModelTranscribes() async throws {
        let capture = FakeCapture(buffer: FakeCapture.tone(seconds: 121))
        let recorded = recorded
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { nil },
            transcribe: { flac, _, _, _ in
                recorded.uploads.withLock { $0.append(flac) }
                return DictationTranscription(text: "a long dictation", cleanedText: "A long dictation.")
            },
            warmUp: {},
            speechDetector: FakeSpeechDetector.hearing()
        )

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        let flac = try #require(recorded.uploads.withLock { $0.first })
        // 120 s of 16 kHz mono.
        #expect(try FLACTestDecoder.decode(flac).totalSamples == 120 * 16_000)
        #expect(!capture.isRunning)
        #expect(recorded.texts.withLock { $0 } == ["A long dictation."])
    }

    @Test func anotherDictationCanStartAfterAFailure() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, transcript: { " " })
        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }
        #expect(controller.phase == .idle)

        controller.start(context: context, canUseAI: true) { _ in }

        #expect(controller.phase == .listening)
        controller.cancel()
    }

    /// A failed dictation leaves nothing behind for the next: stopping the next one before the
    /// microphone answers records and uploads nothing, rather than resending the failed recording.
    @Test func aFailureLeavesNothingForTheNextDictation() async {
        let capture = FakeCapture()
        let accessRequests = Mutex(0)
        let controller = controller(capture: capture, microphoneAccess: {
            let request = accessRequests.withLock { $0 += 1; return $0 }
            if request > 1 { try? await Task.sleep(for: .milliseconds(200)) }
            return true
        }, transcript: { " " })
        await dictate(controller, capture: capture)
        await waitUntil { controller.phase != .transcribing }
        #expect(controller.phase == .idle)
        #expect(recorded.uploads.withLock { $0.count } == 1)

        controller.start(context: context, canUseAI: true) { _ in Issue.record("nothing was recorded") }
        controller.finish()
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(controller.phase == .idle)
        #expect(recorded.uploads.withLock { $0.count } == 1)
        #expect(capture.starts == 1)
        #expect(!capture.isRunning)
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

    /// A dictation cancelled while the backend transcribes and cleans it up never lands in the one
    /// started after it: an older dictation must not append to, or end, a newer one.
    @Test func aSupersededCleanupNeverLandsInTheNextDictation() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, cleaned: {
            try? await Task.sleep(for: .milliseconds(300))
            return "Too late."
        })

        await dictate(controller, capture: capture)
        await waitUntil { recorded.cleanups.withLock { !$0.isEmpty } }
        controller.cancel()
        controller.start(context: context, canUseAI: true) { _ in Issue.record("the second dictation was not finished") }
        await waitUntil { capture.starts == 2 }
        try? await Task.sleep(for: .milliseconds(600))

        #expect(recorded.texts.withLock { $0.isEmpty })
        #expect(recorded.used.withLock { $0.isEmpty })
        #expect(controller.phase == .listening)
        #expect(capture.isRunning)
        controller.cancel()
    }

    /// At the recording cap the recording is sent rather than dropped. (Whole seconds: the recorder,
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

        #expect(controller.phase == .idle)
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

    @Test func appendsToTheEndOfTheInputASpaceApart() {
        #expect(DictationController.appending("Hello there.", to: "") == "Hello there.")
        #expect(DictationController.appending("Hello there.", to: " \n") == "Hello there.")
        #expect(DictationController.appending("see you then", to: "Thanks, ") == "Thanks, see you then")
        #expect(DictationController.appending("second line", to: "first line\n") == "first line second line")
    }

    // MARK: - The dictionary (ADR-IOS-086)

    /// Starts with `context`, waits for the microphone, and taps stop; the text lands in `field`.
    private func dictate(_ controller: DictationController, capture: FakeCapture, context: DictationContext, field: InputField? = nil) async {
        let recorded = recorded
        let starts = capture.starts
        var input: (@MainActor () -> String)?
        if let field { input = { field.text } }
        controller.start(context: context, canUseAI: true, input: input) { text in
            recorded.texts.withLock { $0.append(text) }
            if let field { field.text = DictationController.appending(text, to: field.text) }
        }
        await waitUntil { capture.starts == starts + 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }
    }

    /// The email's body is read from the search index under the key the content stores write it
    /// under (`MessageContentStore.capture`), for any provider, so the read follows the content-key
    /// migration; none for an email no longer there.
    @Test func theEmailsBodyIsReadUnderItsContentKey() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "imap1", provider: .imap)
        try TestDatabase.insertAccount(db, id: "gmail1", email: "other@example.com", provider: .gmail)
        try TestDatabase.insertFolder(db, accountId: "imap1")
        try TestDatabase.insertFolder(db, accountId: "gmail1")
        let imap = try TestDatabase.insertMessageHeader(db, messageId: "42", folderId: "imap1:INBOX", accountId: "imap1", rfc822MessageId: "<note-1@example.com>")
        let gmail = try TestDatabase.insertMessageHeader(db, messageId: "18c2f", folderId: "gmail1:INBOX", accountId: "gmail1")

        try db.read { db in
            for header in [imap, gmail] {
                let key = try DictationController.contentKey(headerId: header.id, db: db)
                #expect(key != nil)
                #expect(try key == MessageContentStore.capture(header, db: db)?.contentKey)
            }
            #expect(try DictationController.contentKey(headerId: "imap1:INBOX:999", db: db) == nil)
        }
    }

    /// The dictionary's words in the transcript and the cleaned-up text are marked used, so a full
    /// dictionary keeps them over the learned words not used since; only the transcript when no
    /// cleanup came back.
    @Test(arguments: [
        (String?.some("Ask Jordan about the roadmap."), ["ask jordan about the road map", "Ask Jordan about the roadmap."]),
        (nil, ["ask jordan about the road map"]),
    ])
    func marksTheWordsOfTheDictationUsed(cleaned: String?, used: [String]) async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, cleaned: { cleaned })

        await dictate(controller, capture: capture)
        await waitUntil { controller.phase == .idle }

        #expect(recorded.used.withLock { $0 } == [used])
    }

    /// The recording goes with the user's dictionary and the terms of what the dictation is about,
    /// the email's body among it; the cleanup's variables carry the dictionary alone (it reads the
    /// screen itself).
    @Test func sendsTheDictionaryAndTheContextsTerms() async throws {
        let capture = FakeCapture()
        let bodies = Mutex<[String]>([])
        let controller = controller(
            capture: capture,
            dictionary: { .init(words: ["Xyvora"], learnsWords: false) },
            emailBody: { id in
                bodies.withLock { $0.append(id) }
                return "We met Xyvora and the team at Brevalle Labs yesterday."
            }
        )
        let context = DictationContext.chatPill(title: "Chat", header: ["From: Kaelthorne Drake"], messages: [], input: "", emailId: "email-1")

        await dictate(controller, capture: capture, context: context)

        #expect(bodies.withLock { $0 } == ["email-1"])
        let vocabulary = try #require(recorded.vocabularies.withLock { $0.first })
        #expect(vocabulary.first == "Xyvora")
        // A dictionary word in the context is sent once.
        #expect(vocabulary.count == 3)
        #expect(Set(vocabulary) == ["Xyvora", "Kaelthorne Drake", "Brevalle Labs"])
        #expect(recorded.cleanups.withLock { $0.first?["dictionary"] } == "Xyvora")
    }

    /// A full dictionary and an email of more terms than the context's share: the dictionary whole,
    /// then the context's first `contextTermsMax` terms, never more words than the backend takes.
    @Test func sendsAtMostTheContextsShareOfTerms() async throws {
        let capture = FakeCapture()
        func name(_ prefix: String, _ i: Int) -> String {
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return prefix + String(letters[i / letters.count]) + String(letters[i % letters.count])
        }
        let words = (0..<DictationConfig.dictionaryMaxEntries).map { name("Qor", $0) }
        let terms = (0..<DictationConfig.contextTermsMax + 50).map { name("Xyv", $0) }
        let controller = controller(
            capture: capture,
            dictionary: { .init(words: words, learnsWords: false) },
            emailBody: { _ in "ask " + terms.joined(separator: " and ") + " today" }
        )
        let context = DictationContext.chatPill(title: "Chat", header: [], messages: [], input: "", emailId: "email-1")

        await dictate(controller, capture: capture, context: context)

        let vocabulary = try #require(recorded.vocabularies.withLock { $0.first })
        #expect(vocabulary.count == DictationConfig.dictionaryMaxEntries + DictationConfig.contextTermsMax)
        guard vocabulary.count == DictationConfig.dictionaryMaxEntries + DictationConfig.contextTermsMax else { return }
        #expect(Array(vocabulary.prefix(DictationConfig.dictionaryMaxEntries)) == words)
        #expect(Array(vocabulary.suffix(DictationConfig.contextTermsMax)) == Array(terms.prefix(DictationConfig.contextTermsMax)))
    }

    /// With no dictionary and nothing to pick, no words are sent.
    @Test func withoutWordsNoneAreSent() async throws {
        let capture = FakeCapture()
        let controller = controller(capture: capture)

        await dictate(controller, capture: capture, context: context)

        #expect(recorded.vocabularies.withLock { $0 } == [[]])
        #expect(recorded.cleanups.withLock { $0.first?["dictionary"] } == "")
    }

    /// The dictionary is read when the dictation starts: a word added meanwhile goes with the next.
    @Test func theDictionaryIsTheOneAtTheStart() async throws {
        let capture = FakeCapture()
        let words = Mutex(["Xyvora"])
        let controller = controller(capture: capture, dictionary: { .init(words: words.withLock { $0 }, learnsWords: false) })

        controller.start(context: context, canUseAI: true) { _ in }
        await waitUntil { capture.starts == 1 }
        words.withLock { $0 = ["Xyvora", "Brevalle"] }
        controller.finish()
        await waitUntil { controller.phase == .idle }
        await dictate(controller, capture: capture, context: context)

        #expect(recorded.vocabularies.withLock { $0 } == [["Xyvora"], ["Xyvora", "Brevalle"]])
    }

    /// Terms not picked within `contextTermsWait` are left out; the dictation goes on without them.
    @Test func slowTermsDoNotHoldUpTheDictation() async throws {
        let capture = FakeCapture()
        let controller = controller(
            capture: capture,
            dictionary: { .init(words: ["Xyvora"], learnsWords: false) },
            emailBody: { _ in
                try? await Task.sleep(for: .seconds(30))
                return "Brevalle Labs"
            }
        )
        let context = DictationContext.chatPill(title: "Chat", header: [], messages: [], input: "", emailId: "email-1")
        let started = ContinuousClock.now

        await dictate(controller, capture: capture, context: context)

        #expect(recorded.vocabularies.withLock { $0 } == [["Xyvora"]])
        #expect(recorded.texts.withLock { $0 }.count == 1)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Cancelled while its terms are still being picked (the pill went away): the recording is not
    /// uploaded.
    @Test func aDictationCancelledWhileItsTermsArePickedUploadsNothing() async {
        let capture = FakeCapture()
        let controller = controller(capture: capture, emailBody: { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        let context = DictationContext.chatPill(title: "Chat", header: [], messages: [], input: "", emailId: "email-1")
        let recorded = recorded
        controller.start(context: context, canUseAI: true) { text in recorded.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }
        controller.finish()
        // The recording is complete (the microphone stopped) and waits for its terms.
        await waitUntil { capture.starts == 1 && !capture.isRunning }
        controller.cancel()
        try? await Task.sleep(for: .seconds(DictationConfig.contextTermsWait * 3))

        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.texts.withLock { $0.isEmpty })
    }

    /// With learning on at the start, the field the text landed in is watched, and the user's
    /// respelling in it is learned when the input is sent.
    @Test func learnsTheUsersCorrectionOfTheText() async throws {
        let capture = FakeCapture()
        let learned = LearnedWords()
        let watch = DictationCorrectionWatch(learn: { learned.words.append($0) }, interval: .seconds(3600), duration: .seconds(7200))
        let controller = controller(
            capture: capture,
            transcript: { "ask zivora about the roadmap" },
            cleaned: { "Ask Zivora about the roadmap today." },
            dictionary: { .init(words: [], learnsWords: true) },
            corrections: watch
        )
        let field = InputField()
        field.text = "Hi."

        await dictate(controller, capture: capture, context: context, field: field)

        #expect(field.text == "Hi. Ask Zivora about the roadmap today.")
        #expect(watch.isWatching)
        field.text = "Hi. Ask Xyvora about the roadmap today."
        controller.inputSent(field.text)
        #expect(learned.words == [["Xyvora"]])
        #expect(!watch.isWatching)
    }

    /// Learning switched off at the start: the field is not watched.
    @Test func withLearningOffNothingIsWatched() async throws {
        let capture = FakeCapture()
        let watch = DictationCorrectionWatch(learn: { _ in Issue.record("nothing learned") }, interval: .seconds(3600))
        let controller = controller(capture: capture, dictionary: { .init(words: [], learnsWords: false) }, corrections: watch)

        await dictate(controller, capture: capture, context: context, field: InputField())

        #expect(recorded.texts.withLock { $0 }.count == 1)
        #expect(!watch.isWatching)
    }

    /// The next dictation's start ends the last one's watch, so its text is never taken for a
    /// correction; so does the pill going away.
    @Test func theNextDictationAndThePillGoingAwayEndTheWatch() async throws {
        let capture = FakeCapture()
        let watch = DictationCorrectionWatch(learn: { _ in }, interval: .seconds(3600))
        let controller = controller(capture: capture, dictionary: { .init(words: [], learnsWords: true) }, corrections: watch)
        let field = InputField()

        await dictate(controller, capture: capture, context: context, field: field)
        #expect(watch.isWatching)
        controller.start(context: context, canUseAI: true) { _ in }
        #expect(!watch.isWatching)
        controller.cancel()

        await dictate(controller, capture: capture, context: context, field: field)
        #expect(watch.isWatching)
        controller.stopLearning()
        #expect(!watch.isWatching)
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
            transcribe: { flac, _, _, cleanup in
                recorded.uploads.withLock { $0.append(flac) }
                recorded.cleanups.withLock { $0.append(cleanup) }
                return DictationTranscription(text: "ask jordan", cleanedText: "Ask Jordan.")
            },
            warmUp: { recorded.warmUps.withLock { $0 += 1 } }
        )

        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { _ in
            Issue.record("no text when opted out")
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.phase == .idle)
        #expect(capture.starts == 0)
        #expect(recorded.uploads.withLock { $0.isEmpty })
        #expect(recorded.cleanups.withLock { $0.isEmpty })
        #expect(recorded.warmUps.withLock { $0 } == 0)
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
        #expect(start.contains("dictation.start(context: dictationContext, canUseAI: canUseAI, input: { inputText })"))
    }

    /// The dictionary (ADR-IOS-086): the terms are picked from the email the pill is about too; the
    /// input as sent is compared for corrections before it is cleared; the pill going away ends the
    /// watch; Settings › Personalization opens the dictionary.
    @Test func theDictionaryIsWiredIntoThePill() throws {
        let source = try pillSource()
        #expect(source.contains("return .chatPill(title: message.subject, header: header, messages: chatMessages, input: inputText, emailId: message.id)"))
        let send = try slice(source, from: "private func sendMessage()", to: "Task { @MainActor in")
        #expect(send.contains("dictation.inputSent(inputText)\n        inputText = \"\""))
        let disappear = try slice(source, from: ".onDisappear {", to: "// No eager cancellation")
        #expect(disappear.contains("dictation.cancel()\n            dictation.stopLearning()"))

        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Settings/TabMailSettingsView.swift"), encoding: .utf8)
        let personalization = try slice(settings, from: "Section(\"Personalization\") {", to: "// BYOK tier configuration")
        #expect(personalization.contains("DictationDictionaryView()"))
        #expect(personalization.contains("Text(\"Voice Dictation Dictionary\")"))
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

    /// While dictating, the input field stays in place with its text dimmed behind the waveform,
    /// can't be edited, and a tap on it stops listening; otherwise nothing covers it.
    @Test func theWaveformDimsTheInputInPlace() throws {
        let source = try pillSource()
        let field = String(try slice(source, from: "TextField(isComposeMode ?", to: "if isWorking {"))
        // The field dims and ignores touches beneath the overlay, which stays full strength and
        // tappable: both modifiers come before it.
        let beneath = try slice(field, from: "TextField(isComposeMode ?", to: ".overlay {")
        #expect(beneath.contains(".opacity(dictation.isActive ? DictationConfig.dimmedInputOpacity : 1)"))
        #expect(beneath.contains(".allowsHitTesting(!dictation.isActive)"))
        #expect(beneath.contains(".accessibilityHidden(dictation.isActive)"))
        let overlay = try slice(field, from: ".overlay {", to: ".onTapGesture { dictation.finish() }")
        #expect(overlay.contains("if dictation.isActive {\n                        DictationPillView(controller: dictation)"))
        #expect(source.components(separatedBy: "DictationPillView(").count == 2)
        #expect(source.components(separatedBy: "TextField(").count == 2)
        #expect(DictationConfig.dimmedInputOpacity > 0 && DictationConfig.dimmedInputOpacity < 0.5)
    }

    /// While listening, send finishes the dictation, then sends its text once it lands; a
    /// dictation that brings back nothing sends nothing, and nothing carries over to the next.
    /// While the words are transcribed, the button is a spinner. A pending retry doesn't take
    /// the slot while dictating.
    @Test func sendFinishesTheDictationThenSendsItsText() throws {
        let source = try pillSource()
        let send = try slice(source, from: "// Normal send button", to: ".disabled(!canTapSend)")
        #expect(send.contains("if dictation.phase == .listening {"))
        #expect(send.contains("sendWhenDictated = true\n                        dictation.finish()\n                    } else {\n                        sendMessage()"))
        #expect(send.contains(".foregroundStyle(canTapSend ? Theme.accent : .secondary.opacity(0.3))"))
        let canTapSend = try slice(source, from: "private var canTapSend: Bool {", to: "private func sendMessage()")
        #expect(canTapSend.contains("canSend || (dictation.phase == .listening && hasTabMailSession && !isWorking && composeReadyToSend)"))
        let composeReady = try slice(source, from: "private var composeReadyToSend: Bool {", to: "private var canTapSend: Bool")
        #expect(composeReady.contains("!isComposeMode || (composeMutationAllowed && composeAttachmentSnapshotReady)"))
        // While dictating, the slot is send even after a failed turn: retry doesn't take it over.
        #expect(source.contains("} else if !isWorking && !dictation.isActive && (pendingResumeRequest != nil || lastFailedMessage != nil)"))
        #expect(!source.contains("Image(systemName: \"stop.circle.fill\")\n                        .font(.title2)\n                        .foregroundStyle(Theme.accent)"))

        let transcribing = try slice(source, from: "} else if dictation.phase == .transcribing {", to: "} else if !isWorking && !dictation.isActive && (pendingResumeRequest != nil")
        #expect(transcribing.contains("DictationSpinner()"))
        #expect(!transcribing.contains("Button"))

        let start = String(try slice(source, from: "private func startDictation()", to: "private var canSend: Bool"))
        let onText = try slice(start, from: "{ text in", to: "scrollPosition.scrollTo(edge: .bottom)")
        let appended = try #require(onText.range(of: "inputText = DictationController.appending(text, to: inputText)"))
        let sent = try #require(onText.range(of: "if sendWhenDictated {\n                sendWhenDictated = false\n                if canSend { sendMessage() }"))
        #expect(appended.upperBound <= sent.lowerBound)

        let ended = try slice(source, from: ".onChange(of: dictation.isActive) {", to: ".onChange(of: isTextFieldFocused)")
        #expect(ended.contains("if !active { sendWhenDictated = false }"))
        let disappear = try slice(source, from: ".onDisappear {", to: "// No eager cancellation")
        #expect(disappear.contains("sendWhenDictated = false"))
        #expect(source.components(separatedBy: "sendWhenDictated = true").count == 2)
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

    /// The app's controller reads the email's body from the search index
    /// (`readsTheEmailsBodyFromTheSearchIndex`) and learns corrections into the dictionary.
    @Test func theAppsControllerReadsBodiesAndLearnsIntoTheDictionary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/DictationController.swift"), encoding: .utf8)
        #expect(controller.contains("emailBody: @escaping EmailBody = { await DictationController.storedEmailBody(headerId: $0) },"))
        #expect(controller.contains("corrections: DictationCorrectionWatch? = DictationCorrectionWatch { DictationDictionary.shared.learn($0) },"))
        #expect(controller.contains("useWords: @escaping @MainActor ([String]) -> Void = { DictationDictionary.shared.use($0) },"))
    }

    /// The Settings menu writes the key the controller reads, the waveform shows no language, and
    /// the mic points to the menu once a dictation has landed.
    @Test func theLanguageMenuAndItsTipAreWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The app's controller transcribes through the factory `theBackendRequestCarriesTheDictationsLanguage` tests.
        let controller = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/DictationController.swift"), encoding: .utf8)
        #expect(controller.contains("self.transcribeAudio = transcribe ?? Self.backendTranscription(AccountManager.shared.backendClient)"))
        // …and warms through the factory `theWarmUpGoesOverTheTranscriptionsSession` tests.
        #expect(controller.contains("self.warmUp = warmUp ?? Self.backendWarmUp(AccountManager.shared.backendClient)"))

        let settings = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Settings/TabMailSettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("@AppStorage(DictationLanguage.settingKey) private var dictationLanguage = DictationLanguage.automatic"))
        #expect(settings.contains("Picker(selection: $dictationLanguage)"))
        #expect(settings.contains("ForEach(DictationLanguage.choices(), id: \\.self)"))
        // Each row is tagged with the value it stores: its own code, or Automatic's.
        let menu = try slice(settings, from: "Picker(selection: $dictationLanguage) {", to: "} label: {")
        #expect(menu.contains("Text(automaticDictationLanguageLabel).tag(DictationLanguage.automatic)"))
        #expect(menu.contains("Text(DictationLanguage.name(of: code)).tag(code)"))
        #expect(menu.components(separatedBy: ".tag(").count == 3)
        // Choosing a language retires the tip that points to the menu.
        let change = try slice(settings, from: ".onChange(of: dictationLanguage) {", to: "}")
        #expect(change.contains("DictationLanguageTip().invalidate(reason: .actionPerformed)"))

        // The tip shows once, after the first dictation that came back, and only after onboarding.
        let tips = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Components/AppTips.swift"), encoding: .utf8)
        let tip = try slice(tips, from: "struct DictationLanguageTip: Tip {", to: "// MARK: - Settings Tips")
        #expect(tip.contains("#Rule(Self.dictationCompleted) { $0.donations.count >= 1 }"))
        #expect(tip.contains("#Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }"))
        #expect(tip.contains("MaxDisplayCount(1)"))
        #expect(tip.components(separatedBy: "#Rule(").count == 3)

        // The waveform shows no language; VoiceOver reads the label `DictationWaveformTests` checks.
        let pill = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Inbox/DictationPillView.swift"), encoding: .utf8)
        #expect(!pill.contains("controller.language"))
        #expect(!pill.contains("Badge"))
        #expect(pill.contains("Waveform(level: controller.level, isFlat: controller.phase == .listening && !controller.hasHeardSpeech)"))
        #expect(pill.contains("guard !isFlat else { return DictationConfig.meterMinBarHeight }"))
        #expect(pill.contains(".accessibilityElement(children: .ignore)\n        .accessibilityLabel(accessibilityLabel)"))
        // While a transcription is tried again, the note takes the waveform's place.
        #expect(pill.contains("if controller.isRetrying {\n                Text(Self.retryingMessage)"))

        let source = try pillSource()
        #expect(source.contains(".popoverTip(DictationLanguageTip(), arrowEdge: .bottom)"))
        // Donated only from the text callback, which a dictation calls once its text is back.
        let beforeStart = try slice(source, from: "private func startDictation()", to: "dictation.start(context:")
        #expect(!beforeStart.contains("donate()"))
        let start = String(try slice(source, from: "private func startDictation()", to: "private var canSend: Bool"))
        let onText = try slice(start, from: "dictation.start(context: dictationContext, canUseAI: canUseAI, input: { inputText }) { text in", to: "scrollPosition.scrollTo(edge: .bottom)")
        #expect(onText.contains("DictationLanguageTip.dictationCompleted.donate()"))
        // Nothing after the callback's last statement donates either.
        let pieces = start.components(separatedBy: "scrollPosition.scrollTo(edge: .bottom)")
        #expect(pieces.count == 2)
        #expect(pieces.last?.contains("donate()") == false)
        #expect(source.components(separatedBy: "dictationCompleted.donate()").count == 2)
    }
}

/// What the waveform reads to VoiceOver: listening, then transcribing, never the language.
@MainActor
struct DictationWaveformTests {
    private func listening(language: String?, microphoneAccess: Bool = true) -> (DictationController, FakeCapture) {
        let capture = FakeCapture()
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { microphoneAccess },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { language },
            transcribe: { _, _, _, _ in try await Task.sleep(for: .seconds(60)); return DictationTranscription(text: "", cleanedText: nil) },
            warmUp: {},
            speechDetector: FakeSpeechDetector.hearing()
        )
        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { _ in }
        return (controller, capture)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: ["ko", nil] as [String?])
    func itReadsListeningThenTranscribing(language: String?) async {
        let (controller, capture) = listening(language: language)
        let waveform = DictationPillView(controller: controller)
        #expect(controller.language == language)
        #expect(waveform.accessibilityLabel == "Listening")
        await waitUntil { capture.starts == 1 }
        #expect(waveform.accessibilityLabel == "Listening")

        controller.finish()
        #expect(controller.phase == .transcribing)
        #expect(waveform.accessibilityLabel == "Transcribing")
        controller.cancel()
        #expect(waveform.accessibilityLabel == "")
    }

    /// While a transcription the server failed is tried again, VoiceOver reads the note the pill
    /// shows; cancelled, nothing.
    @Test func itReadsTheRetryingNoteWhileItRetries() async {
        let capture = FakeCapture()
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { nil },
            transcribe: { _, _, _, _ in throw DictationError(status: 502, code: "transcription_failed") },
            warmUp: {},
            transcriptionRetryDelays: [.seconds(60)],
            speechDetector: FakeSpeechDetector.hearing()
        )
        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { _ in }
        let waveform = DictationPillView(controller: controller)
        await waitUntil { capture.starts == 1 }
        controller.finish()
        #expect(waveform.accessibilityLabel == "Transcribing")

        await waitUntil { controller.isRetrying }
        #expect(controller.phase == .transcribing)
        #expect(waveform.accessibilityLabel == DictationPillView.retryingMessage)
        controller.cancel()
        #expect(waveform.accessibilityLabel == "")
    }

    /// A failed dictation leaves nothing on screen: it isn't active, so the input field doesn't
    /// dim or show the waveform.
    @Test func aFailureLeavesNothingShown() async {
        let (controller, _) = listening(language: "ko", microphoneAccess: false)
        await waitUntil { controller.phase != .listening }
        #expect(controller.phase == .idle)
        #expect(!controller.isActive)
        #expect(DictationPillView(controller: controller).accessibilityLabel == "")
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
                transcribe: { _, language, _, _ in
                    languages.withLock { $0.append(language) }
                    return DictationTranscription(text: "annyeong", cleanedText: "Annyeong.")
                },
                warmUp: {},
                speechDetector: FakeSpeechDetector.hearing()
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

    /// The production transcription carries the dictation's language and the cleanup's variables to
    /// the backend request, and the cleaned-up text it answers comes back as the dictation; without
    /// a language, none is sent.
    @Test(arguments: [("ko", "annyeong"), (nil, "hello")] as [(String?, String)])
    func theBackendRequestCarriesTheDictationsLanguage(language: String?, transcript: String) async throws {
        let http = FakeHTTP.Scenario()
        let bodies = Mutex<[Data]>([])
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            bodies.withLock { $0.append(request.body ?? Data()) }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // Like the backend, only a recording gets a transcript.
            let audio = (body?["audio"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            guard (try? FLACTestDecoder.decode(audio))?.totalSamples ?? 0 > 0 else {
                return .json(raw: #"{"error":"invalid_audio"}"#, statusCode: 400)
            }
            return .json(raw: #"{"text":"\#(transcript)","cleaned_text":"Cleaned.","duration_seconds":1}"#)
        }
        let capture = FakeCapture()
        let texts = Mutex<[String]>([])
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { language },
            transcribe: DictationController.backendTranscription(BackendClient(llmSession: http.session)),
            warmUp: {},
            speechDetector: FakeSpeechDetector.hearing()
        )

        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), canUseAI: true) { text in
            texts.withLock { $0.append(text) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while capture.starts == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        controller.finish()
        while controller.phase != .idle, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(bodies.withLock { $0.count } == 1)
        let body = try #require(bodies.withLock { $0.first }.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["language"] as? String == language)
        #expect(body.keys.contains("language") == (language != nil))
        #expect(body["format"] as? String == "flac")
        // The recording itself: a FLAC carrying the audio the microphone gave.
        let audio = try #require((body["audio"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(try FLACTestDecoder.decode(audio).totalSamples > 0)
        // The cleanup goes in the same request (backend ADR-027).
        #expect(body["cleanup"] as? [String: String] == DictationCleanup.variables(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), dictionary: []))
        #expect(texts.withLock { $0 } == ["Cleaned."])
    }

    /// Settings' menu stores its choice through `@AppStorage` under the key the controller reads:
    /// Korean is sent as `ko`, and Automatic goes back to the iPhone's language.
    @Test func theMenusStoredChoiceIsTheLanguageSent() async {
        await withSetting(nil) {
            let stored = AppStorage(wrappedValue: DictationLanguage.automatic, DictationLanguage.settingKey)
            #expect(DictationLanguage.current() == DictationLanguage.code(forPreferredLanguages: Locale.preferredLanguages))
            stored.wrappedValue = "ko"
            #expect(DictationLanguage.current() == "ko")
            // A new view reads the same choice.
            #expect(AppStorage(wrappedValue: DictationLanguage.automatic, DictationLanguage.settingKey).wrappedValue == "ko")
            stored.wrappedValue = DictationLanguage.automatic
            #expect(DictationLanguage.current() == DictationLanguage.code(forPreferredLanguages: Locale.preferredLanguages))
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
        // Written out from backend ADR-024, not read from the app's config: the default model's 18
        // languages, then the 12 paired with another model.
        let backendLanguages: Set<String> = [
            "en", "es", "fr", "de", "it", "pt", "ar", "da", "nl", "fi", "he", "hi", "ja", "zh", "no", "sv", "tr", "vi",
            "cs", "el", "fa", "hu", "id", "ko", "mk", "ms", "pl", "ro", "ru", "th",
        ]
        let locale = Locale(identifier: "en_US")
        let choices = DictationLanguage.choices(locale: locale)
        #expect(choices.count == backendLanguages.count)
        #expect(Set(choices) == backendLanguages)
        let names = choices.map { DictationLanguage.name(of: $0, locale: locale) }
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(DictationLanguage.name(of: "ko", locale: locale) == "Korean")
    }
}

/// The app's own read of the email's body for its terms: from the search index, under the key the
/// content stores write it under; none for an email not there.
@Suite(.serialized, .processGlobalState)
struct DictationEmailBodyTests {
    @Test func readsTheEmailsBodyFromTheSearchIndex() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "dictation-body-\(UUID().uuidString)"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let header = MessageHeader(messageId: "42", subject: "Plans",
            from: "Sender", fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "", folderId: "\(accountId):INBOX",
            accountId: accountId, folderPath: "INBOX", isInInbox: true)
        try await pool.write { db in try header.insert(db) }
        let key = try #require(try await pool.read { db in try MessageContentStore.capture(header, db: db)?.contentKey })
        let index = SearchIndex.shared
        _ = try await index.indexHeaders([FTSHeaderRecord(contentKey: key, headerId: header.id,
            messageId: header.messageId, subject: header.subject, from: header.fromAddress,
            to: header.to, dateMs: Int64(header.date.timeIntervalSince1970 * 1000))])
        #expect(await DictationController.storedEmailBody(headerId: header.id) == nil)

        try await index.updateBody(contentKey: key, body: "Meet Xyvora at Brevalle Labs.")

        #expect(await DictationController.storedEmailBody(headerId: header.id) == "Meet Xyvora at Brevalle Labs.")
        #expect(await DictationController.storedEmailBody(headerId: "\(accountId):INBOX:999") == nil)
    }
}
