/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PendingOperation")
struct PendingOperationTests {

    @Test("All 15 OperationType cases have raw values")
    func operationTypeRawValues() {
        let allCases: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded, .saveDraft, .deleteDraft,
            .addUserLabel, .removeUserLabel
        ]
        for op in allCases {
            #expect(!op.rawValue.isEmpty)
        }
        #expect(allCases.count == 15)
    }

    @Test("OperationType Codable round-trip")
    func operationTypeCodable() throws {
        let allCases: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded, .saveDraft, .deleteDraft,
            .addUserLabel, .removeUserLabel
        ]
        for op in allCases {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(OperationType.self, from: data)
            #expect(decoded == op)
        }
    }

    @Test("PendingStatus raw values")
    func pendingStatusRawValues() {
        #expect(PendingStatus.queued.rawValue == "queued")
        #expect(PendingStatus.inFlight.rawValue == "inFlight")
        #expect(PendingStatus.cancelled.rawValue == "cancelled")
    }

    @Test("Init sets defaults correctly")
    func initDefaults() {
        let op = PendingOperation(
            type: .archive,
            messageIds: ["msg1", "msg2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        #expect(!op.id.isEmpty)
        #expect(op.type == .archive)
        #expect(op.messageIds == ["msg1", "msg2"])
        #expect(op.accountId == "acc1")
        #expect(op.folderPath == "INBOX")
        #expect(op.destinationPath == nil)
        #expect(op.tagValue == nil)
        #expect(op.retryCount == 0)
        #expect(op.uidResolutionRetryCount == 0)
        #expect(op.status == PendingStatus.queued.rawValue)
    }

    @Test("Move op has destinationPath")
    func moveOpDestination() {
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        #expect(op.destinationPath == "Archive")
    }

    @Test("SetTag op has tagValue")
    func setTagOp() {
        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: ActionTag.archive.rawValue
        )
        #expect(op.tagValue == "archive")
    }

    @Test("messageIds JSON encode/decode")
    func messageIdsJsonRoundTrip() {
        var op = PendingOperation(
            type: .markRead,
            messageIds: ["a", "b", "c"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        #expect(op.messageIds == ["a", "b", "c"])
        op.messageIds = ["x", "y"]
        #expect(op.messageIds == ["x", "y"])
    }

    @Test("Each init generates unique id")
    func uniqueIds() {
        let op1 = PendingOperation(type: .archive, messageIds: ["m1"], accountId: "a", folderPath: "INBOX")
        let op2 = PendingOperation(type: .archive, messageIds: ["m1"], accountId: "a", folderPath: "INBOX")
        #expect(op1.id != op2.id)
    }
}
