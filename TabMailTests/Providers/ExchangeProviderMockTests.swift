/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
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

    @Test("A foreign-host Graph nextLink is refused before any authenticated request")
    func foreignHostNextLinkIsRefusedBeforeRequest() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )

        do {
            _ = try await provider.listMessageIdsPage(
                folder: "inbox",
                pageToken: "https://example.com/v1.0/me/messages?$skiptoken=foreign"
            )
            Issue.record("a foreign-host Graph nextLink must be rejected")
        } catch ProviderError.invalidURL {
            // Expected: reject the untrusted absolute URL before authentication or I/O.
        } catch {
            Issue.record("expected ProviderError.invalidURL, got \(error)")
        }

        #expect(http.recordedCalls().isEmpty)
    }

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

@Suite("ExchangeProvider — draft delete HTTP")
struct ExchangeProviderDraftDeleteHTTPTests {
    private func provider(
        _ http: FakeHTTP.Scenario,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String = { _ in
            "initial-token"
        }
    ) -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "owner@example.com",
            accessToken: accessToken,
            session: http.session
        )
    }

    private func delete(
        _ provider: ExchangeProvider,
        draftId: String
    ) async throws {
        try await provider.deleteDraft(identity: .outlook(graphId: draftId))
    }

    private func expectExchangeNetworkError(
        _ error: Error,
        statusCode: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case ProviderError.networkError(let underlying) = error else {
            Issue.record("expected ProviderError.networkError, got \(error)", sourceLocation: sourceLocation)
            return
        }
        let nsError = underlying as NSError
        #expect(nsError.domain == "Exchange", sourceLocation: sourceLocation)
        #expect(nsError.code == statusCode, sourceLocation: sourceLocation)
    }

    @Test("DELETE 204 succeeds through the production owner")
    func deleteSuccess() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-success"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .status(204)
        )

        try await delete(provider(http), draftId: draftId)

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].method == "DELETE")
        #expect(calls[0].url.contains("/v1.0/me/messages/\(draftId)"))
        #expect(calls[0].body == nil)
    }

    @Test("DELETE 404 is idempotent success")
    func deleteAlreadyGone() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-gone"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .status(404)
        )

        try await delete(provider(http), draftId: draftId)

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.method == "DELETE" })
    }

    @Test("DELETE refreshes authentication once after 401 and succeeds")
    func deleteRefreshesOnceAfter401() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-auth"
        let requestCount = Mutex(0)
        http.register(path: "/messages/\(draftId)", method: "DELETE") { _ in
            requestCount.withLock { count in
                count += 1
                return count == 1 ? .status(401) : .status(204)
            }
        }
        let tokenRequests = Mutex<[Bool]>([])

        try await delete(
            provider(http) { forceRefresh in
                tokenRequests.withLock { $0.append(forceRefresh) }
                return forceRefresh ? "fresh-token" : "initial-token"
            },
            draftId: draftId
        )

        let calls = http.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.method == "DELETE" })
        #expect(tokenRequests.withLock { $0 } == [false, true])
    }

    @Test("a second 401 fails after exactly one forced refresh")
    func deleteDoesNotRefreshTwice() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-auth-exhausted"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .status(401)
        )
        let tokenRequests = Mutex<[Bool]>([])

        do {
            try await delete(
                provider(http) { forceRefresh in
                    tokenRequests.withLock { $0.append(forceRefresh) }
                    return forceRefresh ? "fresh-token" : "initial-token"
                },
                draftId: draftId
            )
            Issue.record("a repeated 401 must throw")
        } catch {
            expectExchangeNetworkError(error, statusCode: 401)
        }

        #expect(http.recordedCalls().count == 2)
        #expect(tokenRequests.withLock { $0 } == [false, true])
    }

    @Test("DELETE exhausts the bounded 429 retry policy as a retryable provider failure")
    func deleteExhausts429Retries() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-rate-limited"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .status(429)
        )

        do {
            try await delete(provider(http), draftId: draftId)
            Issue.record("an exhausted 429 must throw")
        } catch {
            expectExchangeNetworkError(error, statusCode: 429)
        }

        // One initial request plus the production helper's three bounded retries.
        #expect(http.recordedCalls().count == 4)
    }

    @Test("DELETE preserves a transport failure for upstream retry")
    func deleteTransportFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-transport"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .transportError(.networkConnectionLost)
        )

        do {
            try await delete(provider(http), draftId: draftId)
            Issue.record("a transport failure must throw")
        } catch {
            let urlError = error as? URLError
            #expect(urlError?.code == .networkConnectionLost)
        }

        #expect(http.recordedCalls().count == 1)
    }

    @Test("a non-retryable HTTP failure is classified without another request")
    func deleteOtherStatusFailsWithoutRetry() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let draftId = "graph-draft-server-error"
        http.register(
            path: "/messages/\(draftId)",
            method: "DELETE",
            response: .status(500)
        )

        do {
            try await delete(provider(http), draftId: draftId)
            Issue.record("a 500 must throw")
        } catch {
            expectExchangeNetworkError(error, statusCode: 500)
        }

        #expect(http.recordedCalls().count == 1)
    }

    @Test("a non-Outlook draft identity fails before authentication or HTTP")
    func deleteRejectsWrongIdentityBeforeNetwork() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let tokenRequests = Mutex<[Bool]>([])
        let exchange = provider(http) { forceRefresh in
            tokenRequests.withLock { $0.append(forceRefresh) }
            return "unused-token"
        }

        do {
            try await exchange.deleteDraft(identity: .gmail(resourceId: "wrong-provider"))
            Issue.record("a non-Outlook identity must throw")
        } catch {
            guard case ProviderError.actionIdentityResolutionFailed = error else {
                Issue.record("expected actionIdentityResolutionFailed, got \(error)")
                return
            }
        }

        #expect(tokenRequests.withLock { $0 }.isEmpty)
        #expect(http.recordedCalls().isEmpty)
    }
}

