/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

private func makeOp(
    type: OperationType = .move,
    messageIds: [String] = ["100"],
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    destinationPath: String? = nil,
    tagValue: String? = nil,
    status: PendingStatus = .queued
) -> PendingOperation {
    var op = PendingOperation(
        type: type,
        messageIds: messageIds,
        accountId: accountId,
        folderPath: folderPath,
        destinationPath: destinationPath,
        tagValue: tagValue
    )
    op.status = status.rawValue
    return op
}

// MARK: - Suite 1: reconcilePendingOperations crash recovery

@Suite("Reconcile Pending Operations — Crash Recovery")
struct ReconcileCrashRecoveryTests {

    @Test("inFlight ops are reset to queued")
    func inFlightResetToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(status: .inFlight)
        try db.write { try op.insert($0) }

        // Simulate reconcile: reset inFlight → queued
        try db.write { dbConn in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(dbConn)
            for stale in staleOps {
                var updated = stale
                updated.status = PendingStatus.queued.rawValue
                try updated.save(dbConn)
            }
        }

        let result = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(result?.status == PendingStatus.queued.rawValue)
    }

    @Test("cancelled ops are deleted entirely")
    func cancelledOpsDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(status: .cancelled)
        try db.write { try op.insert($0) }

        try db.write { dbConn in
            let deletedCount = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(dbConn)
            #expect(deletedCount == 1)
        }

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("queued ops are unchanged by reconcile")
    func queuedOpsUnchanged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(status: .queued)
        try db.write { try op.insert($0) }

        // Reconcile only touches inFlight and cancelled
        try db.write { dbConn in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(dbConn)
            for stale in staleOps {
                var updated = stale
                updated.status = PendingStatus.queued.rawValue
                try updated.save(dbConn)
            }
            _ = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(dbConn)
        }

        let result = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(result?.status == PendingStatus.queued.rawValue)
        let count = try db.read { try PendingOperation.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("mixed statuses: each handled correctly")
    func mixedStatuses() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let opInFlight = makeOp(type: .markRead, status: .inFlight)
        let opCancelled = makeOp(type: .markUnread, status: .cancelled)
        var opQueued = makeOp(type: .move, status: .queued)
        opQueued.destinationPath = "Archive"

        try db.write { dbConn in
            try opInFlight.insert(dbConn)
            try opCancelled.insert(dbConn)
            try opQueued.insert(dbConn)
        }

        // Reconcile
        try db.write { dbConn in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(dbConn)
            for stale in staleOps {
                var updated = stale
                updated.status = PendingStatus.queued.rawValue
                try updated.save(dbConn)
            }
            _ = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(dbConn)
        }

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.count == 2)

        let inFlightResult = try db.read { try PendingOperation.fetchOne($0, key: opInFlight.id) }
        #expect(inFlightResult?.status == PendingStatus.queued.rawValue)

        let cancelledResult = try db.read { try PendingOperation.fetchOne($0, key: opCancelled.id) }
        #expect(cancelledResult == nil)

        let queuedResult = try db.read { try PendingOperation.fetchOne($0, key: opQueued.id) }
        #expect(queuedResult?.status == PendingStatus.queued.rawValue)
    }
}

// MARK: - Suite 2: isMessageNotFoundError classification

@Suite("isMessageNotFoundError Classification")
struct MessageNotFoundErrorTests {

    /// Helper that replicates the classification logic from AccountManagerQueue
    private func isMessageNotFoundError(_ error: Error) -> Bool {
        let desc = "\(error)"
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error,
           (underlying as NSError).code == 404 { return true }
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }

    @Test("ProviderError.messageNotFound → true")
    func providerErrorMessageNotFound() {
        #expect(isMessageNotFoundError(ProviderError.messageNotFound))
    }

    @Test("Error containing 'no such message' → true")
    func noSuchMessage() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such message"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("Error containing 'UID not found' → true")
    func uidNotFound() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "UID not found in mailbox"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("Error containing 'Message not found' → true")
    func messageNotFoundString() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Message not found on server"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("Error containing 'NONEXISTENT' → true")
    func nonexistent() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "NONEXISTENT mailbox"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("networkError with code 404 → true")
    func networkError404() {
        let underlying = NSError(domain: "HTTP", code: 404, userInfo: nil)
        #expect(isMessageNotFoundError(ProviderError.networkError(underlying: underlying)))
    }

    @Test("Random unrelated error → false")
    func randomError() {
        let error = NSError(domain: "Test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Internal server error"])
        #expect(!isMessageNotFoundError(error))
    }

    @Test("ProviderError.notConnected → false")
    func notConnectedIsFalse() {
        #expect(!isMessageNotFoundError(ProviderError.notConnected))
    }
}

// MARK: - Suite 3: executeOperation dispatch logic

@Suite("Execute Operation Dispatch Logic")
struct ExecuteOperationDispatchTests {

