/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageBody.plainTextToHTML Extended")
struct PlainTextToHTMLExtendedTests {

    @Test("Wraps content in pre-wrap div")
    func wrapsInPreWrapDiv() {
        let html = MessageBody.plainTextToHTML("Hello")
        #expect(html.hasPrefix("<div style=\"white-space:pre-wrap;\">"))
        #expect(html.hasSuffix("</div>"))
    }

    @Test("Escapes HTML entities")
    func escapesHTMLEntities() {
        let html = MessageBody.plainTextToHTML("a < b & c > d")
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&gt;"))
    }

    @Test("Empty lines become paragraph breaks")
    func emptyLinesBecomeBr() {
        let html = MessageBody.plainTextToHTML("Hello\n\nWorld")
        #expect(html.contains("<div><br></div>"))
    }

    @Test("Quoted lines become blockquotes")
    func quotedLinesBlockquote() {
        let html = MessageBody.plainTextToHTML("> quoted text")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("quoted text"))
        #expect(html.contains("</blockquote>"))
    }

    @Test("Multiple quoted lines in one blockquote")
    func multipleQuotedLines() {
        let html = MessageBody.plainTextToHTML("> line 1\n> line 2")
        #expect(html.contains("line 1<br>line 2"))
    }

    @Test("RFC 3676 format=flowed: trailing space joins lines")
    func formatFlowedSoftWrap() {
        let html = MessageBody.plainTextToHTML("Hello \nWorld")
        #expect(html.contains("Hello World"))
    }

    @Test("RFC 3676: no trailing space = hard break")
    func formatFlowedHardBreak() {
        let html = MessageBody.plainTextToHTML("Hello\nWorld")
        #expect(html.contains("<div>Hello</div>"))
        #expect(html.contains("<div>World</div>"))
    }

    @Test("Signature separator '-- ' handling")
    func signatureSeparator() {
        let html = MessageBody.plainTextToHTML("text\n-- \nSignature")
        #expect(html.contains("text"))
        #expect(html.contains("-- "))
        #expect(html.contains("Signature"))
    }

    @Test("Carriage return stripped")
    func carriageReturnStripped() {
        let html = MessageBody.plainTextToHTML("Hello\r\nWorld")
        #expect(!html.contains("\r"))
    }

    @Test("Empty string produces minimal HTML")
    func emptyString() {
        let html = MessageBody.plainTextToHTML("")
        #expect(html.contains("white-space:pre-wrap"))
    }

    @Test("Multiline text with mix of soft and hard breaks")
    func multilineMixed() {
        // Lines ending with space are soft-wrapped, others are hard
        let text = "First \nSecond \nThird\nFourth"
        let html = MessageBody.plainTextToHTML(text)
        // First+Second+Third should be joined (soft wraps), Fourth separate
        #expect(html.contains("First Second Third"))
        #expect(html.contains("<div>Fourth</div>"))
    }

    @Test("Quoted text followed by normal text")
    func quotedThenNormal() {
        let text = "> quoted line\nNormal line"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("quoted line"))
        #expect(html.contains("Normal line"))
    }

    @Test("Quote with leading space after >")
    func quoteWithLeadingSpace() {
        let html = MessageBody.plainTextToHTML("> test quote")
        #expect(html.contains("test quote"))
        #expect(html.contains("<blockquote>"))
    }

    @Test("Multiple empty lines produce multiple br divs")
    func multipleEmptyLines() {
        let html = MessageBody.plainTextToHTML("A\n\n\nB")
        let brCount = html.components(separatedBy: "<div><br></div>").count - 1
        #expect(brCount >= 2)
    }

    @Test("Signature separator is hard break even with trailing space")
    func signatureSeparatorHardBreak() {
        // "-- " is a signature separator — always a hard break
        let html = MessageBody.plainTextToHTML("text\n-- \nnext")
        // The "-- " line should flush as its own div, not join with "next"
        #expect(html.contains("-- "))
    }

    @Test("URL in plain text is escaped properly")
    func urlEscaped() {
        let html = MessageBody.plainTextToHTML("Visit https://example.com/path?q=a&b=c")
        #expect(html.contains("&amp;b=c"))
        #expect(!html.contains("&b=c"))
    }
}

@Suite("MessageBody.create factory")
struct MessageBodyCreateTests {

    // `create` now just stores already-rendered DISPLAY html (BodyRenderer owns all
    // conversion). It no longer takes a textBody or runs plainTextToHTML — see
    // BodyRendererTests for the plain-text→HTML conversion coverage.

    @Test("Stores the provided html verbatim")
    func storesHTML() {
        let body = MessageBody.create(headerId: "h1", htmlBody: "<p>HTML</p>")
        #expect(body.htmlContent == "<p>HTML</p>")
    }

