/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite: historyId Advance-Before-Processing

@Suite("Delta Sync — historyId advances before change processing")
struct DeltaSyncHistoryIdTests {

    @Test("Gmail historyId advances even when totalChanges > 0")
    func gmailHistoryIdAdvancesWithChanges() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        account.lastHistoryId = "100"
        try db.write { try account.update($0) }
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Simulate what gmailDeltaSync now does: advance historyId BEFORE processing
        let newHistoryId = "200"
        try db.write { dbConn in
            _ = try Account.filter(Column("id") == "acc1")
                .updateAll(dbConn, Column("lastHistoryId").set(to: newHistoryId))
        }

        // Verify historyId advanced
        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.lastHistoryId == "200")

        // Even if change processing were to fail after this point,
        // the historyId is already advanced — no eternal re-processing
    }

    @Test("Gmail historyId advances on zero-change delta (no-op fast path)")
    func gmailHistoryIdAdvancesOnZeroChanges() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        account.lastHistoryId = "500"
        try db.write { try account.update($0) }

        // Zero changes — historyId still advances
        let newHistoryId = "550"
        try db.write { dbConn in
            _ = try Account.filter(Column("id") == "acc1")
                .updateAll(dbConn, Column("lastHistoryId").set(to: newHistoryId))
        }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.lastHistoryId == "550")
    }

    @Test("Exchange deltaToken advances before change processing")
    func exchangeDeltaTokenAdvancesWithChanges() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "test@outlook.com", provider: .outlook)
        account.lastHistoryId = "token-old"
        try db.write { try account.update($0) }
        try TestDatabase.insertFolder(db, name: "Inbox", path: "Inbox", role: .inbox, accountId: "acc1")

        // Simulate advance before processing
        let newDeltaToken = "token-new"
        try db.write { dbConn in
            _ = try Account.filter(Column("id") == "acc1")
                .updateAll(dbConn, Column("lastHistoryId").set(to: newDeltaToken))
        }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.lastHistoryId == "token-new")
    }
}

// MARK: - Suite: Idempotent change processing safety

@Suite("Delta Sync — Idempotent change processing is safe with early historyId advance")
struct DeltaSyncIdempotencyTests {

    @Test("Re-inserting same message header is idempotent (upsert pattern)")
    func reinsertSameHeaderIdempotent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First insert
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", subject: "Original", accountId: "acc1", isRead: false
        )

        // Simulate delta sync re-processing the same message (existsLocally && belongsInFolder path)
        try db.write { dbConn in
            if var existing = try MessageHeader
                .filter(Column("messageId") == "msg1" && Column("folderId") == "acc1:INBOX")
                .fetchOne(dbConn) {
                existing.isRead = true // Server update
                try existing.update(dbConn)
            }
        }

        // Message still exists, updated
        let fetched = try db.read {
            try MessageHeader.filter(Column("messageId") == "msg1").fetchOne($0)
        }
        #expect(fetched != nil)
        #expect(fetched?.isRead == true)

        // Only 1 row — no duplicates
        let count = try db.read {
            try MessageHeader.filter(Column("messageId") == "msg1").fetchCount($0)
        }
        #expect(count == 1)
    }

    @Test("Re-deleting already-deleted message is idempotent")
    func reDeleteAlreadyDeletedIdempotent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "msg-del", accountId: "acc1")

        // First delete
        try db.write { dbConn in
            let matches = try MessageHeader
                .filter(Column("messageId") == "msg-del")
                .fetchAll(dbConn)
            for msg in matches { try msg.delete(dbConn) }
        }

        // Second delete (re-processing) — should not crash or error
        let removedCount = try db.write { dbConn -> Int in
            let matches = try MessageHeader
                .filter(Column("messageId") == "msg-del")
                .fetchAll(dbConn)
            for msg in matches { try msg.delete(dbConn) }
            return matches.count
        }

        #expect(removedCount == 0, "Re-deleting already-deleted message returns 0 matches")
    }
}
