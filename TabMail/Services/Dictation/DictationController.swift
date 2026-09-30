/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import GRDB
import Observation

/// Drives one chat-pill dictation at a time: wait for speech → record → transcribe on the backend,
/// which cleans up the transcript with what was on screen in the same request → hand the text back
/// to be appended to the input field. The same flow as TabMail Voice's `DictationController`, started and finished by
/// the mic button instead of a held key, and recording only once speech is heard (a held key
/// already says someone is speaking; an auto-started mic doesn't).
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    /// True once speech is heard. Until then the dictation waits: nothing is recorded but the
    /// moment before speech (`speechPreRollDuration`), the recording cap hasn't started, and the
    /// waveform lies flat.
    private(set) var hasHeardSpeech = false
    /// The language this dictation is transcribed in, read once when it starts: a Settings change
    /// mid-dictation applies to the next one (`DictationLanguage`). Nil: none sent.
    private(set) var language: String?
    /// The transcription failed on the server's side and is being tried again: the field says so.
    private(set) var isRetrying = false

    /// Recording or transcribing: the microphone button stops (or waits for) this dictation.
    var isActive: Bool { phase == .listening || phase == .transcribing }

    /// The recording (FLAC), its language, the words to spell as given and the cleanup's variables →
    /// the transcript and its cleaned-up text.
    typealias Transcribe = @Sendable (Data, String?, [String], [String: String]) async throws -> DictationTranscription
    /// Warms the backend for the transcription to come (`BackendClient.warmUpDictation`).
    typealias WarmUp = @Sendable () async -> Void
    /// The plain-text body of an email (its `messageHeader.id`), for terms; nil without one.
    typealias EmailBody = @Sendable (String) async -> String?
    /// A speech detector for one dictation, given what to call when it hears speech and when it
    /// can't run.
    typealias MakeSpeechDetector = @MainActor (
        _ onSpeech: @escaping @Sendable () -> Void,
        _ onFailure: @escaping @Sendable (any Error) -> Void
    ) -> any SpeechDetecting

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let requestMicrophoneAccess: @MainActor () async -> Bool
    @ObservationIgnored private let isOnline: @MainActor () -> Bool
    @ObservationIgnored private let isOptedOutOfAI: @MainActor () -> Bool
    @ObservationIgnored private let dictationLanguage: @MainActor () -> String?
    @ObservationIgnored private let dictionary: @MainActor () -> DictationDictionary.Snapshot
    @ObservationIgnored private let emailBody: EmailBody
    @ObservationIgnored private let corrections: DictationCorrectionWatch?
    @ObservationIgnored private let transcribeAudio: Transcribe
    @ObservationIgnored private let warmUp: WarmUp
    @ObservationIgnored private let transcriptionRetryDelays: [Duration]
    @ObservationIgnored private let makeSpeechDetector: MakeSpeechDetector
    @ObservationIgnored private let maxRecordingDuration: Duration

    // Per-dictation state. `generation` invalidates callbacks from a superseded dictation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var envelope = LevelEnvelope()
    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var speechDetector: (any SpeechDetecting)?
    @ObservationIgnored private var context: DictationContext?
    @ObservationIgnored private var onText: (@MainActor (String) -> Void)?
    /// The dictionary at the start (ADR-IOS-086): its words go with the dictation, and it says
    /// whether the user's corrections of the text are learned.
    @ObservationIgnored private var dictionaryWords: [String] = []
    @ObservationIgnored private var learnsWords = false
    /// The field the text is appended to, read to learn the user's corrections.
    @ObservationIgnored private var readInput: (@MainActor () -> String)?
    /// Picks the terms of what the dictation is about while the user speaks.
    @ObservationIgnored private var termsTask: Task<[String], Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?

    init(
        capture: any AudioCapturing = MicrophoneCapture(),
        requestMicrophoneAccess: @escaping @MainActor () async -> Bool = DictationController.requestMicrophoneAccess,
        isOnline: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
        // Settings' "Opt Out of AI" (also set by declining AI consent), as every AI call reads it.
        isOptedOutOfAI: @escaping @MainActor () -> Bool = { AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey) },
        dictationLanguage: @escaping @MainActor () -> String? = { DictationLanguage.current() },
        dictionary: @escaping @MainActor () -> DictationDictionary.Snapshot = { DictationDictionary.shared.snapshot },
        emailBody: @escaping EmailBody = { await DictationController.storedEmailBody(headerId: $0) },
        corrections: DictationCorrectionWatch? = DictationCorrectionWatch { DictationDictionary.shared.learn($0) },
        transcribe: Transcribe? = nil,
        warmUp: WarmUp? = nil,
        transcriptionRetryDelays: [Duration] = DictationConfig.transcriptionRetryDelays,
        speechDetector: @escaping MakeSpeechDetector = { SoundClassifierSpeechDetector(onSpeech: $0, onFailure: $1) },
        maxRecordingDuration: Duration = DictationConfig.maxRecordingDuration
    ) {
        self.capture = capture
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.isOnline = isOnline
        self.isOptedOutOfAI = isOptedOutOfAI
        self.dictationLanguage = dictationLanguage
        self.dictionary = dictionary
        self.emailBody = emailBody
        self.corrections = corrections
        self.transcribeAudio = transcribe ?? Self.backendTranscription(AccountManager.shared.backendClient)
        self.warmUp = warmUp ?? Self.backendWarmUp(AccountManager.shared.backendClient)
        self.transcriptionRetryDelays = transcriptionRetryDelays
        self.makeSpeechDetector = speechDetector
        self.maxRecordingDuration = maxRecordingDuration
    }

    /// The transcription on the TabMail backend: the recording with its language, which picks the
    /// speech-to-text model (backend ADR-024), the words to spell as given (backend ADR-025), and the
    /// cleanup's variables, for the cleanup the backend runs in the same request (backend ADR-027).
    static func backendTranscription(_ client: BackendClient) -> Transcribe {
        { flac, language, vocabulary, cleanup in
            try await client.transcribeDictation(flac: flac, language: language, vocabulary: vocabulary, cleanup: cleanup)
        }
    }

    nonisolated static func backendWarmUp(_ client: BackendClient) -> WarmUp {
        { await client.warmUpDictation() }
    }

    /// Starts listening. `context` is what the user sees now (the cleanup reads it); `onText`
    /// receives the cleaned-up dictation. Needs AI access (`canUseAI`: a TabMail session and an
    /// active subscription, as the pill's input bar requires), AI not opted out, and a
    /// connection: the audio and the screen text go to the AI backend. `input` reads the field the
    /// text is appended to, to learn the user's corrections of it (ADR-IOS-086).
    func start(
        context: DictationContext, canUseAI: Bool, input: (@MainActor () -> String)? = nil,
        onText: @escaping @MainActor (String) -> Void
    ) {
        switch phase {
        case .idle: break
        case .listening, .transcribing: return
        }
        // Without AI access the pill shows sign-in or subscribe instead of the input bar: nothing
        // would show the recording, and the backend would refuse it. Opted out of AI, nothing may
        // be sent to the AI backend at all.
        guard canUseAI, !isOptedOutOfAI() else {
            BackgroundSyncLogger.logDebug("[Dictation] not started: no AI access or AI opted out")
            return
        }
        // The mic is off offline; an auto-start that races a lost connection does nothing.
        guard isOnline() else {
            BackgroundSyncLogger.logDebug("[Dictation] not started: offline")
            return
        }

        // The next dictation's text is not the last one's correction.
        corrections?.stop()
        generation += 1
        let current = generation
        self.context = context
        self.onText = onText
        let dictionary = dictionary()
        dictionaryWords = dictionary.words
        learnsWords = dictionary.learnsWords
        readInput = input
        termsTask = Self.pickTerms(context: context, excluding: dictionary.words, emailBody: emailBody)
        envelope = LevelEnvelope()
        level = 0
        hasHeardSpeech = false
        language = dictationLanguage()
        phase = .listening
        // Best effort, never waited for: the dictation goes on whatever it answers.
        let warmUp = warmUp
        Task { await warmUp() }
        startTask = Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestMicrophoneAccess()
            guard self.generation == current, !Task.isCancelled else { return }
            guard granted else {
                BackgroundSyncLogger.logDebug("[Dictation] microphone access not granted")
                self.fail()
                return
            }
            self.beginRecording(generation: current)
        }
        BackgroundSyncLogger.logDebug("[Dictation] listening (generation \(current), language \(language ?? "none"))")
    }

    /// The search index's key for the email `headerId`: the one the content stores write its body
    /// under (`MessageContentStore.capture`), which follows the content-key migration; never built
    /// from the header's id. Nil for an email or account no longer there.
    nonisolated static func contentKey(headerId: String, db: Database) throws -> ContentKey? {
        guard let header = try MessageHeader.fetchOne(db, key: headerId) else { return nil }
        return try MessageContentStore.capture(header, db: db)?.contentKey
    }

    /// The body of the email `headerId` as the search index holds it; nil when it isn't there (not
    /// indexed yet, or gone).
    nonisolated static func storedEmailBody(headerId: String) async -> String? {
        let key = try? await AppDatabase.rawPool.read { db in try contentKey(headerId: headerId, db: db) }
        guard let key = key ?? nil else { return nil }
        return try? await SearchIndex.shared.bodyText(contentKey: key)
    }

    /// The terms of what the dictation is about (`DictationContextTerms`): from the context, and
    /// the email's body when there is one, read on this device. Only the terms are sent.
    private static func pickTerms(context: DictationContext, excluding: [String], emailBody: @escaping EmailBody) -> Task<[String], Never> {
        Task.detached(priority: .userInitiated) {
            let body = if let emailId = context.emailId { await emailBody(emailId) } else { String?.none }
            let text = [context.termsText, body].compactMap { $0 }.joined(separator: "\n")
            return DictationContextTerms.terms(in: text, excluding: excluding, max: DictationConfig.contextTermsMax)
        }
    }

    /// The terms, if they are picked within `contextTermsWait`; else none.
    private func contextTerms() async -> [String] {
        guard let termsTask else { return [] }
        return (try? await withTimeout(seconds: DictationConfig.contextTermsWait) { await termsTask.value }) ?? []
    }

    private func beginRecording(generation current: Int) {
        let recorder = AudioRecorder(maxDuration: maxRecordingDuration)
        self.recorder = recorder
        let detector = makeSpeechDetector(
            { [weak self] in
                // Straight from the detector, so no audio arriving in the meantime is trimmed.
                let held = recorder.keepFromNow()
                Task { @MainActor [weak self] in self?.speechHeard(held: held, generation: current) }
            },
            { [weak self] error in
                Task { @MainActor [weak self] in self?.microphoneFailed(error, generation: current) }
            }
        )
        speechDetector = detector
        capture.start(
            onBuffer: { [weak self] buffer in
                detector.analyze(buffer)
                recorder.append(buffer)
                let decibels = MicrophoneCapture.decibels(of: buffer)
                Task { @MainActor [weak self] in self?.updateLevel(decibels: decibels, generation: current) }
            },
            completion: { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in self?.microphoneFailed(error, generation: current) }
            }
        )
    }

    /// Speech arrived: the recording runs from here, the moment before it included.
    private func speechHeard(held: Duration, generation current: Int) {
        guard generation == current, phase == .listening, !hasHeardSpeech else { return }
        hasHeardSpeech = true
        BackgroundSyncLogger.logDebug("[Dictation] recording from speech (\(held) before it kept)")
        // At the recording cap, stop and send what was said rather than silently dropping audio.
        // The audio held from before speech counts toward it.
        let cap = max(maxRecordingDuration - held, .zero)
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: cap)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            BackgroundSyncLogger.logDebug("[Dictation] max duration reached; finishing")
            self.finish()
        }
    }

    /// Stops listening and transcribes what was said.
    func finish() {
        guard phase == .listening else { return }
        guard recorder != nil else {
            // Still waiting for microphone access: nothing was recorded.
            discard()
            return
        }
        maxDurationTask?.cancel()

        // Keep the microphone open briefly after the tap so the last word isn't clipped.
        let current = generation
        let language = language
        phase = .transcribing
        level = 0
        transcriptionTask = Task { [weak self] in
            try? await Task.sleep(for: DictationConfig.releaseTailDuration)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            await self.completeRecording(language: language, generation: current)
        }
    }

    /// Discards the recording or the transcription in progress; nothing is appended.
    func cancel() {
        guard isActive else { return }
        BackgroundSyncLogger.logDebug("[Dictation] cancelled")
        discard()
    }

    private func microphoneFailed(_ error: any Error, generation current: Int) {
        guard generation == current else { return }
        BackgroundSyncLogger.logDebug("[Dictation] microphone start failed: \(error)")
        generation += 1
        fail()
    }

    private func completeRecording(language: String?, generation current: Int) async {
        capture.stop()
        guard let recorder else { return }
        if !hasHeardSpeech {
            // Stopped before speech was heard: a short word just before the tap may still be in
            // the classifier's last window. Nothing heard at all: nothing is sent.
            let heard = await speechDetector?.finish() ?? false
            guard generation == current, !Task.isCancelled else { return }
            guard heard else {
                BackgroundSyncLogger.logDebug("[Dictation] no speech heard; nothing sent")
                fail()
                return
            }
        }

        let recording: AudioRecorder.Recording
        do {
            recording = try recorder.finish()
        } catch {
            BackgroundSyncLogger.logDebug("[Dictation] recording failed: \(type(of: error))")
            fail()
            return
        }
        BackgroundSyncLogger.logDebug("[Dictation] recorded \(recording.duration)s, peak \(recording.peakLevel), truncated \(recording.truncated)")

        // No loudness gate: on quiet microphones speech sits only a few dB above the room noise,
        // so any level threshold rejects real speech. The speech classifier started the
        // recording; the model decides the words, and an empty transcript ends the dictation below.
        guard !recording.pcm.isEmpty else {
            fail()
            return
        }
        await transcribe(FLACEncoder.encode(pcm16Mono: recording.pcm, sampleRate: recording.sampleRate), language: language, generation: current)
    }

    private func transcribe(_ flac: Data, language: String?, generation current: Int) async {
        let words = dictionaryWords
        let terms = await contextTerms()
        guard generation == current, !Task.isCancelled else { return }
        let cleanup = DictationCleanup.variables(context: context ?? DictationContext(windowTitle: "", screenText: ""), dictionary: words)
        BackgroundSyncLogger.logDebug("[Dictation] uploading \(flac.count) bytes of FLAC, \(words.count) dictionary word(s), \(terms.count) term(s)")
        do {
            let transcription = try await transcribeRetrying(flac, language, words + terms, cleanup, generation: current)
            guard generation == current, !Task.isCancelled else { return }
            let transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            BackgroundSyncLogger.logDebug("[Dictation] transcript ready (\(transcript.count) chars)")
            guard !transcript.isEmpty else {
                fail()
                return
            }
            let text = DictationCleanup.pasted(transcript: transcript, cleanedText: transcription.cleanedText)
            let deliver = onText
            let input = learnsWords ? readInput : nil
            teardown()
            phase = .idle
            deliver?(text)
            if let input { corrections?.watch(pasted: text, field: input) }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[Dictation] transcription failed: \(error)")
            fail()
        }
    }

    /// Makes the transcription request, and makes it again after a server error (a 5xx other than
    /// the backend's own timeout: the speech model behind it was rate limited or failed) or a dropped
    /// connection, once after each of `transcriptionRetryDelays`, so the user need not say it again;
    /// `isRetrying` says so while it waits and tries, until a retry answers. Any other failure (signed out, over quota, a refused request, a timeout) fails at
    /// once. As TabMail Voice's `transcribeRetrying` (ADR-DESK-039).
    private func transcribeRetrying(
        _ flac: Data, _ language: String?, _ vocabulary: [String], _ cleanup: [String: String], generation current: Int
    ) async throws -> DictationTranscription {
        var retry = 0
        while true {
            do {
                // The note goes once a retry answers: `transcribe` tears down, resetting
                // `isRetrying`, with no suspension between.
                return try await transcribeAudio(flac, language, vocabulary, cleanup)
            } catch {
                guard retry < transcriptionRetryDelays.count, Self.isServerError(error), generation == current, !Task.isCancelled else {
                    throw error
                }
                let delay = transcriptionRetryDelays[retry]
                retry += 1
                BackgroundSyncLogger.logDebug("[Dictation] transcription failed (\(error)); retrying in \(delay)")
                isRetrying = true
                try await Task.sleep(for: delay)
            }
        }
    }

    /// The status the backend answers when the speech model did not answer in time.
    nonisolated private static let gatewayTimeoutStatus = 504

    /// A failure on the server's side, worth trying again: a 5xx, or a connection that dropped or
    /// could not be made. Not a timeout: the request may still be running on the server. Nor a 504,
    /// the backend's own timeout: it already waited for the speech model.
    nonisolated static func isServerError(_ error: any Error) -> Bool {
        if case .failed(let status) = error as? DictationError { return status >= 500 && status != gatewayTimeoutStatus }
        guard let error = error as? URLError else { return false }
        return error.code != .timedOut && error.code != .cancelled
    }

    private func updateLevel(decibels: Float, generation: Int) {
        guard generation == self.generation, phase == .listening else { return }
        // The device delivers digital silence while it starts: it says nothing about the room.
        guard decibels > DictationConfig.silenceDecibels else { return }
        // The room's noise still sets the envelope's floor, but the waveform stays flat until
        // speech is heard.
        let newLevel = envelope.level(forDecibels: decibels)
        guard hasHeardSpeech else { return }
        let rate = newLevel > level ? DictationConfig.levelAttack : DictationConfig.levelRelease
        level += (newLevel - level) * rate
    }

    private func discard() {
        generation += 1
        teardown()
        phase = .idle
    }

    private func teardown() {
        capture.stop()
        startTask?.cancel()
        startTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder = nil
        speechDetector = nil
        context = nil
        onText = nil
        readInput = nil
        termsTask?.cancel()
        termsTask = nil
        hasHeardSpeech = false
        isRetrying = false
        level = 0
    }

    /// A failed dictation ends quietly: nothing is appended and the input field comes back.
    private func fail() {
        teardown()
        phase = .idle
    }

    /// The input is being sent: its last correction is compared, and the watch ends.
    func inputSent(_ input: String) {
        corrections?.finish(field: input)
    }

    /// The pill is going away: nothing more is learned from its field.
    func stopLearning() {
        corrections?.stop()
    }

    /// The input field once a dictation is appended to its end, a space apart.
    nonisolated static func appending(_ dictation: String, to input: String) -> String {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? dictation : existing + " " + dictation
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }
}

/// A failed `POST /dictation/transcribe`.
enum DictationError: Error, Equatable {
    case unauthorized
    case subscriptionRequired
    case accountSetupRequired
    case accessDenied
    case rateLimited
    case recordingTooLong
    case failed(status: Int)
    case invalidResponse

    /// From an HTTP error status and the `error` code of its JSON body.
    init(status: Int, code: String?) {
        self = switch (status, code) {
        case (401, _): .unauthorized
        case (402, _): .subscriptionRequired
        case (403, "consent_required"): .accountSetupRequired
        case (403, _): .accessDenied
        case (429, _): .rateLimited
        case (400, "audio_too_large"): .recordingTooLong
        default: .failed(status: status)
        }
    }
}