@Suite("ExchangeProvider — request selection wiring")
struct ExchangeProviderSelectionWiringTests {
    private static let graphBase = "https://graph.microsoft.com/v1.0/me"

    // Literal wire oracles, deliberately independent of production selections.
    // An extra field on a lean header/backfill route is a behavior change and
    // must fail this test rather than updating its own expectation transitively.
    private static let headerFields =
        "id,subject,from,toRecipients,ccRecipients,bccRecipients,replyTo,"
        + "receivedDateTime,isRead,flag,hasAttachments,internetMessageId,"
        + "conversationId,categories,bodyPreview"
    private static let metadataFields = "\(headerFields),parentFolderId"
    private static let backfillFields = "\(headerFields),body"
    private static let fullFields = "\(headerFields),body,parentFolderId"

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "selection-wiring@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )
    }

    private func messageJSON(
        id: String,
        category: String,
        parentFolderId: String? = nil
    ) -> String {
        let parentField = parentFolderId.map { ", \"parentFolderId\": \"\($0)\"" } ?? ""
        return """
        {
          "id": "\(id)",
          "receivedDateTime": "2020-01-14T12:00:00Z",
          "hasAttachments": false,
          "body": {"contentType": "text", "content": "body"},
          "categories": ["\(category)"]\(parentField)
        }
        """
    }

    private func pageJSON(id: String, category: String) -> String {
        "{\"value\":[\(messageJSON(id: id, category: category))]}"
    }

    private func registerRouteResponses(_ http: FakeHTTP.Scenario) {
        http.register(
            path: "/mailFolders/fetch-route/messages?",
            response: .json(raw: pageJSON(id: "fetch-route", category: "category-fetch"))
        )
        http.register(
            path: "/mailFolders/search-route/messages?",
            response: .json(raw: pageJSON(id: "search-route", category: "category-search"))
        )
        http.register(
            path: "/mailFolders/older-route/messages?",
            response: .json(raw: pageJSON(id: "older-route", category: "category-older"))
        )
        http.register(
            path: "/messages/full-route?",
            response: .json(raw: messageJSON(
                id: "full-route", category: "category-full", parentFolderId: "folder-full"))
        )
        http.register(
            path: "/messages/full-route/attachments",
            response: .json(raw: "{\"value\":[]}")
        )
        http.register(
            path: "/messages/backfill-route?",
            response: .json(raw: messageJSON(
                id: "backfill-route", category: "category-backfill"))
        )
        http.register(
            path: "/messages/headers-route?",
            response: .json(raw: messageJSON(
                id: "headers-route", category: "category-headers"))
        )
        http.register(
            path: "/messages/details-route?",
            response: .json(raw: messageJSON(
                id: "details-route", category: "category-details",
                parentFolderId: "folder-details"))
        )
    }

    private func exerciseEveryRoute(
        _ exchange: ExchangeProvider
    ) async throws -> [ExchangeGraphMessageRequest: MessageHeaderInfo] {
        var parsed: [ExchangeGraphMessageRequest: MessageHeaderInfo] = [:]

        let fetched = try await exchange.fetchMessages(
            folder: "fetch-route", limit: 10, offset: 0)
        let fetchedHeader = try #require(fetched.first)
        parsed[.fetchMessages] = fetchedHeader

        let offsetFetched = try await exchange.fetchMessages(
            folder: "fetch-route", limit: 5, offset: 3)
        let offsetHeader = try #require(offsetFetched.first)
        #expect(offsetHeader.userLabelIds == ["category-fetch"])
        #expect(offsetHeader.userLabelIdsAreAuthoritative)

        let full = try await exchange.fetchMessage(id: "full-route", folder: "ignored")
        parsed[.fetchMessage] = full.header

        let backfill = await exchange.fetchBackfillBatch(ids: ["backfill-route"], concurrency: 1)
        var backfillResults: [BackfillResult] = []
        for await result in backfill {
            backfillResults.append(result)
        }
        #expect(backfillResults.count == 1)
        let backfillResult = try #require(backfillResults.first)
        #expect(backfillResult.error == nil)
        let backfillHeader = try #require(backfillResult.header)
        parsed[.fetchSingleBackfill] = backfillHeader

        let searched = try await exchange.search(
            query: "route", folder: "search-route", after: nil, before: nil)
        let searchedHeader = try #require(searched.first)
        parsed[.search] = searchedHeader

        let headers = try await exchange.fetchMessageHeaders(
            ids: ["headers-route"], batchSize: 50, interBatchDelay: 0)
        let listedHeader = try #require(headers.first)
        parsed[.fetchMessageHeaders] = listedHeader

        let older = try await exchange.fetchOlderMessages(
            folder: "older-route", before: Date(timeIntervalSince1970: 1_600_000_000),
            limit: 10)
        let olderHeader = try #require(older.first)
        parsed[.fetchOlderMessages] = olderHeader

        let details = try await exchange.fetchMessageDetails(ids: ["details-route"])
        #expect(details.count == 1)
        let detail = try #require(details.first)
        #expect(detail.parentFolderId == "folder-details")
        parsed[.fetchMessageDetails] = detail.header

        return parsed
    }

    private func normalizedURL(_ raw: String) throws -> String {
        try #require(URL(string: raw)).absoluteString
    }

    private func expectExactURLs(in http: FakeHTTP.Scenario) throws {
        let h = Self.headerFields
        let expected = try [
            normalizedURL(
                "\(Self.graphBase)/mailFolders/fetch-route/messages?$select=\(h)"
                    + "&$top=10&$orderby=receivedDateTime desc"),
            normalizedURL(
                "\(Self.graphBase)/mailFolders/fetch-route/messages?$select=\(h)"
                    + "&$top=5&$orderby=receivedDateTime desc&$skip=3"),
            normalizedURL("\(Self.graphBase)/messages/full-route?$select=\(Self.fullFields)"),
            normalizedURL("\(Self.graphBase)/messages/full-route/attachments"),
            normalizedURL("\(Self.graphBase)/messages/backfill-route?$select=\(Self.backfillFields)"),
            normalizedURL(
                "\(Self.graphBase)/mailFolders/search-route/messages?$select=\(h)"
                    + "&$search=\"route\"&$top=20"),
            normalizedURL("\(Self.graphBase)/messages/headers-route?$select=\(h)"),
            normalizedURL(
                "\(Self.graphBase)/mailFolders/older-route/messages?$select=\(h)"
                    + "&$filter=receivedDateTime lt 2020-09-13T12:26:40Z"
                    + "&$top=10&$orderby=receivedDateTime desc"),
            normalizedURL(
                "\(Self.graphBase)/messages/details-route?$select=\(Self.metadataFields)")
        ]
        #expect(http.recordedCalls().map { $0.url } == expected)
    }

    @Test("Every parser route uses its exact request selection and parses its response")
    func everyRouteUsesItsAssignedSelection() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        registerRouteResponses(http)
        let parsed = try await exerciseEveryRoute(provider(http))
        let expectedCategories: [ExchangeGraphMessageRequest: String] = [
            .fetchMessages: "category-fetch",
            .fetchMessage: "category-full",
            .fetchSingleBackfill: "category-backfill",
            .search: "category-search",
            .fetchMessageHeaders: "category-headers",
            .fetchOlderMessages: "category-older",
            .fetchMessageDetails: "category-details"
        ]

        #expect(parsed.count == ExchangeGraphMessageRequest.allCases.count)
        for route in ExchangeGraphMessageRequest.allCases {
            let header = try #require(parsed[route])
            let category = try #require(expectedCategories[route])
            #expect(header.userLabelIds == [category])
            #expect(header.userLabelIdsAreAuthoritative)
        }
        try expectExactURLs(in: http)
    }
}
