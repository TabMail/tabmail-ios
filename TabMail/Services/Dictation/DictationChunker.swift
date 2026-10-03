/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A part of a recording sent on its own (ADR-IOS-087): samples `start` to `end` (exclusive).
struct DictationChunkCut: Sendable, Equatable {
    /// Its place in the recording, from 0.
    let index: Int
    let start: Int
    let end: Int
    /// True when it starts inside the chunk before it: that chunk was cut with no pause to cut at,
    /// so both hold the same `chunkOverlapSpeech` of speech, which the join keeps once
    /// (`DictationChunkJoin`).
    let overlapped: Bool
}

/// Where a long recording is cut into chunks, as it is recorded (ADR-IOS-087; TabMail Voice's
/// `Chunker`, ADR-DESK-048, rule for rule). It reads the loudness of each `chunkFrameDuration` frame
/// against the recording's own levels, never a fixed one: the quiet end of its frames
/// (`chunkFloorPercentile`) is the room, the loud end (`chunkSpeechPercentile`) the voice, and a
/// frame below `chunkPauseLevel` of the way from one to the other is quiet; a run of quiet frames
/// shorter than `chunkSpeechGap` (between syllables and words) counts as speech, as louder frames no
/// longer than `chunkPauseBlip` inside a quiet stretch (the room's noise) count as quiet. On quiet
/// microphones speech stands only a few dB above the room, which only levels taken from the
/// recording itself can tell apart.
///
/// - **A pause:** once a chunk holds `chunkMinimumSpeech` of speech, it is cut in the middle of the
///   next `chunkPauseDuration` of quiet. No word crosses a pause, so nothing overlaps. Speech much
///   softer than what came before, with few frames at the room's level, can read as quiet: a cut
///   there may split a word or two (found in TabMail Voice's review, 2026-10-03; the chunk is still
///   sent).
/// - **No pause:** a chunk that reaches `chunkMaxDuration` is cut anyway, at the quietest
///   `chunkForcedCutWindow` of its last `chunkForcedCutSearch`, and the next chunk starts
///   `chunkOverlapSpeech` of speech earlier (at most `chunkMaxOverlap` earlier).
///
/// A recording never cut is one upload, as before chunking. Not thread-safe: `AudioRecorder` calls
/// it under its lock.
final class DictationChunker {
    /// Decibels of digital silence, and the histogram's range: −100…0 dB in `binsPerDecibel` steps.
    private static let silenceDecibels: Double = -100
    private static let binsPerDecibel: Double = 2
    private static let binCount = Int(-silenceDecibels * binsPerDecibel) + 1

    private let frameLength: Int
    private let pauseFrames: Int
    private let minimumSpeechFrames: Int
    private let maxSamples: Int
    private let overlapSpeechFrames: Int
    private let maxOverlapFrames: Int
    private let forcedSearchFrames: Int
    private let forcedWindowFrames: Int
    private let gapFrames: Int
    private let blipFrames: Int
    /// Each whole frame's loudness (dB), from the start of the recording.
    private var decibels: [Double] = []
    private var histogram = [Int](repeating: 0, count: DictationChunker.binCount)
    /// Samples of the frame not yet whole.
    private var pending: [Int16] = []
    /// The current chunk: its first sample, whether it overlaps the one before, and its speech frames.
    private var chunkStart = 0
    private var chunkOverlapped = false
    private var speechFrames = 0
    /// The quiet stretch the chunk ends on so far, with any blips inside it, and the louder frames
    /// since its last quiet one: a blip yet, or speech once longer than `chunkPauseBlip`.
    private var quietRun = 0
    private var loudRun = 0
    private var cuts = 0

    init(sampleRate: Double = DictationConfig.recordingSampleRate) {
        let frame = DictationConfig.chunkFrameDuration
        func frames(_ duration: Duration) -> Int { max(1, Int((duration / frame).rounded())) }
        frameLength = Int((sampleRate * Self.seconds(frame)).rounded())
        pending.reserveCapacity(frameLength)
        pauseFrames = frames(DictationConfig.chunkPauseDuration)
        minimumSpeechFrames = frames(DictationConfig.chunkMinimumSpeech)
        maxSamples = Int((sampleRate * Self.seconds(DictationConfig.chunkMaxDuration)).rounded())
        overlapSpeechFrames = frames(DictationConfig.chunkOverlapSpeech)
        maxOverlapFrames = frames(DictationConfig.chunkMaxOverlap)
        forcedSearchFrames = frames(DictationConfig.chunkForcedCutSearch)
        forcedWindowFrames = frames(DictationConfig.chunkForcedCutWindow)
        gapFrames = frames(DictationConfig.chunkSpeechGap)
        blipFrames = frames(DictationConfig.chunkPauseBlip)
    }

    /// Reads the next samples of the recording (16-bit, as captured, before any normalisation) and
    /// returns the chunks they complete, in order: usually none.
    func append(_ samples: UnsafeBufferPointer<Int16>) -> [DictationChunkCut] {
        var result: [DictationChunkCut] = []
        var offset = 0
        while offset < samples.count {
            let count = min(frameLength - pending.count, samples.count - offset)
            pending.append(contentsOf: samples[offset..<(offset + count)])
            offset += count
            guard pending.count == frameLength else { break }
            let loudness = Self.frameDecibels(pending)
            pending.removeAll(keepingCapacity: true)
            if let cut = frame(loudness) { result.append(cut) }
        }
        return result
    }

