/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

@Suite("IMAPProvider.escapeHtml")
struct EscapeHtmlTests {

    @Test("Escapes ampersand")
    func escapesAmpersand() {
        #expect(IMAPProvider.escapeHtml("A & B") == "A &amp; B")
    }

    @Test("Escapes less-than")
    func escapesLessThan() {
        #expect(IMAPProvider.escapeHtml("<script>") == "&lt;script&gt;")
    }

    @Test("Escapes greater-than")
    func escapesGreaterThan() {
        #expect(IMAPProvider.escapeHtml("a > b") == "a &gt; b")
    }

    @Test("Escapes double quotes")
    func escapesDoubleQuotes() {
        #expect(IMAPProvider.escapeHtml("say \"hello\"") == "say &quot;hello&quot;")
    }

    @Test("Does not escape single quotes")
    func doesNotEscapeSingleQuotes() {
        #expect(IMAPProvider.escapeHtml("it's fine") == "it's fine")
    }

    @Test("Empty string returns empty")
    func emptyString() {
        #expect(IMAPProvider.escapeHtml("") == "")
    }

    @Test("No special chars returns unchanged")
    func noSpecialChars() {
        #expect(IMAPProvider.escapeHtml("Hello World 123") == "Hello World 123")
    }

    @Test("Multiple special chars in sequence")
    func multipleSpecialChars() {
        #expect(IMAPProvider.escapeHtml("<b>&\"x\"</b>") == "&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;")
    }

    @Test("Already escaped ampersand gets double-escaped")
    func doubleEscape() {
        #expect(IMAPProvider.escapeHtml("&amp;") == "&amp;amp;")
    }

    @Test("Unicode preserved")
    func unicodePreserved() {
        #expect(IMAPProvider.escapeHtml("Hello 日本語 & 中文") == "Hello 日本語 &amp; 中文")
    }
}

@Suite("IMAPProvider.embeddedHeadersPlainText")
struct EmbeddedHeadersPlainTextTests {

    private func makeInfo(
        subject: String? = nil,
        from: String? = nil,
        to: [String] = [],
        cc: [String] = [],
        date: Date? = nil
    ) -> MessageInfo {
        MessageInfo(
            sequenceNumber: SequenceNumber(1),
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            date: date
        )
    }

    @Test("No filename produces simple separator")
    func noFilename() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("---\n"))
        #expect(!result.contains("--- "))
    }

    @Test("With filename produces labeled separator")
    func withFilename() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: "attachment.eml")
        #expect(result.contains("--- attachment.eml ---"))
    }

    @Test("Subject line included when present")
    func subjectIncluded() {
        let info = makeInfo(subject: "Test Subject")
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("Subject: Test Subject\n"))
    }

    @Test("From line included when present")
    func fromIncluded() {
        let info = makeInfo(from: "alice@example.com")
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("From: alice@example.com\n"))
    }

    @Test("To line joins multiple recipients")
    func toJoinsRecipients() {
        let info = makeInfo(to: ["a@b.com", "c@d.com"])
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("To: a@b.com, c@d.com\n"))
    }

    @Test("CC line joins multiple recipients")
    func ccJoinsRecipients() {
        let info = makeInfo(cc: ["x@y.com", "z@w.com"])
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("CC: x@y.com, z@w.com\n"))
    }

    @Test("Empty to/cc omitted")
    func emptyToAndCcOmitted() {
        let info = makeInfo(subject: "Only Subject")
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(!result.contains("To:"))
        #expect(!result.contains("CC:"))
    }

    @Test("Nil subject/from omitted")
    func nilFieldsOmitted() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(!result.contains("Subject:"))
        #expect(!result.contains("From:"))
    }

    @Test("Date line included when date present")
    func dateIncluded() {
        let date = Date(timeIntervalSince1970: 1710000000)
        let info = makeInfo(date: date)
        let result = IMAPProvider.embeddedHeadersPlainText(info, filename: nil)
        #expect(result.contains("Date:"))
    }
}

@Suite("IMAPProvider.embeddedHeadersHtml")
struct EmbeddedHeadersHtmlTests {

    private func makeInfo(
        subject: String? = nil,
        from: String? = nil,
        to: [String] = [],
        cc: [String] = [],
        date: Date? = nil
    ) -> MessageInfo {
        MessageInfo(
            sequenceNumber: SequenceNumber(1),
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            date: date
        )
    }

    @Test("With filename produces styled div")
    func withFilename() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: "test.eml")
        #expect(result.contains("<b>test.eml</b>"))
        #expect(result.contains("<div"))
    }

    @Test("No filename omits div")
    func noFilename() {
        let info = makeInfo(subject: "Hi")
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(!result.contains("<div"))
    }

    @Test("Subject renders as table row")
    func subjectRow() {
        let info = makeInfo(subject: "Meeting")
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("<b>Subject:</b> Meeting"))
        #expect(result.contains("<tr><td>"))
    }

    @Test("From renders as table row")
    func fromRow() {
        let info = makeInfo(from: "bob@test.com")
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("<b>From:</b> bob@test.com"))
    }

    @Test("HTML special chars in subject are escaped")
    func subjectEscaped() {
        let info = makeInfo(subject: "<script>alert('xss')</script>")
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("&lt;script&gt;"))
        #expect(!result.contains("<script>"))
    }

    @Test("HTML special chars in filename are escaped")
    func filenameEscaped() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: "file<>.eml")
        #expect(result.contains("file&lt;&gt;.eml"))
    }

    @Test("To addresses joined with comma")
    func toJoined() {
        let info = makeInfo(to: ["a@b.com", "c@d.com"])
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("<b>To:</b> a@b.com, c@d.com"))
    }

    @Test("CC addresses joined with comma")
    func ccJoined() {
        let info = makeInfo(cc: ["x@y.com"])
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("<b>CC:</b> x@y.com"))
    }

    @Test("Empty info produces no table")
    func emptyInfoNoTable() {
        let info = makeInfo()
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(!result.contains("<table"))
        #expect(result == "")
    }

    @Test("Table wrapper present when headers exist")
    func tableWrapper() {
        let info = makeInfo(subject: "Hi")
        let result = IMAPProvider.embeddedHeadersHtml(info, filename: nil)
        #expect(result.contains("<table"))
        #expect(result.contains("</table>"))
    }
}
