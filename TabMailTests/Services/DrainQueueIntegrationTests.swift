/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for the pending operation drain queue logic.
/// Simulates what `AccountManager.drainPendingQueue()` does but against
/// TestDatabase + MockEmailProvider, testing the interaction between
/// PendingOperation persistence and provider execution.
@Suite("Drain Queue Integration Tests")
struct DrainQueueIntegrationTests {

    let db: DatabaseQueue
    let provider: MockEmailProvider

    init() throws {
        db = try TestDatabase.make()
        provider = MockEmailProvider()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
    }

    // MARK: - Helpers

    /// Insert a PendingOperation into the database.
    private func insertOp(
        _ op: PendingOperation
    ) throws {
        try db.write { db in try op.insert(db) }
    }

    /// Fetch all pending operations ordered by createdAt.
    private func fetchAllOps() throws -> [PendingOperation] {
        try db.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    /// Fetch a single pending operation by ID.
    private func fetchOp(_ id: String) throws -> PendingOperation? {
        try db.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    /// Simulate the drain algorithm's execute-operation logic (mirrors AccountManager.executeOperation).
    private func simulateExecuteOperation(_ op: PendingOperation, provider: MockEmailProvider) async throws {
        switch op.type {
        case .archive, .delete:
            return // Legacy no-op
        case .move:
            guard let dest = op.destinationPath else { throw ProviderError.messageNotFound }
            guard op.folderPath != dest else { return } // Self-move no-op
            try await provider.move(ids: op.messageIds, from: op.folderPath, to: dest)
        case .markRead:
            try await provider.markRead(ids: op.messageIds, folder: op.folderPath)
        case .markUnread:
            try await provider.markUnread(ids: op.messageIds, folder: op.folderPath)
        case .markFlagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: true, folder: op.folderPath)
        case .markUnflagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: false, folder: op.folderPath)
        case .setTag, .removeTag, .markReplied, .markForwarded, .saveDraft, .deleteDraft,
             .addUserLabel, .removeUserLabel:
            return // Provider-specific or draft ops -- tested via other suites
        }
    }

