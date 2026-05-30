/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

/// Builds a FullMessageInfo with sensible defaults for body fetch tests.
private func makeFullMessageInfo(
    messageId: String = "100",
    htmlBody: String? = nil,
    textBody: String? = nil,
    attachments: [AttachmentInfo] = [],
    inlineImages: [InlineImage] = []
) -> FullMessageInfo {
    let header = MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: "<msg-\(messageId)@example.com>",
        inReplyTo: nil,
        references: [],
        threadId: nil,
        subject: "Test Subject \(messageId)",
        from: "Alice",
        fromAddress: "alice@example.com",
        to: "bob@example.com",
        cc: "",
        bcc: "",
        replyTo: nil,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        snippet: "Original snippet",
        isRead: false,
        isFlagged: false,
        hasAttachments: !attachments.isEmpty,
        isReplied: false,
        isForwarded: false,
        actionTag: nil
    )
    return FullMessageInfo(
        header: header,
        htmlBody: htmlBody,
        textBody: textBody,
        attachments: attachments,
        inlineImages: inlineImages
    )
}

/// Simulates the core fetchBody flow: provider.fetchMessage -> store body in DB -> update snippet -> no-content detection.
/// Mirrors the real AccountManager.fetchBody logic for DB-level testing.
private func simulateFetchBody(
    db: DatabaseQueue,
    provider: MockEmailProvider,
    header: MessageHeader
) async throws {
    // Check if body already exists (idempotent)
    let hasBody = try await db.read { db in try MessageBody.fetchOne(db, key: header.id) != nil }
    guard !hasBody else { return }

    let fullMessage = try await provider.fetchMessage(id: header.messageId, folder: header.folderPath)

    // Determine HTML content using MessageBody.create logic
    let body = MessageBody.create(headerId: header.id, htmlBody: fullMessage.htmlBody, textBody: fullMessage.textBody)
    try await db.write { dbConn in try body.save(dbConn) }

    // Update snippet from body content
    let stripped: String?
    if let text = fullMessage.textBody, !text.isEmpty {
        stripped = text
    } else if let html = fullMessage.htmlBody, !html.isEmpty {
        stripped = EmailFilter.htmlToPlainText(html)
    } else {
        stripped = nil
    }
    if let stripped {
        let snippet = EmailFilter.snippetFromPlainText(stripped)
        let headerId = header.id
        try await db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?", arguments: [snippet, headerId])
        }
    }

    // No-content detection
    let hasTextContent = fullMessage.htmlBody?.isEmpty == false || fullMessage.textBody?.isEmpty == false
    let hasAttachments = !fullMessage.attachments.isEmpty
    if !hasTextContent && !hasAttachments {
        let headerId = header.id
        try await db.write { dbConn in
            guard var msg = try MessageHeader.fetchOne(dbConn, key: headerId) else { return }
            msg.summaryBlurb = "This message has no content."
            msg.actionTag = .delete
            msg.tagSortOrder = ActionTag.delete.sortOrder
            try msg.save(dbConn)
        }
    }
}

// MARK: - Suite 1: Provider fetchMessage -> DB Storage

@Suite("Body Fetch Integration - Provider to DB Storage")
struct BodyFetchProviderToDBTests {

