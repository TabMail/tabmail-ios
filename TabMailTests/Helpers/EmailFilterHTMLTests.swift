/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailFilter.htmlToPlainText")
struct EmailFilterHTMLTests {

    @Test("Strips simple HTML tags")
    func stripsSimpleTags() {
        let result = EmailFilter.htmlToPlainText("<p>Hello <b>World</b></p>")
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
        #expect(!result.contains("<"))
        #expect(!result.contains(">"))
    }

    @Test("Strips style blocks entirely")
    func stripsStyleBlocks() {
        let html = "<style>.red { color: red; }</style><p>Content</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("red"))
        #expect(result.contains("Content"))
    }

    @Test("Strips script blocks entirely")
    func stripsScriptBlocks() {
        let html = "<script>alert('xss')</script><p>Safe</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("alert"))
        #expect(result.contains("Safe"))
    }

    @Test("Strips head blocks entirely")
    func stripsHeadBlocks() {
        let html = "<html><head><title>Page</title></head><body>Content</body></html>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Page"))
        #expect(result.contains("Content"))
    }

    @Test("Head without closing tag — implicit close at body")
    func headWithoutClosingTag() {
        // HTML5 allows omitting </head> — <body> implicitly closes it.
        // Without this fix, skipPastCloseTag scans to EOF and produces empty output.
        let html = "<html><head><meta charset=\"utf-8\"><title>Page</title><style>.x{color:red}</style><body><div>Visible content here</div></body></html>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Page"))
        #expect(!result.contains("color"))
        #expect(result.contains("Visible content here"))
    }

    @Test("Head without closing tag and with style — large email pattern")
    func headWithoutClosingTagLargeStyle() {
        // Simulates transactional emails: <head> with large CSS, no </head>, then <body> content
        let css = String(repeating: ".class{padding:10px;margin:0;font-size:16px;}", count: 100)
        let html = "<html><head><title>Notification</title><style type=\"text/css\">\(css)</style><body><table><tr><td>Payment received</td></tr><tr><td>Thank you for your payment.</td></tr></table></body></html>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Notification"))
        #expect(!result.contains("padding"))
        #expect(result.contains("Payment received"))
        #expect(result.contains("Thank you"))
    }

    @Test("Head with closing tag still works")
    func headWithClosingTagStillWorks() {
        // Ensure the new logic doesn't break normal <head>...</head> handling
        let html = "<html><head><title>Title</title><style>.x{}</style></head><body><p>Body text</p></body></html>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Title"))
        #expect(result.contains("Body text"))
    }

    @Test("Strips title tag content even without head wrapper")
    func stripsTitleWithoutHead() {
        // HTML email fragments may lack <head> — <title> content should still be suppressed
        let html = "<meta charset=\"utf-8\"><title>Document Title Here</title><div>Actual body content</div>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Document Title"))
        #expect(result.contains("Actual body content"))
    }

    @Test("Strips title tag case-insensitive")
    func stripsTitleCaseInsensitive() {
        let html = "<TITLE>Page Title</TITLE><p>Body text</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains("Page Title"))
        #expect(result.contains("Body text"))
    }

    @Test("Transactional email fragment: title + style + content")
    func transactionalEmailFragment() {
        // Typical HTML email fragment: no <head> wrapper, title + massive style + nested tables
        let html = """
        <meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Service Notification</title>
        <style type="text/css">body{margin:0;padding:0}.card{border:1px solid #ccc;padding:20px}</style>
        <div style="background-color:#f4f4f4">
            <table><tbody><tr><td>
                <img src="https://example.com/logo.png" alt="Logo">
            </td></tr></tbody></table>
            <table><tbody><tr><td style="font-size:40px;font-weight:600">
                Payment received
            </td></tr><tr><td>
                Thank you for your payment.
            </td></tr><tr><td>
                <table><tbody>
                    <tr><td style="font-weight:600">Invoice:</td><td>12345</td></tr>
                    <tr><td style="font-weight:600">Amount:</td><td>$9.99</td></tr>
                </tbody></table>
            </td></tr></tbody></table>
        </div>
        """
        let plain = EmailFilter.htmlToPlainText(html)
        let snippet = EmailFilter.snippetFromPlainText(plain)
        // Title and CSS must not leak
        #expect(!plain.contains("Service Notification"))
        #expect(!plain.contains("margin"))
        #expect(!plain.contains("border"))
        // Snippet must start with actual content, not document metadata
        #expect(snippet.hasPrefix("Payment received"))
        #expect(snippet.contains("Thank you"))
        #expect(snippet.contains("Invoice:"))
        #expect(snippet.contains("$9.99"))
    }

    @Test("display:none on void element (img) does not consume remaining content")
    func displayNoneVoidElement() {
        // Void elements like <img> never have a closing tag.
        // skipPastCloseTagNested("img") scans to EOF if used on them.
        let html = """
        <div>Before image</div>
        <img src="logo.png" style="display: none; width:360px;" alt="hidden">
        <div>After image</div>
        <table><tr><td>Table content</td></tr></table>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Before image"))
        #expect(result.contains("After image"))
        #expect(result.contains("Table content"))
    }

    @Test("display:none on non-void element still suppresses content")
    func displayNoneNonVoidElement() {
        let html = """
        <div>Visible</div>
        <div style="display:none">Hidden content here</div>
        <div>Also visible</div>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Visible"))
        #expect(!result.contains("Hidden content"))
        #expect(result.contains("Also visible"))
    }

    @Test("Marketing email with hidden mobile image does not lose content")
    func marketingEmailHiddenMobileImage() {
        // Real-world pattern: desktop logo visible, mobile logo hidden with display:none
        let html = """
        <body>
        <table><tr><td>
            <a href="https://example.com">
                <img src="desktop-logo.png" alt="Logo" style="display: block;">
                <img src="mobile-logo.png" alt="Logo" style="display: none; width:360px;">
            </a>
        </td></tr></table>
        <table><tr><td style="font-size:40px">Payment success</td></tr>
        <tr><td>Thank you for your payment.</td></tr>
        <tr><td>Invoice: 12345</td></tr>
        <tr><td>Amount: $9.99</td></tr></table>
        <table><tr><td>Account details</td></tr></table>
        </body>
        """
        let plain = EmailFilter.htmlToPlainText(html)
        let snippet = EmailFilter.snippetFromPlainText(plain)
        #expect(plain.contains("Payment success"))
        #expect(plain.contains("Thank you"))
        #expect(plain.contains("Account details"))
        #expect(snippet.contains("Payment success"))
    }

    @Test("Decodes &amp; entity")
    func decodesAmpEntity() {
        let result = EmailFilter.htmlToPlainText("A &amp; B")
        #expect(result.contains("A & B"))
    }

    @Test("Decodes &lt; and &gt; entities")
    func decodesLtGtEntities() {
        let result = EmailFilter.htmlToPlainText("&lt;tag&gt;")
        #expect(result.contains("<tag>"))
    }

    @Test("Decodes &nbsp; as space")
    func decodesNbsp() {
        let result = EmailFilter.htmlToPlainText("word&nbsp;word")
        #expect(result.contains("word word"))
    }

    @Test("Decodes numeric entity &#39;")
    func decodesNumericEntity() {
        let result = EmailFilter.htmlToPlainText("it&#39;s")
        #expect(result.contains("it's"))
    }

    @Test("Decodes hex entity &#x27;")
    func decodesHexEntity() {
        let result = EmailFilter.htmlToPlainText("it&#x27;s")
        #expect(result.contains("it's"))
    }

    @Test("Collapses whitespace")
    func collapsesWhitespace() {
        let result = EmailFilter.htmlToPlainText("Hello    \n\n\t  World")
        #expect(result == "Hello World")
    }

    @Test("Handles empty string")
    func emptyString() {
        let result = EmailFilter.htmlToPlainText("")
        #expect(result.isEmpty)
    }

    @Test("Handles plain text (no HTML)")
    func plainText() {
        let result = EmailFilter.htmlToPlainText("Just plain text")
        #expect(result == "Just plain text")
    }

    @Test("Handles HTML comments")
    func htmlComments() {
        let result = EmailFilter.htmlToPlainText("Before<!-- comment -->After")
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
        #expect(!result.contains("comment"))
    }

    @Test("Preserves Unicode text")
    func preservesUnicode() {
        let result = EmailFilter.htmlToPlainText("<p>日本語テスト</p>")
        #expect(result.contains("日本語テスト"))
    }

    @Test("Handles non-breaking space UTF-8 bytes (0xC2 0xA0)")
    func nonBreakingSpaceBytes() {
        let result = EmailFilter.htmlToPlainText("hello\u{00A0}world")
        #expect(result == "hello world")
    }

    @Test("Handles case-insensitive closing tags")
    func caseInsensitiveClosingTags() {
        let html = "<STYLE>.x{}</STYLE><P>Content</P>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.contains(".x"))
        #expect(result.contains("Content"))
    }

    @Test("Decodes &quot; entity")
    func decodesQuotEntity() {
        let result = EmailFilter.htmlToPlainText("say &quot;hello&quot;")
        #expect(result.contains("say \"hello\""))
    }

    @Test("Large HTML performance (no crash)")
    func largeHTML() {
        let html = String(repeating: "<p>Hello World</p>", count: 10000)
        let result = EmailFilter.htmlToPlainText(html)
        #expect(!result.isEmpty)
    }

    @Test("Decodes &#160; (non-breaking space) entity and collapses to space")
    func decodesNbspNumericEntityAsNonBreakingSpace() {
        // Hits lines 167-169: &#160; decodes to \u{00A0} via numeric entity path,
        // then the \u{00A0} branch in htmlToPlainText collapses it to a regular space
        let result = EmailFilter.htmlToPlainText("word1&#160;word2")
        #expect(result == "word1 word2")
    }

    @Test("Handles 4-byte UTF-8 sequences (emoji)")
    func handles4ByteUTF8() {
        // Hits line 221: return 4 in utf8SeqLen for 4-byte UTF-8 lead byte (0xF0+)
        let result = EmailFilter.htmlToPlainText("<p>Hello 😀 World</p>")
        #expect(result.contains("Hello"))
        #expect(result.contains("😀"))
        #expect(result.contains("World"))
    }

    @Test("Handles unterminated HTML comment")
    func unterminatedComment() {
        // Hits line 255: return count in skipPastBytes when "-->" marker is not found
        let result = EmailFilter.htmlToPlainText("Before<!-- unterminated comment without end")
        #expect(result.contains("Before"))
        #expect(!result.contains("unterminated"))
    }

    @Test("Handles unclosed style tag")
    func unclosedStyleTag() {
        // Hits line 279: return count in skipPastCloseTag when </style> is not found
        let result = EmailFilter.htmlToPlainText("<style>body { color: red; } no closing tag here")
        #expect(!result.contains("color"))
        #expect(!result.contains("red"))
    }

    @Test("Invalid hex entity replaced with space")
    func invalidHexEntity() {
        // Hits line 308: return (" ", advance) when hex parse fails (e.g. &#xZZZ;)
        let result = EmailFilter.htmlToPlainText("before&#xZZZZ;after")
        #expect(result.contains("before"))
        #expect(result.contains("after"))
    }

    @Test("Invalid decimal entity replaced with space")
    func invalidDecimalEntity() {
        // Hits line 315: return (" ", advance) when decimal parse fails (e.g. &#abc;)
        let result = EmailFilter.htmlToPlainText("before&#abc;after")
        #expect(result.contains("before"))
        #expect(result.contains("after"))
    }
}

