/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import CoreGraphics
import Foundation
import PDFKit
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

    // MARK: - Streams a page reaches

    /// CCITT data that CoreGraphics decodes to 4,000,000 bytes: 4,000 all-white rows of 8,000
    /// pixels, one bit each.
    static let ccitt = (filter: "/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns 8000 >>", data: Data(repeating: 0xFF, count: 500))

    static let cmap = Data("/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0001> <0048> endbfchar endcmap end end".utf8)

    /// An image XObject CoreGraphics would decode to 4 MB if it decoded images to read text.
    private static let ccittImage = PDFFixtures.streamObject(
        20, dictionary: "<< /Type /XObject /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true /Length \(ccitt.data.count) \(ccitt.filter) >>",
        data: ccitt.data)

    private static func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }

    /// Where the stream under test sits, as reached from a page.
    enum PageRole: CaseIterable {
        case contents, contentsArray, form, iccColorSpace, indexedColorSpace, inlineImageColorSpace, group
    }

    /// A page that draws a CCITT image XObject and reaches stream 5 (`filter`, `data`) in `role`.
    static func pageDocument(_ role: PageRole, filter: String = "/Filter /FlateDecode", data: Data = PDFFixtures.flate(Data("q Q".utf8))) -> Data {
        var draw = "/Im1 Do"
        switch role {
        case .form: draw += " /Fm1 Do"
        case .iccColorSpace, .indexedColorSpace: draw += " /CS1 cs 0 sc"
        case .inlineImageColorSpace: draw += " BI /W 1 /H 1 /CS /CS1 /BPC 8 ID 0 EI"
        default: break
        }
        let colorSpace = role == .indexedColorSpace ? "[/Indexed /DeviceRGB 0 5 0 R]" : "[/ICCBased 5 0 R]"
        let usesColorSpace = [.iccColorSpace, .indexedColorSpace, .inlineImageColorSpace].contains(role)
        let resources = "/XObject << /Im1 20 0 R\(role == .form ? " /Fm1 5 0 R" : "") >>" + (usesColorSpace ? " /ColorSpace << /CS1 \(colorSpace) >>" : "")
        let contents = role == .contents ? "5 0 R" : role == .contentsArray ? "[4 0 R 5 0 R]" : "4 0 R"
        let group = role == .group ? " /Group << /S /Transparency /CS [/ICCBased 5 0 R] >>" : ""
        let extra = role == .form ? "/Type /XObject /Subtype /Form /BBox [0 0 1 1] " : role == .iccColorSpace || role == .inlineImageColorSpace || role == .group ? "/N 1 " : ""
        return PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << \(resources) >> /Contents \(contents)\(group) >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(draw.utf8.count) >>", data: Data(draw.utf8)),
            PDFFixtures.streamObject(5, dictionary: "<< \(extra)/Length \(data.count) \(filter) >>", data: data),
        ] + (6...19).map { object($0, "null") } + [ccittImage])
    }

    @Test("A page reaching a stream the budget cannot count is over budget, as content, form, colour space or group")
    func pageReachesUncountedStream() throws {
        for role in PageRole.allCases {
            let ccitt = try firstPage(Self.pageDocument(role, filter: Self.ccitt.filter, data: Self.ccitt.data))
            #expect(check(ccitt, 1_000_000) == .overBudget, "\(role)")
            // The control draws the CCITT image too: an image is never decoded to read text.
            let flate = try firstPage(Self.pageDocument(role))
            #expect(check(flate, 1_000_000) == .withinBudget, "\(role)")
        }
    }

    /// Where the stream under test sits, as reached from a font.
    enum FontRole: CaseIterable {
        case toUnicode, fontProgram, encoding, cidToGIDMap, type3Resources, extGStateFont, inForm, labelledImage
    }

    /// A page whose font `/F1` reaches stream 7 (`filter`, `data`) in `role`, drawing with `/F1`
    /// unless `drawsWith` names another font. A Type 3 `/F1` holds `type3Resources` (by default
    /// font 9, whose map is stream 7). `inherited` moves the resources to the page tree; `chain`
    /// links that many dictionaries from the resources.
    static func fontDocument(
        _ role: FontRole, filter: String = "/Filter /FlateDecode", data: Data = PDFFixtures.flate(cmap),
        type3Resources: String = "/Font << /F9 9 0 R >>", resources more: String = "", drawsWith font: String = "/F1",
        inherited: Bool = false, chain: Int = 0
    ) -> Data {
        let type3 = role == .type3Resources
        let content = type3 ? "BT \(font) 12 Tf 72 700 Td (a) Tj ET" : "BT \(font) 12 Tf 72 700 Td <0001> Tj ET"
        let toUnicode = [.toUnicode, .extGStateFont, .inForm, .labelledImage].contains(role) ? " /ToUnicode 7 0 R" : ""
        let type0 = "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding \(role == .encoding ? "7 0 R" : "/Identity-H") /DescendantFonts [6 0 R]\(toUnicode) >>"
        let image = role == .labelledImage ? " /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true" : ""
        let form = "BT /F1 12 Tf 2 20 Td <0001> Tj ET"
        var resources = role == .extGStateFont ? "/ExtGState << /GS1 10 0 R >> " : role == .inForm ? "/XObject << /Fm1 13 0 R >> " : "/Font << /F1 5 0 R /F2 12 0 R \(more)>> "
        if chain > 0 { resources += "/Next 14 0 R " }
        var objects = [
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1\(inherited ? " /Resources << \(resources)>>" : "") >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\(inherited ? "" : " /Resources << \(resources)>>") /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(content.utf8.count) >>", data: Data(content.utf8)),
            object(5, type3
                ? "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 11 0 R >> /Encoding << /Differences [97 /a] >> /FirstChar 97 /LastChar 97 /Widths [1000] /Resources << \(type3Resources) >> >>"
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

    @Test("An image a Type 3 glyph draws is not followed; the same stream reached as a font's map is")
    func type3ImageAndRoles() throws {
        let imageMap = Self.ccitt.filter + " /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true"
        // The Type 3 font's resources hold stream 7 as an image XObject: skipped.
        let image = Self.fontDocument(.type3Resources, filter: imageMap, data: Self.ccitt.data, type3Resources: "/XObject << /Im1 7 0 R >>")
        #expect(check(try firstPage(image), 1_000_000) == .withinBudget)
        // Font 9 is reached as the Type 3 font's /XObject dictionary, where its map passes as an
        // image entry, and, with /F3, as the page's font, where its map is checked.
        for more in ["", "/F3 9 0 R "] {
            let data = Self.fontDocument(.type3Resources, filter: imageMap, data: Self.ccitt.data, type3Resources: "/XObject 9 0 R", resources: more)
            #expect(check(try firstPage(data), 1_000_000) == (more.isEmpty ? .withinBudget : .overBudget), "\(more)")
        }
    }

    @Test("A font the page holds but never selects is checked too")
    func unusedFont() throws {
        let unused = Self.fontDocument(.labelledImage, filter: Self.ccitt.filter, data: Self.ccitt.data, drawsWith: "/F2")
        #expect(check(try firstPage(unused), 1_000_000) == .overBudget)
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, resources: "/F3 9 0 R ")), 1_000_000) == .withinBudget)
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

    @Test("Objects are each followed once, and nesting deeper than followed is over budget")
    func objectDepth() throws {
        // Object 8 refers to itself; followed again each time, it would pass the depth limit.
        #expect(check(try firstPage(Self.fontDocument(.toUnicode)), 1_000_000) == .withinBudget)
        // The resources are depth 0 and `/Next` link n is depth n.
        let limit = PDFPageGlyphCounter.Bounds.maxObjectDepth
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, chain: limit)), 1_000_000) == .withinBudget)
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, chain: limit + 1)), 1_000_000) == .overBudget)
    }

    @Test("Resources a page inherits from its page tree are checked")
    func inheritedResources() throws {
        let ccitt = Self.fontDocument(.toUnicode, filter: Self.ccitt.filter, data: Self.ccitt.data, inherited: true)
        #expect(check(try firstPage(ccitt), 1_000_000) == .overBudget)
        #expect(check(try firstPage(Self.fontDocument(.toUnicode, inherited: true)), 1_000_000) == .withinBudget)
    }

    /// A page whose `/XObject` dictionary (object 4) holds a CCITT image and a form; with
    /// `formResources`, the form's `/Resources` are that same dictionary.
    private static func xObjectsAsResources(_ formResources: Bool) -> Data {
        PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject 4 0 R >> /Contents 5 0 R >>"),
            object(4, "<< /Im1 6 0 R /Fm1 7 0 R >>"),
            PDFFixtures.streamObject(5, dictionary: "<< /Length 7 >>", data: Data("/Fm1 Do".utf8)),
            PDFFixtures.streamObject(
                6, dictionary: "<< /Type /XObject /Subtype /Image /Width 8000 /Height 4000 /BitsPerComponent 1 /ImageMask true /Length \(ccitt.data.count) \(ccitt.filter) >>",
                data: ccitt.data),
            PDFFixtures.streamObject(
                7, dictionary: "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] \(formResources ? "/Resources 4 0 R " : "")/Length 0 >>",
                data: Data()),
        ])
    }

    @Test("A dictionary reached as an /XObject dictionary and again as plain resources is checked in each role")
    func dictionaryInTwoRoles() throws {
        // The second visit is nested inside the first, so it comes second whatever the key order.
        #expect(check(try firstPage(Self.xObjectsAsResources(true)), 1_000_000) == .overBudget)
        #expect(check(try firstPage(Self.xObjectsAsResources(false)), 1_000_000) == .withinBudget)
    }

    @Test("A page whose page tree loops without reaching resources is over budget")
    func parentLoop() throws {
        func document(_ loop: Bool) -> Data {
            PDFFixtures.document([
                Self.object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                Self.object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 \(loop ? "/Parent 2 0 R " : "")>>"),
                Self.object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"),
            ])
        }
        #expect(check(try firstPage(document(true)), 1_000_000) == .overBudget)
        #expect(check(try firstPage(document(false)), 1_000_000) == .withinBudget)
    }

    @Test("A deadline that passes while a page's objects are checked is a timeout, not over budget")
    func deadlineWhileWalking() throws {
        // A million array entries take the walk a large fraction of a second.
        let data = PDFFixtures.document([
            Self.object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            Self.object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            Self.object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Big 4 0 R >> >>"),
            Self.object(4, "[\(String(repeating: "0 ", count: 1_000_000))]"),
        ])
        let page = try firstPage(data)
        #expect(check(page, 1_000_000, deadline: .now + .milliseconds(50)) == .timedOut)
        #expect(check(try firstPage(data), 1_000_000) == .withinBudget)
    }

    /// The page draws form A (directly, or with `outer` through form P), and A draws `/B`. `aEntry`
    /// is what A's dictionary adds (its `/Resources`, a decoy, or nothing); the page's `/B` draws
    /// `pageB`, and P's `/B` draws `outerB`.
    private static func formNamingB(aEntry: String, pageB: String, outerB: String = "SMALL", outer: Bool = false) -> Data {
        func form(_ number: Int, _ entry: String, _ content: String) -> Data {
            PDFFixtures.streamObject(
                number, dictionary: "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] \(entry) /Length \(content.utf8.count) >>",
                data: Data(content.utf8))
        }
        func text(_ string: String) -> String { "BT /F1 12 Tf 72 700 Td (\(string)) Tj ET" }
        let font = "/Resources << /Font << /F1 5 0 R >> >>"
        let content = outer ? "/P Do" : "/A Do"
        return PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /A 6 0 R /P 9 0 R /B 7 0 R >> >> /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(content.utf8.count) >>", data: Data(content.utf8)),
            object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            form(6, aEntry, "/B Do"),
            form(7, font, text(pageB)),
            form(8, font, text("DECOY")),
            form(9, "/Resources << /XObject << /A 6 0 R /B 10 0 R >> >>", "/A Do"),
            form(10, font, text(outerB)),
        ])
    }

    @Test("A form names other forms through the resources PDFKit uses: its own, or else those of the stream drawing it")
    func formResourcesAsPDFKitResolvesThem() throws {
        let heavy = "HEAVY" + String(repeating: "x", count: 1_995)
        let cases: [(label: String, data: Data, drawn: String?, verdict: PDFPageGlyphCounter.Verdict)] = [
            ("A without resources", Self.formNamingB(aEntry: "", pageB: heavy), "HEAVY", .overBudget),
            ("A without resources, small", Self.formNamingB(aEntry: "", pageB: "SMALL"), "SMALL", .withinBudget),
            ("an /XObject key in A's own dictionary", Self.formNamingB(aEntry: "/XObject << /B 8 0 R >>", pageB: heavy), "HEAVY", .overBudget),
            ("A's own resources lack B", Self.formNamingB(aEntry: "/Resources << >>", pageB: heavy), nil, .withinBudget),
            ("A's own resources name B", Self.formNamingB(aEntry: "/Resources << /XObject << /B 8 0 R >> >>", pageB: heavy), "DECOY", .withinBudget),
            ("P's B, heavy", Self.formNamingB(aEntry: "", pageB: "SMALL", outerB: heavy, outer: true), "HEAVY", .overBudget),
            ("P's B, small", Self.formNamingB(aEntry: "", pageB: heavy, outerB: "SMALL", outer: true), "SMALL", .withinBudget),
        ]
        for (label, data, drawn, verdict) in cases {
            // PDFKit itself is the oracle for which form A's `/B` draws.
            let text = PDFDocument(data: data)?.page(at: 0)?.string ?? ""
            for marker in ["HEAVY", "SMALL", "DECOY"] {
                #expect(text.contains(marker) == (marker == drawn), "\(label): \(marker)")
            }
            #expect(check(try firstPage(data), 1_000) == verdict, "\(label)")
        }
    }
}

