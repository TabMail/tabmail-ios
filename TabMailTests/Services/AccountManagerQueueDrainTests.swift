/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
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

    @Test("OAuth reconnect never strands a claimed MOVE without a wire attempt")
    func reconnectPreservesClaimedMoveAdmission() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let accountId = "reconnect-claimed-move"
        try insertStableProviderFixture(accountId: accountId, pool: pool)
        var account = Account(
            emailAddress: "\(accountId)@example.com",
            displayName: "Reconnect",
            provider: .gmail
        )
        account.id = accountId

        var claimed = PendingOperation(
            type: .move,
            messageIds: ["claimed-message"],
            accountId: accountId,
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        claimed.status = PendingStatus.inFlight.rawValue
        claimed.everAttempted = true
        try insertOp(claimed, pool: pool)
        let claimedSnapshot = claimed

        let provider = MockEmailProvider()
        await provider.setMoveThrows(
            ProviderError.networkError(underlying: URLError(.notConnectedToInternet))
        )
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)
        await AccountManager.shared.installReconnectQueueTestRuntime(
            accountId: accountId,
            provider: provider,
            queue: queue
        )

        let gate = ReconnectWorkGate()
        let blocker = Task {
            await queue.execute(priority: .bodyFetch) { await gate.hold() }
        }
        await gate.waitUntilHeld()

        let queuedDrain = Task {
            await queue.execute(priority: .userAction) {
                _ = await AccountManager.shared.executeSingleOp(
                    claimedSnapshot,
                    provider: provider,
                    context: AccountManager.DrainContext()
                )
            }
        }
        for _ in 0..<1_000 {
            if await queue.waitingCount == 1 { break }
            await Task.yield()
        }
        #expect(await queue.waitingCount == 1, "the claimed MOVE must be waiting when reconnect detaches runtime state")

        // Re-authentication uses the nil `deletingCredentials` path. It may
        // detach the old queue from AccountManager, but must not invalidate the
        // captured drain closure: ordinary provider failure requeues the claim.
        await AccountManager.shared.disconnectAccount(account)
        await gate.release()
        await blocker.value
        await queuedDrain.value

        let after = try fetchOp(claimedSnapshot.id, pool: pool)
        #expect(after?.status == PendingStatus.queued.rawValue)
        #expect(after?.everAttempted == true)
        #expect(await provider.movedIds.count == 1, "reconnect must not skip the claimed MOVE's provider attempt")
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

    @Test("reconcilePendingOperations: ordinary inFlight retries, attempted MOVE is dropped, cancelled deletes")
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
        var uncertainMove = PendingOperation(
            type: .move,
            messageIds: ["msg-move"],
            accountId: "acc-gap1",
            folderPath: "INBOX",
            destinationPath: "Archive")
        uncertainMove.status = PendingStatus.inFlight.rawValue
        uncertainMove.everAttempted = true
        var preEmissionMove = PendingOperation(
            type: .move,
            messageIds: ["msg-prewire"],
            accountId: "acc-gap1",
            folderPath: "INBOX",
            destinationPath: "Archive")
        preEmissionMove.status = PendingStatus.inFlight.rawValue
        preEmissionMove.everAttempted = false
        let queuedOp = PendingOperation(type: .markFlagged, messageIds: ["msg-queued"], accountId: "acc-gap1", folderPath: "INBOX")
        try insertOp(inFlightOp, pool: pool)
        try insertOp(cancelledOp, pool: pool)
        try insertOp(uncertainMove, pool: pool)
        try insertOp(preEmissionMove, pool: pool)
        try insertOp(queuedOp, pool: pool)

        await AccountManager.shared.reconcilePendingOperations()

        let remaining = try await pool.read { db in
            try PendingOperation.filter(Column("accountId") == "acc-gap1").fetchAll(db)
        }
        #expect(remaining.count == 3)

        let inFlightAfter = try fetchOp(inFlightOp.id, pool: pool)
        #expect(inFlightAfter != nil, "inFlight op must survive (reset, not dropped)")
        #expect(inFlightAfter?.status == PendingStatus.queued.rawValue, "inFlight op reset to queued by crash recovery")

        let cancelledAfter = try fetchOp(cancelledOp.id, pool: pool)
        #expect(cancelledAfter == nil, "cancelled op deleted by crash recovery")

        let uncertainMoveAfter = try fetchOp(uncertainMove.id, pool: pool)
        #expect(uncertainMoveAfter == nil, "an attempted MOVE with an unknown provider outcome must never be replayed")

        let preEmissionMoveAfter = try fetchOp(preEmissionMove.id, pool: pool)
        #expect(preEmissionMoveAfter?.status == PendingStatus.queued.rawValue,
                "a MOVE with no persisted attempt evidence remains retryable")

        let queuedAfter = try fetchOp(queuedOp.id, pool: pool)
        #expect(queuedAfter != nil, "already-queued op must survive untouched")
        #expect(queuedAfter?.status == PendingStatus.queued.rawValue, "already-queued op untouched")
        #expect(queuedAfter?.retryCount == 0, "untouched op's retryCount is unaffected")
    }

    // MARK: - 8b. Launch crash recovery for the draft push's own in-flight state

    /// THE INVARIANT: a draft push interrupted by a CRASH must be admissible again
    /// after the launch reconciliation — the durable `.saveDraft` producer is not
    /// retired by an attempt that never completed.
    ///
    /// The hole this pins. `DraftStore.performStageA` durably commits
    /// `serverPushStatus = "pushing"` in its own transaction BEFORE the provider
    /// call; the Stage-A CAS admits only `nil` or `"dirty"` (unchanged — the push
    /// ENTRY additionally re-admits claim-proven residue, but that is a different
    /// layer and not what this test probes); and
    /// `.notApplied` is a NORMAL return, so `executeOperation`'s `.saveDraft` arm
    /// falls through to `.allMembers` and `executeSingleOp` DELETES the
    /// `PendingOperation`. A jetsam / force-quit / `0xdead10cc` kill in the network
    /// window leaves no process alive to run the in-process clear-arms at all, and
    /// an interrupted attempt is an UNKNOWN, which never-drop clause 2 makes
    /// retryable. Both sibling queues sweep their own in-flight state
    /// (`PendingOperation.inFlight` → this very function; `OutboxMessage.sending` →
    /// `performOutboxReconciliation`); the draft push was the one that did not.
    ///
    /// 🚨 CORRECTED 2026-08-06. This paragraph used to open *"The in-process failure
    /// arms DO clear `"pushing"`"* — unqualified — which is what made a crash look
    /// like the only producer of residue. Those arms clear it only when their own DB
    /// write succeeds; when it throws, the row is left `"pushing"` inside a live
    /// process. That case is NOT this test's subject and is not fixed here: it is
    /// closed inside `pushDraftToServer` by a per-draft in-process claim, and pinned
    /// by `NeverDropExitClosureTests.inProcessPushingResidueNeverRetiresItsSaveProducer`.
    ///
    /// ASSERTED THROUGH THE PRODUCTION ADMISSION DECISION, not the column: the
    /// oracle is whether `performStageA` — the same CAS `pushDraftToServer` runs —
    /// admits a fresh attempt. A reimplementation that cleared the state to `nil`
    /// instead of `"dirty"`, or moved the reset elsewhere, still passes; a system
    /// where the producer stays wedged still fails. Asserting `== "dirty"` would be
    /// the mechanism (`MIS-015`).
    ///
    /// TWO-SIDED on one fixture: the pre-sweep half proves the row really is stuck
    /// (so the post-sweep half is not a trivially-admissible empty case).
    @Test("A draft push orphaned by a crash is re-admitted at launch — the durable Save producer is not retired")
    func launchReconciliationReAdmitsAnOrphanedDraftPush() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let accountId = "acc-orphan-push"
        let draftId = "draft-orphaned-push"
        let epoch = "E1"
        try await pool.write { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Orphan",
                provider: .gmail)
            account.id = accountId
            try account.insert(db)
            var draft = Draft(
                id: draftId, accountId: accountId, toJSON: "[\"to@example.com\"]",
                ccJSON: "[]", bccJSON: "[]", subject: "subject", body: "body",
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: 1, updatedAt: 1)
            draft.instanceEpoch = epoch
            // Exactly what Stage A commits before the provider call.
            draft.serverPushStatus = "pushing"
            draft.pushAttemptVersion = 1
            draft.rfc822MessageId = "draft-interrupted@example.com"
            try draft.insert(db)
        }

        /// Does a fresh push attempt get admitted? Runs the real Stage-A CAS. A
        /// refused attempt writes nothing, so the pre-sweep probe is side-effect
        /// free.
        func admitsAFreshPushAttempt(_ rfc: String) async throws -> Bool {
            try await pool.write { db in
                guard let current = try Draft.fetchOne(db, key: draftId) else { return false }
                return try DraftStore.performStageA(
                    initialDraft: current,
                    expectedInstanceEpoch: epoch,
                    previousIdentity: nil,
                    freshRfc: rfc,
                    db: db) != nil
            }
        }

        // THE WEDGE, before the sweep: the Stage-A CAS refuses a `"pushing"` row
        // outright, so nothing this probe can do admits a fresh attempt.
        //
        // 🚨 CORRECTED 2026-08-06. This used to add *"Nothing else in the tree clears
        // `"pushing"` except an authored edit via `applySave`'s remap."* That is no
        // longer true: `pushDraftToServer` re-admits provably-orphaned residue via
        // `DraftStore.reAdmitOrphanedPushingDraft`, authorised by an in-process
        // claim. This probe deliberately calls `performStageA` DIRECTLY — the CAS,
        // not the push entry — so it holds no claim and the assertion below still
        // describes the Stage-A layer this test is about.
        #expect(try await admitsAFreshPushAttempt("draft-retry-a@example.com") == false,
                "fixture must start wedged, or the post-sweep half proves nothing")

        await AccountManager.shared.reconcilePendingOperations()

        // THE INVARIANT: the intention survives the crash — the next drain can push.
        #expect(try await admitsAFreshPushAttempt("draft-retry-b@example.com") == true,
                "a push interrupted by a crash must be retryable after launch recovery")
    }

    // MARK: - 9. GAP2: MockEmailProvider.setMoveThrowsOnId — partial-batch progress + requeue-then-retry

    @Test("Batch move [A,B,C] fails on B via a generic connection error (ProviderError.notConnected): the WHOLE op resets to queued (not split), retryCount+1, failedAccounts marked, movedIds shows only the successful prefix [A] — a cleared retry then completes the op")
    func batchMoveGenericFailureHaltsWholeOpThenRetrySucceeds() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // The Archive folder exists locally because the scenario under test is
        // an ordinary move to a real destination.
        //
        // ⚑ HISTORICAL NOTE (audit round 1, finding A-5): this used to say the
        // folder was required, because `executeSingleOp`'s generic-error branch
        // DELETED the op when the destination was merely absent from local GRDB.
        // That branch is gone — local absence is not provider authority, so a
        // missing destination row now leaves the op queued like any other
        // undetermined outcome. The folder is still created here to keep this
        // test about the requeue-then-retry path and nothing else.
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
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
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
    }

    // MARK: - 10b. IOS-QUEUE-008: same provider RESOURCE, two folder paths

    /// THE SYSTEM PROPERTY: two queued operations that name the same provider
    /// RESOURCE never execute concurrently and execute in `createdAt` (issue)
    /// order. On Gmail/Graph a message id is folder-INDEPENDENT, so "same
    /// resource" is `(account, id)` — the folder is not part of the address.
    ///
    /// The gesture that produced this (delete → undo ≈2s later → delete again
    /// ≈1s later, one Gmail message): undo enqueues the INVERSE move, whose
    /// source is by construction the forward op's DESTINATION, so the queue held
    /// `TRASH→INBOX` at t0 and `INBOX→TRASH` at t0+1 while ONE drain pass fetched
    /// both. A folder-qualified lane key put them in different connected
    /// components, `drainPendingQueue` launches one Task per lane concurrently,
    /// the inverse finished LAST, and Gmail kept the message in INBOX while the
    /// local row said TRASH — both ops retiring as provider successes, so the
    /// next full sync re-inserted the row the user had deleted.
    ///
    /// The oracle is the wire itself, in both directions: the move hook counts
    /// concurrent entries into `move` and sleeps long enough that a genuinely
    /// parallel pair must be seen as parallel, so a regression cannot pass by
    /// timing luck, and a serialized pair cannot fail by it either.
    @Test("drainPendingQueue() (real): on a stable-id account, an undo inverse and a re-delete of the same message never overlap on the wire and run in issue order")
    func drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-stable-id-same-message"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            try insertStableProviderFixture(accountId: accountId, pool: pool)
            // The inverse op's SOURCE folder — `optimisticMoveToFolder` restored
            // the row to the destination of the op it undid, so the inverse is
            // addressed from TRASH and needs that folder row to exist.
            try await pool.writeWithoutTransaction { db in
                try Folder(name: "TRASH", path: "TRASH", role: .trash, accountId: accountId).insert(db)
            }

            // Dynamic (repo rule: no hardcoded dates); whole-second so the GRDB
            // date round-trip compares exactly.
            let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
            // The undo's inverse: restore the message the delete moved to TRASH.
            var opInverse = PendingOperation(
                type: .move, messageIds: ["m1"], accountId: accountId,
                folderPath: "TRASH", destinationPath: "INBOX")
            opInverse.createdAt = t0
            // The user's NEWEST intention: delete it again.
            var opRedelete = PendingOperation(
                type: .move, messageIds: ["m1"], accountId: accountId,
                folderPath: "INBOX", destinationPath: "TRASH")
            opRedelete.createdAt = t0.addingTimeInterval(1)
            try insertOp(opInverse, pool: pool)
            try insertOp(opRedelete, pool: pool)

            let wire = Mutex<(inFlight: Int, overlapped: Bool)>((inFlight: 0, overlapped: false))
            await provider.setMoveHook {
                wire.withLock { state in
                    state.inFlight += 1
                    if state.inFlight > 1 { state.overlapped = true }
                }
                // Long enough that a second, genuinely concurrent `move` is
                // observed inside this window rather than after it.
                try? await Task.sleep(for: .milliseconds(250))
                wire.withLock { $0.inFlight -= 1 }
            }

            await AccountManager.shared.drainPendingQueue()

            let overlapped = wire.withLock { $0.overlapped }
            #expect(!overlapped,
                    "two ops on the same Gmail message executed concurrently; the later one can land first and undo the user's newest intention")

            let allMoves = await provider.movedIds
            let m1Moves = allMoves.filter { $0.ids.contains("m1") }
            let landed = m1Moves.map { "\($0.from)→\($0.to)" }
            #expect(m1Moves.count == 2,
                    "both moves must have reached the provider, got \(landed)")
            guard m1Moves.count == 2 else { return }
            #expect(landed == ["TRASH→INBOX", "INBOX→TRASH"],
                    "the two moves must land on the wire in createdAt (issue) order, got \(landed)")
            #expect(m1Moves[1].to == "TRASH",
                    "the user's LATEST destination must be the one that wins on the wire, got \(m1Moves[1].to)")

            let remaining = try await pool.read { db in
                try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
            }
            #expect(remaining.isEmpty, "both ops executed (deleted)")
        }
    }

    @Test("drainPendingQueue() (real): a generic connection error on the first same-lane op gates the rest of the lane — all remaining ops in that lane are requeued, none execute")
    func drainPendingQueueRealFirstOpFailureGatesRestOfLane() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gap3-failure"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.notConnected)
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
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
    }

    @Test("drainPendingQueue() (real): two concurrent calls are safe — the isDraining/needsRedrain guard serializes them, the op executes exactly once (no duplication, no crash)")
    func drainPendingQueueRealConcurrentCallsExecuteOpsExactlyOnce() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gap3-reentrant"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
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

    // MARK: - T3.5 / T4.H1 coupling — a body-preserving Gmail action 400 is still terminal
    //
    // `GmailProvider.modifyMessage` now issues its POST through
    // `AuthedHTTP.requestPreservingBadRequestBody`, so a final 400 arrives as
    // `HTTPError.networkErrorWithBody(400, body)` rather than the bodyless
    // `.networkError(400)`. `AccountManager.isPermanentlyInvalidError` was
    // widened in the same change to classify the two identically.
    //
    // 🚨 CORRECTED (audit round 1, finding B-3). The first of these tests used
    // to assert the OPPOSITE — that an UNCLASSIFIED Gmail action 400 is
    // TERMINAL — and it was the test blessing the defect. Its premise was that
    // a bare status code plus "the body was preserved" is a classification. It
    // is not. `isPermanentlyInvalidError` bound the body to `_` and retired the
    // op on the STATUS alone, so `"Precondition check failed."` — a
    // `failedPrecondition` a retry can resolve — destroyed the user's action
    // exactly as if Gmail had said the id was never valid.
    //
    // The three tests now pin the SYSTEM property along the axis that actually
    // decides it — whether the provider issued an AUTHORITATIVE rejection —
    // and the durable row's END STATE is the observable:
    //
    //   * a STRUCTURALLY RECOGNISED authoritative 400 ("Invalid id value …",
    //     `reason == invalidArgument`) is TERMINAL: the row is gone. Exit 2.
    //   * an UNCLASSIFIED 400 is NOT: we could not determine the answer, which
    //     is not an exit. The row survives, queued.
    //   * a transient 503 is NOT: the row survives, queued.
    //
    // RED PROOF for the unclassified case, recorded: with
    // `isPermanentlyInvalidError`'s pre-fix bare-status arms restored
    // (`case .networkError(400), .networkErrorWithBody(400, _): return true`),
    // `unclassifiedGmailActionBadRequestKeepsTheDurableOpQueued` fails at
    // `after != nil` — the row is nil, the intention destroyed — and its
    // `outcome == .haltLane` expectation fails with `.proceed`.
    //
    // NON-VACUITY is two-sided and DURABLE + WIRE on every one of the three:
    // each asserts both the row's end state and that its injected response was
    // genuinely consumed at the HTTP boundary, so a row that survived because
    // the provider was never reached cannot pass.

    @Test("real GmailProvider: an UNCLASSIFIED action 400 is NOT terminal — the durable op row survives, queued for retry")
    func unclassifiedGmailActionBadRequestKeepsTheDurableOpQueued() async throws {
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

        #expect(outcome == .haltLane)
        let after = try fetchOp(op.id, pool: pool)
        #expect(
            after != nil,
            "an unrecognised 400 is an absence of evidence, not the provider telling us the work is moot — it must not retire the user's intention"
        )
        guard let after else { return }
        #expect(after.status == PendingStatus.queued.rawValue)
        #expect(after.retryCount == op.retryCount + 1)
        #expect(
            server.unclassified400ServedCount() == 1,
            "the injected unclassified 400 must have been served exactly once: \(server.unclassified400ServedCount())"
        )
    }

    @Test("real GmailProvider: a STRUCTURALLY RECOGNISED invalid-id 400 IS terminal — the durable op row is deleted")
    func authoritativeGmailInvalidIdRejectionRetiresTheDurableOp() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-gmail-invalid-id-400"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let providerMessageId = "gmail-queue-invalid-id-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-queue-invalid-id@example.com",
            providerMessageId: providerMessageId,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        // Gmail's real body: reason `invalidArgument`, message
        // `"Invalid id value <id>"` — the provider stating authoritatively that
        // this address can never name a message. Exit 2.
        server.injectInvalidId400OnModify(providerMessageId: providerMessageId)

        try insertStableProviderFixture(accountId: accountId, pool: pool)
        let op = PendingOperation(
            type: .markRead, messageIds: [providerMessageId],
            accountId: accountId, folderPath: "INBOX"
        )
        try insertOp(op, pool: pool)

        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: server.provider(), context: AccountManager.DrainContext()
        )

        // The NON-VACUITY partner of the unclassified test: if the fix had
        // narrowed the classifier to nothing, this row would survive too and
        // the pair would stop distinguishing anything.
        #expect(outcome == .proceed)
        let after = try fetchOp(op.id, pool: pool)
        #expect(
            after == nil,
            "an authoritative provider rejection of the address itself must retire the op rather than retry it forever"
        )
        #expect(
            server.invalidId400OnModifyServedCount() == 1,
            "the injected invalid-id 400 must have been served exactly once: \(server.invalidId400OnModifyServedCount())"
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

private actor ReconnectWorkGate {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        held = true
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension AccountManager {
    func installReconnectQueueTestRuntime(
        accountId: String,
        provider: any EmailProvider,
        queue: ProviderWorkQueue
    ) {
        providers[accountId] = provider
        workQueues[accountId] = queue
    }
}
