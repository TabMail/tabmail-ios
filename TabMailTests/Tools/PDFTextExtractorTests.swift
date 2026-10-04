/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PDFTextExtractor")
struct PDFTextExtractorTests {

    private func limits(maxPages: Int = 20, maxOutputChars: Int = 100_000, timeout: Duration = .seconds(20),
                        streamCaps: PDFStreamBudget.Caps? = nil, maxPageTextBytes: Int? = nil) -> PDFTextExtractor.Limits {
        let defaults = PDFTextExtractor.Limits(maxPages: maxPages, maxOutputChars: maxOutputChars, timeout: timeout)
        return PDFTextExtractor.Limits(
            maxPages: maxPages, maxOutputChars: maxOutputChars, timeout: timeout,
            streamCaps: streamCaps ?? defaults.streamCaps,
            maxPageTextBytes: maxPageTextBytes ?? defaults.maxPageTextBytes)
    }

    private func extract(_ data: Data, start: Int = 1, end: Int? = nil,
                         limits: PDFTextExtractor.Limits? = nil) async -> PDFTextExtractor.Outcome {
        await PDFTextExtractor.extract(data: data, startPage: start, endPage: end, limits: limits ?? self.limits())
    }

    private func pages(_ outcome: PDFTextExtractor.Outcome) -> PDFTextExtractor.Pages? {
        if case .ok(let pages) = outcome { return pages }
        return nil
    }

    // MARK: - Signature

    @Test("Signature is found at the start or after leading junk inside the window")
    func signatureWindow() {
        #expect(PDFTextExtractor.hasPdfSignature(Data("%PDF-1.7\n".utf8), scanBytes: 1024))
        #expect(PDFTextExtractor.hasPdfSignature(Data((String(repeating: "x", count: 100) + "%PDF-1.4").utf8), scanBytes: 1024))
        #expect(!PDFTextExtractor.hasPdfSignature(Data((String(repeating: "x", count: 100) + "%PDF-1.4").utf8), scanBytes: 104))
        #expect(PDFTextExtractor.hasPdfSignature(Data((String(repeating: "x", count: 100) + "%PDF-1.4").utf8), scanBytes: 105))
        #expect(!PDFTextExtractor.hasPdfSignature(Data("PK\u{03}\u{04} not a pdf".utf8), scanBytes: 1024))
        #expect(!PDFTextExtractor.hasPdfSignature(Data("%PDF".utf8), scanBytes: 1024))
        #expect(!PDFTextExtractor.hasPdfSignature(Data(), scanBytes: 1024))
    }

    // MARK: - Text

    @Test("Reads the text of every page with its page number")
    func readsText() async throws {
        let data = PDFFixtures.make([.text("Alpha first page"), .text("Bravo second page")])
        let result = try #require(pages(await extract(data)))
        #expect(result.totalPages == 2)
        #expect(result.firstPage == 1)
        #expect(result.lastPage == 2)
        #expect(result.nextStartPage == nil)
        #expect(result.cutPage == nil)
        #expect(!result.stoppedAtOutputLimit)
        try #require(result.pages.count == 2)
        #expect(result.pages[0].page == 1)
        #expect(result.pages[0].text.contains("Alpha first page"))
        #expect(result.pages[1].page == 2)
        #expect(result.pages[1].text.contains("Bravo second page"))
        #expect(!result.pages[0].unreadable)
    }

    @Test("CJK text is extracted as the original characters")
    func cjkText() async throws {
        let data = PDFFixtures.make([.text("請求書の合計金額 中文测试 한국어")])
        let result = try #require(pages(await extract(data)))
        try #require(result.pages.count == 1)
        #expect(result.pages[0].text.contains("請求書の合計金額"))
        #expect(result.pages[0].text.contains("中文测试"))
        #expect(result.pages[0].text.contains("한국어"))
    }

    @Test("Empty and image-only pages yield no text and are not unreadable")
    func imageOnlyPages() async throws {
        let data = PDFFixtures.make([.image, .empty])
        let result = try #require(pages(await extract(data)))
        try #require(result.pages.count == 2)
        #expect(result.pages.allSatisfy { $0.text.isEmpty && !$0.unreadable })
    }

    // MARK: - Page range

    @Test("A page range reads only those pages and points at the next one")
    func pageRange() async throws {
        let data = PDFFixtures.make((1...5).map { .text("Content of page \($0)") })
        let result = try #require(pages(await extract(data, start: 2, end: 3)))
        #expect(result.firstPage == 2)
        #expect(result.lastPage == 3)
        #expect(result.pages.map(\.page) == [2, 3])
        #expect(result.pages[0].text.contains("Content of page 2"))
        #expect(result.nextStartPage == 4)
    }

