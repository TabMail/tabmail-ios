/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import TabMail

/// The dictation upload's encoder. The signals and the golden stream are TabMail Voice's
/// (`apps/desktop/test/flac.test.ts`), so both apps are pinned to the same bytes.
struct FLACEncoderTests {
    /// A deterministic pseudo-random sequence (a linear congruential generator), so noise is
    /// repeatable. In doubles, as Voice's TypeScript computes it, so the samples are identical.
    static func noise(_ count: Int, amplitude: Double, seed: Double = 1) -> [Int16] {
        var state = seed
        return (0..<count).map { _ in
            state = (state * 1_103_515_245 + 12_345).truncatingRemainder(dividingBy: 2_147_483_648)
            return Int16(jsRound((state / 2_147_483_648 - 0.5) * 2 * amplitude))
        }
    }

    /// Speech-like: a gliding tone with a little noise, and a stretch of digital silence.
    static func speechLike(_ count: Int) -> [Int16] {
        let hiss = noise(count, amplitude: 100)
        return (0..<count).map { index in
            let silent = index % 20_000 < 3_000
            let x = Double(index)
            return silent ? 0 : Int16(jsRound(9_000 * sin(2 * Double.pi * (180 + x / 400) * x / 16_000))) + hiss[index]
        }
    }

    /// A pure tone, which a high predictor order codes best.
    static func tone(_ count: Int) -> [Int16] {
        (0..<count).map { Int16(jsRound(9_000 * sin(2 * Double.pi * 440 * Double($0) / 16_000))) }
    }

    /// Quiet audio with a full-scale burst in the middle and a step near the end: the burst's
    /// partition needs the largest Rice parameter, while the quiet rest keeps a predictor cheaper
    /// than verbatim. The step wraps where it meets the burst, as Voice's `Int16Array` does.
    static func burstAndStep(_ count: Int) -> [Int16] {
        var samples = noise(count, amplitude: 30, seed: 5)
        let burst = count / 2
        for index in burst..<min(count, burst + 64) { samples[index] = index % 2 == 0 ? .max : .min }
        for index in (count * 3 / 4)..<count { samples[index] &+= 12_000 }
        return samples
    }

    /// The stream header ("fLaC" and the STREAMINFO block), and a generous bound on a frame's own
    /// header and footer.
    private static let streamHeaderBytes = 42
    private static let frameOverheadBytes = 16

    /// JavaScript's `Math.round`: halves round up.
    private static func jsRound(_ value: Double) -> Double {
        let down = value.rounded(.down)
        return value - down >= 0.5 ? down + 1 : down
    }

    static func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func encode(_ samples: [Int16], sampleRate: Double = 16_000) -> Data {
        FLACEncoder.encode(pcm16Mono: Self.pcm(samples), sampleRate: sampleRate)
    }

    private static let block = DictationConfig.flacBlockSize

    /// Lossless: whatever the signal, the stream decodes to exactly the samples given.
    @Test(arguments: [
        ("speech-like", speechLike(3 * block + 17)),
        ("digital silence", [Int16](repeating: 0, count: 2 * block)),
        ("loud noise", noise(block + 100, amplitude: 32_000)),
        ("full-scale square wave", (0..<5_000).map { $0 % 2 == 0 ? Int16.max : Int16.min }),
        ("one sample", [-5]),
        ("a block exactly", noise(block, amplitude: 2_000, seed: 7)),
        ("a block and one", noise(block + 1, amplitude: 2_000, seed: 9)),
    ] as [(String, [Int16])])
    func decodesToTheSameSamples(_ name: String, samples: [Int16]) throws {
        let decoded = try FLACTestDecoder.decode(encode(samples))
        #expect(decoded.pcm == Self.pcm(samples))
        #expect(decoded.totalSamples == samples.count)
        #expect(decoded.sampleRate == 16_000)
    }

    /// A recording can end on any sample, so the last frame can be any length: every short one,
    /// and a few odd longer ones, alone and after a full block, over noise, a tone and a burst with
    /// a step (each takes a different coding path).
    @Test(arguments: ["noise", "a tone", "quiet audio with a full-scale burst and a step"])
    func decodesToTheSameSamplesWhateverLengthTheLastFrameIs(_ signal: String) throws {
        let tails = Array(1...40) + [127, 255, 1_001]
        for tail in tails {
            for count in [tail, Self.block + tail] {
                let samples = switch signal {
                case "noise": Self.noise(count, amplitude: 2_000, seed: 11)
                case "a tone": Self.tone(count)
                default: Self.burstAndStep(count)
                }
                let decoded = try FLACTestDecoder.decode(encode(samples))
                #expect(decoded.pcm == Self.pcm(samples), "\(count) samples")
            }
        }
    }

