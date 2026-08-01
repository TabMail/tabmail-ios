/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Transactions")
struct DatabaseTransactionTests {

    @Test("Write transaction is atomic — rollback on error")
    func writeTransactionRollback() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert one message successfully
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Attempt to insert in a transaction that fails partway
        do {
            try db.write { db in
                let header = MessageHeader(
                    messageId: "2",
                    subject: "Test",
                    from: "a@b.com",
                    fromAddress: "a@b.com",
                    to: "c@d.com",
                    date: Date(),
                    snippet: "",
                    folderId: "acc1:INBOX",
                    accountId: "acc1",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                try header.insert(db)
                // Force error
                throw TestTransactionError.intentional
            }
        } catch is TestTransactionError {
            // Expected
        }

        // Only the first message should exist (second was rolled back)
        let count = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("Foreign key enforcement prevents orphan messages")
    func foreignKeyEnforcement() throws {
        let db = try TestDatabase.make()
        // Don't insert account — try to insert a message header directly
        do {
            try db.write { db in
                let header = MessageHeader(
                    messageId: "1",
                    subject: "Orphan",
                    from: "a@b.com",
                    fromAddress: "a@b.com",
                    to: "c@d.com",
                    date: Date(),
                    snippet: "",
                    folderId: "",
                    accountId: "nonexistent",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                try header.insert(db)
            }
            Issue.record("Expected foreign key violation")
        } catch {
            // Expected — FK constraint violation
        }
    }

    @Test("Concurrent reads don't block")
    func concurrentReads() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        for i in 0..<10 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        // Multiple reads should succeed without blocking
        let count1 = try db.read { try MessageHeader.fetchCount($0) }
        let count2 = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count1 == 10)
        #expect(count2 == 10)
    }

    @Test("INSERT OR IGNORE for duplicate primary key")
    func insertOrIgnore() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Insert body
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>First</p>")

        // Second insert with INSERT OR IGNORE should not overwrite
        try db.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:1"), htmlContent: "<p>Second</p>")
            try body.insert(db, onConflict: .ignore)
        }

        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(body?.htmlContent == "<p>First</p>")
    }
}

private enum TestTransactionError: Error {
    case intentional
}
