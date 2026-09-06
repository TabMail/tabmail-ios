/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for AccountManagerQueue drain flow patterns.
/// Tests the DB-level logic used by drainPendingQueue and executeOperation,
/// using TestDatabase + MockEmailProvider for real GRDB + mock provider interaction.
@Suite("AccountManagerQueue Integration")
struct AccountManagerQueueIntegrationTests {

    // MARK: - executeOperation via AccountManager.shared

    @Test("executeOperation move calls provider.move with correct args")
    @MainActor
    func executeOperationMoveCallsProvider() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Trash")
    }

    @Test("executeOperation markRead calls provider.markRead")
    @MainActor
    func executeOperationMarkRead() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1"])
        #expect(reads[0].folder == "INBOX")
    }

    @Test("executeOperation markUnread calls provider.markUnread")
    @MainActor
    func executeOperationMarkUnread() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-3"],
            accountId: "acct1",
            folderPath: "Sent"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-3"])
        #expect(unreads[0].folder == "Sent")
    }

    @Test("executeOperation markFlagged calls provider with flagged=true")
    @MainActor
    func executeOperationMarkFlagged() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("executeOperation markUnflagged calls provider with flagged=false")
    @MainActor
    func executeOperationMarkUnflagged() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-2"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].flagged == false)
    }

    @Test("executeOperation propagates provider connection error")
    @MainActor
    func executeOperationPropagatesConnectionError() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        await #expect(throws: ProviderError.self) {
            _ = try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("executeOperation propagates messageNotFound error")
    @MainActor
    func executeOperationPropagatesMessageNotFound() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.messageNotFound)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )

        await #expect(throws: ProviderError.self) {
            _ = try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    // MARK: - isMessageNotFoundError classification

    @Test("isMessageNotFoundError returns true for ProviderError.messageNotFound")
    @MainActor
    func isMessageNotFoundForProviderError() {
        let result = AccountManager.shared.isMessageNotFoundError(ProviderError.messageNotFound)
        #expect(result == true)
    }

    @Test("isMessageNotFoundError returns true for 404 networkError")
    @MainActor
    func isMessageNotFoundFor404() {
        let underlying = NSError(domain: "test", code: 404, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        let result = AccountManager.shared.isMessageNotFoundError(error)
        #expect(result == true)
    }

    @Test("isMessageNotFoundError returns true for 'no such message' text")
    @MainActor
    func isMessageNotFoundForNoSuchMessage() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such message"])
        let result = AccountManager.shared.isMessageNotFoundError(error)
        #expect(result == true)
    }

    @Test("isMessageNotFoundError returns true for 'UID not found' text")
    @MainActor
    func isMessageNotFoundForUIDNotFound() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "UID not found in folder"])
        let result = AccountManager.shared.isMessageNotFoundError(error)
        #expect(result == true)
    }

    @Test("isMessageNotFoundError returns true for 'NONEXISTENT' text")
    @MainActor
    func isMessageNotFoundForNonexistent() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "NONEXISTENT mailbox"])
        let result = AccountManager.shared.isMessageNotFoundError(error)
        #expect(result == true)
    }

    /// A `ProviderEvidenceUnavailable` whose rendered description carries the
    /// classifier's text-fallback fragments — an `[NONEXISTENT]` response code
    /// (RFC 5530 §3, which names a missing MAILBOX) and the words `UID not
    /// found` — because several real conformers carry the server's raw tagged
    /// response text as a diagnostic payload. Declared here rather than reusing
    /// a production error type on purpose: the contract under test is the
    /// PROTOCOL, so a future conformer nobody has written yet must be covered by
    /// it too, and a test pinned to one concrete case would not say that.
    private struct TextBearingEvidenceUnavailable: ProviderEvidenceUnavailable,
        CustomStringConvertible
    {
        var description: String { "refused: no([NONEXISTENT] UID not found)" }
    }

    /// GitHub #115 (round 2, restated structurally in round 3). A provider that
    /// could not obtain the evidence its safety gate needs has told the queue
    /// NOTHING about whether the work is done — an absence of evidence, never
    /// never-drop exit 2 — so the operation stays queued whatever the server's
    /// response text happened to say. Because those errors may carry that text
    /// as a payload, the classifier's substring fallback would otherwise read a
    /// refusal quoting `[NONEXISTENT]` or `UID not found` as a
    /// provider-authoritative "already gone" and delete the op.
    ///
    /// Round 3 moved the exemption from one transport library's enum case to the
    /// `ProviderEvidenceUnavailable` protocol, which is why this test now drives
    /// a conformer rather than an `IMAPError`: the guarantee is that NO
    /// evidence-unavailable error can be text-classified, not that one named
    /// case cannot. The `NSError` text cases above are unchanged — raw server
    /// text reaching the queue on any OTHER error shape is still classified as
    /// before, which is what keeps this exemption narrow.
    @Test("isMessageNotFoundError and isConfirmedGoneError are false for an evidence-unavailable error, whatever its rendered text")
    @MainActor
    func evidenceUnavailableIsNeverMessageNotFound() {
        let error = TextBearingEvidenceUnavailable()
        // NON-VACUITY: the description really does carry the fragments the
        // fallback matches, so a passing result is the structural exemption and
        // not a payload that never triggered the fallback.
        #expect("\(error)".contains("NONEXISTENT"))
        #expect("\(error)".contains("UID not found"))
        #expect(
            AccountManager.shared.isMessageNotFoundError(error) == false,
            "an evidence-unavailable refusal was classified as message-not-found on its rendered text: \(error)")
        #expect(
            AccountManager.shared.isConfirmedGoneError(error) == false,
            "an evidence-unavailable refusal was classified as confirmed-gone: \(error)")
    }

    @Test("isMessageNotFoundError returns false for connection error")
    @MainActor
    func isMessageNotFoundFalseForConnectionError() {
        let result = AccountManager.shared.isMessageNotFoundError(ProviderError.notConnected)
        #expect(result == false)
    }

    @Test("isMessageNotFoundError returns false for auth error")
    @MainActor
    func isMessageNotFoundFalseForAuthError() {
        let result = AccountManager.shared.isMessageNotFoundError(ProviderError.authenticationFailed)
        #expect(result == false)
    }

    @Test("isMessageNotFoundError returns false for generic 500 error")
    @MainActor
    func isMessageNotFoundFalseForGeneric500() {
        let underlying = NSError(domain: "test", code: 500, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        let result = AccountManager.shared.isMessageNotFoundError(error)
        #expect(result == false)
    }

    // MARK: - DB Patterns for drain flow

    @Test("drain pattern: PendingOp inserted then deleted after execute succeeds")
    func drainPatternInsertAndDelete() throws {
        let db = try TestDatabase.make()

        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Verify it exists
        let fetched = try db.read { try PendingOperation.fetchAll($0) }
        #expect(fetched.count == 1)

        // Simulate successful execution + deletion
        try db.write { _ = try PendingOperation.deleteOne($0, key: op.id) }

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("drain pattern: op stays in queue when status reset to queued after error")
    func drainPatternOpStaysOnError() throws {
        let db = try TestDatabase.make()

        var op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { try op.insert($0) }

        // Simulate claiming (mark inFlight)
        try db.write { dbConn in
            op.status = PendingStatus.inFlight.rawValue
            try op.save(dbConn)
        }

        let inFlightOp = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(inFlightOp?.status == PendingStatus.inFlight.rawValue)

        // Simulate error → reset to queued
        try db.write { dbConn in
            op.status = PendingStatus.queued.rawValue
            try op.save(dbConn)
        }

        let resetOp = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(resetOp?.status == PendingStatus.queued.rawValue)
    }

    @Test("drain pattern: cancelled op is deleted during drain")
    func drainPatternCancelledOpDeleted() throws {
        let db = try TestDatabase.make()

        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Simulate undo cancellation
        try db.write { dbConn in
            op.status = PendingStatus.cancelled.rawValue
            try op.save(dbConn)
        }

        // Simulate drain detecting cancelled → delete
        try db.write { dbConn in
            let fetched = try PendingOperation.fetchOne(dbConn, key: op.id)
            if fetched?.status == PendingStatus.cancelled.rawValue {
                _ = try PendingOperation.deleteOne(dbConn, key: op.id)
            }
        }

        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("drain pattern: atomic claim marks inFlight, skips already-inFlight ops")
    func drainPatternAtomicClaim() throws {
        let db = try TestDatabase.make()

        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // First claim succeeds
        let claimed = try db.write { dbConn -> PendingOperation? in
            guard var fetched = try PendingOperation.fetchOne(dbConn, key: op.id) else { return nil }
            if fetched.status == PendingStatus.inFlight.rawValue { return nil }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
            return fetched
        }
        #expect(claimed != nil)
        #expect(claimed?.status == PendingStatus.inFlight.rawValue)

        // Second claim returns nil (already inFlight)
        let secondClaim = try db.write { dbConn -> PendingOperation? in
            guard var fetched = try PendingOperation.fetchOne(dbConn, key: op.id) else { return nil }
            if fetched.status == PendingStatus.inFlight.rawValue { return nil }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
            return fetched
        }
        #expect(secondClaim == nil)
    }

    @Test("drain pattern: failedAccounts skips ops for same account")
    func drainPatternFailedAccountsSkip() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        var op2 = PendingOperation(type: .markRead, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        var op3 = PendingOperation(type: .markRead, messageIds: ["msg-3"], accountId: "acc2", folderPath: "INBOX")
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.order(Column("createdAt").asc).fetchAll($0) }
        #expect(ops.count == 3)

        // Simulate failedAccounts = {"acc1"} — acc1 ops skipped, acc2 proceeds
        let failedAccounts: Set<String> = ["acc1"]
        var executed: [String] = []
        for op in ops {
            if failedAccounts.contains(op.accountId) { continue }
            executed.append(op.accountId)
        }
        #expect(executed == ["acc2"])
    }

    @Test("drain pattern: FIFO ordering by createdAt")
    func drainPatternFIFOOrdering() throws {
        let db = try TestDatabase.make()

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op1.createdAt = date1
        var op2 = PendingOperation(type: .move, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive")
        op2.createdAt = date2
        var op3 = PendingOperation(type: .markUnread, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX")
        op3.createdAt = date3

        // Insert in reverse order
        try db.write { dbConn in
            try op3.insert(dbConn)
            try op1.insert(dbConn)
            try op2.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.order(Column("createdAt").asc).fetchAll($0) }
        #expect(ops.count == 3)
        #expect(ops[0].type == .markRead)
        #expect(ops[1].type == .move)
        #expect(ops[2].type == .markUnread)
    }

    @Test("reconcile pattern: inFlight ops reset to queued on crash recovery")
    func reconcilePatternResetInFlight() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op1.status = PendingStatus.inFlight.rawValue
        var op2 = PendingOperation(type: .move, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
        op2.status = PendingStatus.inFlight.rawValue
        var op3 = PendingOperation(type: .markRead, messageIds: ["msg-3"], accountId: "acc1", folderPath: "INBOX")
        // op3 stays queued

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        // Simulate reconcile: reset inFlight → queued
        try db.write { dbConn in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(dbConn)
            for op in staleOps {
                var updated = op
                updated.status = PendingStatus.queued.rawValue
                try updated.save(dbConn)
            }
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 3)
        for op in ops {
            #expect(op.status == PendingStatus.queued.rawValue)
        }
    }

    @Test("reconcile pattern: cancelled ops cleaned up")
    func reconcilePatternCancelledCleanup() throws {
        let db = try TestDatabase.make()

        var op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op1.status = PendingStatus.cancelled.rawValue
        var op2 = PendingOperation(type: .move, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
        // op2 stays queued

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
        }

        // Simulate reconcile: delete cancelled ops
        try db.write { dbConn in
            _ = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
    }
}
