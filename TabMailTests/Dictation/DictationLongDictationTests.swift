/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// A microphone the test speaks into: `feed` delivers audio as buffers, when the test says.
private final class SpeakingCapture: AudioCapturing, @unchecked Sendable {
    private struct State {
        var starts = 0
        var isRunning = false
        var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var deliveredOnStop: [Float] = []
    }

    private let state = Mutex(State())

    var starts: Int { state.withLock { $0.starts } }
    var isRunning: Bool { state.withLock { $0.isRunning } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, completion: @escaping @Sendable ((any Error)?) -> Void) {
        state.withLock { state in
            state.starts += 1
            state.isRunning = true
            state.onBuffer = onBuffer
        }
        completion(nil)
    }

    func stop() {
        // A tap callback already running still delivers its audio as the microphone stops.
        let (onBuffer, samples) = state.withLock { ($0.onBuffer, $0.deliveredOnStop) }
        if let onBuffer { for buffer in DictationTestAudio.buffers(samples) { onBuffer(buffer) } }
        state.withLock { state in
            state.isRunning = false
            state.onBuffer = nil
        }
    }

    /// Audio the microphone delivers as it stops.
    func deliverOnStop(_ samples: [Float]) {
        state.withLock { $0.deliveredOnStop = samples }
    }

    func feed(_ samples: [Float]) {
        guard let onBuffer = state.withLock({ $0.onBuffer }) else { return }
        for buffer in DictationTestAudio.buffers(samples) { onBuffer(buffer) }
    }
}

/// Hears speech in any buffer louder than a room, at once.
private final class LoudnessSpeechDetector: SpeechDetecting, @unchecked Sendable {
    private let heard = Mutex(false)
    private let onSpeech: @Sendable () -> Void

    init(onSpeech: @escaping @Sendable () -> Void) {
        self.onSpeech = onSpeech
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard MicrophoneCapture.decibels(of: buffer) > -30 else { return }
        let isFirst = heard.withLock { heard in
            defer { heard = true }
            return !heard
        }
        if isFirst { onSpeech() }
    }

    func finish() async -> Bool { heard.withLock { $0 } }
}

/// The backend, answering each chunk as the test says. A chunk is told apart by its audio: the
/// first upload of new audio is the next chunk, a repeat is a retry of one.
private final class ChunkBackend: Sendable {
    enum Reply: Sendable {
        case part
        case serverError
        case gatewayTimeout
        case connectionLost
        case refused
        /// The speech model's rate limit, past the backend's own retries.
        case speechModelRateLimited
        /// This account's own rate limit.
        case accountRateLimited
        /// Never answers until cancelled.
        case never
    }

    private struct State {
        var chunks: [Data] = []
        var attempts: [Int] = []
        var inFlight = 0
        var cleanups: [[String: String]] = []
        var languages: [String?] = []
        var vocabularies: [[String]] = []
    }

    private let state = Mutex(State())
    /// The reply to chunk `index`'s `attempt`th try (from 0).
    let reply: @Sendable (_ index: Int, _ attempt: Int) -> Reply

    init(reply: @escaping @Sendable (_ index: Int, _ attempt: Int) -> Reply = { _, _ in .part }) {
        self.reply = reply
    }

    /// Chunks sent so far, and how many tries each took.
    var sent: Int { state.withLock { $0.chunks.count } }
    var attempts: [Int] { state.withLock { $0.attempts } }
    var inFlight: Int { state.withLock { $0.inFlight } }
    var cleanups: [[String: String]] { state.withLock { $0.cleanups } }
    var languages: [String?] { state.withLock { $0.languages } }
    var vocabularies: [[String]] { state.withLock { $0.vocabularies } }
    /// Every request made, retries included.
    var requests: Int { state.withLock { $0.cleanups.count } }
    var chunks: [Data] { state.withLock { $0.chunks } }

