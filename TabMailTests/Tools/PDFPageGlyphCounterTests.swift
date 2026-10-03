/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import CoreGraphics
import Foundation
@testable import TabMail

/// `PDFPageGlyphCounter` keeps pages that draw too much text away from `PDFPage.string`.
@Suite("PDFPageGlyphCounter")
struct PDFPageGlyphCounterTests {

    /// A one-page file whose content draws `content` and may invoke a form `/Fm1` drawing `form`.
    private func page(content: String, form: String = "") throws -> CGPDFPage {
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        let data = PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(content.utf8.count) >>", data: Data(content.utf8)),
            PDFFixtures.streamObject(5, dictionary: "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Length \(form.utf8.count) >>", data: Data(form.utf8)),
        ])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        return try #require(document.page(at: 1))
    }

    private func check(_ page: CGPDFPage, _ maxBytes: Int, deadline: ContinuousClock.Instant = .now + .seconds(20)) -> PDFPageGlyphCounter.Verdict {
        PDFPageGlyphCounter.check(page, maxBytes: maxBytes, deadline: deadline)
    }

    @Test("Every text-showing operator counts, up to exactly the cap")
    func countsShownStrings() throws {
        // Tj 5 + ' 3 + " 2 + TJ 4 = 14 bytes; the numbers in TJ and " are not text.
        let page = try page(content: "BT (Alpha) Tj (abc) ' 1 2 (xy) \" [(ab) -250 (cd)] TJ ET")
        #expect(check(page, 14) == .withinBudget)
        #expect(check(page, 13) == .overBudget)
    }

    @Test("Text in a form counts each time the form is drawn")
    func countsForms() throws {
        let page = try page(content: "/Fm1 Do /Fm1 Do /Fm1 Do", form: "BT (Alpha) Tj ET")
        #expect(check(page, 15) == .withinBudget)
        #expect(check(page, 14) == .overBudget)
    }

    @Test("Every invocation of a form counts, however many there are")
    func manyFormInvocations() throws {
        // 3,000 invocations of a 5-byte form: 15,000 bytes.
        let page = try page(content: String(repeating: "/Fm1 Do ", count: 3_000), form: "BT (abcde) Tj ET")
        #expect(check(page, 15_000) == .withinBudget)
        #expect(check(page, 14_999) == .overBudget)
    }

    @Test("Forms nested deeper than the counter follows are over budget")
    func formsNestedTooDeep() throws {
        let limit = PDFPageGlyphCounter.Bounds.maxFormDepth
        #expect(check(try nestedForms(limit), 1_000_000) == .withinBudget)
        #expect(check(try nestedForms(limit + 1), 1_000_000) == .overBudget)
    }

    /// A page drawing form 1, which draws form 2, and so on to form `depth`, which draws text.
    private func nestedForms(_ depth: Int) throws -> CGPDFPage {
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        var objects = [
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length 7 >>", data: Data("/Fm1 Do".utf8)),
        ]
        for level in 1...depth {
            let number = 4 + level
            let content = level == depth ? "BT (a) Tj ET" : "/Fm1 Do"
            let resources = level == depth ? "" : "/Resources << /XObject << /Fm1 \(number + 1) 0 R >> >> "
            objects.append(PDFFixtures.streamObject(
                number, dictionary: "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] \(resources)/Length \(content.utf8.count) >>",
                data: Data(content.utf8)))
        }
        let provider = try #require(CGDataProvider(data: PDFFixtures.document(objects) as CFData))
        return try #require(CGPDFDocument(provider)?.page(at: 1))
    }

    @Test("A passed deadline stops the count")
    func deadline() throws {
        let page = try page(content: String(repeating: "q Q ", count: 600))
        #expect(check(page, 1_000, deadline: .now - .seconds(1)) == .timedOut)
        #expect(check(page, 1_000) == .withinBudget)
        // A page too short to reach the in-scan check is still not counted after the deadline.
        let short = try self.page(content: "BT (a) Tj ET")
        #expect(check(short, 1_000, deadline: .now - .seconds(1)) == .timedOut)
        #expect(check(short, 1_000) == .withinBudget)
    }

    // MARK: - Streams a font reaches

    /// Where the stream under test sits.
    enum FontRole: CaseIterable {
        case toUnicode, fontProgram, encoding, cidToGIDMap, type3Resources, extGStateFont, inForm, labelledImage
    }

    /// CCITT data that CoreGraphics decodes to 4,000,000 bytes: 4,000 all-white rows of 8,000
    /// pixels, one bit each.
    static let ccitt = (filter: "/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns 8000 >>", data: Data(repeating: 0xFF, count: 500))

    static let cmap = Data("/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0001> <0048> endbfchar endcmap end end".utf8)

    /// A page whose font `/F1` reaches stream 7 (`filter`, `data`) in `role`. The page also has a
    /// Helvetica `/F2` and the Type 3 font's inner font as `/F3`, and draws with `/F1` unless
    /// `drawsWith` names another font; a Type 3 page then draws `more`.
    static func fontDocument(
        _ role: FontRole, filter: String = "/Filter /FlateDecode", data: Data = PDFFixtures.flate(cmap),
        drawsWith font: String = "/F1", then more: String = "", chain: Int = 0
    ) -> Data {
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        let type3 = role == .type3Resources
        let content: String
        switch role {
        case .extGStateFont: content = "BT /GS1 gs 72 700 Td <0001> Tj ET"
        case .inForm: content = "/Fm1 Do"
        case .type3Resources: content = "BT \(font) 12 Tf 72 700 Td (a) Tj \(more)ET"
        default: content = "BT \(font) 12 Tf 72 700 Td <0001> Tj ET"
        }
        let toUnicode = [.toUnicode, .extGStateFont, .inForm, .labelledImage].contains(role) ? " /ToUnicode 7 0 R" : ""
        let next = chain > 0 ? " /Next 14 0 R" : ""
        let type0 = "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding \(role == .encoding ? "7 0 R" : "/Identity-H") /DescendantFonts [6 0 R]\(toUnicode)\(next) >>"
        let image = role == .labelledImage ? " /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true" : ""
        let form = "BT /F1 12 Tf 2 20 Td <0001> Tj ET"
        var objects = [
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R /F2 12 0 R /F3 9 0 R >> /ExtGState << /GS1 10 0 R >> /XObject << /Fm1 13 0 R >> >> /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(content.utf8.count) >>", data: Data(content.utf8)),
            object(5, type3
                ? "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 11 0 R >> /Encoding << /Differences [97 /a] >> /FirstChar 97 /LastChar 97 /Widths [1000] /Resources << /Font << /F9 9 0 R >> >> >>"
                : type0),
            object(6, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 8 0 R\(role == .cidToGIDMap ? " /CIDToGIDMap 7 0 R" : "") >>"),
            PDFFixtures.streamObject(7, dictionary: "<< /Length \(data.count) \(filter)\(image) >>", data: data),
            object(8, "<< /Type /FontDescriptor /FontName /X /Flags 4 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /Self 8 0 R\(role == .fontProgram ? " /FontFile2 7 0 R" : "") >>"),
            object(9, "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>"),
            object(10, "<< /Type /ExtGState /Font [5 0 R 12] >>"),
            PDFFixtures.streamObject(11, dictionary: "<< /Length 9 >>", data: Data("1000 0 d0".utf8)),
            object(12, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            PDFFixtures.streamObject(13, dictionary: "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Length \(form.utf8.count) >>", data: Data(form.utf8)),
        ]
        for link in 0..<chain {
            objects.append(object(14 + link, link == chain - 1 ? "<< >>" : "<< /Next \(15 + link) 0 R >>"))
        }
        return PDFFixtures.document(objects)
    }

    private func firstPage(_ data: Data) throws -> CGPDFPage {
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider)?.page(at: 1))
    }

    @Test("A font reaching a stream the budget cannot count is over budget, in every role CoreGraphics decodes it")
    func fontReachesUncountedStream() throws {
        for role in FontRole.allCases {
            let ccitt = try firstPage(Self.fontDocument(role, filter: Self.ccitt.filter, data: Self.ccitt.data))
            #expect(check(ccitt, 1_000_000) == .overBudget, "\(role)")
            let flate = try firstPage(Self.fontDocument(role))
            #expect(check(flate, 1_000_000) == .withinBudget, "\(role)")
        }
    }

    @Test("Every filter the budget cannot count is refused in a font, and every filter it counts is not")
    func fontStreamFilters() throws {
        for filter in ["/Filter /CCITTFaxDecode", "/Filter /CCF", "/Filter /JBIG2Decode", "/Filter /DCTDecode",
                       "/Filter /JPXDecode", "/Filter [/FlateDecode /CCITTFaxDecode]", "/Filter [/FlateDecode /LZWDecode]",
                       "/Filter /Crypt", "/Filter [/FlateDecode 5]", "/Filter 5"] {
            #expect(check(try firstPage(Self.fontDocument(.toUnicode, filter: filter)), 1_000_000) == .overBudget, "\(filter)")
        }
        for filter in ["", "/Filter /FlateDecode", "/Filter /Fl", "/Filter [/ASCII85Decode /FlateDecode]",
                       "/Filter /LZWDecode", "/Filter /RunLengthDecode", "/Filter /ASCIIHexDecode"] {
            #expect(check(try firstPage(Self.fontDocument(.toUnicode, filter: filter)), 1_000_000) == .withinBudget, "\(filter)")
        }
    }

    @Test("A font the page never selects and an image a Type 3 glyph draws are not followed")
    func unusedFontAndType3Image() throws {
        let unused = try firstPage(Self.fontDocument(.toUnicode, filter: Self.ccitt.filter, data: Self.ccitt.data, drawsWith: "/F2"))
        #expect(check(unused, 1_000_000) == .withinBudget)
        let used = try firstPage(Self.fontDocument(.toUnicode, filter: Self.ccitt.filter, data: Self.ccitt.data, drawsWith: "/F1"))
        #expect(check(used, 1_000_000) == .overBudget)

        // The Type 3 font's resources hold stream 7 as an image XObject; reached so, it is skipped.
        var data = Self.fontDocument(.type3Resources, filter: Self.ccitt.filter + " /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true", data: Self.ccitt.data)
        data = try #require(String(data: data, encoding: .isoLatin1)?
            .replacingOccurrences(of: "/Resources << /Font << /F9 9 0 R >> >>", with: "/Resources << /XObject << /Im1 7 0 R >> >>")
            .data(using: .isoLatin1))
        #expect(check(try firstPage(data), 1_000_000) == .withinBudget)

        // Font 9 is first followed as the Type 3 font's /XObject dictionary, where its map passes
        // as an image entry; selected next as /F3, its map is still checked as a font's.
        let imageMap = Self.ccitt.filter + " /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true"
        for more in ["", "/F3 12 Tf <0001> Tj "] {
            data = Self.fontDocument(.type3Resources, filter: imageMap, data: Self.ccitt.data, then: more)
            data = try #require(String(data: data, encoding: .isoLatin1)?
                .replacingOccurrences(of: "/Resources << /Font << /F9 9 0 R >> >>", with: "/Resources << /XObject 9 0 R >>")
                .data(using: .isoLatin1))
            #expect(check(try firstPage(data), 1_000_000) == (more.isEmpty ? .withinBudget : .overBudget), "\(more)")
        }
    }

    @Test("A CCITT map CoreGraphics decodes past the stream cap is refused, though the stream budget cannot count it")
    func ccittMapOracle() throws {
        let data = Self.fontDocument(.toUnicode, filter: Self.ccitt.filter, data: Self.ccitt.data)
        let caps = PDFStreamBudget.Caps(streamBytes: 1_000_000, totalBytes: 2_000_000)
        #expect(PDFStreamBudget.check(data, caps: caps, deadline: .now + .seconds(20)) == .withinBudget)

        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: 1))
        let decoded = try withExtendedLifetime(page) { () -> Int in
            let pageDictionary = try #require(page.dictionary)
            var resources: CGPDFDictionaryRef?
            var fonts: CGPDFDictionaryRef?
            var font: CGPDFDictionaryRef?
            var map: CGPDFStreamRef?
            try #require(CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources))
            try #require(CGPDFDictionaryGetDictionary(try #require(resources), "Font", &fonts))
            try #require(CGPDFDictionaryGetDictionary(try #require(fonts), "F1", &font))
            try #require(CGPDFDictionaryGetStream(try #require(font), "ToUnicode", &map))
            var format = CGPDFDataFormat.raw
            return (CGPDFStreamCopyData(try #require(map), &format) as Data?)?.count ?? 0
        }
        #expect(decoded > caps.streamBytes)
        #expect(check(page, 1_000_000) == .overBudget)
    }

    @Test("A font's objects are each followed once, and nesting deeper than followed is over budget")
    func fontObjectDepth() throws {
        // Object 8 refers to itself; followed again each time, it would pass the depth limit.
        #expect(check(try firstPage(Self.fontDocument(.toUnicode)), 1_000_000) == .withinBudget)
        // The font is depth 0 and `/Next` link n is depth n.
        let limit = PDFPageGlyphCounter.Bounds.maxFontDepth
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, chain: limit)), 1_000_000) == .withinBudget)
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, chain: limit + 1)), 1_000_000) == .overBudget)
    }
}
