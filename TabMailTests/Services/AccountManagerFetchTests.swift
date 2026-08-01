/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for fetchBody-related DB patterns and helper logic.
/// AccountManager.fetchBody itself is coupled to the singleton (providers dict,
/// SearchIndex, BodyFetchProcessor, AI processing), so we test the DB write patterns
/// and body creation logic that underlie it.
@Suite("AccountManagerFetch - DB Patterns")
struct AccountManagerFetchTests {

    // MARK: - MessageBody creation from FullMessageInfo

    // `create` stores already-rendered display html (BodyRenderer owns conversion).
    // The plain-text→HTML fallback now lives in BodyRendererTests.

    @Test("MessageBody.create stores the provided html")
    func messageBodyCreateStoresHtml() {
        let body = MessageBody.create( contentKey: ContentKey(rawValue: "h1"), htmlBody: "<p>Hello</p>")
        #expect(body.htmlContent == "<p>Hello</p>")
    }

    @Test("MessageBody.create produces nil htmlContent when html is nil")
    func messageBodyCreateNilWhenNil() {
        let body = MessageBody.create( contentKey: ContentKey(rawValue: "h1"), htmlBody: nil)
        #expect(body.htmlContent == nil)
    }

    @Test("MessageBody.create produces nil htmlContent when html is empty")
    func messageBodyCreateNilWhenEmpty() {
        let body = MessageBody.create( contentKey: ContentKey(rawValue: "h1"), htmlBody: "")
        #expect(body.htmlContent == nil)
    }

    // MARK: - fetchBody DB pattern: body write + save (upsert)