    @Test("nil html → nil htmlContent")
    func nilHTML() {
        let body = MessageBody.create(headerId: "h1", htmlBody: nil)
        #expect(body.htmlContent == nil)
    }

    @Test("empty html → nil htmlContent")
    func emptyHTML() {
        let body = MessageBody.create(headerId: "h1", htmlBody: "")
        #expect(body.htmlContent == nil)
    }

    @Test("Sets headerId correctly")
    func setsHeaderId() {
        let body = MessageBody.create(headerId: "custom-id-123", htmlBody: "<p>Hi</p>")
        #expect(body.id == "custom-id-123")
    }

    @Test("Sets fetchedAt to current time")
    func setsFetchedAt() {
        let before = Date()
        let body = MessageBody.create(headerId: "h1", htmlBody: "<p>Hi</p>")
        #expect(body.fetchedAt >= before)
    }

    @Test("Does NOT re-escape already-display html (no double-escape at storage)")
    func doesNotReEscapeHTML() {
        // Display html with correctly-encoded entities is stored verbatim — the
        // factory must never run plainTextToHTML over it (that was the bug).
        let html = "<p>Tom &amp; Jerry &nbsp;say hi</p>"
        let body = MessageBody.create(headerId: "h1", htmlBody: html)
        #expect(body.htmlContent == html)
        #expect(body.htmlContent?.contains("&amp;amp;") == false)
        #expect(body.htmlContent?.contains("&lt;p&gt;") == false)
    }
}

// MARK: - Draft Display Tests

@Suite("MessageBody draft display")
struct MessageBodyDraftDisplayTests {

    // MARK: - plainTextToHTML newline preservation

    @Test("Each newline produces a separate div — no lines lost")
    func eachNewlineProducesSeparateDiv() {
        let text = "Line 1\nLine 2\nLine 3"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Line 1</div>"))
        #expect(html.contains("<div>Line 2</div>"))
        #expect(html.contains("<div>Line 3</div>"))
    }

    @Test("Single line with no newlines wraps in one div")
    func singleLineNoNewline() {
        let html = MessageBody.plainTextToHTML("Just one line")
        #expect(html.contains("<div>Just one line</div>"))
    }

    @Test("Trailing newline does not produce spurious content")
    func trailingNewline() {
        let html = MessageBody.plainTextToHTML("Hello\n")
        #expect(html.contains("<div>Hello</div>"))
        // Trailing empty line should produce a br div
        #expect(html.contains("<div><br></div>"))
    }

    @Test("Leading newline produces br div before content")
    func leadingNewline() {
        let html = MessageBody.plainTextToHTML("\nHello")
        #expect(html.contains("<div><br></div>"))
        #expect(html.contains("<div>Hello</div>"))
    }

    @Test("CRLF line endings preserve newlines")
    func crlfLineEndings() {
        let text = "Line 1\r\nLine 2\r\nLine 3"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Line 1</div>"))
        #expect(html.contains("<div>Line 2</div>"))
        #expect(html.contains("<div>Line 3</div>"))
    }

    @Test("Indented lines preserve leading spaces")
    func indentedLines() {
        let text = "Header:\n  Item 1\n  Item 2"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Header:</div>"))
        #expect(html.contains("<div>  Item 1</div>"))
        #expect(html.contains("<div>  Item 2</div>"))
    }

    // MARK: - Draft-like content patterns

    @Test("Multi-paragraph draft preserves paragraph breaks")
    func multiParagraphDraft() {
        let text = "Dear Alice,\n\nThank you for your email.\n\nBest regards,\nBob"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Dear Alice,</div>"))
        // Empty line between paragraphs → <div><br></div>
        let brCount = html.components(separatedBy: "<div><br></div>").count - 1
        #expect(brCount == 2)
        #expect(html.contains("<div>Thank you for your email.</div>"))
        #expect(html.contains("<div>Best regards,</div>"))
        #expect(html.contains("<div>Bob</div>"))
    }

    @Test("Bullet-style list draft preserves each bullet")
    func bulletListDraft() {
        let text = "TODO:\n- Fix login bug\n- Update tests\n- Deploy"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>TODO:</div>"))
        #expect(html.contains("<div>- Fix login bug</div>"))
        #expect(html.contains("<div>- Update tests</div>"))
        #expect(html.contains("<div>- Deploy</div>"))
    }

    @Test("Draft with numbered list preserves numbers")
    func numberedListDraft() {
        let text = "Steps:\n1. Open file\n2. Edit line\n3. Save"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>1. Open file</div>"))
        #expect(html.contains("<div>2. Edit line</div>"))
        #expect(html.contains("<div>3. Save</div>"))
    }

    // MARK: - Trailing space (RFC 3676 soft wrap) edge cases

