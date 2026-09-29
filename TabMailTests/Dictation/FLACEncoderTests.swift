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
