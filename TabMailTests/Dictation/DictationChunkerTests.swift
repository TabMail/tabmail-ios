/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Ported from TabMail Voice's `Chunker` tests with the chunker itself (ADR-IOS-087). Pause cuts are
/// off as shipped (owner, 2026-10-07) and kept for a later look: the tests of that rule turn them on,
/// and the `asShipped…` tests run the chunker as the app builds it.
struct DictationChunkerTests {
    private typealias Audio = DictationTestAudio
    private let rate = DictationTestAudio.rate

    private func seconds(_ samples: Int) -> Double { Double(samples) / rate }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func speech(_ duration: Double, _ random: inout Audio.Random, amplitude: Float = 0.25) -> [Int16] {
        Audio.pcm16(Audio.speech(duration, &random, amplitude: amplitude))
    }

    private func room(_ duration: Double, _ random: inout Audio.Random) -> [Int16] {
        Audio.pcm16(Audio.room(duration, &random))
    }

    /// Feeds `audio` in the microphone's buffers, as the recorder does; returns every cut and the last.
    /// `cutsAtPauses` nil runs the chunker as shipped.
    private func chunk(_ audio: [Int16], step: Int = Int(DictationConfig.audioTapBufferSize), cutsAtPauses: Bool? = true) -> (cuts: [DictationChunkCut], last: DictationChunkCut?) {
        let chunker = cutsAtPauses.map { DictationChunker(cutsAtPauses: $0) } ?? DictationChunker()
        var cuts: [DictationChunkCut] = []
        audio.withUnsafeBufferPointer { all in
            for offset in stride(from: 0, to: all.count, by: step) {
                cuts += chunker.append(UnsafeBufferPointer(rebasing: all[offset..<min(offset + step, all.count)]))
            }
        }
        return (cuts, chunker.finish(totalSamples: audio.count))
    }

    /// What every cutting must hold: the chunks cover the recording in order from its first sample to
    /// its last, each starting where the one before ended unless it overlaps it (and then within
    /// `chunkMaxOverlap` of its end), each within `chunkMaxDuration`, so within what the backend
    /// transcribes at once.
    private func expectCovers(_ audio: [Int16], _ cuts: [DictationChunkCut], _ last: DictationChunkCut?) {
        guard let last else {
            #expect(cuts.isEmpty)
            return
        }
        let all = cuts + [last]
        #expect(all.map(\.index) == Array(all.indices))
        #expect(all.first?.start == 0)
        #expect(last.end == audio.count)
        for (index, cut) in all.enumerated() {
            #expect(cut.end > cut.start)
            #expect(seconds(cut.end - cut.start) <= seconds(DictationConfig.chunkMaxDuration))
            guard index > 0 else { continue }
            let before = all[index - 1]
            #expect(cut.start > before.start)
            if cut.overlapped {
                #expect(cut.start < before.end)
                #expect(seconds(before.end - cut.start) <= seconds(DictationConfig.chunkMaxOverlap) + 0.02)
            } else {
                #expect(cut.start == before.end)
            }
        }
    }

    @Test func aShortDictationIsNeverCut() {
        var random = Audio.Random(seed: 1)
        let audio = speech(6, &random) + room(2, &random) + speech(5, &random)
        let (cuts, last) = chunk(audio)
        #expect(cuts.isEmpty)
        #expect(last == nil)
    }

    @Test func cutsInTheMiddleOfAOneSecondPauseOnceAChunkHoldsTenSecondsOfSpeech() {
        var random = Audio.Random(seed: 2)
        let pauseStart = Int(12 * rate)
        let audio = speech(12, &random) + room(1.5, &random) + speech(5, &random)
        let (cuts, last) = chunk(audio)
        #expect(cuts.count == 1)
        guard cuts.count == 1 else { return }
        let cut = cuts[0]
        // Inside the pause: no word is split, and nothing overlaps.
        #expect(cut.end > pauseStart)
        #expect(cut.end < pauseStart + Int(1.5 * rate))
        #expect(!cut.overlapped)
        #expect(last == DictationChunkCut(index: 1, start: cut.end, end: audio.count, overlapped: false))
        expectCovers(audio, cuts, last)
    }

    @Test func aPauseShorterThanASecondOrBeforeTenSecondsOfSpeechIsNotCutAt() {
        var random = Audio.Random(seed: 3)
        // 0.7 s breaths, then a 2 s pause after only 6 s of speech, then 12 s of speech and a real pause.
        let audio = speech(4, &random) + room(0.7, &random) + speech(2, &random) + room(2, &random)
            + speech(12, &random) + room(1.5, &random) + speech(3, &random)
        let (cuts, last) = chunk(audio)
        #expect(cuts.count == 1)
        guard cuts.count == 1 else { return }
        let firstPause = (4 + 0.7 + 2) * rate
        #expect(Double(cuts[0].end) > firstPause + 2 * rate + 12 * rate)
        expectCovers(audio, cuts, last)
    }

