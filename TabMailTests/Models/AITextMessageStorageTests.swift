/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Each text message belongs to its AI result (ADR-IOS-103): it is stored, replaced and restored
/// together with that result, never kept from an older one.
@Suite("AI text messages: schema, cache write-through and restore")
struct AITextMessageStorageTests {

    private func columns(_ db: DatabaseQueue, _ table: String) throws -> Set<String> {
        try db.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    @Test("v95 adds both text-message columns to messageHeader and messageAICache")
    func migrationAddsColumns() throws {
        let db = try TestDatabase.make()
        for table in ["messageHeader", "messageAICache"] {
            let cols = try columns(db, table)
            #expect(cols.contains("summaryTextMessage"), "\(table)")
            #expect(cols.contains("replyTextMessage"), "\(table)")
        }
        let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v95_addAITextMessages"))
    }

    @Test("The header round-trips both text messages")
    func headerRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "rt@example.com")
        header.summaryTextMessage = "Summary text"
        header.replyTextMessage = "Reply text"
        try db.write { [header] in try header.update($0) }
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.summaryTextMessage == "Summary text")
        #expect(fetched?.replyTextMessage == "Reply text")
    }

    private func entry(_ db: DatabaseQueue, _ rfc: String) throws -> MessageAICache? {
        try db.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:\(rfc)") }
    }

    @Test("writeThrough stores the text message with its summary and replaces it with the next summary")
    func summaryTextMessageFollowsSummary() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            summaryBlurb: "First", summaryTextMessage: "First text", db: $0)
        }
        #expect(try entry(db, "s@example.com")?.summaryTextMessage == "First text")

        // A write that does not touch the summary keeps the text message.
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            actionTag: .reply, db: $0)
        }
        #expect(try entry(db, "s@example.com")?.summaryTextMessage == "First text")

        // A new summary without a text message (a peer's) does not keep the old one.
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            summaryBlurb: "Peer", db: $0)
        }
        let after = try entry(db, "s@example.com")
        #expect(after?.summaryBlurb == "Peer")
        #expect(after?.summaryTextMessage == nil)
        #expect(after?.actionTag == .reply)
    }

    @Test("writeThrough stores the text message with its reply and replaces it with the next reply")
    func replyTextMessageFollowsReply() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            cachedReply: "Body one", replyTextMessage: "Text one", db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            summaryBlurb: "Summary", db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            cachedReply: "Body two", db: $0)
        }
        let after = try entry(db, "r@example.com")
        #expect(after?.cachedReply == "Body two")
        #expect(after?.replyTextMessage == nil)
    }

    @Test("restoreIfCached restores each text message with its result")
    func restoreCarriesTextMessages() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "x@example.com",
                                            summaryBlurb: "Summary", summaryTextMessage: "Summary text",
                                            cachedReply: "Reply", replyTextMessage: "Reply text", db: $0)
        }
        var header = MessageHeader(
            messageId: "7", subject: "S", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = "x@example.com"
        try db.write { try MessageAICache.restoreIfCached(into: &header, accountId: "acc1", folderPath: "INBOX", db: $0) }
        #expect(header.summaryBlurb == "Summary")
        #expect(header.summaryTextMessage == "Summary text")
        #expect(header.cachedReply == "Reply")
        #expect(header.replyTextMessage == "Reply text")
    }

    @Test("restoreIfCached does not graft a cached text message onto the header's own result")
    func restoreKeepsHeaderResult() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "y@example.com",
                                            summaryBlurb: "Cached", summaryTextMessage: "Cached text",
                                            cachedReply: "Cached reply", replyTextMessage: "Cached reply text", db: $0)
        }
        var header = MessageHeader(
            messageId: "8", subject: "S", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = "y@example.com"
        header.summaryBlurb = "Own"
        header.cachedReply = "Own reply"
        try db.write { try MessageAICache.restoreIfCached(into: &header, accountId: "acc1", folderPath: "INBOX", db: $0) }
        #expect(header.summaryBlurb == "Own")
        #expect(header.summaryTextMessage == nil)
        #expect(header.cachedReply == "Own reply")
        #expect(header.replyTextMessage == nil)
    }
}