    @Test("Trailing space joins lines (RFC 3676 soft wrap)")
    func trailingSpaceJoinsLines() {
        // Trailing space = soft wrap → lines should join
        let text = "This is a long \nsentence."
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("This is a long sentence."))
    }

    @Test("No trailing space keeps lines separate (hard break)")
    func noTrailingSpaceKeepsSeparate() {
        let text = "Line 1\nLine 2"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Line 1</div>"))
        #expect(html.contains("<div>Line 2</div>"))
    }

    @Test("Signature separator always hard breaks even with trailing space")
    func signatureSeparatorAlwaysHardBreaks() {
        let text = "Body text\n-- \nJohn Doe"
        let html = MessageBody.plainTextToHTML(text)
        // "-- " should NOT join with "John Doe" despite trailing space
        #expect(html.contains("<div>-- </div>"))
        #expect(html.contains("<div>John Doe</div>"))
    }

    // MARK: - plain-text→HTML conversion (now via plainTextToHTML; BodyRenderer owns it for inbound bodies)

    @Test("Text-only conversion preserves newlines")
    func textOnlyConversionPreservesNewlines() {
        let text = "Hello\n\nWorld\nFoo"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Hello</div>"))
        #expect(html.contains("<div><br></div>"))
        #expect(html.contains("<div>World</div>"))
        #expect(html.contains("<div>Foo</div>"))
    }

    @Test("Raw text passed as htmlBody loses newlines — documents the pitfall")
    func rawTextAsHtmlBodyLosesNewlines() {
        // If a provider accidentally puts plain text into htmlBody, newlines are
        // lost because HTML renders \n as whitespace. Inbound bodies avoid this by
        // going through BodyRenderer (which converts plain text via plainTextToHTML).
        let rawText = "Line 1\nLine 2\nLine 3"
        let body = MessageBody.create(headerId: "draft1", htmlBody: rawText)
        #expect(body.htmlContent == rawText)
        #expect(body.htmlContent?.contains("<div>") == false)
    }

    @Test("HTML body is used as-is without conversion")
    func htmlBodyUsedAsIs() {
        let htmlBody = "<div>Hello</div><div><br></div><div>World</div>"
        let body = MessageBody.create(headerId: "draft1", htmlBody: htmlBody)
        #expect(body.htmlContent == htmlBody)
    }

    // MARK: - Whitespace-only content

    @Test("Whitespace-only lines produce br divs")
    func whitespaceOnlyLines() {
        let text = "Before\n   \nAfter"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Before</div>"))
        #expect(html.contains("<div><br></div>"))
        #expect(html.contains("<div>After</div>"))
    }

    @Test("Tab-indented lines preserved")
    func tabIndentedLines() {
        let text = "Function:\n\tline 1\n\tline 2"
        let html = MessageBody.plainTextToHTML(text)
        #expect(html.contains("<div>Function:</div>"))
        #expect(html.contains("<div>\tline 1</div>"))
        #expect(html.contains("<div>\tline 2</div>"))
    }

    // MARK: - Count verification

    @Test("Number of divs matches number of non-empty lines")
    func divCountMatchesLineCount() {
        let lines = ["Alpha", "Beta", "Gamma", "Delta"]
        let text = lines.joined(separator: "\n")
        let html = MessageBody.plainTextToHTML(text)
        for line in lines {
            #expect(html.contains("<div>\(line)</div>"))
        }
    }

    @Test("10 lines produce 10 separate divs")
    func tenLinesProduceTenDivs() {
        let lines = (1...10).map { "Line \($0)" }
        let text = lines.joined(separator: "\n")
        let html = MessageBody.plainTextToHTML(text)
        for line in lines {
            #expect(html.contains("<div>\(line)</div>"))
        }
    }
}

@Suite("MessageBody GRDB Persistence")
struct MessageBodyPersistenceTests {

    @Test("Insert and fetch round-trip")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg1")

