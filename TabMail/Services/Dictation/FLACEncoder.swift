/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Encodes 16-bit mono PCM as FLAC (RFC 9639) for the dictation upload: lossless, about half the
/// size of WAV for speech, so the upload is shorter. The same encoder as TabMail Voice's
/// `FLACEncoder`, byte for byte: fixed-size frames, each frame's subframe the smallest of constant
/// (digital silence), verbatim and the fixed predictors of order 0–4 with Rice-coded residuals.
enum FLACEncoder {
    private static let bitsPerSample = 16
    private static let streamInfoBytes = 34
    /// "fLaC", the metadata block header and STREAMINFO.
    private static let streamHeaderBytes = 4 + 4 + streamInfoBytes
    /// The 4-bit Rice parameter's largest value; 15 is the escape code, never written here.
    private static let maxRiceParameter = 14
    private static let fixedPredictorOrders = 4

    /// The frame header's block size codes for the sizes it names outright (RFC 9639 §9.1.1).
    private static let blockSizeCodes: [Int: UInt64] = [
        192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5,
        256: 8, 512: 9, 1024: 10, 2048: 11, 4096: 12, 8192: 13, 16384: 14, 32768: 15,
    ]
    /// The frame header's sample rate codes for the rates it names outright (RFC 9639 §9.1.2).
    private static let sampleRateCodes: [Int: UInt64] = [
        88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6,
        24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11,
    ]

    static func encode(pcm16Mono pcm: Data, sampleRate: Double) -> Data {
        let rate = Int(sampleRate)
        let count = pcm.count / MemoryLayout<Int16>.size
        // Copied out rather than bound in place: `Data` need not be aligned. Little-endian, as
        // every Apple platform is.
        let pcmSamples = [Int16](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = pcm.copyBytes(to: buffer) / MemoryLayout<Int16>.size
        }
        // The per-sample loops run on unsafe buffers, as `while` loops returning plain values:
        // debug builds don't optimise, and there range iteration, tuples and arrays made encoding
        // take a quarter of a second per 7 s of audio.
        let samples = [Int32](unsafeUninitializedCapacity: count) { buffer, initialized in
            pcmSamples.withUnsafeBufferPointer { source in
                var index = 0
                while index < count {
                    buffer[index] = Int32(source[index])
                    index += 1
                }
            }
            initialized = count
        }

        let blockSize = min(DictationConfig.flacBlockSize, max(count, 1))
        var writer = BitWriter(capacity: pcm.count + streamHeaderBytes)
        for byte in "fLaC".utf8 { writer.write(UInt64(byte), 8) }
        // The last (and only) metadata block: STREAMINFO.
        writer.write(1, 1)
        writer.write(0, 7)
        writer.write(UInt64(streamInfoBytes), 24)
        writer.write(UInt64(blockSize), 16)
        writer.write(UInt64(blockSize), 16)
        writer.write(0, 24) // smallest and largest frame: unknown
        writer.write(0, 24)
        writer.write(UInt64(rate), 20)
        writer.write(0, 3) // one channel
        writer.write(UInt64(bitsPerSample - 1), 5)
        writer.write(UInt64(count), 36)
        for _ in 0..<8 { writer.write(0, 16) } // no MD5 signature

        var residuals = ResidualBuffers(capacity: blockSize)
        samples.withUnsafeBufferPointer { all in
            var frame = 0
            var start = 0
            while start < count {
                let end = min(start + blockSize, count)
                writeFrame(&writer, block: UnsafeBufferPointer(rebasing: all[start..<end]), frame: frame, rate: rate, residuals: &residuals)
                frame += 1
                start = end
            }
        }
        return writer.finish()
    }

    private static func writeFrame(_ writer: inout BitWriter, block: UnsafeBufferPointer<Int32>, frame: Int, rate: Int, residuals: inout ResidualBuffers) {
        let frameStart = writer.byteCount
        writer.write(0b11111111111110, 14)
        writer.write(0, 1)
        writer.write(0, 1) // fixed block size
        let sizeCode = blockSizeCodes[block.count] ?? (block.count <= 256 ? 6 : 7)
        writer.write(sizeCode, 4)
        var rateCode = sampleRateCodes[rate]
        var rateBits = 0
        if rateCode == nil {
            if rate % 1000 == 0 && rate / 1000 < 256 { (rateCode, rateBits) = (12, 8) }
            else if rate < 65536 { (rateCode, rateBits) = (13, 16) }
            else if rate % 10 == 0 && rate / 10 < 65536 { (rateCode, rateBits) = (14, 16) }
            else { rateCode = 0 } // STREAMINFO's
        }
        let code = rateCode ?? 0
        writer.write(code, 4)
        writer.write(0, 4) // mono
        writer.write(0b100, 3) // 16 bits per sample
        writer.write(0, 1)
        writeCodedNumber(&writer, UInt64(frame))
        if sizeCode == 6 { writer.write(UInt64(block.count - 1), 8) }
        if sizeCode == 7 { writer.write(UInt64(block.count - 1), 16) }
        if rateBits > 0 { writer.write(UInt64(code == 12 ? rate / 1000 : code == 14 ? rate / 10 : rate), rateBits) }
        writer.write(UInt64(writer.crc8(from: frameStart)), 8)
        writeSubframe(&writer, block: block, residuals: &residuals)
        writer.alignToByte()
        writer.write(UInt64(writer.crc16(from: frameStart)), 16)
    }

