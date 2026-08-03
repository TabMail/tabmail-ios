/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Real-`executeSingleOp` queue persistence and lane-halt tests.
///
/// Unlike `AccountManagerQueueIntegrationTests.swift` (which only exercises
/// `executeOperation`, a pure provider-dispatch function with no DB access),
/// `executeSingleOp` reads/writes `PendingOperation` rows via `self.dbPool`
/// (== `AppDatabase.dbPool` == `AppDatabase.shared`). So these tests swap
/// `AppDatabase.shared` to a temp-file-backed `DatabasePool`, mirroring
/// `InboxGestureActionTests.makeTestDB()`/`restoreTestDB()` — `TestDatabase.make()`
/// (a `DatabaseQueue`) is NOT usable here since `AppDatabase(dbPool:)` requires
/// a `DatabasePool`.
///
/// `.serialized`: swaps the process-wide `AppDatabase.shared` singleton —
/// mirrors `InboxGestureActionTests` / `MessageDetailStagedFallbackTests`.
@Suite("AccountManagerQueue drain — executeSingleOp + lane halt (F2)", .serialized, .processGlobalState)
struct AccountManagerQueueDrainTests {

    // MARK: - Harness (mirrors InboxGestureActionTests.makeTestDB/restoreTestDB)

    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        return (pool, dir, previous)
    }

    /// See `InboxGestureActionTests.restoreTestDB`: the drain paths driven here
    /// fire unstructured background Tasks that can outlive the test body, so no
    /// earlier boundary can safely close the pool. Restore a real predecessor
    /// when present, and retain this installed fixture until process exit in
    /// either case.
    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    private func insertOp(_ op: PendingOperation, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try op.insert(db) }
    }

    private func fetchOp(_ id: String, pool: DatabasePool) throws -> PendingOperation? {
        try pool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    /// The GAP3 cases exercise lane mechanics with opaque ids. Make their
    /// account explicitly stable-provider-backed so T2.6's IMAP UID/epoch
    /// checkpoint is correctly inapplicable.
    private func insertStableProviderFixture(accountId: String, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "GAP3", provider: .gmail)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
        }
    }

    // MARK: - 3. Tag ops keep their immediate best-effort drop

    @Test(".setTag completes immediately (local-only, ADR-IOS-036): op deleted, outcome .proceed, provider never called")
    func setTagCompletesImmediatelyBestEffort() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // `executeOperation`'s `.setTag`/`.removeTag` case is local-only
        // (ADR-IOS-036), so it never calls the provider.
        let provider = MockEmailProvider()
        let op = PendingOperation(type: .setTag, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX", tagValue: "archive")
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        #expect(outcome == .proceed)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after == nil)
        let callLog = await provider.callLog
        #expect(callLog.isEmpty)
    }

    // MARK: - 6. Batch split preserves the parent op's createdAt (buildLanes FIFO invariant)
    //
    // The `messageNotFound` split constructs ops via `PendingOperation(...)`, whose init stamps
    // `createdAt = Date()` — LATER than a same-lane sibling op queued between the
    // original batch and the split. That starves the split op behind the sibling
    // on every later `buildLanes` pass, since lanes preserve createdAt-asc order.
    // The fix copies `currentOp.createdAt` onto each split op before insert.

    @Test("Batch messageNotFound split: each new single-message op inherits the parent's createdAt, not Date()")
    func messageNotFoundBatchSplitPreservesCreatedAt() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.messageNotFound)

        var op = PendingOperation(type: .move, messageIds: ["msg-1", "msg-2"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive")
        // Dynamic (repo rule: no hardcoded dates); whole-second so the GRDB date
        // round-trip compares exactly.
        let parentCreatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        op.createdAt = parentCreatedAt
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        // .haltLane (F3, not .proceed): the split singles are freshly queued,
        // un-executed — the lane must halt so a later same-lane op never runs
        // ahead of them. See laneHaltsAfterBatchSplitBlocksChainedOp below for
        // the integration scenario this prevents.
        #expect(outcome == .haltLane)
        let originalStillThere = try fetchOp(op.id, pool: pool)
        #expect(originalStillThere == nil)

        let splitOps = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db)
        }
        #expect(splitOps.count == 2)
        guard splitOps.count == 2 else { return }
        for splitOp in splitOps {
            #expect(splitOp.type == .move)
            #expect(splitOp.createdAt == parentCreatedAt)
        }
    }

    // MARK: - 8. GAP1: reconcilePendingOperations (real function) — launch-time crash recovery

    @Test("reconcilePendingOperations (real function): inFlight→queued, cancelled deleted, queued untouched, count==2 — accountId has no registered provider so the triggered drain no-ops safely")
    func reconcilePendingOperationsResetsInFlightDeletesCancelledLeavesQueued() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // No provider registered for "acc-gap1" — drainPendingQueue's claim
        // loop (`guard providers[op.accountId] != nil else { ...skip... }`,
        // AccountManagerQueue.swift) no-ops on both surviving ops without
        // ever calling executeSingleOp, so this test observes ONLY
        // reconcilePendingOperations' own crash-recovery SQL (reset
        // inFlight→queued, delete cancelled), not drain behavior. The
        // subsequent reconcileOutbox()/reconcileCalendarQueue() calls inside
        // reconcilePendingOperations no-op safely too — their tables are
        // empty in this test DB.
        var inFlightOp = PendingOperation(type: .markRead, messageIds: ["msg-inflight"], accountId: "acc-gap1", folderPath: "INBOX")
        inFlightOp.status = PendingStatus.inFlight.rawValue
        var cancelledOp = PendingOperation(type: .markUnread, messageIds: ["msg-cancelled"], accountId: "acc-gap1", folderPath: "INBOX")
        cancelledOp.status = PendingStatus.cancelled.rawValue
        let queuedOp = PendingOperation(type: .markFlagged, messageIds: ["msg-queued"], accountId: "acc-gap1", folderPath: "INBOX")
        try insertOp(inFlightOp, pool: pool)
        try insertOp(cancelledOp, pool: pool)
        try insertOp(queuedOp, pool: pool)

        await AccountManager.shared.reconcilePendingOperations()

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == "acc-gap1").fetchAll(db)
        }
        #expect(remaining.count == 2)

        let inFlightAfter = try fetchOp(inFlightOp.id, pool: pool)
        #expect(inFlightAfter != nil, "inFlight op must survive (reset, not dropped)")
        #expect(inFlightAfter?.status == PendingStatus.queued.rawValue, "inFlight op reset to queued by crash recovery")

        let cancelledAfter = try fetchOp(cancelledOp.id, pool: pool)
        #expect(cancelledAfter == nil, "cancelled op deleted by crash recovery")

        let queuedAfter = try fetchOp(queuedOp.id, pool: pool)
        #expect(queuedAfter != nil, "already-queued op must survive untouched")
        #expect(queuedAfter?.status == PendingStatus.queued.rawValue, "already-queued op untouched")
        #expect(queuedAfter?.retryCount == 0, "untouched op's retryCount is unaffected")
    }

    // MARK: - 9. GAP2: MockEmailProvider.setMoveThrowsOnId — partial-batch progress + requeue-then-retry

    @Test("Batch move [A,B,C] fails on B via a generic connection error (ProviderError.notConnected): the WHOLE op resets to queued (not split), retryCount+1, failedAccounts marked, movedIds shows only the successful prefix [A] — a cleared retry then completes the op")
    func batchMoveGenericFailureHaltsWholeOpThenRetrySucceeds() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // The Archive folder must exist locally — otherwise executeSingleOp's
        // generic-error self-heal branch (`destMissing`, AccountManagerQueue.swift)
        // would DROP the op instead of resetting it to queued, defeating the
        // requeue-then-retry scenario under test here.
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc-gap2"
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc-gap2").insert(db)
        }

        let provider = MockEmailProvider()
        // Generic connection error — NOT messageNotFound —
        // the same ProviderError.notConnected ConnectionResilienceTests uses
        // for the "ordinary connection blip" scenario (falls through to
        // executeSingleOp's bottom generic catch).
        await provider.setMoveThrowsOnId("B", error: ProviderError.notConnected)

        let op = PendingOperation(type: .move, messageIds: ["A", "B", "C"], accountId: "acc-gap2", folderPath: "INBOX", destinationPath: "Archive")
        try insertOp(op, pool: pool)

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: context)

        #expect(outcome == .haltLane)
        #expect(context.failedAccounts.contains("acc-gap2"))

        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil, "the whole op must be reset to queued — a generic transient error is not confirmed staleness, so it must NOT split")
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
        #expect(after.retryCount == 1)
        #expect(after.messageIds == ["A", "B", "C"], "batch stays intact")

        let movedAfterFailure = await provider.movedIds
        #expect(movedAfterFailure.count == 1)
        guard movedAfterFailure.count == 1 else { return }
        #expect(movedAfterFailure[0].ids == ["A"], "only the prefix BEFORE the failing id (B) was recorded as moved")
        #expect(movedAfterFailure[0].from == "INBOX")
        #expect(movedAfterFailure[0].to == "Archive")

        // Idempotent-retry simulation: connection restored — clear the
        // failure on the SAME mock instance, re-claim (mirrors how the real
        // drain's claim step marks inFlight before calling executeSingleOp
        // again), and re-run.
        await provider.clearMoveThrowsOnId()
        var mutableReclaimed = after
        mutableReclaimed.status = PendingStatus.inFlight.rawValue
        let reclaimed = mutableReclaimed
        try await pool.writeWithoutTransaction { db in try reclaimed.save(db) }

        let secondOutcome = await AccountManager.shared.executeSingleOp(reclaimed, provider: provider, context: AccountManager.DrainContext())
        #expect(secondOutcome == .proceed)

        let final = try fetchOp(op.id, pool: pool)
        #expect(final == nil, "op deleted — completed on retry")

        let movedAfterRetry = await provider.movedIds
        #expect(movedAfterRetry.count == 2)
        #expect(movedAfterRetry.last?.ids == ["A", "B", "C"], "retry succeeds for the full batch")
    }

    // MARK: - 10. GAP3: drainPendingQueue() end-to-end via registerProviderForTesting

    @Test("drainPendingQueue() (real, end-to-end): 3 queued ops across two lanes all execute exactly once, and same-lane ops run in createdAt order")
    func drainPendingQueueRealEndToEndExecutesLanesInCreatedAtOrder() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gap3-lanes"
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) }
            restoreTestDB(pool: pool, previous: previous, dir: dir)
        }

        let provider = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        try insertStableProviderFixture(accountId: accountId, pool: pool)

        // Dynamic (repo rule: no hardcoded dates); whole-second so the GRDB
        // date round-trip compares exactly.
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        // Lane 1: two ops sharing "msg-1" (buildLanes connected-component) — must run in createdAt order.
        var opA = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: accountId, folderPath: "INBOX")
        opA.createdAt = t0
        var opB = PendingOperation(type: .markFlagged, messageIds: ["msg-1"], accountId: accountId, folderPath: "INBOX")
        opB.createdAt = t0.addingTimeInterval(1)
        // Lane 2: a different message id — a separate connected component, runs concurrently.
        var opC = PendingOperation(type: .markRead, messageIds: ["msg-2"], accountId: accountId, folderPath: "INBOX")
        opC.createdAt = t0
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)
        try insertOp(opC, pool: pool)

        await AccountManager.shared.drainPendingQueue()

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }
        #expect(remaining.isEmpty, "all ops executed (deleted)")

        let callLog = await provider.callLog
        let readIdx = callLog.firstIndex { $0.contains("markRead") && $0.contains("msg-1") }
        let flagIdx = callLog.firstIndex { $0.contains("markFlagged") && $0.contains("msg-1") }
        #expect(readIdx != nil && flagIdx != nil, "both lane-1 ops must have reached the provider")
        if let readIdx, let flagIdx {
            #expect(readIdx < flagIdx, "same-lane ops (sharing msg-1) execute in createdAt order")
        }
        let readCalls = await provider.markedReadIds
        #expect(readCalls.contains { $0.ids == ["msg-2"] }, "lane 2's op also executed")
    }

    @Test("drainPendingQueue() (real): a generic connection error on the first same-lane op gates the rest of the lane — all remaining ops in that lane are requeued, none execute")
    func drainPendingQueueRealFirstOpFailureGatesRestOfLane() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gap3-failure"
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) }
            restoreTestDB(pool: pool, previous: previous, dir: dir)
        }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.notConnected)
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        try insertStableProviderFixture(accountId: accountId, pool: pool)

        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var opA = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: accountId, folderPath: "INBOX")
        opA.createdAt = t0
        var opB = PendingOperation(type: .markFlagged, messageIds: ["msg-1"], accountId: accountId, folderPath: "INBOX")
        opB.createdAt = t0.addingTimeInterval(1)
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)

        await AccountManager.shared.drainPendingQueue()

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(remaining.count == 2, "both ops must still exist — requeued, not executed or dropped")
        guard remaining.count == 2 else { return }
        #expect(remaining.allSatisfy { $0.status == PendingStatus.queued.rawValue })
        let everyClaimIsConservative = remaining.allSatisfy(\.everAttempted)
        #expect(everyClaimIsConservative,
                "every row claimed in the drain snapshot must be durably conservative before any scheduled provider I/O; a later lane halt does not erase that evidence")

        let flagged = await provider.markedFlaggedIds
        #expect(flagged.isEmpty, "the later same-lane op must never have reached the provider — failedAccounts gates the rest of the lane")
    }

    @Test("drainPendingQueue() (real): two concurrent calls are safe — the isDraining/needsRedrain guard serializes them, the op executes exactly once (no duplication, no crash)")
    func drainPendingQueueRealConcurrentCallsExecuteOpsExactlyOnce() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gap3-reentrant"
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) }
            restoreTestDB(pool: pool, previous: previous, dir: dir)
        }

        let provider = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        try insertStableProviderFixture(accountId: accountId, pool: pool)

        let op = PendingOperation(type: .markRead, messageIds: ["msg-reentrant"], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        async let first: Void = AccountManager.shared.drainPendingQueue()
        async let second: Void = AccountManager.shared.drainPendingQueue()
        await first
        await second

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }
        #expect(remaining.isEmpty, "the op executed (deleted)")

        let readCalls = await provider.markedReadIds
        #expect(readCalls.count == 1, "the op must execute EXACTLY ONCE despite two concurrent drain calls")
    }

    // MARK: - T3.5 / T4.H1 coupling — a body-preserving Gmail action 400 is still terminal
    //
    // `GmailProvider.modifyMessage` now issues its POST through
    // `AuthedHTTP.requestPreservingBadRequestBody`, so a final 400 arrives as
    // `HTTPError.networkErrorWithBody(400, body)` rather than the bodyless
    // `.networkError(400)`. `AccountManagerQueue.isPermanentlyInvalidError` was
    // widened in the same change to classify the two identically.
    //
    // These two tests pin the SYSTEM property that widening exists for — the
    // durable row's END STATE — not the matcher's mechanism:
    //
    //   * an unclassified Gmail action 400 is TERMINAL: the row is gone;
    //   * a transient 503 is NOT: the row survives, queued, for another drain.
    //
    // RED PROOF (recorded, since this defect never existed as a landed commit):
    // the failing configuration is the HALF-PORT — `modifyMessage` switched to
    // the body-preserving helper while `isPermanentlyInvalidError` still matched
    // only `.networkError`. In that state the 400 falls through to the generic
    // transient branch and the first test below observes the row still present
    // with `status == queued`, i.e. it becomes indistinguishable from its own
    // 503 control. Reverting only the `networkErrorWithBody` arm of
    // `isPermanentlyInvalidError` reproduces it.

    @Test("real GmailProvider: an UNCLASSIFIED action 400 is terminal — the durable op row is deleted, not left queued")
    func unclassifiedGmailActionBadRequestRetiresTheDurableOp() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gmail-unclassified-400"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let providerMessageId = "gmail-queue-unclassified-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-queue-unclassified@example.com",
            providerMessageId: providerMessageId,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        server.injectUnclassified400(providerMessageId: providerMessageId)

        try insertStableProviderFixture(accountId: accountId, pool: pool)
        let op = PendingOperation(
            type: .markRead, messageIds: [providerMessageId],
            accountId: accountId, folderPath: "INBOX"
        )
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: server.provider(), context: AccountManager.DrainContext()
        )

        #expect(outcome == .proceed)
        let after = try fetchOp(op.id, pool: pool)
        #expect(
            after == nil,
            "a permanent-shaped Gmail action 400 must not survive as a forever-retrying row"
        )
        // Two-sided non-vacuity, DURABLE + WIRE: the row is gone AND the
        // injected 400 was genuinely consumed at the HTTP boundary — a row
        // deleted for any other reason (provider never reached, op claimed by
        // something else) leaves this counter at zero.
        #expect(
            server.unclassified400ServedCount() == 1,
            "the injected unclassified 400 must have been served exactly once: \(server.unclassified400ServedCount())"
        )
    }

    @Test("real GmailProvider: a transient 503 is NOT terminal — the durable op row survives, requeued for retry")
    func transientGmailActionFailureKeepsTheDurableOpQueued() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gmail-transient-503"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let providerMessageId = "gmail-queue-transient-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-queue-transient@example.com",
            providerMessageId: providerMessageId,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        server.injectTransient503OnModify(providerMessageId: providerMessageId)

        try insertStableProviderFixture(accountId: accountId, pool: pool)
        let op = PendingOperation(
            type: .markRead, messageIds: [providerMessageId],
            accountId: accountId, folderPath: "INBOX"
        )
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: server.provider(), context: AccountManager.DrainContext()
        )

        // The CONTROL: if the terminal classification were over-broad — or if
        // "the row is gone" in the sibling test came from something other than
        // the 400 — this row would be gone too.
        #expect(outcome == .haltLane)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil, "a transient failure must never retire the user's intention")
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
        #expect(after.retryCount == op.retryCount + 1)
        #expect(
            server.transient503OnModifyServedCount() == 1,
            "503 is outside HTTPRetryPolicy.gmail's retryable set, so it is served exactly once: \(server.transient503OnModifyServedCount())"
        )
    }
}
