/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("HTML link text conversion")
struct EmailFilterLinkTests {
    @Test(arguments: [
        #"<a href="https://example.com/read">Read</a>"#,
        "<A HREF='https://example.com/read'>Read</A>",
        "<a href=https://example.com/read>Read</a>",
        #"<a title="other href='wrong'" href="https://example.com/read"><b>Read</b></a>"#
    ])
    func preservesDestination(html: String) {
        #expect(EmailFilter.htmlToPlainText(html) == "[Read](https://example.com/read)")
        #expect(EmailFilter.extractPlainText(htmlBody: html, textBody: "Read") == "[Read](https://example.com/read)")
    }

    @Test func decodesAddressEntities() {
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/?a=1&amp;b=&#50;">A &amp; B</a>"#)
            == "[A & B](https://example.com/?a=1&b=2)")
        #expect(EmailFilter.htmlToPlainText(#"<a href="https://example.com/?a=1&custom;">Read</a>"#)
            == "[Read](https://example.com/?a=1&custom;)")
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
}
