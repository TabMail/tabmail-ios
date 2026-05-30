/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database PendingOperation")
struct DatabasePendingOpTests {

    @Test("PendingOperation insert and fetch")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingOperation(
            type: .archive,
            messageIds: ["msg1", "msg2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil)
        #expect(fetched?.type == .archive)
        #expect(fetched?.messageIds == ["msg1", "msg2"])
    }

    @Test("PendingOperation persists independently of account (no FK)")
    func noFKToAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingOperation(
            type: .delete,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Delete account — PendingOperation has no FK, so it persists
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(!remaining.isEmpty)
    }

    @Test("Multiple pending operations for same account")
    func multipleOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let types: [OperationType] = [.archive, .delete, .move, .markRead]
        for opType in types {
            let op = PendingOperation(
                type: opType,
                messageIds: ["msg1"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try db.write { try op.insert($0) }
        }

        let all = try db.read { try PendingOperation.fetchAll($0) }
        #expect(all.count == 4)
    }

    @Test("PendingOperation status update persists")
    func statusUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingOperation(
            type: .archive,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.update($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.inFlight.rawValue)
    }

    @Test("PendingOperation with move includes destination")
    func moveHasDestination() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingOperation(
            type: .move,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.destinationPath == "Archive")
    }
}
