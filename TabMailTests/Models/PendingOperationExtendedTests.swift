/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PendingOperation Extended")
struct PendingOperationExtendedTests {

    @Test("OperationType rawValues match expected strings")
    func operationTypeRawValues() {
        #expect(OperationType.archive.rawValue == "archive")
        #expect(OperationType.delete.rawValue == "delete")
        #expect(OperationType.move.rawValue == "move")
        #expect(OperationType.markRead.rawValue == "markRead")
        #expect(OperationType.markUnread.rawValue == "markUnread")
        #expect(OperationType.markFlagged.rawValue == "markFlagged")
        #expect(OperationType.markUnflagged.rawValue == "markUnflagged")
        #expect(OperationType.setTag.rawValue == "setTag")
    }

    @Test("PendingStatus rawValues")
    func pendingStatusRawValues() {
        #expect(PendingStatus.queued.rawValue == "queued")
        #expect(PendingStatus.inFlight.rawValue == "inFlight")
    }

    @Test("PendingOperation generates unique IDs")
    func uniqueIds() {
        let op1 = PendingOperation(type: .archive, messageIds: ["1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .archive, messageIds: ["1"], accountId: "acc1", folderPath: "INBOX")
        #expect(op1.id != op2.id)
    }

    @Test("PendingOperation stores messageIds as JSON")
    func messageIdsJSON() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingOperation(
            type: .archive,
            messageIds: ["msg1", "msg2", "msg3"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.messageIds.count == 3)
        #expect(fetched?.messageIds.contains("msg2") == true)
    }

    @Test("PendingOperation setTag includes tagValue")
    func setTagIncludesTagValue() {
        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: ActionTag.reply.rawValue
        )
        #expect(op.tagValue == ActionTag.reply.rawValue)
    }

    @Test("PendingOperation default status is queued")
    func defaultStatusQueued() {
        let op = PendingOperation(
            type: .delete,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        #expect(op.status == PendingStatus.queued.rawValue)
    }
}
