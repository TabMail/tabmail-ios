/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("E2E Offline Resilience")
struct E2EOfflineResilienceTests {

    @Test("Actions while offline: PendingOps queued correctly")
    func actionsWhileOffline() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        // User archives 3 messages while offline → 3 PendingOps
        for i in 0..<3 {
            var op = PendingOperation(
                type: .archive,
                messageIds: ["\(i)"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try db.write { try op.insert($0) }
        }

        let pendingCount = try db.read { try PendingOperation.fetchCount($0) }
        #expect(pendingCount == 3)
    }

    @Test("Send while offline: OutboxMessage queued for later drain")
    func sendWhileOffline() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Offline send", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // Message is queued, status is .queued
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .queued)
    }

    @Test("Reconnect scenario: all queued ops ready for drain")
    func reconnectDrainReady() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // 2 pending ops + 1 outbox message queued offline
        var op1 = PendingOperation(
            type: .archive,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        var op2 = PendingOperation(
            type: .markRead,
            messageIds: ["2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op1.insert($0) }
        try db.write { try op2.insert($0) }

        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // On reconnect: verify everything is in drainable state
        let pendingOps = try db.read {
            try PendingOperation.filter(Column("status") == PendingStatus.queued.rawValue).fetchAll($0)
        }
        let queuedOutbox = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.queued.rawValue).fetchAll($0)
        }
        #expect(pendingOps.count == 2)
        #expect(queuedOutbox.count == 1)
    }

    @Test("Concurrent pending ops from multiple accounts don't interfere")
    func multiAccountPendingOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "gmail", email: "u@gmail.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "imap", email: "u@imap.com", provider: .imap)

        // Gmail op
        var gmailOp = PendingOperation(
            type: .archive,
            messageIds: ["g1"],
            accountId: "gmail",
            folderPath: "INBOX"
        )
        try db.write { try gmailOp.insert($0) }

        // IMAP op
        var imapOp = PendingOperation(
            type: .delete,
            messageIds: ["i1"],
            accountId: "imap",
            folderPath: "INBOX"
        )
        try db.write { try imapOp.insert($0) }

        // Query per account
        let gmailOps = try db.read {
            try PendingOperation.filter(Column("accountId") == "gmail").fetchAll($0)
        }
        let imapOps = try db.read {
            try PendingOperation.filter(Column("accountId") == "imap").fetchAll($0)
        }
        #expect(gmailOps.count == 1)
        #expect(imapOps.count == 1)
        #expect(gmailOps.first?.type == .archive)
        #expect(imapOps.first?.type == .delete)
    }
}