    /// On a quiet microphone the room's own noise pokes over the quiet line a frame or two at a time
    /// all through a pause (the owner's recording, 2026-10-03, was never cut): such blips leave the
    /// pause going, and a louder stretch just past `chunkPauseBlip` ends it, as a syllable does.
    @Test(arguments: [true, false])
    func aPauseWithBlipsOfTheRoomInItIsCutAtOnlyWhileTheyAreShort(short: Bool) {
        var random = Audio.Random(seed: 12)
        let blip = seconds(DictationConfig.chunkPauseBlip + (short ? .zero : DictationConfig.chunkFrameDuration * 2))
        var audio = speech(12, &random)
        for _ in 0..<8 { audio += room(0.25, &random) + speech(blip, &random) }
        audio += room(0.25, &random) + speech(5, &random)
        let pauseStart = Int(12 * rate)
        let (cuts, last) = chunk(audio)
        if short {
            #expect(cuts.count == 1)
            guard cuts.count == 1 else { return }
            #expect(cuts[0].end > pauseStart)
            #expect(cuts[0].end < pauseStart + Int(2.5 * rate))
        } else {
            #expect(cuts.isEmpty)
        }
        expectCovers(audio, cuts, last)
    }

    /// The blips count toward the pause's second: a pause just over `chunkPauseDuration` in all,
    /// whose quiet frames alone fall short of it, is cut at (the owner's pauses were about 85% quiet
    /// frames).
    @Test func aPausesBlipsCountTowardItsSecond() {
        var random = Audio.Random(seed: 13)
        let blip = seconds(DictationConfig.chunkPauseBlip)
        var pause: [Int16] = []
        for _ in 0..<4 { pause += room(0.2, &random) + speech(blip, &random, amplitude: 0.9) }
        pause += room(0.1, &random)
        let pauseDuration = seconds(DictationConfig.chunkPauseDuration) * rate
        let quiet = Double(pause.count) - 4 * blip * rate
        #expect(Double(pause.count) > pauseDuration)
        #expect(quiet < pauseDuration)
        let pauseStart = Int(12 * rate)
        let audio = speech(12, &random) + pause + speech(5, &random)
        let (cuts, last) = chunk(audio)
        #expect(cuts.count == 1)
        guard cuts.count == 1 else { return }
        #expect(cuts[0].end > pauseStart)
        #expect(cuts[0].end < pauseStart + pause.count)
        expectCovers(audio, cuts, last)
    }

    /// With no pause at all, a chunk is cut at `chunkMaxDuration`, and the next starts about
    /// `chunkOverlapSpeech` of speech earlier, so the cut's words are heard whole in one of them.
    @Test func speechWithNoPauseIsCutAtTheMaximumLengthTheNextChunkOverlappingIt() throws {
        var random = Audio.Random(seed: 4)
        let audio = speech(130, &random)
        let (cuts, last) = chunk(audio)
        #expect(cuts.count == 1)
        guard cuts.count == 1 else { return }
        let cut = cuts[0]
        let next = try #require(last)
        #expect(seconds(cut.end) > seconds(DictationConfig.chunkMaxDuration - DictationConfig.chunkForcedCutSearch))
        #expect(seconds(cut.end) <= seconds(DictationConfig.chunkMaxDuration))
        #expect(next.overlapped)
        let overlap = seconds(cut.end - next.start)
        #expect(overlap >= seconds(DictationConfig.chunkOverlapSpeech))
        #expect(overlap <= seconds(DictationConfig.chunkMaxOverlap))
        expectCovers(audio, cuts, last)
    }

    /// A forced cut lands on the quietest moment near the end, a dip between syllables.
    @Test func aForcedCutLandsOnTheQuietestWindowOfTheChunksLastSeconds() {
        var random = Audio.Random(seed: 5)
        let dipAt = seconds(DictationConfig.chunkMaxDuration) - 2
        // A 0.4 s dip (shorter than a pause) two seconds before the maximum length.
        let audio = speech(dipAt, &random) + room(0.4, &random) + speech(20, &random)
        let (cuts, _) = chunk(audio)
        let end = seconds(cuts.first?.end ?? 0)
        #expect(end >= dipAt)
        #expect(end <= dipAt + 0.4)
    }