    @Test("An end page past the document is clamped to the last page")
    func endClamped() async throws {
        let data = PDFFixtures.make([.text("one"), .text("two")])
        let result = try #require(pages(await extract(data, start: 1, end: 50)))
        #expect(result.lastPage == 2)
        #expect(result.nextStartPage == nil)
    }

    @Test("The page cap bounds one call and the next call continues")
    func pageCap() async throws {
        let data = PDFFixtures.make((1...7).map { .text("Page number \($0)") })
        let first = try #require(pages(await extract(data, limits: limits(maxPages: 3))))
        #expect(first.pages.map(\.page) == [1, 2, 3])
        #expect(first.nextStartPage == 4)
        #expect(!first.stoppedAtOutputLimit)

        let last = try #require(pages(await extract(data, start: 7, limits: limits(maxPages: 3))))
        #expect(last.pages.map(\.page) == [7])
        #expect(last.nextStartPage == nil)
    }

    @Test("A start page past the end reports the page count")
    func pastEnd() async {
        let data = PDFFixtures.make([.text("one"), .text("two")])
        #expect(await extract(data, start: 3) == .pastEnd(totalPages: 2))
    }

    // MARK: - Output limit

    @Test("A page that would overflow the text limit is left for the next call")
    func stopsBeforeOverflowingPage() async throws {
        let data = PDFFixtures.make([.text("Alpha"), .text("Bravo"), .text("Charlie Delta Echo Foxtrot")])
        let result = try #require(pages(await extract(data, limits: limits(maxOutputChars: 15))))
        #expect(result.pages.map(\.page) == [1, 2])
        #expect(result.stoppedAtOutputLimit)
        #expect(result.nextStartPage == 3)
        #expect(result.cutPage == nil)
        let used = result.pages.reduce(0) { $0 + $1.text.utf16.count }
        #expect(used <= 15)
    }

    @Test("Pages that end exactly at the text limit are kept whole")
    func exactlyAtOutputLimit() async throws {
        let data = PDFFixtures.make([.text("Alpha"), .text("Bravo"), .text("Charlie")])
        let result = try #require(pages(await extract(data, limits: limits(maxOutputChars: 10))))
        #expect(result.pages.map(\.text) == ["Alpha", "Bravo"])
        #expect(result.cutPage == nil)
        #expect(result.stoppedAtOutputLimit)
        #expect(result.nextStartPage == 3)
    }

    @Test("A first page longer than the limit is cut so the call still makes progress")
    func cutsFirstPage() async throws {
        let long = String(repeating: "Lorem ipsum dolor sit amet ", count: 20)
        let data = PDFFixtures.make([.text(long), .text("next")])
        let result = try #require(pages(await extract(data, limits: limits(maxOutputChars: 40))))
        try #require(result.pages.count == 1)
        #expect(result.cutPage == 1)
        #expect(result.pages[0].text.utf16.count == 40)
        let cutFrom = try #require(result.pages[0].cutFrom)
        #expect(cutFrom > 40)
        #expect(!result.stoppedAtOutputLimit)
        #expect(result.nextStartPage == 2)
    }

    @Test("Cutting never splits a surrogate pair and counts UTF-16 units")
    func cutKeepsScalarsWhole() {
        #expect(PDFTextExtractor.cut("ab😀cd", toUTF16Length: 3) == "ab")
        #expect(PDFTextExtractor.cut("ab😀cd", toUTF16Length: 4) == "ab😀")
        #expect(PDFTextExtractor.cut("abc", toUTF16Length: 5) == "abc")
        #expect(PDFTextExtractor.cut("abcdef", toUTF16Length: 4) == "abcd")
    }

    @Test("Normalising unifies line breaks, drops spaces before them and trims")
    func normalize() {
        #expect(PDFTextExtractor.normalize("  one  \r\ntwo\t\rthree \n\n") == "one\ntwo\nthree")
    }

    // MARK: - Bad input

    @Test("Bytes with a PDF header but no document are malformed")
    func malformed() async {
        #expect(await extract(Data("%PDF-1.7\nthis is not a document\n%%EOF".utf8)) == .malformed)
        #expect(await extract(Data()) == .malformed)
    }

    @Test("A truncated PDF never crashes and is refused or read")
    func truncated() async {
        let full = PDFFixtures.make([.text("Alpha"), .text("Bravo")])
        let outcome = await extract(full.prefix(full.count / 2))
        switch outcome {
        case .malformed, .tooLarge, .ok: break
        default: Issue.record("unexpected outcome \(outcome)")
        }
    }

    @Test("A PDF with a user password is reported as encrypted")
    func userPassword() async {
        let data = PDFFixtures.make([.text("Secret text")], userPassword: "user-pass", ownerPassword: "owner-pass")
        #expect(await extract(data) == .encrypted)
    }

