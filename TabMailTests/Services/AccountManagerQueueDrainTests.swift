/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Real-`executeSingleOp` tests for the uidResolutionFailed transient-retry fix (ADR-IOS-018 amendment 2026-07-10, DECISIONS.md): a claimed
/// `PendingOperation` that hits `ProviderError.uidResolutionFailed` for a
/// non-move, non-tag type (markRead/markUnread/markFlagged/...) must retry with
/// a capped budget (`SyncConfig.maxUidResolutionRetries`) instead of being
/// unconditionally dropped, and the per-lane drain loop must HALT the lane
/// (not run a later op in the same connected component) whenever an op is
/// reset to `.queued` for retry.
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

    // MARK: - 1. Non-move, non-tag op: first uidResolutionFailed retries (haltLane)

    @Test(".markRead + uidResolutionFailed, uidResolutionRetryCount 0: op reset to queued, uidResolutionRetryCount bumped (retryCount untouched), outcome .haltLane")
    func markReadUidResolutionFailedFirstRetryHalts() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.uidResolutionFailed("msg-1"))

        let op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        #expect(outcome == .haltLane)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil)
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
        #expect(after.uidResolutionRetryCount == 1)
        #expect(after.retryCount == 0)
    }

    // MARK: - 2. Non-move, non-tag op: uidResolutionRetryCount at cap confirms stale (proceed)

    @Test(".markRead + uidResolutionFailed at retry cap (on the DEDICATED uidResolutionRetryCount): op deleted (confirmed stale), outcome .proceed")
    func markReadUidResolutionFailedAtCapDrops() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.uidResolutionFailed("msg-1"))

        var op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op.uidResolutionRetryCount = SyncConfig.maxUidResolutionRetries
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        #expect(outcome == .proceed)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after == nil)
    }

    // MARK: - 2b. Contamination regression: a saturated SHARED retryCount must not pre-exhaust the dedicated cap

    @Test("Contamination regression: retryCount at cap from prior generic-branch blips does NOT pre-exhaust uidResolutionRetryCount — op requeued, not dropped")
    func retryCountAtCapDoesNotContaminateUidResolutionCap() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.uidResolutionFailed("msg-1"))

        // Simulate prior ordinary connection blips: the GENERIC transient-error
        // branch (bottom of executeSingleOp's catch) bumped the SHARED retryCount
        // to the cap on unrelated failures. This op has never actually hit
        // uidResolutionFailed before, so uidResolutionRetryCount is still its
        // struct default (0). Before the fix, the uidResolutionFailed branch read
        // the shared retryCount and would have wrongly dropped this op on its
        // FIRST real SEARCH miss.
        var op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        op.retryCount = SyncConfig.maxUidResolutionRetries
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        #expect(outcome == .haltLane)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil)
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
        #expect(after.uidResolutionRetryCount == 1)
        #expect(after.retryCount == SyncConfig.maxUidResolutionRetries) // untouched by this branch
    }

    // MARK: - 3. Tag ops keep their immediate best-effort drop

    @Test(".setTag completes immediately (local-only, ADR-IOS-036): op deleted, outcome .proceed, provider never called")
    func setTagCompletesImmediatelyBestEffort() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // NOTE: `executeOperation`'s `.setTag`/`.removeTag` case is a local-only
        // no-op (ADR-IOS-036) — it never calls the provider, so it can never
        // actually throw `uidResolutionFailed` through the real dispatch path.
        // The `uidResolutionFailed` + tag-op catch branch in `executeSingleOp`
        // (kept verbatim per the ADR-IOS-018 amendment (2026-07-10)) is therefore legacy/defensive
        // code that is unreachable via `executeOperation` today. What IS real and
        // testable is the observable behavior the spec describes — "deleted
        // immediately, best-effort, .proceed" — which a `.setTag` op reaches via
        // the SUCCESS path (executeOperation no-ops → op deletes normally).
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

    // MARK: - 4. Move op with a non-IMAP provider: destination can't be confirmed → retry, failedAccounts untouched

    @Test(".move + uidResolutionFailed with non-IMAP provider: reset to queued, failedAccounts NOT touched, outcome .haltLane")
    func moveUidResolutionFailedNonIMAPProviderHalts() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // MockEmailProvider is NOT an IMAPProvider, so the destination-existence
        // check (`provider as? IMAPProvider`) can never run — this exercises the
        // "non-IMAP move provider" fallthrough at the bottom of the
        // uidResolutionFailed branch.
        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.uidResolutionFailed("msg-1"))

        let op = PendingOperation(type: .move, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive")
        try insertOp(op, pool: pool)

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: context)

        #expect(outcome == .haltLane)
        #expect(context.failedAccounts.isEmpty)
        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil)
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
    }

    // MARK: - 5. Lane-halt integration: a later op in the same lane must NOT run

    @Test("Lane halt integration: markFlagged never executes after markRead's uidResolutionFailed halts the lane")
    func laneHaltIntegrationBlocksLaterOpInSameLane() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.uidResolutionFailed("msg-1"))

        let readOp = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let flagOp = PendingOperation(type: .markFlagged, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try insertOp(readOp, pool: pool)
        try insertOp(flagOp, pool: pool)

        // Sanity-check F1: the two ops share a member id, so buildLanes puts
        // them in ONE lane (this is what makes the halt meaningful — without
        // F1 they'd land in separate lanes and this scenario couldn't occur).
        let lanes = AccountManager.buildLanes([readOp, flagOp])
        #expect(lanes.count == 1)
        guard lanes.count == 1 else { return }

        // Hand-drive the per-lane loop exactly as `drainPendingQueue`'s Task body
        // does (there is no test hook to populate the actor-isolated
        // `providers`/`workQueues` dictionaries needed to call the real
        // singleton `drainPendingQueue()` end-to-end), calling the REAL
        // `executeSingleOp` for each op in lane order and halting+requeuing on
        // `.haltLane` — see AccountManagerQueueDrainTests file doc comment.
        let context = AccountManager.DrainContext()
        let lane = lanes[0]
        for (index, op) in lane.enumerated() {
            let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: context)
            if outcome == .haltLane {
                for remainingOp in lane[(index + 1)...] {
                    try await pool.writeWithoutTransaction { db in
                        var updated = remainingOp
                        updated.status = PendingStatus.queued.rawValue
                        try updated.save(db)
                    }
                }
                break
            }
        }

        // markFlagged must NEVER have been called — the lane halted at markRead.
        let flagged = await provider.markedFlaggedIds
        #expect(flagged.isEmpty)

        // Both ops remain queued (readOp reset by executeSingleOp itself;
        // flagOp requeued by the halt-requeue loop above).
        let readAfter = try fetchOp(readOp.id, pool: pool)
        let flagAfter = try fetchOp(flagOp.id, pool: pool)
        #expect(readAfter?.status == PendingStatus.queued.rawValue)
        #expect(flagAfter?.status == PendingStatus.queued.rawValue)
    }

    // MARK: - 6. Batch split preserves the parent op's createdAt (buildLanes FIFO invariant)
    //
    // Both `executeSingleOp` split sites (messageNotFound, uidResolutionFailed)
    // used to construct split ops via `PendingOperation(...)`, whose init stamps
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

    @Test("Batch uidResolutionFailed split: each new single-message op inherits the parent's createdAt, not Date()")
    func uidResolutionFailedBatchSplitPreservesCreatedAt() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.uidResolutionFailed("msg-1"))

        var op = PendingOperation(type: .markRead, messageIds: ["msg-1", "msg-2"], accountId: "acc1", folderPath: "INBOX")
        // Dynamic (repo rule: no hardcoded dates); whole-second so the GRDB date
        // round-trip compares exactly.
        let parentCreatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        op.createdAt = parentCreatedAt
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())

        // .haltLane (F3, not .proceed) — see the identical note on the
        // messageNotFound split test above.
        #expect(outcome == .haltLane)
        let originalStillThere = try fetchOp(op.id, pool: pool)
        #expect(originalStillThere == nil)

        let splitOps = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db)
        }
        #expect(splitOps.count == 2)
        guard splitOps.count == 2 else { return }
        for splitOp in splitOps {
            #expect(splitOp.type == .markRead)
            #expect(splitOp.createdAt == parentCreatedAt)
        }
    }

    // MARK: - 7. F3 integration: batch split must halt the lane — a later
    // same-lane op must not run ahead of the un-executed split children.
    //
    // Regression for the exact data-loss scenario: lane [move([A,B] INBOX→
    // ARCHIVE), move([B] ARCHIVE→TRASH)]. Before the fix, the batch split
    // returned `.proceed`, so the chained TRASH move ran in the SAME pass —
    // ahead of the still-unexecuted split singles — and would go on to
    // SEARCH-miss B in ARCHIVE (still sitting in INBOX) and get wrongly
    // confirmed-stale/dropped, permanently losing the user's delete.

    @Test("Lane halt integration: batch move split halts the lane — the chained move on a shared message id never executes in the same pass")
    func laneHaltsAfterBatchSplitBlocksChainedOp() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.uidResolutionFailed("msg-a"))

        let batchOp = PendingOperation(type: .move, messageIds: ["msg-a", "msg-b"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive")
        let chainedOp = PendingOperation(type: .move, messageIds: ["msg-b"], accountId: "acc1", folderPath: "Archive", destinationPath: "Trash")
        try insertOp(batchOp, pool: pool)
        try insertOp(chainedOp, pool: pool)

        // Sanity-check F1: both ops touch msg-b, so buildLanes puts them in ONE
        // lane — without F1 they'd land in separate lanes and race concurrently,
        // which is a different (already-fixed) bug from the one under test here.
        let lanes = AccountManager.buildLanes([batchOp, chainedOp])
        #expect(lanes.count == 1)
        guard lanes.count == 1 else { return }

        // Hand-drive the per-lane loop exactly as `drainPendingQueue`'s Task body
        // does — see laneHaltIntegrationBlocksLaterOpInSameLane above for why
        // there's no test hook onto the real singleton drain.
        let context = AccountManager.DrainContext()
        let lane = lanes[0]
        for (index, op) in lane.enumerated() {
            let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: context)
            if outcome == .haltLane {
                for remainingOp in lane[(index + 1)...] {
                    try await pool.writeWithoutTransaction { db in
                        var updated = remainingOp
                        updated.status = PendingStatus.queued.rawValue
                        try updated.save(db)
                    }
                }
                break
            }
        }

        // The chained op must NEVER have reached the provider — no move call
        // recorded with its destination (Trash). (The batch's own failed
        // attempt to Archive is expected and recorded.)
        let moved = await provider.movedIds
        #expect(!moved.contains { $0.to == "Trash" }, "chained op's move must not have run this pass")
        #expect(moved.contains { $0.to == "Archive" }, "sanity: the batch op's own (failing) move attempt did run")

        // Chained op still exists, still queued — not deleted, not executed.
        let chainedAfter = try fetchOp(chainedOp.id, pool: pool)
        #expect(chainedAfter != nil)
        #expect(chainedAfter?.status == PendingStatus.queued.rawValue)

        // Original batch op is gone, replaced by two split singles (both queued).
        let batchAfter = try fetchOp(batchOp.id, pool: pool)
        #expect(batchAfter == nil)
        let splitOps = try await pool.read { db in
            try PendingOperation
                .filter(Column("accountId") == "acc1" && Column("id") != chainedOp.id)
                .fetchAll(db)
        }
        #expect(splitOps.count == 2, "the batch split into two single-message ops")
        guard splitOps.count == 2 else { return }
        for splitOp in splitOps {
            #expect(splitOp.type == .move)
            #expect(splitOp.status == PendingStatus.queued.rawValue)
        }
        let splitMessageIds = Set(splitOps.flatMap(\.messageIds))
        #expect(splitMessageIds == ["msg-a", "msg-b"])
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
        // Generic connection error — NOT uidResolutionFailed/messageNotFound —
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
}
