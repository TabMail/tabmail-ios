/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// A running on-device recognition: audio goes in, text comes out through the handler it was started
/// with. Tests substitute it.
protocol SpeechRecognition: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    /// Cancels the task and ends the audio.
    func finish()
}

/// Dictation for a user who opted out of AI (ADR-IOS-085 amendment 2026-10-29): Apple's
/// `SFSpeechRecognizer`, on this iPhone only. Nothing is sent to TabMail's backend, and
/// `requiresOnDeviceRecognition` keeps the audio from leaving the phone; where the language has no
/// on-device model, `isAvailable(locale:)` is false and the mic stays off. The speech-recognition
/// permission is asked at the first tap, never earlier.
///
/// The microphone and the audio session belong to `AudioCapturing` (the backend dictation's own
/// `MicrophoneCapture`): its serial queue orders a stop after the start it follows and releases the
/// session on every stop. This class only owns the recognition and the generation that tells a
/// superseded start, stop or callback from the current one: every callback checks its generation
/// before it changes anything, so an older recording can never touch a newer one.
@MainActor
@Observable
final class OnDeviceSpeechRecognizer {
    var isRecording = false
    private(set) var isStarting = false

    /// Starts a recognition for `locale`, or nil when the language has no on-device model. The handler
    /// gets each result's text and whether the recognition ended (final result or error).
    typealias RecognitionStarter = @Sendable (Locale, @escaping @Sendable (_ transcript: String?, _ ended: Bool) -> Void) -> (any SpeechRecognition)?

    private let capture: any AudioCapturing
    private let startRecognition: RecognitionStarter
    private let requestPermissions: @Sendable () async -> Bool
    private var recognition: (any SpeechRecognition)?
    /// Advances at every start and stop; main actor only.
    private var generation: UInt = 0

    init(
        capture: any AudioCapturing = MicrophoneCapture(),
        startRecognition: @escaping RecognitionStarter = OnDeviceSpeechRecognizer.startSystemRecognition,
        requestPermissions: @escaping @Sendable () async -> Bool = OnDeviceSpeechRecognizer.requestSystemPermissions
    ) {
        self.capture = capture
        self.startRecognition = startRecognition
        self.requestPermissions = requestPermissions
    }

    /// Whether this iPhone can recognise `locale` without the network.
    nonisolated static func isAvailable(locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// The recognition request: partial results, punctuation, and on-device only.
    nonisolated static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    private final class SystemRecognition: SpeechRecognition, @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?

        init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

        func finish() {
            task?.cancel()
            request.endAudio()
        }
    }

    nonisolated private static func startSystemRecognition(
        locale: Locale,
        handler: @escaping @Sendable (String?, Bool) -> Void
    ) -> (any SpeechRecognition)? {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return nil
        }
        let recognition = SystemRecognition(request: makeRequest())
        recognition.task = recognizer.recognitionTask(with: recognition.request) { result, error in
            handler(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
        return recognition
    }

    /// Asks for speech recognition and the microphone (each only when not yet decided).
    nonisolated private static func requestSystemPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
                c.resume(returning: SFSpeechRecognizer.authorizationStatus() == .authorized)
            } else {
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(locale: Locale, onTranscript: @escaping @MainActor @Sendable (String) -> Void) {
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Speech] start() entry: isRecording=\(isRecording) isStarting=\(isStarting)")
        }
        guard !isRecording, !isStarting else { return }

        isStarting = true
        generation &+= 1
        let current = generation
        Task {
            let granted = await requestPermissions()
            guard current == generation else { return }
            guard granted else {
                BackgroundSyncLogger.logDebug("[Speech] Permissions not granted")
                isStarting = false
                return
            }
            begin(generation: current, locale: locale, onTranscript: onTranscript)
        }
    }

    /// Ends the recording, or a start still waiting for a permission or the microphone. Safe to call
    /// at any time and more than once: the capture releases the audio session on every stop.
    func stop() {
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Speech] stop() entry: isRecording=\(isRecording) isStarting=\(isStarting)")
        }
        generation &+= 1
        isRecording = false
        isStarting = false
        capture.stop()
        recognition?.finish()
        recognition = nil
    }

    private func begin(generation current: UInt, locale: Locale, onTranscript: @escaping @MainActor @Sendable (String) -> Void) {
        let started = startRecognition(locale) { [weak self] transcript, ended in
            DispatchQueue.main.async {
                self?.received(generation: current, transcript: transcript, ended: ended, onTranscript: onTranscript)
            }
        }
        guard let started else {
            BackgroundSyncLogger.logDebug("[Speech] Speech recognizer not available")
            isStarting = false
            return
        }
        recognition = started
        capture.start(onBuffer: { started.append($0) }, completion: { [weak self] error in
            DispatchQueue.main.async { self?.captureStarted(generation: current, error: error) }
        })
    }

    /// A result from the recognition of `generation`; ignored once another start or stop has begun.
    private func received(generation current: UInt, transcript: String?, ended: Bool, onTranscript: @MainActor (String) -> Void) {
        guard current == generation else { return }
        if let transcript, isRecording { onTranscript(transcript) }
        if ended { stop() }
    }

    private func captureStarted(generation current: UInt, error: (any Error)?) {
        guard current == generation else { return }
        if let error {
            BackgroundSyncLogger.logDebug("[Speech] Failed to start recording: \(error)")
            stop()
            return
        }
        isRecording = true
        isStarting = false
    }
}
