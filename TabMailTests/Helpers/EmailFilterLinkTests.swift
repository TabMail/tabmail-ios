/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("HTML link text conversion")
struct EmailFilterLinkTests {
    @Test(arguments: [
        #"<a href="https://example.com/read">Read</a>"#,
        "<A HREF='https://example.com/read'>Read</A>",
        "<a href=https://example.com/read>Read</a>",
        "<a href=https://example.com/read title=details>Read</a>",
        "<a\rhref\u{0C}=\t\" https://example.com/read \" title=details>Read</a>",
        #"<a title="other href='wrong'" href="https://example.com/read"><b>Read</b></a>"#
    ])
    func preservesDestination(html: String) {
        #expect(EmailFilter.htmlToPlainText(html) == "[Read](https://example.com/read)")
        #expect(EmailFilter.extractPlainText(htmlBody: html, textBody: "Read") == "[Read](https://example.com/read)")
    }

    @Test func decodesAddressEntities() {
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/?a=1&amp;b=&#50;">A &amp; B</a>"#)
            == #"[A &amp; B](https://example.com/?a=1&amp;b=2)"#)
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/?a=1&custom;">Read</a>"#)
            == #"[Read](https://example.com/?a=1&amp;custom;)"#)
    }

    @Test func keepsMultipleLinksAndSurroundingText() {
        #expect(EmailFilter.htmlToPlainText(#"Before <a href="/one">One</a> and <a href="mailto:user@example.com">Email</a> after"#)
            == "Before [One](/one) and [Email](mailto:user@example.com) after")
    }

    @Test func omitsHiddenDestinations() {
        #expect(EmailFilter.htmlToPlainText(#"<head><a href="/head">Head</a></head><div style="display:none"><a href="/hidden">Hidden</a></div><a style="display:none" href="/also-hidden">Hidden</a><a href="/visible">Visible</a>"#)
            == "[Visible](/visible)")
    }

    @Test func noAddressRemainsText() {
        #expect(EmailFilter.htmlToPlainText(#"<a name="section">Section</a> <a href="">Empty</a>"#) == "Section Empty")
    }

    @Test func retainsEmptyAndUnclosedLinks() {
        #expect(EmailFilter.htmlToPlainText(#"<a href="/image"><img src="image.png"></a>"#) == "[](/image)")
        #expect(EmailFilter.htmlToPlainText(#"<a href="/open">Open"#) == "[Open](/open)")
    }

    @Test func escapesMarkdownDelimitersAndQuotedGreaterThan() {
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/a(b)>c">[Read]</a>"#)
            == #"[\[Read\]](https://example.com/a\(b\)>c)"#)
    }

    @Test(arguments: [
        (#"<a href="https://example.com/a b">Read</a>"#, "https://example.com/a%20b"),
        (#"<a href="https://example.com/a&#32;b">Read</a>"#, "https://example.com/a%20b"),
        (#"<a href="https://example.com/?x=&amp;copy;">Read</a>"#, "https://example.com/?x=&copy;"),
        (#"<a href="https://example.com/?x=&amp;amp;">Read</a>"#, "https://example.com/?x=&amp;"),
        (#"<a href="https://example.com/a(b)">Read</a>"#, "https://example.com/a(b)"),
        (#"<a href="https://example.com/a\b">Read</a>"#, "https://example.com/a%5Cb")
    ])
    func destinationRoundTrip(html: String, destination: String) throws {
        let output = EmailFilter.htmlToPlainText(html)
        let parsed = try AttributedString(markdown: output)
        #expect(String(parsed.characters) == "Read")
        #expect(parsed.runs.compactMap { $0.link?.absoluteString } == [destination])
    }

    @Test(arguments: [
        "<div data-value=don't>Visible message</div>",
        #"<div data-value=a=b"c>Visible message</div>"#,
        "<div title='quoted > value'>Visible message</div>"
    ])
    func attributeRecoveryPreservesBody(html: String) async {
        #expect(EmailFilter.extractPlainText(htmlBody: html, textBody: "Sibling") == "Visible message")
        let rendered = await BodyRenderer.render(ingredients: RawBodyIngredients(rawHTML: html, rawText: "Sibling", attachments: [], inlineImages: [], icsData: nil))
        #expect(rendered.textContent == "Visible message")
    }

    @Test func incompleteAndAdjacentAnchors() {
        #expect(EmailFilter.htmlToPlainText(#"<a href="/one">One<a href="/two">Two</a> tail"#)
            == "[One](/one) [Two](/two) tail")
        #expect(EmailFilter.htmlToPlainText(#"<a href="/one">One</a href="/wrong"> tail"#)
            == "[One](/one) tail")
        #expect(EmailFilter.htmlToPlainText(#"Visible<a href="/unfinished"#) == "Visible")
        #expect(EmailFilter.htmlToPlainText(#"<a href>Label</a> <a href= >Empty</a>"#) == "Label Empty")
    }

}
