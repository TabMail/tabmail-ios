/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database E2E Scenarios")
struct DatabaseE2ETests {

    @Test("Full email lifecycle: receive → read → archive → delete account")
    func fullEmailLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // Receive message
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Hello</p>")

        // Mark as read
        header.isRead = true
        try db.write { try header.update($0) }

        // Move to archive (update folderId)
        header.folderId = "acc1:Archive"
        header.isInInbox = false
        try db.write { try header.update($0) }

        let inboxCount = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount($0)
        }
        #expect(inboxCount == 0)

        let archiveCount = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchCount($0)
        }
        #expect(archiveCount == 1)

        // Delete account — cascades everything
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let totalHeaders = try db.read { try MessageHeader.fetchCount($0) }
        let totalBodies = try db.read { try MessageBody.fetchCount($0) }
        let totalFolders = try db.read { try Folder.fetchCount($0) }
        #expect(totalHeaders == 0)
        #expect(totalBodies == 0)
        #expect(totalFolders == 0)
    }

    @Test("Outbox send lifecycle: queue → send → stamp sentAt → delete")
    func outboxSendLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Queue message
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }
        #expect(msg.outboxStatus == .queued)

        // Start sending
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        // Stamp sentAt FIRST (double-send firewall)
        msg.sentAt = Date()
        try db.write { try msg.update($0) }

        let stamped = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(stamped?.sentAt != nil)

        // Delete after confirmed sent
        _ = try db.write { try msg.delete($0) }
        let remaining = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("Pending operation lifecycle: create → execute → delete")
    func pendingOpLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Create pending op
        var op = PendingOperation(
            type: .archive,
            messageIds: ["msg1", "msg2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Mark in flight
        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.update($0) }

        let inFlight = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(inFlight?.status == PendingStatus.inFlight.rawValue)

        // Complete — delete
        _ = try db.write { try op.delete($0) }
        let remaining = try db.read { try PendingOperation.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("AI processing lifecycle: insert header → add AI cache → delete header → cache survives")
    func aiCacheLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@ex.com>")

        // AI processes message
        let cacheKey = "acc1:INBOX:<msg@ex.com>"
        try db.write { db in
            var cache = MessageAICache(key: cacheKey, rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "Summary"
            cache.actionTag = .archive
            cache.cachedReply = "Suggested reply"
            try cache.insert(db)
        }

        // Message leaves inbox (header deleted during re-sync)
        try db.write { _ = try MessageHeader.deleteOne($0, key: "acc1:INBOX:1") }

        // AI cache survives — ready for re-insertion
        let cache = try db.read { try MessageAICache.fetchOne($0, key: cacheKey) }
        #expect(cache?.summaryBlurb == "Summary")
        #expect(cache?.cachedReply == "Suggested reply")
    }

    @Test("Multi-account inbox aggregation")
    func multiAccountAggregation() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "gmail", email: "user@gmail.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "imap", email: "user@imap.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "gmail")
        try TestDatabase.insertFolder(db, accountId: "imap")

        // 3 messages in gmail inbox, 2 in imap inbox
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "gmail:INBOX", accountId: "gmail")
        }
        for i in 0..<2 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "imap:INBOX", accountId: "imap")
        }

        // Aggregated inbox query
        let allInbox = try db.read {
            try MessageHeader.filter(Column("isInInbox") == true).order(Column("date").desc).fetchAll($0)
        }
        #expect(allInbox.count == 5)
    }

    @Test("Chat turn budget enforcement via DB")
    func chatTurnBudget() throws {
        let db = try TestDatabase.make()

        // Insert 120 turns (exceeds 100-turn budget)
        for i in 0..<120 {
            let turn = ChatTurn(
                id: "t\(i)",
                timestamp: Double(i * 1000),
                role: i % 2 == 0 ? "user" : "assistant",
                content: "msg \(i)",
                userMessage: nil,
                type: "normal",
                chars: 10,
                renderedContent: nil,
                sessionId: "s1",
                remindersSnapshot: nil,
                emailContextJSON: nil,
                thinkingContent: nil
            )
            try db.write { try turn.insert($0) }
        }

        // Enforce budget: delete oldest to keep maxExchanges * 2 = 100
        try db.write { db in
            let totalTurns = try ChatTurn.fetchCount(db)
            let maxMessages = 100
            if totalTurns > maxMessages {
                let excess = totalTurns - maxMessages
                let oldest = try ChatTurn
                    .order(Column("timestamp").asc)
                    .limit(excess)
                    .fetchAll(db)
                for old in oldest {
                    try old.delete(db)
                }
            }
        }

        let remaining = try db.read { try ChatTurn.fetchCount($0) }
        #expect(remaining == 100)
    }

    @Test("Folder unread recount after message operations")
    func folderUnreadRecount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        // Insert 5 messages, 3 unread
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: i < 2)
        }

        // Recount unread
        let unreadCount = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX" && Column("isRead") == false).fetchCount($0)
        }

        // Update folder
        folder.unreadCount = unreadCount
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.unreadCount == 3)
    }
}
