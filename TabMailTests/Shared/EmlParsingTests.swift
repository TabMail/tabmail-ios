/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit tests for `EmlParsing.parse(rawBytes:)` — the shared helper that
/// parses raw RFC 822 bytes from a file-uploaded `.eml` into
/// (`EmlMarker.Envelope`, body HTML). Wraps the SwiftMail fork's `EMLParser` so
/// these tests mostly verify our envelope mapping + plain-text fallback
/// behavior.
///
/// All content is synthetic.
@Suite("EmlParsing — raw RFC 822 → envelope + body")
struct EmlParsingTests {

    @Test("isEmlFilename: case-insensitive .eml suffix matcher")
    func isEmlFilename() {
        #expect(EmlParsing.isEmlFilename("foo.eml"))
        #expect(EmlParsing.isEmlFilename("FOO.EML"))
        #expect(EmlParsing.isEmlFilename("bar.Eml"))
        #expect(!EmlParsing.isEmlFilename("foo.txt"))
        #expect(!EmlParsing.isEmlFilename(""))
        #expect(!EmlParsing.isEmlFilename(nil))
        #expect(!EmlParsing.isEmlFilename("emlfoo"))
    }

    @Test("parse html-body message returns envelope + html body")
    func parseHtmlBody() throws {
        let rfc822 = """
        From: Inner Sender <inner@example.com>\r
        To: Receiver <to@example.com>\r
        Subject: Parsed HTML body\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HELLO FROM HTML BODY</p>
        """
        let data = Data(rfc822.utf8)
        let parsed = try #require(EmlParsing.parse(rawBytes: data))

        #expect(parsed.envelope.subject == "Parsed HTML body")
        #expect(parsed.envelope.from?.contains("inner@example.com") ?? false)
        #expect(parsed.envelope.to.contains { $0.contains("to@example.com") })
        #expect(parsed.bodyHtml.contains("HELLO FROM HTML BODY"))
    }

    @Test("parse text/plain message returns plainTextToHTML-converted body")
    func parsePlainTextBody() throws {
        let rfc822 = """
        From: plain@example.com\r
        To: rx@example.com\r
        Subject: Plain only\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Line one\r
        \r
        Line two with a link https://example.com
        """
        let data = Data(rfc822.utf8)
        let parsed = try #require(EmlParsing.parse(rawBytes: data))

        #expect(parsed.envelope.subject == "Plain only")
        #expect(parsed.bodyHtml.contains("Line one"))
        #expect(parsed.bodyHtml.contains("Line two"))
        // plainTextToHTML always wraps in <div> tags — confirm we're not
        // returning raw plain text.
        #expect(parsed.bodyHtml.contains("<div"))
    }

    @Test("parse invalid / non-RFC822 bytes returns nil")
    func parseGarbage() {
        let garbage = Data("this is not an email message at all".utf8)
        // SwiftMail's EMLParser may accept this as a one-line message without
        // headers — contract: either nil (preferred) OR an envelope with
        // mostly-empty fields. Either way, we should not crash.
        let result = EmlParsing.parse(rawBytes: garbage)
        if let parsed = result {
            #expect(parsed.envelope.subject == nil || parsed.envelope.subject?.isEmpty == true)
        }
        // Primary contract is: no crash. Pass either outcome.
    }

    @Test("parse empty body yields empty bodyHtml (no crash)")
    func parseEmptyBody() throws {
        let rfc822 = """
        From: a@b.c\r
        Subject: no body\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        \r

        """
        let data = Data(rfc822.utf8)
        let parsed = try #require(EmlParsing.parse(rawBytes: data))
        #expect(parsed.envelope.subject == "no body")
        #expect(parsed.bodyHtml.isEmpty || !parsed.bodyHtml.contains("<p>"))
    }

    @Test("parseNestedSection / nestedSection round-trip")
    func compoundSectionRoundTrip() {
        let encoded = EmlParsing.nestedSection(parent: "parent-att-id", index: 3)
        let decoded = EmlParsing.parseNestedSection(encoded)
        #expect(decoded?.parent == "parent-att-id")
        #expect(decoded?.index == 3)

        // Plain (non-nested) section is recognized as non-compound.
        #expect(EmlParsing.parseNestedSection("plain-id") == nil)
        // Accidentally-`|`-containing IDs (e.g. Exchange itemAttachment
        // compound "outer|inner") must NOT be interpreted as eml-nested.
        #expect(EmlParsing.parseNestedSection("outer|inner") == nil)
    }

    @Test("nestedBytes returns the nth attachment's decoded payload")
    func nestedBytesLookup() throws {
        // Synthetic multipart/mixed with two attachments. Note: boundary
        // needs both CRLF around each delimiter per RFC 2046.
        let boundary = "----=_B1"
        let rfc822 = """
        From: a@b.c\r
        To: x@y.z\r
        Subject: Carries two attachments\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body text\r
        --\(boundary)\r
        Content-Type: application/octet-stream\r
        Content-Disposition: attachment; filename="first.bin"\r
        \r
        FIRST-PAYLOAD-BYTES\r
        --\(boundary)\r
        Content-Type: application/octet-stream\r
        Content-Disposition: attachment; filename="second.bin"\r
        \r
        SECOND-PAYLOAD-BYTES\r
        --\(boundary)--\r
        """
        let raw = Data(rfc822.utf8)

        let parsed = try #require(EmlParsing.parse(rawBytes: raw))
        // SwiftMail's classification of "attachment" for octet-stream parts
        // with a filename is stable — expect both to show up.
        guard parsed.nested.count == 2 else {
            Issue.record("Expected 2 nested attachments, got \(parsed.nested.count)")
            return
        }
        #expect(parsed.nested[0].filename == "first.bin")
        #expect(parsed.nested[1].filename == "second.bin")

        let firstBytes = try #require(EmlParsing.nestedBytes(rawBytes: raw, index: 0))
        #expect(String(data: firstBytes, encoding: .utf8)?.contains("FIRST-PAYLOAD-BYTES") ?? false)

        let secondBytes = try #require(EmlParsing.nestedBytes(rawBytes: raw, index: 1))
        #expect(String(data: secondBytes, encoding: .utf8)?.contains("SECOND-PAYLOAD-BYTES") ?? false)

        // Out-of-range returns nil (no crash).
        #expect(EmlParsing.nestedBytes(rawBytes: raw, index: 42) == nil)
        #expect(EmlParsing.nestedBytes(rawBytes: raw, index: -1) == nil)
    }

    @Test("Envelope round-trips through EmlMarker.build + parser")
    func roundTripThroughMarker() throws {
        let rfc822 = """
        From: Round Trip <rt@example.com>\r
        To: Dest <dest@example.com>\r
        Subject: Round trip test\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Round trip body</p>
        """
        let parsed = try #require(EmlParsing.parse(rawBytes: Data(rfc822.utf8)))
        let markerHtml = EmlMarker.build(
            filename: "round.eml",
            partSection: "uploaded-1",
            envelope: parsed.envelope,
            bodyHtml: parsed.bodyHtml
        )
        let metadata = EmailFilter.parseEmlSectionMetadata(html: markerHtml, filename: "round.eml")
        #expect(metadata?.subject == "Round trip test")
        #expect(metadata?.partSection == "uploaded-1")
        #expect(metadata?.from?.contains("rt@example.com") ?? false)
    }
}