    /// A long silence (the user away) is still cut within the maximum length.
    @Test func aLongSilenceIsCutWithinTheMaximumLength() {
        var random = Audio.Random(seed: 6)
        let audio = speech(12, &random) + room(1.5, &random) + room(240, &random) + speech(5, &random)
        let (cuts, last) = chunk(audio)
        expectCovers(audio, cuts, last)
        #expect(cuts.count >= 3)
    }

    @Test func aRecordingOfNothingButTheRoomIsCutWithinTheMaximumLengthToo() {
        var random = Audio.Random(seed: 7)
        let audio = room(250, &random)
        let (cuts, last) = chunk(audio)
        #expect(!cuts.isEmpty)
        expectCovers(audio, cuts, last)
    }

    /// The same audio cuts the same way however the microphone splits it into buffers.
    @Test func cutsTheSameWhateverTheSizeOfTheBuffersFed() {
        var random = Audio.Random(seed: 8)
        let audio = speech(12, &random) + room(1.5, &random) + speech(30, &random) + room(1.2, &random)
            + speech(11, &random) + room(1.1, &random) + speech(2, &random)
        let byBuffers = chunk(audio)
        let bySamples = chunk(audio, step: 7)
        let whole = chunk(audio, step: audio.count)
        #expect(bySamples.cuts == byBuffers.cuts && bySamples.last == byBuffers.last)
        #expect(whole.cuts == byBuffers.cuts && whole.last == byBuffers.last)
        #expect(byBuffers.cuts.count == 3)
    }

    /// Seeded random dictations up to ten minutes, of speech, breaths, pauses and long silences at
    /// random lengths and loudness: the chunks always cover the recording within the maximum length.
    @Test(arguments: UInt32(100)..<UInt32(108))
    func randomDictationsAreAlwaysCoveredWithinTheMaximumLength(seed: UInt32) {
        let audio = randomDictation(seed: seed)
        let (cuts, last) = chunk(audio)
        expectCovers(audio, cuts, last)
    }

    /// A seeded random dictation of one to ten minutes: speech, breaths, pauses and long silences at
    /// random lengths and loudness.
    private func randomDictation(seed: UInt32) -> [Int16] {
        var random = Audio.Random(seed: seed)
        var audio: [Int16] = []
        let target = (60 + random.next() * 540) * rate
        while Double(audio.count) < target {
            let kind = random.next()
            if kind < 0.6 {
                let length = 1 + random.next() * (random.next() < 0.1 ? 140 : 15)
                let amplitude = Float(0.05 + random.next() * 0.3)
                audio += speech(length, &random, amplitude: amplitude)
            } else if kind < 0.85 {
                audio += room(0.2 + random.next() * 0.8, &random)
            } else {
                audio += room(1 + random.next() * (random.next() < 0.2 ? 60 : 3), &random)
            }
        }
        return audio
    }

    // MARK: As shipped: cut only at the maximum length (owner, 2026-10-07)

    /// People pause between words and sentences: a pause after ten seconds of speech is not cut at.
    @Test func asShippedADictationWithPausesAfterTenSecondsOfSpeechIsNeverCutShortOfTheMaximumLength() {
        var random = Audio.Random(seed: 20)
        let audio = speech(12, &random) + room(1.5, &random) + speech(30, &random) + room(1.2, &random)
            + speech(11, &random) + room(1.1, &random) + speech(2, &random)
        let (cuts, last) = chunk(audio, cutsAtPauses: nil)
        #expect(cuts.isEmpty)
        #expect(last == nil)
    }

    @Test func asShippedALongDictationWithPausesIsCutOnlyAtTheMaximumLengthEachChunkOverlappingTheOneBefore() {
        var random = Audio.Random(seed: 21)
        var audio: [Int16] = []
        for _ in 0..<18 { audio += speech(12, &random) + room(1.5, &random) }
        let (cuts, last) = chunk(audio, cutsAtPauses: nil)
        #expect(cuts.count > 1)
        for cut in cuts {
            #expect(seconds(cut.end - cut.start) > seconds(DictationConfig.chunkMaxDuration - DictationConfig.chunkForcedCutSearch))
        }
        #expect((cuts + [last]).dropFirst().allSatisfy { $0?.overlapped == true })
        expectCovers(audio, cuts, last)
    }

    @Test(arguments: UInt32(200)..<UInt32(204))
    func asShippedRandomDictationsAreCutOnlyAtTheMaximumLength(seed: UInt32) {
        let audio = randomDictation(seed: seed)
        let (cuts, last) = chunk(audio, cutsAtPauses: nil)
        expectCovers(audio, cuts, last)
        #expect((cuts + [last]).dropFirst().allSatisfy { $0?.overlapped == true })
    }
}
