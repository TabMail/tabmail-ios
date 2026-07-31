/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Integration tests for `ExchangeProvider.fetchMessage` and `fetchAttachment`
/// via the URLProtocol-level `FakeHTTP` mock.
///
/// These cover the three Microsoft Graph paths that are load-bearing for
/// `.eml`-style nested message rendering:
///
/// 1. `#microsoft.graph.itemAttachment` discovery on a message → `$expand` call
///    on `microsoft.graph.itemattachment/item` → marker emission + nested
///    attachment classification, including the required SECOND list call to
///    `.../microsoft.graph.itemattachment/item/attachments` (Graph's nested
///    `$expand` does not reliably return nested attachments — documented
///    limitation).
/// 2. The compound `"outerId|innerId"` section format built at marker time →
///    `fetchAttachment` routes the download to
///    `.../microsoft.graph.itemattachment/item/attachments/{innerId}`.
/// 3. Performance guard: when the nested `item.hasAttachments == false`, no
///    fallback list call is made (one round-trip saved per expansion).
///
/// All response bodies are synthesised at test time from the schema cited in
/// `TabMailTests/Fixtures/README.md` (Microsoft Graph v1.0 — attachment
/// resource, itemAttachment resource, attachment-get, attachment-list).
/// `.serialized` — `FakeHTTP` state is process-global. Running tests in this
/// suite in parallel would race on matcher registration.
@Suite("ExchangeProvider — HTTP-level integration", .serialized, .processGlobalState)
struct ExchangeProviderMockTests {

    // MARK: - Test 1: itemAttachment expand + nested-list fallback + marker

    @Test("fetchMessage expands itemAttachment, lists nested children, emits marker")
    func itemAttachmentExpandAndFallback() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-graph-1"
        let outerAttId = "outer-itemattachment-id"
        let innerPdfId = "inner-pdf-id"

        // Top-level message JSON — schema per
        // learn.microsoft.com/en-us/graph/api/resources/message
        let topLevelJSON = """
        {
          "id": "\(messageId)",
          "subject": "Top level",
          "from": {"emailAddress": {"name": "Sender", "address": "sender@example.com"}},
          "toRecipients": [{"emailAddress": {"address": "recipient@example.com"}}],
          "receivedDateTime": "2025-10-02T01:50:00Z",
          "isRead": true,
          "hasAttachments": true,
          "body": {"contentType": "html", "content": "<p>Outer body</p>"}
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: topLevelJSON))

        // /attachments list — one itemAttachment, no file attachments.
        // Schema per learn.microsoft.com/en-us/graph/api/message-list-attachments.
        let attachmentsJSON = """
        {
          "value": [
            {
              "@odata.type": "#microsoft.graph.itemAttachment",
              "id": "\(outerAttId)",
              "name": "Fwd: nested message.eml",
              "contentType": "message/rfc822",
              "size": 9876,
              "isInline": false
            }
          ]
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)/attachments", method: "GET", response: .json(raw: attachmentsJSON))