    @Test("HTML body stored in MessageBody with correct headerId")
    func htmlBodyStoredCorrectly() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(messageId: "100", htmlBody: "<p>Hello world</p>")
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body != nil)
        #expect(body?.id == header.id)
        #expect(body?.htmlContent == "<p>Hello world</p>")
    }

    @Test("Text-only message converted via plainTextToHTML")
    func textOnlyConvertedToHTML() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "200")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(messageId: "200", htmlBody: nil, textBody: "Plain text email content")
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body != nil)
        #expect(body?.htmlContent != nil)
        // plainTextToHTML wraps in HTML structure
        #expect(body?.htmlContent?.contains("Plain text email content") == true)
        // Should NOT be raw plain text — should have HTML tags
        #expect(body?.htmlContent?.contains("<") == true)
    }

    @Test("Both HTML and text — HTML takes priority")
    func htmlTakesPriorityOverText() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "300")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(
            messageId: "300",
            htmlBody: "<div>Rich HTML</div>",
            textBody: "Fallback plain text"
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body?.htmlContent == "<div>Rich HTML</div>")
    }

    @Test("Empty HTML body — textBody used as fallback")
    func emptyHtmlFallsBackToText() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "400")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(
            messageId: "400",
            htmlBody: "",
            textBody: "Fallback text content"
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body?.htmlContent != nil)
        #expect(body?.htmlContent?.contains("Fallback text content") == true)
    }

    @Test("Provider throws messageNotFound — no MessageBody created")
    func providerThrowsMessageNotFound() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "500")

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(ProviderError.messageNotFound)

        do {
            try await simulateFetchBody(db: db, provider: provider, header: header)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is ProviderError)
        }

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body == nil)
    }

    @Test("Provider throws network error — no MessageBody created")
    func providerThrowsNetworkError() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "600")

        let provider = MockEmailProvider()
        let networkErr = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "No internet"])
        await provider.setFetchMessageThrows(ProviderError.networkError(underlying: networkErr))

        do {
            try await simulateFetchBody(db: db, provider: provider, header: header)
            Issue.record("Expected error to be thrown")
        } catch {
            // Error propagated — good
        }

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body == nil)
    }

    @Test("Body already exists — skip fetch (idempotent)")
    func bodyAlreadyExistsSkipsFetch() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "700")

        // Pre-insert a body
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Existing body</p>")

        let provider = MockEmailProvider()
        // Don't set fetchMessageResult — if fetch is called, it will throw (no result configured)

        // Should not throw — body exists, fetch skipped
        try await simulateFetchBody(db: db, provider: provider, header: header)

        // Verify original body unchanged
        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body?.htmlContent == "<p>Existing body</p>")

        // Verify provider was NOT called
        let calls = await provider.callLog
        #expect(!calls.contains { $0.contains("fetchMessage") })
    }
}

// MARK: - Suite 2: MessageBody Persistence Patterns

@Suite("Body Fetch Integration - MessageBody Persistence")
struct BodyFetchMessageBodyPersistenceTests {

    @Test("MessageBody id matches headerId (FK relationship)")
    func bodyIdMatchesHeaderId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let body = MessageBody(headerId: header.id, htmlContent: "<p>Test</p>")
        try db.write { try body.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched?.id == header.id)
    }

    @Test("MessageBody CASCADE deletes when header deleted")
    func cascadeDeleteOnHeaderRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        // Verify body exists
        let bodyBefore = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(bodyBefore != nil)

        // Delete the header
        try db.write { dbConn in
            _ = try MessageHeader.deleteOne(dbConn, key: header.id)
        }

        // Body should be cascade-deleted
        let bodyAfter = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(bodyAfter == nil)
    }

    @Test("save() acts as upsert — second write updates existing body")
    func saveActsAsUpsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // First write
        let body1 = MessageBody(headerId: header.id, htmlContent: "<p>Version 1</p>")
        try db.write { try body1.save($0) }

        // Second write (upsert)
        let body2 = MessageBody(headerId: header.id, htmlContent: "<p>Version 2</p>")
        try db.write { try body2.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched?.htmlContent == "<p>Version 2</p>")

        // Only one row should exist
        let count = try db.read { try MessageBody.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("Multiple bodies for different messages coexist")
    func multipleBodiesCoexist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "101")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "102")
        let h3 = try TestDatabase.insertMessageHeader(db, messageId: "103")

        try TestDatabase.insertMessageBody(db, headerId: h1.id, htmlContent: "<p>Body 1</p>")
        try TestDatabase.insertMessageBody(db, headerId: h2.id, htmlContent: "<p>Body 2</p>")
        try TestDatabase.insertMessageBody(db, headerId: h3.id, htmlContent: "<p>Body 3</p>")

        let count = try db.read { try MessageBody.fetchCount($0) }
        #expect(count == 3)

        let b1 = try db.read { try MessageBody.fetchOne($0, key: h1.id) }
        let b2 = try db.read { try MessageBody.fetchOne($0, key: h2.id) }
        let b3 = try db.read { try MessageBody.fetchOne($0, key: h3.id) }
        #expect(b1?.htmlContent == "<p>Body 1</p>")
        #expect(b2?.htmlContent == "<p>Body 2</p>")
        #expect(b3?.htmlContent == "<p>Body 3</p>")
    }

    @Test("Body with nil htmlContent persists correctly")
    func nilHtmlContentPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let body = MessageBody(headerId: header.id, htmlContent: nil)
        try db.write { try body.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.htmlContent == nil)
    }

    @Test("Body read-back matches exactly what was written")
    func readBackMatchesWrite() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let htmlContent = "<html><body><h1>Title</h1><p>Paragraph with <em>emphasis</em> and <a href=\"https://example.com\">link</a>.</p></body></html>"
        let body = MessageBody(headerId: header.id, htmlContent: htmlContent)
        try db.write { try body.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched?.htmlContent == htmlContent)
        #expect(fetched?.id == header.id)
    }
}

