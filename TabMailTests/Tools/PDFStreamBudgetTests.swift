/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `PDFStreamBudget` refuses decompression bombs before PDFKit opens a file. The caps here are
/// small so each case is a few KB; the production caps are the same code with larger numbers.
@Suite("PDFStreamBudget")
struct PDFStreamBudgetTests {

    private func check(_ data: Data, stream: Int = 1_000, total: Int = 10_000,
                       deadline: ContinuousClock.Instant = .now + .seconds(20)) -> PDFStreamBudget.Verdict {
        PDFStreamBudget.check(data, caps: PDFStreamBudget.Caps(streamBytes: stream, totalBytes: total), deadline: deadline)
    }

    private func flateFile(_ inflatedBytes: Int, dictionary: String = "<< /Length 0 /Filter /FlateDecode >>") -> Data {
        PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: PDFFixtures.flateZeros(inflatedBytes))])
    }

    // MARK: - Caps

    @Test("A stream that inflates to exactly the cap passes; one byte more is refused")
    func streamCapBoundary() {
        #expect(check(flateFile(1_000)) == .withinBudget)
        #expect(check(flateFile(1_001)) == .overBudget)
    }

    @Test("The total cap counts every stream in the file")
    func totalCap() {
        let file = PDFFixtures.raw([
            PDFFixtures.streamObject(1, dictionary: "<< /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(600)),
            PDFFixtures.streamObject(2, dictionary: "<< /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(600)),
        ])
        #expect(check(file, total: 1_200) == .withinBudget)
        #expect(check(file, total: 1_199) == .overBudget)
    }

    @Test("A false /Length does not shorten what is counted")
    func lyingLength() {
        #expect(check(flateFile(5_000, dictionary: "<< /Length 5 /Filter /FlateDecode >>")) == .overBudget)
    }

    @Test("Ordinary generated PDFs pass the production caps")
    func generatedPdfsPass() {
        let data = PDFFixtures.make([.text("Alpha"), .image, .text("請求書の合計金額 中文测试 한국어")])
        let caps = PDFStreamBudget.Caps(
            streamBytes: AttachmentReadPdfTool.Config.maxDecodedStreamBytes,
            totalBytes: AttachmentReadPdfTool.Config.maxDecodedTotalBytes)
        #expect(PDFStreamBudget.check(data, caps: caps, deadline: .now + .seconds(20)) == .withinBudget)
    }

    @Test("A passed deadline stops the check")
    func deadline() {
        #expect(check(flateFile(10), deadline: .now - .seconds(1)) == .timedOut)
    }

    // MARK: - Reading the dictionary

    @Test("An escaped filter name is read as CoreGraphics reads it")
    func escapedFilterName() {
        #expect(check(flateFile(5_000, dictionary: "<< /Filter /Fl#61teDecode >>")) == .overBudget)
        #expect(check(flateFile(5_000, dictionary: "<< /Filt#65r /FlateDecode >>")) == .overBudget)
    }

    @Test("Only the stream's own /Filter counts, not one in a string or a nested dictionary")
    func filterKeyScope() {
        let decoys = "<< /Note (/Filter /DCTDecode) /DecodeParms << /Filter /DCTDecode >> /Filter /FlateDecode >>"
        #expect(check(flateFile(5_000, dictionary: decoys)) == .overBudget)
        let nestedOnly = "<< /DecodeParms << /Filter /FlateDecode >> >>"
        #expect(check(flateFile(5_000, dictionary: nestedOnly)) == .withinBudget)
    }

    @Test("A malformed earlier object cannot hide a later stream")
    func malformedObjectDoesNotHideTheNext() {
        let unclosedString = Data("1 0 obj\n<< /Title (never closed >>\nendobj\n".utf8)
        let fakeEnd = PDFFixtures.streamObject(2, dictionary: "<< >>", data: Data("endstream\nendobj\n<< (".utf8))
        let bomb = PDFFixtures.streamObject(3, dictionary: "<< /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(5_000))
        #expect(check(PDFFixtures.raw([unclosedString, fakeEnd, bomb])) == .overBudget)
    }

    @Test("Each object is read only up to the next, so many malformed objects stay cheap")
    func malformedObjectsStayLinear() {
        // Each object opens a string it never closes. Read to the end of the file each time, these
        // 20,000 objects would take billions of steps; read to the next object, a few hundred thousand.
        let objects = (1...20_000).map { Data("\($0) 0 obj\n<< /T (\nendobj\n".utf8) }
        #expect(check(PDFFixtures.raw(objects), deadline: .now + .seconds(5)) == .withinBudget)
    }

    @Test("Flate data without a zlib header counts as nothing, as CoreGraphics inflates none of it")
    func undecodableData() {
        let noise = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        let file = PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: "<< /Filter /FlateDecode >>", data: noise)])
        #expect(check(file) == .withinBudget)

        // The same bomb is refused with its header and ignored without it.
        let bomb = PDFFixtures.flateZeros(5_000)
        let headerless = PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: "<< /Filter /FlateDecode >>", data: bomb.dropFirst(2))])
        #expect(check(headerless) == .withinBudget)
        #expect(check(flateFile(5_000)) == .overBudget)
    }

    // MARK: - Filters

    @Test("ASCII encodings in front of Flate are undone and the Flate output counted")
    func asciiLayers() {
        for (filter, encode) in [("/ASCII85Decode", Self.base85), ("/ASCIIHexDecode", Self.hex)] {
            let small = encode(PDFFixtures.flateZeros(900))
            let big = encode(PDFFixtures.flateZeros(5_000))
            let dictionary = "<< /Filter [\(filter) /FlateDecode] >>"
            #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: small)])) == .withinBudget)
            #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: big)])) == .overBudget)
        }
    }

    @Test("ASCII85 zero groups count toward the cap")
    func base85ZeroGroups() {
        let zeros = Data(String(repeating: "z", count: 300).utf8) + Data("~>".utf8)
        let dictionary = "<< /Filter /ASCII85Decode >>"
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: zeros)])) == .overBudget)
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: zeros)]), stream: 1_200) == .withinBudget)
    }

    @Test("LZW output is counted")
    func lzw() {
        // Codes 97, 258, 259, … each repeat the previous entry plus one byte: 1 + 2 + … + n bytes.
        let within = Self.lzwRun(44)  // 990 bytes
        let over = Self.lzwRun(45)    // 1,035 bytes
        let dictionary = "<< /Filter /LZWDecode >>"
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: within)])) == .withinBudget)
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: over)])) == .overBudget)
    }

    @Test("RunLength output is counted")
    func runLength() {
        func runs(_ count: Int) -> Data { Data(Array(repeating: [UInt8(129), 0x41], count: count).flatMap { $0 } + [128]) }
        let dictionary = "<< /Filter /RunLengthDecode >>"
        // Each run repeats one byte 128 times.
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: runs(7))])) == .withinBudget)
        #expect(check(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: dictionary, data: runs(8))])) == .overBudget)
    }

    @Test("Filter chains the check cannot follow are refused; others are planned")
    func plans() {
        #expect(PDFStreamBudget.plan(filters: ["FlateDecode", "FlateDecode"], indirect: false) == .refuse)
        #expect(PDFStreamBudget.plan(filters: ["DCTDecode", "FlateDecode"], indirect: false) == .refuse)
        #expect(PDFStreamBudget.plan(filters: ["FlateDecode"], indirect: true) == .refuse)
        #expect(PDFStreamBudget.plan(filters: ["A85", "Fl"], indirect: false) == .count(textLayers: [.base85], expander: .flate))
        #expect(PDFStreamBudget.plan(filters: ["FlateDecode", "DCTDecode"], indirect: false) == .count(textLayers: [], expander: .flate))
        #expect(PDFStreamBudget.plan(filters: ["DCTDecode"], indirect: false) == .count(textLayers: [], expander: nil))
        #expect(PDFStreamBudget.plan(filters: [], indirect: false) == .count(textLayers: [], expander: nil))
    }

    @Test("A filter given by indirect reference refuses the file")
    func indirectFilter() {
        #expect(check(flateFile(10, dictionary: "<< /Filter 7 0 R >>")) == .overBudget)
    }

    // MARK: - Encoders

    private static func hex(_ data: Data) -> Data {
        Data((data.map { String(format: "%02x", $0) }.joined() + ">").utf8)
    }

    private static func base85(_ data: Data) -> Data {
        var out = ""
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 4, bytes.count)])
            let padded = chunk + Array(repeating: 0, count: 4 - chunk.count)
            var value = padded.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var digits: [Character] = []
            for _ in 0..<5 {
                digits.insert(Character(UnicodeScalar(UInt8(value % 85) + 33)), at: 0)
                value /= 85
            }
            out += String(digits.prefix(chunk.count + 1))
            index += 4
        }
        return Data((out + "~>").utf8)
    }

    /// `n` LZW codes (9 bits each, after a clear) decoding to 1 + 2 + … + n bytes, then end-of-data.
    private static func lzwRun(_ n: Int) -> Data {
        let codes = [256, 97] + (0..<(n - 1)).map { 258 + $0 } + [257]
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for code in codes {
            buffer = buffer << 9 | code
            bits += 9
            while bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(UInt8((buffer << (8 - bits)) & 0xFF)) }
        return Data(out)
    }
}