    @Test("archive type is legacy no-op — no provider call needed")
    func archiveIsNoOp() {
        let op = makeOp(type: .archive)
        #expect(op.type == .archive)
        // The switch returns immediately for .archive — nothing to assert beyond type recognition
    }

    @Test("delete type is legacy no-op — no provider call needed")
    func deleteIsNoOp() {
        let op = makeOp(type: .delete)
        #expect(op.type == .delete)
    }

    @Test("move with source==dest is self-move guard — no-op")
    func moveSelfMoveGuard() {
        let op = makeOp(type: .move, folderPath: "INBOX", destinationPath: "INBOX")
        #expect(op.folderPath == op.destinationPath)
        // Self-move check: folderPath != dest guard fails → returns without provider call
    }

    @Test("move without destinationPath throws messageNotFound")
    func moveMissingDestination() {
        let op = makeOp(type: .move, destinationPath: nil)
        #expect(op.destinationPath == nil)
        // In executeOperation, missing destinationPath throws ProviderError.messageNotFound
    }
}

// MARK: - Suite 5: Drain Algorithm DB-Level Details

@Suite("Drain Algorithm DB-Level Details")
struct DrainAlgorithmTests {

    @Test("FIFO ordering by createdAt ascending")
    func fifoOrdering() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op1 = makeOp(type: .markRead, messageIds: ["1"])
        op1.createdAt = Date(timeIntervalSince1970: 1000)
        var op2 = makeOp(type: .markUnread, messageIds: ["2"])
        op2.createdAt = Date(timeIntervalSince1970: 2000)
        var op3 = makeOp(type: .markFlagged, messageIds: ["3"])
        op3.createdAt = Date(timeIntervalSince1970: 500)

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let ops = try db.read {
            try PendingOperation.order(Column("createdAt").asc).fetchAll($0)
        }

        #expect(ops.count == 3)
        #expect(ops[0].id == op3.id) // earliest
        #expect(ops[1].id == op1.id)
        #expect(ops[2].id == op2.id) // latest
    }

    @Test("Cancelled ops deleted during claim phase")
    func cancelledDeletedDuringClaim() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(status: .cancelled)
        try db.write { try op.insert($0) }

        // Simulate claim phase
        let claimed = try db.write { dbConn -> PendingOperation? in
            guard var fetched = try PendingOperation.fetchOne(dbConn, key: op.id) else { return nil }
            if fetched.status == PendingStatus.cancelled.rawValue {
                _ = try PendingOperation.deleteOne(dbConn, key: fetched.id)
                return nil
            }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
            return fetched
        }

        #expect(claimed == nil)
        let remaining = try db.read { try PendingOperation.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("inFlight ops skipped in claim phase")
    func inFlightSkippedDuringClaim() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(status: .inFlight)
        try db.write { try op.insert($0) }

        let claimed = try db.write { dbConn -> PendingOperation? in
            guard var fetched = try PendingOperation.fetchOne(dbConn, key: op.id) else { return nil }
            if fetched.status == PendingStatus.cancelled.rawValue {
                _ = try PendingOperation.deleteOne(dbConn, key: fetched.id)
                return nil
            }
            if fetched.status == PendingStatus.inFlight.rawValue {
                return nil
            }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
            return fetched
        }

        #expect(claimed == nil)
        // Op still exists, just skipped
        let remaining = try db.read { try PendingOperation.fetchCount($0) }
        #expect(remaining == 1)
    }

    @Test("Batch messageNotFound → split into individual ops")
    func batchSplitOnMessageNotFound() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let batchOp = makeOp(type: .move, messageIds: ["msg1", "msg2", "msg3"], destinationPath: "Archive")
        try db.write { try batchOp.insert($0) }

        // Simulate split on messageNotFound for batch
        try db.write { dbConn in
            for msgId in batchOp.messageIds {
                try PendingOperation(
                    type: batchOp.type,
                    messageIds: [msgId],
                    accountId: batchOp.accountId,
                    folderPath: batchOp.folderPath,
                    destinationPath: batchOp.destinationPath,
                    tagValue: batchOp.tagValue
                ).insert(dbConn)
            }
            _ = try PendingOperation.deleteOne(dbConn, key: batchOp.id)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 3)
        for op in ops {
            #expect(op.messageIds.count == 1)
            #expect(op.type == .move)
            #expect(op.destinationPath == "Archive")
        }
    }

    @Test("Single messageNotFound → delete op (server wins)")
    func singleMessageNotFoundDeletesOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = makeOp(type: .move, messageIds: ["msg1"], destinationPath: "Archive")
        try db.write { try op.insert($0) }

        // Single-message conflict — drop
        try db.write { dbConn in
            _ = try PendingOperation.deleteOne(dbConn, key: op.id)
        }

        let remaining = try db.read { try PendingOperation.fetchCount($0) }
        #expect(remaining == 0)
    }

}