// MARK: - Suite 3: Snippet and Content Processing

@Suite("Body Fetch Integration - Snippet and Content Processing")
struct SnippetProcessingTests {

    @Test("HTML body produces snippet via htmlToPlainText then snippetFromPlainText")
    func htmlBodyProducesSnippet() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", snippet: "Old snippet")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(
            messageId: "100",
            htmlBody: "<p>This is the HTML body content for snippet extraction.</p>"
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.snippet != "Old snippet")
        #expect(updated?.snippet.contains("HTML body content") == true)
    }

    @Test("Text body used directly for snippet")
    func textBodyUsedForSnippet() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "200", snippet: "Old snippet")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(
            messageId: "200",
            htmlBody: nil,
            textBody: "Direct plain text for snippet generation"
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.snippet != "Old snippet")
        #expect(updated?.snippet.contains("Direct plain text") == true)
    }

    @Test("Very long body produces truncated snippet")
    func longBodyTruncatesSnippet() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "300")

        let provider = MockEmailProvider()
        let longText = String(repeating: "This is a long sentence for testing. ", count: 100)
        let fullMsg = makeFullMessageInfo(messageId: "300", htmlBody: nil, textBody: longText)
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        // snippetFromPlainText defaults to maxChars: 150
        #expect(updated?.snippet != nil)
        #expect((updated?.snippet.count ?? 0) <= 200) // Allow some margin for word boundaries
        #expect((updated?.snippet.count ?? 0) < longText.count)
    }

    @Test("Empty body — snippet remains unchanged")
    func emptyBodySnippetUnchanged() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let originalSnippet = "Original snippet text"
        let header = try TestDatabase.insertMessageHeader(db, messageId: "400", snippet: originalSnippet)

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(messageId: "400", htmlBody: nil, textBody: nil)
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.snippet == originalSnippet)
    }

    @Test("Special characters in HTML preserved after round-trip")
    func specialCharsPreservedInHtml() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "500")

        let provider = MockEmailProvider()
        let htmlWithSpecials = "<p>Price: $100 &amp; tax &lt;5%&gt; — \"quoted\" 'text' \u{00E9}\u{00FC}\u{00F1}</p>"
        let fullMsg = makeFullMessageInfo(messageId: "500", htmlBody: htmlWithSpecials)
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let body = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body?.htmlContent == htmlWithSpecials)
    }
}

// MARK: - Suite 4: No-Content Detection

@Suite("Body Fetch Integration - No-Content Detection")
struct NoContentDetectionTests {

