/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import CoreGraphics
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

    @Test("A fake endstream inside stream data cannot hide a later stream")
    func fakeEndDoesNotHideTheNext() {
        let fakeEnd = PDFFixtures.streamObject(1, dictionary: "<< >>", data: Data("endstream\nendobj\n<< (".utf8))
        let bomb = PDFFixtures.streamObject(2, dictionary: "<< /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(5_000))
        #expect(check(PDFFixtures.raw([fakeEnd, bomb])) == .overBudget)
        #expect(check(PDFFixtures.raw([fakeEnd, bomb]), stream: 5_000) == .withinBudget)
    }

    @Test("A dictionary still open at the next object is refused")
    func unclosedDictionaryRefused() {
        let closed = Data("1 0 obj\n<< /Title (closed) >>\nendobj\n".utf8)
        let unclosed = Data("1 0 obj\n<< /Title (never closed >>\nendobj\n".utf8)
        let next = Data("2 0 obj\n<< >>\nendobj\n".utf8)
        #expect(check(PDFFixtures.raw([closed, next])) == .withinBudget)
        #expect(check(PDFFixtures.raw([unclosed, next])) == .overBudget)
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

    // MARK: - Every stream CoreGraphics decodes is counted

    /// Ways to write a page's content stream that CoreGraphics still decodes in full.
    enum Trick: String, CaseIterable {
        case none
        case headerInString
        case headerInComment
        case headerInStringClaimingTheStream
        case headerGluedToPreviousByte
        case headerGluedAndCommentBeforeKeyword
        case filterByReferenceInArray
        case spaceBeforeEndOfLine
        case commentAfterKeyword
        case textAfterKeyword

        /// Written so the check can read it exactly, rather than refusing what it cannot follow.
        var readable: Bool { [.none, .spaceBeforeEndOfLine, .commentAfterKeyword, .textAfterKeyword].contains(self) }
    }

    /// A one-page document whose content stream (object 4) inflates to 5,000 bytes, written with `trick`.
    private static func document(_ trick: Trick) -> Data {
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        var dictionary = "<< /Filter /FlateDecode >>"
        var keyword = "\nstream\n"
        var page = object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>")
        switch trick {
        case .none: break
        case .headerInString: dictionary = "<< /X (9 0 obj) /Filter /FlateDecode >>"
        case .headerInComment: dictionary = "<< % 9 0 obj\n/Filter /FlateDecode >>"
        case .headerInStringClaimingTheStream:
            // Read from the decoy, the dictionary ends at the same `>>` with a filter that is not counted.
            dictionary = "<< /Filter /FlateDecode /X (9 0 obj << /Filter /DCTDecode /Y \\() >>"
        case .headerGluedToPreviousByte: page = Data("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobjx".utf8)
        case .headerGluedAndCommentBeforeKeyword:
            page = Data("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobjx".utf8)
            keyword = " % c\nstream\n"
        case .filterByReferenceInArray: dictionary = "<< /Filter [5 0 R] >>"
        case .spaceBeforeEndOfLine: keyword = "\nstream \n"
        case .commentAfterKeyword: keyword = "\nstream %c\n"
        case .textAfterKeyword: keyword = "\nstream(x) abc\n"
        }
        let content = PDFFixtures.flate(Data(String(repeating: "q Q\n", count: 1_250).utf8))
        return PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            page,
            Data("4 0 obj\n\(dictionary)\(keyword)".utf8) + content + Data("\nendstream\nendobj\n".utf8),
            object(5, "/FlateDecode"),
        ])
    }

    /// What CoreGraphics decodes from the page's content stream: the oracle, independent of the check.
    private static func decodedByCoreGraphics(_ data: Data) throws -> Int {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: 1))
        // The dictionary belongs to the page, which must outlive every read of it.
        return try withExtendedLifetime(page) {
            let dictionary = try #require(page.dictionary)
            var found: CGPDFStreamRef?
            try #require(CGPDFDictionaryGetStream(dictionary, "Contents", &found))
            let stream = try #require(found)
            var format = CGPDFDataFormat.raw
            let decoded = try #require(CGPDFStreamCopyData(stream, &format))
            return CFDataGetLength(decoded)
        }
    }

    @Test("A stream CoreGraphics decodes past the cap is refused however it is written", arguments: Trick.allCases)
    func everyDecodedStreamCounts(_ trick: Trick) throws {
        let data = Self.document(trick)
        #expect(try Self.decodedByCoreGraphics(data) == 5_000)
        #expect(check(data) == .overBudget)
        #expect(check(data, stream: 5_000, total: 5_000) == (trick.readable ? .withinBudget : .overBudget))
    }

    @Test("The word stream in strings and text is not taken for a stream")
    func streamInText() {
        let file = PDFFixtures.raw([
            Data("1 0 obj\n<< /Title (Revenue stream) /Subject (stream\n) >>\nendobj\n".utf8),
            PDFFixtures.streamObject(2, dictionary: "<< >>", data: Data("BT (data stream) Tj ET\n% upstream\n".utf8)),
        ])
        #expect(check(file, stream: 1, total: 1) == .withinBudget)
    }

    @Test("A percent sign before the word stream on the same line is not taken for a comment hiding a stream")
    func percentBeforeStreamOnOneLine() {
        let file = PDFFixtures.raw([
            Data("1 0 obj\n<< /Title (Revenue grew 12% in each stream) >>\nendobj\n".utf8),
            PDFFixtures.streamObject(2, dictionary: "<< >>", data: Data("BT (Revenue grew 12% in each stream) Tj ET\n".utf8)),
        ])
        #expect(check(file, stream: 1, total: 1) == .withinBudget)
        // A percent sign on the line before still counts: see `Trick.headerGluedAndCommentBeforeKeyword`.
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

    /// A one-page file whose content stream is `data` under `filter`, so CoreGraphics' decode of
    /// the page contents is the oracle for the count.
    private static func contents(filter: String, data: Data) -> Data {
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        return PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(data.count) /Filter \(filter) >>", data: data),
        ])
    }

    /// Counted exactly: within a cap of `count` bytes, over a cap of one byte less.
    private func countsExactly(_ data: Data, _ count: Int) -> Bool {
        check(data, stream: count, total: count) == .withinBudget && check(data, stream: count - 1, total: count) == .overBudget
    }

    /// Bytes from a fixed four-letter alphabet, varied enough that LZW codes grow past 10 bits.
    private static func letters(_ count: Int) -> [UInt8] {
        var seed: UInt32 = 1
        return (0..<count).map { _ in
            seed = seed &* 1_103_515_245 &+ 12_345
            return UInt8(ascii: "a") + UInt8((seed >> 16) % 4)
        }
    }

    @Test("LZW dictionary entries count at their full length, with codes wider than 9 bits")
    func lzwDictionaryHits() throws {
        let plain = Self.letters(6_000)
        let encoded = Self.lzwEncode(plain)
        #expect(encoded.width >= 11)
        let data = Self.contents(filter: "/LZWDecode", data: encoded.data)
        #expect(try Self.decodedByCoreGraphics(data) == plain.count)
        #expect(countsExactly(data, plain.count))
    }

    @Test("LZW written with /EarlyChange 0 counts at its full length")
    func lzwLateChange() throws {
        let plain = Self.letters(6_000)
        let encoded = Self.lzwEncode(plain, earlyChange: false)
        #expect(encoded.width >= 11)
        #expect(encoded.data != Self.lzwEncode(plain).data)
        let data = Self.contents(filter: "/LZWDecode /DecodeParms << /EarlyChange 0 >>", data: encoded.data)
        #expect(try Self.decodedByCoreGraphics(data) == plain.count)
        #expect(countsExactly(data, plain.count))
    }

    @Test("LZW counts toward the file total at its full length under either /EarlyChange")
    func lzwTotalEitherSetting() {
        // Each setting's decoder stops early on the other's data, so the stream cap alone cannot
        // tell which count is used; the total can.
        let plain = Self.letters(6_000)
        for earlyChange in [true, false] {
            let lzw = Self.lzwEncode(plain, earlyChange: earlyChange).data
            let data = PDFFixtures.raw([
                PDFFixtures.streamObject(1, dictionary: "<< /Length \(lzw.count) /Filter /LZWDecode >>", data: lzw),
                PDFFixtures.streamObject(2, dictionary: "<< /Length 0 /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(1_000)),
            ])
            #expect(check(data, stream: 6_000, total: 7_000) == .withinBudget, "\(earlyChange)")
            #expect(check(data, stream: 6_000, total: 6_999) == .overBudget, "\(earlyChange)")
        }
    }

    @Test("RunLength literal and repeat runs both count")
    func runLengthLiteralRuns() throws {
        let literal = Array("Hello, world".utf8)
        let encoded = Data([UInt8(literal.count - 1)] + literal + [UInt8(257 - 100), UInt8(ascii: "x")] + [0, UInt8(ascii: "!")] + [128])
        let data = Self.contents(filter: "/RunLengthDecode", data: encoded)
        #expect(try Self.decodedByCoreGraphics(data) == 113)
        #expect(countsExactly(data, 113))
    }

    @Test("Two ASCII layers in front of Flate are both undone")
    func stackedAsciiLayers() throws {
        let data = Self.contents(filter: "[/ASCIIHexDecode /ASCII85Decode /FlateDecode]", data: Self.hex(Self.base85(PDFFixtures.flateZeros(3_000))))
        #expect(try Self.decodedByCoreGraphics(data) == 3_000)
        #expect(countsExactly(data, 3_000))
    }

    @Test("Counting stops where the data stops decoding")
    func countingStopsAtUndecodableData() {
        func codes(_ list: [Int]) -> Data { Self.lzwPack(list.map { ($0, 9) }) }
        // An LZW code past the next free entry, and data with no end-of-data code, end the count.
        #expect(Self.lzwCount(codes([256, 65, 66, 300, 67, 257])) == 2)
        #expect(Self.lzwCount(codes([256, 65, 66])) == 2)
        // ASCII85 stops at a character outside its alphabet.
        let base85 = Self.base85(Data(repeating: 0x41, count: 8)).dropLast(2) + Data("v".utf8) + Self.base85(Data(count: 8))
        #expect(countsExactly(PDFFixtures.raw([PDFFixtures.streamObject(1, dictionary: "<< /Filter /ASCII85Decode >>", data: base85)]), 8))
    }

    @Test("Inflating stops at a deadline that passes mid-stream")
    func inflateDeadline() {
        let zeros = PDFFixtures.flateZeros(20_000_000)
        zeros.withUnsafeBytes { raw in
            let body = raw.bindMemory(to: UInt8.self)
            #expect(PDFStreamBudget.Counting.inflated(body, cap: .max, deadline: .now - .seconds(1)) == nil)
            #expect(PDFStreamBudget.Counting.inflated(body, cap: .max, deadline: .now + .seconds(20)) == 20_000_000)
        }
    }

    private static func lzwCount(_ data: Data) -> Int? {
        data.withUnsafeBytes { PDFStreamBudget.Counting.lzw($0.bindMemory(to: UInt8.self), cap: .max) }
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

    /// Packs LZW codes, each with its bit width, most significant bit first.
    private static func lzwPack(_ codes: [(code: Int, width: Int)]) -> Data {
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for (code, width) in codes {
            buffer = buffer << width | code
            bits += width
            while bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(UInt8((buffer << (8 - bits)) & 0xFF)) }
        return Data(out)
    }

    /// LZW as PDF writes it by default (`/EarlyChange 1`): a code widens once the next free entry
    /// reaches the current width's range; with `earlyChange: false` (`/EarlyChange 0`) it widens
    /// one code later. Returns the data and the widest code used.
    private static func lzwEncode(_ input: [UInt8], earlyChange: Bool = true) -> (data: Data, width: Int) {
        var table = Dictionary(uniqueKeysWithValues: (0..<256).map { ([UInt8($0)], $0) })
        var next = 258
        var width = 9
        var codes: [(code: Int, width: Int)] = [(256, width)]
        var word: [UInt8] = []
        for byte in input {
            let extended = word + [byte]
            if table[extended] != nil {
                word = extended
                continue
            }
            codes.append((table[word] ?? 0, width))
            table[extended] = next
            next += 1
            if next - (earlyChange ? 0 : 1) >= 1 << width, width < 12 { width += 1 }
            word = [byte]
        }
        if !word.isEmpty { codes.append((table[word] ?? 0, width)) }
        codes.append((257, width))
        return (lzwPack(codes), width)
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
