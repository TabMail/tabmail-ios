/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailReadTool")
struct EmailReadToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db, translator)
    }

    @Test("Missing unique_id returns error")
    func missingUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("error"))
        #expect(result.contains("invalid or missing unique_id"))
    }

    @Test("Unknown numeric ID returns not found")
    func unknownNumericId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(999)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }

    @Test("Valid message returns full content")
    func validMessage() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", subject: "Test Subject",
            from: "Alice", fromAddress: "alice@test.com",
            to: "bob@test.com"
        )
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Hello world</p>")
        await translator.seed(header.id, as: 42)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(42)])
        #expect(result.contains("unique_id: 42"))
        #expect(result.contains("subject: Test Subject"))
        #expect(result.contains("Alice <alice@test.com>"))
        #expect(result.contains("to: bob@test.com"))
        #expect(result.contains("Hello world")) // HTML stripped to text
    }

    @Test("Falls back to snippet when no body")
    func fallbackToSnippet() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg2", subject: "No Body",
            snippet: "This is the snippet"
        )
        await translator.seed(header.id, as: 10)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(10)])
        #expect(result.contains("This is the snippet"))
    }

    @Test("unique_id as string")
    func uniqueIdAsString() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg3", subject: "String ID")
        await translator.seed(header.id, as: 5)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("5")])
        #expect(result.contains("subject: String ID"))
    }

    @Test("unique_id as double")
    func uniqueIdAsDouble() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg4", subject: "Double ID")
        await translator.seed(header.id, as: 7)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .double(7.0)])
        #expect(result.contains("subject: Double ID"))
    }

    @Test("Message with no subject shows (No subject)")
    func noSubject() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg5", subject: "")
        await translator.seed(header.id, as: 1)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(1)])
        #expect(result.contains("subject: (No subject)"))
    }

    @Test("Output includes date, from, to, cc fields")
    func outputFields() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg6", subject: "Fields",
            from: "Sender", fromAddress: "s@t.com",
            to: "r@t.com"
        )
        await translator.seed(header.id, as: 3)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(3)])
        #expect(result.contains("date:"))
        #expect(result.contains("from:"))
        #expect(result.contains("to:"))
        #expect(result.contains("cc:"))
        #expect(result.contains("body:"))
        #expect(result.contains("has_attachments:"))
        #expect(result.contains("replied:"))
    }

    @Test("Deleted message returns not found")
    func deletedMessage() async throws {
        let (ctx, _, translator) = try makeContext()
        // Seed translator with ID but don't insert into DB
        await translator.seed("deleted_msg", as: 99)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(99)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }
}

@Suite("HTML link ingestion", .serialized, .processGlobalState)
struct HTMLLinkIngestionTests {
    @Test("Fetched HTML links reach stored text, search, and cached or indexed agent reads")
    func linkAddressesReachAgentAndSearch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "link-ingestion-\(UUID().uuidString)"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let header = MessageHeader(messageId: "links", subject: "Details",
            from: "Sender", fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "No body yet", folderId: "\(accountId):INBOX",
            accountId: accountId, folderPath: "INBOX", isInInbox: false)
        try await pool.write { try header.insert($0) }
        let key = ContentKey(rawValue: header.id)
        let index = SearchIndex.shared
        _ = try await index.indexHeaders([FTSHeaderRecord(contentKey: key, headerId: header.id,
            messageId: header.messageId, subject: header.subject, from: header.fromAddress,
            to: header.to, dateMs: Int64(header.date.timeIntervalSince1970 * 1000))])
        let term = "uniquelinkdestination"
        #expect(!(try await index.keywordSearch(query: term)).contains { $0.contentKey == key })
        #expect(try await index.rawFTSBody(contentKey: key)?.contains(term) != true)

        let html = #"<p>See <a href="https://example.com/uniquelinkdestination">the details</a>.</p>"#
        let markdown = "[the details](https://example.com/uniquelinkdestination)"
        let info = MessageHeaderInfo(messageId: header.messageId, rfc822MessageId: nil,
            inReplyTo: nil, references: [], threadId: nil, subject: header.subject,
            from: header.from, fromAddress: header.fromAddress, to: header.to, cc: "", bcc: "",
            replyTo: nil, date: header.date, snippet: header.snippet, isRead: false,
            isFlagged: false, hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil)
        let provider = MockEmailProvider()
        await provider.setFetchMessageResult(FullMessageInfo(header: info, htmlBody: html, textBody: "See the details."))
        let outcome = await BodyFetchProcessor.fetchAndProcess(item: .init(headerId: header.id,
            accountId: accountId, folderPath: "INBOX", messageId: header.messageId, isInInbox: false),
            provider: provider, enableAI: true)
        await ActiveEmbeddingQueue.shared.clearForTesting()
        if case .success = outcome {} else { Issue.record("Body ingestion did not succeed") }
        #expect(try await index.rawFTSBody(contentKey: key)?.contains(markdown) == true)
        #expect((try await index.keywordSearch(query: term)).contains { $0.contentKey == key })
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: header.id)?.bodyComplete } == true)

        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 42)
        let tool = EmailReadTool(context: ToolContext(db: pool, translator: translator))
        #expect(try await tool.execute(arguments: ["unique_id": .int(42)]).contains(markdown))
        // Evict display HTML and clear the snippet so only indexed body text can satisfy the read.
        try await pool.write { db in
            _ = try MessageBody.deleteOne(db, key: key.rawValue)
            try db.execute(sql: "UPDATE messageHeader SET snippet = '' WHERE id = ?", arguments: [header.id])
        }
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: key.rawValue) } == nil)
        #expect(try await tool.execute(arguments: ["unique_id": .int(42)]).contains(markdown))
        try await index.removeMessages(contentKeys: [key])
        #expect(!(try await index.keywordSearch(query: term)).contains { $0.contentKey == key })
    }
}
