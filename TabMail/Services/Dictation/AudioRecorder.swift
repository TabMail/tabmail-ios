/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import os

/// Accumulates one dictation as 16 kHz mono 16-bit PCM, ready to encode as FLAC and upload;
/// `finish` peak-normalises it (`normalizePeak`).
/// Until `keepFromNow` (speech heard), only the latest `preRoll` of audio is held. From then on a
/// long recording is cut into chunks as it goes (`DictationChunker`, ADR-IOS-087): each is handed out
/// by `takeChunks` (`onChunk` says one is waiting), and `finish` returns the last.
///
/// `append` is called on the audio render thread; all state is behind one lock, so appends are
/// serialised and `finish` sees every buffer appended before it.
final class AudioRecorder: Sendable {
    struct Recording: Sendable {
        /// Little-endian 16-bit mono PCM samples, peak-normalised (`normalizePeak`): the whole
        /// recording, or, when it was cut into chunks, the last chunk's (`lastChunk`).
        let pcm: Data
        let sampleRate: Double
        /// The gain `normalizePeak` applied (1 when none).
        let gain: Double
        /// Loudest buffer's level on the waveform's 0…1 scale, as captured (before `gain`).
        let peakLevel: Float
        /// When the microphone delivered its first buffer (nil if it never did).
        let firstBufferAt: ContinuousClock.Instant?
        /// True when recording hit `maxFrames` and later audio was dropped.
        let truncated: Bool
        /// The last chunk, from the last cut to the end, when the recording was cut into chunks
        /// (ADR-IOS-087); nil when it is one upload.
        let lastChunk: DictationChunkCut?

        var duration: TimeInterval {
            Double(pcm.count / MemoryLayout<Int16>.size) / sampleRate
        }
    }

    /// A chunk cut off a long recording: its samples as captured, not yet normalised.
    struct Chunk: Sendable {
        let cut: DictationChunkCut
        /// Little-endian 16-bit mono PCM samples.
        let pcm: Data
    }

    private struct State {
        var converter: AVAudioConverter?
        var pcm = Data()
        var peakLevel: Float = 0
        var firstBufferAt: ContinuousClock.Instant?
        var truncated = false
        /// `finish` was called: a buffer the microphone still delivers as it stops is not the
        /// dictation's, and must cut no chunk after the last.
        var finished = false
        var firstError: (any Error)?
        var isHoldingPreRoll = true
        /// Reads what is kept, from `keepFromNow` on; its sample indices are `pcm`'s.
        var chunker: DictationChunker
        /// Chunks cut and not yet taken (`takeChunks`), in order.
        var chunks: [Chunk] = []
    }

    enum RecorderError: Error {
        case cannotConvertAudio
    }

    let outputFormat: AVAudioFormat
    private let maxFrames: Int
    private let preRollFrames: Int
    private let state: OSAllocatedUnfairLock<State>
    /// Called, on the audio thread, when a chunk is cut and waiting in `takeChunks`.
    private let onChunk: (@Sendable () -> Void)?

    init(
        sampleRate: Double = DictationConfig.recordingSampleRate,
        maxDuration: Duration = DictationConfig.maxRecordingDuration,
        preRoll: Duration = DictationConfig.speechPreRollDuration,
        cutsAtPauses: Bool = DictationConfig.chunkCutsAtPauses,
        onChunk: (@Sendable () -> Void)? = nil
    ) {
        self.onChunk = onChunk
        state = OSAllocatedUnfairLock(uncheckedState: State(chunker: DictationChunker(cutsAtPauses: cutsAtPauses)))
        // Force-unwrap: a 16-bit integer mono format is always constructible.
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        maxFrames = Int(Double(maxDuration.components.seconds) * sampleRate)
        preRollFrames = min(Int(Double(preRoll.components.seconds) * sampleRate), maxFrames)
    }

    /// Speech was heard: from now on everything is kept (up to `maxDuration`), after the audio
    /// already held. Returns how much was held.
    @discardableResult
    func keepFromNow() -> Duration {
        let (held, cut) = state.withLockUnchecked { state in
            state.isHoldingPreRoll = false
            // The held audio is the start of what is kept: the chunker reads it first.
            let held = state.pcm
            let cut = held.withUnsafeBytes { Self.chunk($0.bindMemory(to: Int16.self), state: &state) }
            return (Duration.seconds(Double(state.pcm.count / MemoryLayout<Int16>.size) / outputFormat.sampleRate), cut)
        }
        if cut { onChunk?() }
        return held
    }

    /// The chunks cut since the last call, in order (ADR-IOS-087).
    func takeChunks() -> [Chunk] {
        state.withLockUnchecked { state in
            defer { state.chunks = [] }
            return state.chunks
        }
    }

