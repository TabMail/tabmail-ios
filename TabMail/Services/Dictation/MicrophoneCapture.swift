/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Synchronization

/// What dictation needs from a microphone. Tests substitute one that records nothing.
protocol AudioCapturing: AnyObject, Sendable {
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        completion: @escaping @Sendable ((any Error)?) -> Void
    )
    func stop()
}

/// Streams buffers from the microphone while one dictation records.
///
/// All audio-session and engine work runs on one serial queue, never the main thread (iOS 26
/// requires `AVAudioSession` changes off the main actor, and starting the device is slow). The
/// queue also orders a `stop` after the `start` it follows, so a stop that races a start still
/// tears it down.
///
/// The audio session is active only between `start` and `stop`: every stop deactivates it.
/// While a recording-capable session stays active, iOS mutes haptics process-wide and other
/// apps' audio stays interrupted (iOS memory 086), so it never outlives a dictation.
final class MicrophoneCapture: AudioCapturing {
    enum CaptureError: Error {
        case noInputDevice
    }

    /// The running engine and whether this capture activated the audio session. Only the capture
    /// queue changes it; the Mutex makes that safe to state to the compiler.
    private struct Audio: @unchecked Sendable {
        var running: AVAudioEngine?
        var isSessionActive = false
    }

    private let queue = DispatchQueue(label: "ai.tabmail.dictation.microphone", qos: .userInitiated)
    private let handler = Mutex<(@Sendable (AVAudioPCMBuffer) -> Void)?>(nil)
    private let audio = Mutex(Audio())

    /// Starts the microphone. `onBuffer` runs on the audio render thread; `completion` on the
    /// capture queue, with the error if the microphone couldn't start.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        handler.withLock { $0 = onBuffer }
        queue.async { [self] in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                self.audio.withLock { $0.isSessionActive = true }

                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw CaptureError.noInputDevice
                }
                input.installTap(onBus: 0, bufferSize: DictationConfig.audioTapBufferSize, format: format) { [weak self] buffer, _ in
                    self?.handler.withLock { $0 }?(buffer)
                }
                engine.prepare()
                try engine.start()
                self.audio.withLock { $0.running = engine }
                completion(nil)
            } catch {
                self.handler.withLock { $0 = nil }
                self.teardownOnQueue()
                completion(error)
            }
        }
    }

    /// Stops the microphone, if running, and releases the audio session.
    func stop() {
        handler.withLock { $0 = nil }
        queue.async { self.teardownOnQueue() }
    }

    private func teardownOnQueue() {
        let (engine, wasActive) = audio.withLock { audio in
            defer { audio = Audio() }
            return (audio.running, audio.isSessionActive)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        guard wasActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Busy if audio I/O hasn't fully stopped; the next start re-activates it regardless.
            BackgroundSyncLogger.logDebug("[Dictation] MicrophoneCapture: deactivating the audio session failed: \(error)")
        }
    }

    /// RMS loudness of a buffer in dBFS (`silenceDecibels` for digital silence).
    static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return DictationConfig.silenceDecibels }
        let count = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for index in 0..<count {
            sumOfSquares += samples[index] * samples[index]
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        guard rms > 0 else { return DictationConfig.silenceDecibels }
        return max(20 * log10(rms), DictationConfig.silenceDecibels)
    }

    /// Level (0…1) of a buffer's loudness on a fixed scale, for the recording's peak-level
    /// diagnostics (the waveform adapts instead: `LevelEnvelope`).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let quiet = DictationConfig.levelQuietDecibels
        return max(0, min(1, (decibels(of: buffer) - quiet) / (DictationConfig.levelLoudDecibels - quiet)))
    }
}