    func transcribe(_ flac: Data, language: String? = nil, vocabulary: [String] = [], cleanup: [String: String]) async throws -> DictationTranscription {
        let (index, attempt) = state.withLock { state in
            let index = state.chunks.firstIndex(of: flac) ?? {
                state.chunks.append(flac)
                state.attempts.append(0)
                return state.chunks.count - 1
            }()
            defer { state.attempts[index] += 1 }
            state.inFlight += 1
            state.cleanups.append(cleanup)
            state.languages.append(language)
            state.vocabularies.append(vocabulary)
            return (index, state.attempts[index])
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        // A moment on the network, so requests overlap the recording and each other.
        try await Task.sleep(for: .milliseconds(5))
        switch reply(index, attempt) {
        case .part: return DictationTranscription(text: "raw \(index)", cleanedText: "Part \(index).")
        case .serverError: throw DictationError.failed(status: 502)
        case .gatewayTimeout: throw DictationError.failed(status: 504)
        case .connectionLost: throw URLError(.networkConnectionLost)
        case .refused: throw DictationError(status: 400, code: nil)
        case .speechModelRateLimited: throw DictationError(status: 429, code: "transcription_rate_limited")
        case .accountRateLimited: throw DictationError(status: 429, code: "rate_limited")
        case .never:
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
    }
}

/// The polish of a long dictation's joined text: answers each with `reply`, and records what it was
/// given. `.held` answers only once `answer()` is called, even after a cancel.
private final class Polisher: Sendable {
    enum Reply: Sendable {
        case text(String)
        case failure
        /// Never answers until cancelled.
        case never
        case held(String)
    }

    private struct State {
        var calls: [(text: String, cleanup: [String: String])] = []
        var cancelled = false
        var answered = false
    }

    private let state = Mutex(State())
    let reply: Reply

    init(_ reply: Reply = .failure) {
        self.reply = reply
    }

    var calls: [(text: String, cleanup: [String: String])] { state.withLock { $0.calls } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func answer() {
        state.withLock { $0.answered = true }
    }

    func polish(_ text: String, cleanup: [String: String]) async throws -> String {
        state.withLock { $0.calls.append((text, cleanup)) }
        switch reply {
        case .text(let reply):
            return reply
        case .failure:
            throw DictationError.failed(status: 500)
        case .never:
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                state.withLock { $0.cancelled = true }
                throw error
            }
            throw CancellationError()
        case .held(let reply):
            while !state.withLock({ $0.answered }) { await Task.yield() }
            return reply
        }
    }
}

/// The texts the dictations in one test pasted.
private final class Pasted: Sendable {
    let texts = Mutex<[String]>([])
}

/// A long dictation on iOS (ADR-IOS-087): cut into chunks as it is recorded, each sent at once with
/// its own cleanup, retried while the user goes on, and the text the chunks' in order up to the
/// first that gave up. As TabMail Voice's long-dictation tests (ADR-DESK-049).
@MainActor
struct DictationLongDictationTests {
    private typealias Audio = DictationTestAudio
    private let context = DictationContext(windowTitle: "Chat", screenText: "Me: hi\n» ‸")
    private let pasted = Pasted()

    private func controller(
        _ capture: SpeakingCapture,
        _ backend: ChunkBackend,
        chunkRetryDelays: [Duration] = [.milliseconds(1)],
        retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1)],
        retryNoticeDelay: Duration = .seconds(60),
        language: String? = nil,
        words: [String] = [],
        emailBody: @escaping DictationController.EmailBody = { _ in nil },
        useWords: @escaping @MainActor ([String]) -> Void = { _ in },
        polisher: Polisher = Polisher(),
        polishTimeout: Duration = .seconds(5)
    ) -> DictationController {
        DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { language },
            dictionary: { .init(words: words, learnsWords: false) },
            emailBody: emailBody,
            corrections: nil,
            useWords: useWords,
            transcribe: { flac, language, vocabulary, cleanup in try await backend.transcribe(flac, language: language, vocabulary: vocabulary, cleanup: cleanup) },
            warmUp: {},
            polish: { text, cleanup in try await polisher.polish(text, cleanup: cleanup) },
            chunkPolishTimeout: polishTimeout,
            transcriptionRetryDelays: retryDelays,
            transcriptionRetryNoticeDelay: retryNoticeDelay,
            chunkRetryDelays: chunkRetryDelays,
            speechDetector: { onSpeech, _ in LoudnessSpeechDetector(onSpeech: onSpeech) }
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func start(_ controller: DictationController, _ capture: SpeakingCapture) async {
        let pasted = pasted
        controller.start(context: context, canUseAI: true) { text in pasted.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }
    }

    /// Speaks for `seconds` each, a 1.5 s pause after all but the last: one chunk each (all at
    /// least `chunkMinimumSpeech` long but the last). Each pause's chunk is sent before the user
    /// goes on, as seconds of speech apart would have it, so the backend sees the chunks in order.
    private func speak(_ capture: SpeakingCapture, _ backend: ChunkBackend, seed: UInt32, _ seconds: Double...) async {
        var random = Audio.Random(seed: seed)
        for (index, length) in seconds.enumerated() {
            let isLast = index == seconds.count - 1
            capture.feed(Audio.speech(length, &random) + (isLast ? [] : Audio.room(1.5, &random)))
            if !isLast { await waitUntil { backend.sent == index + 1 } }
        }
    }

    @Test func chunksAreSentWhileRecordingAndJoinedInOrderEachWithItsCleanup() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 1, 12, 12, 5)
        // The first two were sent while the user was still speaking.
        await waitUntil { backend.attempts.count == 2 && backend.inFlight == 0 }
        #expect(backend.sent == 2)
        #expect(controller.phase == .listening)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1. Part 2."])
        #expect(backend.sent == 3)
        // Each chunk went with the dictation's cleanup.
        #expect(backend.cleanups.count == 3)
        #expect(backend.cleanups.allSatisfy { $0["window_title"] == "Chat" && $0["screen_text"] == "Me: hi\n» ‸" })
        #expect(!capture.isRunning)
        // Every upload is a chunk, none the whole recording.
        let lengths = backend.chunks.compactMap { try? FLACTestDecoder.decode($0).totalSamples }
        #expect(lengths.count == 3)
        #expect(lengths.allSatisfy { $0 < Int(25 * Audio.rate) })
    }

    /// Owner, 2026-10-03: "a final polished pass if time permits". Once its chunks are in, their
    /// cleanups, joined, go through the cleanup prompt once more as a whole, with the dictation's
    /// cleanup variables, and its reply is pasted. As TabMail Voice's.
    @Test func aLongDictationIsPolishedAsAWholeAndThePolishIsPasted() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let polisher = Polisher(.text("Part zero, part one and part two."))
        let controller = controller(capture, backend, words: ["Xyvora"], polisher: polisher)
        await start(controller, capture)

        await speak(capture, backend, seed: 50, 12, 12, 5)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part zero, part one and part two."])
        let calls = polisher.calls
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].text == "Part 0. Part 1. Part 2.")
        #expect(calls[0].cleanup == backend.cleanups.first)
        #expect(calls[0].cleanup["dictionary"] == "Xyvora")
    }

    /// The polish is only if time permits: one that fails, comes back empty or takes longer than
    /// `chunkPolishTimeout` leaves the chunks' cleanups, joined, to be pasted, and the dictation
    /// ends as ever. One running out of time is cancelled.
    @Test(arguments: [Polisher.Reply.failure, .text(" "), .never])
    fileprivate func aPolishThatFailsLeavesTheChunksCleanupsPasted(reply: Polisher.Reply) async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let polisher = Polisher(reply)
        let controller = controller(capture, backend, polisher: polisher, polishTimeout: .milliseconds(200))
        await start(controller, capture)

        await speak(capture, backend, seed: 51, 12, 12, 5)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1. Part 2."])
        #expect(polisher.calls.count == 1)
        if case .never = reply {
            await waitUntil { polisher.wasCancelled }
            #expect(polisher.wasCancelled)
        }
    }

    /// A cancel while the polish runs ends the dictation: nothing is pasted, and the polish stops.
    @Test func aLongDictationCancelledWhileItIsPolishedPastesNothing() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let polisher = Polisher(.never)
        let controller = controller(capture, backend, polisher: polisher, polishTimeout: .seconds(60))
        await start(controller, capture)

        await speak(capture, backend, seed: 52, 12, 5)
        controller.finish()
        await waitUntil { polisher.calls.count == 1 }
        controller.cancel()
        await waitUntil { polisher.wasCancelled }

        #expect(polisher.wasCancelled)
        #expect(controller.phase == .idle)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
    }

    /// A polish that answers only after its dictation was cancelled, with the next one already
    /// listening, never pastes or ends that one.
    @Test func aPolishAnsweringAfterACancelNeverEndsTheNextDictation() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let polisher = Polisher(.held("Late."))
        let controller = controller(capture, backend, polisher: polisher, polishTimeout: .seconds(60))
        await start(controller, capture)

        await speak(capture, backend, seed: 53, 12, 5)
        controller.finish()
        await waitUntil { polisher.calls.count == 1 }
        controller.cancel()
        let pasted = pasted
        controller.start(context: context, canUseAI: true) { text in pasted.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 2 }
        polisher.answer()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(controller.phase == .listening)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
        controller.cancel()
    }

    /// One chunk left before a chunk that gave up already had its whole cleanup: it is not polished.
    /// Two or more are.
    @Test(arguments: [1, 2])
    func onlyAPrefixOfTwoChunksOrMoreIsPolished(refusedChunk: Int) async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, _ in index == refusedChunk ? .refused : .part }
        let polisher = Polisher()
        let controller = controller(capture, backend, polisher: polisher)
        await start(controller, capture)

        await speak(capture, backend, seed: 54, 12, 12, 5)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        let expected = (0..<refusedChunk).map { "Part \($0)." }.joined(separator: " ")
        #expect(pasted.texts.withLock { $0 } == [expected])
        #expect(polisher.calls.map(\.text) == (refusedChunk > 1 ? [expected] : []))
    }

    @Test func aChunkCutWithNoPauseOverlapsTheNextAndTheirSharedWordsAreKeptOnce() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let replies = Mutex<[Int: String]>([
            0: "We should ship the release on Friday because the tests are gre",
            1: "release on Friday because the tests are green and the notes are ready.",
        ])
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { nil },
            dictionary: { .init(words: [], learnsWords: false) },
            emailBody: { _ in nil },
            corrections: nil,
            useWords: { _ in },
            transcribe: { flac, _, _, cleanup in
                let index = (try await backend.transcribe(flac, cleanup: cleanup)).text == "raw 0" ? 0 : 1
                return DictationTranscription(text: replies.withLock { $0[index] ?? "" }, cleanedText: nil)
            },
            warmUp: {},
            speechDetector: { onSpeech, _ in LoudnessSpeechDetector(onSpeech: onSpeech) }
        )
        await start(controller, capture)

        var random = Audio.Random(seed: 2)
        capture.feed(Audio.speech(130, &random))
        await waitUntil { backend.sent == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 2)
        #expect(pasted.texts.withLock { $0 } == ["We should ship the release on Friday because the tests are green and the notes are ready."])
    }

    /// A long silence (the user away) cuts chunks the model hears nothing in; the chunk after them
    /// overlaps an empty one, not the speech before the silence, so it is joined whole and no word
    /// on either side of the silence is lost however the two texts read.
    @Test func theWordsOnBothSidesOfALongSilenceAreAllPasted() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let replies = [
            "We should meet next week to talk about the budget. I think that one of the main points is the travel cost and the hotel.",
            "Okay, back again. I think that one of the main points we missed is staffing, so let us add it.",
        ]
        let controller = DictationController(
            capture: capture,
            requestMicrophoneAccess: { true },
            isOnline: { true },
            isOptedOutOfAI: { false },
            dictationLanguage: { nil },
            dictionary: { .init(words: [], learnsWords: false) },
            emailBody: { _ in nil },
            corrections: nil,
            useWords: { _ in },
            transcribe: { flac, _, _, cleanup in
                let index = Int((try await backend.transcribe(flac, cleanup: cleanup)).text.dropFirst("raw ".count)) ?? 0
                let reply = index == 0 ? replies[0] : index == 3 ? replies[1] : ""
                return DictationTranscription(text: reply, cleanedText: reply)
            },
            warmUp: {},
            speechDetector: { onSpeech, _ in LoudnessSpeechDetector(onSpeech: onSpeech) }
        )
        await start(controller, capture)

        var random = Audio.Random(seed: 20)
        capture.feed(Audio.speech(12, &random) + Audio.room(1.5, &random) + Audio.room(240, &random) + Audio.speech(5, &random))
        await waitUntil { backend.sent == 3 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 4)
        #expect(pasted.texts.withLock { $0 } == [replies.joined(separator: " ")])
    }

    /// Every chunk goes with the dictation's language and its dictionary's words, as one recording
    /// does: a long dictation in another language is not heard as English.
    @Test func everyChunkGoesWithTheDictationsLanguageAndWords() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend, language: "de", words: ["Zyxwordx"])
        await start(controller, capture)

        await speak(capture, backend, seed: 21, 12, 4)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 2)
        #expect(backend.languages == ["de", "de"])
        #expect(backend.vocabularies.allSatisfy { $0.contains("Zyxwordx") })
        #expect(backend.vocabularies.count == 2)
    }

    /// Every chunk goes with the context's terms, as one recording does (ADR-IOS-086).
    @Test func everyChunkGoesWithTheContextsTerms() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend, emailBody: { _ in "We met the team at Brevalle Labs yesterday." })
        let pasted = pasted
        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "Me: hi\n» ‸", emailId: "email-1"), canUseAI: true) { text in pasted.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }

        await speak(capture, backend, seed: 43, 12, 4)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.vocabularies.count == 2)
        #expect(backend.vocabularies.allSatisfy { $0.contains("Brevalle Labs") })
    }

    /// A long dictation marks what its chunks heard as used, for the dictionary's learned words, as
    /// one recording does (ADR-IOS-086).
    @Test func aLongDictationMarksWhatItHeardAsUsed() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let used = Mutex<[[String]]>([])
        let controller = controller(capture, backend, useWords: { texts in used.withLock { $0.append(texts) } })
        await start(controller, capture)

        await speak(capture, backend, seed: 44, 12, 4)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
        #expect(used.withLock { $0 } == [["raw 0", "Part 0.", "raw 1", "Part 1."]])
    }

    /// The last audio, delivered as the microphone stops, can complete a pause and cut a chunk whose
    /// task is queued behind the release: the release takes it up, so its words are pasted too.
    @Test func aChunkCutAsTheMicrophoneStopsIsPasted() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 45, 12, 12)
        var random = Audio.Random(seed: 46)
        // A pause not yet a second long, completed by the audio delivered as the microphone stops.
        capture.feed(Audio.room(0.9, &random))
        capture.deliverOnStop(Audio.room(0.2, &random))
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 3)
        // The backend numbers parts as their requests arrive, and the chunk cut as the microphone
        // stops can be sent after the last one: every part is pasted, each once.
        let texts = pasted.texts.withLock { $0 }
        #expect(texts.count == 1)
        #expect((texts.first ?? "").components(separatedBy: ". ").map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.sorted() == ["Part 0", "Part 1", "Part 2"])
    }

    /// Speech much softer than the speech before it (the user leaning back, or speaking low) is
    /// still sent and pasted: no chunk is judged by its loudness alone (owner, 2026-10-03).
    @Test func aSoftStretchAfterLoudSpeechIsSentAndPastedWithTheRest() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        // 30 s close to the microphone, a pause, two minutes 28 dB softer (still well above the
        // room), a pause, and 12 s close again.
        var random = Audio.Random(seed: 22)
        capture.feed(Audio.speech(30, &random) + Audio.room(1.5, &random) + Audio.speech(120, &random, amplitude: 0.01) + Audio.room(1.5, &random) + Audio.speech(12, &random))
        await waitUntil { backend.sent >= 2 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        let sent = backend.sent
        #expect(sent >= 3)
        #expect(pasted.texts.withLock { $0 } == [(0..<sent).map { "Part \($0)." }.joined(separator: " ")])
    }

    /// A steady sound with no voice above its room is sent in every chunk, as one recording is:
    /// the model decides.
    @Test func aSteadySoundIsSentInEveryChunk() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        let rate = DictationConfig.recordingSampleRate
        let seconds = Double(DictationConfig.chunkMaxDuration.components.seconds) + 10
        capture.feed((0..<Int(seconds * rate)).map { Float(0.25 * sin(2 * Double.pi * 220 * Double($0) / rate)) })
        await waitUntil { backend.sent == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 2)
        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
    }

    /// Each chunk is raised to the same peak on its own (ADR-IOS-085's −3 dBFS amendment): a quiet
    /// stretch is not left quiet beside a loud one.
    @Test func eachChunkIsPeakNormalisedOnItsOwn() async throws {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        var random = Audio.Random(seed: 23)
        capture.feed(Audio.speech(12, &random, amplitude: 0.1) + Audio.room(1.5, &random))
        await waitUntil { backend.sent == 1 }
        capture.feed(Audio.speech(4, &random, amplitude: 0.4))
        controller.finish()
        await waitUntil { controller.phase == .idle }

        let chunks = backend.chunks
        #expect(chunks.count == 2)
        let target = Int((Double(Int16.max) * pow(10, DictationConfig.normalizedPeakDecibels / 20)).rounded())
        for flac in chunks {
            let pcm = try FLACTestDecoder.decode(flac).pcm
            let peak = pcm.withUnsafeBytes { $0.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) } }
            #expect(abs(peak - target) <= 1)
        }
    }

    /// Cancelled while a chunk waits to be tried again: no request is made after the cancel.
    @Test func noRequestIsMadeAfterACancelWhileAChunkWaitsToBeTriedAgain() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { _, _ in .serverError }
        let controller = controller(capture, backend, chunkRetryDelays: [.seconds(3_600)])
        await start(controller, capture)

        var random = Audio.Random(seed: 24)
        capture.feed(Audio.speech(12, &random) + Audio.room(1.5, &random) + Audio.speech(3, &random))
        await waitUntil { backend.requests == 1 && backend.inFlight == 0 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.requests == 1)
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(backend.requests == 1)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
    }

    /// Cancelled while the first chunk's upload is still prepared (the email's terms are read): it is
    /// never sent.
    @Test func noRequestIsMadeAfterACancelWhileTheChunksUploadIsPrepared() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let reading = Mutex(false)
        let controller = controller(capture, backend, emailBody: { _ in
            reading.withLock { $0 = true }
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        let pasted = pasted
        controller.start(context: DictationContext(windowTitle: "Chat", screenText: "Me: hi\n» ‸", emailId: "email-1"), canUseAI: true) { text in pasted.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 1 }

        var random = Audio.Random(seed: 25)
        capture.feed(Audio.speech(12, &random) + Audio.room(1.5, &random) + Audio.speech(1, &random))
        await waitUntil { reading.withLock { $0 } }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(backend.requests == 0)
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(600))

        #expect(backend.requests == 0)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
    }

    /// While the user is still dictating, a chunk that fails on the server's side, drops its
    /// connection, times out on the backend or is rate limited by the speech model is tried again,
    /// with no retry state shown: nobody waits for it yet.
    @Test func aChunkFailingWhileRecordingIsTriedAgainUntilItAnswers() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, attempt in
            guard index == 0 else { return .part }
            return [.serverError, .connectionLost, .gatewayTimeout, .speechModelRateLimited, .serverError][safe: attempt] ?? .part
        }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 3, 12, 5)
        await waitUntil { backend.attempts.first == 6 && backend.inFlight == 0 }
        #expect(backend.attempts == [6])
        #expect(!controller.isRetrying)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
    }

    /// At the release, a chunk still failing stops waiting and gets its last tries at once, as one
    /// recording does, with the retry state shown.
    @Test func atTheReleaseAChunkStillFailingGetsItsLastTriesWithTheRetryState() async {
        let capture = SpeakingCapture()
        let released = Mutex(false)
        let backend = ChunkBackend { index, _ in
            guard index == 0 else { return .part }
            return released.withLock { $0 } ? .part : .serverError
        }
        // A wait while recording far longer than the test: only the release ends it.
        let controller = controller(capture, backend, chunkRetryDelays: [.seconds(3_600)], retryDelays: [.milliseconds(200)], retryNoticeDelay: .milliseconds(1))
        await start(controller, capture)

        await speak(capture, backend, seed: 4, 12, 5)
        await waitUntil { backend.attempts.first == 1 && backend.inFlight == 0 }
        // Still failing at the release: the waiting chunk is tried at once, fails, and is retried
        // after `retryDelays` under the retry state.
        controller.finish()
        await waitUntil { controller.isRetrying }
        #expect(controller.isRetrying)
        await waitUntil { controller.showsRetryNote }
        #expect(controller.showsRetryNote)
        released.withLock { $0 = true }
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
        #expect(!controller.isRetrying)
        #expect(!controller.showsRetryNote)
    }

    /// Once every chunk has answered, nothing is retrying: the retry state and its note end before
    /// the polish, not after it (as TabMail Voice's).
    @Test func theRetryStateEndsOnceTheChunksAnswerNotAfterThePolish() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, attempt in index == 1 && attempt == 0 ? .serverError : .part }
        let polisher = Polisher(.never)
        let controller = controller(capture, backend, retryDelays: [.milliseconds(300)], retryNoticeDelay: .milliseconds(1), polisher: polisher, polishTimeout: .seconds(60))
        await start(controller, capture)

        await speak(capture, backend, seed: 52, 12, 5)
        controller.finish()
        await waitUntil { controller.showsRetryNote }
        #expect(controller.isRetrying)
        #expect(controller.showsRetryNote)
        await waitUntil { polisher.calls.count == 1 }

        #expect(polisher.calls.count == 1)
        #expect(!controller.isRetrying)
        #expect(!controller.showsRetryNote)
        controller.cancel()
        await waitUntil { polisher.wasCancelled }
    }

    /// Cancelled while a chunk waits for one of its last tries after the release: no request is made
    /// after it (decision 7).
    @Test func noRequestIsMadeAfterACancelWhileAChunkWaitsForALastTry() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { _, _ in .serverError }
        let controller = controller(capture, backend, retryDelays: [.seconds(3_600)])
        await start(controller, capture)

        var random = Audio.Random(seed: 47)
        capture.feed(Audio.speech(12, &random) + Audio.room(1.5, &random) + Audio.speech(3, &random))
        await waitUntil { backend.requests >= 1 }
        controller.finish()
        await waitUntil { controller.isRetrying && backend.inFlight == 0 }
        try? await Task.sleep(for: .milliseconds(100))
        let made = backend.requests
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(backend.requests == made)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
    }

    /// Cancelled with the first chunk's text in hand and a later one still running, and a new
    /// dictation started at once: the old one's release ends without touching the new one, and its
    /// text is never pasted (an older action never overrides a newer one).
    @Test func aCancelledLongDictationNeverEndsTheNextOne() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, _ in index == 0 ? .part : .never }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 48, 12, 5)
        await waitUntil { backend.attempts.first == 1 && backend.inFlight == 0 }
        controller.finish()
        await waitUntil { backend.inFlight == 1 }
        controller.cancel()
        let pasted = pasted
        controller.start(context: context, canUseAI: true) { text in pasted.texts.withLock { $0.append(text) } }
        await waitUntil { capture.starts == 2 }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(controller.phase != .idle)
        #expect(capture.isRunning)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
        controller.cancel()
    }

    /// Only the chunks before the first that gave up are pasted (owner, 2026-10-03: "paste only the
    /// up to successful part"): the ones after it are not, even when they answered.
    @Test func onlyTheChunksBeforeTheFirstThatGaveUpArePasted() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, _ in index == 2 ? .refused : .part }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 5, 12, 12, 12, 5)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
        await waitUntil { backend.inFlight == 0 }
        #expect(backend.inFlight == 0)
    }

    /// After the release, a chunk whose last tries all fail gives up too: what came before it is
    /// pasted, and the requests after it are cancelled.
    @Test func aChunkWhoseLastTriesFailEndsTheTextThereAndLaterRequestsStop() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, _ in
            switch index {
            case 1: .serverError
            case 2: .never
            default: .part
            }
        }
        // Chunk 1 waits out the recording; chunk 2 never answers.
        let controller = controller(capture, backend, chunkRetryDelays: [.seconds(3_600)])
        await start(controller, capture)

        await speak(capture, backend, seed: 6, 12, 12, 12, 5)
        await waitUntil { backend.sent == 3 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0."])
        // Chunk 1: the try that failed while recording, one at the release and one per retry delay.
        #expect(backend.attempts.dropFirst().first == 4)
        await waitUntil { backend.inFlight == 0 }
        #expect(backend.inFlight == 0)
    }

    /// The last chunk is sent at the release, so the backend's own timeout on it, or the speech
    /// model's rate limit outlasting the backend's retries, comes after the release: it is tried
    /// again, as while recording (owner, 2026-10-03: "we should not lose the end").
    @Test(arguments: [false, true])
    func theLastChunkFailingOnTheBackendAfterTheReleaseIsTriedAgainAndTheEndIsPasted(rateLimited: Bool) async {
        let capture = SpeakingCapture()
        let failure: ChunkBackend.Reply = rateLimited ? .speechModelRateLimited : .gatewayTimeout
        let backend = ChunkBackend { index, attempt in index == 1 && attempt < 2 ? failure : .part }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 10, 12, 4)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
        #expect(backend.attempts == [1, 3])
    }

    /// While the user dictates, a refused chunk, or one over this account's own rate limit, gives up
    /// at once: only the server's side failing is tried again.
    @Test(arguments: [false, true])
    func aChunkRefusedWhileRecordingIsNotTriedAgain(rateLimited: Bool) async {
        let capture = SpeakingCapture()
        let failure: ChunkBackend.Reply = rateLimited ? .accountRateLimited : .refused
        let backend = ChunkBackend { index, _ in index == 0 ? failure : .part }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 27, 12, 4)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.attempts.first == 1)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.attempts.first == 1)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
    }

    /// The provider's rate limits come in bursts of seconds: the last tries after the release span
    /// about a minute (owner, 2026-10-03: "we definitely need more retries … we should not lose the end").
    @Test func theLastTriesAfterTheReleaseOutlastABurstOfRateLimits() {
        let total = DictationConfig.transcriptionRetryDelays.reduce(Duration.zero, +)
        #expect(total >= .seconds(45))
        #expect(DictationConfig.transcriptionRetryDelays.count >= 6)
    }

    /// The first chunk giving up loses the dictation, as one recording's failure does: nothing is
    /// pasted, whatever came after.
    @Test func theFirstChunkGivingUpPastesNothing() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, _ in index == 0 ? .refused : .part }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 7, 12, 12, 5)
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(pasted.texts.withLock { $0 }.isEmpty)
        #expect(!capture.isRunning)
    }

    /// Cancelled while recording, or while the chunks are still transcribed: nothing is pasted, and
    /// every request stops.
    @Test(arguments: [false, true])
    func aCancelledLongDictationPastesNothingAndStopsItsRequests(afterRelease: Bool) async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend { _, _ in .never }
        let controller = controller(capture, backend)
        await start(controller, capture)

        await speak(capture, backend, seed: 8, 12, 12, 5)
        await waitUntil { backend.inFlight == 2 }
        if afterRelease {
            controller.finish()
            await waitUntil { backend.inFlight == 3 }
        }
        controller.cancel()
        await waitUntil { backend.inFlight == 0 }

        #expect(backend.inFlight == 0)
        #expect(controller.phase == .idle)
        #expect(pasted.texts.withLock { $0 }.isEmpty)
        #expect(!capture.isRunning)
    }

    /// The last chunk is the quiet after a pause: it is sent too, and the model decides.
    @Test func aLastChunkOfQuietAfterAPauseIsSentToo() async {
        let capture = SpeakingCapture()
        let backend = ChunkBackend()
        let controller = controller(capture, backend)
        await start(controller, capture)

        var random = Audio.Random(seed: 9)
        capture.feed(Audio.speech(12, &random) + Audio.room(5, &random))
        await waitUntil { backend.sent == 1 }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        #expect(backend.sent == 2)
        #expect(pasted.texts.withLock { $0 } == ["Part 0. Part 1."])
    }

    /// Seeded random long dictations against a backend that fails at random: the text is always the
    /// chunks' in order up to the first that gave up, nothing stays in flight, and the microphone
    /// is released.
    @Test(arguments: UInt32(1)...UInt32(8))
    func randomLongDictationsPasteThePrefixUpToTheFirstChunkThatGaveUp(seed: UInt32) async {
        var random = Audio.Random(seed: seed &* 7_919)
        let replies: [[ChunkBackend.Reply]] = (0..<12).map { _ in
            (0..<6).map { _ in
                switch random.next() {
                case ..<0.55: .part
                case ..<0.7: .serverError
                case ..<0.8: .connectionLost
                case ..<0.9: .gatewayTimeout
                default: .refused
                }
            }
        }
        let capture = SpeakingCapture()
        let backend = ChunkBackend { index, attempt in replies[safe: index]?[safe: attempt] ?? .part }
        let controller = controller(capture, backend, chunkRetryDelays: [.milliseconds(Int(random.next() * 5))])
        await start(controller, capture)

        let segments = 2 + Int(random.next() * 5)
        for index in 0..<segments {
            let isLast = index == segments - 1
            let pause = 1.2 + random.next()
            capture.feed(Audio.speech(10.5 + random.next() * 4, &random) + (isLast ? [] : Audio.room(pause, &random)))
            if !isLast { await waitUntil { backend.sent == index + 1 } }
        }
        // Released at once or after some of the chunks answered.
        try? await Task.sleep(for: .milliseconds(Int(random.next() * 3) * 20))
        controller.finish()
        await waitUntil { controller.phase == .idle }
        await waitUntil { backend.inFlight == 0 }

        // The chunk's outcome: the tries before the release go on until anything but a server
        // error, a dropped connection or the backend's timeout; the order of the release decides
        // the rest, so the oracle reads which tries were made.
        let attempts = backend.attempts
        let gaveUp = attempts.indices.first { index in
            let last = replies[safe: index]?[safe: attempts[index] - 1] ?? .part
            return last != .part
        }
        let expected = (0..<(gaveUp ?? attempts.count)).map { "Part \($0)." }.joined(separator: " ")
        #expect(pasted.texts.withLock { $0 } == (expected.isEmpty ? [] : [expected]), "seed \(seed), attempts \(attempts)")
        #expect(backend.inFlight == 0)
        #expect(!capture.isRunning)
        #expect(controller.phase == .idle)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