    @Test("A PDF with only an owner password opens and is read")
    func ownerPasswordOnly() async throws {
        let data = PDFFixtures.make([.text("Restricted but readable")], ownerPassword: "owner-pass")
        let result = try #require(pages(await extract(data)))
        #expect(result.pages.first?.text.contains("Restricted but readable") == true)
    }

    // MARK: - Memory bounds

    @Test("A file whose streams inflate past the cap is too large; the same file without it is read")
    func decompressionBomb() async throws {
        let document = PDFFixtures.make([.text("Alpha")])
        let bomb = PDFFixtures.streamObject(900, dictionary: "<< /Filter /FlateDecode >>", data: PDFFixtures.flateZeros(2_000_000))
        let capped = limits(streamCaps: PDFStreamBudget.Caps(streamBytes: 1_000_000, totalBytes: 10_000_000))
        #expect(await extract(document + bomb, limits: capped) == .tooLarge)
        let result = try #require(pages(await extract(document, limits: capped)))
        #expect(result.pages.first?.text == "Alpha")
    }

    @Test("A page drawing more text than the cap is left out as unreadable; other pages are read")
    func pageTextCap() async throws {
        let data = PDFFixtures.make([.text("Alpha"), .text(String(repeating: "Bravo ", count: 20)), .text("Charlie")])
        let result = try #require(pages(await extract(data, limits: limits(maxPageTextBytes: 50))))
        #expect(result.pages.map(\.text) == ["Alpha", "", "Charlie"])
        #expect(result.pages.map(\.unreadable) == [false, true, false])
        #expect(result.nextStartPage == nil)

        let uncapped = try #require(pages(await extract(data)))
        #expect(uncapped.pages.allSatisfy { !$0.unreadable })
    }

    @Test("A document whose title has a percent sign and then the word stream is read")
    func percentAndStreamInTitle() async throws {
        let titled = PDFFixtures.make([.text("Alpha")], title: "Revenue grew 12% in each stream")
        let result = try #require(pages(await extract(titled)))
        #expect(result.pages.map(\.text) == ["Alpha"])
    }

    @Test("A page reaching a CCITT stream as a font map, content or colour space is left out as unreadable before PDFKit decodes it")
    func pageReachingCCITTStream() async throws {
        let ccitt = PDFPageGlyphCounterTests.ccitt
        let bombs = [PDFPageGlyphCounterTests.fontDocument(.toUnicode, filter: ccitt.filter, data: ccitt.data)]
            + [.contents, .form, .iccColorSpace].map { PDFPageGlyphCounterTests.pageDocument($0, filter: ccitt.filter, data: ccitt.data) }
        for bomb in bombs {
            let refused = try #require(pages(await extract(bomb)))
            #expect(refused.pages.map(\.unreadable) == [true])
        }
        let controls = [PDFPageGlyphCounterTests.fontDocument(.toUnicode)]
            + [.contents, .form, .iccColorSpace].map { PDFPageGlyphCounterTests.pageDocument($0) }
        for control in controls {
            let read = try #require(pages(await extract(control)))
            #expect(read.pages.map(\.unreadable) == [false])
        }
    }

    // MARK: - Deadline

    @Test("A passed deadline returns timeout")
    func timeout() async {
        let data = PDFFixtures.make([.text("Alpha")])
        #expect(await extract(data, limits: limits(timeout: .zero)) == .timeout)
    }

    @Test("A deadline that passes inside PDFKit's read of a page returns timeout without waiting for it")
    func deadlineInsidePDFKit() async {
        // 190,000 glyphs are under the per-page cap, and counting them takes well under a
        // millisecond; PDFKit takes most of a second to read them, cannot be interrupted, and no
        // later check sees the deadline, so only `withTimeout` reports it.
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        let content = Data("BT /F1 1 Tf 0 0 Td (\(String(repeating: "a", count: 190_000))) Tj ET".utf8)
        let data = PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Length \(content.count) >>", data: content),
            object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ])
        #expect(await extract(data, limits: limits(timeout: .milliseconds(200))) == .timeout)
        #expect(pages(await extract(data)) != nil)
    }

    @Test("A deadline that passes while a page's text is counted stops the read with a timeout")
    func deadlineWhileCounting() throws {
        // Twenty million operators take the counter a large fraction of a second; inflating the
        // stream and opening the file take a few milliseconds. Read directly, without the
        // `withTimeout` that would report the timeout on its own.
        func object(_ number: Int, _ body: String) -> Data { Data("\(number) 0 obj\n\(body)\nendobj\n".utf8) }
        let content = PDFFixtures.flate(Data(String(repeating: "q Q ", count: 10_000_000).utf8))
        let data = PDFFixtures.document([
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Filter /FlateDecode >>", data: content),
        ])
        let outcome = PDFTextExtractor.readPages(
            data: data, startPage: 1, endPage: nil, limits: limits(), deadline: .now + .milliseconds(200))
        #expect(outcome == .timeout)
    }
}
