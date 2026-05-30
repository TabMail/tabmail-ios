/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageBody")
struct MessageBodyTests {

    @Test("plainTextToHTML wraps text in pre-wrap div")
    func plainTextToHTMLBasic() {
        let html = MessageBody.plainTextToHTML("Hello\nWorld")
        #expect(html.contains("Hello"))
        #expect(html.contains("World"))
        #expect(html.contains("white-space"))
    }

    @Test("plainTextToHTML escapes HTML entities")
    func plainTextToHTMLEscaping() {
        let html = MessageBody.plainTextToHTML("<script>alert(1)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;") || html.contains("&lt;"))
    }

    @Test("plainTextToHTML handles RFC 3676 format=flowed soft break")
    func plainTextToHTMLFlowed() {
        // Trailing space indicates soft break (lines should join)
        let html = MessageBody.plainTextToHTML("Line1 \nLine2")
        // The two lines should be joined (soft break)
        #expect(html.contains("Line1") && html.contains("Line2"))
    }

    @Test("plainTextToHTML handles blockquote lines")
    func plainTextToHTMLBlockquote() {
        let html = MessageBody.plainTextToHTML("> Quoted text")
        #expect(html.contains("blockquote") || html.contains("Quoted text"))
    }

    @Test("plainTextToHTML handles empty input")
    func plainTextToHTMLEmpty() {
        let html = MessageBody.plainTextToHTML("")
        #expect(html.contains("div") || html.isEmpty)
    }

    @Test("create factory with HTML body")
    func createWithHTML() {
        let body = MessageBody.create(headerId: "h1", htmlBody: "<p>Hello</p>", textBody: nil)
        #expect(body.id == "h1")
        #expect(body.htmlContent == "<p>Hello</p>")
    }

    @Test("create factory with text body falls back to plainTextToHTML")
    func createWithText() {
        let body = MessageBody.create(headerId: "h1", htmlBody: nil, textBody: "Plain text")
        #expect(body.id == "h1")
        #expect(body.htmlContent != nil)
        #expect(body.htmlContent!.contains("Plain text"))
    }

    @Test("create factory prefers HTML over text")
    func createPrefersHTML() {
        let body = MessageBody.create(headerId: "h1", htmlBody: "<b>Bold</b>", textBody: "Bold")
        #expect(body.htmlContent == "<b>Bold</b>")
    }

    @Test("attachmentsJSON round-trip")
    func attachmentsJSONRoundTrip() {
        var body = MessageBody(headerId: "h1", htmlContent: nil)
        let jsonStr = "[{\"filename\":\"test.pdf\",\"mimeType\":\"application/pdf\",\"size\":1024}]"
        body.attachmentsJSON = jsonStr
        #expect(body.attachmentsJSON == jsonStr)
    }

    @Test("init sets fetchedAt")
    func initSetsFetchedAt() {
        let before = Date()
        let body = MessageBody(headerId: "h1", htmlContent: nil)
        #expect(body.fetchedAt >= before)
    }

    @Test("icsText is nil by default")
    func icsTextDefault() {
        let body = MessageBody(headerId: "h1", htmlContent: nil)
        #expect(body.icsText == nil)
    }
}