    /// The frame number in the UTF-8-like coding of RFC 9639 §9.1.5.
    private static func writeCodedNumber(_ writer: inout BitWriter, _ value: UInt64) {
        if value < 0x80 {
            writer.write(value, 8)
            return
        }
        var continuation: UInt64 = 1
        while value >= 1 << (5 * continuation + 6) { continuation += 1 }
        writer.write(((0xFF << (7 - continuation)) & 0xFF) | value >> (6 * continuation), 8)
        for index in stride(from: Int(continuation) - 1, through: 0, by: -1) {
            writer.write(0x80 | (value >> UInt64(6 * index)) & 0x3F, 8)
        }
    }

    private static func writeSubframe(_ writer: inout BitWriter, block: UnsafeBufferPointer<Int32>, residuals: inout ResidualBuffers) {
        let first = block[0]
        var index = 1
        while index < block.count, block[index] == first { index += 1 }
        if index == block.count {
            writer.write(0, 8) // constant
            writer.write(sampleBits(first), bitsPerSample)
            return
        }
        var best: (order: Int, partitions: RicePartitions)?
        var bestBits = block.count * bitsPerSample // verbatim
        for order in 0...fixedPredictorOrders where order < block.count {
            let residual = UnsafeBufferPointer(rebasing: residuals.candidate[0..<block.count - order])
            fixedResidual(block, order: order, into: residuals.candidate)
            let partitions = ricePartitions(residual, blockLength: block.count, order: order)
            let bits = order * bitsPerSample + partitions.bits
            if bits < bestBits {
                (best, bestBits) = ((order, partitions), bits)
                residuals.keepCandidate()
            }
        }
        guard let best else {
            writer.write(0b00000010, 8) // verbatim
            for sample in block { writer.write(sampleBits(sample), bitsPerSample) }
            return
        }
        writer.write(0b00010000 | UInt64(best.order) << 1, 8) // fixed predictor of this order
        for index in 0..<best.order { writer.write(sampleBits(block[index]), bitsPerSample) }
        writer.write(0, 2) // Rice, 4-bit parameters
        writer.write(UInt64(best.partitions.order), 4)
        let residual = residuals.best
        let perPartition = block.count >> best.partitions.order
        var position = 0
        for (partition, parameter) in best.partitions.parameters.enumerated() {
            writer.write(UInt64(parameter), 4)
            let end = (partition + 1) * perPartition - best.order
            while position < end {
                writer.rice(zigzag(residual[position]), parameter: parameter)
                position += 1
            }
        }
    }

    /// A sample's 16 bits, two's complement.
    private static func sampleBits(_ sample: Int32) -> UInt64 {
        UInt64(UInt16(truncatingIfNeeded: sample))
    }

    /// The residual of the fixed predictor of `order` (RFC 9639 §9.2.5): `x.count - order` values.
    private static func fixedResidual(_ x: UnsafeBufferPointer<Int32>, order: Int, into residual: UnsafeMutableBufferPointer<Int32>) {
        var i = order
        switch order {
        case 0: while i < x.count { residual[i] = x[i]; i += 1 }
        case 1: while i < x.count { residual[i - 1] = x[i] - x[i - 1]; i += 1 }
        case 2: while i < x.count { residual[i - 2] = x[i] - 2 * x[i - 1] + x[i - 2]; i += 1 }
        case 3: while i < x.count { residual[i - 3] = x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3]; i += 1 }
        default: while i < x.count { residual[i - 4] = x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4]; i += 1 }
        }
    }

    private static func zigzag(_ value: Int32) -> UInt64 {
        value >= 0 ? UInt64(value) * 2 : UInt64(-Int64(value)) * 2 - 1
    }

    private struct RicePartitions {
        var order: Int
        var parameters: [Int]
        /// The residual section's estimated size, its method and order fields included.
        var bits: Int
    }

    /// The partition order and per-partition Rice parameters that code `residual` smallest,
    /// estimated from each partition's sum as libFLAC does.
    private static func ricePartitions(_ residual: UnsafeBufferPointer<Int32>, blockLength: Int, order: Int) -> RicePartitions {
        var maxOrder = 0
        while maxOrder < DictationConfig.flacMaxPartitionOrder,
              blockLength % (1 << (maxOrder + 1)) == 0,
              blockLength >> (maxOrder + 1) > order {
            maxOrder += 1
        }
        // Sums of the finest partitions (the first is `order` samples short: the warm-up samples),
        // merged pairwise for each coarser order.
        let finestLength = blockLength >> maxOrder
        var sums = [UInt64](repeating: 0, count: 1 << maxOrder)
        var lengths = [Int](repeating: finestLength, count: 1 << maxOrder)
        lengths[0] -= order
        var index = 0
        for partition in 0..<sums.count {
            let end = (partition + 1) * finestLength - order
            var sum: UInt64 = 0
            while index < end {
                sum += zigzag(residual[index])
                index += 1
            }
            sums[partition] = sum
        }
        var best = RicePartitions(order: 0, parameters: [], bits: .max)
        for partitionOrder in stride(from: maxOrder, through: 0, by: -1) {
            var parameters: [Int] = []
            var bits = 2 + 4
            for partition in 0..<sums.count {
                let parameter = riceParameter(sum: sums[partition], length: lengths[partition])
                parameters.append(parameter)
                bits += 4 + riceBits(sum: sums[partition], length: lengths[partition], parameter: parameter)
            }
            if bits < best.bits { best = RicePartitions(order: partitionOrder, parameters: parameters, bits: bits) }
            if partitionOrder > 0 {
                sums = stride(from: 0, to: sums.count, by: 2).map { sums[$0] + sums[$0 + 1] }
                lengths = stride(from: 0, to: lengths.count, by: 2).map { lengths[$0] + lengths[$0 + 1] }
            }
        }
        return best
    }

    /// The Rice parameter that codes a partition of `length` residuals summing to `sum` smallest…
    private static func riceParameter(sum: UInt64, length: Int) -> Int {
        var parameter = 0
        var candidate = 1
        while candidate <= maxRiceParameter {
            if riceBits(sum: sum, length: length, parameter: candidate) < riceBits(sum: sum, length: length, parameter: parameter) {
                parameter = candidate
            }
            candidate += 1
        }
        return parameter
    }

    /// …and about how many bits it takes: each residual's low bits and unary stop bit, plus the
    /// quotients, estimated from the sum.
    private static func riceBits(sum: UInt64, length: Int, parameter: Int) -> Int {
        length * (parameter + 1) + Int(sum >> UInt64(parameter))
    }
}