    /// Converts and appends one captured buffer. Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let level = MicrophoneCapture.level(of: buffer)
        let now = ContinuousClock.now
        let cut = state.withLockUnchecked { state in
            guard !state.finished else { return false }
            if state.firstBufferAt == nil { state.firstBufferAt = now }
            guard state.firstError == nil, !state.truncated else { return false }
            state.peakLevel = max(state.peakLevel, level)
            do {
                let converted = try convert(buffer, state: &state)
                return appendSamples(of: converted, to: &state)
            } catch {
                BackgroundSyncLogger.logDebug("[Dictation] AudioRecorder: conversion failed: \(type(of: error))")
                state.firstError = error
                return false
            }
        }
        if cut { onChunk?() }
    }

    /// Everything recorded so far, peak-normalised. Throws the first conversion error, if one
    /// occurred.
    func finish() throws -> Recording {
        let (pcm, peakLevel, firstBufferAt, truncated, lastChunk) = try state.withLockUnchecked { state in
            state.finished = true
            if let error = state.firstError { throw error }
            let samples = state.pcm.count / MemoryLayout<Int16>.size
            let lastChunk = state.isHoldingPreRoll ? nil : state.chunker.finish(totalSamples: samples)
            let pcm = lastChunk.map { Self.samples($0.start..<$0.end, of: state.pcm) } ?? state.pcm
            return (pcm, state.peakLevel, state.firstBufferAt, state.truncated, lastChunk)
        }
        // Outside the lock: nothing is appended once finished.
        let normalized = Self.normalizePeak(pcm)
        return Recording(
            pcm: normalized.pcm,
            sampleRate: outputFormat.sampleRate,
            gain: normalized.gain,
            peakLevel: peakLevel,
            firstBufferAt: firstBufferAt,
            truncated: truncated,
            lastChunk: lastChunk
        )
    }

    /// The chunker reads `samples`, the next of the recording; the chunks it cuts wait in
    /// `state.chunks`. True when it cut any.
    private static func chunk(_ samples: UnsafeBufferPointer<Int16>, state: inout State) -> Bool {
        let cuts = state.chunker.append(samples)
        for cut in cuts {
            state.chunks.append(Chunk(cut: cut, pcm: Self.samples(cut.start..<cut.end, of: state.pcm)))
        }
        return !cuts.isEmpty
    }

    /// Samples `range` of 16-bit PCM, as a fresh zero-based Data.
    private static func samples(_ range: Range<Int>, of pcm: Data) -> Data {
        let size = MemoryLayout<Int16>.size
        return Data(pcm[(pcm.startIndex + range.lowerBound * size)..<(pcm.startIndex + range.upperBound * size)])
    }

    /// Scales 16-bit mono PCM so its loudest sample sits at `DictationConfig.normalizedPeakDecibels`,
    /// boosting by at most `DictationConfig.maxNormalizationGainDecibels` and never cutting (peak
    /// normalisation, one gain for the whole recording). As TabMail Voice's `normalizePeak`.
    static func normalizePeak(_ pcm: Data) -> (pcm: Data, gain: Double) {
        var samples = [Int16](repeating: 0, count: pcm.count / MemoryLayout<Int16>.size)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        guard peak > 0 else { return (pcm, 1) }
        let target = Double(Int16.max) * pow(10, DictationConfig.normalizedPeakDecibels / 20)
        let gain = min(target / Double(peak), pow(10, DictationConfig.maxNormalizationGainDecibels / 20))
        guard gain > 1 else { return (pcm, 1) }
        // No clamp needed: every scaled sample is at most the target.
        for index in samples.indices {
            samples[index] = Int16((Double(samples[index]) * gain).rounded())
        }
        return (samples.withUnsafeBytes { Data($0) }, gain)
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

    /// Appends the buffer's samples; true when they completed a chunk (`takeChunks`).
    private func appendSamples(of buffer: AVAudioPCMBuffer, to state: inout State) -> Bool {
        guard let samples = buffer.int16ChannelData?[0] else { return false }
        if state.isHoldingPreRoll {
            // Only the latest `preRoll` is held (never more than the cap). A fresh Data rather
            // than a slice: the recording's indices stay zero-based.
            state.pcm.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let held = preRollFrames * MemoryLayout<Int16>.size
            if state.pcm.count > held { state.pcm = Data(state.pcm.suffix(held)) }
            return false
        }
        let recordedFrames = state.pcm.count / MemoryLayout<Int16>.size
        let room = maxFrames - recordedFrames
        let frames = min(Int(buffer.frameLength), room)
        if frames < Int(buffer.frameLength) { state.truncated = true }
        guard frames > 0 else { return false }
        let kept = UnsafeBufferPointer(start: samples, count: frames)
        state.pcm.append(kept)
        return Self.chunk(kept, state: &state)
    }
}

/// The converter's input block runs synchronously inside `convert`; this box lets it hand over
/// exactly one buffer per call.
private final class SuppliedFlag: @unchecked Sendable {
    var value = false
}
