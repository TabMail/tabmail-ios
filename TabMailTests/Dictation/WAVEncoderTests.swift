/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Testing
@testable import TabMail

struct DictationWAVEncoderTests {
    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    @Test func writesACanonicalPCMHeader() {
        let pcm = Data(repeating: 7, count: 320)
        let wav = WAVEncoder.encode(pcm16Mono: pcm, sampleRate: 16_000)

        #expect(wav.count == WAVEncoder.headerSize + pcm.count)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(wav, at: 4) == UInt32(wav.count - 8))
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(uint32(wav, at: 16) == 16)
        #expect(uint16(wav, at: 20) == 1)        // PCM
        #expect(uint16(wav, at: 22) == 1)        // mono
        #expect(uint32(wav, at: 24) == 16_000)   // sample rate
        #expect(uint32(wav, at: 28) == 32_000)   // byte rate
        #expect(uint16(wav, at: 32) == 2)        // block align
        #expect(uint16(wav, at: 34) == 16)       // bits per sample
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(uint32(wav, at: 40) == UInt32(pcm.count))
        #expect(wav.subdata(in: 44..<wav.count) == pcm)
    }

    /// Independent oracle: AVAudioFile must be able to read what we wrote.
    @Test func producesAFileCoreAudioCanRead() throws {
        let samples: [Int16] = (0..<1600).map { Int16(truncatingIfNeeded: $0 * 20) }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabmail-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVEncoder.encode(pcm16Mono: pcm, sampleRate: 16_000).write(to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(samples.count))
    }
}
