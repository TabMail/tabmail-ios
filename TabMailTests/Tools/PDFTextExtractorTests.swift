/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

@Suite("PDFTextExtractor")
struct PDFTextExtractorTests {

    private func limits(maxPages: Int = 20, maxOutputChars: Int = 100_000, timeout: Duration = .seconds(20)) -> PDFTextExtractor.Limits {
        PDFTextExtractor.Limits(maxPages: maxPages, maxOutputChars: maxOutputChars, timeout: timeout)
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

    @Test("A cut first page keeps a character outside the BMP whole and counts UTF-16 units")
    func cutKeepsScalarsWhole() async throws {
        // U+2000B is two UTF-16 units; a cut after "ab" plus one unit would split it.
        let data = PDFFixtures.make([.text("ab\u{2000B}cdefgh")])
        let whole = try #require(pages(await extract(data)))
        try #require(whole.pages.first?.text == "ab\u{2000B}cdefgh")

        let three = try #require(pages(await extract(data, limits: limits(maxOutputChars: 3))))
        #expect(three.pages.first?.text == "ab")
        #expect(three.pages.first?.cutFrom == 10)
        let four = try #require(pages(await extract(data, limits: limits(maxOutputChars: 4))))
        #expect(four.pages.first?.text == "ab\u{2000B}")
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
        case .malformed, .failed, .ok: break
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

    @Test("A page pdf.js cannot read is unreadable, and the document still opens")
    func unreadablePage() async throws {
        // The page tree names itself as its own kid: pdf.js counts one page and fails to load it.
        let data = PDFFixtures.document([
            PDFFixtures.object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFFixtures.object(2, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>"),
        ])
        let result = try #require(pages(await extract(data)))
        #expect(result.totalPages == 1)
        #expect(result.pages.map(\.unreadable) == [true])
        #expect(result.pages.map(\.text) == [""])
    }

    // MARK: - Isolation

    @Test("A decompression bomb is read in the WebContent process: the app's own memory stays flat")
    func decompressionBombStaysOutOfTheApp() async throws {
        // A /ToUnicode map that maps "A" to "Z" after 200 MB of padding, about 200 KB compressed.
        // "Zlpha" proves pdf.js inflated and read all of it; before ADR-IOS-088, CoreGraphics
        // inflated such a map inside the app.
        let mapped = try #require(pages(await extract(PDFFixtures.textDocument("Alpha", toUnicode: Self.aToZ(padding: 0)))))
        #expect(mapped.pages.map(\.text) == ["Zlpha"])
        let bomb = PDFFixtures.textDocument("Alpha", toUnicode: Self.aToZ(padding: 200_000_000))

        let before = PDFFixtures.footprint()
        let peak = Peak()
        let sampler = Task {
            while !Task.isCancelled {
                peak.record(PDFFixtures.footprint())
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let outcome = await extract(bomb)
        sampler.cancel()
        let read = try #require(pages(outcome))
        #expect(read.pages.map(\.text) == ["Zlpha"])
        #expect(peak.value - before < 64 * 1024 * 1024, "app footprint grew \(peak.value - before) bytes")
    }

    /// A flate-filtered CMap mapping byte 0x41 ("A") to "Z", after `padding` spaces.
    private static func aToZ(padding: Int) -> Data {
        let map = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /AtoZ def
            1 begincodespacerange <00> <FF> endcodespacerange
            1 beginbfchar <41> <005A> endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
        return PDFFixtures.flate(Data(repeating: UInt8(ascii: " "), count: padding) + Data(map.utf8))
    }

    // MARK: - Deadline

    @Test("A passed deadline returns timeout")
    func timeout() async {
        let data = PDFFixtures.make([.text("Alpha")])
        #expect(await extract(data, limits: limits(timeout: .zero)) == .timeout)
    }

    @Test("A deadline that passes while pdf.js is busy in one step returns timeout without waiting for it")
    func deadlineWhileParsing() async {
        // Ten million operators in one flate content stream take pdf.js seconds to scan.
        let content = PDFFixtures.flate(Data(String(repeating: "q Q ", count: 10_000_000).utf8))
        let data = PDFFixtures.document([
            PDFFixtures.object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFFixtures.object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFFixtures.object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>"),
            PDFFixtures.streamObject(4, dictionary: "<< /Filter /FlateDecode >>", data: content),
        ])
        let start = ContinuousClock.now
        #expect(await extract(data, limits: limits(timeout: .milliseconds(500))) == .timeout)
        #expect(ContinuousClock.now - start < .milliseconds(500) + AttachmentReadPdfTool.Config.hostTeardownGrace)
    }
}

/// The largest value recorded, shared with the sampling task.
private final class Peak: Sendable {
    private let state = Mutex<UInt64>(0)
    func record(_ value: UInt64) { state.withLock { $0 = max($0, value) } }
    var value: UInt64 { state.withLock { $0 } }
}
