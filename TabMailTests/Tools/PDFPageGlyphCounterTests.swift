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

    @Test("A passed deadline stops the count")
    func deadline() throws {
        let page = try page(content: String(repeating: "q Q ", count: 600))
        #expect(check(page, 1_000, deadline: .now - .seconds(1)) == .timedOut)
        #expect(check(page, 1_000) == .withinBudget)
    }
}
