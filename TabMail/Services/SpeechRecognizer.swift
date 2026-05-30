/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import Speech
@preconcurrency import AVFoundation
import Synchronization

@MainActor
@Observable
final class SpeechRecognizer {
    var isRecording = false
    private var isStarting = false

    // Mutex protects audio state accessed from both background queue (setup) and MainActor (stop).
    // Audio types aren't Sendable, so we wrap them in @unchecked Sendable struct + Mutex.
    // Generation counter detects stale completions from previous start/stop cycles —
    // prevents zombie recordings when stop() races with in-flight beginRecording().
    nonisolated private let _audioState = Mutex(AudioState())

    private struct AudioState: @unchecked Sendable {
        var audioEngine: AVAudioEngine?
        var recognitionTask: SFSpeechRecognitionTask?
        var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        var generation: UInt = 0
    }

    /// Pre-request both permissions so the first `start()` doesn't block on dialogs.
    nonisolated func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func start(onTranscript: @escaping @MainActor @Sendable (String) -> Void) {
        guard !isRecording, !isStarting else { return }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioApplication.shared.recordPermission

        if speechStatus == .notDetermined || micStatus == .undetermined {
            requestPermissions()
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                self.start(onTranscript: onTranscript)
            }
            return
        }

        guard speechStatus == .authorized, micStatus == .granted else {
            print("[Speech] Permissions not granted (speech: \(speechStatus.rawValue), mic: \(micStatus.rawValue))")
            return
        }

        isStarting = true
        let gen = _audioState.withLock { state in
            state.generation &+= 1
            return state.generation
        }
        beginRecording(generation: gen, onTranscript: onTranscript)
    }

    func stop() {
        // Extract resources from mutex quickly, update UI state immediately.
        // Heavy audio teardown (engine.stop, removeTap) runs off main thread
        // to prevent blocking keyboard animation on dictation→keyboard switch.
        let resources = _audioState.withLock { state -> (AVAudioEngine?, SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?) in
            state.generation &+= 1  // Invalidate any in-flight beginRecording
            let engine = state.audioEngine
            let task = state.recognitionTask
            let request = state.recognitionRequest
            state.audioEngine = nil
            state.recognitionTask = nil
            state.recognitionRequest = nil
            return (engine, task, request)
        }
        isRecording = false
        isStarting = false

        let (engine, task, request) = resources
        if engine != nil || task != nil || request != nil {
            DispatchQueue.global(qos: .userInitiated).async {
                task?.cancel()
                request?.endAudio()
                if let engine {
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                }
            }
        }
    }

    /// Audio setup runs on a background queue (iOS 26 AVAudioSession requirement).
    /// All property writes go through DispatchQueue.main.async to stay on @MainActor.
    /// `generation` tracks the start/stop cycle — if stop() was called during setup,
    /// the generation will have advanced and we tear down instead of committing.
    private func beginRecording(generation: UInt, onTranscript: @escaping @MainActor @Sendable (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recognizer = SFSpeechRecognizer(locale: Locale.current)
            guard let recognizer, recognizer.isAvailable else {
                print("[Speech] Speech recognizer not available")
                DispatchQueue.main.async { [weak self] in self?.isStarting = false }
                return
            }

            guard AVAudioSession.sharedInstance().isInputAvailable else {
                print("[Speech] No audio input available")
                DispatchQueue.main.async { [weak self] in self?.isStarting = false }
                return
            }

            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

                let engine = AVAudioEngine()
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.addsPunctuation = true

                let inputNode = engine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                    print("[Speech] No valid audio input format available")
                    DispatchQueue.main.async { [weak self] in self?.isStarting = false }
                    return
                }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    let transcript = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal ?? false
                    let hasError = error != nil
                    DispatchQueue.main.async { [weak self] in
                        // Only forward transcripts while still recording — cancel() can fire
                        // a stale/empty callback after stop() set isRecording=false.
                        if let transcript, self?.isRecording == true {
                            onTranscript(transcript)
                        }
                        if hasError || isFinal {
                            self?.stop()
                        }
                    }
                }

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                    request.append(buffer)
                }

                engine.prepare()
                try engine.start()

                // Atomically check generation before committing — if stop() was called
                // during setup, the generation will have advanced.
                guard let self else { return }
                let shouldCommit = self._audioState.withLock { state in
                    guard state.generation == generation else { return false }
                    state.audioEngine = engine
                    state.recognitionRequest = request
                    state.recognitionTask = task
                    return true
                }

                if !shouldCommit {
                    // Stale — stop() was called during setup. Tear down.
                    engine.stop()
                    inputNode.removeTap(onBus: 0)
                    task.cancel()
                    request.endAudio()
                    return
                }

                // isRecording is @Observable — must be set on MainActor.
                // Re-check generation to catch stop() between mutex release and dispatch.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let stillValid = self._audioState.withLock { $0.generation == generation }
                    if stillValid {
                        self.isRecording = true
                        self.isStarting = false
                    } else {
                        self.stop()
                    }
                }
            } catch {
                print("[Speech] Failed to start recording: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.stop()
                }
            }
        }
    }
}
