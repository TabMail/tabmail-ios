/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// HTTP-level `GmailProvider` integration tests using an isolated `FakeHTTP`
/// scenario per test. The fetch fixtures verify end-to-end marker emission and
/// nested-attachment classification for the three paths that matter:
///
/// 1. Top-level HTML body + nested `.eml` with inner HTML body + inner PDF.
/// 2. Top-level HTML body + nested `.eml` with only `text/plain` inside.
/// 3. Top-level HTML body delivered via `body.attachmentId` (large body path).
///
/// All fixture JSON is synthesised at test time from the authoritative schema
/// documented in `TabMailTests/Fixtures/README.md` (Gmail REST API v1 —
/// `users.messages.get?format=full` + `users.messages.attachments.get`).
@Suite("GmailProvider — HTTP-level integration")
struct GmailProviderMockTests {
    private static let fixtureDateMs = String(TestFixtureDate.milliseconds())
    private static let fixtureRFC2822 = TestFixtureDate.rfc2822()
    private static let previousFixtureRFC2822 = TestFixtureDate.rfc2822(daysFromAnchor: -1)

    private static func actionMetadata(
        id: String,
        rfc822MessageId: String,
        labelIds: [String]? = ["INBOX"]
    ) -> String {
        makeGmailMessageJSON(
            id: id,
            internalDateMs: fixtureDateMs,
            topLevelMimeType: "multipart/alternative",
            payloadHeaders: [
                ("Message-ID", "<\(rfc822MessageId)>"),
                ("Subject", "Action resolution"),
                ("From", "sender@example.com"),
                ("To", "recipient@example.com"),
                ("Date", fixtureRFC2822),
            ],
            parts: [.plain(body: "Action resolution")],
            labelIds: labelIds
        )
    }

    // MARK: - Test 1: nested .eml with inner PDF