@Suite("EmailFilter.htmlToPlainText — Web Draft Bodies")
struct EmailFilterHTMLDraftTests {

    @Test("Gmail-style draft HTML extracts plain text")
    func gmailDraft() {
        let html = """
        <div dir="ltr"><div>Hi team,</div><div><br></div><div>Here is the update for this week.</div><div><br></div><div>Best,</div><div>Alice</div></div>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Hi team,"))
        #expect(result.contains("Here is the update for this week."))
        #expect(result.contains("Best,"))
        #expect(result.contains("Alice"))
        #expect(!result.contains("<div"))
        #expect(!result.contains("</div>"))
    }

    @Test("Outlook-style draft HTML with style blocks extracts plain text")
    func outlookDraft() {
        let html = """
        <html><head><style>body{font-family:Calibri;font-size:11pt}</style></head><body><p>Dear Bob,</p><p>Please review the attached document.</p><p>Regards,<br>Carol</p></body></html>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Dear Bob,"))
        #expect(result.contains("Please review the attached document."))
        #expect(result.contains("Regards,"))
        #expect(result.contains("Carol"))
        #expect(!result.contains("Calibri"))
        #expect(!result.contains("<p>"))
    }

    @Test("Rich HTML draft with links extracts text only")
    func richDraftWithLinks() {
        let html = """
        <div>Check out <a href="https://example.com">this link</a> for details.</div>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Check out"))
        #expect(result.contains("this link"))
        #expect(result.contains("for details."))
        #expect(!result.contains("href"))
        #expect(!result.contains("https://"))
    }

    @Test("Plain text body passes through unchanged")
    func plainTextDraft() {
        let text = "Just a plain text draft without HTML"
        let result = EmailFilter.htmlToPlainText(text)
        #expect(result == text)
    }

    @Test("Draft with &nbsp; entities converts to spaces")
    func draftWithNbsp() {
        let html = "<div>Hello&nbsp;&nbsp;&nbsp;World</div>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
        #expect(!result.contains("&nbsp;"))
    }

    @Test("Draft with nested formatting tags extracts text")
    func nestedFormattingTags() {
        let html = "<div><b><i><u>Important</u></i></b> message here</div>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Important"))
        #expect(result.contains("message here"))
        #expect(!result.contains("<b>"))
    }
}

@Suite("EmailFilter.htmlToPlainText — Block-Level Newlines")
struct EmailFilterHTMLBlockNewlineTests {

    @Test("Closing </div> produces newline between lines")
    func closingDivProducesNewline() {
        let html = "<div>Line 1</div><div>Line 2</div>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Line 1\nLine 2"))
    }

    @Test("Closing </p> produces newline")
    func closingPProducesNewline() {
        let html = "<p>Paragraph 1</p><p>Paragraph 2</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Paragraph 1\nParagraph 2"))
    }

    @Test("<br> produces newline")
    func brProducesNewline() {
        let html = "Line 1<br>Line 2"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Line 1\nLine 2"))
    }

    @Test("<br/> self-closing produces newline")
    func brSelfClosingProducesNewline() {
        let html = "Line 1<br/>Line 2"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Line 1\nLine 2"))
    }

    @Test("Gmail-style div structure preserves line breaks")
    func gmailDivStructure() {
        let html = "<div>Hello</div><div><br></div><div>World</div>"
        let result = EmailFilter.htmlToPlainText(html)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(nonEmpty.count >= 2)
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
    }

    @Test("Multiple paragraphs have newlines between them")
    func multipleParagraphs() {
        let html = "<p>First</p><p>Second</p><p>Third</p>"
        let result = EmailFilter.htmlToPlainText(html)
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("First"))
        #expect(lines[1].contains("Second"))
        #expect(lines[2].contains("Third"))
    }

    @Test("Heading tags produce newlines")
    func headingTags() {
        let html = "<h1>Title</h1><p>Content</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Title\n"))
        #expect(result.contains("Content"))
    }

    @Test("List items produce newlines")
    func listItems() {
        let html = "<ul><li>Item 1</li><li>Item 2</li><li>Item 3</li></ul>"
        let result = EmailFilter.htmlToPlainText(html)
        let lines = result.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.count >= 3)
    }

    @Test("Table rows produce newlines")
    func tableRows() {
        let html = "<table><tr><td>Row 1</td></tr><tr><td>Row 2</td></tr></table>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Row 1"))
        #expect(result.contains("Row 2"))
        #expect(result.contains("\n"))
    }

    @Test("Round-trip: plainTextToHTML then htmlToPlainText preserves lines")
    func roundTripPreservesLines() {
        let original = "Line 1\nLine 2\nLine 3"
        let html = MessageBody.plainTextToHTML(original)
        let roundTripped = EmailFilter.htmlToPlainText(html)
        let lines = roundTripped.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("Line 1"))
        #expect(lines[1].contains("Line 2"))
        #expect(lines[2].contains("Line 3"))
    }

    @Test("Round-trip: multi-paragraph draft preserves structure")
    func roundTripMultiParagraph() {
        let original = "Dear Alice,\n\nThank you.\n\nBest,\nBob"
        let html = MessageBody.plainTextToHTML(original)
        let roundTripped = EmailFilter.htmlToPlainText(html)
        #expect(roundTripped.contains("Dear Alice,"))
        #expect(roundTripped.contains("Thank you."))
        #expect(roundTripped.contains("Best,"))
        #expect(roundTripped.contains("Bob"))
        // All four content lines must be separated by newlines
        let contentLines = roundTripped.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(contentLines.count >= 4)
    }

    @Test("Inline tags do NOT produce newlines")
    func inlineTagsNoNewline() {
        let html = "Hello <b>bold</b> <i>italic</i> world"
        let result = EmailFilter.htmlToPlainText(html)
        // Should be on one line — no newlines from inline tags
        #expect(!result.contains("\n"))
        #expect(result.contains("Hello"))
        #expect(result.contains("bold"))
        #expect(result.contains("world"))
    }

    @Test("Blockquote produces newline")
    func blockquoteNewline() {
        let html = "<p>Before</p><blockquote>Quoted</blockquote><p>After</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Before"))
        #expect(result.contains("Quoted"))
        #expect(result.contains("After"))
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count >= 3)
    }
}

@Suite("EmailFilter HTML-to-snippet canonical path")
struct EmailFilterHTMLToSnippetTests {

    @Test("Extracts snippet from HTML via canonical path")
    func basicSnippet() {
        let html = "<p>This is a test email with some content.</p>"
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.contains("This is a test email"))
    }

    @Test("Snippet is truncated to maxChars")
    func truncation() {
        let html = "<p>" + String(repeating: "Hello world. ", count: 50) + "</p>"
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain, maxChars: 50)
        #expect(result.count <= 50)
    }

    @Test("Snippet strips HTML tags via htmlToPlainText")
    func stripsHTML() {
        let html = "<b>Bold</b> <i>italic</i>"
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.contains("Bold"))
        #expect(!result.contains("<b>"))
    }

    @Test("Very large HTML produces valid snippet")
    func largeHTML() {
        let html = String(repeating: "<p>Hello</p>", count: 500)
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(!result.isEmpty)
        #expect(result.count <= 150)
    }
}

@Suite("EmailFilter.snippetFromPlainText")
struct EmailFilterSnippetFromPlainTextTests {

    @Test("Collapses whitespace in snippet")
    func collapsesWhitespace() {
        let text = "Hello    \n\n   World"
        let result = EmailFilter.snippetFromPlainText(text)
        #expect(result == "Hello World")
    }

    @Test("Respects maxChars")
    func respectsMaxChars() {
        let text = String(repeating: "A ", count: 100)
        let result = EmailFilter.snippetFromPlainText(text, maxChars: 20)
        #expect(result.count <= 20)
    }

    @Test("Collapses repeated separator characters")
    func collapsesSeparators() {
        let text = "Section 1\n----------\nSection 2"
        let result = EmailFilter.snippetFromPlainText(text)
        // Should not contain "----------", should collapse to "-"
        #expect(!result.contains("--"))
    }

    @Test("Trims trailing spaces")
    func trimsTrailingSpaces() {
        let result = EmailFilter.snippetFromPlainText("Hello   ")
        #expect(result == "Hello")
    }

    @Test("Empty text returns empty")
    func emptyText() {
        let result = EmailFilter.snippetFromPlainText("")
        #expect(result.isEmpty)
    }
}

@Suite("EmailFilter.isNoReply")
struct EmailFilterIsNoReplyTests {

    @Test("Detects noreply@")
    func detectsNoreply() {
        #expect(EmailFilter.isNoReply("noreply@company.com"))
    }

    @Test("Detects no-reply@")
    func detectsNoReplyHyphen() {
        #expect(EmailFilter.isNoReply("no-reply@company.com"))
    }

    @Test("Detects do-not-reply@")
    func detectsDoNotReply() {
        #expect(EmailFilter.isNoReply("do-not-reply@company.com"))
    }

    @Test("Detects notifications@")
    func detectsNotifications() {
        #expect(EmailFilter.isNoReply("notifications@codehub.example"))
    }

    @Test("Detects newsletter@")
    func detectsNewsletter() {
        #expect(EmailFilter.isNoReply("newsletter@company.com"))
    }

    @Test("Regular address is not no-reply")
    func regularAddress() {
        #expect(!EmailFilter.isNoReply("alice@company.com"))
    }

    @Test("Case insensitive")
    func caseInsensitive() {
        #expect(EmailFilter.isNoReply("NoReply@Company.com"))
    }
}

@Suite("EmailFilter.hasUnsubscribeLink")
struct EmailFilterUnsubscribeLinkTests {

    @Test("Detects List-Unsubscribe header")
    func detectsListUnsubscribe() {
        #expect(EmailFilter.hasUnsubscribeLink("List-Unsubscribe: <mailto:unsub@x.com>"))
    }

    @Test("Detects unsubscribe link with http")
    func detectsUnsubscribeWithHttp() {
        #expect(EmailFilter.hasUnsubscribeLink("<a href=\"http://example.com/unsubscribe\">Unsubscribe</a>"))
    }

    @Test("Does not detect unsubscribe without link")
    func noUnsubscribeWithoutLink() {
        #expect(!EmailFilter.hasUnsubscribeLink("Please unsubscribe from our list"))
    }

    @Test("Nil HTML returns false")
    func nilHTML() {
        #expect(!EmailFilter.hasUnsubscribeLink(nil))
    }

    @Test("Case insensitive")
    func caseInsensitive() {
        #expect(EmailFilter.hasUnsubscribeLink("<a href=\"http://x.com\">UNSUBSCRIBE</a>"))
    }

    @Test("Detects opt-out with click")
    func detectsOptOut() {
        #expect(EmailFilter.hasUnsubscribeLink("Click here to opt out http://example.com"))
    }
}

@Suite("EmailFilter.decodeHTMLEntities")
struct EmailFilterDecodeHTMLEntitiesTests {

    @Test("Decodes &#39;")
    func decodesNumeric39() {
        #expect(EmailFilter.decodeHTMLEntities("it&#39;s") == "it's")
    }

    @Test("Decodes &#x27;")
    func decodesHex27() {
        #expect(EmailFilter.decodeHTMLEntities("it&#x27;s") == "it's")
    }

    @Test("Decodes &amp;")
    func decodesAmp() {
        #expect(EmailFilter.decodeHTMLEntities("A &amp; B") == "A & B")
    }

    @Test("Decodes &lt; and &gt;")
    func decodesLtGt() {
        #expect(EmailFilter.decodeHTMLEntities("&lt;tag&gt;") == "<tag>")
    }

    @Test("Decodes &quot;")
    func decodesQuot() {
        #expect(EmailFilter.decodeHTMLEntities("&quot;hi&quot;") == "\"hi\"")
    }

    @Test("Decodes &nbsp;")
    func decodesNbsp() {
        #expect(EmailFilter.decodeHTMLEntities("a&nbsp;b") == "a b")
    }

    @Test("Plain text passes through")
    func plainText() {
        #expect(EmailFilter.decodeHTMLEntities("hello world") == "hello world")
    }

    @Test("Multiple entities in same string")
    func multipleEntities() {
        let result = EmailFilter.decodeHTMLEntities("A &amp; B &lt; C &gt; D")
        #expect(result == "A & B < C > D")
    }
}