    @Test("No htmlBody, no textBody, no attachments — marked as delete actionTag")
    func noContentMarkedAsDelete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(messageId: "100", htmlBody: nil, textBody: nil, attachments: [])
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.actionTag == ActionTag.delete)
        #expect(updated?.summaryBlurb == "This message has no content.")
        #expect(updated?.tagSortOrder == ActionTag.delete.sortOrder)
    }

    @Test("htmlBody with empty string — still has content (empty string is falsy)")
    func emptyHtmlStringIsNoContent() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "200")

        let provider = MockEmailProvider()
        // Empty string htmlBody — `htmlBody?.isEmpty == false` is false for ""
        let fullMsg = makeFullMessageInfo(messageId: "200", htmlBody: "", textBody: nil, attachments: [])
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        // Empty string means no text content — marked as delete
        #expect(updated?.actionTag == ActionTag.delete)
    }

    @Test("No body but has attachments — NOT marked as no-content")
    func noBodyWithAttachmentsNotMarked() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "300")

        let provider = MockEmailProvider()
        let attachment = AttachmentInfo(
            filename: "document.pdf",
            contentType: "application/pdf",
            section: "2",
            size: 1024,
            encoding: "base64"
        )
        let fullMsg = makeFullMessageInfo(
            messageId: "300",
            htmlBody: nil,
            textBody: nil,
            attachments: [attachment]
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        // Has attachments — should NOT be marked as no-content
        #expect(updated?.actionTag != ActionTag.delete)
        #expect(updated?.summaryBlurb != "This message has no content.")
    }

    @Test("Only textBody — NOT marked as no-content")
    func onlyTextBodyNotMarked() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "400")

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(
            messageId: "400",
            htmlBody: nil,
            textBody: "Some text content"
        )
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        let updated = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.actionTag != ActionTag.delete)
        #expect(updated?.summaryBlurb != "This message has no content.")
    }
}

// MARK: - Suite 5: Body Fetch Queue Patterns (DB-level)

@Suite("Body Fetch Integration - Queue Patterns")
struct ActiveBodyQueueTests {

    @Test("Messages without body detected via MessageBody existence check")
    func hasBodyCheckViaExistence() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "101")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "102")
        try TestDatabase.insertMessageBody(db, headerId: h1.id, htmlContent: "<p>Has body</p>")
        // h2 has no body

        let withoutBody = try await db.read { dbConn -> [String] in
            let headerIds = try MessageHeader.fetchAll(dbConn).map(\.id)
            return try headerIds.filter { headerId in
                try MessageBody.fetchOne(dbConn, key: headerId) == nil
            }
        }

        #expect(withoutBody.count == 1)
        #expect(withoutBody.contains(h2.id))
    }

    @Test("Batch of headers — only those without body need fetching")
    func batchHeadersFilteredByBody() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 5 headers, give bodies to 3
        var headers: [MessageHeader] = []
        for i in 1...5 {
            let h = try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
            headers.append(h)
        }
        try TestDatabase.insertMessageBody(db, headerId: headers[0].id)
        try TestDatabase.insertMessageBody(db, headerId: headers[2].id)
        try TestDatabase.insertMessageBody(db, headerId: headers[4].id)

        let headerIds = headers.map(\.id)
        let needsFetch = try await db.read { dbConn -> [String] in
            try headerIds.filter { headerId in
                try MessageBody.fetchOne(dbConn, key: headerId) == nil
            }
        }

        #expect(needsFetch.count == 2)
        #expect(needsFetch.contains(headers[1].id))
        #expect(needsFetch.contains(headers[3].id))
    }

    @Test("After body fetch, message has body in DB")
    func afterFetchBodyExistsInDB() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // Confirm no body initially
        let before = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(before == nil)

        let provider = MockEmailProvider()
        let fullMsg = makeFullMessageInfo(messageId: "100", htmlBody: "<p>Fetched body</p>")
        await provider.setFetchMessageResult(fullMsg)

        try await simulateFetchBody(db: db, provider: provider, header: header)

        // Confirm body exists after fetch
        let after = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(after != nil)
        #expect(after?.htmlContent == "<p>Fetched body</p>")
    }
}
