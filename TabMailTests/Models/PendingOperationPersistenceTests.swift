/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Comprehensive GRDB persistence tests for PendingOperation.
@Suite("PendingOperation Persistence")
struct PendingOperationPersistenceTests {

    // MARK: - Insert / Fetch / Delete round-trip

    @Test("Insert and fetch round-trip preserves all fields")
    func insertFetchRoundTrip() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive",
            tagValue: nil
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil)
        #expect(fetched?.id == op.id)
        #expect(fetched?.type == .move)
        #expect(fetched?.messageIds == ["msg-1", "msg-2"])
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.folderPath == "INBOX")
        #expect(fetched?.destinationPath == "Archive")
        #expect(fetched?.tagValue == nil)
        #expect(fetched?.retryCount == 0)
        #expect(fetched?.status == PendingStatus.queued.rawValue)
    }

    @Test("Delete removes op from DB")
    func deleteRemovesOp() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        try db.write { _ = try PendingOperation.deleteOne($0, key: op.id) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched == nil)
    }

    @Test("fetchAll returns all inserted ops")
    func fetchAllReturnsAll() throws {
        let db = try TestDatabase.make()
        let op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .markUnread, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        let op3 = PendingOperation(type: .move, messageIds: ["msg-3"], accountId: "acc2", folderPath: "INBOX", destinationPath: "Trash")
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let all = try db.read { try PendingOperation.fetchAll($0) }
        #expect(all.count == 3)
    }

    // MARK: - Queue ordering by timestamp

    @Test("Ordering by createdAt ascending yields FIFO order")
    func orderingByCreatedAt() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op1.createdAt = Date(timeIntervalSince1970: 100)
        var op2 = PendingOperation(type: .move, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
        op2.createdAt = Date(timeIntervalSince1970: 200)
        var op3 = PendingOperation(type: .markFlagged, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX")
        op3.createdAt = Date(timeIntervalSince1970: 50)

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let ordered = try db.read { try PendingOperation.order(Column("createdAt").asc).fetchAll($0) }
        #expect(ordered.count == 3)
        #expect(ordered[0].id == op3.id) // earliest
        #expect(ordered[1].id == op1.id)
        #expect(ordered[2].id == op2.id) // latest
    }

    @Test("Ordering by createdAt descending yields newest first")
    func orderingByCreatedAtDesc() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op1.createdAt = Date(timeIntervalSince1970: 100)
        var op2 = PendingOperation(type: .markUnread, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        op2.createdAt = Date(timeIntervalSince1970: 300)

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
        }

        let ordered = try db.read { try PendingOperation.order(Column("createdAt").desc).fetchAll($0) }
        #expect(ordered[0].id == op2.id)
        #expect(ordered[1].id == op1.id)
    }

    // MARK: - Filter by accountId

    @Test("Filter by accountId returns only matching ops")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()

        let op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .markRead, messageIds: ["msg-2"], accountId: "acc2", folderPath: "INBOX")
        let op3 = PendingOperation(type: .move, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let acc1Ops = try db.read {
            try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Ops.count == 2)
        #expect(acc1Ops.allSatisfy { $0.accountId == "acc1" })

        let acc2Ops = try db.read {
            try PendingOperation.filter(Column("accountId") == "acc2").fetchAll($0)
        }
        #expect(acc2Ops.count == 1)
        #expect(acc2Ops[0].accountId == "acc2")
    }

    @Test("Filter by nonexistent accountId returns empty")
    func filterByNonexistentAccountId() throws {
        let db = try TestDatabase.make()

        let op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        let result = try db.read {
            try PendingOperation.filter(Column("accountId") == "nonexistent").fetchAll($0)
        }
        #expect(result.isEmpty)
    }

    // MARK: - Status transitions

    @Test("Status transition: queued → inFlight")
    func statusTransitionQueuedToInFlight() throws {
        let db = try TestDatabase.make()
        var op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        #expect(op.status == PendingStatus.queued.rawValue)

        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.inFlight.rawValue)
    }

    @Test("Status transition: inFlight → queued (on failure)")
    func statusTransitionInFlightToQueued() throws {
        let db = try TestDatabase.make()
        var op = PendingOperation(type: .move, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.insert($0) }

        op.status = PendingStatus.queued.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.queued.rawValue)
    }

    @Test("Status transition: queued → cancelled")
    func statusTransitionQueuedToCancelled() throws {
        let db = try TestDatabase.make()
        var op = PendingOperation(type: .markFlagged, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        op.status = PendingStatus.cancelled.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.cancelled.rawValue)
    }

    @Test("Filter by status works for all statuses")
    func filterByStatus() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        var op2 = PendingOperation(type: .markUnread, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        op2.status = PendingStatus.inFlight.rawValue
        var op3 = PendingOperation(type: .markFlagged, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX")
        op3.status = PendingStatus.cancelled.rawValue

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let queued = try db.read {
            try PendingOperation.filter(Column("status") == PendingStatus.queued.rawValue).fetchAll($0)
        }
        #expect(queued.count == 1)

        let inFlight = try db.read {
            try PendingOperation.filter(Column("status") == PendingStatus.inFlight.rawValue).fetchAll($0)
        }
        #expect(inFlight.count == 1)

        let cancelled = try db.read {
            try PendingOperation.filter(Column("status") == PendingStatus.cancelled.rawValue).fetchAll($0)
        }
        #expect(cancelled.count == 1)
    }

    // MARK: - Duplicate prevention / uniqueness

    @Test("Each PendingOperation has a unique UUID id")
    func uniqueUUIDs() throws {
        let db = try TestDatabase.make()

        let op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
        }

        #expect(op1.id != op2.id)
        let all = try db.read { try PendingOperation.fetchAll($0) }
        #expect(all.count == 2)
    }

    @Test("Duplicate insert with same id throws")
    func duplicateInsertThrows() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        #expect(throws: (any Error).self) {
            try db.write { try op.insert($0) }
        }
    }

    // MARK: - Tag operations persistence

    @Test("setTag op persists tagValue")
    func setTagPersistsTagValue() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: ActionTag.reply.rawValue
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.tagValue == "reply")
        #expect(fetched?.type == .setTag)
    }

    @Test("removeTag op has nil tagValue")
    func removeTagNilTagValue() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(
            type: .removeTag,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.tagValue == nil)
        #expect(fetched?.type == .removeTag)
    }

    // MARK: - messageIds JSON encoding

    @Test("messageIds with special characters round-trip correctly")
    func messageIdsSpecialChars() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["<msg@example.com>", "uid:123", "foo/bar"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.messageIds == ["<msg@example.com>", "uid:123", "foo/bar"])
    }

    @Test("Empty messageIds array persists correctly")
    func emptyMessageIds() throws {
        let db = try TestDatabase.make()
        let op = PendingOperation(
            type: .markRead,
            messageIds: [],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.messageIds.isEmpty == true)
    }

    // MARK: - retryCount

    @Test("retryCount can be incremented and persisted")
    func retryCountIncrement() throws {
        let db = try TestDatabase.make()
        var op = PendingOperation(type: .move, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
        try db.write { try op.insert($0) }

        op.retryCount = 3
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.retryCount == 3)
    }

    // MARK: - uidResolutionRetryCount (dedicated budget, separate from retryCount)

    @Test("uidResolutionRetryCount defaults to 0 and round-trips independently of retryCount")
    func uidResolutionRetryCountDefaultsAndPersists() throws {
        let db = try TestDatabase.make()
        var op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try db.write { try op.insert($0) }

        let inserted = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(inserted?.uidResolutionRetryCount == 0)

        // Bump retryCount (simulating unrelated generic-branch blips) and
        // uidResolutionRetryCount (simulating real SEARCH misses) independently —
        // they must not clobber each other.
        op.retryCount = 5
        op.uidResolutionRetryCount = 2
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.retryCount == 5)
        #expect(fetched?.uidResolutionRetryCount == 2)
    }

    // MARK: - deleteAll by filter

    @Test("deleteAll by status removes matching ops only")
    func deleteAllByStatus() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        var op2 = PendingOperation(type: .markUnread, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        op2.status = PendingStatus.cancelled.rawValue
        var op3 = PendingOperation(type: .markFlagged, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX")
        op3.status = PendingStatus.cancelled.rawValue

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let deletedCount = try db.write {
            try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll($0)
        }
        #expect(deletedCount == 2)

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].status == PendingStatus.queued.rawValue)
    }

    // MARK: - All operation types persist

    @Test("All OperationType values persist and round-trip via GRDB")
    func allOperationTypesPersist() throws {
        let db = try TestDatabase.make()
        let types: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded
        ]

        for opType in types {
            let op = PendingOperation(type: opType, messageIds: ["msg"], accountId: "acc1", folderPath: "INBOX")
            try db.write { try op.insert($0) }
            let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
            #expect(fetched?.type == opType, "OperationType \(opType.rawValue) should round-trip")
        }

        let all = try db.read { try PendingOperation.fetchAll($0) }
        #expect(all.count == types.count)
    }
}
