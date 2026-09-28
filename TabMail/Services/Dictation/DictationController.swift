/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import Observation

/// Drives one chat-pill dictation at a time: record → transcribe on the backend → clean up the
/// transcript with what was on screen → hand the text back to be appended to the input field.
/// The same flow as TabMail Voice's `DictationController`, started and finished by the mic
/// button instead of a held key.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    /// True once the microphone delivers audio; until then the pill shows its warm-up swirl.
    private(set) var isHearing = false
    /// The language this dictation is transcribed in, read once when it starts so the pill's badge
    /// and the request always agree (`DictationLanguage`). Nil: none sent, no badge.
    private(set) var language: String?

    /// Recording or transcribing: the microphone button stops (or waits for) this dictation.
    var isActive: Bool { phase == .listening || phase == .transcribing }

    /// The recording (WAV) and its language → the transcript.
    typealias Transcribe = @Sendable (Data, String?) async throws -> String

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let requestMicrophoneAccess: @MainActor () async -> Bool
    @ObservationIgnored private let isOnline: @MainActor () -> Bool
    @ObservationIgnored private let isOptedOutOfAI: @MainActor () -> Bool
    @ObservationIgnored private let dictationLanguage: @MainActor () -> String?
    @ObservationIgnored private let transcribeAudio: Transcribe
    @ObservationIgnored private let complete: DictationCleanup.Complete
    @ObservationIgnored private let cleanupTimeout: TimeInterval
    @ObservationIgnored private let maxRecordingDuration: Duration

    // Per-dictation state. `generation` invalidates callbacks from a superseded dictation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var envelope = LevelEnvelope()
    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var context: DictationContext?
    @ObservationIgnored private var onText: (@MainActor (String) -> Void)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var failureResetTask: Task<Void, Never>?

    init(
        capture: any AudioCapturing = MicrophoneCapture(),
        requestMicrophoneAccess: @escaping @MainActor () async -> Bool = DictationController.requestMicrophoneAccess,
        isOnline: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
        // Settings' "Opt Out of AI" (also set by declining AI consent), as every AI call reads it.
        isOptedOutOfAI: @escaping @MainActor () -> Bool = { AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey) },
        dictationLanguage: @escaping @MainActor () -> String? = { DictationLanguage.current() },
        transcribe: Transcribe? = nil,
        complete: DictationCleanup.Complete? = nil,
        cleanupTimeout: TimeInterval = DictationConfig.cleanupTimeout,
        maxRecordingDuration: Duration = DictationConfig.maxRecordingDuration
    ) {
        self.capture = capture
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.isOnline = isOnline
        self.isOptedOutOfAI = isOptedOutOfAI
        self.dictationLanguage = dictationLanguage
        self.transcribeAudio = transcribe ?? Self.backendTranscription(AccountManager.shared.backendClient)
        // Direct: a user waiting on their dictation doesn't queue behind background AI work.
        self.complete = complete ?? { try await AccountManager.shared.backendClient.sendCompletionsDirect($0) }
        self.cleanupTimeout = cleanupTimeout
        self.maxRecordingDuration = maxRecordingDuration
    }

    /// The transcription on the TabMail backend: the recording with its language, which picks the
    /// speech-to-text model (backend ADR-024).
    static func backendTranscription(_ client: BackendClient) -> Transcribe {
        { wav, language in try await client.transcribeDictation(wav: wav, language: language) }
    }

    /// Starts listening. `context` is what the user sees now (the cleanup reads it); `onText`
    /// receives the cleaned-up dictation. Needs AI access (`canUseAI`: a TabMail session and an
    /// active subscription, as the pill's input bar requires), AI not opted out, and a
    /// connection: the audio and the screen text go to the AI backend.
    func start(context: DictationContext, canUseAI: Bool, onText: @escaping @MainActor (String) -> Void) {
        switch phase {
        case .idle, .failed: break
        case .listening, .transcribing: return
        }
        // Without AI access the pill shows sign-in or subscribe instead of the input bar: nothing
        // would show the recording, and the backend would refuse it. Opted out of AI, nothing may
        // be sent to the AI backend at all.
        guard canUseAI, !isOptedOutOfAI() else {
            BackgroundSyncLogger.logDebug("[Dictation] not started: no AI access or AI opted out")
            return
        }
        guard isOnline() else {
            fail(Self.offlineMessage)
            return
        }

        failureResetTask?.cancel()
        generation += 1
        let current = generation
        self.context = context
        self.onText = onText
        envelope = LevelEnvelope()
        level = 0
        isHearing = false
        language = dictationLanguage()
        phase = .listening
        startTask = Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestMicrophoneAccess()
            guard self.generation == current, !Task.isCancelled else { return }
            guard granted else {
                BackgroundSyncLogger.logDebug("[Dictation] microphone access not granted")
                self.teardown()
                self.fail(Self.microphoneDeniedMessage)
                return
            }
            self.beginRecording(generation: current)
        }
        BackgroundSyncLogger.logDebug("[Dictation] listening (generation \(current), language \(language ?? "none"))")
    }

    private func beginRecording(generation current: Int) {
        let recorder = AudioRecorder(maxDuration: maxRecordingDuration)
        self.recorder = recorder
        capture.start(
            onBuffer: { [weak self] buffer in
                recorder.append(buffer)
                let decibels = MicrophoneCapture.decibels(of: buffer)
                Task { @MainActor [weak self] in self?.updateLevel(decibels: decibels, generation: current) }
            },
            completion: { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in self?.microphoneFailed(error, generation: current) }
            }
        )
        // At the recording cap, stop and send what was said rather than silently dropping audio.
        let cap = maxRecordingDuration
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
        teardown()
        fail(Self.microphoneFailedMessage)
    }

    private func completeRecording(language: String?, generation current: Int) async {
        capture.stop()
        guard let recorder else { return }

        let recording: AudioRecorder.Recording
        do {
            recording = try recorder.finish()
        } catch {
            BackgroundSyncLogger.logDebug("[Dictation] recording failed: \(type(of: error))")
            teardown()
            fail(Self.recordingFailedMessage)
            return
        }
        BackgroundSyncLogger.logDebug("[Dictation] recorded \(recording.duration)s, peak \(recording.peakLevel), truncated \(recording.truncated)")

        // No loudness gate: on quiet microphones speech sits only a few dB above the room noise,
        // so any level threshold rejects real speech. The model decides; an empty transcript is
        // reported below.
        guard !recording.pcm.isEmpty else {
            teardown()
            fail(Self.nothingHeardMessage)
            return
        }
        await transcribe(WAVEncoder.encode(pcm16Mono: recording.pcm, sampleRate: recording.sampleRate), language: language, generation: current)
    }

    private func transcribe(_ wav: Data, language: String?, generation current: Int) async {
        BackgroundSyncLogger.logDebug("[Dictation] uploading \(wav.count) bytes")
        do {
            let transcript = try await transcribeAudio(wav, language).trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == current, !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[Dictation] transcript ready (\(transcript.count) chars)")
            guard !transcript.isEmpty else {
                teardown()
                fail(Self.nothingHeardMessage)
                return
            }
            let text = await DictationCleanup.cleanUp(
                transcript, context: context ?? DictationContext(windowTitle: "", screenText: ""),
                complete: complete, timeout: cleanupTimeout
            )
            guard generation == current, !Task.isCancelled else { return }
            let deliver = onText
            teardown()
            phase = .idle
            deliver?(text)
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[Dictation] transcription failed: \(error)")
            teardown()
            fail(Self.message(for: error))
        }
    }

    private func updateLevel(decibels: Float, generation: Int) {
        guard generation == self.generation, phase == .listening else { return }
        // The device delivers digital silence while it starts; the waveform appears with the
        // first real signal.
        if !isHearing, decibels > DictationConfig.silenceDecibels { isHearing = true }
        guard isHearing else { return }
        let newLevel = envelope.level(forDecibels: decibels)
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
        context = nil
        onText = nil
        isHearing = false
        level = 0
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        failureResetTask?.cancel()
        failureResetTask = Task { [weak self] in
            try? await Task.sleep(for: DictationConfig.errorDisplayDuration)
            guard !Task.isCancelled, let self, case .failed = self.phase else { return }
            self.phase = .idle
        }
    }

    /// The input field once a dictation is appended to its end, a space apart.
    nonisolated static func appending(_ dictation: String, to input: String) -> String {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? dictation : existing + " " + dictation
    }

    // MARK: Messages (one or two lines of the pill)

    nonisolated static let nothingHeardMessage = "Didn't catch that. Try again."
    nonisolated static let offlineMessage = "Dictation needs an internet connection."
    nonisolated static let microphoneDeniedMessage = "Allow microphone access in Settings to dictate."
    nonisolated static let microphoneFailedMessage = "Couldn't start the microphone."
    nonisolated static let recordingFailedMessage = "Couldn't record audio."
    nonisolated static let failedMessage = "Dictation failed. Please try again."

    nonisolated static func message(for error: any Error) -> String {
        if let error = error as? DictationError, let description = error.errorDescription { return description }
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            return offlineMessage
        }
        return failedMessage
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

/// A failed `POST /dictation/transcribe`, with the message the pill shows for it.
enum DictationError: LocalizedError, Equatable {
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

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your TabMail session has ended. Sign in again."
        case .subscriptionRequired: "Dictation needs an active TabMail subscription."
        case .accountSetupRequired: "Finish setting up your TabMail account at tabmail.ai."
        case .accessDenied: "This account can't use this TabMail server."
        case .rateLimited: "Too many dictations right now. Try again in a moment."
        case .recordingTooLong: "That recording was too long to transcribe."
        case .failed: DictationController.failedMessage
        case .invalidResponse: "TabMail returned an unexpected response."
        }
    }
}
