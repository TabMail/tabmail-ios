/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Test seam (this suite only): like `AccountManager.registerProviderForTesting`,
/// but lets a test pick the `ProviderWorkQueue` concurrency directly instead of
/// always using the production `SyncConfig.imapMaxConnectionCeiling` ceiling.
/// Needed to occupy a queue's single slot and force a subsequent claimant to
/// actually wait for it (see `cancellationWhileQueuedForProviderSlot...`).
extension AccountManager {
    func registerProviderForTesting(
        accountId: String,
        provider: any EmailProvider,
        maxConcurrency: Int
    ) {
        providers[accountId] = provider
        workQueues[accountId] = ProviderWorkQueue(provider: provider, maxConcurrency: maxConcurrency)
    }
}

/// Small rendezvous gate mirroring `AccountManagerQueueDrainTests`'s private
/// `QueuePreparationTestGate` (file-private there, so duplicated here per this
/// codebase's established per-file test-fixture convention — see e.g.
/// `InboxGestureActionTests.makeTestDB` being independently duplicated across
/// several suites rather than centralized).
private actor LivenessTestGate {
    private var didArrive = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWaitForRelease() async {
        didArrive = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrival() async {
        guard !didArrive else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    /// Idempotently releases every present or future resolver waiter. Tests call
    /// this on both success and failure paths before joining their drain tasks.
    func releaseAll() {
        isReleased = true
        let arrivals = arrivalWaiters
        let releases = releaseWaiters
        arrivalWaiters.removeAll()
        releaseWaiters.removeAll()
        for waiter in arrivals { waiter.resume() }
        for waiter in releases { waiter.resume() }
    }
}

/// §14.5 narrow queue-primitive safety tests for the Round-C global FIFO
/// (PLAN_INTENTION_QUEUE_AUDIT_V2.md §9.4 / Round C "Drain durable actions as
/// one global FIFO"). Companion to `AccountManagerQueueDrainTests.swift` — a
/// separate file (per this task's own latitude) so the anti-wedge liveness
/// scenarios don't further inflate an already 2000+ line suite.
///
/// The invariant every test here must prove at the end: **the queue is not
/// wedged.** Two shared helpers encode that:
///   - `assertQueueLivenessInvariants` — the STATIC checks (gate free, no
///     stranded waiter, no leaked owner/re-drain flag, no row left `inFlight`)
///     that must hold even while the queue is legitimately blocked on an
///     unresolved frontier;
///   - `assertQueueNotWedged` — the static checks PLUS the DEFINITIVE dynamic
///     check: a brand-new canary op, unrelated to the scenario under test,
///     must still drain to completion. Static cleanliness alone cannot
///     distinguish "healthy queue" from "queue that will never do anything
///     again"; only a subsequent real drain proves liveness.
///
/// `.serialized`/`.processGlobalState`: mirrors `AccountManagerQueueDrainTests`
/// — swaps the process-wide `AppDatabase.shared` singleton and mutates
/// `AccountManager.shared`'s registries, so it needs the same cross-suite
/// process-global critical section.
@Suite(
    "AccountManagerQueue liveness / anti-wedge (§14.5, Round C)",
    .serialized,
    .processGlobalState
)
struct AccountManagerQueueLivenessTests {

    private func joinDrainTask(_ task: Task<Void, Never>) async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await task.value
        }
    }

    // MARK: - Harness (mirrors AccountManagerQueueDrainTests.makeTestDB/restoreTestDB)

    /// Pools are closed at the next serialized test boundary, after the unread-count
    /// actor proves its leading/trailing debounce work is idle. Closing synchronously
    /// in `defer` races the production debounce task and produces SQLite use-after-close.
    private static let deferredDatabaseCleanup = Mutex<[(pool: DatabasePool, dir: URL)]>([])

    private func makeTestDB() async throws -> (
        pool: DatabasePool,
        dir: URL,
        previous: AppDatabase?
    ) {
        await UnreadCountManager.shared.awaitIdleForTesting()
        let deferred = Self.deferredDatabaseCleanup.withLock { cleanups in
            let result = cleanups
            cleanups.removeAll()
            return result
        }
        for cleanup in deferred {
            try? cleanup.pool.close()
            try? FileManager.default.removeItem(at: cleanup.dir)
        }

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

    /// Restore the process-global pointer immediately, but defer closing this pool
    /// until the next serialized test has awaited `UnreadCountManager` quiescence.
    private func restoreTestDB(
        pool: DatabasePool,
        previous: AppDatabase?,
        dir: URL
    ) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            Self.deferredDatabaseCleanup.withLock { $0.append((pool, dir)) }
        }
    }

    private func insertOp(_ op: PendingOperation, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try op.insert(db) }
    }

    private func fetchOp(_ id: String, pool: DatabasePool) throws -> PendingOperation? {
        try pool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    private func withRegisteredProvider(
        accountId: String,
        provider: any EmailProvider,
        operation: () async throws -> Void
    ) async throws {
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider
        )
        do {
            try await operation()
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
    }

    // MARK: - Shared anti-wedge assertions

    /// The STATIC liveness invariants — hold even while the queue is
    /// legitimately blocked (e.g. an unresolved permanently-failing
    /// frontier). No permit leak, no stranded waiter, no leaked drain
    /// owner/re-drain flag, and no row left `inFlight` with no live claimant.
    private func assertQueueLivenessInvariants(pool: DatabasePool) async throws {
        #expect(
            !AccountManager.shared.pendingOperationMutationGate.isHeldForTesting,
            "the mutation gate must not be leaked"
        )
        #expect(
            AccountManager.shared.pendingOperationMutationGate.waiterCountForTesting == 0,
            "no waiter may be stranded on the mutation gate"
        )
        #expect(
            await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
            "no drain owner or re-drain flag may be leaked"
        )
        let inFlightCount = try await pool.read { db in
            try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchCount(db)
        }
        #expect(inFlightCount == 0, "no row may be left stranded inFlight")
    }

    /// The DEFINITIVE "not wedged" check: static invariants PLUS proof that a
    /// brand-new, scenario-unrelated canary op still drains to completion.
    /// Requires `provider` (already registered for `accountId`) to be in a
    /// non-throwing state — callers clear any configured failure first.
    private func assertQueueNotWedged(
        pool: DatabasePool,
        accountId: String,
        provider: MockEmailProvider
    ) async throws {
        try await assertQueueLivenessInvariants(pool: pool)

        let canaryMessageId = "wedge-canary-\(UUID().uuidString.lowercased())@example.com"
        let canary = PendingOperation(
            type: .markRead,
            messageIds: [canaryMessageId],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try insertOp(canary, pool: pool)
        await AccountManager.shared.drainPendingQueue()
        #expect(
            try fetchOp(canary.id, pool: pool) == nil,
            "a scenario-unrelated canary op must still drain to completion — the queue must not be wedged"
        )
        let sawCanary = await provider.markedReadIds.contains { $0.ids == [canaryMessageId] }
        #expect(sawCanary, "the canary must have actually reached the provider")
    }

    // MARK: - 1. Stranded inFlight from ANY cause self-heals

    @Test("a row stranded inFlight mid-session (queue already prepared) self-heals at the next drain ownership — direct test of Part 1's reset")
    func strandedInFlightRowSelfHealsAtNextOwnership() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-stranded-selfheal-\(suffix)"
        let strandedMessageId = "stranded-\(suffix)@example.com"
        let behindMessageId = "stranded-behind-\(suffix)@example.com"

        let provider = MockEmailProvider()
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            // Prime the queue FIRST with an ordinary (empty) drain. This is
            // essential, not decorative: `preparePendingQueueForExecution`
            // runs the once-per-`AppDatabase` startup recovery
            // (`recoverPendingMessageQueueAfterCrash`, which ALSO does an
            // inFlight->queued reset) only on a database's FIRST successful
            // prepare — every later `drainPendingQueue()` call against the
            // SAME database takes the cached fast path and skips it (§9.4:
            // "does NOT re-run mid-session"). Without this priming call, a
            // single `drainPendingQueue()` below would be indistinguishable
            // from process start and would pass EVEN WITHOUT Part 1's fix —
            // confirmed: this test fails without Part 1's reset ONLY when the
            // stranded row is seeded AFTER this priming drain.
            await AccountManager.shared.drainPendingQueue()

            // NOW seed a row as `inFlight` with no owner — simulates a
            // terminal GRDB write that failed every retry attempt, or any
            // other unexpected early return between claim and completion,
            // occurring mid-session on an already-prepared queue
            // (deliberately NOT cancellation — that path is already covered
            // by `AccountManagerQueueDrainTests.cancelledDrainDoesNotStrandClaimedFrontier`).
            var stranded = PendingOperation(
                type: .markRead,
                messageIds: [strandedMessageId],
                accountId: accountId,
                folderPath: "INBOX"
            )
            stranded.status = PendingStatus.inFlight.rawValue
            let behind = PendingOperation(
                type: .markFlagged,
                messageIds: [behindMessageId],
                accountId: accountId,
                folderPath: "INBOX"
            )
            try insertOp(stranded, pool: pool)
            try insertOp(behind, pool: pool)

            await AccountManager.shared.drainPendingQueue()

            #expect(
                try fetchOp(stranded.id, pool: pool) == nil,
                "the stranded row must be reset to queued, executed, and deleted — not left wedging the frontier"
            )
            #expect(
                try fetchOp(behind.id, pool: pool) == nil,
                "the row behind the formerly-stranded frontier must also complete in the SAME drain"
            )
            let readCalls = await provider.markedReadIds
            #expect(readCalls.contains { $0.ids == [strandedMessageId] })
            let flagCalls = await provider.markedFlaggedIds
            #expect(flagCalls.contains { $0.ids == [behindMessageId] })

            try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        }
    }

    // MARK: - 2. Cancellation between claim and the provider call

    @Test("cancelling the drain while it is queued for a provider-queue slot (claimed, before any provider I/O) does not strand or wedge")
    func cancellationWhileQueuedForProviderSlotDoesNotStrandOrWedge() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-cancel-slot-wait-\(suffix)"
        let firstMessageId = "cancel-slot-first-\(suffix)@example.com"
        let secondMessageId = "cancel-slot-second-\(suffix)@example.com"

        let provider = MockEmailProvider()
        // maxConcurrency: 1 so a single occupier forces the drain's claimed-
        // frontier `queue.execute(priority: .userAction) { ... }` call to
        // wait for the slot — i.e. strictly AFTER claim (row already
        // `inFlight`) but strictly BEFORE any provider I/O (markRead is never
        // invoked while the occupier holds the only slot).
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider,
            maxConcurrency: 1
        )

        let op1 = PendingOperation(type: .markRead, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
        let op2 = PendingOperation(type: .markFlagged, messageIds: [secondMessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op1, pool: pool)
        try insertOp(op2, pool: pool)

        guard let queue = await AccountManager.shared.workQueues[accountId] else {
            Issue.record("provider work queue was not registered")
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            return
        }

        let occupantEntered = LivenessTestGate()
        let occupantTask = Task { @Sendable in
            await queue.execute(priority: .userAction) {
                await occupantEntered.arriveAndWaitForRelease()
            }
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await occupantEntered.waitUntilArrival()
        }

        let drain = Task { await AccountManager.shared.drainPendingQueue() }
        do {
            // Wait until op1 is claimed (inFlight) — proves the drain is now
            // blocked strictly on the occupied work-queue slot, before any
            // provider I/O has run.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                while try fetchOp(op1.id, pool: pool)?.status != PendingStatus.inFlight.rawValue {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            #expect(await provider.markedReadIds.isEmpty, "provider I/O must not have started yet")

            drain.cancel()
            // Release the occupant now. `ProviderWorkQueue.execute`'s
            // non-throwing Void overload is deliberately NOT cancellation-
            // aware (always waits for a slot and always runs the work), so
            // the drain's claimed op still runs to a normal terminal
            // completion despite the cancellation signal — this test proves
            // that stays true (and stays non-wedging even if a future change
            // made this call site cancellation-aware, thanks to Part 1's
            // ownership-start reset).
            await occupantEntered.releaseAll()
            try await joinDrainTask(drain)
            _ = await occupantTask.value
        } catch {
            await occupantEntered.releaseAll()
            drain.cancel()
            try? await joinDrainTask(drain)
            _ = await occupantTask.value
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }

        #expect(try fetchOp(op1.id, pool: pool) == nil, "op1 must not be stranded inFlight after the cancelled drain")
        let readCalls = await provider.markedReadIds
        #expect(readCalls.contains { $0.ids == [firstMessageId] })

        // A subsequent (uncancelled) drain picks up op2, which the cancelled
        // owner never reached.
        await AccountManager.shared.drainPendingQueue()
        #expect(try fetchOp(op2.id, pool: pool) == nil, "op2 must not be wedged behind the cancelled drain")
        let flagCalls = await provider.markedFlaggedIds
        #expect(flagCalls.contains { $0.ids == [secondMessageId] })

        try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    // MARK: - 3. Provider throws CancellationError specifically

    @Test("provider throwing CancellationError specifically is an ordinary transient failure, never a terminal drop")
    func providerCancellationErrorIsTransientNotTerminal() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-provider-cancellationerror-\(suffix)"
        let messageId = "provider-cancellationerror-\(suffix)@example.com"

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(CancellationError())

        let op = PendingOperation(type: .markRead, messageIds: [messageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()

            let afterFailure = try fetchOp(op.id, pool: pool)
            #expect(afterFailure != nil, "CancellationError must never terminally drop the op")
            #expect(afterFailure?.status == PendingStatus.queued.rawValue)
            #expect(afterFailure?.messageIds == [messageId], "payload unchanged")
            #expect(afterFailure?.retryCount == 1)
            #expect(await provider.markedReadIds.count == 1, "exactly one attempt reached the provider")

            try await assertQueueLivenessInvariants(pool: pool)

            // A later drain, once the failure clears, completes it — proving
            // it was requeued (retryable), not silently swallowed.
            await provider.setMarkReadThrows(nil)
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(op.id, pool: pool) == nil, "a later drain completes it once the failure clears")
            #expect(await provider.markedReadIds.count == 2)

            try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        }
    }

    // MARK: - 4. A legacy .cancelled row at the head of the FIFO

    @Test("a legacy .cancelled row at the head of the FIFO is skipped and deleted, never blocking the frontier")
    func legacyCancelledRowAtHeadDoesNotBlockFrontier() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-legacy-cancelled-head-\(suffix)"
        let firstMessageId = "legacy-cancelled-first-\(suffix)@example.com"
        let secondMessageId = "legacy-cancelled-second-\(suffix)@example.com"

        let provider = MockEmailProvider()
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            // Prime the queue FIRST with an ordinary (empty) drain. Without
            // this, the row below would be deleted by the once-per-database
            // STARTUP legacy cleanup in `recoverPendingMessageQueueAfterCrash`
            // (which unconditionally deletes every `.cancelled` row at
            // process start, independent of `claimFrontierOperation`'s
            // runtime skip-and-delete logic under test here) rather than by
            // the frontier-claiming walk this test means to exercise. Priming
            // first makes the row a genuine MID-SESSION `.cancelled` row —
            // exactly how Undo's pre-Round-D status-cancellation path
            // actually created one (§9.4) — and is the only way this test
            // exercises `claimFrontierOperation`'s cancelled-row branch rather
            // than being silently satisfied by unrelated startup cleanup.
            await AccountManager.shared.drainPendingQueue()

            var cancelledOp = PendingOperation(
                type: .markRead,
                messageIds: ["legacy-cancelled-opaque-\(suffix)@example.com"],
                accountId: accountId,
                folderPath: "INBOX"
            )
            cancelledOp.status = PendingStatus.cancelled.rawValue
            let queuedOp1 = PendingOperation(type: .markRead, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
            let queuedOp2 = PendingOperation(type: .markFlagged, messageIds: [secondMessageId], accountId: accountId, folderPath: "INBOX")
            // Insertion order matters: cancelled row FIRST (lowest rowid), so it
            // is the FIFO head that must be skipped without blocking either
            // queued row behind it.
            try insertOp(cancelledOp, pool: pool)
            try insertOp(queuedOp1, pool: pool)
            try insertOp(queuedOp2, pool: pool)

            await AccountManager.shared.drainPendingQueue()

            #expect(try fetchOp(cancelledOp.id, pool: pool) == nil, "the cancelled row is physically deleted")
            #expect(try fetchOp(queuedOp1.id, pool: pool) == nil)
            #expect(try fetchOp(queuedOp2.id, pool: pool) == nil)
            let readCalls = await provider.markedReadIds
            #expect(readCalls.count == 1)
            #expect(readCalls.first?.ids == [firstMessageId])
            let flagCalls = await provider.markedFlaggedIds
            #expect(flagCalls.count == 1)
            #expect(flagCalls.first?.ids == [secondMessageId], "both queued rows executed IN ORDER behind the skipped cancelled row")

            try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        }
    }

    // MARK: - 5. No lost re-drain wakeup

    @Test("a second op enqueued mid-drain (during a provider call) is picked up by the SAME running owner — no lost re-drain wakeup")
    func opEnqueuedMidDrainIsPickedUpBySameOwner() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-mid-drain-enqueue-\(suffix)"
        let firstMessageId = "mid-drain-first-\(suffix)@example.com"
        let secondMessageId = "mid-drain-second-\(suffix)@example.com"

        let provider = MockEmailProvider()
        let providerGate = LivenessTestGate()
        await provider.setMarkReadHook {
            await providerGate.arriveAndWaitForRelease()
        }

        let op1 = PendingOperation(type: .markRead, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op1, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            let drain = Task { await AccountManager.shared.drainPendingQueue() }
            do {
                try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                    await providerGate.waitUntilArrival()
                }

                // Enqueue op2 while op1's provider call is still in flight —
                // NOT via a second `drainPendingQueue()` call. If the drain
                // loop only queried the table once per pass instead of
                // re-claiming fresh from the table on every iteration, op2
                // would be silently left behind until some other external
                // trigger called `drainPendingQueue()` again.
                let op2 = PendingOperation(type: .markFlagged, messageIds: [secondMessageId], accountId: accountId, folderPath: "INBOX")
                try insertOp(op2, pool: pool)

                await providerGate.releaseAll()
                try await joinDrainTask(drain)

                #expect(try fetchOp(op1.id, pool: pool) == nil)
                #expect(
                    try fetchOp(op2.id, pool: pool) == nil,
                    "op2 enqueued mid-drain must be picked up by the SAME running owner with no additional external drain trigger"
                )
                let readCalls = await provider.markedReadIds
                #expect(readCalls.contains { $0.ids == [firstMessageId] })
                let flagCalls = await provider.markedFlaggedIds
                #expect(flagCalls.contains { $0.ids == [secondMessageId] })

                try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
            } catch {
                await providerGate.releaseAll()
                drain.cancel()
                try? await joinDrainTask(drain)
                throw error
            }
        }
    }

    // MARK: - 6. A permanently-failing frontier does not spin

    @Test("a permanently-failing frontier does not spin within one drain, and the queue stays live (gate free, no owner leaked) while blocked")
    func permanentlyFailingFrontierDoesNotSpinAndStaysLiveWhileBlocked() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-permanent-fail-\(suffix)"
        let frontierMessageId = "permanent-fail-frontier-\(suffix)@example.com"
        let behindMessageId = "permanent-fail-behind-\(suffix)@example.com"

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.notConnected)

        let frontier = PendingOperation(type: .markRead, messageIds: [frontierMessageId], accountId: accountId, folderPath: "INBOX")
        let behind = PendingOperation(type: .markFlagged, messageIds: [behindMessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(frontier, pool: pool)
        try insertOp(behind, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()

            // Bounded: exactly one attempt reached the provider this drain —
            // the frontier is retried on the NEXT drain call, never in a
            // tight loop within this one.
            #expect(await provider.markedReadIds.count == 1, "the drain must not spin on the same failing frontier within one call")

            let afterFirstDrain = try fetchOp(frontier.id, pool: pool)
            #expect(afterFirstDrain?.status == PendingStatus.queued.rawValue)
            #expect(afterFirstDrain?.messageIds == [frontierMessageId], "payload unchanged")
            #expect(afterFirstDrain?.retryCount == 1)
            let behindAfterFirstDrain = try fetchOp(behind.id, pool: pool)
            #expect(behindAfterFirstDrain?.status == PendingStatus.queued.rawValue, "never claimed while the frontier blocks")
            #expect(await provider.markedFlaggedIds.isEmpty, "the row behind an unresolved frontier must never reach its provider")

            // Definitive no-wedge check WHILE the frontier is still blocked:
            // a blocked queue must still be a LIVE queue. The dynamic canary
            // probe cannot be used here — by FIFO design the canary would
            // itself queue behind the still-unresolved frontier — so only the
            // static invariants apply at this checkpoint.
            try await assertQueueLivenessInvariants(pool: pool)

            // Clear the failure — a fresh drain completes both rows in order.
            await provider.setMarkReadThrows(nil)
            await AccountManager.shared.drainPendingQueue()

            #expect(try fetchOp(frontier.id, pool: pool) == nil)
            #expect(try fetchOp(behind.id, pool: pool) == nil)
            #expect(await provider.markedReadIds.count == 2, "one failed attempt + one successful retry")
            #expect(await provider.markedFlaggedIds.count == 1)

            try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        }
    }

    // MARK: - 7. Repeated drains after a blocked frontier stay safe

    @Test("repeated drains against a permanently-failing frontier stay safe — no permit leak, no owner leak, no duplicate claims, no stranded row")
    func repeatedDrainsAgainstPermanentlyFailingFrontierStaySafe() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-repeated-permanent-fail-\(suffix)"
        let messageId = "repeated-permanent-fail-\(suffix)@example.com"

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.notConnected)

        let op = PendingOperation(type: .markRead, messageIds: [messageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        let repeatCount = 5
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            for attempt in 1...repeatCount {
                await AccountManager.shared.drainPendingQueue()
                try await assertQueueLivenessInvariants(pool: pool)
                let afterAttempt = try fetchOp(op.id, pool: pool)
                #expect(afterAttempt != nil, "attempt \(attempt): the op must not be dropped")
                #expect(afterAttempt?.status == PendingStatus.queued.rawValue, "attempt \(attempt): no duplicate/dangling claim")
                #expect(afterAttempt?.retryCount == attempt, "attempt \(attempt): exactly one provider attempt per drain call — no duplicate claims")
            }

            // Exactly `repeatCount` attempts reached the provider — one per
            // drain call, no duplicates, no skips.
            #expect(await provider.markedReadIds.count == repeatCount)

            await provider.setMarkReadThrows(nil)
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(op.id, pool: pool) == nil)
            #expect(await provider.markedReadIds.count == repeatCount + 1)

            try await assertQueueNotWedged(pool: pool, accountId: accountId, provider: provider)
        }
    }
}