    @Test("fetchMessage with nested .eml emits marker + classifies nested PDF")
    func nestedEmlWithInnerPdf() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-1"
        let innerAttId = "inner-pdf-att-id-xyz"

        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: Self.fixtureDateMs,
            topLevelMimeType: "multipart/mixed",
            payloadHeaders: [
                ("Subject", "Outer subject"),
                ("From", "outer@example.com"),
                ("Date", Self.fixtureRFC2822)
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
                        ("Date", Self.previousFixtureRFC2822)
                    ],
                    innerParts: [
                        .html(body: "<p>INNER BODY TEXT</p>"),
                        .pdf(filename: "nested-report.pdf", attachmentId: innerAttId, size: 12345)
                    ]
                )
            ]
        )

        http.register(
            path: "/messages/\(messageId)",
            method: "GET",
            response: .json(raw: messageJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
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
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-2"

        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: Self.fixtureDateMs,
            topLevelMimeType: "multipart/mixed",
            payloadHeaders: [
                ("Subject", "Outer"),
                ("From", "outer@example.com"),
                ("Date", Self.fixtureRFC2822)
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

        http.register(path: "/messages/\(messageId)", method: "GET", response: .json(raw: messageJSON))

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: http.session
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
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-upload"
        let emlAttachmentId = "uploaded-eml-attid"

        // The .eml "file" bytes: a synthetic complete RFC 822 message that
        // our parser should extract envelope + body from.
        let innerRfc822 = """
        From: Uploaded Sender <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: UPLOADED SUBJECT LINE\r
        Date: \(Self.fixtureRFC2822)\r
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
          "internalDate": "\(Self.fixtureDateMs)",
          "labelIds": ["INBOX"],
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Outer"}, {"name": "From", "value": "outer@example.com"}, {"name": "Date", "value": "\(Self.fixtureRFC2822)"}],
            "parts": [
              {"mimeType": "text/html", "body": {"size": 20, "data": "\(base64URL("<p>top body</p>"))"}},
              {"mimeType": "application/octet-stream", "filename": "report.eml", "body": {"size": \(innerBytes.count), "attachmentId": "\(emlAttachmentId)"}}
            ]
          }
        }
        """
        http.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: messageJSON))

        // Gmail returns attachment body as {size, data: base64url} per the
        // users.messages.attachments.get reference.
        let attachmentJSON = """
        {"size": \(innerBytes.count), "data": "\(base64URL(innerRfc822))"}
        """
        http.register(
            path: "/messages/\(messageId)/attachments/\(emlAttachmentId)",
            method: "GET",
            response: .json(raw: attachmentJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: http.session
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)

        #expect(html.contains("top body"))
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"report.eml\""))
        #expect(html.contains("data-subject=\"UPLOADED SUBJECT LINE\""))
        #expect(html.contains("UPLOADED BODY CONTENT"))

        // Verify the bytes fetch actually happened via attachments.get.
        let urls = http.recordedCalls().map { $0.url }
        #expect(urls.contains { $0.contains("/attachments/\(emlAttachmentId)") })
    }

    // MARK: - Test 2.75: nested attachments inside a file-uploaded .eml

    @Test("fetchMessage + fetchAttachment round-trip for nested attachment inside file-uploaded .eml")
    func fileUploadedEmlNestedAttachmentRoundTrip() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-upload-nested"
        let emlAttId = "uploaded-eml-nested-attid"

        let pdfPayloadText = "%%SYNTHETIC-PDF-PAYLOAD%%"
        let innerRfc822 = """
        From: Uploaded <uploaded@example.com>\r
        To: Me <me@example.com>\r
        Subject: HAS NESTED PDF\r
        Date: \(Self.fixtureRFC2822)\r
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
          "internalDate": "\(Self.fixtureDateMs)",
          "labelIds": ["INBOX"],
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Outer"}, {"name": "From", "value": "outer@example.com"}, {"name": "Date", "value": "\(Self.fixtureRFC2822)"}],
            "parts": [
              {"mimeType": "text/html", "body": {"size": 10, "data": "\(base64URL("<p>top</p>"))"}},
              {"mimeType": "application/octet-stream", "filename": "carrier.eml", "body": {"size": \(innerBytes.count), "attachmentId": "\(emlAttId)"}}
            ]
          }
        }
        """
        http.register(path: "/messages/\(messageId)?", method: "GET", response: .json(raw: messageJSON))

        // Gmail attachments.get returns {size, data: base64url}. Reused for
        // both the in-render fetch (by extractNestedFromFileUploadedEmls)
        // and the tap-time compound fetch (recursive call).
        let attachmentJSON = """
        {"size": \(innerBytes.count), "data": "\(base64URL(innerRfc822))"}
        """
        http.register(
            path: "/messages/\(messageId)/attachments/\(emlAttId)",
            method: "GET",
            response: .json(raw: attachmentJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: http.session
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
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-3"
        let bodyAttachmentId = "big-body-att-id-42"
        let largeBody = "<p>This body exceeds Gmail's inline size cap.</p>"

        // Top-level HTML body part has body.attachmentId (no body.data).
        let messageJSON = makeGmailMessageJSON(
            id: messageId,
            internalDateMs: Self.fixtureDateMs,
            topLevelMimeType: "multipart/alternative",
            payloadHeaders: [
                ("Subject", "Big body"),
                ("From", "sender@example.com"),
                ("Date", Self.fixtureRFC2822)
            ],
            parts: [
                .htmlAttachmentId(attachmentId: bodyAttachmentId, size: largeBody.utf8.count)
            ]
        )

        http.register(path: "/messages/\(messageId)?format=full", method: "GET", response: .json(raw: messageJSON))

        // Second call: the attachments.get for the large body.
        // Response schema: {"size": N, "data": "<base64url>"} — verified against
        // https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get
        let attachmentBodyJSON = """
        {"size": \(largeBody.utf8.count), "data": "\(base64URL(largeBody))"}
        """
        http.register(
            path: "/messages/\(messageId)/attachments/\(bodyAttachmentId)",
            method: "GET",
            response: .json(raw: attachmentBodyJSON)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: http.session
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")
        let html = try #require(info.htmlBody)
        #expect(html.contains("This body exceeds Gmail's inline size cap."))

        // Verify the attachments.get was actually made (not that the provider
        // inferred the body from somewhere else).
        let urls = http.recordedCalls().map { $0.url }
        #expect(urls.contains { $0.contains("/attachments/\(bodyAttachmentId)") })
    }

    // MARK: - Test 4: single-part attachment-only message (DMARC report)

    /// Regression: a DMARC aggregate report from Google arrives as a SINGLE-PART
    /// message — the whole payload IS one `application/zip` (no `parts`, no text
    /// body). The attachment lives on the top-level `payload` node, not inside
    /// `payload.parts`. Before the fix, `fetchMessage` only walked `payload.parts`,
    /// so it returned an empty body AND `attachments=0`; the message looked blank
    /// and got stranded forever in the confirmed-empty → reply-retry loop. The body
    /// is legitimately empty (no text part) — what matters is the attachment is
    /// surfaced so `BodyFetchProcessor` routes it through the `[attachment]` path.
    @Test("fetchMessage surfaces the attachment of a single-part (DMARC zip) message")
    func singlePartAttachmentOnlyMessage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let messageId = "msg-dmarc"
        let zipAttId = "dmarc-zip-att-id"
        let intervalStart = Int(TestFixtureDate.daysFromAnchor(-2).timeIntervalSince1970)
        let intervalEnd = Int(TestFixtureDate.daysFromAnchor(-1).timeIntervalSince1970)
        let zipFilename = "domain.com!example.com!\(intervalStart)!\(intervalEnd).zip"

        // Top-level payload IS the zip — note there is NO "parts" key.
        let messageJSON = """
        {
          "id": "\(messageId)",
          "internalDate": "\(Self.fixtureDateMs)",
          "labelIds": ["INBOX"],
          "payload": {
            "mimeType": "application/zip",
            "filename": "\(zipFilename)",
            "headers": [
              {"name": "Subject", "value": "Report domain: example.com Submitter: domain.com"},
              {"name": "From", "value": "reports@domain.com"},
              {"name": "Date", "value": "\(Self.fixtureRFC2822)"},
              {"name": "Content-Disposition", "value": "attachment; filename=\\"\(zipFilename)\\""}
            ],
            "body": {"size": 1234, "attachmentId": "\(zipAttId)"}
          }
        }
        """
        http.register(path: "/messages/\(messageId)", method: "GET", response: .json(raw: messageJSON))

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "tok" },
            session: http.session
        )

        let info = try await provider.fetchMessage(id: messageId, folder: "INBOX")

        // Body is legitimately empty (no text/html or text/plain part).
        #expect(info.htmlBody == nil)
        #expect((info.textBody ?? "").isEmpty)

        // The attachment MUST be surfaced (this is the regression).
        #expect(info.attachments.count == 1)
        guard info.attachments.count == 1 else { return }
        #expect(info.attachments[0].contentType == "application/zip")
        #expect(info.attachments[0].section == zipAttId)
        #expect(info.attachments[0].filename == zipFilename)
        #expect(info.attachments[0].parentEmlSection == nil)
    }

    // MARK: - Durable RFC action resolution

    @Test("legacy provider id resolves to RFC identity inside recorded source scope")
    func legacyProviderIdResolvesInsideRecordedScope() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-source"
        let rfc822 = "legacy-source@example.com"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822,
                labelIds: ["INBOX"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "INBOX",
            destinationFolder: "TRASH"
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
        #expect(http.recordedCalls().count == 1)
    }

    @Test("legacy provider id resolves inside recorded optimistic destination")
    func legacyProviderIdResolvesInsideRecordedDestination() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-destination"
        let rfc822 = "legacy-destination@example.com"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822,
                labelIds: ["TRASH"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "INBOX",
            destinationFolder: "TRASH"
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
    }

    @Test("legacy provider id resolves inside synthetic All Mail scope")
    func legacyProviderIdResolvesInsideSyntheticAllMail() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-archive"
        let rfc822 = "legacy-archive@example.com"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822,
                labelIds: ["CATEGORY_UPDATES", "STARRED"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: GmailProvider.archivePath,
            destinationFolder: nil
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
    }

    @Test("legacy provider id with omitted labels resolves inside synthetic All Mail")
    func legacyProviderIdWithoutLabelsResolvesInsideSyntheticAllMail() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-unlabelled"
        let rfc822 = "legacy-unlabelled@example.com"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822,
                labelIds: nil
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: GmailProvider.archivePath,
            destinationFolder: nil
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
    }

    @Test("legacy provider id is outside synthetic All Mail when an excluded label remains")
    func legacyProviderIdOutsideSyntheticAllMailIsStale() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-inbox"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: "legacy-inbox@example.com",
                labelIds: ["INBOX", "STARRED"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: GmailProvider.archivePath,
            destinationFolder: nil
        )

        #expect(result == .staleOrAmbiguous)
    }

    @Test("legacy provider id outside recorded scope is authoritative stale")
    func legacyProviderIdOutsideRecordedScopeIsStale() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-elsewhere"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: "legacy-elsewhere@example.com",
                labelIds: ["SENT"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "INBOX",
            destinationFolder: "TRASH"
        )

        #expect(result == .staleOrAmbiguous)
    }

    @Test("legacy provider id 404 is authoritative stale")
    func legacyProviderIdGoneIsStale() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-gone"
        http.register(path: "/messages/\(providerId)?", response: .status(404))
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "INBOX",
            destinationFolder: nil
        )

        #expect(result == .staleOrAmbiguous)
    }

    @Test("legacy provider id lookup preserves reserved path characters")
    func legacyProviderIdIsPercentEncoded() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail/legacy+target"
        let rfc822 = "legacy-encoded@example.com"
        http.register(
            path: "/messages/gmail%2Flegacy%2Btarget?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.resolveLegacyMessageActionIdentity(
            providerMessageId: providerId,
            sourceFolder: "INBOX",
            destinationFolder: nil
        )

        #expect(result == .resolved(rfc822MessageId: rfc822))
        #expect(http.recordedCalls().first?.url.contains("gmail%2Flegacy%2Btarget") == true)
    }

    @Test("malformed legacy provider metadata is retryable uncertainty")
    func malformedLegacyProviderMetadataThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-malformed"
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: #"{"id":"gmail-legacy-malformed","labelIds":["INBOX"]}"#)
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            _ = try await provider.resolveLegacyMessageActionIdentity(
                providerMessageId: providerId,
                sourceFolder: "INBOX",
                destinationFolder: nil
            )
            Issue.record("malformed legacy metadata must throw")
        } catch {}
    }

    @Test("non-gone legacy provider lookup failure is retryable uncertainty")
    func legacyProviderLookupFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gmail-legacy-uncertain"
        http.register(path: "/messages/\(providerId)?", response: .status(400))
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            _ = try await provider.resolveLegacyMessageActionIdentity(
                providerMessageId: providerId,
                sourceFolder: "INBOX",
                destinationFolder: nil
            )
            Issue.record("non-gone legacy lookup failure must throw")
        } catch {}
    }

    @Test("markRead resolves one source-scoped RFC identity before mutation")
    func markReadResolvesRFCIdentity() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let rfc822 = "read+target@example.com"
        let providerId = "gmail-read-target"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gmail-read-target","threadId":"thread-read"}]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(id: providerId, rfc822MessageId: rfc822))
        )
        http.register(
            path: "/messages/\(providerId)/modify",
            method: "POST",
            response: .json(raw: "{}")
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(ids: [rfc822], folder: "INBOX")

        let calls = http.recordedCalls()
        let modifyCalls = calls.filter { $0.url.contains("/messages/\(providerId)/modify") }
        #expect(modifyCalls.count == 1)
        guard modifyCalls.count == 1, let bodyData = modifyCalls[0].body else { return }
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["removeLabelIds"] as? [String] == ["UNREAD"])
        let listURL = try #require(calls.first?.url)
        #expect(listURL.contains("rfc822msgid"))
        #expect(listURL.contains("%2B"))
        #expect(listURL.contains("labelIds=INBOX"))
        #expect(listURL.contains("maxResults=2"))
        #expect(listURL.contains("includeSpamTrash=true"))
        let decodedQuery = URLComponents(string: listURL)?.queryItems?
            .first(where: { $0.name == "q" })?.value
        #expect(decodedQuery == "rfc822msgid:\(rfc822)")
    }

    @Test("blank action source fails closed before provider lookup")
    func blankActionSourceDoesNotRequestOrMutate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(ids: ["source@example.com"], folder: " \n ")

        #expect(http.recordedCalls().isEmpty)
    }

    @Test("zero or ambiguous RFC matches are stale no-ops")
    func staleAndAmbiguousRFCMatchesDoNotMutate() async throws {
        for listJSON in [
            #"{"messages":[]}"#,
            #"{"messages":[{"id":"one","threadId":"t1"},{"id":"two","threadId":"t2"}]}"#,
            #"{"messages":[{"id":"one","threadId":"t1"}],"nextPageToken":"more"}"#,
        ] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages?q=", response: .json(raw: listJSON))
            let provider = GmailProvider(
                userEmail: "test@example.com",
                accessToken: { _ in "fake-access-token" },
                session: http.session
            )

            try await provider.markRead(ids: ["stale@example.com"], folder: "INBOX")

            let calls = http.recordedCalls()
            #expect(calls.count == 1)
            #expect(!calls.contains { $0.url.contains("/modify") })
        }
    }

    @Test("mixed action batch skips stale members and deduplicates resolved Gmail ids")
    func mixedActionBatchResolvesBeforeMutation() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let rfc822 = "batch-target@example.com"
        let providerId = "gmail-batch-target"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gmail-batch-target","threadId":"thread-batch"}]}"#)
        )
        http.register(
            path: "q=rfc822msgid%3Astale%40example.com",
            response: .json(raw: #"{"messages":[]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(id: providerId, rfc822MessageId: rfc822))
        )
        http.register(
            path: "/messages/\(providerId)/modify",
            method: "POST",
            response: .json(raw: "{}")
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(
            ids: ["stale@example.com", rfc822, rfc822],
            folder: "INBOX"
        )

        let modifyCalls = http.recordedCalls().filter {
            $0.url.contains("/messages/\(providerId)/modify")
        }
        #expect(modifyCalls.count == 1)
    }

    @Test("later batch lookup failure prevents every mutation")
    func batchResolutionCompletesBeforeMutation() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let firstRFC822 = "first@example.com"
        let firstProviderId = "gmail-first"
        http.register(
            path: "q=rfc822msgid%3Afirst%40example.com",
            response: .json(raw: #"{"messages":[{"id":"gmail-first","threadId":"thread-first"}]}"#)
        )
        http.register(
            path: "/messages/\(firstProviderId)?",
            response: .json(raw: Self.actionMetadata(
                id: firstProviderId,
                rfc822MessageId: firstRFC822
            ))
        )
        http.register(
            path: "q=rfc822msgid%3Asecond%40example.com",
            response: .json(raw: "{")
        )
        http.register(
            path: "/messages/\(firstProviderId)/modify",
            method: "POST",
            response: .json(raw: "{}")
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            try await provider.markRead(
                ids: [firstRFC822, "second@example.com"],
                folder: "INBOX"
            )
            Issue.record("later batch lookup failure must throw")
        } catch {}

        let calls = http.recordedCalls()
        #expect(calls.contains { $0.url.contains("/messages/\(firstProviderId)?") })
        #expect(!calls.contains { $0.url.contains("/modify") })
    }

    @Test("malformed sole-candidate metadata throws without mutation")
    func malformedRFCResolutionThrowsWithoutMutation() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"malformed","threadId":"thread"}]}"#)
        )
        http.register(path: "/messages/malformed?", response: .json(raw: "{}"))
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            try await provider.markRead(ids: ["malformed@example.com"], folder: "INBOX")
            Issue.record("malformed resolver metadata must throw")
        } catch {}

        let calls = http.recordedCalls()
        #expect(calls.count == 2)
        #expect(!calls.contains { $0.url.contains("/modify") })
    }

    @Test("contradictory sole-candidate RFC metadata throws without mutation")
    func contradictoryRFCMetadataThrowsWithoutMutation() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "contradictory"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"contradictory","threadId":"thread"}]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: "different@example.com"
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            try await provider.markRead(ids: ["requested@example.com"], folder: "INBOX")
            Issue.record("contradictory resolver metadata must throw")
        } catch {}

        #expect(!http.recordedCalls().contains { $0.url.contains("/modify") })
    }

    @Test("candidate outside recorded source is a stale no-op")
    func sourceMembershipMismatchDoesNotMutate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let rfc822 = "moved@example.com"
        let providerId = "moved-candidate"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"moved-candidate","threadId":"thread"}]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(
                id: providerId,
                rfc822MessageId: rfc822,
                labelIds: ["OTHER"]
            ))
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(ids: [rfc822], folder: "INBOX")

        #expect(!http.recordedCalls().contains { $0.url.contains("/modify") })
    }

    @Test("candidate disappearing during metadata fetch is a stale no-op")
    func metadataGoneDoesNotMutate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let providerId = "gone-before-metadata"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gone-before-metadata","threadId":"thread"}]}"#)
        )
        http.register(path: "/messages/\(providerId)?", response: .status(404))
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(ids: ["gone@example.com"], folder: "INBOX")

        #expect(!http.recordedCalls().contains { $0.url.contains("/modify") })
    }

    @Test("collection lookup 404 is uncertainty and throws")
    func collectionLookupGoneThrowsWithoutMutation() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages?q=", response: .status(404))
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        do {
            try await provider.markRead(ids: ["lookup@example.com"], folder: "INBOX")
            Issue.record("collection-level lookup failure must throw")
        } catch {}

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        #expect(!calls.contains { $0.url.contains("/modify") })
    }

    @Test("candidate disappearing during mutation is a stale no-op")
    func mutationGoneReturnsNormally() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let rfc822 = "gone-during-mutation@example.com"
        let providerId = "gone-during-mutation"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gone-during-mutation","threadId":"thread"}]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(id: providerId, rfc822MessageId: rfc822))
        )
        http.register(
            path: "/messages/\(providerId)/modify",
            method: "POST",
            response: .status(410)
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.markRead(ids: [rfc822], folder: "INBOX")

        #expect(http.recordedCalls().contains { $0.url.contains("/modify") })
    }

    @Test("user-label membership resolves RFC identity before mutation")
    func userLabelResolvesRFCIdentity() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let rfc822 = "label-target@example.com"
        let providerId = "gmail-label-target"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gmail-label-target","threadId":"thread-label"}]}"#)
        )
        http.register(
            path: "/messages/\(providerId)?",
            response: .json(raw: Self.actionMetadata(id: providerId, rfc822MessageId: rfc822))
        )
        http.register(
            path: "/messages/\(providerId)/modify",
            method: "POST",
            response: .json(raw: "{}")
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.setUserLabel(
            ids: [rfc822],
            labelId: "Label_1",
            present: true,
            folder: "INBOX"
        )

        let modify = http.recordedCalls().first { $0.url.contains("/messages/\(providerId)/modify") }
        let bodyData = try #require(modify?.body)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["addLabelIds"] as? [String] == ["Label_1"])
    }

    // MARK: - search() folder scoping

    @Test("move from synthetic All Mail adds only the destination label")
    func moveFromAllMailIsAddOnly() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let rfc822 = "all-mail-move@example.com"
        let messageId = "gmail-all-mail-move"
        http.register(
            path: "/messages?q=",
            response: .json(raw: #"{"messages":[{"id":"gmail-all-mail-move","threadId":"thread-move"}]}"#)
        )
        http.register(
            path: "/messages/\(messageId)?",
            response: .json(raw: Self.actionMetadata(
                id: messageId,
                rfc822MessageId: rfc822,
                labelIds: ["CATEGORY_PERSONAL"]
            ))
        )
        http.register(
            path: "/messages/\(messageId)/modify",
            method: "POST",
            response: .json(raw: "{}")
        )
        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        try await provider.move(
            ids: [rfc822],
            from: GmailProvider.archivePath,
            to: "INBOX"
        )

        let calls = http.recordedCalls()
        #expect(calls.count == 3)
        guard calls.count == 3,
              let modifyCall = calls.first(where: { $0.url.contains("/messages/\(messageId)/modify") }),
              let bodyData = modifyCall.body
        else { return }
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(body["addLabelIds"] as? [String] == ["INBOX"])
        #expect(body["removeLabelIds"] == nil,
                "TabMail's synthetic All Mail path must never reach Gmail as a label id")
        let listURL = try #require(calls.first?.url)
        #expect(!listURL.contains("labelIds"))
        #expect(!listURL.contains(GmailProvider.archivePath))
        #expect(listURL.contains("-in:inbox") || listURL.contains("-in%3Ainbox"))
    }

    @Test("search with synthetic All Mail folder omits labelIds and uses exclusion query")
    func searchAllMailUsesExclusionQuery() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        http.register(
            path: "/messages?q=",
            method: "GET",
            response: .json(raw: #"{"messages": []}"#)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let results = try await provider.search(
            query: "hello", folder: GmailProvider.archivePath,
            after: nil, before: nil, from: nil, to: nil
        )
        #expect(results.isEmpty)

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        guard let url = calls.first?.url else { return }
        // The synthetic path must never reach the API (Gmail: 400 "Invalid label")
        #expect(!url.contains("labelIds"), "All Mail search must not send labelIds: \(url)")
        #expect(!url.contains(GmailProvider.archivePath), "Synthetic path leaked into URL: \(url)")
        // Scoped via query exclusions instead (percent-encoded "-in:inbox" etc.)
        #expect(url.contains("-in:inbox") || url.contains("-in%3Ainbox"), "Missing exclusion query: \(url)")
    }

    @Test("search fetches and parses headers for returned refs (parallel path)")
    func searchFetchesHeaders() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        http.register(
            path: "/messages?q=",
            method: "GET",
            response: .json(raw: #"{"messages": [{"id": "s-1", "threadId": "t-1"}, {"id": "s-2", "threadId": "t-2"}]}"#)
        )
        for (id, subject) in [("s-1", "First hit"), ("s-2", "Second hit")] {
        http.register(
                path: "/messages/\(id)",
                method: "GET",
                response: .json(raw: makeGmailMessageJSON(
                    id: id,
                    internalDateMs: Self.fixtureDateMs,
                    topLevelMimeType: "multipart/alternative",
                    payloadHeaders: [
                        ("Subject", subject),
                        ("From", "sender@example.com"),
                        ("Date", Self.fixtureRFC2822)
                    ],
                    parts: [.html(body: "<p>body</p>")]
                ))
            )
        }

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let results = try await provider.search(
            query: "hit", folder: "INBOX",
            after: nil, before: nil, from: nil, to: nil
        )

        #expect(results.count == 2)
        let subjects = Set(results.map(\.subject))
        #expect(subjects == ["First hit", "Second hit"])
        // 1 list call + 2 per-message gets
        #expect(http.recordedCalls().count == 3)
    }

    // MARK: - request() concurrency gate (GmailAPI.maxConcurrentRequests)

    @Test("request() gate: N≫limit concurrent fetches all drain (no deadlock / no loss)")
    func requestConcurrencyGateDrainsAll() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        // Fire well above the per-account cap so most callers must wait on the
        // gate's FIFO waiter queue, then be handed a slot as earlier ones release.
        // A release-accounting bug (a stuck waiter) hangs here; a dropped request
        // shows up as a short count.
        let count = GmailAPI.maxConcurrentRequests * 5
        for i in 0..<count {
            let id = String(format: "cmsg-%03d", i)
        http.register(
                path: "/messages/\(id)",
                method: "GET",
                response: .json(raw: makeGmailMessageJSON(
                    id: id,
                    internalDateMs: Self.fixtureDateMs,
                    topLevelMimeType: "multipart/alternative",
                    payloadHeaders: [
                        ("Subject", "S\(i)"),
                        ("From", "sender@example.com"),
                        ("Date", Self.fixtureRFC2822)
                    ],
                    parts: [.html(body: "<p>body \(i)</p>")]
                ))
            )
        }

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let okCount = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                let id = String(format: "cmsg-%03d", i)
                group.addTask {
                    let info = try? await provider.fetchMessage(id: id, folder: "INBOX")
                    return info?.htmlBody?.contains("body \(i)") ?? false
                }
            }
            var ok = 0
            for await r in group where r { ok += 1 }
            return ok
        }

        // Every concurrent fetch completed → the gate released slots correctly
        // and no caller was stranded.
        #expect(okCount == count)
        // …and each one actually hit the network (no request swallowed by the gate).
        let gets = http.recordedCalls().filter { $0.url.contains("/messages/cmsg-") }
        #expect(gets.count >= count)
    }

    @Test("search with empty folder is account-wide: no labelIds, no exclusion terms")
    func searchAccountWideOmitsScoping() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        http.register(
            path: "/messages?q=",
            method: "GET",
            response: .json(raw: #"{"messages": []}"#)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        _ = try await provider.search(
            query: "hello", folder: "",
            after: nil, before: nil, from: nil, to: nil
        )

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        guard let url = calls.first?.url else { return }
        // Account-wide (search-all fan-out passes folder: "") — whole account,
        // distinct from the All Mail case which adds -in: exclusions.
        #expect(!url.contains("labelIds"), "account-wide search must not send labelIds: \(url)")
        #expect(!url.contains("-in:") && !url.contains("-in%3A"), "account-wide search must not add exclusions: \(url)")
    }

    @Test("search with real label passes labelIds")
    func searchRealLabelPassesLabelIds() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        http.register(
            path: "/messages?q=",
            method: "GET",
            response: .json(raw: #"{"messages": []}"#)
        )

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        _ = try await provider.search(
            query: "hello", folder: "INBOX",
            after: nil, before: nil, from: nil, to: nil
        )

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        guard let url = calls.first?.url else { return }
        #expect(url.contains("labelIds=INBOX"), "Real label must be passed as labelIds: \(url)")
    }

    @Test("request boundary guard rejects leaked synthetic folder path without network call")
    func syntheticFolderPathGuard() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        // A folder string that bypasses exact-match translation but still carries
        // the sentinel — simulates a future call site forgetting the translation.
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchMessages(
                folder: "\(GmailProvider.archivePath)/sub", limit: 5, offset: 0
            )
        }
        #expect(http.recordedCalls().isEmpty, "Guard must reject before any network call")
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
    parts: [GmailPartSpec],
    labelIds: [String]? = ["INBOX"]
) -> String {
    let headersJSON = headersArrayJSON(payloadHeaders)
    let partsJSON = parts.map { partSpecToJSON($0) }.joined(separator: ",")
    let labelsJSON = labelIds.map { labels in
        let values = labels.map { "\"\($0)\"" }.joined(separator: ",")
        return "\"labelIds\": [\(values)],"
    } ?? ""

    return """
    {
      "id": "\(id)",
      "internalDate": "\(internalDateMs)",
      \(labelsJSON)
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