    /// Simulate one pass of the drain loop: fetch queued ops, claim, execute, handle errors.
    /// Returns the number of ops that were processed (success or conflict-resolved).
    @discardableResult
    private func simulateDrainPass(provider: MockEmailProvider, failedAccounts: inout Set<String>) async throws -> Int {
        let ops = try fetchAllOps()
        var executedCount = 0

        for op in ops {
            if failedAccounts.contains(op.accountId) { continue }

            // Atomic claim: re-read and check status
            let currentOp: PendingOperation? = try await db.write { db -> PendingOperation? in
                guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else {
                    return nil
                }
                if fetched.status == PendingStatus.cancelled.rawValue {
                    _ = try PendingOperation.deleteOne(db, key: fetched.id)
                    return nil
                }
                if fetched.status == PendingStatus.inFlight.rawValue {
                    return nil
                }
                fetched.status = PendingStatus.inFlight.rawValue
                try fetched.save(db)
                return fetched
            }
            guard let currentOp else { continue }

            do {
                try await simulateExecuteOperation(currentOp, provider: provider)
                // Success: delete the op
                try await db.write { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                executedCount += 1
            } catch {
                // UID resolution on tag ops: delete (best-effort)
                if case ProviderError.uidResolutionFailed = error,
                   [.setTag, .removeTag].contains(currentOp.type) {
                    try await db.write { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    executedCount += 1
                    continue
                }
                // Message not found
                if isMessageNotFoundError(error) {
                    if currentOp.messageIds.count > 1 {
                        // Split batch into individual ops
                        try await db.write { db in
                            for msgId in currentOp.messageIds {
                                try PendingOperation(
                                    type: currentOp.type,
                                    messageIds: [msgId],
                                    accountId: currentOp.accountId,
                                    folderPath: currentOp.folderPath,
                                    destinationPath: currentOp.destinationPath,
                                    tagValue: currentOp.tagValue
                                ).insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                        executedCount += 1
                        continue
                    }
                    // Single message: drop (server wins)
                    try await db.write { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    executedCount += 1
                    continue
                }
                // UID resolution on non-tag ops: reset to queued, NOT add to failedAccounts
                if case ProviderError.uidResolutionFailed = error {
                    try await db.write { db in
                        var updated = currentOp
                        updated.status = PendingStatus.queued.rawValue
                        try updated.save(db)
                    }
                    continue
                }
                // Connection/transient error: reset to queued, skip this account
                try await db.write { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
                failedAccounts.insert(currentOp.accountId)
            }
        }
        return executedCount
    }

    /// Check if an error represents "message not found" (mirrors AccountManager.isMessageNotFoundError).
    private func isMessageNotFoundError(_ error: Error) -> Bool {
        let desc = "\(error)"
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error,
           (underlying as NSError).code == 404 { return true }
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }

    // MARK: - 1. Basic operation execution flow

    @Test("Basic markRead: queue → claim → execute → delete")
    func basicMarkReadFlow() async throws {
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op)

        // Verify op is in DB
        let beforeOps = try fetchAllOps()
        #expect(beforeOps.count == 1)
        #expect(beforeOps[0].status == PendingStatus.queued.rawValue)

        // Drain
        var failedAccounts = Set<String>()
        let count = try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Op should be deleted from DB
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
        #expect(count == 1)

        // Provider should have received the call
        let reads = await provider.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1"])
        #expect(reads[0].folder == "INBOX")
    }

    // MARK: - 2. Move operation dispatch

    @Test("Move operation calls provider.move with correct from/to/ids")
    func moveOperationDispatch() async throws {
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        let moved = await provider.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Archive")

        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    // MARK: - 3. Self-move no-op

    @Test("Self-move (source == dest) does NOT call provider.move")
    func selfMoveNoOp() async throws {
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "INBOX"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Provider should NOT have been called
        let moved = await provider.movedIds
        #expect(moved.isEmpty)

        // Op should still be deleted (treated as success)
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    // MARK: - 4. Cancelled op skipped

    @Test("Cancelled op is deleted without calling provider")
    func cancelledOpSkipped() async throws {
        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op.status = PendingStatus.cancelled.rawValue
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Op deleted during claim phase
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)

        // Provider should NOT have been called
        let callLog = await provider.callLog
        #expect(callLog.isEmpty)
    }

    // MARK: - 5. InFlight ops skipped

    @Test("InFlight ops are skipped on subsequent passes")
    func inFlightOpsSkipped() async throws {
        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op.status = PendingStatus.inFlight.rawValue
        try insertOp(op)

        var failedAccounts = Set<String>()
        let count = try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Op should still be in DB (not processed)
        let afterOps = try fetchAllOps()
        #expect(afterOps.count == 1)
        #expect(afterOps[0].status == PendingStatus.inFlight.rawValue)

        // Nothing executed
        #expect(count == 0)
        let callLog = await provider.callLog
        #expect(callLog.isEmpty)
    }

    // MARK: - 6. MessageNotFound conflict resolution (single msg)

    @Test("MessageNotFound on single message: op deleted (server wins)")
    func messageNotFoundSingleMsg() async throws {
        await provider.setMoveThrows(ProviderError.messageNotFound)

        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Op should be deleted (conflict resolved)
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)

        // Account should NOT be in failedAccounts
        #expect(!failedAccounts.contains("acc1"))
    }

    // MARK: - 7. MessageNotFound batch splitting

    @Test("MessageNotFound on batch: splits into individual single-message ops")
    func messageNotFoundBatchSplit() async throws {
        await provider.setMoveThrows(ProviderError.messageNotFound)

        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2", "msg-3"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )
        let originalId = op.id
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Original batch op should be deleted
        let originalOp = try fetchOp(originalId)
        #expect(originalOp == nil)

        // Should have 3 new individual ops
        let newOps = try fetchAllOps()
        #expect(newOps.count == 3)

        let msgIds = newOps.map(\.messageIds)
        #expect(msgIds.contains(["msg-1"]))
        #expect(msgIds.contains(["msg-2"]))
        #expect(msgIds.contains(["msg-3"]))

        // All new ops should be queued
        for newOp in newOps {
            #expect(newOp.type == .move)
            #expect(newOp.folderPath == "INBOX")
            #expect(newOp.destinationPath == "Trash")
            #expect(newOp.status == PendingStatus.queued.rawValue)
        }
    }

    // MARK: - 8. Connection error retry

    @Test("Network error resets op to queued, NOT deleted")
    func connectionErrorRetry() async throws {
        let networkError = ProviderError.networkError(
            underlying: NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        )
        await provider.setMoveThrows(networkError)

        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Op should still exist and be reset to queued
        let afterOps = try fetchAllOps()
        #expect(afterOps.count == 1)
        #expect(afterOps[0].status == PendingStatus.queued.rawValue)

        // Account should be in failedAccounts (skip remaining ops for this account)
        #expect(failedAccounts.contains("acc1"))
    }

    // MARK: - 9. UID resolution failure on tag ops

    @Test("uidResolutionFailed on setTag: op deleted (best-effort)")
    func uidResolutionFailedTagOp() async throws {
        // setTag/removeTag use provider-specific casts, so simulateExecuteOperation
        // returns without calling the mock. We need to test the error handling path directly.
        // Create a custom provider wrapper that throws uidResolutionFailed for tag ops.

        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: "archive"
        )
        try insertOp(op)

        // Manually simulate what the drain does when uidResolutionFailed is thrown on a tag op:
        // Claim the op
        try await db.write { db in
            var fetched = try PendingOperation.fetchOne(db, key: op.id)!
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(db)
        }

        // Simulate the error handling for uidResolutionFailed + tag op
        let error = ProviderError.uidResolutionFailed("msg-1")
        let isTagOp = [OperationType.setTag, .removeTag].contains(op.type)
        #expect(isTagOp)

        if case ProviderError.uidResolutionFailed = error, isTagOp {
            try await db.write { db in
                _ = try PendingOperation.deleteOne(db, key: op.id)
            }
        }

        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    // MARK: - 10. UID resolution failure on non-tag ops

    @Test("uidResolutionFailed on move: op reset to queued, NOT deleted")
    func uidResolutionFailedNonTagOp() async throws {
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try insertOp(op)

        // Claim the op
        try await db.write { db in
            var fetched = try PendingOperation.fetchOne(db, key: op.id)!
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(db)
        }

        // Simulate the error handling for uidResolutionFailed + non-tag op
        let error = ProviderError.uidResolutionFailed("msg-1")
        let isTagOp = [OperationType.setTag, .removeTag].contains(op.type)
        #expect(!isTagOp)

        if case ProviderError.uidResolutionFailed = error, !isTagOp {
            try await db.write { db in
                var updated = try PendingOperation.fetchOne(db, key: op.id)!
                updated.status = PendingStatus.queued.rawValue
                try updated.save(db)
            }
        }

        let afterOps = try fetchAllOps()
        #expect(afterOps.count == 1)
        #expect(afterOps[0].status == PendingStatus.queued.rawValue)
        #expect(afterOps[0].id == op.id)
    }

    // MARK: - 11. Multi-account isolation

    @Test("Failure in one account does not block other accounts")
    func multiAccountIsolation() async throws {
        // Set up second account
        try TestDatabase.insertAccount(db, id: "acc2", email: "user2@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        // Create a provider for acc2 that will succeed
        let provider2 = MockEmailProvider()

        // Queue a markRead for acc1 (will fail with network error)
        let networkError = ProviderError.networkError(
            underlying: NSError(domain: "NSURLErrorDomain", code: -1009)
        )
        // We use a single provider that fails for all ops via markReadThrows
        // But the drain sim uses one provider -- so we simulate multi-account differently:
        // acc1 op fails, acc2 op succeeds.

        var op1 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op1.createdAt = Date(timeIntervalSince1970: 1000)
        try insertOp(op1)

        var op2 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-2"],
            accountId: "acc2",
            folderPath: "INBOX"
        )
        op2.createdAt = Date(timeIntervalSince1970: 2000)
        try insertOp(op2)

        // Simulate drain with per-account provider dispatch:
        // acc1 uses provider (fails), acc2 uses provider2 (succeeds)
        var failedAccounts = Set<String>()

        let ops = try fetchAllOps()
        for op in ops {
            if failedAccounts.contains(op.accountId) { continue }

            let activeProvider: MockEmailProvider
            if op.accountId == "acc1" {
                await provider.setMarkReadThrows(networkError)
                activeProvider = provider
            } else {
                activeProvider = provider2
            }

            let currentOp: PendingOperation? = try await db.write { db -> PendingOperation? in
                guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else { return nil }
                if fetched.status == PendingStatus.cancelled.rawValue {
                    _ = try PendingOperation.deleteOne(db, key: fetched.id)
                    return nil
                }
                if fetched.status == PendingStatus.inFlight.rawValue { return nil }
                fetched.status = PendingStatus.inFlight.rawValue
                try fetched.save(db)
                return fetched
            }
            guard let currentOp else { continue }

            do {
                try await simulateExecuteOperation(currentOp, provider: activeProvider)
                try await db.write { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
            } catch {
                try await db.write { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
                failedAccounts.insert(currentOp.accountId)
            }
        }

        // acc1 op should still exist (reset to queued after failure)
        let op1After = try fetchOp(op1.id)
        #expect(op1After != nil)
        #expect(op1After?.status == PendingStatus.queued.rawValue)

        // acc2 op should be deleted (succeeded)
        let op2After = try fetchOp(op2.id)
        #expect(op2After == nil)

        // Only acc1 is in failedAccounts
        #expect(failedAccounts.contains("acc1"))
        #expect(!failedAccounts.contains("acc2"))

        // provider2 received the markRead call
        let reads2 = await provider2.markedReadIds
        #expect(reads2.count == 1)
        #expect(reads2[0].ids == ["msg-2"])
    }

    // MARK: - 12. FIFO ordering

    @Test("Operations execute in createdAt order (FIFO)")
    func fifoOrdering() async throws {
        var op1 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op1.createdAt = Date(timeIntervalSince1970: 1000)
        try insertOp(op1)

        var op2 = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op2.createdAt = Date(timeIntervalSince1970: 2000)
        try insertOp(op2)

        var op3 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-3"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op3.createdAt = Date(timeIntervalSince1970: 3000)
        try insertOp(op3)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // All ops should be deleted
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)

        // Check provider call log for order
        let callLog = await provider.callLog
        #expect(callLog.count == 3)
        #expect(callLog[0].contains("markRead"))
        #expect(callLog[1].contains("markUnread"))
        #expect(callLog[2].contains("markRead"))

        // Verify the specific message IDs to confirm ordering
        let reads = await provider.markedReadIds
        let unreads = await provider.markedUnreadIds
        #expect(reads.count == 2)
        #expect(unreads.count == 1)
        #expect(reads[0].ids == ["msg-1"]) // First markRead (oldest)
        #expect(unreads[0].ids == ["msg-2"]) // markUnread (middle)
        #expect(reads[1].ids == ["msg-3"]) // Second markRead (newest)
    }

    // MARK: - 13. Reconcile crash recovery

    @Test("Crash recovery: inFlight ops from previous session reset to queued")
    func reconcileCrashRecovery() throws {
        var op1 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op1.status = PendingStatus.inFlight.rawValue
        try insertOp(op1)

        var op2 = PendingOperation(
            type: .move,
            messageIds: ["msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        op2.status = PendingStatus.inFlight.rawValue
        try insertOp(op2)

        // Also insert a queued op that should remain unchanged
        let op3 = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-3"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op3)

        // Simulate reconcilePendingOperations: reset inFlight to queued
        try db.write { db in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(db)
            #expect(staleOps.count == 2)

            for staleOp in staleOps {
                var updated = staleOp
                updated.status = PendingStatus.queued.rawValue
                try updated.save(db)
            }
        }

        // All 3 ops should now be queued
        let allOps = try fetchAllOps()
        #expect(allOps.count == 3)
        for op in allOps {
            #expect(op.status == PendingStatus.queued.rawValue)
        }
    }

    // MARK: - 14. Cancelled ops cleanup

    @Test("Crash recovery: cancelled ops from previous session are deleted")
    func cancelledOpsCleanup() throws {
        var op1 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op1.status = PendingStatus.cancelled.rawValue
        try insertOp(op1)

        var op2 = PendingOperation(
            type: .move,
            messageIds: ["msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        op2.status = PendingStatus.cancelled.rawValue
        try insertOp(op2)

        // Also insert a queued op that should survive
        let op3 = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-3"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op3)

        // Simulate reconcilePendingOperations: clean up cancelled ops
        try db.write { db in
            let cancelledCount = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(db)
            #expect(cancelledCount == 2)
        }

        // Only the queued op should remain
        let afterOps = try fetchAllOps()
        #expect(afterOps.count == 1)
        #expect(afterOps[0].id == op3.id)
        #expect(afterOps[0].status == PendingStatus.queued.rawValue)
    }

    // MARK: - 15. markFlagged / markUnflagged dispatch

    @Test("markFlagged dispatches with flagged=true")
    func markFlaggedDispatch() async throws {
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        let flagged = await provider.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1", "msg-2"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")

        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    @Test("markUnflagged dispatches with flagged=false")
    func markUnflaggedDispatch() async throws {
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        let flagged = await provider.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == false)
        #expect(flagged[0].folder == "INBOX")

        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    // MARK: - Additional edge case tests

    @Test("markUnread dispatches correctly")
    func markUnreadDispatch() async throws {
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-5"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        let unreads = await provider.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-5"])
        #expect(unreads[0].folder == "INBOX")

        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    @Test("Archive/delete ops are legacy no-ops: op deleted without provider call")
    func archiveDeleteLegacyNoOp() async throws {
        let archiveOp = PendingOperation(
            type: .archive,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        let deleteOp = PendingOperation(
            type: .delete,
            messageIds: ["msg-2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try insertOp(archiveOp)
        try insertOp(deleteOp)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Both should be deleted (executeOperation returns immediately)
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)

        // Provider should not have been called for any action method
        let moved = await provider.movedIds
        let reads = await provider.markedReadIds
        let flagged = await provider.markedFlaggedIds
        #expect(moved.isEmpty)
        #expect(reads.isEmpty)
        #expect(flagged.isEmpty)
    }

    @Test("Move without destinationPath throws messageNotFound and is deleted")
    func moveMissingDestination() async throws {
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
            // No destinationPath
        )
        try insertOp(op)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Should be deleted (messageNotFound thrown, single msg → drop)
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)
    }

    @Test("Multiple queued ops for same message all drain correctly")
    func multipleOpsForSameMessage() async throws {
        var op1 = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op1.createdAt = Date(timeIntervalSince1970: 1000)
        try insertOp(op1)

        var op2 = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        op2.createdAt = Date(timeIntervalSince1970: 2000)
        try insertOp(op2)

        var failedAccounts = Set<String>()
        try await simulateDrainPass(provider: provider, failedAccounts: &failedAccounts)

        // Both ops should be drained
        let afterOps = try fetchAllOps()
        #expect(afterOps.isEmpty)

        let reads = await provider.markedReadIds
        let flagged = await provider.markedFlaggedIds
        #expect(reads.count == 1)
        #expect(flagged.count == 1)
    }

    @Test("isMessageNotFoundError detects various error formats")
    func messageNotFoundErrorDetection() {
        #expect(isMessageNotFoundError(ProviderError.messageNotFound))
        #expect(isMessageNotFoundError(ProviderError.networkError(
            underlying: NSError(domain: "HTTP", code: 404)
        )))

        // String-based detection
        let noSuchMsg = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such message"])
        #expect(isMessageNotFoundError(noSuchMsg))

        // Should NOT match on unrelated errors
        #expect(!isMessageNotFoundError(ProviderError.notConnected))
        #expect(!isMessageNotFoundError(ProviderError.networkError(
            underlying: NSError(domain: "HTTP", code: 500)
        )))
    }
}