    /// Silence is a constant subframe: a few bytes a frame, not a sample's worth each.
    @Test func digitalSilenceCostsAFewBytesAFrame() {
        let frames = 5
        let size = encode([Int16](repeating: 0, count: frames * Self.block)).count
        #expect(size <= Self.streamHeaderBytes + frames * Self.frameOverheadBytes)
    }

    /// A frame no predictor shrinks is sent verbatim, so no stream is much larger than its PCM (the
    /// upload's size bound rests on this, ADR-IOS-085).
    @Test(arguments: [
        ("full-scale noise", noise(3 * block + 5, amplitude: 32_767, seed: 3)),
        ("a full-scale square wave", (0..<(3 * block + 5)).map { $0 % 2 == 0 ? Int16.max : Int16.min }),
    ] as [(String, [Int16])])
    func fullScaleAudioIsNoLargerThanItsPCMAndAFramesOverhead(_ name: String, samples: [Int16]) {
        let frames = (samples.count + Self.block - 1) / Self.block
        #expect(encode(samples).count <= samples.count * 2 + Self.streamHeaderBytes + frames * Self.frameOverheadBytes)
    }

    @Test func anEmptyRecordingIsAValidStreamOfNoSamples() throws {
        let decoded = try FLACTestDecoder.decode(encode([]))
        #expect([decoded.totalSamples, decoded.frames, decoded.pcm.count] as [Int] == [0, 0, 0])
    }

    @Test func framesAreFullBlocksButTheLast() throws {
        let decoded = try FLACTestDecoder.decode(encode(Self.speechLike(3 * Self.block + 17)))
        #expect(decoded.frames == 4)
        #expect([decoded.minBlockSize, decoded.maxBlockSize] as [Int] == [Self.block, Self.block])
    }

    /// Frame numbers past 127 take the coded number's two-byte form; a two-minute dictation has
    /// ~470 frames.
    @Test func numbersFramesPastTheOneByteRange() throws {
        let samples = Self.noise(130 * Self.block, amplitude: 1_000, seed: 3)
        let decoded = try FLACTestDecoder.decode(encode(samples))
        #expect(decoded.frames == 130)
        #expect(decoded.pcm == Self.pcm(samples))
    }

    /// The frame header names common rates outright and codes others in kHz, Hz or tens of Hz.
    @Test(arguments: [8_000, 16_000, 44_100, 48_000, 22_000, 11_025, 100_000, 100_001])
    func carriesTheSampleRate(_ rate: Int) throws {
        let decoded = try FLACTestDecoder.decode(encode(Self.noise(500, amplitude: 1_000), sampleRate: Double(rate)))
        #expect(decoded.sampleRate == rate)
    }

    /// The point of it: speech-like audio uploads at well under WAV's size.
    @Test func compressesSpeechLikeAudioToUnder60PercentOfItsPCM() {
        let samples = Self.speechLike(10 * 16_000)
        #expect(Double(encode(samples).count) < 0.6 * Double(samples.count * 2))
    }

    /// Independent oracle: Core Audio's own FLAC decoder reads the stream back to the same samples.
    @Test func coreAudioDecodesTheSameSamples() throws {
        let samples = Self.speechLike(3 * Self.block + 17)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabmail-flac-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try encode(samples).write(to: url)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(samples.count))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int16ChannelData)
        #expect(Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))) == samples)
    }

    /// Pins the exact bytes of the stream the reference decoder accepted (`flac -t`, and `flac -d`
    /// gave back the same samples) when Voice's encoder was written: Voice pins the same hash, so a
    /// change to either bitstream is noticed.
    @Test func writesTheStreamTheReferenceDecoderWasCheckedAgainst() {
        let stream = encode(Self.speechLike(3 * Self.block + 17))
        let hash = SHA256.hash(data: stream).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "46f96d77b49e3f3f2f89b186ea28a3ded006994e259e28dd6f0ef6291ac3b862")
    }
}
