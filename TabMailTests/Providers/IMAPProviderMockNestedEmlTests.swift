/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// End-to-end IMAPProvider tests using `FakeIMAPServer` with multipart
/// BODYSTRUCTURE including a nested `message/rfc822` part.
///
/// Response shapes are verified against RFC 3501 §7.4.2 (FETCH response /
/// body-type-msg) — the nested rfc822 BODYSTRUCTURE includes envelope and a
/// recursive body inside the standard body-fields. Without the recursion,
/// SwiftMail's parser rejects the response and `fetchMessage` fails.
///
/// `.serialized` — FakeIMAPServer binds a listening socket; parallel runs
/// would contend on ephemeral port allocation.
@Suite("IMAPProvider — nested rfc822 end-to-end", .serialized)
struct IMAPProviderMockNestedEmlTests {

    // MARK: - File-uploaded .eml (filename-based, octet-stream, base64 transfer)

    /// Regression test for the "messageNotFound" bug where tapping a nested
    /// attachment inside a file-uploaded `.eml` would throw because the
    /// recursive parent fetch carried `encoding: nil` instead of the outer
    /// `.eml`'s actual transfer encoding. When the outer is base64 (common),
    /// that meant EMLParser received base64 text rather than decoded RFC 822.
    ///
    /// Shape: BODYSTRUCTURE declares an `application/octet-stream` part with
    /// `.eml` filename and `BASE64` transfer encoding. `BODY[<section>]`
    /// returns base64-encoded bytes that decode to a multipart RFC 822
    /// containing a nested PDF.
    @Test("fetchMessage + fetchAttachment round-trip for file-uploaded .eml with base64 transfer")
    func fileUploadedEmlBase64EndToEnd() async throws {
        let topHtml = "<p>TOP BODY</p>"
        let topHtmlBytes = Data(topHtml.utf8)

        let pdfPayloadText = "%%SYNTHETIC-IMAP-PDF%%"

        // The uploaded `.eml` file's content — a complete RFC 822 message
        // with one text/html body and one attachment. The attachment is
        // plain-text-inlined (no transfer encoding) so the test focuses on
        // the OUTER `.eml`'s base64 transfer encoding — that's the
        // encoding-passthrough path that caused the messageNotFound bug.
        let innerRfc822 = """
        From: Uploader <uploader@example.com>\r
        To: Me <me@example.com>\r
        Subject: IMAP NESTED SUBJECT\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="inner-b"\r
        \r
        --inner-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>NESTED BODY</p>\r
        --inner-b\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="imap-nested.pdf"\r
        \r
        \(pdfPayloadText)\r
        --inner-b--\r
        """
        let innerBytes = Data(innerRfc822.utf8)

        // On the IMAP wire, BODY[2] returns the .eml bytes in their
        // transfer-encoded form. Outlook et al. typically base64-encode
        // `.eml` attachments for 7-bit-safe transport.
        let emlOnWire = innerBytes.base64EncodedString()
        let emlOnWireBytes = Data(emlOnWire.utf8)

        // Top-level outer multipart/mixed assembled for the full-message fetch.
        // Needed when callers request BODY[] (we don't in this test, but it
        // keeps the fake self-consistent).
        let outerRaw = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="outer-b"\r
        \r
        --outer-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(topHtml)\r
        --outer-b\r
        Content-Type: application/octet-stream; name="carrier.eml"\r
        Content-Disposition: attachment; filename="carrier.eml"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(emlOnWire)\r
        --outer-b--\r
        """
        let outerBytes = Data(outerRaw.utf8)

        // BODYSTRUCTURE — RFC 3501 §7.4.2 body-type-mpart. The
        // octet-stream part declares BASE64 encoding and a Content-
        // Disposition with filename="carrier.eml".
        let bodystructure = """
        (("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(topHtmlBytes.count) 1)("APPLICATION" "OCTET-STREAM" ("NAME" "carrier.eml") NIL NIL "BASE64" \(emlOnWireBytes.count) NIL ("attachment" ("filename" "carrier.eml"))) "MIXED")
        """

        let outerHeader = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="outer-b"\r
        \r

        """

        let msg = FakeIMAPServer.makeMultipartMessage(
            uid: 77,
            subject: "Outer",
            from: "Outer <outer@example.com>",
            to: "Recipient <recipient@example.com>",
            date: "Thu, 02 Oct 2025 01:50:00 +0000",
            internalDate: "02-Oct-2025 01:50:00 +0000",
            messageID: "<outer@example.com>",
            rawHeader: outerHeader,
            fullMessage: outerBytes,
            bodystructure: bodystructure,
            partBodies: [
                "1": topHtmlBytes,
                "2": emlOnWireBytes   // base64 text on the wire
            ]
        )

        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: "testuser",
            password: "testpass",
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )

        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // === Part 1: fetchMessage surfaces marker + nested PDF ===

        let info = try await provider.fetchMessage(id: "77", folder: "INBOX")
        let html = try #require(info.htmlBody)
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"carrier.eml\""))
        #expect(html.contains("data-subject=\"IMAP NESTED SUBJECT\""))
        #expect(html.contains("NESTED BODY"))