/// Two residual buffers of a block's length: the fixed predictor being tried, and the best so far.
/// Non-copyable structs rather than classes, here and `BitWriter`, so debug builds check
/// exclusive access at compile time rather than on every access.
private struct ResidualBuffers: ~Copyable {
    private(set) var candidate: UnsafeMutableBufferPointer<Int32>
    private(set) var best: UnsafeMutableBufferPointer<Int32>

    init(capacity: Int) {
        candidate = .allocate(capacity: capacity)
        best = .allocate(capacity: capacity)
    }

    deinit {
        candidate.deallocate()
        best.deallocate()
    }

    /// The candidate becomes the best; the old best is reused for the next candidate.
    mutating func keepCandidate() {
        swap(&candidate, &best)
    }
}

/// Big-endian bit packing into a growing buffer.
private struct BitWriter: ~Copyable {
    private var buffer: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    private(set) var byteCount = 0
    private var pending: UInt64 = 0
    private var pendingBits = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 64)
        buffer = .allocate(capacity: self.capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// `value`'s low `bits` bits (at most 56), most significant first.
    mutating func write(_ value: UInt64, _ bits: Int) {
        guard bits > 0 else { return }
        pending = pending << UInt64(bits) | value & (1 << UInt64(bits) - 1)
        pendingBits += bits
        while pendingBits >= 8 {
            pendingBits -= 8
            push(UInt8(truncatingIfNeeded: pending >> UInt64(pendingBits)))
        }
        pending &= 1 << UInt64(pendingBits) - 1
    }

    /// `value` Rice-coded with `parameter`: the quotient in unary (zeros, then a one), then the low bits.
    mutating func rice(_ value: UInt64, parameter: Int) {
        var quotient = Int(value >> UInt64(parameter))
        while quotient >= 32 {
            write(0, 32)
            quotient -= 32
        }
        write(1, quotient + 1)
        write(value, parameter)
    }

    mutating func alignToByte() {
        if pendingBits > 0 { write(0, 8 - pendingBits) }
    }

    func crc8(from start: Int) -> UInt8 {
        var crc: UInt8 = 0
        var index = start
        while index < byteCount {
            crc = crc8Table[Int(crc ^ buffer[index])]
            index += 1
        }
        return crc
    }

    func crc16(from start: Int) -> UInt16 {
        var crc: UInt16 = 0
        var index = start
        while index < byteCount {
            crc = crc << 8 ^ crc16Table[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ buffer[index])]
            index += 1
        }
        return crc
    }

    mutating func finish() -> Data {
        alignToByte()
        return Data(bytes: buffer, count: byteCount)
    }

    private mutating func push(_ byte: UInt8) {
        if byteCount == capacity {
            let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * 2)
            grown.moveInitialize(from: buffer, count: byteCount)
            buffer.deallocate()
            buffer = grown
            capacity *= 2
        }
        buffer[byteCount] = byte
        byteCount += 1
    }
}

private let crc8Table: [UInt8] = (0..<256).map { byte in
    var crc = UInt8(byte)
    for _ in 0..<8 { crc = crc & 0x80 != 0 ? crc << 1 ^ 0x07 : crc << 1 }
    return crc
}

private let crc16Table: [UInt16] = (0..<256).map { byte in
    var crc = UInt16(byte) << 8
    for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x8005 : crc << 1 }
    return crc
}
