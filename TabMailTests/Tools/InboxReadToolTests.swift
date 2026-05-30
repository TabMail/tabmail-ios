/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("InboxReadTool")
struct InboxReadToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db)
    }

    private func seedInbox(_ db: DatabaseQueue, count: Int, accountId: String = "acc1") throws {
        try TestDatabase.insertAccount(db, id: accountId)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        for i in 1...count {
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "msg\(i)",
                subject: "Subject \(i)",
                from: "sender\(i)@test.com",
                fromAddress: "sender\(i)@test.com",
                date: Date(timeIntervalSince1970: Double(1710000000 + i * 3600)),
                snippet: "Snippet \(i)",
                folderId: "\(accountId):INBOX",
                accountId: accountId,
                isInInbox: true
            )
        }
    }

    @Test("Empty inbox returns page 1 of 1 with no items")
    func emptyInbox() async throws {
        let (ctx, db) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("totalItems"))
        #expect(result.contains("0"))
    }

    @Test("Returns messages with correct fields")
    func returnsMessages() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 3)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("unique_id:"))
        #expect(result.contains("Subject 1"))
        #expect(result.contains("Subject 2"))
        #expect(result.contains("Subject 3"))
        #expect(result.contains("sender1@test.com"))
        #expect(result.contains("====BEGIN EMAIL LIST===="))
        #expect(result.contains("====END EMAIL LIST===="))
    }

    @Test("Page 1 of 1 for small inbox")
    func singlePage() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 5)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Page 1 of 1"))
        #expect(result.contains("\"totalItems\":5") || result.contains("\"totalItems\": 5"))
    }

    @Test("Default page_index is 1")
    func defaultPageIndex() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 3)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Page 1"))
    }

    @Test("page_index as int")
    func pageIndexInt() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 3)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["page_index": .int(1)])
        #expect(result.contains("Page 1"))
    }

    @Test("page_index as string")
    func pageIndexString() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 3)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["page_index": .string("1")])
        #expect(result.contains("Page 1"))
    }

    @Test("Negative page_index clamped to 1")
    func negativePageIndex() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 3)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["page_index": .int(-5)])
        #expect(result.contains("Page 1"))
    }

    @Test("Only inbox messages returned (not non-inbox)")
    func onlyInboxMessages() async throws {
        let (ctx, db) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "inbox1", subject: "In Inbox", isInInbox: true)
        try TestDatabase.insertMessageHeader(db, messageId: "archive1", subject: "In Archive", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("In Inbox"))
        #expect(!result.contains("In Archive"))
    }

    @Test("Messages ordered by date descending")
    func orderedByDateDesc() async throws {
        let (ctx, db) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        // Insert older first, newer second
        try TestDatabase.insertMessageHeader(db, messageId: "old", subject: "Old Email", date: Date(timeIntervalSince1970: 1000000))
        try TestDatabase.insertMessageHeader(db, messageId: "new", subject: "New Email", date: Date(timeIntervalSince1970: 2000000))
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        let oldRange = result.range(of: "Old Email")
        let newRange = result.range(of: "New Email")
        #expect(oldRange != nil)
        #expect(newRange != nil)
        // "New Email" should appear before "Old Email" (desc order)
        if let o = oldRange, let n = newRange {
            #expect(n.lowerBound < o.lowerBound)
        }
    }

    @Test("Numeric IDs assigned by translator")
    func numericIds() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 2)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        // MockChatIdTranslator assigns sequential IDs starting from 1
        #expect(result.contains("unique_id: 1") || result.contains("unique_id: 2"))
    }

    @Test("has_attachments field included")
    func hasAttachmentsField() async throws {
        let (ctx, db) = try makeContext()
        try seedInbox(db, count: 1)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("has_attachments: no"))
    }

    @Test("Action tag field included")
    func actionTagField() async throws {
        let (ctx, db) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "msg1", subject: "Tagged", actionTag: .archive)
        let tool = InboxReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("currently_tagged_for: archive"))
    }
}
