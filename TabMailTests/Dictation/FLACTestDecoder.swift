/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A test-only FLAC decoder (RFC 9639) for the subset `FLACEncoder` writes: one channel, 16 bits,
/// constant, verbatim and fixed-predictor subframes with 4-bit Rice parameters. It checks every
/// frame's CRC-8 and CRC-16, and throws on anything else, so a test fails rather than reading a
/// stream the encoder should not have written. TabMail Voice's `test/flacDecoder.ts`, in Swift.
enum FLACTestDecoder {
    struct Decoded {
        var sampleRate: Int
        var minBlockSize: Int
        var maxBlockSize: Int
        var totalSamples: Int
        /// The samples as little-endian 16-bit PCM, as `Recording.pcm` holds them.
        var pcm: Data
        var frames: Int
    }

    struct Invalid: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        var reader = BitReader(bytes: bytes)
        guard try reader.read(32) == 0x664C_6143 else { throw Invalid("no fLaC marker") }
        let last = try reader.read(1), type = try reader.read(7), length = try reader.read(24)
        guard last == 1, type == 0, length == 34 else { throw Invalid("expected a single STREAMINFO block") }
        let minBlockSize = try reader.read(16)
        let maxBlockSize = try reader.read(16)
        _ = try reader.read(24)
        _ = try reader.read(24)
        let sampleRate = try reader.read(20)
        guard try reader.read(3) == 0 else { throw Invalid("expected one channel") }
        guard try reader.read(5) == 15 else { throw Invalid("expected 16 bits per sample") }
        let totalSamples = try reader.read(36)
        for _ in 0..<8 { _ = try reader.read(16) }

        var samples: [Int] = []
        var frames = 0
        while reader.byteOffset < bytes.count {
            let frameStart = reader.byteOffset
            guard try reader.read(14) == 0b11111111111110, try reader.read(1) == 0 else { throw Invalid("frame \(frames): no sync code") }
            guard try reader.read(1) == 0 else { throw Invalid("expected fixed block size") }
            let sizeCode = try reader.read(4)
            let rateCode = try reader.read(4)
            guard try reader.read(4) == 0, try reader.read(3) == 0b100, try reader.read(1) == 0 else { throw Invalid("expected mono 16-bit frames") }
            let frameNumber = try readCodedNumber(&reader)
            guard frameNumber == frames else { throw Invalid("frame \(frames) numbered \(frameNumber)") }
            let blockSize: Int = switch sizeCode {
            case 6: try reader.read(8) + 1
            case 7: try reader.read(16) + 1
            case 1: 192
            case 2...5: 576 << (sizeCode - 2)
            default: 256 << (sizeCode - 8)
            }
            let frameRate: Int = switch rateCode {
            case 12: try reader.read(8) * 1000
            case 13: try reader.read(16)
            case 14: try reader.read(16) * 10
            case 0: sampleRate
            default: standardRates[rateCode]
            }
            guard frameRate == sampleRate else { throw Invalid("frame \(frames): rate \(frameRate), STREAMINFO \(sampleRate)") }
            let headerCRC = crc(bytes[frameStart..<reader.byteOffset], polynomial: 0x07, width: 8)
            guard try reader.read(8) == headerCRC else { throw Invalid("frame \(frames): header CRC-8 mismatch") }

            try readSubframe(&reader, blockSize: blockSize, into: &samples)
            reader.alignToByte()
            let frameCRC = crc(bytes[frameStart..<reader.byteOffset], polynomial: 0x8005, width: 16)
            guard try reader.read(16) == frameCRC else { throw Invalid("frame \(frames): CRC-16 mismatch") }
            frames += 1
        }
        guard samples.count == totalSamples else { throw Invalid("STREAMINFO says \(totalSamples) samples, frames hold \(samples.count)") }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: Int16(sample))
            pcm.append(UInt8(bits & 0xFF))
            pcm.append(UInt8(bits >> 8))
        }
        return Decoded(sampleRate: sampleRate, minBlockSize: minBlockSize, maxBlockSize: maxBlockSize, totalSamples: totalSamples, pcm: pcm, frames: frames)
    }

    private static let standardRates = [0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000]

    private static func readSubframe(_ reader: inout BitReader, blockSize: Int, into out: inout [Int]) throws {
        guard try reader.read(1) == 0 else { throw Invalid("subframe padding bit set") }
        let type = try reader.read(6)
        guard try reader.read(1) == 0 else { throw Invalid("wasted bits are never written") }
        if type == 0 {
            let value = signed(try reader.read(16))
            out.append(contentsOf: repeatElement(value, count: blockSize))
            return
        }
        if type == 1 {
            for _ in 0..<blockSize { out.append(signed(try reader.read(16))) }
            return
        }
        guard (8...12).contains(type) else { throw Invalid("unexpected subframe type \(type)") }
        let order = type - 8
        var block: [Int] = []
        for _ in 0..<order { block.append(signed(try reader.read(16))) }
        guard try reader.read(2) == 0 else { throw Invalid("expected 4-bit Rice parameters") }
        let partitions = 1 << (try reader.read(4))
        var residual: [Int] = []
        for partition in 0..<partitions {
            let parameter = try reader.read(4)
            guard parameter != 15 else { throw Invalid("escape code is never written") }
            let count = blockSize / partitions - (partition == 0 ? order : 0)
            for _ in 0..<count {
                var quotient = 0
                while try reader.read(1) == 0 { quotient += 1 }
                let value = quotient << parameter + (parameter > 0 ? try reader.read(parameter) : 0)
                residual.append(value % 2 == 0 ? value / 2 : -(value + 1) / 2)
            }
        }
        let coefficients = [[], [1], [2, -1], [3, -3, 1], [4, -6, 4, -1]][order]
        for error in residual {
            let i = block.count
            var prediction = 0
            for (lag, coefficient) in coefficients.enumerated() { prediction += coefficient * block[i - 1 - lag] }
            block.append(prediction + error)
        }
        guard block.count == blockSize else { throw Invalid("subframe decoded \(block.count) of \(blockSize) samples") }
        out.append(contentsOf: block)
    }

    private static func readCodedNumber(_ reader: inout BitReader) throws -> Int {
        let first = try reader.read(8)
        if first < 0x80 { return first }
        var continuation = 0
        while first & (0x40 >> continuation) != 0 { continuation += 1 }
        var value = first & (0x3F >> continuation)
        for _ in 0..<continuation {
            let next = try reader.read(8)
            guard next & 0xC0 == 0x80 else { throw Invalid("bad coded number") }
            value = value << 6 | next & 0x3F
        }
        return value
    }

    private static func signed(_ value: Int) -> Int {
        value >= 1 << 15 ? value - 1 << 16 : value
    }

    /// A straightforward bitwise CRC, independent of the encoder's table-driven one.
    private static func crc(_ bytes: ArraySlice<UInt8>, polynomial: Int, width: Int) -> Int {
        let top = 1 << (width - 1)
        let mask = 1 << width - 1
        var value = 0
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                let incoming = Int(byte >> bit) & 1
                let feedback = (value & top != 0 ? 1 : 0) ^ incoming
                value = value << 1 & mask
                if feedback == 1 { value ^= polynomial }
            }
        }
        return value
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        var byteOffset: Int { (position + 7) / 8 }

        mutating func read(_ bits: Int) throws -> Int {
            var value = 0
            for _ in 0..<bits {
                guard position >> 3 < bytes.count else { throw Invalid("read past the end of the stream") }
                value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
                position += 1
            }
            return value
        }

        mutating func alignToByte() {
            position = byteOffset * 8
        }
    }
}
