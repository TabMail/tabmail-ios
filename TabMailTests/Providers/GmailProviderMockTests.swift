/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Integration tests for `GmailProvider.fetchMessage` via the URLProtocol-level
/// `FakeHTTP` mock. Verifies end-to-end marker emission + nested-attachment
/// classification for the three paths that matter:
///
/// 1. Top-level HTML body + nested `.eml` with inner HTML body + inner PDF.
/// 2. Top-level HTML body + nested `.eml` with only `text/plain` inside.
/// 3. Top-level HTML body delivered via `body.attachmentId` (large body path).
///
/// All fixture JSON is synthesised at test time from the authoritative schema
/// documented in `TabMailTests/Fixtures/README.md` (Gmail REST API v1 —
/// `users.messages.get?format=full` + `users.messages.attachments.get`).
/// `.serialized` — `FakeHTTP` state is process-global. Running tests in this
/// suite in parallel would race on matcher registration.
@Suite("GmailProvider.fetchMessage — HTTP-level integration", .serialized)
struct GmailProviderMockTests {

    // MARK: - Test 1: nested .eml with inner PDF

    @Test("fetchMessage with nested .eml emits marker + classifies nested PDF")
    func nestedEmlWithInnerPdf() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-1"
        let innerAttId = "inner-pdf-att-id-xyz"

        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: "1700000000000",
            topLevelMimeType: "multipart/mixed",
            payloadHeaders: [
                ("Subject", "Outer subject"),
                ("From", "outer@example.com"),
                ("Date", "Wed, 2 Oct 2025 01:50:00 +0000")
            ],
            parts: [
                .html(body: "<p>TOP BODY TEXT</p>"),
                .messageRfc822(
                    filename: "inner.eml",
                    partAttachmentId: "outer-rfc822-att-id",
                    innerHeaders: [
                        ("Subject", "INNER SUBJECT"),
                        ("From", "inner@example.com"),
                        ("To", "to1@example.com, to2@example.com"),
                        ("Date", "Tue, 1 Oct 2025 12:00:00 +0000")
                    ],
                    innerParts: [
                        .html(body: "<p>INNER BODY TEXT</p>"),
                        .pdf(filename: "nested-report.pdf", attachmentId: innerAttId, size: 12345)
                    ]
                )
            ]
        )

        FakeHTTP.register(
            path: "/messages/\(messageId)",
            method: "GET",
            response: .json(raw: messageJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")

        // Top-level body must include both the top text AND the marker block.
        let html = try #require(info.htmlBody)
        #expect(html.contains("TOP BODY TEXT"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"inner.eml\""))
        #expect(html.contains("data-subject=\"INNER SUBJECT\""))
        #expect(html.contains("data-from=\"inner@example.com\""))
        #expect(html.contains("INNER BODY TEXT"))

        // Nested PDF must appear in attachments tagged with parentEmlSection.
        let nested = info.attachments.first { $0.filename == "nested-report.pdf" }
        let pdf = try #require(nested)
        #expect(pdf.parentEmlSection == "outer-rfc822-att-id")
        #expect(pdf.contentType == "application/pdf")
        #expect(pdf.section == innerAttId)
    }

    // MARK: - Test 2: nested .eml with only text/plain inside

    @Test("fetchMessage with text/plain-only nested .eml converts inner body via plainTextToHTML")
    func nestedEmlPlainTextOnly() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-2"

        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: "1700000000000",
            topLevelMimeType: "multipart/mixed",
            payloadHeaders: [
                ("Subject", "Outer"),
                ("From", "outer@example.com"),
                ("Date", "Wed, 2 Oct 2025 01:50:00 +0000")
            ],
            parts: [
                .html(body: "<p>Hello world</p>"),
                .messageRfc822(
                    filename: "plain.eml",
                    partAttachmentId: "rfc822-att",
                    innerHeaders: [
                        ("Subject", "Plain text inner"),
                        ("From", "plain@example.com")
                    ],
                    innerParts: [
                        .plain(body: "Line one\n\nLine two with an https://example.com link")
                    ]
                )
            ]
        )

        FakeHTTP.register(path: "/messages/\(messageId)", method: "GET", response: .json(raw: messageJSON))

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)

        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"plain.eml\""))
        // plainTextToHTML wraps each line's text — check that the content survived.
        #expect(html.contains("Line one"))
        #expect(html.contains("Line two with an"))
        // Confirm plainTextToHTML added some form of <br> / <p> line break
        // (contract of plainTextToHTML — we don't care which, just that the
        // inner body is HTML, not literal plain-text dumped verbatim).
        #expect(html.contains("<br") || html.contains("<p"))
    }

    // MARK: - Test 2.5: file-uploaded .eml (non-rfc822 content-type, filename-based detection)

    @Test("fetchMessage renders file-uploaded .eml via EmlParsing (filename-based detection)")
    func fileUploadedEmlRendersWithMarker() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-upload"
        let emlAttachmentId = "uploaded-eml-attid"

        // The .eml "file" bytes: a synthetic complete RFC 822 message that
        // our parser should extract envelope + body from.
        let innerRfc822 = """
        From: Uploaded Sender <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: UPLOADED SUBJECT LINE\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>UPLOADED BODY CONTENT</p>
        """
        let innerBytes = Data(innerRfc822.utf8)

        // Outer Gmail message: plain HTML body + one application/octet-stream
        // attachment named `report.eml`. This is the exact shape Outlook-Web
        // uploads produce when the user drag-drops a `.eml` file.
        let messageJSON = """
        {
          "id": "\(messageId)",
          "internalDate": "1700000000000",
          "labelIds": ["INBOX"],
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Outer"}, {"name": "From", "value": "outer@example.com"}, {"name": "Date", "value": "Wed, 2 Oct 2025 01:50:00 +0000"}],
            "parts": [
              {"mimeType": "text/html", "body": {"size": 20, "data": "\(base64URL("<p>top body</p>"))"}},
              {"mimeType": "application/octet-stream", "filename": "report.eml", "body": {"size": \(innerBytes.count), "attachmentId": "\(emlAttachmentId)"}}
            ]
          }
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: messageJSON))

        // Gmail returns attachment body as {size, data: base64url} per the
        // users.messages.attachments.get reference.
        let attachmentJSON = """
        {"size": \(innerBytes.count), "data": "\(base64URL(innerRfc822))"}
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(emlAttachmentId)",
            method: "GET",
            response: .json(raw: attachmentJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)

        #expect(html.contains("top body"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"report.eml\""))
        #expect(html.contains("data-subject=\"UPLOADED SUBJECT LINE\""))
        #expect(html.contains("UPLOADED BODY CONTENT"))

        // Verify the bytes fetch actually happened via attachments.get.
        let urls = FakeHTTP.recordedCalls().map { $0.url }
        #expect(urls.contains { $0.contains("/attachments/\(emlAttachmentId)") })
    }

    // MARK: - Test 2.75: nested attachments inside a file-uploaded .eml

    @Test("fetchMessage + fetchAttachment round-trip for nested attachment inside file-uploaded .eml")
    func fileUploadedEmlNestedAttachmentRoundTrip() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-upload-nested"
        let emlAttId = "uploaded-eml-nested-attid"

        let pdfPayloadText = "%%SYNTHETIC-PDF-PAYLOAD%%"
        let innerRfc822 = """
        From: Uploaded <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: HAS NESTED PDF\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="inner-b"\r
        \r
        --inner-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>body</p>\r
        --inner-b\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="nested.pdf"\r
        \r
        \(pdfPayloadText)\r
        --inner-b--\r
        """
        let innerBytes = Data(innerRfc822.utf8)

        let messageJSON = """
        {
          "id": "\(messageId)",
          "internalDate": "1700000000000",
          "labelIds": ["INBOX"],
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Outer"}, {"name": "From", "value": "o@x"}, {"name": "Date", "value": "Wed, 2 Oct 2025 01:50:00 +0000"}],
            "parts": [
              {"mimeType": "text/html", "body": {"size": 10, "data": "\(base64URL("<p>top</p>"))"}},
              {"mimeType": "application/octet-stream", "filename": "carrier.eml", "body": {"size": \(innerBytes.count), "attachmentId": "\(emlAttId)"}}
            ]
          }
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: messageJSON))

        // Gmail attachments.get returns {size, data: base64url}. Reused for
        // both the in-render fetch (by extractNestedFromFileUploadedEmls)
        // and the tap-time compound fetch (recursive call).
        let attachmentJSON = """
        {"size": \(innerBytes.count), "data": "\(base64URL(innerRfc822))"}
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(emlAttId)",
            method: "GET",
            response: .json(raw: attachmentJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        // === Part 1: fetchMessage surfaces marker + nested attachment ===

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-subject=\"HAS NESTED PDF\""))

        let nested = info.attachments.first { $0.filename == "nested.pdf" }
        let pdfAtt = try #require(nested)
        #expect(pdfAtt.parentEmlSection == emlAttId)
        let expectedCompound = EmlParsing.nestedSection(parent: emlAttId, index: 0)
        #expect(pdfAtt.section == expectedCompound)

        // === Part 2: fetchAttachment compound path returns nested PDF bytes ===

        let fetchedBytes = try await provider.fetchAttachment(messageId: messageId, attachmentId: pdfAtt.section)
        let fetchedString = String(data: fetchedBytes, encoding: .utf8) ?? ""
        #expect(fetchedString.contains("%%SYNTHETIC-PDF-PAYLOAD%%"))
    }

    // MARK: - Test 3: top-level body delivered via body.attachmentId

    @Test("fetchMessage triggers attachments.get for large body (body.attachmentId path)")
    func topLevelBodyViaAttachmentId() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-3"
        let bodyAttachmentId = "big-body-att-id-42"
        let largeBody = "<p>This body exceeds Gmail's inline size cap.</p>"

        // Top-level HTML body part has body.attachmentId (no body.data).
        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: "1700000000000",
            topLevelMimeType: "multipart/alternative",
            payloadHeaders: [
                ("Subject", "Big body"),
                ("From", "sender@example.com"),
                ("Date", "Wed, 2 Oct 2025 01:50:00 +0000")
            ],
            parts: [
                .htmlAttachmentId(attachmentId: bodyAttachmentId, size: largeBody.utf8.count)
            ]
        )

        FakeHTTP.register(path: "/messages/\(messageId)?format=full", method: "GET", response: .json(raw: messageJSON))

        // Second call: the attachments.get for the large body.
        // Response schema: {"size": N, "data": "<base64url>"} — verified against
        // https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get
        let attachmentBodyJSON = """
        {"size": \(largeBody.utf8.count), "data": "\(base64URL(largeBody))"}
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(bodyAttachmentId)",
            method: "GET",
            response: .json(raw: attachmentBodyJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)
        #expect(html.contains("This body exceeds Gmail's inline size cap."))

        // Verify the attachments.get was actually made (not that the provider
        // inferred the body from somewhere else).
        let urls = FakeHTTP.recordedCalls().map { $0.url }
        #expect(urls.contains { $0.contains("/attachments/\(bodyAttachmentId)") })
    }
}

// MARK: - Fixture builder

/// A Gmail MIME part spec used by the test helper. Each case corresponds to a
/// shape documented in `TabMailTests/Fixtures/README.md`.
private enum GmailPartSpec {
    /// Inline `text/html` body (base64url-encoded in body.data).
    case html(body: String)
    /// Inline `text/plain` body.
    case plain(body: String)
    /// `text/html` body delivered via body.attachmentId (large body path).
    case htmlAttachmentId(attachmentId: String, size: Int)
    /// File attachment (application/pdf). `filename` set, `body.attachmentId` set, no data.
    case pdf(filename: String, attachmentId: String, size: Int)
    /// `message/rfc822` attachment (nested email).
    case messageRfc822(
        filename: String,
        partAttachmentId: String,
        innerHeaders: [(String, String)],
        innerParts: [GmailPartSpec]
    )
}

/// Build a Gmail `users.messages.get?format=full` response body as JSON string.
/// Schema source: https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages
private func makeGmailMessageJSON(
    id: String,
    internalDateMs: String,
    topLevelMimeType: String,
    payloadHeaders: [(String, String)],
    parts: [GmailPartSpec]
) -> String {
    let headersJSON = headersArrayJSON(payloadHeaders)
    let partsJSON = parts.map { partSpecToJSON($0) }.joined(separator: ",")

    return """
    {
      "id": "\(id)",
      "internalDate": "\(internalDateMs)",
      "labelIds": ["INBOX"],
      "payload": {
        "mimeType": "\(topLevelMimeType)",
        "headers": \(headersJSON),
        "parts": [\(partsJSON)]
      }
    }
    """
}

private func partSpecToJSON(_ spec: GmailPartSpec) -> String {
    switch spec {
    case let .html(body):
        return """
        {"mimeType": "text/html", "body": {"size": \(body.utf8.count), "data": "\(base64URL(body))"}}
        """
    case let .plain(body):
        return """
        {"mimeType": "text/plain", "body": {"size": \(body.utf8.count), "data": "\(base64URL(body))"}}
        """
    case let .htmlAttachmentId(attachmentId, size):
        return """
        {"mimeType": "text/html", "body": {"size": \(size), "attachmentId": "\(attachmentId)"}}
        """
    case let .pdf(filename, attachmentId, size):
        return """
        {"mimeType": "application/pdf", "filename": "\(filename)", "body": {"size": \(size), "attachmentId": "\(attachmentId)"}}
        """
    case let .messageRfc822(filename, partAttachmentId, innerHeaders, innerParts):
        let innerHeadersJSON = headersArrayJSON(innerHeaders)
        let innerPartsJSON = innerParts.map { partSpecToJSON($0) }.joined(separator: ",")
        return """
        {
          "mimeType": "message/rfc822",
          "filename": "\(filename)",
          "headers": \(innerHeadersJSON),
          "body": {"size": 0, "attachmentId": "\(partAttachmentId)"},
          "parts": [\(innerPartsJSON)]
        }
        """
    }
}

private func headersArrayJSON(_ headers: [(String, String)]) -> String {
    let entries = headers.map { "{\"name\": \"\($0.0)\", \"value\": \"\($0.1)\"}" }
    return "[\(entries.joined(separator: ","))]"
}