    /// The last chunk, from the last cut to `totalSamples`, the end of the recording; nil when the
    /// recording was never cut (one upload, as before chunking).
    func finish(totalSamples: Int) -> DictationChunkCut? {
        guard cuts > 0 else { return nil }
        // The frame not yet whole is part of the last chunk; its loudness is not needed.
        return DictationChunkCut(index: cuts, start: chunkStart, end: totalSamples, overlapped: chunkOverlapped)
    }

    /// Takes the next whole frame; returns the chunk it completes, if any.
    private func frame(_ loudness: Double) -> DictationChunkCut? {
        decibels.append(loudness)
        histogram[Self.bin(of: loudness)] += 1

        let quiet = loudness < pauseLevel()
        count(quiet: quiet)
        let frameEnd = decibels.count * frameLength
        if quiet, quietRun >= pauseFrames, speechFrames >= minimumSpeechFrames {
            // The middle of the pause so far: half its quiet ends this chunk, half starts the next.
            return cut(end: frameEnd - (pauseFrames / 2) * frameLength, nextStart: nil)
        }
        if frameEnd - chunkStart >= maxSamples { return forcedCut() }
        return nil
    }

    /// No pause came: the chunk ends at the quietest window of its last frames, and the next starts
    /// `chunkOverlapSpeech` of speech before that.
    private func forcedCut() -> DictationChunkCut {
        let frames = decibels.count
        let firstFrame = max((chunkStart + frameLength - 1) / frameLength, frames - forcedSearchFrames)
        var best = frames - forcedWindowFrames
        var bestPower = Double.infinity
        var start = firstFrame
        while start + forcedWindowFrames <= frames {
            var power = 0.0
            for frame in start..<(start + forcedWindowFrames) { power += pow(10, decibels[frame] / 10) }
            if power < bestPower {
                bestPower = power
                best = start
            }
            start += 1
        }
        let end = (best + forcedWindowFrames / 2) * frameLength
        // Back from the cut, over frames the current levels call speech, to `chunkOverlapSpeech` of
        // it, never past `chunkMaxOverlap` nor to the chunk's own start.
        let level = pauseLevel()
        let earliest = max(end / frameLength - maxOverlapFrames, chunkStart / frameLength + 1)
        var frame = end / frameLength
        var speech = 0
        var gap = 0
        while frame > earliest, speech < overlapSpeechFrames {
            frame -= 1
            if decibels[frame] < level {
                gap += 1
                continue
            }
            if gap < gapFrames { speech += gap }
            gap = 0
            speech += 1
        }
        return cut(end: end, nextStart: frame * frameLength)
    }

    /// Ends the current chunk at sample `end`; the next starts at `nextStart`, or at `end` when nil
    /// (no overlap).
    private func cut(end: Int, nextStart: Int?) -> DictationChunkCut {
        let chunk = DictationChunkCut(index: cuts, start: chunkStart, end: end, overlapped: chunkOverlapped)
        cuts += 1
        chunkStart = nextStart ?? end
        chunkOverlapped = nextStart != nil
        // The next chunk's speech so far, from its start to now, and the quiet it ends on.
        let level = pauseLevel()
        speechFrames = 0
        quietRun = 0
        loudRun = 0
        for frame in (chunkStart / frameLength)..<decibels.count { count(quiet: decibels[frame] < level) }
        return chunk
    }

    /// Counts the next frame into the chunk's speech or the quiet it ends on.
    private func count(quiet: Bool) {
        if quiet {
            // A blip inside the quiet was the room's: the quiet goes on through it.
            quietRun += loudRun + 1
            loudRun = 0
            return
        }
        loudRun += 1
        if quietRun > 0, loudRun <= blipFrames { return }
        // Speech: a gap between syllables or words before it is part of the speech; a longer quiet is not.
        if quietRun < gapFrames { speechFrames += quietRun }
        speechFrames += loudRun
        quietRun = 0
        loudRun = 0
    }

    /// The loudness below which a frame is quiet: `chunkPauseLevel` of the way from the recording's
    /// room level to its voice level. The voice level is taken over the frames at least
    /// `chunkMinimumRange` above the room only, so a long silence doesn't drag it down to the room's;
    /// with no such frame there is no voice yet, and every frame is quiet.
    private func pauseLevel() -> Double {
        guard let floor = percentile(DictationConfig.chunkFloorPercentile, fromBin: 0) else { return .infinity }
        guard let speech = percentile(DictationConfig.chunkSpeechPercentile, fromBin: Self.bin(of: floor + DictationConfig.chunkMinimumRange)) else {
            return .infinity
        }
        return floor + DictationConfig.chunkPauseLevel * (speech - floor)
    }

    /// The loudness `fraction` of the way up the frames from bin `fromBin`; nil when there are none.
    private func percentile(_ fraction: Double, fromBin: Int) -> Double? {
        let count = histogram[fromBin...].reduce(0, +)
        guard count > 0 else { return nil }
        let target = Int((fraction * Double(count - 1)).rounded(.down))
        var seen = 0
        for bin in fromBin..<Self.binCount {
            seen += histogram[bin]
            if seen > target { return Self.silenceDecibels + Double(bin) / Self.binsPerDecibel }
        }
        return nil
    }

    /// A frame's RMS loudness in dBFS, at least `silenceDecibels`.
    private static func frameDecibels(_ samples: [Int16]) -> Double {
        var sumOfSquares = 0.0
        for sample in samples { sumOfSquares += Double(sample) * Double(sample) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot() / 32_768
        return rms > 0 ? max(20 * log10(rms), silenceDecibels) : silenceDecibels
    }

    private static func bin(of loudness: Double) -> Int {
        min(binCount - 1, max(0, Int(((loudness - silenceDecibels) * binsPerDecibel).rounded())))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
