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
            == #"[A &amp; B](https://example.com/?a=1&amp;b=&#50;)"#)
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/?a=1&custom;">Read</a>"#)
            == #"[Read](https://example.com/?a=1&custom;)"#)
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
        (#"<a href="https://example.com/?x=&sol;">Read</a>"#, "https://example.com/?x=/"),
        (#"<a href="https://example.com/?x=1&AMP;y=2">Read</a>"#, "https://example.com/?x=1&y=2"),
        (#"<a href="https://example.com/a\!b">Read</a>"#, "https://example.com/a%5C!b"),
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
        "<div data-value=a='b>Visible message</div>",
        "<div data-value=plain title='quoted > value'>Visible message</div>",
        "<div data-value='plain' title='quoted > value'>Visible message</div>",
        #"<div title="A > display:none">Visible message</div>"#,
        #"<div title="style='display:none'">Visible message</div>"#,
        #"<div data-style="display:none">Visible message</div>"#,
        #"<div style="background:url('>display:none')">Visible message</div>"#,
        #"<div style="background:url('x;display:none')">Visible message</div>"#,
        #"<div style="/* > display:none */ color:red">Visible message</div>"#,
        #"<div style="background:url(x;display:none)">Visible message</div>"#,
        #"<div style='background:url("x\";display:none")'>Visible message</div>"#,
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

    @Test func literalLabelsKeepBothAdjacentLinks() throws {
        let html = #"<a href="https://example.com/one">one `</a> and <a href="https://example.com/two">two `</a>"#
        let parsed = try AttributedString(markdown: EmailFilter.htmlToPlainText(html))
        #expect(String(parsed.characters) == "one ` and two `")
        #expect(parsed.runs.compactMap { $0.link?.absoluteString } == ["https://example.com/one", "https://example.com/two"])
    }

    @Test(arguments: [#"A \* B"#, "*literal*", "_literal_", "`literal`", "[literal]"])
    func literalLabelRoundTrip(label: String) throws {
        let html = "<a href='https://example.com/read'>\(label)</a>"
        let parsed = try AttributedString(markdown: EmailFilter.htmlToPlainText(html))
        #expect(String(parsed.characters) == label)
        #expect(parsed.runs.compactMap { $0.link?.absoluteString } == ["https://example.com/read"])
    }

    @Test func addressTextIsNotAStyle() throws {
        let html = #"<a href="https://example.com/?q=>display:none">Visible</a>"#
        let parsed = try AttributedString(markdown: EmailFilter.htmlToPlainText(html))
        #expect(String(parsed.characters) == "Visible")
        #expect(parsed.runs.compactMap { $0.link?.absoluteString } == ["https://example.com/?q=%3Edisplay:none"])
        #expect(EmailFilter.htmlToPlainText(#"<a style='color:red; display:none !important' href='/hidden'>Hidden</a>"#).isEmpty)
        #expect(EmailFilter.htmlToPlainText(#"<div style="background:url('x;display:none'); /* ignored */ display:none">Hidden</div>"#).isEmpty)
    }

}