        let nested = info.attachments.first { $0.filename == "imap-nested.pdf" }
        let pdfAtt = try #require(nested)
        #expect(pdfAtt.parentEmlSection == "2")
        let expectedCompound = EmlParsing.nestedSection(parent: "2", index: 0)
        #expect(pdfAtt.section == expectedCompound)
        // The critical invariant: encoding is the PARENT's transfer encoding,
        // not the nested attachment's. Tap-time dispatch uses this to
        // base64-decode the parent correctly before EMLParser sees the bytes.
        #expect(pdfAtt.encoding?.lowercased() == "base64")

        // === Part 2: fetchAttachment compound path — parent's base64 ===
        // === encoding is carried through the recursive call            ===

        let fetchedBytes = try await provider.fetchAttachment(
            messageId: "77", folder: "INBOX",
            section: pdfAtt.section, encoding: pdfAtt.encoding
        )
        let fetchedString = String(data: fetchedBytes, encoding: .utf8) ?? ""
        #expect(fetchedString.contains("%%SYNTHETIC-IMAP-PDF%%"))
    }

    @Test("fetchMessage emits marker for nested message/rfc822 part with BODYSTRUCTURE recursion")
    func nestedRfc822EmitsMarker() async throws {
        // Top-level body (section 1) — text/html.
        let topHtml = "<p>TOP BODY TEXT</p>"
        let topHtmlBytes = Data(topHtml.utf8)

        // Nested body (section 2.1 — inside the rfc822) — text/html.
        let innerHtml = "<p>INNER BODY TEXT</p>"
        let innerHtmlBytes = Data(innerHtml.utf8)

        // Full section 2 (the raw nested rfc822 — used if the provider ever
        // requests BODY[2] as a whole). Matches what a real server returns.
        let innerRfc822 = """
        From: Inner Sender <inner@example.com>\r
        To: To One <to1@example.com>\r
        Subject: Inner subject\r
        Date: Wed, 01 Oct 2025 12:00:00 +0000\r
        Message-ID: <inner@example.com>\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(innerHtml)
        """
        let innerRfc822Bytes = Data(innerRfc822.utf8)

        // Full outer message — multipart/mixed with boundary.
        let boundary = "----=_Part_1_abc"
        let outerRaw = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer subject\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(topHtml)\r
        --\(boundary)\r
        Content-Type: message/rfc822\r
        Content-Disposition: attachment; filename="inner.eml"\r
        \r
        \(innerRfc822)\r
        --\(boundary)--\r
        """
        let outerBytes = Data(outerRaw.utf8)

        // RFC 3501 §7.4.2 body-type-mpart: list of body-type entries then
        // media-subtype. body-type-msg: basic fields + envelope + recursive
        // body + lines.
        // Envelope address list form: ((name source-route local domain))
        let innerEnvelope = """
        ("Wed, 01 Oct 2025 12:00:00 +0000" "Inner subject" (("Inner Sender" NIL "inner" "example.com")) (("Inner Sender" NIL "inner" "example.com")) (("Inner Sender" NIL "inner" "example.com")) (("To One" NIL "to1" "example.com")) NIL NIL NIL "<inner@example.com>")
        """
        let innerBodyStructure = """
        ("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(innerHtmlBytes.count) 1)
        """
        let bodystructure = """
        (("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(topHtmlBytes.count) 1)("MESSAGE" "RFC822" ("NAME" "inner.eml") NIL NIL "7BIT" \(innerRfc822Bytes.count) \(innerEnvelope) \(innerBodyStructure) \(innerRfc822.filter { $0 == "\n" }.count)) "MIXED")
        """

        let outerHeader = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer subject\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r

        """

        let msg = FakeIMAPServer.makeMultipartMessage(
            uid: 42,
            subject: "Outer subject",
            from: "Outer <outer@example.com>",
            to: "Recipient <recipient@example.com>",
            date: "Thu, 02 Oct 2025 01:50:00 +0000",
            internalDate: "02-Oct-2025 01:50:00 +0000",
            messageID: "<outer@example.com>",
            rawHeader: outerHeader,
            fullMessage: outerBytes,
            bodystructure: bodystructure,
            partBodies: [
                "1": topHtmlBytes,
                "2": innerRfc822Bytes,
                "2.1": innerHtmlBytes
            ]
        )

        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: "testuser",
            password: "testpass",
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )

        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let info: FullMessageInfo
        do {
            info = try await provider.fetchMessage(id: "42", folder: "INBOX")
        } catch {
            Issue.record("fetchMessage threw: \(error)")
            return
        }

        // The whole point — htmlBody contains the top body AND the marker for
        // the nested rfc822 part.
        let html = try #require(info.htmlBody)
        #expect(html.contains("TOP BODY TEXT"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("INNER BODY TEXT"))
    }
}
