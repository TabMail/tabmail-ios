/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import os

/// Accumulates one dictation as 16 kHz mono 16-bit PCM, ready to wrap in a WAV and upload.
/// Until `keepFromNow` (speech heard), only the latest `preRoll` of audio is held.
///
/// `append` is called on the audio render thread; all state is behind one lock, so appends are
/// serialised and `finish` sees every buffer appended before it.
final class AudioRecorder: Sendable {
    struct Recording: Sendable {
        /// Little-endian 16-bit mono PCM samples.
        let pcm: Data
        let sampleRate: Double
        /// Loudest buffer's level on the waveform's 0…1 scale.
        let peakLevel: Float
        /// When the microphone delivered its first buffer (nil if it never did).
        let firstBufferAt: ContinuousClock.Instant?
        /// True when recording hit `maxFrames` and later audio was dropped.
        let truncated: Bool

        var duration: TimeInterval {
            Double(pcm.count / MemoryLayout<Int16>.size) / sampleRate
        }
    }

    private struct State {
        var converter: AVAudioConverter?
        var pcm = Data()
        var peakLevel: Float = 0
        var firstBufferAt: ContinuousClock.Instant?
        var truncated = false
        var firstError: (any Error)?
        var isHoldingPreRoll = true
    }

    enum RecorderError: Error {
        case cannotConvertAudio
    }

    let outputFormat: AVAudioFormat
    private let maxFrames: Int
    private let preRollFrames: Int
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(
        sampleRate: Double = DictationConfig.recordingSampleRate,
        maxDuration: Duration = DictationConfig.maxRecordingDuration,
        preRoll: Duration = DictationConfig.speechPreRollDuration
    ) {
        // Force-unwrap: a 16-bit integer mono format is always constructible.
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        maxFrames = Int(Double(maxDuration.components.seconds) * sampleRate)
        preRollFrames = min(Int(Double(preRoll.components.seconds) * sampleRate), maxFrames)
    }

    /// Speech was heard: from now on everything is kept (up to `maxDuration`), after the audio
    /// already held. Returns how much was held.
    @discardableResult
    func keepFromNow() -> Duration {
        state.withLockUnchecked { state in
            state.isHoldingPreRoll = false
            return .seconds(Double(state.pcm.count / MemoryLayout<Int16>.size) / outputFormat.sampleRate)
        }
    }

    /// Converts and appends one captured buffer. Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let level = MicrophoneCapture.level(of: buffer)
        let now = ContinuousClock.now
        state.withLockUnchecked { state in
            if state.firstBufferAt == nil { state.firstBufferAt = now }
            guard state.firstError == nil, !state.truncated else { return }
            state.peakLevel = max(state.peakLevel, level)
            do {
                let converted = try convert(buffer, state: &state)
                appendSamples(of: converted, to: &state)
            } catch {
                BackgroundSyncLogger.logDebug("[Dictation] AudioRecorder: conversion failed: \(type(of: error))")
                state.firstError = error
            }
        }
    }

    /// Everything recorded so far. Throws the first conversion error, if one occurred.
    func finish() throws -> Recording {
        try state.withLockUnchecked { state in
            if let error = state.firstError { throw error }
            return Recording(
                pcm: state.pcm,
                sampleRate: outputFormat.sampleRate,
                peakLevel: state.peakLevel,
                firstBufferAt: state.firstBufferAt,
                truncated: state.truncated
            )
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, state: inout State) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if state.converter == nil || state.converter?.inputFormat != inputFormat {
            guard let made = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw RecorderError.cannotConvertAudio
            }
            // Multi-channel interfaces: mix all channels down rather than keeping only the first.
            made.downmix = true
            state.converter = made
        }
        guard let converter = state.converter else { throw RecorderError.cannotConvertAudio }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecorderError.cannotConvertAudio
        }

        let supplied = SuppliedFlag()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? RecorderError.cannotConvertAudio
        }
        return output
    }

    private func appendSamples(of buffer: AVAudioPCMBuffer, to state: inout State) {
        guard let samples = buffer.int16ChannelData?[0] else { return }
        if state.isHoldingPreRoll {
            // Only the latest `preRoll` is held (never more than the cap). A fresh Data rather
            // than a slice: the recording's indices stay zero-based.
            state.pcm.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let held = preRollFrames * MemoryLayout<Int16>.size
            if state.pcm.count > held { state.pcm = Data(state.pcm.suffix(held)) }
            return
        }
        let recordedFrames = state.pcm.count / MemoryLayout<Int16>.size
        let room = maxFrames - recordedFrames
        let frames = min(Int(buffer.frameLength), room)
        if frames < Int(buffer.frameLength) { state.truncated = true }
        guard frames > 0 else { return }
        state.pcm.append(UnsafeBufferPointer(start: samples, count: frames))
    }
}

/// The converter's input block runs synchronously inside `convert`; this box lets it hand over
/// exactly one buffer per call.
private final class SuppliedFlag: @unchecked Sendable {
    var value = false
}
