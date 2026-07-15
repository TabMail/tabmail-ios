/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

private actor QueuePreparationTestGate {
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

@Suite("Pending-operation mutation gate")
struct PendingOperationMutationGateTests {
    private func withPermit<T: Sendable>(
        on gate: PendingOperationMutationGate,
        _ mutation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await gate.acquire()
        defer { gate.release(lease) }
        try Task.checkCancellation()
        return try await mutation()
    }

    private func waitForWaiters(
        _ expectedCount: Int,
        on gate: PendingOperationMutationGate
    ) async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            while gate.waiterCountForTesting != expectedCount {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func join<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            try await task.value
        }
    }

    @Test("permit is FIFO and admits only one mutation at a time")
    func permitIsFIFOAndSerial() async throws {
        let gate = PendingOperationMutationGate()
        let holder = QueuePreparationTestGate()
        let firstMutation = QueuePreparationTestGate()
        let order = Mutex<[Int]>([])

        let holderTask = Task { @Sendable in
            try await withPermit(on: gate) {
                await holder.arriveAndWaitForRelease()
            }
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await holder.waitUntilArrival()
        }

        let firstTask = Task { @Sendable in
            try await withPermit(on: gate) {
                order.withLock { $0.append(1) }
                await firstMutation.arriveAndWaitForRelease()
            }
        }
        try await waitForWaiters(1, on: gate)

        let secondTask = Task { @Sendable in
            try await withPermit(on: gate) {
                order.withLock { $0.append(2) }
            }
        }
        try await waitForWaiters(2, on: gate)

        await holder.releaseAll()
        _ = try await join(holderTask)
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await firstMutation.waitUntilArrival()
        }
        #expect(order.withLock { $0 } == [1])
        #expect(gate.waiterCountForTesting == 1)

        await firstMutation.releaseAll()
        _ = try await join(firstTask)
        _ = try await join(secondTask)
        #expect(order.withLock { $0 } == [1, 2])
        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
    }

    @Test("cancelling a queued waiter removes it and does not strand the permit")
    func queuedCancellationDoesNotStrandPermit() async throws {
        let gate = PendingOperationMutationGate()
        let holder = QueuePreparationTestGate()
        let survivorRan = Mutex(false)

        let holderTask = Task { @Sendable in
            try await withPermit(on: gate) {
                await holder.arriveAndWaitForRelease()
            }
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await holder.waitUntilArrival()
        }

        let cancelledTask = Task { @Sendable in
            try await withPermit(on: gate) {
                Issue.record("cancelled waiter entered the mutation")
            }
        }
        try await waitForWaiters(1, on: gate)

        let survivorTask = Task { @Sendable in
            try await withPermit(on: gate) {
                survivorRan.withLock { $0 = true }
            }
        }
        try await waitForWaiters(2, on: gate)

        cancelledTask.cancel()
        do {
            _ = try await join(cancelledTask)
            Issue.record("cancelled waiter unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForWaiters(1, on: gate)

        await holder.releaseAll()
        _ = try await join(holderTask)
        _ = try await join(survivorTask)
        #expect(survivorRan.withLock { $0 })

        try await withPermit(on: gate) {}
        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
    }

    @Test("a pre-cancelled acquisition never takes the permit")
    func preCancelledAcquisitionDoesNotTakePermit() async throws {
        let gate = PendingOperationMutationGate()
        let start = QueuePreparationTestGate()

        let task = Task { @Sendable in
            await start.arriveAndWaitForRelease()
            let lease = try await gate.acquire()
            defer { gate.release(lease) }
            Issue.record("pre-cancelled acquisition unexpectedly succeeded")
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await start.waitUntilArrival()
        }

        task.cancel()
        await start.releaseAll()
        do {
            _ = try await join(task)
            Issue.record("pre-cancelled acquisition unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
        try await withPermit(on: gate) {}
    }

    @Test("cancellation racing with permit handoff leaves the gate reusable")
    func handoffCancellationLeavesGateReusable() async throws {
        let gate = PendingOperationMutationGate()
        let survivorRan = Mutex(false)
        let lease = try await gate.acquire()

        let waiterTask = Task { @Sendable in
            try await withPermit(on: gate) {
                Issue.record("cancelled handoff owner entered the mutation")
            }
        }
        try await waitForWaiters(1, on: gate)

        let survivorTask = Task { @Sendable in
            try await withPermit(on: gate) {
                survivorRan.withLock { $0 = true }
            }
        }
        try await waitForWaiters(2, on: gate)

        // Ownership has moved to waiterTask, but its continuation has not yet
        // resumed when the hook cancels it. The gate must synchronously hand the
        // permit onward to survivorTask and never enter waiterTask's body.
        #expect(gate.releaseForTesting(lease) {
            waiterTask.cancel()
        })
        do {
            _ = try await join(waiterTask)
            Issue.record("cancelled handoff owner unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await join(survivorTask)
        #expect(survivorRan.withLock { $0 })

        try await withPermit(on: gate) {}
        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
    }

    @Test("cancelling the last waiter after handoff frees the gate")
    func lastWaiterHandoffCancellationFreesGate() async throws {
        let gate = PendingOperationMutationGate()
        let lease = try await gate.acquire()

        let waiterTask = Task { @Sendable in
            try await withPermit(on: gate) {
                Issue.record("cancelled last handoff owner entered the mutation")
            }
        }
        try await waitForWaiters(1, on: gate)

        #expect(gate.releaseForTesting(lease) {
            waiterTask.cancel()
        })
        do {
            _ = try await join(waiterTask)
            Issue.record("cancelled last handoff owner unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
        try await withPermit(on: gate) {}
    }

    @Test("a stale lease cannot release its successor")
    func staleLeaseCannotReleaseSuccessor() async throws {
        let gate = PendingOperationMutationGate()
        let firstLease = try await gate.acquire()
        let successorEntered = QueuePreparationTestGate()
        let followerRan = Mutex(false)

        let successorTask = Task { @Sendable in
            try await withPermit(on: gate) {
                await successorEntered.arriveAndWaitForRelease()
            }
        }
        try await waitForWaiters(1, on: gate)
        #expect(gate.release(firstLease))
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await successorEntered.waitUntilArrival()
        }

        #expect(!gate.release(firstLease))
        let followerTask = Task { @Sendable in
            try await withPermit(on: gate) {
                followerRan.withLock { $0 = true }
            }
        }
        try await waitForWaiters(1, on: gate)
        #expect(!followerRan.withLock { $0 })

        await successorEntered.releaseAll()
        _ = try await join(successorTask)
        _ = try await join(followerTask)
        #expect(followerRan.withLock { $0 })
        #expect(!gate.isHeldForTesting)
    }

    @Test("cancellation after entry releases the permit through defer")
    func cancellationAfterEntryReleasesPermit() async throws {
        let gate = PendingOperationMutationGate()
        let entered = QueuePreparationTestGate()
        let survivorRan = Mutex(false)

        let ownerTask = Task { @Sendable in
            try await withPermit(on: gate) {
                await entered.arriveAndWaitForRelease()
                try Task.checkCancellation()
            }
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await entered.waitUntilArrival()
        }

        let survivorTask = Task { @Sendable in
            try await withPermit(on: gate) {
                survivorRan.withLock { $0 = true }
            }
        }
        try await waitForWaiters(1, on: gate)

        ownerTask.cancel()
        await entered.releaseAll()
        do {
            _ = try await join(ownerTask)
            Issue.record("cancelled permit owner unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await join(survivorTask)

        #expect(survivorRan.withLock { $0 })
        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
    }

    @Test("throwing mutation releases the permit")
    func throwingMutationReleasesPermit() async throws {
        struct ExpectedFailure: Error {}

        let gate = PendingOperationMutationGate()
        do {
            try await withPermit(on: gate) {
                throw ExpectedFailure()
            }
            Issue.record("throwing mutation unexpectedly completed")
        } catch is ExpectedFailure {
            // Expected.
        }

        try await withPermit(on: gate) {}
        #expect(gate.waiterCountForTesting == 0)
        #expect(!gate.isHeldForTesting)
    }

    /// Deadlock-audit item 8: many independent tasks race `acquire()`→
    /// release() on a SHARED gate, roughly half pre-cancelled before they
    /// even start racing (and thus cancelled at every possible point along
    /// `acquire()`'s await chain across the whole run, since scheduling
    /// order is nondeterministic), asserting via a plain `Mutex`-protected
    /// counter that AT MOST ONE task is ever "inside" (between a successful
    /// `acquire()` and its matching `release()`) at any instant. Protects
    /// `withTaskCancellationHandler`'s unregistration semantics
    /// (`cancelAcquisition`'s queued-waiter-removal vs. "already became
    /// owner, forward the handoff" race — see that function's doc comment)
    /// against refactors: a regression here is exactly two owners observed
    /// simultaneously inside the gate, or a stranded waiter/owner afterward.
    /// Flat, TOP-LEVEL `Task` handles only (mirrors `permitIsFIFOAndSerial`
    /// elsewhere in this file) — nesting a nested `TaskGroup`/`Task` inside
    /// an outer `group.addTask` closure trips Swift 6's `sending`-parameter
    /// checker on the shared `Mutex`-protected captures even though `Mutex`
    /// itself is safe for this exact pattern. Bounded time (no sleeps;
    /// `Task.yield` only), wrapped in `withTimeout` so a real deadlock fails
    /// fast instead of hanging CI.
    @Test("many tasks stress the gate with random cancellation: at most one owner is ever inside, no leaks, bounded time")
    func gateStressWithRandomCancellationNeverAdmitsTwoOwners() async throws {
        let gate = PendingOperationMutationGate()
        let insideCount = Mutex<Int>(0)
        let maxObservedInside = Mutex<Int>(0)
        let violationDetected = Mutex<Bool>(false)
        let totalAttempts = 500

        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            var attempts: [Task<Void, Never>] = []
            attempts.reserveCapacity(totalAttempts)
            for _ in 0..<totalAttempts {
                let attempt = Task<Void, Never> { @Sendable in
                    do {
                        let lease = try await gate.acquire()
                        let current = insideCount.withLock { count -> Int in
                            count += 1
                            return count
                        }
                        maxObservedInside.withLock { $0 = max($0, current) }
                        if current > 1 {
                            violationDetected.withLock { $0 = true }
                        }
                        // No sleeps — yield gives every other task a
                        // scheduling chance to race for the gate while this
                        // one is "inside".
                        await Task.yield()
                        insideCount.withLock { $0 -= 1 }
                        gate.release(lease)
                    } catch is CancellationError {
                        // Expected under random cancellation.
                    } catch {
                        Issue.record("unexpected error from gate.acquire(): \(error)")
                    }
                }
                if Bool.random() {
                    attempt.cancel()
                }
                attempts.append(attempt)
            }
            for attempt in attempts {
                await attempt.value
            }
        }

        #expect(!violationDetected.withLock { $0 }, "at most one task may ever be inside the gate at a time")
        #expect(maxObservedInside.withLock { $0 } <= 1)
        #expect(insideCount.withLock { $0 } == 0, "no leaked in-flight owner")
        #expect(!gate.isHeldForTesting, "the gate must end unheld")
        #expect(gate.waiterCountForTesting == 0, "no waiter may be stranded")
    }
}

/// Real-`executeSingleOp` tests for durable completion and generic retry outcomes.
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
@Suite(
    "AccountManagerQueue drain outcomes",
    .serialized,
    .processGlobalState
)
struct AccountManagerQueueDrainTests {

    private func waitForPreparationParticipants(_ expectedCount: Int) async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            while await AccountManager.shared
                .pendingQueuePreparationParticipantCountForTesting() < expectedCount {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func joinDrainTask(_ task: Task<Void, Never>) async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await task.value
        }
    }

    // MARK: - Harness (mirrors InboxGestureActionTests.makeTestDB/restoreTestDB)

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
    /// If there was no previous AppDatabase, leave this one installed as before;
    /// `AppDatabase.rawPool` force-unwraps the singleton on unrelated later access.
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

    private func insertAccount(
        id: String,
        provider: AccountProvider,
        pool: DatabasePool
    ) async throws {
        try await pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "queue-test-\(UUID().uuidString)@example.com",
                displayName: "Queue Test",
                provider: provider
            )
            account.id = id
            try account.insert(db)
        }
    }

    private func makeQueueDraft(
        id: String,
        accountId: String,
        subject: String,
        body: String,
        serverDraftId: String
    ) -> Draft {
        let now = Date().timeIntervalSince1970
        return Draft(
            id: id,
            accountId: accountId,
            toJSON: Draft.encodeStringArray(["recipient@example.com"]),
            ccJSON: "[]",
            bccJSON: "[]",
            subject: subject,
            body: body,
            replyToId: nil,
            isForward: false,
            editHistoryJSON: nil,
            createdAt: now,
            updatedAt: now,
            serverDraftId: serverDraftId,
            serverPushStatus: nil,
            rfc822MessageId: "\(id)@example.com",
            attachmentsDirName: nil
        )
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

    /// An admissible, unread, durable header — valid RFC identity + non-blank
    /// account/folder scope so `markRead`'s admission (`durableActionAddress`)
    /// accepts it, mirroring `InboxGestureActionTests.makeDurableHeader`.
    private func makeGateTestHeader(accountId: String, messageId: String, folderPath: String = "INBOX") -> MessageHeader {
        let folderId = "\(accountId):\(folderPath)"
        var header = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        header.headerComplete = true
        header.isRead = false
        header.rfc822MessageId = "<\(accountId)-\(messageId)@example.com>"
        return header
    }

    private func insertHeader(_ header: MessageHeader, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    private func fetchHeader(_ id: String, pool: DatabasePool) throws -> MessageHeader? {
        try pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    private func fetchOpsForAccount(_ accountId: String, pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }
    }

    // MARK: - Durable admission / gate linearizability (§9.3, round C2)

    @Test("durable admission commits its local mutation and its queue row under one gate")
    func durableAdmissionCommitsLocalMutationAndQueueRowUnderOneGate() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gate-linearizable-\(suffix)"
        let messageId = "gate-linearizable-\(suffix)"
        // messageHeader.accountId carries a CASCADE FK to account(id).
        try await insertAccount(id: accountId, provider: .imap, pool: pool)
        let header = makeGateTestHeader(accountId: accountId, messageId: messageId)
        try insertHeader(header, pool: pool)

        // No provider registered for this account: if markRead's fire-and-forget
        // drain races ahead after the gate releases, its claim step finds no
        // work queue and requeues the row instead of executing/deleting it — so
        // the row's mere existence stays deterministic regardless of drain timing.
        let gate = AccountManager.shared.pendingOperationMutationGate
        let lease = try await gate.acquire()

        let markReadTask = Task { @Sendable in
            await AccountManager.shared.markRead([header])
        }

        do {
            // Deterministically wait until markRead's admission write is
            // blocked trying to acquire the gate we're holding — no fixed
            // sleep, and bounded so a regression can't hang the suite.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                while gate.waiterCountForTesting < 1 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }

            // Linearizability point (§9.3): while the lease is still held,
            // NEITHER the local optimistic mutation NOR the durable queue
            // row has committed — they are one gated transaction, not two
            // independently-visible writes.
            let blockedHeader = try fetchHeader(header.id, pool: pool)
            #expect(blockedHeader?.isRead == false, "the optimistic mutation must not commit while admission is blocked on the gate")
            let blockedOps = try fetchOpsForAccount(accountId, pool: pool)
            #expect(blockedOps.isEmpty, "the durable queue row must not commit while admission is blocked on the gate")
        } catch {
            gate.release(lease)
            markReadTask.cancel()
            throw error
        }

        gate.release(lease)
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await markReadTask.value
        }

        // Once unblocked, both sides landed together.
        let finalHeader = try fetchHeader(header.id, pool: pool)
        #expect(finalHeader?.isRead == true)
        let finalOps = try fetchOpsForAccount(accountId, pool: pool)
        #expect(finalOps.count == 1)
        guard finalOps.count == 1 else { return }
        #expect(finalOps[0].type == .markRead)
    }

    /// Fix 4: `removeAccount`'s `PendingOperation` purge was a bare
    /// `dbPool.write`, the one mutator of the `pendingOperation` table that
    /// did not coordinate through `pendingOperationMutationGate` (§9.3's
    /// "all fifteen production append sites" list never covered this DELETE
    /// path). Mirrors `durableAdmissionCommitsLocalMutationAndQueueRowUnderOneGate`'s
    /// pattern: hold the gate lease directly, prove the purge is BLOCKED
    /// while another writer holds it, then release and prove it completes.
    @Test("removeAccount purges PendingOperation rows under the same gate as every other mutator — a held lease blocks the purge until released")
    func removeAccountRoutesPendingOperationPurgeThroughTheGate() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-removeaccount-gate-\(suffix)"
        // .caldav short-circuits PushNotificationService's unsubscribe/revoke
        // calls (no network I/O) — this test isolates the PendingOperation
        // gate race, not push/provider plumbing.
        try await insertAccount(id: accountId, provider: .caldav, pool: pool)
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["removeaccount-gate-\(suffix)@example.com"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try insertOp(op, pool: pool)

        var account = Account(
            emailAddress: "removeaccount-gate-\(suffix)@example.com",
            displayName: "Gate Test",
            provider: .caldav
        )
        account.id = accountId
        let accountToRemove = account

        let gate = AccountManager.shared.pendingOperationMutationGate
        let lease = try await gate.acquire()

        let removeTask = Task { @Sendable in
            await AccountManager.shared.removeAccount(accountToRemove)
        }

        do {
            // Deterministically wait until removeAccount's purge is blocked
            // trying to acquire the gate we're holding — no fixed sleep,
            // bounded so a regression (the bare, ungated write) can't hang
            // the suite: it fails this wait instead.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                while gate.waiterCountForTesting < 1 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }

            // Linearizability point (Fix 4): while the lease is held by
            // another writer, removeAccount's purge must not have committed.
            let blockedOps = try fetchOpsForAccount(accountId, pool: pool)
            #expect(blockedOps.count == 1, "removeAccount's purge must not commit while another writer holds the gate")
        } catch {
            gate.release(lease)
            removeTask.cancel()
            throw error
        }

        gate.release(lease)
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await removeTask.value
        }

        let finalOps = try fetchOpsForAccount(accountId, pool: pool)
        #expect(finalOps.isEmpty, "the purge completes once the gate is free — no stranded row")
        let finalAccount = try await pool.read { db in try Account.fetchOne(db, key: accountId) }
        #expect(finalAccount == nil)
        #expect(!gate.isHeldForTesting, "the gate must not be leaked by removeAccount")

        // The queue is not wedged: a canary op on a different, still-
        // registered account still drains to completion.
        let canaryAccountId = "acc-removeaccount-canary-\(suffix)"
        let canaryMessageId = "removeaccount-canary-\(suffix)@example.com"
        try await insertAccount(id: canaryAccountId, provider: .gmail, pool: pool)
        let canaryProvider = MockEmailProvider()
        try await withRegisteredProvider(accountId: canaryAccountId, provider: canaryProvider) {
            let canaryOp = PendingOperation(
                type: .markRead,
                messageIds: [canaryMessageId],
                accountId: canaryAccountId,
                folderPath: "INBOX"
            )
            try insertOp(canaryOp, pool: pool)
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(canaryOp.id, pool: pool) == nil, "a scenario-unrelated canary op must still drain — the queue must not be wedged")
            let sawCanary = await canaryProvider.markedReadIds.contains { $0.ids == [canaryMessageId] }
            #expect(sawCanary, "the canary must have actually reached its provider")
        }
        #expect(!gate.isHeldForTesting, "the gate is free after the canary drains")
    }

    @Test(".setTag completes immediately: op deleted and provider never called")
    func setTagCompletesImmediatelyBestEffort() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // Legacy action-tag rows flush through the local-only success path and
        // never call a provider (ADR-IOS-036 / ADR-IOS-060).
        let provider = MockEmailProvider()
        let op = PendingOperation(type: .setTag, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX", tagValue: "archive")
        try insertOp(op, pool: pool)

        _ = await AccountManager.shared.executeSingleOp(op, provider: provider, context: AccountManager.DrainContext())
        let after = try fetchOp(op.id, pool: pool)
        #expect(after == nil)
        let callLog = await provider.callLog
        #expect(callLog.isEmpty)
    }

    @Test("claimed RFC move dispatches one whole provider batch and deletes the durable row")
    func claimedMoveDispatchesWholeBatchAndDeletesRow() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let messageIds = [
            "first-\(suffix)@example.com",
            "second-\(suffix)@example.com",
        ]
        var operation = PendingOperation(
            type: .move,
            messageIds: messageIds,
            accountId: "acc-move-dispatch-\(suffix)",
            folderPath: "Source-\(suffix)",
            destinationPath: "Destination-\(suffix)"
        )
        operation.status = PendingStatus.inFlight.rawValue
        let claimed = operation
        try insertOp(claimed, pool: pool)

        let provider = MockEmailProvider()
        _ = await AccountManager.shared.executeSingleOp(
            claimed,
            provider: provider,
            context: AccountManager.DrainContext()
        )

        #expect(try fetchOp(claimed.id, pool: pool) == nil)
        let moves = await provider.movedIds
        #expect(moves.count == 1)
        guard moves.count == 1 else { return }
        #expect(moves[0].ids == messageIds)
        #expect(moves[0].from == claimed.folderPath)
        #expect(moves[0].to == claimed.destinationPath)
    }

    // MARK: - Launch-time crash recovery

    @Test("reconcilePendingOperations resets in-flight work to queued and leaves queued work untouched")
    func reconcilePendingOperationsResetsInFlightLeavesQueued() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // No provider is registered, so the triggered drain safely leaves both
        // rows queued. This isolates launch recovery's in-flight reset.
        let suffix = UUID().uuidString.lowercased()
        var inFlightOp = PendingOperation(
            type: .markRead,
            messageIds: ["inflight-\(suffix)@example.com"],
            accountId: "acc-gap1",
            folderPath: "INBOX"
        )
        inFlightOp.status = PendingStatus.inFlight.rawValue
        let queuedOp = PendingOperation(
            type: .markFlagged,
            messageIds: ["queued-\(suffix)@example.com"],
            accountId: "acc-gap1",
            folderPath: "INBOX"
        )
        try insertOp(inFlightOp, pool: pool)
        try insertOp(queuedOp, pool: pool)

        await AccountManager.shared.reconcilePendingOperations()

        let remaining = try await pool.read { db in
            try PendingOperation
                .filter(Column("accountId") == "acc-gap1")
                .fetchAll(db)
        }
        #expect(remaining.count == 2)

        let inFlightAfter = try fetchOp(inFlightOp.id, pool: pool)
        #expect(inFlightAfter?.status == PendingStatus.queued.rawValue)
        #expect(inFlightAfter?.retryCount == 0)

        let queuedAfter = try fetchOp(queuedOp.id, pool: pool)
        #expect(queuedAfter?.status == PendingStatus.queued.rawValue)
        #expect(queuedAfter?.retryCount == 0)
    }

    // MARK: - Transient partial-batch retry

    @Test("Batch move [A,B,C] fails on B via a generic connection error: the whole op stays queued, retryCount increments, and a cleared retry completes it")
    func batchMoveGenericFailureRequeuesWholeOpThenRetrySucceeds() async throws {
        let (pool, dir, previous) = try await makeTestDB()
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
        // Generic connection error — not an authoritative stale response —
        // the same ProviderError.notConnected ConnectionResilienceTests uses
        // for the "ordinary connection blip" scenario (falls through to
        // executeSingleOp's bottom generic catch).
        await provider.setMoveThrowsOnId("B", error: ProviderError.notConnected)

        let op = PendingOperation(type: .move, messageIds: ["A", "B", "C"], accountId: "acc-gap2", folderPath: "INBOX", destinationPath: "Archive")
        try insertOp(op, pool: pool)

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(op, provider: provider, context: context)
        #expect(outcome == .stopDrain, "a generic transient error must stop the drain rather than let a later row overtake it")

        let after = try fetchOp(op.id, pool: pool)
        #expect(after != nil, "a generic transient error keeps the whole operation retryable")
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

        _ = await AccountManager.shared.executeSingleOp(reclaimed, provider: provider, context: AccountManager.DrainContext())

        let final = try fetchOp(op.id, pool: pool)
        #expect(final == nil, "op deleted — completed on retry")

        let movedAfterRetry = await provider.movedIds
        #expect(movedAfterRetry.count == 2)
        #expect(movedAfterRetry.last?.ids == ["A", "B", "C"], "retry succeeds for the full batch")
    }

    /// Positive-outcome pin for the `.move` local-destination self-heal
    /// (`destMissing`, `AccountManagerQueue.executeSingleOp`'s transient
    /// catch): the check reads the LOCAL `Folder` table — not provider
    /// interpretation — so it fires regardless of what error (if any) the
    /// provider throws. Round E kept this self-heal deliberately in the
    /// generic queue (it is local command validity, not provider-error
    /// classification) while deleting `isMessageNotFoundError`/
    /// `isConfirmedGoneError`/`isPermanentlyInvalidError`. The sibling
    /// negative test above (`batchMoveGenericFailureRequeuesWholeOpThenRetrySucceeds`)
    /// carefully AVOIDS this branch by pre-inserting the destination Folder;
    /// this test is the missing positive counterpart — plus proves the
    /// dropped op does not wedge a later op behind it.
    @Test("Move op whose destination Folder row is missing locally is dropped by the self-heal, and a later op still proceeds")
    func moveWithMissingLocalDestinationFolderSelfHealsAndLaterOpProceeds() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        let accountId = "acc-selfheal-\(UUID().uuidString.lowercased())"

        // Deliberately do NOT insert an "Obsolete" Folder row — this is the
        // "account's folder list was re-ingested" scenario the self-heal
        // exists for (e.g. IMAP→OAuth migration renaming a folder path),
        // leaving the queued op pointing at a path no local Folder owns.
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
        }

        let provider = MockEmailProvider()
        // RFC822-shaped ids kept for realism (hybrid identity would admit a
        // bare token just the same — the deleted legacy conversion pass no
        // longer exists to care about member shape).
        let staleMessageId = "self-heal-\(UUID().uuidString.lowercased())@example.com"
        let laterMessageId = "self-heal-later-\(UUID().uuidString.lowercased())@example.com"
        // The provider would happily attempt the move if asked — the
        // self-heal must fire from the LOCAL Folder-table check, never from
        // provider-error interpretation (Law 5). Any thrown error reaches
        // the same generic transient catch; a connection error is the
        // simplest realistic shape.
        await provider.setMoveThrowsOnId(staleMessageId, error: ProviderError.notConnected)

        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var staleOp = PendingOperation(
            type: .move, messageIds: [staleMessageId], accountId: accountId,
            folderPath: "INBOX", destinationPath: "Obsolete"
        )
        staleOp.createdAt = t0
        var laterOp = PendingOperation(
            type: .markRead, messageIds: [laterMessageId], accountId: accountId, folderPath: "INBOX"
        )
        laterOp.createdAt = t0.addingTimeInterval(1)
        try insertOp(staleOp, pool: pool)
        try insertOp(laterOp, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        let staleAfter = try fetchOp(staleOp.id, pool: pool)
        #expect(staleAfter == nil, "self-heal drops the op whose destination Folder is missing locally")

        let laterAfter = try fetchOp(laterOp.id, pool: pool)
        #expect(laterAfter == nil, "a later op is not wedged behind the dropped stale op — it still proceeds and completes")

        let callLog = await provider.callLog
        #expect(callLog.contains { $0.hasPrefix("move(") }, "the provider was attempted once — self-heal fires from the catch block, not a pre-flight skip")

        let reads = await provider.markedReadIds
        #expect(reads.count == 1)
        #expect(reads.first?.ids == [laterMessageId])
    }

    // MARK: - End-to-end drain behavior

    @Test("drainPendingQueue executes three queued operations exactly once")
    func drainPendingQueueRealEndToEndExecutesAllOperations() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        let accountId = "acc-gap3-drain"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        let suffix = UUID().uuidString.lowercased()
        let firstMessageId = "first-\(suffix)@example.com"
        let secondMessageId = "second-\(suffix)@example.com"

        // Dynamic dates keep insertion order deterministic without pinning
        // scheduler construction details.
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var opA = PendingOperation(type: .markRead, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
        opA.createdAt = t0
        var opB = PendingOperation(type: .markFlagged, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
        opB.createdAt = t0.addingTimeInterval(1)
        var opC = PendingOperation(type: .markRead, messageIds: [secondMessageId], accountId: accountId, folderPath: "INBOX")
        opC.createdAt = t0
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)
        try insertOp(opC, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }
        #expect(remaining.isEmpty, "all ops executed (deleted)")

        let readCalls = await provider.markedReadIds
        #expect(readCalls.contains { $0.ids == [firstMessageId] })
        #expect(readCalls.contains { $0.ids == [secondMessageId] })
        let flaggedCalls = await provider.markedFlaggedIds
        #expect(flaggedCalls.contains { $0.ids == [firstMessageId] })
    }

    @Test("drainPendingQueue() (real): two concurrent calls are safe — the isDraining/needsRedrain guard serializes them, the op executes exactly once (no duplication, no crash)")
    func drainPendingQueueRealConcurrentCallsExecuteOpsExactlyOnce() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        let accountId = "acc-gap3-reentrant"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        let providerGate = QueuePreparationTestGate()
        await provider.setMarkReadHook {
            await providerGate.arriveAndWaitForRelease()
        }

        let messageId = "reentrant-\(UUID().uuidString.lowercased())@example.com"
        let op = PendingOperation(type: .markRead, messageIds: [messageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            let first = Task { await AccountManager.shared.drainPendingQueue() }
            do {
                try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                    await providerGate.waitUntilArrival()
                }
                let second = Task { await AccountManager.shared.drainPendingQueue() }
                try await joinDrainTask(second)
                await providerGate.releaseAll()
                try await joinDrainTask(first)
            } catch {
                await providerGate.releaseAll()
                first.cancel()
                try? await joinDrainTask(first)
                throw error
            }
        }

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }
        #expect(remaining.isEmpty, "the op executed (deleted)")

        let readCalls = await provider.markedReadIds
        #expect(readCalls.count == 1, "the op must execute EXACTLY ONCE despite two concurrent drain calls")
        #expect(
            await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
            "awaiting the owner must also join its requested re-drain"
        )
    }

    @Test("destructive completion publishes exact source removal and destination addition keys")
    func destructiveCompletionPublishesDirectionalMemberships() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-membership-producer-\(suffix)"
        let messageId = "membership-message-\(suffix)"
        let sourcePath = "Source-\(suffix)"
        let destinationPath = "Destination-\(suffix)"
        let unrelatedPath = "External-\(suffix)"
        var operation = PendingOperation(
            type: .move,
            messageIds: [messageId],
            accountId: accountId,
            folderPath: sourcePath,
            destinationPath: destinationPath
        )
        operation.status = PendingStatus.inFlight.rawValue
        let persisted = operation
        try await pool.writeWithoutTransaction { db in
            try persisted.insert(db)
        }

        let provider = MockEmailProvider(messageFieldScope: .account)
        let outcome = await AccountManager.shared.executeSingleOp(
            persisted,
            provider: provider,
            context: AccountManager.DrainContext()
        )
        #expect(outcome == .proceed)

        let recent = await AccountManager.shared.recentlyCompleted
        let accountIdentityKey = MessageIdentity.recentlyCompletedAccountKey(
            accountId: accountId,
            messageId: messageId
        )
        let sourceKey = MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: sourcePath,
            messageId: messageId,
            membership: .removedSource
        )
        let destinationKey = MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: destinationPath,
            messageId: messageId,
            membership: .addedDestination
        )
        let unrelatedKey = MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: unrelatedPath,
            messageId: messageId,
            membership: .addedDestination
        )
        #expect(recent[accountIdentityKey] != nil)
        #expect(recent[sourceKey] != nil)
        #expect(recent[destinationKey] != nil)
        #expect(recent[unrelatedKey] == nil,
                "a move must not freeze unrelated label membership")
    }

    @Test("default-operation drain publishes claimed identity before deleting its row")
    func defaultCompletionPublishesClaimedIdentity() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-default-completion-\(suffix)"
        let messageId = "default-message-\(suffix)@example.com"
        let operation = PendingOperation(
            type: .markReplied,
            messageIds: [messageId],
            accountId: accountId,
            folderPath: "INBOX-\(suffix)"
        )
        try insertOp(operation, pool: pool)

        let provider = MockEmailProvider(messageFieldScope: .account)
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(operation.id, pool: pool) == nil)
        let recent = await AccountManager.shared.recentlyCompleted
        #expect(recent[MessageIdentity.recentlyCompletedAccountKey(
            accountId: accountId,
            messageId: messageId
        )] != nil,
        "the DB-to-recent handoff must exist even without a local header")
    }

    // MARK: - Preparation flight (crash recovery before any drain owner)

    /// Hybrid replacement for the deleted conversion-uncertainty test: a
    /// released bare provider-ID row stranded `inFlight` by a crash is reset
    /// to `queued` by the preparation flight and drains directly through the
    /// token path — no conversion step exists. Independent Outbox/calendar
    /// recovery behaves exactly as before.
    @Test("crash-stranded legacy provider-ID row recovers and drains via the token path; outbox/calendar recovery stay independent")
    func crashStrandedLegacyRowRecoversAndDrainsViaTokenPath() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-preparation-retry-\(suffix)"
        let providerMessageId = "provider-retry-\(suffix)"
        let followerMessageId = "follower-\(suffix)@example.com"
        let source = "Source-\(suffix)"
        let destination = "Destination-\(suffix)"
        try await insertAccount(id: accountId, provider: .gmail, pool: pool)

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.seedStatefulMessage(
            id: providerMessageId,
            folder: source,
            providerMessageId: providerMessageId
        )
        var operation = PendingOperation(
            type: .move,
            messageIds: [providerMessageId],
            accountId: accountId,
            folderPath: source,
            destinationPath: destination
        )
        let queueStart = Date()
        operation.createdAt = queueStart
        operation.status = PendingStatus.inFlight.rawValue
        var canonicalFollower = PendingOperation(
            type: .markFlagged,
            messageIds: [followerMessageId],
            accountId: accountId,
            folderPath: source
        )
        canonicalFollower.createdAt = queueStart.addingTimeInterval(1)
        var completedOutbox = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(
                to: ["recipient@example.com"],
                subject: "Queue preparation independence",
                body: "Completed before restart"
            )
        )
        completedOutbox.status = OutboxStatus.sending.rawValue
        completedOutbox.sentAt = Date()
        completedOutbox.appendedToSent = true
        var calendarOperation = PendingCalendarOperation(
            operationType: .create,
            accountId: accountId,
            arguments: ["title": .string("Queue preparation independence")]
        )
        calendarOperation.status = PendingStatus.inFlight.rawValue
        let persistedOperation = operation
        let persistedFollower = canonicalFollower
        let persistedOutbox = completedOutbox
        let persistedCalendarOperation = calendarOperation
        try await pool.writeWithoutTransaction { db in
            try persistedOperation.insert(db)
            try persistedFollower.insert(db)
            try persistedOutbox.insert(db)
            try persistedCalendarOperation.insert(db)
        }

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcilePendingOperations()
        }

        // No conversion, no startup blocking: the bare provider-ID member
        // reached the provider byte-exact as a token and both rows drained.
        #expect(try fetchOp(operation.id, pool: pool) == nil)
        #expect(try fetchOp(canonicalFollower.id, pool: pool) == nil)
        #expect(await provider.statefulFolder(messageId: providerMessageId) == destination)
        let moves = await provider.movedIds
        #expect(moves.count == 1)
        guard moves.count == 1 else { return }
        #expect(moves[0].ids == [providerMessageId])
        let flagCalls = await provider.markedFlaggedIds
        #expect(flagCalls.count == 1)
        guard flagCalls.count == 1 else { return }
        #expect(flagCalls[0].ids == [followerMessageId])
        // Independent recovery unchanged: the sent outbox row is finalized
        // (deleted) and the calendar op is reset to queued.
        let independentRecovery = try await pool.read { db in
            (
                try OutboxMessage.fetchOne(db, key: persistedOutbox.id),
                try PendingCalendarOperation.fetchOne(db, key: persistedCalendarOperation.id)
            )
        }
        #expect(independentRecovery.0 == nil)
        #expect(independentRecovery.1?.status == PendingStatus.queued.rawValue)
    }

    /// Preparation single-flight, hybrid edition: with the converter gone,
    /// preparation is crash recovery's gated write — block it by holding the
    /// shared mutation gate. Both drains join ONE flight; release lets exactly
    /// one owner execute the row once.
    @Test("concurrent drains share one blocked preparation flight and execute once")
    func concurrentDrainsShareOnePreparationFlightAndExecuteOnce() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-preparation-single-flight-\(suffix)"
        let rfcMessageId = "single-flight-\(suffix)@example.com"
        let source = "Source-\(suffix)"
        try await insertAccount(id: accountId, provider: .outlook, pool: pool)

        let provider = MockEmailProvider(messageFieldScope: .account)
        let operation = PendingOperation(
            type: .markRead,
            messageIds: [rfcMessageId],
            accountId: accountId,
            folderPath: source
        )
        try insertOp(operation, pool: pool)

        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider
        )

        let gate = AccountManager.shared.pendingOperationMutationGate
        let lease = try await gate.acquire()
        let first = Task { await AccountManager.shared.drainPendingQueue() }
        var second: Task<Void, Never>?
        var leaseReleased = false
        do {
            // Preparation's crash-recovery gated write is now blocked on the
            // lease we hold.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                while gate.waiterCountForTesting < 1 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            let joined = Task { await AccountManager.shared.drainPendingQueue() }
            second = joined
            try await waitForPreparationParticipants(2)

            #expect(await provider.markedReadIds.isEmpty)
            #expect(try fetchOp(operation.id, pool: pool)?.status == PendingStatus.queued.rawValue)
            #expect(await AccountManager.shared.isDraining == false)

            gate.release(lease)
            leaseReleased = true
            try await joinDrainTask(first)
            try await joinDrainTask(joined)

            #expect(await AccountManager.shared.needsRedrain == false)
            #expect(try fetchOp(operation.id, pool: pool) == nil)
            #expect(await provider.markedReadIds.count == 1, "one shared flight, one owner, one execution")
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        } catch {
            second?.cancel()
            first.cancel()
            if !leaseReleased { gate.release(lease) }
            try? await joinDrainTask(first)
            if let second {
                try? await joinDrainTask(second)
            }
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
    }

    /// PLAN_IDENTITY_HYBRID §7.6 — a released (≤1.6.38) bare provider-ID row
    /// is, by shape, a tail member: it executes directly through the token
    /// path with NO pre-drain conversion, no startup blocking, and its member
    /// string reaches the provider byte-exact. A younger RFC row behind it
    /// preserves FIFO order.
    @Test("a released bare provider-ID row executes directly through the token path with no conversion")
    func legacyProviderIdRowExecutesViaTokenPathWithoutConversion() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-token-legacy-\(suffix)"
        let providerMessageId = "provider-resource-\(suffix)"
        let followerRFCId = "follower-\(suffix)@example.com"
        let source = "Source-\(suffix)"
        let destination = "Destination-\(suffix)"
        try await insertAccount(id: accountId, provider: .outlook, pool: pool)

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.seedStatefulMessage(
            id: providerMessageId,
            folder: source,
            providerMessageId: providerMessageId
        )
        let legacyRow = PendingOperation(
            type: .move,
            messageIds: [providerMessageId],
            accountId: accountId,
            folderPath: source,
            destinationPath: destination
        )
        let followerRow = PendingOperation(
            type: .markRead,
            messageIds: [followerRFCId],
            accountId: accountId,
            folderPath: source
        )
        try insertOp(legacyRow, pool: pool)
        try insertOp(followerRow, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(legacyRow.id, pool: pool) == nil, "the bare provider-ID row must drain without any conversion step")
        #expect(try fetchOp(followerRow.id, pool: pool) == nil)
        let moves = await provider.movedIds
        #expect(moves.count == 1)
        guard moves.count == 1 else { return }
        #expect(moves[0].ids == [providerMessageId], "the token member reaches the provider byte-exact")
        #expect(moves[0].from == source)
        #expect(moves[0].to == destination)
        #expect(await provider.statefulFolder(messageId: providerMessageId) == destination)
        // FIFO order preserved: the legacy row (older) executed before the follower.
        let callLog = await provider.callLog
        let moveIndex = callLog.firstIndex { $0.hasPrefix("move(") }
        let readIndex = callLog.firstIndex { $0.hasPrefix("markRead(") }
        #expect(moveIndex != nil && readIndex != nil)
        if let moveIndex, let readIndex {
            #expect(moveIndex < readIndex, "insertion-order FIFO: the released row drains first")
        }
    }

    /// PLAN_IDENTITY_HYBRID §7.8 — a member containing `@` that fails RFC
    /// validation (double brackets) classifies as a TOKEN, is looked up as an
    /// exact opaque string, and no-ops authoritatively — it must never be
    /// re-normalized into the decoy message whose real RFC identity is the
    /// inner string.
    @Test("a malformed with-@ member classifies as a token: zero-match no-op, decoy untouched")
    func malformedAtMemberClassifiesAsTokenZeroMatchNoOp() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-token-malformed-\(suffix)"
        let decoyRFC = "decoy-\(suffix)@example.com"
        let decoyProviderId = "gmail-decoy-\(suffix)"
        // Contains exactly the decoy's RFC identity inside double brackets —
        // fails `durableActionRFC822MessageId`, so it is a token. A buggy
        // "normalize harder" path would strip to the decoy's identity and
        // mutate the wrong message.
        let malformedMember = "<<\(decoyRFC)>>"
        try await insertAccount(id: accountId, provider: .gmail, pool: pool)

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: decoyRFC, providerMessageId: decoyProviderId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }

        let operation = PendingOperation(
            type: .markRead,
            messageIds: [malformedMember],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try insertOp(operation, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(operation.id, pool: pool) == nil, "an exact zero-match token is authoritative stale — the row leaves the queue")
        let decoy = server.snapshots(rfc822MessageId: decoyRFC)
        #expect(decoy.count == 1)
        guard decoy.count == 1 else { return }
        #expect(decoy[0].labels.contains("UNREAD"), "the decoy sharing the inner identity must NOT be mutated")
    }

    @Test("a cancelled caller cannot own a drain after prepared fast-path authorization")
    func cancelledPreparedCallerCannotBecomeDrainOwner() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-preparation-cancelled-owner-\(suffix)"
        let messageId = "cancelled-owner-\(suffix)@example.com"
        let provider = MockEmailProvider()

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            // Establish the ready-database fast path before installing the
            // authorization hook used to suspend the candidate owner.
            await AccountManager.shared.drainPendingQueue()

            let operation = PendingOperation(
                type: .markRead,
                messageIds: [messageId],
                accountId: accountId,
                folderPath: "INBOX"
            )
            try insertOp(operation, pool: pool)

            let gate = QueuePreparationTestGate()
            await AccountManager.shared.setPendingQueueAuthorizationHookForTesting {
                await gate.arriveAndWaitForRelease()
            }
            let drain = Task { await AccountManager.shared.drainPendingQueue() }
            do {
                try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                    await gate.waitUntilArrival()
                }
                drain.cancel()
                await gate.releaseAll()
                try await joinDrainTask(drain)
            } catch {
                drain.cancel()
                await gate.releaseAll()
                try? await joinDrainTask(drain)
                throw error
            }

            let remaining = try fetchOp(operation.id, pool: pool)
            #expect(remaining?.status == PendingStatus.queued.rawValue)
            #expect(await provider.markedReadIds.isEmpty)
            #expect(await AccountManager.shared.isDraining == false)
            #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
        }
    }

    @Test("startup cleanup drops cancelled and every legacy no-op row without a provider")
    func startupCleanupDropsCancelledAndLegacyNoOpRowsWithoutProvider() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        var cancelled = PendingOperation(
            type: .markRead,
            messageIds: ["opaque-cancelled"],
            accountId: "missing-account",
            folderPath: "INBOX"
        )
        cancelled.status = PendingStatus.cancelled.rawValue
        let archive = PendingOperation(
            type: .archive,
            messageIds: ["opaque-archive"],
            accountId: "missing-account",
            folderPath: "INBOX"
        )
        let delete = PendingOperation(
            type: .delete,
            messageIds: ["opaque-delete"],
            accountId: "missing-account",
            folderPath: "INBOX"
        )
        let setTag = PendingOperation(
            type: .setTag,
            messageIds: ["opaque-set-tag"],
            accountId: "missing-account",
            folderPath: "INBOX",
            tagValue: "not-a-current-action-tag"
        )
        let removeTag = PendingOperation(
            type: .removeTag,
            messageIds: ["opaque-remove-tag"],
            accountId: "missing-account",
            folderPath: "INBOX",
            tagValue: nil
        )
        try insertOp(cancelled, pool: pool)
        try insertOp(archive, pool: pool)
        try insertOp(delete, pool: pool)
        try insertOp(setTag, pool: pool)
        try insertOp(removeTag, pool: pool)

        await AccountManager.shared.reconcilePendingOperations()

        let count = try await pool.read { db in
            try PendingOperation.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("simulated restart reruns crash recovery on the same database")
    func simulatedRestartRerunsCrashRecoveryOnSameDatabase() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-preparation-restart-\(suffix)"
        let firstMessageId = "before-restart-\(suffix)@example.com"
        let replayedMessageId = "after-restart-\(suffix)@example.com"
        let provider = MockEmailProvider()
        let first = PendingOperation(
            type: .markRead,
            messageIds: [firstMessageId],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try insertOp(first, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(first.id, pool: pool) == nil)

            var abandoned = PendingOperation(
                type: .markRead,
                messageIds: [replayedMessageId],
                accountId: accountId,
                folderPath: "INBOX"
            )
            abandoned.status = PendingStatus.inFlight.rawValue
            try insertOp(abandoned, pool: pool)

            await AccountManager.shared.resetPendingQueuePreparationForTesting()
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(abandoned.id, pool: pool) == nil)
        }

        let calls = await provider.markedReadIds
        #expect(calls.count == 2)
        #expect(calls.contains { $0.ids == [firstMessageId] })
        #expect(calls.contains { $0.ids == [replayedMessageId] })
    }

    @Test("preparation readiness is scoped to the active database instance")
    func preparationReadinessIsScopedToActiveDatabaseInstance() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir)
        }

        let firstSuffix = UUID().uuidString.lowercased()
        let firstAccountId = "acc-preparation-db-one-\(firstSuffix)"
        let firstProvider = MockEmailProvider()
        let firstOperation = PendingOperation(
            type: .markRead,
            messageIds: ["db-one-\(firstSuffix)@example.com"],
            accountId: firstAccountId,
            folderPath: "INBOX"
        )
        try insertOp(firstOperation, pool: firstPool)
        try await withRegisteredProvider(accountId: firstAccountId, provider: firstProvider) {
            await AccountManager.shared.drainPendingQueue()
        }
        #expect(try fetchOp(firstOperation.id, pool: firstPool) == nil)

        let (secondPool, secondDir, secondPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: secondPool, previous: secondPrevious, dir: secondDir)
        }

        let secondSuffix = UUID().uuidString.lowercased()
        let secondAccountId = "acc-preparation-db-two-\(secondSuffix)"
        let providerMessageId = "provider-db-two-\(secondSuffix)"
        let source = "Source-\(secondSuffix)"
        let destination = "Destination-\(secondSuffix)"
        try await insertAccount(id: secondAccountId, provider: .gmail, pool: secondPool)

        let secondProvider = MockEmailProvider(messageFieldScope: .account)
        // Hybrid: the bare provider-ID row is a token member — no conversion
        // exists; the fresh database still requires its own preparation
        // (crash recovery) before this row may drain.
        await secondProvider.seedStatefulMessage(
            id: providerMessageId,
            folder: source,
            providerMessageId: providerMessageId
        )
        let secondOperation = PendingOperation(
            type: .move,
            messageIds: [providerMessageId],
            accountId: secondAccountId,
            folderPath: source,
            destinationPath: destination
        )
        try insertOp(secondOperation, pool: secondPool)

        try await withRegisteredProvider(
            accountId: secondAccountId,
            provider: secondProvider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(secondOperation.id, pool: secondPool) == nil)
        #expect(await secondProvider.statefulFolder(messageId: providerMessageId) == destination)
    }

    @Test("an older blocked database flight cannot clear or publish over its replacement")
    func overlappingDatabaseReplacementKeepsNewPreparationAuthoritative() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir)
        }

        let firstSuffix = UUID().uuidString.lowercased()
        let firstAccountId = "acc-preparation-overlap-one-\(firstSuffix)"
        let firstProviderMessageId = "provider-overlap-one-\(firstSuffix)"
        let firstSource = "Source-one-\(firstSuffix)"
        let firstDestination = "Destination-one-\(firstSuffix)"
        try await insertAccount(id: firstAccountId, provider: .gmail, pool: firstPool)

        let firstGate = QueuePreparationTestGate()
        let firstProvider = MockEmailProvider(messageFieldScope: .account)
        await firstProvider.seedStatefulMessage(
            id: firstProviderMessageId,
            folder: firstSource,
            providerMessageId: firstProviderMessageId
        )
        // Hold the FIRST database's preparation flight open (the deleted
        // legacy converter used to provide this suspension point).
        await AccountManager.shared.setPendingQueuePreparationHookForTesting {
            await firstGate.arriveAndWaitForRelease()
        }
        let firstOperation = PendingOperation(
            type: .move,
            messageIds: [firstProviderMessageId],
            accountId: firstAccountId,
            folderPath: firstSource,
            destinationPath: firstDestination
        )
        try insertOp(firstOperation, pool: firstPool)
        await AccountManager.shared.registerProviderForTesting(
            accountId: firstAccountId,
            provider: firstProvider
        )

        let firstDrain = Task { await AccountManager.shared.drainPendingQueue() }
        let secondGate = QueuePreparationTestGate()
        var secondFixture: (pool: DatabasePool, dir: URL, previous: AppDatabase?)?
        var secondAccountId: String?
        var secondDrain: Task<Void, Never>?

        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await firstGate.waitUntilArrival()
            }

            let fixture = try await makeTestDB()
            secondFixture = fixture
            let secondSuffix = UUID().uuidString.lowercased()
            let accountId = "acc-preparation-overlap-two-\(secondSuffix)"
            secondAccountId = accountId
            let providerMessageId = "provider-overlap-two-\(secondSuffix)"
            let source = "Source-two-\(secondSuffix)"
            let destination = "Destination-two-\(secondSuffix)"
            try await insertAccount(id: accountId, provider: .outlook, pool: fixture.pool)

            let secondProvider = MockEmailProvider(messageFieldScope: .account)
            await secondProvider.seedStatefulMessage(
                id: providerMessageId,
                folder: source,
                providerMessageId: providerMessageId
            )
            // Swap the flight hook: the REPLACEMENT database's preparation
            // now blocks on the second gate (captured at flight creation).
            await AccountManager.shared.setPendingQueuePreparationHookForTesting {
                await secondGate.arriveAndWaitForRelease()
            }
            let secondOperation = PendingOperation(
                type: .move,
                messageIds: [providerMessageId],
                accountId: accountId,
                folderPath: source,
                destinationPath: destination
            )
            try insertOp(secondOperation, pool: fixture.pool)
            await AccountManager.shared.registerProviderForTesting(
                accountId: accountId,
                provider: secondProvider
            )

            let replacementDrain = Task { await AccountManager.shared.drainPendingQueue() }
            secondDrain = replacementDrain
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await secondGate.waitUntilArrival()
            }

            await firstGate.releaseAll()
            try await joinDrainTask(firstDrain)

            let firstAfterReplacement = try fetchOp(firstOperation.id, pool: firstPool)
            #expect(firstAfterReplacement != nil)
            #expect(firstAfterReplacement?.status == PendingStatus.queued.rawValue)
            #expect(await firstProvider.movedIds.isEmpty)

            let blockedReplacement = try fetchOp(secondOperation.id, pool: fixture.pool)
            #expect(blockedReplacement?.messageIds == [providerMessageId])
            #expect(blockedReplacement?.status == PendingStatus.queued.rawValue)
            #expect(await secondProvider.movedIds.isEmpty)
            #expect(
                await AccountManager.shared.pendingQueuePreparationParticipantCountForTesting() == 1
            )
            #expect(await AccountManager.shared.isDraining == false)

            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            await secondGate.releaseAll()
            try await joinDrainTask(replacementDrain)

            #expect(try fetchOp(secondOperation.id, pool: fixture.pool) == nil)
            #expect(await secondProvider.movedIds.count == 1)
            #expect(await secondProvider.statefulFolder(messageId: providerMessageId) == destination)

            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
            restoreTestDB(pool: fixture.pool, previous: fixture.previous, dir: fixture.dir)
            secondFixture = nil
        } catch {
            firstDrain.cancel()
            secondDrain?.cancel()
            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            await firstGate.releaseAll()
            await secondGate.releaseAll()
            try? await joinDrainTask(firstDrain)
            if let secondDrain {
                try? await joinDrainTask(secondDrain)
            }
            if let secondAccountId {
                await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
            }
            await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
            if let secondFixture {
                restoreTestDB(
                    pool: secondFixture.pool,
                    previous: secondFixture.previous,
                    dir: secondFixture.dir
                )
            }
            throw error
        }
    }

    @Test("a database swap after preparation authorization cannot redirect the drain")
    func authorizedDrainRemainsBoundToItsPreparedDatabase() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir)
        }
        guard let firstDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("first test database was not installed")
            return
        }

        let (secondPool, secondDir, secondPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: secondPool, previous: secondPrevious, dir: secondDir)
        }
        guard let secondDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("second test database was not installed")
            return
        }
        AppDatabase.shared.withLock { $0 = firstDatabase }

        let suffix = UUID().uuidString.lowercased()
        let firstAccountId = "acc-authorized-first-\(suffix)"
        let secondAccountId = "acc-authorized-second-\(suffix)"
        let firstMessageId = "authorized-first-\(suffix)@example.com"
        let secondMessageId = "authorized-second-\(suffix)@example.com"
        let source = "Source-\(suffix)"
        let destination = "Destination-\(suffix)"
        let firstProvider = MockEmailProvider()
        let secondProvider = MockEmailProvider()
        let firstOperation = PendingOperation(
            type: .move,
            messageIds: [firstMessageId],
            accountId: firstAccountId,
            folderPath: source,
            destinationPath: destination
        )
        let secondOperation = PendingOperation(
            type: .markRead,
            messageIds: [secondMessageId],
            accountId: secondAccountId,
            folderPath: "INBOX"
        )
        try insertOp(firstOperation, pool: firstPool)
        try insertOp(secondOperation, pool: secondPool)
        await firstProvider.seedStatefulMessage(
            id: firstMessageId,
            folder: source,
            providerMessageId: "provider-\(suffix)"
        )
        await AccountManager.shared.registerProviderForTesting(
            accountId: firstAccountId,
            provider: firstProvider
        )
        await AccountManager.shared.registerProviderForTesting(
            accountId: secondAccountId,
            provider: secondProvider
        )

        do {
            await AccountManager.shared.setPendingQueueAuthorizationHookForTesting {
                AppDatabase.shared.withLock { $0 = secondDatabase }
            }
            await AccountManager.shared.drainPendingQueue()

            #expect(try fetchOp(firstOperation.id, pool: firstPool) == nil)
            #expect(try fetchOp(secondOperation.id, pool: secondPool)?.status
                == PendingStatus.queued.rawValue)
            #expect(await firstProvider.statefulFolder(messageId: firstMessageId) == destination)
            #expect(await firstProvider.movedIds.count == 1)
            #expect(
                await firstProvider.callLog.allSatisfy { !$0.hasPrefix("fetchMessages(") },
                "the durable queue must not inherit ordinary sync work after a move"
            )
            #expect(await secondProvider.markedReadIds.isEmpty)

            await AccountManager.shared.drainPendingQueue()

            #expect(try fetchOp(secondOperation.id, pool: secondPool) == nil)
            #expect(await secondProvider.markedReadIds.count == 1)
        } catch {
            await AccountManager.shared.setPendingQueueAuthorizationHookForTesting(nil)
            await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
            await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
            throw error
        }

        await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
        await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
    }

    @Test("an owner retries the newest database when an obsolete re-preparation loses a replacement race")
    func ownerRetainsNewestDatabaseRedrainRequestAcrossObsoletePreparation() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir) }
        guard let firstDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("first test database was not installed")
            return
        }

        let (secondPool, secondDir, secondPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: secondPool, previous: secondPrevious, dir: secondDir) }
        guard let secondDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("second test database was not installed")
            return
        }

        let (thirdPool, thirdDir, thirdPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: thirdPool, previous: thirdPrevious, dir: thirdDir) }
        guard let thirdDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("third test database was not installed")
            return
        }
        AppDatabase.shared.withLock { $0 = firstDatabase }

        let suffix = UUID().uuidString.lowercased()
        let firstAccountId = "acc-redrain-first-\(suffix)"
        let secondAccountId = "acc-redrain-second-\(suffix)"
        let thirdAccountId = "acc-redrain-third-\(suffix)"
        let firstMessageId = "redrain-first-\(suffix)@example.com"
        let secondProviderMessageId = "provider-redrain-second-\(suffix)"
        let thirdMessageId = "redrain-third-\(suffix)@example.com"

        try await insertAccount(id: secondAccountId, provider: .outlook, pool: secondPool)
        let firstProviderGate = QueuePreparationTestGate()
        let secondPreparationGate = QueuePreparationTestGate()
        let firstProvider = MockEmailProvider()
        await firstProvider.setMarkReadHook {
            await firstProviderGate.arriveAndWaitForRelease()
        }
        let secondProvider = MockEmailProvider()
        let thirdProvider = MockEmailProvider()

        let firstOperation = PendingOperation(
            type: .markRead,
            messageIds: [firstMessageId],
            accountId: firstAccountId,
            folderPath: "INBOX"
        )
        let secondOperation = PendingOperation(
            type: .move,
            messageIds: [secondProviderMessageId],
            accountId: secondAccountId,
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        let thirdOperation = PendingOperation(
            type: .markFlagged,
            messageIds: [thirdMessageId],
            accountId: thirdAccountId,
            folderPath: "INBOX"
        )
        try insertOp(firstOperation, pool: firstPool)
        try insertOp(secondOperation, pool: secondPool)
        try insertOp(thirdOperation, pool: thirdPool)

        await AccountManager.shared.registerProviderForTesting(
            accountId: firstAccountId,
            provider: firstProvider
        )
        await AccountManager.shared.registerProviderForTesting(
            accountId: secondAccountId,
            provider: secondProvider
        )
        await AccountManager.shared.registerProviderForTesting(
            accountId: thirdAccountId,
            provider: thirdProvider
        )

        let owner = Task { await AccountManager.shared.drainPendingQueue() }
        var secondCaller: Task<Void, Never>?
        var thirdCaller: Task<Void, Never>?
        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await firstProviderGate.waitUntilArrival()
            }

            // Ask the active owner for another pass while A is still current.
            // This is the request that makes the owner join B's preparation
            // after the first provider call completes.
            let initialRedrain = Task { await AccountManager.shared.drainPendingQueue() }
            try await joinDrainTask(initialRedrain)
            #expect(await AccountManager.shared.needsRedrain)

            AppDatabase.shared.withLock { $0 = secondDatabase }
            // Hold database B's preparation flight open (the deleted legacy
            // converter used to provide this suspension point).
            await AccountManager.shared.setPendingQueuePreparationHookForTesting {
                await secondPreparationGate.arriveAndWaitForRelease()
            }
            let secondDrain = Task { await AccountManager.shared.drainPendingQueue() }
            secondCaller = secondDrain
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await secondPreparationGate.waitUntilArrival()
            }

            await firstProviderGate.releaseAll()
            try await waitForPreparationParticipants(2)

            AppDatabase.shared.withLock { $0 = thirdDatabase }
            // Database C's flight must NOT block — clear the hook before it
            // is created (each flight captures the hook at creation).
            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            let thirdDrain = Task { await AccountManager.shared.drainPendingQueue() }
            thirdCaller = thirdDrain
            try await joinDrainTask(thirdDrain)

            await secondPreparationGate.releaseAll()
            try await joinDrainTask(secondDrain)
            try await joinDrainTask(owner)

            #expect(try fetchOp(firstOperation.id, pool: firstPool) == nil)
            #expect(try fetchOp(secondOperation.id, pool: secondPool) != nil)
            #expect(try fetchOp(thirdOperation.id, pool: thirdPool) == nil)
            #expect(await firstProvider.markedReadIds.count == 1)
            #expect(await secondProvider.movedIds.isEmpty)
            #expect(await thirdProvider.markedFlaggedIds.count == 1)
            #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
        } catch {
            owner.cancel()
            secondCaller?.cancel()
            thirdCaller?.cancel()
            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            await firstProviderGate.releaseAll()
            await secondPreparationGate.releaseAll()
            try? await joinDrainTask(owner)
            if let secondCaller { try? await joinDrainTask(secondCaller) }
            if let thirdCaller { try? await joinDrainTask(thirdCaller) }
            await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
            await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
            await AccountManager.shared.unregisterProviderForTesting(accountId: thirdAccountId)
            throw error
        }

        await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
        await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
        await AccountManager.shared.unregisterProviderForTesting(accountId: thirdAccountId)
    }

    @Test("a draft save remains bound to its authorized database across the provider await")
    func draftSaveRemainsBoundAcrossProviderAwaitDatabaseSwap() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir)
        }
        guard let firstDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("first test database was not installed")
            return
        }

        let (secondPool, secondDir, secondPrevious) = try await makeTestDB()
        defer {
            restoreTestDB(pool: secondPool, previous: secondPrevious, dir: secondDir)
        }
        guard let secondDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("second test database was not installed")
            return
        }
        AppDatabase.shared.withLock { $0 = firstDatabase }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-draft-binding-\(suffix)"
        let draftId = "draft-binding-\(suffix)"
        try await insertAccount(id: accountId, provider: .gmail, pool: firstPool)
        try await insertAccount(id: accountId, provider: .gmail, pool: secondPool)
        let firstDraft = makeQueueDraft(
            id: draftId,
            accountId: accountId,
            subject: "Database A subject",
            body: "Database A body",
            serverDraftId: "server-a-\(suffix)"
        )
        let secondDraft = makeQueueDraft(
            id: draftId,
            accountId: accountId,
            subject: "Database B subject",
            body: "Database B body",
            serverDraftId: "server-b-\(suffix)"
        )
        try await firstPool.writeWithoutTransaction { db in
            try firstDraft.insert(db)
        }
        try await secondPool.writeWithoutTransaction { db in
            try secondDraft.insert(db)
        }
        let operation = PendingOperation(
            type: .saveDraft,
            messageIds: [draftId],
            accountId: accountId,
            folderPath: "Drafts"
        )
        try insertOp(operation, pool: firstPool)

        let provider = MockEmailProvider()
        await provider.setSaveDraftHook {
            AppDatabase.shared.withLock { $0 = secondDatabase }
        }
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        let savedDrafts = await provider.savedDrafts
        #expect(savedDrafts.count == 1)
        guard savedDrafts.count == 1 else { return }
        #expect(savedDrafts[0].draft.subject == firstDraft.subject)
        #expect(savedDrafts[0].draft.body == MessageBody.plainTextToHTML(firstDraft.body))
        #expect(savedDrafts[0].existingDraftId == firstDraft.serverDraftId)

        let persistedFirst = try await firstPool.read { db in
            try Draft.fetchOne(db, key: draftId)
        }
        let persistedSecond = try await secondPool.read { db in
            try Draft.fetchOne(db, key: draftId)
        }
        #expect(persistedFirst?.serverPushStatus == "pushed")
        #expect(persistedFirst?.serverDraftId == "mock-draft-id")
        #expect(persistedFirst?.subject == firstDraft.subject)
        #expect(persistedSecond?.serverPushStatus == secondDraft.serverPushStatus)
        #expect(persistedSecond?.serverDraftId == secondDraft.serverDraftId)
        #expect(persistedSecond?.subject == secondDraft.subject)
        #expect(persistedSecond?.body == secondDraft.body)
        #expect(try fetchOp(operation.id, pool: firstPool) == nil)
        let secondQueueCount = try await secondPool.read { db in
            try PendingOperation.fetchCount(db)
        }
        #expect(secondQueueCount == 0)
    }

    @Test("field completions retain alternating exact values for the claimed id without a header")
    func fieldCompletionPublishesClaimedIdAndRetainsOppositeValues() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-field-completion-\(suffix)"
        let messageId = "field-message-\(suffix)"
        var markRead = PendingOperation(
            type: .markRead,
            messageIds: [messageId],
            accountId: accountId,
            folderPath: "INBOX-\(suffix)"
        )
        markRead.status = PendingStatus.inFlight.rawValue
        var markUnread = PendingOperation(
            type: .markUnread,
            messageIds: [messageId],
            accountId: accountId,
            folderPath: markRead.folderPath
        )
        markUnread.status = PendingStatus.inFlight.rawValue
        let persistedRead = markRead
        let persistedUnread = markUnread
        try await pool.writeWithoutTransaction { db in
            try persistedRead.insert(db)
            try persistedUnread.insert(db)
        }
        let provider = MockEmailProvider(messageFieldScope: .account)

        let readOutcome = await AccountManager.shared.executeSingleOp(
            persistedRead,
            provider: provider,
            context: AccountManager.DrainContext()
        )
        #expect(readOutcome == .proceed)
        let readKey = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: accountId,
            messageId: messageId,
            value: .read(true)
        )
        let recentAfterRead = await AccountManager.shared.recentlyCompleted
        let readExpiry = try #require(recentAfterRead[readKey])

        try await Task.sleep(for: .milliseconds(2))
        let unreadOutcome = await AccountManager.shared.executeSingleOp(
            persistedUnread,
            provider: provider,
            context: AccountManager.DrainContext()
        )
        #expect(unreadOutcome == .proceed)

        let unreadKey = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: accountId,
            messageId: messageId,
            value: .read(false)
        )
        let recent = await AccountManager.shared.recentlyCompleted
        let unreadExpiry = try #require(recent[unreadKey])
        #expect(recent[readKey] == readExpiry,
                "a later opposite completion must retain the earlier exact value")
        #expect(unreadExpiry > readExpiry)
        #expect(recent[MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            messageId: messageId,
            field: .read
        )] == unreadExpiry)
        #expect(recent[MessageIdentity.recentlyCompletedAccountKey(
            accountId: accountId,
            messageId: messageId
        )] == unreadExpiry)
        #expect(try fetchOp(markRead.id, pool: pool) == nil)
        #expect(try fetchOp(markUnread.id, pool: pool) == nil)
    }

    // MARK: - Round C: dumb global FIFO (§14.5 narrow queue-primitive safety tests)

    @Test("insertion order (SQLite rowid), not wall-clock createdAt, controls FIFO — even under simulated clock rollback")
    func insertionOrderNotWallClockControlsFIFO() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-fifo-rowid-\(suffix)"
        let firstMessageId = "fifo-first-\(suffix)@example.com"
        let secondMessageId = "fifo-second-\(suffix)@example.com"
        let thirdMessageId = "fifo-third-\(suffix)@example.com"

        let now = Date()
        // Inserted FIRST (lowest rowid) but stamped with a far-future
        // createdAt — simulates a forward clock skew.
        var op1 = PendingOperation(type: .markRead, messageIds: [firstMessageId], accountId: accountId, folderPath: "INBOX")
        op1.createdAt = now.addingTimeInterval(10_000)
        // Inserted SECOND but stamped with the OLDEST createdAt of the three —
        // simulates a clock rollback. If createdAt controlled ordering this
        // would run FIRST; rowid must keep it second.
        var op2 = PendingOperation(type: .markRead, messageIds: [secondMessageId], accountId: accountId, folderPath: "INBOX")
        op2.createdAt = now.addingTimeInterval(-10_000)
        // Inserted THIRD with an ordinary createdAt.
        var op3 = PendingOperation(type: .markRead, messageIds: [thirdMessageId], accountId: accountId, folderPath: "INBOX")
        op3.createdAt = now
        try insertOp(op1, pool: pool)
        try insertOp(op2, pool: pool)
        try insertOp(op3, pool: pool)

        let provider = MockEmailProvider()
        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        let calls = await provider.markedReadIds
        #expect(
            calls.map { $0.ids } == [[firstMessageId], [secondMessageId], [thirdMessageId]],
            "the provider must observe ops in insertion (rowid) order, not createdAt order"
        )
        #expect(try fetchOp(op1.id, pool: pool) == nil)
        #expect(try fetchOp(op2.id, pool: pool) == nil)
        #expect(try fetchOp(op3.id, pool: pool) == nil)
    }

    @Test("a transient frontier failure blocks later work — no overtaking, global FIFO across accounts")
    func transientFrontierFailureBlocksLaterWorkAcrossAccounts() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountA = "acc-fifo-block-a-\(suffix)"
        let accountB = "acc-fifo-block-b-\(suffix)"
        let op1MessageId = "block-op1-\(suffix)@example.com"
        let op2MessageId = "block-op2-\(suffix)@example.com"
        let op3MessageId = "block-op3-\(suffix)@example.com"

        let providerA = MockEmailProvider()
        let providerB = MockEmailProvider()
        await providerA.setMarkReadThrows(ProviderError.notConnected)
        // A cross-provider order recorder: proves op3 (account B) never runs
        // until op1 (account A) has fully resolved — the FIFO must never let
        // a later row on a DIFFERENT account overtake an unresolved frontier.
        let order = Mutex<[String]>([])
        await providerA.setMarkReadHook { order.withLock { $0.append("A") } }
        await providerB.setMarkReadHook { order.withLock { $0.append("B") } }

        // op1 (account A) is the frontier and throws transiently. op2 (same
        // account A) and op3 (a DIFFERENT account B) are queued behind it.
        let op1 = PendingOperation(type: .markRead, messageIds: [op1MessageId], accountId: accountA, folderPath: "INBOX")
        let op2 = PendingOperation(type: .markFlagged, messageIds: [op2MessageId], accountId: accountA, folderPath: "INBOX")
        let op3 = PendingOperation(type: .markRead, messageIds: [op3MessageId], accountId: accountB, folderPath: "INBOX")
        try insertOp(op1, pool: pool)
        try insertOp(op2, pool: pool)
        try insertOp(op3, pool: pool)

        await AccountManager.shared.registerProviderForTesting(accountId: accountA, provider: providerA)
        await AccountManager.shared.registerProviderForTesting(accountId: accountB, provider: providerB)

        await AccountManager.shared.drainPendingQueue()

        let op1AfterFirstDrain = try fetchOp(op1.id, pool: pool)
        #expect(op1AfterFirstDrain?.status == PendingStatus.queued.rawValue, "op1 stays queued after a transient failure")
        #expect(op1AfterFirstDrain?.messageIds == [op1MessageId], "op1's payload is unchanged")
        #expect(op1AfterFirstDrain?.retryCount == 1)
        let op2AfterFirstDrain = try fetchOp(op2.id, pool: pool)
        #expect(op2AfterFirstDrain?.status == PendingStatus.queued.rawValue, "op2 must still exist, never claimed")
        let op3AfterFirstDrain = try fetchOp(op3.id, pool: pool)
        #expect(op3AfterFirstDrain?.status == PendingStatus.queued.rawValue, "op3 must still exist, never claimed")
        #expect(await providerA.markedReadIds.count == 1, "only op1's single attempt reached provider A")
        #expect(await providerA.markedFlaggedIds.isEmpty, "op2 must never reach its provider while op1 blocks the frontier")
        #expect(await providerB.markedReadIds.isEmpty, "op3 must never reach its provider while op1 blocks the frontier")

        // Clear the failure and drain again — all three complete in order.
        await providerA.setMarkReadThrows(nil)
        await AccountManager.shared.drainPendingQueue()

        #expect(try fetchOp(op1.id, pool: pool) == nil)
        #expect(try fetchOp(op2.id, pool: pool) == nil)
        #expect(try fetchOp(op3.id, pool: pool) == nil)
        #expect(await providerA.markedReadIds.count == 2, "op1: one failed attempt + one successful retry")
        #expect(await providerA.markedFlaggedIds.count == 1)
        #expect(await providerB.markedReadIds.count == 1)
        #expect(
            order.withLock { $0 } == ["A", "A", "B"],
            "op1 must fully resolve on account A before op3 ever reaches account B's provider"
        )

        await AccountManager.shared.unregisterProviderForTesting(accountId: accountA)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountB)
    }

    @Test("provider I/O never runs while the pending-operation mutation gate is held")
    func providerIONeverRunsWhileMutationGateHeld() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gate-not-held-\(suffix)"
        let messageId = "gate-not-held-\(suffix)@example.com"
        let provider = MockEmailProvider()
        let gateWasHeldDuringProviderCall = Mutex(false)
        await provider.setMarkReadHook {
            if AccountManager.shared.pendingOperationMutationGate.isHeldForTesting {
                gateWasHeldDuringProviderCall.withLock { $0 = true }
            }
        }

        let op = PendingOperation(type: .markRead, messageIds: [messageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(op.id, pool: pool) == nil, "the op drained end to end")
        #expect(
            !gateWasHeldDuringProviderCall.withLock { $0 },
            "the mutation gate must never be held while provider I/O is in flight"
        )
    }

    @Test("a batch is retried whole after a transient failure — never split into child rows")
    func batchRetriedWholeNeverSplit() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-no-split-\(suffix)"
        // RFC-shaped (contains "@") like every other durable message id in
        // this suite — a bare token would be treated as a legacy
        // provider-ID needing resolution by drainPendingQueue's identity
        // conversion gate (unrelated to what this test exercises) and would
        // block the drain before it ever reaches the provider.
        let messageIds = [
            "split-a-\(suffix)@example.com",
            "split-b-\(suffix)@example.com",
            "split-c-\(suffix)@example.com",
        ]
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "no-split-\(suffix)@example.com", displayName: "No Split", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId).insert(db)
        }

        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.notConnected)

        let op = PendingOperation(type: .move, messageIds: messageIds, accountId: accountId, folderPath: "INBOX", destinationPath: "Archive")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()

            let rowsAfterFailure = try await pool.read { db in
                try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
            }
            #expect(rowsAfterFailure.count == 1, "the batch must never split into child rows on a transient failure")
            guard rowsAfterFailure.count == 1 else { return }
            #expect(rowsAfterFailure[0].id == op.id)
            #expect(rowsAfterFailure[0].status == PendingStatus.queued.rawValue)
            #expect(rowsAfterFailure[0].messageIds == messageIds, "batch membership is unchanged, still 3 members")
            #expect(rowsAfterFailure[0].retryCount == 1)
            let movesAfterFailure = await provider.movedIds
            #expect(movesAfterFailure.count == 1)
            #expect(movesAfterFailure.last?.ids == messageIds, "the single attempt already carried the whole batch")

            await provider.setMoveThrows(nil)
            await AccountManager.shared.drainPendingQueue()

            let rowsAfterRetry = try await pool.read { db in
                try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
            }
            #expect(rowsAfterRetry.isEmpty, "the batch completed as one row — no split remnants")
            let movesAfterRetry = await provider.movedIds
            #expect(movesAfterRetry.count == 2, "one failed whole-batch attempt + one successful whole-batch attempt")
            #expect(movesAfterRetry.last?.ids == messageIds, "the retry is a single whole-batch provider call")
        }
    }

    @Test("a missing provider blocks the frontier without skipping it; registering the provider then draining completes both ops in order")
    func missingProviderBlocksFrontierUntilRegistered() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountWithoutProvider = "acc-missing-provider-\(suffix)"
        let accountWithProvider = "acc-has-provider-\(suffix)"
        let op1MessageId = "missing-provider-op1-\(suffix)@example.com"
        let op2MessageId = "missing-provider-op2-\(suffix)@example.com"

        // op1 (no provider registered) is inserted first and becomes the
        // frontier; op2 (provider registered) is inserted second.
        let op1 = PendingOperation(type: .markRead, messageIds: [op1MessageId], accountId: accountWithoutProvider, folderPath: "INBOX")
        let op2 = PendingOperation(type: .markRead, messageIds: [op2MessageId], accountId: accountWithProvider, folderPath: "INBOX")
        try insertOp(op1, pool: pool)
        try insertOp(op2, pool: pool)

        let provider2 = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountWithProvider, provider: provider2)

        await AccountManager.shared.drainPendingQueue()

        let op1AfterFirstDrain = try fetchOp(op1.id, pool: pool)
        #expect(op1AfterFirstDrain != nil, "the frontier row is never deleted while its provider is missing")
        #expect(op1AfterFirstDrain?.status == PendingStatus.queued.rawValue, "the frontier row is returned to queued, never left inFlight")
        let op2AfterFirstDrain = try fetchOp(op2.id, pool: pool)
        #expect(op2AfterFirstDrain?.status == PendingStatus.queued.rawValue, "op2 must still exist, never claimed while op1 blocks the frontier")
        #expect(await provider2.markedReadIds.isEmpty, "op2 must never reach its provider while the frontier is blocked")

        let provider1 = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountWithoutProvider, provider: provider1)
        await AccountManager.shared.drainPendingQueue()

        #expect(try fetchOp(op1.id, pool: pool) == nil)
        #expect(try fetchOp(op2.id, pool: pool) == nil)
        #expect(await provider1.markedReadIds.count == 1)
        #expect(await provider2.markedReadIds.count == 1)

        await AccountManager.shared.unregisterProviderForTesting(accountId: accountWithoutProvider)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountWithProvider)
    }

    @Test("a cancelled drain does not strand its claimed frontier")
    func cancelledDrainDoesNotStrandClaimedFrontier() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-cancelled-frontier-\(suffix)"
        let op1MessageId = "cancelled-frontier-op1-\(suffix)@example.com"
        let op2MessageId = "cancelled-frontier-op2-\(suffix)@example.com"

        // op1 is the frontier and blocks INSIDE its provider call, so the
        // drain task can be cancelled at exactly the point where it still owes
        // the claimed row a terminal lifecycle write. op2 is a different
        // action type so its provider arrival is unambiguous.
        let op1 = PendingOperation(type: .markRead, messageIds: [op1MessageId], accountId: accountId, folderPath: "INBOX")
        let op2 = PendingOperation(type: .markFlagged, messageIds: [op2MessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op1, pool: pool)
        try insertOp(op2, pool: pool)

        let provider = MockEmailProvider()
        let providerGate = QueuePreparationTestGate()
        await provider.setMarkReadHook {
            await providerGate.arriveAndWaitForRelease()
        }

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            let drain = Task { await AccountManager.shared.drainPendingQueue() }
            do {
                try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                    await providerGate.waitUntilArrival()
                }
                // Cancel while the drain is suspended inside op1's provider
                // call — it has already claimed op1 (inFlight) but has not yet
                // written op1's terminal outcome.
                drain.cancel()
                await providerGate.releaseAll()
                try await joinDrainTask(drain)
            } catch {
                await providerGate.releaseAll()
                drain.cancel()
                try? await joinDrainTask(drain)
                throw error
            }

            // The claimed frontier must never be left inFlight: the protected-
            // frontier rule refuses to steal or skip such a row, and crash
            // recovery does not re-run mid-session, so one stranded row would
            // wedge the whole global FIFO until the next app launch.
            let op1AfterCancellation = try fetchOp(op1.id, pool: pool)
            if let op1AfterCancellation {
                #expect(
                    op1AfterCancellation.status == PendingStatus.queued.rawValue,
                    "a surviving claimed frontier must be back in queued, never stranded inFlight"
                )
                #expect(op1AfterCancellation.messageIds == [op1MessageId], "its payload is unchanged")
            }
            #expect(
                !AccountManager.shared.pendingOperationMutationGate.isHeldForTesting,
                "a cancelled drain must not leak the mutation permit"
            )

            // The queue is not wedged: a subsequent drain makes progress and
            // both ops reach the provider and leave the durable queue.
            await AccountManager.shared.drainPendingQueue()

            #expect(try fetchOp(op1.id, pool: pool) == nil, "op1 must not be wedged in the queue")
            #expect(try fetchOp(op2.id, pool: pool) == nil, "op2 must not be blocked behind a stranded frontier")
            #expect(await provider.markedReadIds.contains { $0.ids == [op1MessageId] })
            #expect(await provider.markedFlaggedIds.contains { $0.ids == [op2MessageId] })
            #expect(
                !AccountManager.shared.pendingOperationMutationGate.isHeldForTesting,
                "the mutation permit is released after the queue drains"
            )
        }
    }

    // MARK: - Provider-adapter Law 4 classification (Round E)

    /// Pins the primary "Gmail gap" from the Round E audit: `modifyMessage`
    /// only caught 404/410, so a destination label deleted remotely between
    /// enqueue and drain escaped as an uncaught HTTP 400 — today's queue only
    /// rescues it via the deleted `isPermanentlyInvalidError` classifier.
    /// `GmailProvider.modifyMessage` now structurally parses Gmail's real
    /// invalid-label 400 body and normal-returns (Law 4); the generic queue
    /// no longer classifies provider error types at all (Law 5) — this test
    /// proves the adapter alone is sufficient through the REAL drain.
    @Test("Gmail move to a remotely deleted destination label terminal-no-ops through the real drain, and a later op still proceeds")
    func gmailMoveToDeletedDestinationLabelSelfHealsAndLaterOpProceeds() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        let accountId = "acc-gmail-gone-label-\(UUID().uuidString.lowercased())"
        let rfc822MessageId = "gmail-gone-label-\(UUID().uuidString.lowercased())@example.com"
        let deletedLabelId = "Label_gone_\(UUID().uuidString.lowercased())"
        let providerMessageId = "gmail-resource-\(UUID().uuidString.lowercased())"
        let otherRfc822MessageId = "gmail-gone-label-other-\(UUID().uuidString.lowercased())@example.com"
        let otherProviderMessageId = "gmail-resource-other-\(UUID().uuidString.lowercased())"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfc822MessageId, providerMessageId: providerMessageId, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: otherRfc822MessageId, providerMessageId: otherProviderMessageId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.markLabelDeleted(deletedLabelId)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        // A local Folder row for the destination label MUST exist so the
        // queue's local-destination-missing self-heal (kept per Round E
        // item 4c — it reads local command validity, not provider error
        // types) cannot mask whether `GmailProvider` itself classifies the
        // invalid-label 400. Without this row, reverting the adapter fix
        // would still "pass" this test for the wrong reason.
        try await pool.writeWithoutTransaction { db in
            try Folder(name: "Project", path: deletedLabelId, role: .custom, accountId: accountId).insert(db)
        }

        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var staleOp = PendingOperation(
            type: .move, messageIds: [rfc822MessageId], accountId: accountId,
            folderPath: "INBOX", destinationPath: deletedLabelId
        )
        staleOp.createdAt = t0
        var laterOp = PendingOperation(
            type: .markRead, messageIds: [otherRfc822MessageId], accountId: accountId, folderPath: "INBOX"
        )
        laterOp.createdAt = t0.addingTimeInterval(1)
        try insertOp(staleOp, pool: pool)
        try insertOp(laterOp, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.drainPendingQueue()
        }

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchCount(db)
        }
        #expect(remaining == 0, "the gone-label move terminal-no-ops and the later markRead completes")

        let untouched = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(untouched.count == 1)
        guard untouched.count == 1 else { return }
        #expect(untouched[0].labels.contains("INBOX"), "the move never applied — message stays in INBOX")
        #expect(!untouched[0].labels.contains(deletedLabelId))

        let laterMessage = server.snapshots(rfc822MessageId: otherRfc822MessageId)
        #expect(laterMessage.count == 1)
        guard laterMessage.count == 1 else { return }
        #expect(laterMessage[0].isRead, "the later markRead was not wedged behind the gone-label op")
    }

    // MARK: - Provider API doc-pins (web-verified API audit, 2026-07)

    /// SPEC-B1: a real observed Gmail `rfc822msgid:` search-index quirk can
    /// surface a DECOY message (whose true Message-ID is a SUPERSTRING of
    /// the queried id) alongside the true match. Two refs make the op
    /// ambiguous — the count guard in `resolveActionMessageId`
    /// (`refs.count == 1`) is what protects both candidates from mutation,
    /// not the later metadata-compare (verified by the mutation-check for
    /// this test, which disables ONLY the compare via
    /// `GmailProvider.skipActionMetadataVerificationForTesting` and confirms
    /// the assertions still hold — the count guard alone is sufficient).
    @Test("Gmail rfc822msgid substring decoy: two refs authoritative-no-op through the real drain, decoy never mutated")
    func gmailRfc822MsgidSubstringDecoyNeverMutated() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gmail-decoy-\(suffix)"
        let targetRFC = "abc-\(suffix)@example.com"
        let decoyRFC = "xabc-\(suffix)@example.com"
        let targetProviderId = "gmail-target-\(suffix)"
        let decoyProviderId = "gmail-decoy-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: targetRFC, providerMessageId: targetProviderId, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: decoyRFC, providerMessageId: decoyProviderId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.addSubstringDecoyMatchForTesting(decoyProviderMessageId: decoyProviderId, matchesQuery: targetRFC)

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let op = PendingOperation(type: .markRead, messageIds: [targetRFC], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(op.id, pool: pool) == nil, "two-ref ambiguity is authoritative — the row leaves the queue")
        let target = server.snapshots(rfc822MessageId: targetRFC)
        let decoy = server.snapshots(rfc822MessageId: decoyRFC)
        #expect(target.count == 1)
        #expect(decoy.count == 1)
        guard target.count == 1, decoy.count == 1 else { return }
        #expect(target[0].labels.contains("UNREAD"), "the true match must NOT be mutated while ambiguous")
        #expect(decoy[0].labels.contains("UNREAD"), "the decoy must NEVER be mutated")
    }

    /// SPEC-B2: `resolveActionMessageId` unconditionally sends
    /// `includeSpamTrash=true` — real Gmail excludes TRASH/SPAM-labeled
    /// messages from EVERY list/search response otherwise, even given an
    /// explicit `labelIds=TRASH` filter. A markRead recorded against the
    /// TRASH scope only resolves because of this parameter.
    @Test("Gmail markRead against TRASH scope resolves only because includeSpamTrash=true is sent")
    func gmailTrashScopedMarkReadRequiresIncludeSpamTrash() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gmail-trash-\(suffix)"
        let rfc822MessageId = "trash-\(suffix)@example.com"
        let providerMessageId = "gmail-trash-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfc822MessageId, providerMessageId: providerMessageId, labels: ["TRASH", "UNREAD"]),
        ])
        defer { server.close() }

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let op = PendingOperation(type: .markRead, messageIds: [rfc822MessageId], accountId: accountId, folderPath: "TRASH")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(op.id, pool: pool) == nil, "the markRead resolves and completes")
        let snapshot = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(snapshot.count == 1)
        guard snapshot.count == 1 else { return }
        #expect(snapshot[0].isRead, "remote UNREAD must be removed — includeSpamTrash=true made the TRASH-scoped search resolve")
    }

    /// SPEC-B3: a search response with exactly one ref PLUS a non-nil
    /// `nextPageToken` is treated as ambiguous (the guard requires
    /// `response.nextPageToken == nil`), even when the implied next page
    /// would be empty. This pins the CURRENT deliberate
    /// ambiguity-conservative choice as a doc-pin, not a bug.
    @Test("Gmail spurious nextPageToken on a single-ref search pins the ambiguity-conservative no-op")
    func gmailSpuriousNextPageTokenPinsAmbiguityConservativeNoOp() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gmail-nextpage-\(suffix)"
        let rfc822MessageId = "nextpage-\(suffix)@example.com"
        let providerMessageId = "gmail-nextpage-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfc822MessageId, providerMessageId: providerMessageId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.armSpuriousNextPageTokenForTesting(rfc822MessageId: rfc822MessageId)

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let op = PendingOperation(type: .markRead, messageIds: [rfc822MessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(op.id, pool: pool) == nil, "a dangling nextPageToken is authoritative — the row leaves the queue as a no-op")
        let snapshot = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(snapshot.count == 1)
        guard snapshot.count == 1 else { return }
        #expect(snapshot[0].labels.contains("UNREAD"), "no mutation applies while a next page is (spuriously) claimed to exist")
    }

    /// GAP-4: the SOURCE-scoped variant of the deleted-label 400 (the list
    /// query's `labelIds` names a deleted label) — distinct from the
    /// already-covered DESTINATION variant in
    /// `gmailMoveToDeletedDestinationLabelSelfHealsAndLaterOpProceeds` (a
    /// `.move`'s destination). Here a plain `.markRead` is recorded against
    /// a SOURCE folder scope whose Gmail label was deleted remotely between
    /// enqueue and drain.
    @Test("Gmail markRead against a remotely deleted SOURCE label terminal-no-ops through the real drain, and a later op still proceeds")
    func gmailSourceScopedDeletedLabelTerminalNoOpsAndLaterOpProceeds() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gmail-gone-source-\(suffix)"
        let deletedLabelId = "Label_gone_source_\(suffix)"
        let rfc822MessageId = "gone-source-\(suffix)@example.com"
        let providerMessageId = "gmail-gone-source-\(suffix)"
        let otherRFC = "gone-source-other-\(suffix)@example.com"
        let otherProviderId = "gmail-gone-source-other-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfc822MessageId, providerMessageId: providerMessageId, labels: [deletedLabelId, "UNREAD"]),
            .init(rfc822MessageId: otherRFC, providerMessageId: otherProviderId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.markLabelDeleted(deletedLabelId)

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)

        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var staleOp = PendingOperation(
            type: .markRead, messageIds: [rfc822MessageId], accountId: accountId, folderPath: deletedLabelId
        )
        staleOp.createdAt = t0
        var laterOp = PendingOperation(
            type: .markRead, messageIds: [otherRFC], accountId: accountId, folderPath: "INBOX"
        )
        laterOp.createdAt = t0.addingTimeInterval(1)
        try insertOp(staleOp, pool: pool)
        try insertOp(laterOp, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == accountId).fetchCount(db)
        }
        #expect(remaining == 0, "the gone-source-label markRead terminal-no-ops and the later op completes")

        let untouched = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(untouched.count == 1)
        guard untouched.count == 1 else { return }
        #expect(untouched[0].labels.contains("UNREAD"), "the markRead never applied — the source scope is gone")

        let laterMessage = server.snapshots(rfc822MessageId: otherRFC)
        #expect(laterMessage.count == 1)
        guard laterMessage.count == 1 else { return }
        #expect(laterMessage[0].isRead, "the later markRead was not wedged behind the gone-source-label op")
    }

    /// GAP-9: another TabMail client moves the message (removes it from the
    /// recorded SOURCE label) between enqueue and drain. The queued
    /// markRead's source-scoped search then resolves ZERO refs —
    /// authoritative no-op. The message's remote read-state is left exactly
    /// as the "other client" left it; this test pins that queue/remote-state
    /// delta as the end state (an ordinary later sync reconciling any LOCAL
    /// optimistic flip is a separate mechanism, out of scope here).
    @Test("Gmail message moved by another client between enqueue and drain: markRead resolves zero refs, remote read-state unchanged, op completes as no-op")
    func gmailMovedByAnotherClientBetweenEnqueueAndDrain() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-gmail-moved-\(suffix)"
        let rfc822MessageId = "moved-\(suffix)@example.com"
        let providerMessageId = "gmail-moved-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfc822MessageId, providerMessageId: providerMessageId, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let op = PendingOperation(type: .markRead, messageIds: [rfc822MessageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(op, pool: pool)

        // "Another client" archives the message BEFORE this device drains its
        // queued markRead — a second, independent provider instance against
        // the SAME backing fixture state, exactly as a second real device
        // would hit the same Gmail account.
        let otherClientProvider = server.provider()
        try await otherClientProvider.move(ids: [rfc822MessageId], from: "INBOX", to: GmailProvider.archivePath)
        let movedAway = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(movedAway.count == 1)
        guard movedAway.count == 1 else { return }
        #expect(!movedAway[0].labels.contains("INBOX"), "setup: the other client's move must have actually left INBOX")

        try await withRegisteredProvider(accountId: accountId, provider: server.provider()) {
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try fetchOp(op.id, pool: pool) == nil, "zero refs in the now-stale source scope is authoritative — the row leaves the queue")
        let final = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(final.count == 1)
        guard final.count == 1 else { return }
        #expect(final[0].labels.contains("UNREAD"), "remote read-state is unchanged by the no-op'd markRead")
        #expect(!final[0].labels.contains("INBOX"), "the message stays wherever the other client left it")
    }

    // MARK: - Queue liveness/deadlock audit pins (2026-07)

    /// The STATIC liveness invariants — hold even while the queue is
    /// legitimately blocked on a not-yet-registered provider, mirrors
    /// `AccountManagerQueueLivenessTests`/`AccountManagerQueueDemotionTests`'
    /// copies (duplicated per-file by this suite family's convention).
    private func assertQueueLivenessInvariants(pool: DatabasePool) async throws {
        #expect(!AccountManager.shared.pendingOperationMutationGate.isHeldForTesting, "the mutation gate must not be leaked")
        #expect(AccountManager.shared.pendingOperationMutationGate.waiterCountForTesting == 0, "no waiter may be stranded")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(), "isDraining/needsRedrain must both be false")
        let inFlightCount = try await pool.read { db in
            try PendingOperation.filter(Column("status") == PendingStatus.inFlight.rawValue).fetchCount(db)
        }
        #expect(inFlightCount == 0, "no row may be left stranded inFlight")
    }

    /// Deadlock-audit item 7: an owner mid-drain requests a redrain, then
    /// loses the re-preparation race to an obsolete database swap WITHOUT a
    /// rescuing second redrain landing during the await — contrast with
    /// `ownerRetainsNewestDatabaseRedrainRequestAcrossObsoletePreparation`,
    /// which covers the RESCUE case (a third caller's redrain request lands
    /// during the obsolete flight's await, so the owner retries once more
    /// and succeeds within the same call). Here nothing rescues it: the
    /// owner's `repeat` loop legitimately gives up
    /// (`nextDatabase == nil && !needsRedrain`) and DROPS the redrain,
    /// returning with the newest database's op untouched. Pins that this
    /// drop is safe: static liveness invariants hold immediately after, and
    /// a later, wholly independent `drainPendingQueue()` call completes the
    /// leftover op.
    @Test("a dropped redrain after an obsolete re-preparation is safe: quiescent, no stranded state, and a later external drain completes the leftover op")
    func redrainDropOnFailedRepreparationIsRecoveredByALaterExternalDrain() async throws {
        let (firstPool, firstDir, firstPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: firstPool, previous: firstPrevious, dir: firstDir) }
        guard let firstDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("first test database was not installed")
            return
        }

        let (secondPool, secondDir, secondPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: secondPool, previous: secondPrevious, dir: secondDir) }
        guard let secondDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("second test database was not installed")
            return
        }

        let (thirdPool, thirdDir, thirdPrevious) = try await makeTestDB()
        defer { restoreTestDB(pool: thirdPool, previous: thirdPrevious, dir: thirdDir) }
        guard let thirdDatabase = AppDatabase.shared.withLock({ $0 }) else {
            Issue.record("third test database was not installed")
            return
        }
        AppDatabase.shared.withLock { $0 = firstDatabase }

        let suffix = UUID().uuidString.lowercased()
        let firstAccountId = "acc-redrain-drop-first-\(suffix)"
        let thirdAccountId = "acc-redrain-drop-third-\(suffix)"
        let firstMessageId = "redrain-drop-first-\(suffix)@example.com"
        let leftoverMessageId = "redrain-drop-leftover-\(suffix)@example.com"

        let firstProviderGate = QueuePreparationTestGate()
        let secondPreparationGate = QueuePreparationTestGate()
        let firstProvider = MockEmailProvider()
        await firstProvider.setMarkReadHook {
            await firstProviderGate.arriveAndWaitForRelease()
        }
        let leftoverProvider = MockEmailProvider()

        let firstOperation = PendingOperation(
            type: .markRead, messageIds: [firstMessageId], accountId: firstAccountId, folderPath: "INBOX"
        )
        let leftoverOperation = PendingOperation(
            type: .markRead, messageIds: [leftoverMessageId], accountId: thirdAccountId, folderPath: "INBOX"
        )
        try insertOp(firstOperation, pool: firstPool)
        try insertOp(leftoverOperation, pool: thirdPool)

        await AccountManager.shared.registerProviderForTesting(accountId: firstAccountId, provider: firstProvider)
        await AccountManager.shared.registerProviderForTesting(accountId: thirdAccountId, provider: leftoverProvider)

        let owner = Task { await AccountManager.shared.drainPendingQueue() }
        var redrainCaller: Task<Void, Never>?
        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await firstProviderGate.waitUntilArrival()
            }

            // Ask the active owner for another pass while A is still current
            // — this is the ONE redrain request this test grants. Unlike the
            // rescue-case sibling test, no SECOND redrain lands later.
            let redrain = Task { await AccountManager.shared.drainPendingQueue() }
            redrainCaller = redrain
            try await joinDrainTask(redrain)
            #expect(await AccountManager.shared.needsRedrain)

            AppDatabase.shared.withLock { $0 = secondDatabase }
            // Hold database B's preparation flight open so it can be swapped
            // out from under the owner before it resolves.
            await AccountManager.shared.setPendingQueuePreparationHookForTesting {
                await secondPreparationGate.arriveAndWaitForRelease()
            }

            await firstProviderGate.releaseAll()
            try await waitForPreparationParticipants(1)

            // Swap to C WITHOUT any further redrain request landing — this is
            // the "drop": B's flight will resolve `.success` but obsolete,
            // and `needsRedrain` stays false, so the owner's repeat loop
            // gives up instead of retrying.
            AppDatabase.shared.withLock { $0 = thirdDatabase }
            // C's own (future, separate) flight must not block — clear the
            // hook now so it never captures it.
            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            await secondPreparationGate.releaseAll()

            try await joinDrainTask(owner)

            // The drop: the owner returned WITHOUT ever draining C's leftover op.
            #expect(try fetchOp(leftoverOperation.id, pool: thirdPool) != nil, "the leftover op is genuinely dropped by this drain call")
            #expect(await leftoverProvider.markedReadIds.isEmpty)

            try await assertQueueLivenessInvariants(pool: thirdPool)

            // A later, wholly independent external drain call picks the
            // leftover op back up and completes it.
            await AccountManager.shared.drainPendingQueue()
            #expect(try fetchOp(leftoverOperation.id, pool: thirdPool) == nil, "a later external drain completes the leftover op")
            #expect(await leftoverProvider.markedReadIds.contains { $0.ids == [leftoverMessageId] })
            try await assertQueueLivenessInvariants(pool: thirdPool)
        } catch {
            owner.cancel()
            redrainCaller?.cancel()
            await AccountManager.shared.setPendingQueuePreparationHookForTesting(nil)
            await firstProviderGate.releaseAll()
            await secondPreparationGate.releaseAll()
            try? await joinDrainTask(owner)
            if let redrainCaller { try? await joinDrainTask(redrainCaller) }
            await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
            await AccountManager.shared.unregisterProviderForTesting(accountId: thirdAccountId)
            throw error
        }

        await AccountManager.shared.unregisterProviderForTesting(accountId: firstAccountId)
        await AccountManager.shared.unregisterProviderForTesting(accountId: thirdAccountId)
    }

    /// Deadlock-audit item 9: pins that every DB write executed WHILE
    /// `pendingOperationMutationGate.isHeldForTesting` is true runs at
    /// `.priority` tier — "gated writes can never park behind the merge's
    /// privileged section" (the `DatabaseWriteQueue`/`PriorityGate` ADR).
    /// Drives the real drain loop's two gated write call sites
    /// (`claimFrontierOperation`'s claim write, `retryGatedQueueWrite`'s
    /// completion write) through `DatabaseWriteQueue.shared`'s test
    /// observer, sampling `pendingOperationMutationGate.isHeldForTesting`
    /// synchronously at the moment each write starts (the observer fires
    /// from inside `execute(priority:)`, which is itself invoked from
    /// inside `database.write`, which both call sites invoke ONLY while
    /// still holding the gate's lease — see both functions' `defer { ...
    /// release(lease) }` placement).
    @Test("every DB write that runs while the pending-operation mutation gate is held executes at .priority tier")
    func gatedWritesAlwaysRunAtPriorityTier() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-tier-\(suffix)"
        let messageId = "tier-\(suffix)@example.com"
        let provider = MockEmailProvider()

        let recorded = Mutex<[(priority: WritePriority, gateHeld: Bool)]>([])
        await DatabaseWriteQueue.shared.setTestObserverForTesting { priority, _ in
            let gateHeld = AccountManager.shared.pendingOperationMutationGate.isHeldForTesting
            recorded.withLock { $0.append((priority, gateHeld)) }
        }

        let operation = PendingOperation(type: .markRead, messageIds: [messageId], accountId: accountId, folderPath: "INBOX")
        try insertOp(operation, pool: pool)

        do {
            try await withRegisteredProvider(accountId: accountId, provider: provider) {
                await AccountManager.shared.drainPendingQueue()
            }
        } catch {
            await DatabaseWriteQueue.shared.setTestObserverForTesting(nil)
            throw error
        }
        await DatabaseWriteQueue.shared.setTestObserverForTesting(nil)

        #expect(try fetchOp(operation.id, pool: pool) == nil, "sanity: the op actually drained")

        let entries = recorded.withLock { $0 }
        #expect(!entries.isEmpty, "the drain must have produced at least one observed write")
        let gatedEntries = entries.filter { $0.gateHeld }
        #expect(!gatedEntries.isEmpty, "at least one write (claim or completion) must have run while the gate was held")
        for entry in gatedEntries {
            #expect(entry.priority == .priority, "a write observed while the gate is held must be .priority tier, was \(entry.priority)")
        }
    }
}
