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
/// The legacy static `FakeHTTP` namespace is process-global. Serialize both
/// within this suite and against every other process-global test fixture.
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
        let receivedDate = TestFixtureDate.iso8601(daysFromAnchor: -1)
        let nestedReceivedDate = TestFixtureDate.iso8601(daysFromAnchor: -2)

        // Top-level message JSON — schema per
        // learn.microsoft.com/en-us/graph/api/resources/message
        let topLevelJSON = """
        {
          "id": "\(messageId)",
          "subject": "Top level",
          "from": {"emailAddress": {"name": "Sender", "address": "sender@example.com"}},
          "toRecipients": [{"emailAddress": {"address": "recipient@example.com"}}],
          "receivedDateTime": "\(receivedDate)",
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
            "receivedDateTime": "\(nestedReceivedDate)",
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
        let receivedDate = TestFixtureDate.iso8601(daysFromAnchor: -1)
        let receivedRFC2822Date = TestFixtureDate.rfc2822(daysFromAnchor: -1)

        // Synthesize an RFC 822 `.eml` payload with envelope + one text/html
        // body + one application/pdf attachment. Transfer-encode the PDF bytes
        // as base64 inside the .eml (RFC 2045) so EMLParser's own
        // transfer-decoding gets exercised too.
        let pdfPayloadText = "%%SYNTHETIC-PDF-BYTES%%"
        let innerRfc822 = """
        From: Uploaded <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: ENVELOPE SUBJECT\r
        Date: \(receivedRFC2822Date)\r
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
          "receivedDateTime": "\(receivedDate)",
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
        let receivedDate = TestFixtureDate.iso8601(daysFromAnchor: -1)
        let nestedReceivedDate = TestFixtureDate.iso8601(daysFromAnchor: -2)

        let topLevelJSON = """
        {"id": "\(messageId)", "receivedDateTime": "\(receivedDate)", "hasAttachments": true,
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
            "receivedDateTime": "\(nestedReceivedDate)",
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

@Suite("ExchangeProvider — durable RFC action resolution")
struct ExchangeProviderActionResolutionTests {
    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )
    }

    private func row(id: String, rfc822MessageId: String, folder: String) -> String {
        """
        {"id":"\(id)","internetMessageId":"<\(rfc822MessageId)>","parentFolderId":"\(folder)"}
        """
    }

    private func list(_ rows: [String], nextLink: String? = nil) -> String {
        let next = nextLink.map { #", "@odata.nextLink":"\#($0)""# } ?? ""
        return #"{"value":[\#(rows.joined(separator: ","))]\#(next)}"#
    }

    @Test("legacy Graph id resolves to RFC identity in recorded source")
    func legacyGraphIdResolvesInsideSource() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "graph/legacy+token="
        let rfc822 = "Legacy-Graph@Example.COM"
        http.register(
            path: "/messages/graph%2Flegacy%2Btoken%3D?",
            response: .json(raw: row(
                id: providerId,
                rfc822MessageId: rfc822,
                folder: "source-folder"
            ))
        )

        let result = try await provider(http).resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "source-folder",
            destinationFolder: "destination-folder"
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
        let call = try #require(http.recordedCalls().first)
        let components = try #require(URLComponents(string: call.url))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(call.url.contains("graph%2Flegacy%2Btoken%3D"))
        #expect(query["$select"] == "id,parentFolderId,internetMessageId")
    }

    @Test("legacy Graph id resolves in recorded optimistic destination")
    func legacyGraphIdResolvesInsideDestination() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "graph-legacy-destination"
        let rfc822 = "legacy-destination@example.com"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: row(
                id: providerId,
                rfc822MessageId: rfc822,
                folder: "destination-folder"
            ))
        )

        let result = try await provider(http).resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "source-folder",
            destinationFolder: "destination-folder"
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
    }

    @Test("legacy Graph id outside both recorded folders is stale")
    func legacyGraphIdOutsideScopeIsStale() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "graph-legacy-elsewhere"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: row(
                id: providerId,
                rfc822MessageId: "legacy-elsewhere@example.com",
                folder: "other-folder"
            ))
        )

        let result = try await provider(http).resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "source-folder",
            destinationFolder: "destination-folder"
        )

        #expect(result == .staleOrAmbiguous)
    }

    @Test("legacy Graph id 404 is authoritative stale")
    func legacyGraphIdGoneIsStale() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "graph-legacy-gone"
        http.register(path: "/messages/\(providerId)?", response: .status(404))

        let result = try await provider(http).resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "source-folder",
            destinationFolder: nil
        )

        #expect(result == .staleOrAmbiguous)
    }

    @Test("malformed legacy Graph metadata is retryable uncertainty")
    func malformedLegacyGraphMetadataThrows() async {
        let responses = [
            #"{"id":"graph-legacy-malformed","parentFolderId":"source-folder"}"#,
            #"{"id":"different","internetMessageId":"<legacy@example.com>","parentFolderId":"source-folder"}"#,
            #"{"id":"graph-legacy-malformed","internetMessageId":"opaque","parentFolderId":"source-folder"}"#,
            #"{"id":"graph-legacy-malformed","internetMessageId":"<legacy@example.com>","parentFolderId":" "}"#,
            #"{"id":"graph-legacy-malformed","internetMessageId":"<legacy@example.com>","parentFolderId":"source\u0001folder"}"#,
        ]
        for response in responses {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/messages/graph-legacy-malformed?",
                response: .json(raw: response)
            )

            do {
                _ = try await provider(http).resolveLegacyMessageActionIdentity(
                    providerMessageId: "graph-legacy-malformed",
                    sourceFolder: "source-folder",
                    destinationFolder: nil
                )
                Issue.record("malformed legacy Graph metadata must throw")
            } catch {}
        }
    }

    @Test("invalid legacy Graph folder scope throws before networking")
    func invalidLegacyGraphFolderScopeThrowsBeforeNetworking() async {
        let inputs = [
            (source: " ", destination: Optional("destination-folder")),
            (source: "source\u{0001}folder", destination: Optional("destination-folder")),
            (source: "source-folder", destination: Optional(" destination-folder")),
            (source: "source-folder", destination: Optional("destination\u{0001}folder")),
        ]
        for input in inputs {
            let http = FakeHTTP.Scenario()
            defer { http.close() }

            do {
                _ = try await provider(http).resolveLegacyMessageActionIdentity(
                    providerMessageId: "graph-legacy-invalid-scope",
                    sourceFolder: input.source,
                    destinationFolder: input.destination
                )
                Issue.record("invalid legacy Graph folder scope must throw")
            } catch {}
            #expect(http.recordedCalls().isEmpty)
        }
    }

    @Test("non-gone legacy Graph lookup failure is retryable uncertainty")
    func legacyGraphLookupFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "graph-legacy-uncertain"
        http.register(path: "/messages/\(providerId)?", response: .status(400))

        do {
            _ = try await provider(http).resolveLegacyMessageActionIdentity(
                providerMessageId: providerId,
                sourceFolder: "source-folder",
                destinationFolder: nil
            )
            Issue.record("non-gone legacy Graph failure must throw")
        } catch {}
    }

    @Test("exact RFC match uses encoded OData lookup and transient Graph id")
    func exactMatchUsesTransientGraphId() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let rfc822 = "O'Hare+Case@Example.COM"
        let source = "source-folder"
        let providerId = "graph-now"
        http.register(
            path: "/mailFolders/\(source)/messages",
            response: .json(raw: list([row(
                id: providerId,
                rfc822MessageId: rfc822,
                folder: source
            )]))
        )
        http.register(
            path: "/messages/\(providerId)",
            method: "PATCH",
            response: .json(raw: "{}")
        )

        try await provider(http).markRead(ids: [rfc822], folder: source)

        let calls = http.recordedCalls()
        let listCall = try #require(calls.first(where: { $0.method == "GET" }))
        let components = try #require(URLComponents(string: listCall.url))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(components.path.hasSuffix("/mailFolders/\(source)/messages"))
        #expect(query["$select"] == "id,parentFolderId,internetMessageId")
        #expect(query["$top"] == "2")
        #expect(query["$filter"] == "internetMessageId eq '<O''Hare+Case@Example.COM>'")
        #expect(listCall.url.contains("%2B"))
        let patchCalls = calls.filter { $0.method == "PATCH" }
        #expect(patchCalls.count == 1)
        guard patchCalls.count == 1, let bodyData = patchCalls[0].body else { return }
        #expect(patchCalls[0].url.contains("/messages/\(providerId)"))
        #expect(!patchCalls[0].url.contains(rfc822))
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["isRead"] as? Bool == true)
    }

    @Test("invalid RFC identity or blank source fails closed")
    func invalidIdentityOrSourceMakesNoRequest() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let exchange = provider(http)

        try await exchange.markRead(ids: ["bad\r@example.com"], folder: "source")
        try await exchange.markRead(ids: ["valid@example.com"], folder: " \n ")

        #expect(http.recordedCalls().isEmpty)
    }

    @Test("zero and multiple RFC matches are stale no-ops")
    func zeroAndMultipleMatchesDoNotMutate() async throws {
        for response in [
            list([]),
            list([
                row(id: "one", rfc822MessageId: "target@example.com", folder: "source"),
                row(id: "two", rfc822MessageId: "target@example.com", folder: "source"),
            ]),
        ] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/mailFolders/source/messages", response: .json(raw: response))

            try await provider(http).markRead(ids: ["target@example.com"], folder: "source")

            #expect(http.recordedCalls().filter { $0.method == "GET" }.count == 1)
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }
    }

    @Test("Graph paging is followed until exact or ambiguous")
    func pagingIsExhaustedBeforeMutation() async throws {
        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let next = "https://graph.microsoft.com/v1.0/me/action-page-empty"
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "only", rfc822MessageId: "target@example.com", folder: "source"),
                ], nextLink: next))
            )
            http.register(path: "/action-page-empty", response: .json(raw: list([])))
            http.register(
                path: "/messages/only",
                method: "PATCH",
                response: .json(raw: "{}")
            )

            try await provider(http).markRead(ids: ["target@example.com"], folder: "source")

            #expect(http.recordedCalls().contains { $0.url.contains("/action-page-empty") })
            #expect(http.recordedCalls().filter { $0.method == "PATCH" }.count == 1)
        }

        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let next = "https://graph.microsoft.com/v1.0/me/action-page-second"
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "one", rfc822MessageId: "target@example.com", folder: "source"),
                ], nextLink: next))
            )
            http.register(
                path: "/action-page-second",
                response: .json(raw: list([
                    row(id: "two", rfc822MessageId: "target@example.com", folder: "source"),
                ]))
            )

            try await provider(http).markRead(ids: ["target@example.com"], folder: "source")

            #expect(http.recordedCalls().contains { $0.url.contains("/action-page-second") })
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }
    }

    @Test("missing or contradictory selected fields throw without mutation")
    func malformedSelectedFieldsThrow() async {
        let responses = [
            #"{"value":[{"id":"candidate","parentFolderId":"source"}]}"#,
            #"{"value":[{"id":"candidate","internetMessageId":"<target@example.com>"}]}"#,
            #"{"value":[{"id":"   ","internetMessageId":"<target@example.com>","parentFolderId":"source"}]}"#,
            list([row(id: "candidate", rfc822MessageId: "other@example.com", folder: "source")]),
            list([row(id: "candidate", rfc822MessageId: "target@example.com", folder: "other")]),
            list([
                row(id: "valid", rfc822MessageId: "target@example.com", folder: "source"),
                row(id: "contradictory", rfc822MessageId: "other@example.com", folder: "source"),
            ]),
        ]
        for response in responses {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/mailFolders/source/messages", response: .json(raw: response))

            do {
                try await provider(http).markRead(
                    ids: ["target@example.com"],
                    folder: "source"
                )
                Issue.record("missing or contradictory Graph fields must throw")
            } catch {}

            #expect(http.recordedCalls().filter { $0.method == "GET" }.count == 1)
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }
    }

    @Test("folder absence no-ops but failed pagination retries")
    func folderGoneAndPaginationFailureAreClassified() async throws {
        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/mailFolders/source/messages", response: .status(404))

            try await provider(http).markRead(ids: ["target@example.com"], folder: "source")

            #expect(http.recordedCalls().filter { $0.method == "GET" }.count == 1)
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }

        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let next = "https://graph.microsoft.com/v1.0/me/action-page-failure"
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "candidate", rfc822MessageId: "target@example.com", folder: "source"),
                ], nextLink: next))
            )
            http.register(path: "/action-page-failure", response: .status(404))

            do {
                try await provider(http).markRead(
                    ids: ["target@example.com"],
                    folder: "source"
                )
                Issue.record("failed Graph pagination must throw")
            } catch {}

            #expect(http.recordedCalls().contains { $0.url.contains("/action-page-failure") })
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }

        for next in [
            "http://graph.microsoft.com/v1.0/me/unsafe-page",
            "https://example.com/v1.0/me/unsafe-page",
            "https://graph.microsoft.com:444/v1.0/me/unsafe-page",
            "https://user@graph.microsoft.com/v1.0/me/unsafe-page",
        ] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "candidate", rfc822MessageId: "target@example.com", folder: "source"),
                ], nextLink: next))
            )

            do {
                try await provider(http).markRead(
                    ids: ["target@example.com"],
                    folder: "source"
                )
                Issue.record("untrusted Graph pagination origin must throw")
            } catch {}

            #expect(http.recordedCalls().filter { $0.method == "GET" }.count == 1)
            #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
        }
    }

    @Test("later batch lookup failure prevents every mutation")
    func wholeBatchResolvesBeforeMutation() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "%3Cfirst%40example.com%3E",
            response: .json(raw: list([
                row(id: "first-id", rfc822MessageId: "first@example.com", folder: "source"),
            ]))
        )
        http.register(
            path: "%3Csecond%40example.com%3E",
            response: .json(raw: "{")
        )
        http.register(path: "/messages/first-id", method: "PATCH", response: .json(raw: "{}"))

        do {
            try await provider(http).markRead(
                ids: ["first@example.com", "second@example.com"],
                folder: "source"
            )
            Issue.record("later Graph lookup failure must throw")
        } catch {}

        let getCalls = http.recordedCalls().filter { $0.method == "GET" }
        #expect(getCalls.count == 2)
        guard getCalls.count == 2 else { return }
        #expect(getCalls[0].url.contains("%3Cfirst%40example.com%3E"))
        #expect(getCalls[1].url.contains("%3Csecond%40example.com%3E"))
        #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
    }

    @Test("setter bodies are assignments and duplicate RFC members mutate once")
    func setterBodiesAndResolvedDedup() async throws {
        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "unread-id", rfc822MessageId: "target@example.com", folder: "source"),
                ]))
            )
            http.register(path: "/messages/unread-id", method: "PATCH", response: .json(raw: "{}"))

            try await provider(http).markUnread(
                ids: ["target@example.com", "target@example.com"],
                folder: "source"
            )

            let patches = http.recordedCalls().filter { $0.method == "PATCH" }
            #expect(patches.count == 1)
            guard patches.count == 1, let bodyData = patches[0].body else { return }
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(body["isRead"] as? Bool == false)
        }

        for (flagged, status) in [(true, "flagged"), (false, "notFlagged")] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "flag-id", rfc822MessageId: "target@example.com", folder: "source"),
                ]))
            )
            http.register(path: "/messages/flag-id", method: "PATCH", response: .json(raw: "{}"))

            try await provider(http).markFlagged(
                ids: ["target@example.com"],
                flagged: flagged,
                folder: "source"
            )

            let patch = try #require(http.recordedCalls().first { $0.method == "PATCH" })
            let bodyData = try #require(patch.body)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let flag = try #require(body["flag"] as? [String: Any])
            #expect(flag["flagStatus"] as? String == status)
        }
    }

    @Test("mutation disappearance no-ops and inverse move re-resolves RFC identity")
    func mutationGoneAndMoveIdChurn() async throws {
        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/mailFolders/source/messages",
                response: .json(raw: list([
                    row(id: "gone-patch", rfc822MessageId: "target@example.com", folder: "source"),
                ]))
            )
            http.register(path: "/messages/gone-patch", method: "PATCH", response: .status(404))

            try await provider(http).markRead(ids: ["target@example.com"], folder: "source")

            let patches = http.recordedCalls().filter { $0.method == "PATCH" }
            #expect(patches.count == 1)
            guard patches.count == 1 else { return }
            #expect(patches[0].url.contains("/messages/gone-patch"))
        }

        do {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(
                path: "/mailFolders/source-a/messages",
                response: .json(raw: list([
                    row(id: "graph-before", rfc822MessageId: "move@example.com", folder: "source-a"),
                ]))
            )
            http.register(
                path: "/mailFolders/source-b/messages",
                response: .json(raw: list([
                    row(id: "graph-after", rfc822MessageId: "move@example.com", folder: "source-b"),
                ]))
            )
            http.register(
                path: "/messages/graph-before/move",
                method: "POST",
                response: .json(raw: "{")
            )
            http.register(
                path: "/messages/graph-after/move",
                method: "POST",
                response: .status(410)
            )
            let exchange = provider(http)

            try await exchange.move(
                ids: ["move@example.com"],
                from: "source-a",
                to: "source-b"
            )
            try await exchange.move(
                ids: ["move@example.com"],
                from: "source-b",
                to: "source-a"
            )

            let calls = http.recordedCalls()
            let posts = calls.filter { $0.method == "POST" }
            #expect(posts.count == 2)
            guard posts.count == 2 else { return }
            #expect(posts[0].url.contains("/messages/graph-before/move"))
            #expect(posts[1].url.contains("/messages/graph-after/move"))
            #expect(!calls.contains { $0.url.contains("translateExchangeIds") })
        }
    }
}
