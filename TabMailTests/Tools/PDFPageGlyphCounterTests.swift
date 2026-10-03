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
}