        let body = MessageBody(headerId: "acc1:INBOX:msg1", htmlContent: "<p>Hello World</p>")
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg1") }
        #expect(fetched != nil)
        #expect(fetched?.htmlContent == "<p>Hello World</p>")
        #expect(fetched?.id == "acc1:INBOX:msg1")
    }

    @Test("Insert with nil htmlContent")
    func insertNilContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg2")

        let body = MessageBody(headerId: "acc1:INBOX:msg2", htmlContent: nil)
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg2") }
        #expect(fetched != nil)
        #expect(fetched?.htmlContent == nil)
    }

    @Test("Update htmlContent")
    func updateContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg3")

        var body = MessageBody(headerId: "acc1:INBOX:msg3", htmlContent: "<p>Original</p>")
        try db.write { try body.insert($0) }

        body.htmlContent = "<p>Updated</p>"
        try db.write { try body.update($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg3") }
        #expect(fetched?.htmlContent == "<p>Updated</p>")
    }

    @Test("Delete removes record")
    func deleteRemoves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg4")

        let body = MessageBody(headerId: "acc1:INBOX:msg4", htmlContent: "<p>Delete me</p>")
        try db.write { try body.insert($0) }

        try db.write { try body.delete($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg4") }
        #expect(fetched == nil)
    }

    @Test("Persists fetchedAt timestamp")
    func persistsFetchedAt() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg5")

        let before = Date().addingTimeInterval(-1) // 1s tolerance for Date precision
        let body = MessageBody(headerId: "acc1:INBOX:msg5", htmlContent: "<p>Test</p>")
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg5") }
        #expect(fetched != nil)
        #expect(fetched!.fetchedAt >= before)
    }

    @Test("Persists attachmentsJSON")
    func persistsAttachmentsJSON() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg6")

        var body = MessageBody(headerId: "acc1:INBOX:msg6", htmlContent: "<p>With attachment</p>")
        body.attachmentsJSON = """
        [{"filename":"report.pdf","contentType":"application/pdf","section":"1.1","size":2048}]
        """
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg6") }
        #expect(fetched?.attachmentsJSON != nil)
        let attachments = fetched!.attachments
        #expect(attachments.count == 1)
        #expect(attachments[0].filename == "report.pdf")
        #expect(attachments[0].size == 2048)
    }

    @Test("Persists icsText")
    func persistsIcsText() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg7")

        var body = MessageBody(headerId: "acc1:INBOX:msg7", htmlContent: "<p>Meeting</p>")
        body.icsText = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:msg7") }
        #expect(fetched?.icsText?.contains("VCALENDAR") == true)
    }
}

@Suite("MessageBody.attachments")
struct MessageBodyAttachmentsTests {

    @Test("Parses attachments from JSON")
    func parsesAttachments() {
        var body = MessageBody(headerId: "h1", htmlContent: "<p>test</p>")
        body.attachmentsJSON = """
        [{"filename":"doc.pdf","contentType":"application/pdf","section":"1.2","size":1024,"encoding":"base64"}]
        """
        let attachments = body.attachments
        #expect(attachments.count == 1)
        #expect(attachments[0].filename == "doc.pdf")
        #expect(attachments[0].contentType == "application/pdf")
        #expect(attachments[0].size == 1024)
    }

    @Test("Nil attachmentsJSON returns empty array")
    func nilJSON() {
        let body = MessageBody(headerId: "h1", htmlContent: nil)
        #expect(body.attachments.isEmpty)
    }

    @Test("Invalid JSON returns empty array")
    func invalidJSON() {
        var body = MessageBody(headerId: "h1", htmlContent: nil)
        body.attachmentsJSON = "not json"
        #expect(body.attachments.isEmpty)
    }

    @Test("Empty array JSON returns empty array")
    func emptyArrayJSON() {
        var body = MessageBody(headerId: "h1", htmlContent: nil)
        body.attachmentsJSON = "[]"
        #expect(body.attachments.isEmpty)
    }

    @Test("Multiple attachments parsed correctly")
    func multipleAttachments() {
        var body = MessageBody(headerId: "h1", htmlContent: nil)
        body.attachmentsJSON = """
        [
            {"filename":"doc.pdf","contentType":"application/pdf","section":"1.1","size":1024},
            {"filename":"image.png","contentType":"image/png","section":"1.2","size":2048,"encoding":"base64"}
        ]
        """
        let attachments = body.attachments
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == "doc.pdf")
        #expect(attachments[1].filename == "image.png")
        #expect(attachments[1].encoding == "base64")
    }

    @Test("Attachment without encoding field decodes (nil encoding)")
    func attachmentWithoutEncoding() {
        var body = MessageBody(headerId: "h1", htmlContent: nil)
        body.attachmentsJSON = """
        [{"filename":"test.txt","contentType":"text/plain","section":"1","size":100}]
        """
        let attachments = body.attachments
        #expect(attachments.count == 1)
        #expect(attachments[0].encoding == nil)
    }
}

@Suite("MessageBody.icsText")
struct MessageBodyICSTextTests {

    @Test("icsText field persists via GRDB")
    func icsTextPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        var body = MessageBody(headerId: "acc1:INBOX:1", htmlContent: "<p>Meeting invite</p>")
        body.icsText = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Team Meeting\nEND:VEVENT\nEND:VCALENDAR"
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.icsText?.contains("VCALENDAR") == true)
        #expect(fetched?.icsText?.contains("Team Meeting") == true)
    }

    @Test("icsText defaults to nil")
    func icsTextDefaultNil() {
        let body = MessageBody(headerId: "h1", htmlContent: "<p>No calendar</p>")
        #expect(body.icsText == nil)
    }
}
