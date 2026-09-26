/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Wraps 16-bit mono PCM in a canonical 44-byte RIFF/WAVE header.
enum WAVEncoder {
    static let headerSize = 44
    private static let bitsPerSample: UInt16 = 16
    private static let channels: UInt16 = 1
    private static let pcmFormatTag: UInt16 = 1
    private static let fmtChunkSize: UInt32 = 16

    static func encode(pcm16Mono pcm: Data, sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = rate * UInt32(blockAlign)
        let dataSize = UInt32(pcm.count)

        var wav = Data(capacity: headerSize + pcm.count)
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLittleEndian(UInt32(headerSize - 8) + dataSize)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.appendLittleEndian(fmtChunkSize)
        wav.appendLittleEndian(pcmFormatTag)
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(rate)
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLittleEndian(dataSize)
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