        // $expand call — returns envelope + body + hasAttachments=true, but no
        // attachments list (Graph's nested expand limitation, verified against
        // learn.microsoft.com/en-us/answers/questions/1013332/).
        let expandedJSON = """
        {
          "@odata.type": "#microsoft.graph.itemAttachment",
          "id": "\(outerAttId)",
          "name": "Fwd: nested message.eml",
          "contentType": "message/rfc822",
          "size": 9876,
          "item": {
            "subject": "Nested message subject",
            "from": {"emailAddress": {"name": "Nested Sender", "address": "nested@example.com"}},
            "toRecipients": [{"emailAddress": {"address": "to1@example.com"}}, {"emailAddress": {"address": "to2@example.com"}}],
            "receivedDateTime": "2025-10-01T12:00:00Z",
            "body": {"contentType": "html", "content": "<p>Nested body text</p>"},
            "hasAttachments": true
          }
        }
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(outerAttId)?",
            method: "GET",
            response: .json(raw: expandedJSON)
        )

        // Fallback list call for nested attachments — documented path.
        let nestedListJSON = """
        {
          "value": [
            {
              "@odata.type": "#microsoft.graph.fileAttachment",
              "id": "\(innerPdfId)",
              "name": "nested-report.pdf",
              "contentType": "application/pdf",
              "size": 54321,
              "isInline": false
            }
          ]
        }
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(outerAttId)/microsoft.graph.itemattachment/item/attachments",
            method: "GET",
            response: .json(raw: nestedListJSON)
        )

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")

        // Top body + marker concatenated into htmlBody.
        let html = try #require(info.htmlBody)
        #expect(html.contains("Outer body"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"Fwd: nested message.eml\""))
        #expect(html.contains("data-subject=\"Nested message subject\""))
        #expect(html.contains("Nested body text"))

        // Top-level attachment (the .eml itself) + nested PDF both appear.
        #expect(info.attachments.count == 2)
        let topLevel = info.attachments.first { $0.section == outerAttId }
        #expect(topLevel != nil)
        #expect(topLevel?.parentEmlSection == nil)

        let nested = info.attachments.first { $0.filename == "nested-report.pdf" }
        let pdf = try #require(nested)
        #expect(pdf.parentEmlSection == outerAttId)
        #expect(pdf.section == "\(outerAttId)|\(innerPdfId)")  // compound format
        #expect(pdf.contentType == "application/pdf")

        // Confirm the fallback URL was hit — the whole point of this test.
        let calls = FakeHTTP.recordedCalls().map { $0.url }
        #expect(calls.contains { $0.contains("/microsoft.graph.itemattachment/item/attachments") && !$0.contains("/attachments/\(innerPdfId)") })
    }

    // MARK: - Test 2: compound section → correct download URL

    @Test("fetchAttachment with compound section routes to the nested-item URL")
    func compoundSectionDownloadsFromNestedItemPath() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-download"
        let outerAttId = "outer-id"
        let innerAttId = "inner-id"
        let fileBytes = Data("hello nested attachment".utf8)
        let base64 = fileBytes.base64EncodedString()

        let expectedPath = "/messages/\(messageId)/attachments/\(outerAttId)/microsoft.graph.itemattachment/item/attachments/\(innerAttId)"

        // Graph returns fileAttachment JSON with contentBytes (standard base64).
        // Source: learn.microsoft.com/en-us/graph/api/resources/fileattachment.
        let responseJSON = """
        {
          "@odata.type": "#microsoft.graph.fileAttachment",
          "id": "\(innerAttId)",
          "name": "leaf.pdf",
          "contentType": "application/pdf",
          "size": \(fileBytes.count),
          "contentBytes": "\(base64)"
        }
        """
        FakeHTTP.register(path: expectedPath, method: "GET", response: .json(raw: responseJSON))

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        let compoundId = "\(outerAttId)|\(innerAttId)"
        let data = try await provider.fetchAttachment(messageId: messageId, attachmentId: compoundId)

        #expect(data == fileBytes)
        // Verify the exact URL segment was used — the whole point.
        let urls = FakeHTTP.recordedCalls().map { $0.url }
        #expect(urls.contains { $0.contains(expectedPath) })
        #expect(!urls.contains { $0.contains("/attachments/\(compoundId)") })  // NOT the plain form
    }

    // MARK: - Test 2.5: file-uploaded .eml (filename-based, fileAttachment)

    @Test("fetchMessage + fetchAttachment round-trip for file-uploaded .eml with nested PDF")
    func fileUploadedEmlEndToEnd() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-upload"
        let emlAttId = "uploaded-eml-attid"

        // Synthesize an RFC 822 `.eml` payload with envelope + one text/html
        // body + one application/pdf attachment. Transfer-encode the PDF bytes
        // as base64 inside the .eml (RFC 2045) so EMLParser's own
        // transfer-decoding gets exercised too.
        let pdfPayloadText = "%%SYNTHETIC-PDF-BYTES%%"
        let innerRfc822 = """
        From: Uploaded <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: ENVELOPE SUBJECT\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="inner-b"\r
        \r
        --inner-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>INNER BODY</p>\r
        --inner-b\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="nested-report.pdf"\r
        \r
        \(pdfPayloadText)\r
        --inner-b--\r
        """
        let innerBytes = Data(innerRfc822.utf8)

        // Graph message with hasAttachments=true, then one fileAttachment
        // whose filename ends `.eml`. Schema per learn.microsoft.com/
        // en-us/graph/api/resources/fileattachment.
        let topLevelJSON = """
        {
          "id": "\(messageId)",
          "subject": "Outer",
          "from": {"emailAddress": {"address": "outer@example.com"}},
          "receivedDateTime": "2025-10-02T01:50:00Z",
          "hasAttachments": true,
          "body": {"contentType": "html", "content": "<p>top body</p>"}
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: topLevelJSON))

        let attachmentsListJSON = """
        {
          "value": [
            {
              "@odata.type": "#microsoft.graph.fileAttachment",
              "id": "\(emlAttId)",
              "name": "report.eml",
              "contentType": "application/octet-stream",
              "size": \(innerBytes.count),
              "isInline": false
            }
          ]
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)/attachments", method: "GET", response: .json(raw: attachmentsListJSON))

        // fileAttachment detail: contentBytes is standard base64 of the
        // entire .eml file payload (Graph always returns contentBytes
        // base64-encoded, per attachment-get reference).
        let fileAttachmentJSON = """
        {
          "@odata.type": "#microsoft.graph.fileAttachment",
          "id": "\(emlAttId)",
          "name": "report.eml",
          "contentType": "application/octet-stream",
          "size": \(innerBytes.count),
          "contentBytes": "\(innerBytes.base64EncodedString())"
        }
        """
        FakeHTTP.register(path: "/messages/\(messageId)/attachments/\(emlAttId)", method: "GET", response: .json(raw: fileAttachmentJSON))

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        // === Part 1: fetchMessage surfaces marker + nested attachment ===

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)

        #expect(html.contains("top body"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"report.eml\""))
        #expect(html.contains("data-subject=\"ENVELOPE SUBJECT\""))
        #expect(html.contains("INNER BODY"))

        let topLevel = info.attachments.first { $0.section == emlAttId }
        #expect(topLevel != nil)
        #expect(topLevel?.parentEmlSection == nil)

        let nested = info.attachments.first { $0.filename == "nested-report.pdf" }
        let pdfAtt = try #require(nested)
        #expect(pdfAtt.parentEmlSection == emlAttId)
        #expect(pdfAtt.contentType == "application/pdf")
        let expectedCompound = EmlParsing.nestedSection(parent: emlAttId, index: 0)
        #expect(pdfAtt.section == expectedCompound)

        // === Part 2: fetchAttachment compound path returns nested bytes ===

        let fetchedBytes = try await provider.fetchAttachment(
            messageId: messageId, attachmentId: pdfAtt.section
        )
        // EMLParser may include trailing line-ending bytes; check content
        // instead of exact byte-count match.
        let fetchedString = String(data: fetchedBytes, encoding: .utf8) ?? ""
        #expect(fetchedString.contains("%%SYNTHETIC-PDF-BYTES%%"))
    }

    // MARK: - Test 3: hasAttachments=false → no fallback list call

    @Test("fetchMessage skips nested-list call when inner item.hasAttachments == false")
    func skipsFallbackWhenNoNestedAttachments() async throws {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }

        let messageId = "msg-no-nested"
        let outerAttId = "outer-id"

        let topLevelJSON = """
        {"id": "\(messageId)", "receivedDateTime": "2025-10-02T01:50:00Z", "hasAttachments": true,
         "body": {"contentType": "html", "content": "<p>Top</p>"}}
        """
        FakeHTTP.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: topLevelJSON))

        let attachmentsJSON = """
        {"value": [{"@odata.type": "#microsoft.graph.itemAttachment", "id": "\(outerAttId)",
                    "name": "small.eml", "contentType": "message/rfc822", "size": 100, "isInline": false}]}
        """
        FakeHTTP.register(path: "/messages/\(messageId)/attachments", method: "GET", response: .json(raw: attachmentsJSON))

        // Expand returns hasAttachments=false — no fallback call expected.
        let expandedJSON = """
        {
          "@odata.type": "#microsoft.graph.itemAttachment",
          "id": "\(outerAttId)",
          "name": "small.eml",
          "item": {
            "subject": "Small nested",
            "receivedDateTime": "2025-10-01T12:00:00Z",
            "body": {"contentType": "html", "content": "<p>Tiny</p>"},
            "hasAttachments": false
          }
        }
        """
        FakeHTTP.register(
            path: "/messages/\(messageId)/attachments/\(outerAttId)?",
            method: "GET",
            response: .json(raw: expandedJSON)
        )

        // Intentionally DO NOT register the fallback URL — if the provider
        // calls it, FakeHTTP returns 599 and decoding throws, the enclosing
        // try/catch logs + swallows, and the marker still renders without
        // children. The assertion below checks the URL was never touched.

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: FakeHTTP.makeSession()
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)
        #expect(html.contains("class=\"tm-eml-section\""))

        // Only the .eml top-level chip — no nested PDFs.
        #expect(info.attachments.count == 1)
        #expect(info.attachments.first?.parentEmlSection == nil)

        // Verify fallback URL was NOT called.
        let urls = FakeHTTP.recordedCalls().map { $0.url }
        let fallbackPrefix = "/microsoft.graph.itemattachment/item/attachments"
        #expect(!urls.contains { $0.contains(fallbackPrefix) })
    }
}
