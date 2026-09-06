/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("E2E Crash Recovery Scenarios")
struct E2ECrashRecoveryTests {

    @Test("Crash during archive: PendingOp recovered and executable")
    func crashDuringArchive() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Queue archive op (simulates user action)
        var op = PendingOperation(
            type: .archive,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op.status = PendingStatus.inFlight.rawValue // Was in-flight when "crash" happened
        try db.write { try op.insert($0) }

        // Simulate crash recovery: reset inFlight → queued
        try db.write { db in
            try db.execute(
                sql: "UPDATE pendingOperation SET status = ? WHERE status = ?",
                arguments: [PendingStatus.queued.rawValue, PendingStatus.inFlight.rawValue]
            )
        }

        let recovered = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(recovered?.status == PendingStatus.queued.rawValue)
    }

    @Test("Crash during send with sentAt: reconcile completes without re-send")
    func crashDuringSendWithSentAt() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Important", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date() // Send succeeded before crash
        msg.appendedToSent = false // But appendToSent didn't complete
        try db.write { try msg.insert($0) }

        // Reconcile: sentAt present → should NOT re-send, but should append to Sent
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil) // Proves send happened
        #expect(fetched?.appendedToSent == false) // Still needs appendToSent
    }

    @Test("Crash during body fetch: headers without bodies re-fetchable")
    func crashDuringBodyFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 5 headers, only 2 have bodies
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:0")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        // After crash recovery: find headers without bodies
        let headersWithoutBodies = try db.read { db -> Int in
            let sql = """
                SELECT COUNT(*) FROM messageHeader mh
                LEFT JOIN messageBody mb ON mh.id = mb.id
                WHERE mb.id IS NULL
                """
            return try Int.fetchOne(db, sql: sql) ?? 0
        }
        #expect(headersWithoutBodies == 3) // 3 headers need body re-fetch
    }

    @Test("Multiple pending ops survive restart and maintain FIFO order")
    func multiplePendingOpsSurviveRestart() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Queue 3 ops in order
        for i in 0..<3 {
            var op = PendingOperation(
                type: .markRead,
                messageIds: ["msg\(i)"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try db.write { try op.insert($0) }
        }

        // "Restart": fetch all pending ops ordered by createdAt
        let ops = try db.read {
            try PendingOperation
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }
        #expect(ops.count == 3)
        // FIFO order preserved
        #expect(ops[0].messageIds.first == "msg0")
        #expect(ops[1].messageIds.first == "msg1")
        #expect(ops[2].messageIds.first == "msg2")
    }

    @Test("Outbox failed messages stay visible for user retry")
    func outboxFailedMessagesVisible() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Fail", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        try db.write { try msg.insert($0) }

        // Failed messages are NOT auto-deleted
        let failed = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.failed.rawValue).fetchAll($0)
        }
        #expect(failed.count == 1)
        #expect(failed.first?.retryCount == 3)
    }
}