    @Test("fetchBody pattern: MessageBody inserted for header")
    func fetchBodyPatternInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // Simulate fetchBody writing the body
        let body = MessageBody( contentKey: ContentKey(rawValue: header.id), htmlContent: "<p>Email body</p>")
        try db.write { try body.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.htmlContent == "<p>Email body</p>")
    }

    @Test("fetchBody pattern: save() upserts (user-open wins over background)")
    func fetchBodyPatternUpsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // Background render inserts first
        let bgBody = MessageBody( contentKey: ContentKey(rawValue: header.id), htmlContent: "<p>Background render</p>")
        try db.write { try bgBody.insert($0, onConflict: .ignore) }

        // User-open path uses save() which overwrites
        let userBody = MessageBody( contentKey: ContentKey(rawValue: header.id), htmlContent: "<p>User-open render with CID images</p>")
        try db.write { try userBody.save($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(fetched?.htmlContent == "<p>User-open render with CID images</p>")
    }

    @Test("fetchBody pattern: hasBody check prevents re-fetch")
    func fetchBodyPatternHasBodyCheck() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // No body yet
        let hasBody1 = try db.read { try MessageBody.fetchOne($0, key: header.id) != nil }
        #expect(hasBody1 == false)

        // Insert body
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        // Now has body
        let hasBody2 = try db.read { try MessageBody.fetchOne($0, key: header.id) != nil }
        #expect(hasBody2 == true)
    }

    // MARK: - No-content message pattern

    @Test("no-content pattern: header updated with delete tag and summary")
    func noContentPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // Simulate no-content detection
        try db.write { dbConn in
            guard var msg = try MessageHeader.fetchOne(dbConn, key: header.id) else { return }
            msg.summaryBlurb = "This message has no content."
            msg.actionTag = .delete
            msg.tagSortOrder = ActionTag.delete.sortOrder
            try msg.save(dbConn)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.summaryBlurb == "This message has no content.")
        #expect(updated?.actionTag == .delete)
        #expect(updated?.tagSortOrder == ActionTag.delete.sortOrder)
    }

    // MARK: - hasAttachments correction pattern

    @Test("hasAttachments corrected when body fetch discovers attachments")
    func hasAttachmentsCorrection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        // Header initially has no attachments
        let initial = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(initial?.hasAttachments == false)

        // Simulate body fetch discovering attachments
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET hasAttachments = 1 WHERE id = ?", arguments: [header.id])
        }

        let corrected = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(corrected?.hasAttachments == true)
    }

    // MARK: - Snippet update pattern

    @Test("snippet updated after body fetch")
    func snippetUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", snippet: "")

        let newSnippet = "This is the first line of the email body content..."
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?", arguments: [newSnippet, header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.snippet == newSnippet)
    }

    // MARK: - Stale header eviction pattern

    /// `evictStaleHeader`'s eviction is now TWO steps, not one: the header delete,
    /// then `MessageContentStore.releaseUnowned(…, stores: [.searchIndex, .body])`
    /// AFTER that transaction commits. Stage D dropped the FK that used to fuse
    /// them. This pins the half this in-memory queue can see — the delete alone
    /// does not touch the body; the routed second half is pinned against the
    /// production path in `ContentOwnershipSweepTests`.
    @Test("evict pattern: deleting MessageHeader no longer deletes MessageBody by itself")
    func evictPatternLeavesBodyToTheRoutedRelease() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        // Evict header
        try db.write { _ = try MessageHeader.deleteOne($0, key: header.id) }

        let headerGone = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        let body = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(headerGone == nil)
        #expect(body != nil, "the body must outlive the header delete — only the routed release may remove it")
    }

    // MARK: - MockEmailProvider fetchMessage

    @Test("MockEmailProvider returns configured FullMessageInfo")
    func mockProviderFetchMessage() async throws {
        let mock = MockEmailProvider()
        let headerInfo = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: "<test@example.com>",
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Test",
            from: "sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        let fullMsg = FullMessageInfo(
            header: headerInfo,
            htmlBody: "<p>Hello from server</p>",
            textBody: "Hello from server"
        )
        await mock.setFetchMessageResult(fullMsg)

        let result = try await mock.fetchMessage(id: "100", folder: "INBOX")
        #expect(result.htmlBody == "<p>Hello from server</p>")
        #expect(result.textBody == "Hello from server")
    }

    @Test("MockEmailProvider throws messageNotFound when no result configured")
    func mockProviderFetchMessageThrowsWhenNil() async throws {
        let mock = MockEmailProvider()
        // fetchMessageResult is nil by default

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchMessage(id: "100", folder: "INBOX")
        }
    }

    @Test("MockEmailProvider records fetchMessage call log")
    func mockProviderFetchMessageCallLog() async throws {
        let mock = MockEmailProvider()
        let headerInfo = MessageHeaderInfo(
            messageId: "42",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Test",
            from: "sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        await mock.setFetchMessageResult(FullMessageInfo(header: headerInfo, htmlBody: nil, textBody: "text"))

        _ = try await mock.fetchMessage(id: "42", folder: "Sent")

        let log = await mock.callLog
        #expect(log.contains("fetchMessage(id:42,folder:Sent)"))
    }

    // MARK: - Integration: mock fetch → DB write

    @Test("integration: fetch from mock provider → write body to DB")
    func integrationFetchAndWriteBody() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        let mock = MockEmailProvider()
        let headerInfo = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Test",
            from: "sender",
            fromAddress: "sender@example.com",
            to: "to@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        let fullMsg = FullMessageInfo(header: headerInfo, htmlBody: "<b>Content</b>", textBody: "Content")
        await mock.setFetchMessageResult(fullMsg)

        // Simulate fetchBody: fetch from provider then write
        let fetched = try await mock.fetchMessage(id: header.messageId, folder: header.folderPath)
        let body = MessageBody.create( contentKey: ContentKey(rawValue: header.id), htmlBody: fetched.htmlBody)
        try await db.write { try body.save($0) }

        let stored = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(stored != nil)
        #expect(stored?.htmlContent == "<b>Content</b>")
    }

    @Test("integration: fetch returns nil body → body created with nil content")
    func integrationFetchNilBody() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "200")

        let mock = MockEmailProvider()
        let headerInfo = MessageHeaderInfo(
            messageId: "200",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Empty",
            from: "sender",
            fromAddress: "sender@example.com",
            to: "to@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        let fullMsg = FullMessageInfo(header: headerInfo, htmlBody: nil, textBody: nil)
        await mock.setFetchMessageResult(fullMsg)

        let fetched = try await mock.fetchMessage(id: "200", folder: "INBOX")
        let body = MessageBody.create( contentKey: ContentKey(rawValue: header.id), htmlBody: fetched.htmlBody)
        try await db.write { try body.save($0) }

        let stored = try await db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(stored != nil)
        #expect(stored?.htmlContent == nil)
    }

    // MARK: - plainTextToHTML conversion

    @Test("plainTextToHTML wraps plain text in HTML div")
    func plainTextToHtmlBasic() {
        let html = MessageBody.plainTextToHTML("Hello world")
        #expect(html.contains("Hello world"))
        #expect(html.contains("<div"))
    }

    @Test("plainTextToHTML handles quote lines with blockquote")
    func plainTextToHtmlQuotes() {
        let html = MessageBody.plainTextToHTML("> This is quoted text")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("This is quoted text"))
    }

    @Test("plainTextToHTML escapes HTML entities")
    func plainTextToHtmlEscaping() {
        let html = MessageBody.plainTextToHTML("a < b & c > d")
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&gt;"))
    }
}

// MARK: - MockEmailProvider helper for setting fetchMessageResult

extension MockEmailProvider {
    func setFetchMessageResult(_ result: FullMessageInfo?) {
        fetchMessageResult = result
    }
}
