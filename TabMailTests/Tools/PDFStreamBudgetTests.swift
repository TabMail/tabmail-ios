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
