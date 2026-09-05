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
    ///
    /// `provider` defaults to `.gmail` — every pre-existing caller. A3.1 adds a
    /// second account-scoped-id shape (the demo account, whose row is stored
    /// `.imap` but admitted into `AccountManager.accountScopedIdAccountIds` BY ID), so a
    /// caller that needs to pin that classification passes it explicitly instead
    /// of this file growing a near-duplicate helper.
    private func insertStableProviderFixture(
        accountId: String, pool: DatabasePool, provider: AccountProvider = .gmail
    ) throws {
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "GAP3", provider: provider)
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
    ///
    /// A3.1: parameterized over EVERY way `AccountManager.accountScopedIdAccountIds`
    /// admits an account into the account-qualified lane space. It admits an id
    /// two ways — by PROVIDER (`provider == .gmail`) and by ID
    /// (`DemoSeed.demoAccountId`, whose row is nonetheless stored `.imap`). A
    /// term-by-term mutation of either — deleting the demo-id arm, or narrowing
    /// the provider arm — must show up as a wire-order/overlap failure on the
    /// affected case and nowhere else. The pure `buildLanes` unit tests in
    /// `PendingQueueLaneTests` inject the set directly, so they cannot see a
    /// defect in how the drain COMPUTES it; only a real-drain fixture per
    /// classification can.
    ///
    /// 🚨 THE OUTLOOK CASE IS NOT HERE, AND ITS ABSENCE IS NOT AN OPINION ABOUT
    /// GRAPH. Graph reallocates a message's id on every move (`IOS-GRAPH-002` —
    /// this tree sends no `Prefer: IdType="ImmutableId"`), so a serialized Graph
    /// follower is only safe because `finishMove` readdresses it in the same
    /// transaction that retires the move (`IOS-GRAPH-005`). That property needs a
    /// churning Graph server to be worth asserting, and this fixture's mock
    /// provider does not churn — so Outlook's real-drain coverage lives in
    /// `OutlookQueueHandoffTests` (T1/T2) against `StatefulExchangeActionServer`
    /// with `churnsIdOnMove: true`, not here. What this suite still owns is the
    /// two ADMISSION SHAPES, by provider and by id. Membership itself is pinned
    /// as an exact set by
    /// `accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`.
    // Not `private`: it is the parameter type of a `@Test(arguments:)` function,
    // and Swift requires a method to be at least as accessible as its parameter
    // types. It stays scoped by being nested in this suite.
    struct StableIdAccountCase: CustomStringConvertible, Sendable {
        let label: String
        let accountId: String
        /// What is written to the `account.provider` column. For the demo case
        /// this is deliberately `.imap` — the classifier admits it BY ID, not by
        /// provider, so the fixture must prove the admission holds even though
        /// the stored provider alone would say "folder-qualified".
        let dbProvider: AccountProvider
        var description: String { label }
    }

    private static let stableIdAccountCases: [StableIdAccountCase] = [
        StableIdAccountCase(
            label: "gmail", accountId: "acc-stable-id-same-message-gmail", dbProvider: .gmail),
        StableIdAccountCase(
            label: "demo (row stored .imap, admitted by DemoSeed.demoAccountId)",
            accountId: DemoSeed.demoAccountId, dbProvider: .imap),
    ]

    /// The classifier, tested DIRECTLY against real `account` rows — every
    /// provider at once, in one call, asserted as an EXACT set.
    ///
    /// Why this exists in addition to the real-drain parameterization: a drain
    /// fixture can only show that the account it seeds is classified correctly.
    /// It is structurally blind to an account it does not seed, so "`.icloud` was
    /// quietly admitted" is invisible to every drain test — and admitting an
    /// account whose ids are FOLDER-LOCAL is the mutation whose consequence is a
    /// wrong-message mutation or a starved bystander (`IOS-QUEUE-001`): UID 77 in
    /// `INBOX` and UID 77 in `Archive` would share one lane despite being
    /// different physical messages. An exact-set oracle over rows for every
    /// provider is the only shape that can fail on an account the test author did
    /// not think to seed.
    ///
    /// ⚠️ Outlook's membership is load-bearing in the OTHER direction and is
    /// asserted here positively: Graph ids are account-scoped, and since the
    /// retirement handoff exists (`IOS-GRAPH-005`) the account-qualified lane is
    /// what makes an undo inverse and a re-delete of one message serialize
    /// instead of race. Dropping Outlook back out of the set is the mutation this
    /// leg catches; before 2026-09-04 the same assertion ran with the opposite
    /// sign (`IOS-QUEUE-008`'s amendment records the supersession).
    ///
    /// The unknown-provider row is not decoration either: it pins that the
    /// classifier reads the RAW `provider` column rather than decoding
    /// `AccountProvider`, so one corrupt bystander row cannot throw the whole
    /// snapshot (`DecodingError.dataCorrupted`) and wedge every account's drain.
    @Test("AccountManager.accountScopedIdAccountIds admits Gmail, Outlook and the demo account and NOTHING else — not IMAP, not iCloud, not an undecodable provider string")
    func accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let gmailId = "acc-classifier-gmail"
        let outlookId = "acc-classifier-outlook"
        let imapId = "acc-classifier-imap"
        let icloudId = "acc-classifier-icloud"
        let unknownId = "acc-classifier-unknown"

        try await pool.writeWithoutTransaction { db in
            for (id, provider) in [
                (gmailId, AccountProvider.gmail),
                (outlookId, .outlook),
                (imapId, .imap),
                (icloudId, .icloud),
                // The demo account's row is stored `.imap` ON PURPOSE — it is
                // admitted BY ID, and a fixture that stored it as `.gmail` would
                // pass even if the demo-id arm were deleted.
                (DemoSeed.demoAccountId, .imap),
                // Inserted as a decodable provider, then corrupted by raw SQL —
                // `Account` cannot ENCODE a string its enum does not have.
                (unknownId, .gmail),
            ] {
                var account = Account(
                    emailAddress: "\(id)@example.com", displayName: id, provider: provider)
                account.id = id
                try account.insert(db)
            }
            try db.execute(
                sql: "UPDATE account SET provider = ? WHERE id = ?",
                arguments: ["future-provider", unknownId])
        }

        // Non-vacuity for the corrupt row: decoding whole `Account` rows really
        // does throw here, so the classifier's id-only query is doing work a
        // naive `Account.fetchAll(db)` could not.
        let wholeRowDecodeThrows = try await pool.read { db -> Bool in
            do {
                _ = try Account.fetchAll(db)
                return false
            } catch {
                return true
            }
        }
        #expect(wholeRowDecodeThrows,
                "fixture is not exercising the corrupt-row path — Account.fetchAll decoded cleanly")

        let classified = try await pool.read { db in
            try AccountManager.accountScopedIdAccountIds(db)
        }

        #expect(classified == [gmailId, outlookId, DemoSeed.demoAccountId], """
            accountScopedIdAccountIds must be EXACTLY {gmail, outlook, demo}.
            observed: \(classified.sorted())
            outlook admitted: \(classified.contains(outlookId)) \
            (must be true — the retirement handoff is what makes the \
            account-qualified lane correct for Graph; see IOS-GRAPH-005)
            imap admitted: \(classified.contains(imapId)) \
            (must be false — an IMAP UID is mailbox-local; see IOS-QUEUE-001)
            icloud admitted: \(classified.contains(icloudId))
            undecodable admitted: \(classified.contains(unknownId))
            """)
    }

    @Test("drainPendingQueue() (real): on an account-scoped-id account, an undo inverse and a re-delete of the same message never overlap on the wire and run in issue order",
          arguments: stableIdAccountCases)
    func drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder(
        accountCase: StableIdAccountCase
    ) async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = accountCase.accountId
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            try insertStableProviderFixture(
                accountId: accountId, pool: pool, provider: accountCase.dbProvider)
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

    // MARK: - 10c. IOS-QUEUE-008: the exported log has to be able to answer it

    /// The MESSAGE half of every entry in a `read(channel: .queue)` result —
    /// `[<ISO8601>] [QUEUE] ` stripped — so an assertion can compare EXACT text
    /// without depending on a timestamp. A physical line with no entry head is
    /// dropped: no `.queue` writer emits a continuation line, and treating one as
    /// an entry would make an exact-list assertion depend on text that is not one.
    private static func queueEntryMessages(in log: String) -> [String] {
        let head = "] [\(AppLogChannel.queue.tag)] "
        return log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.hasPrefix("["), let range = line.range(of: head) else { return nil }
            return String(line[range.upperBound...])
        }
    }

    /// The lane-composition line and the per-op drain lines, in append order.
    ///
    /// Deliberately narrower than "every `.queue` entry": other entries in the
    /// same read legitimately name an op id too
    /// (`[MoveTrace] executeOperation.move … opId=`, `[MoveTrace] entered inbox …
    /// op <id>`), and this artifact is about the lane/order decision, not about
    /// those. Prefix-anchored so `[Queue] Draining N ops:` — a different line
    /// that also starts `[Queue] D` — cannot drift into the set.
    private static func laneOrderEntries(in log: String) -> [String] {
        queueEntryMessages(in: log).filter {
            $0.hasPrefix("[Queue] Lanes: ") || $0.hasPrefix("[Queue] drain lane ")
        }
    }

    /// THE INVARIANT: the wire order of the drain is RECONSTRUCTIBLE from the
    /// exported log. Not "the formatter renders this string" — what
    /// `IOS-QUEUE-008` actually needed, and could not get, was an artifact that
    /// answers *which lane did each op land in, and in what order did they go
    /// out*. `print` alone could never answer it (no `freopen`/`dup2` in this
    /// tree, so `stdout` is unreachable on a device) and neither could an
    /// instrumentation whose gate is never open.
    ///
    /// Measured at `4f9bd4bbc`, before this test existed: the `queueLog` body had
    /// **0 hits across 1,310 calls** on the whole suite, and both per-op drain
    /// lines had 0. No test flipped `DebugModeManager.loggingEnabledOverrideForTesting`,
    /// and the real gate is always false in the test host (no unlock flag, no
    /// session), so the instrumentation whose entire purpose is this artifact had
    /// never once been executed.
    ///
    /// Two-sided on purpose: the same drain writes NOTHING to the channel while
    /// the gate is closed. Without that half, a writer that had been accidentally
    /// hard-enabled would satisfy the first half and look correct.
    ///
    /// A third phase, between the two, arms a RETRYABLE provider fault so the lane
    /// HALTS: `outcome=haltLane` is the instrument's only positive statement that a
    /// lane stopped, and an all-succeed phase can never observe it — replacing that
    /// interpolation with the literal `outcome=proceed` left every test in the tree
    /// green while the exported log would describe a halted lane as one that kept
    /// draining. A debug instrument may miss a line, but it must not lie.
    @Test("drainPendingQueue() (real): with debug logging unlocked, the exported QUEUE channel reconstructs the lane composition and the per-op wire order — and stays silent when it is locked")
    func drainLaneInstrumentationIsReadableFromTheExportedLog() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let accountId = "acc-queue-log-lane-order"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // Redirect the single app log at a temp file of its own, and force the
        // runtime debug gate, for the duration of this test. Both are
        // process-global seams — hence `.serialized, .processGlobalState` on this
        // suite — and both are restored unconditionally.
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            try insertStableProviderFixture(accountId: accountId, pool: pool)
            try await pool.writeWithoutTransaction { db in
                try Folder(name: "TRASH", path: "TRASH", role: .trash, accountId: accountId).insert(db)
            }

            /// Queue the `IOS-QUEUE-008` pair on one message: the undo's inverse
            /// (TRASH→INBOX) and, one second later, the user's newest intention
            /// (INBOX→TRASH). Same shape as
            /// `drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder`,
            /// which pins the WIRE; this pins that the LOG says the same thing.
            func queuePair(messageId: String) throws -> (inverse: String, redelete: String) {
                // Dynamic (repo rule: no hardcoded dates); whole-second so the
                // GRDB date round-trip compares exactly.
                let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
                var opInverse = PendingOperation(
                    type: .move, messageIds: [messageId], accountId: accountId,
                    folderPath: "TRASH", destinationPath: "INBOX")
                opInverse.createdAt = t0
                var opRedelete = PendingOperation(
                    type: .move, messageIds: [messageId], accountId: accountId,
                    folderPath: "INBOX", destinationPath: "TRASH")
                opRedelete.createdAt = t0.addingTimeInterval(1)
                try insertOp(opInverse, pool: pool)
                try insertOp(opRedelete, pool: pool)
                return (String(opInverse.id.prefix(8)), String(opRedelete.id.prefix(8)))
            }

            // ---- Gate OPEN ------------------------------------------------
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
            let unlockedPair = try queuePair(messageId: "m1")
            await AccountManager.shared.drainPendingQueue()
            let queueLog = AppLogStore.read(channel: .queue)

            // The EXACT, count-guarded artifact. Equality, not containment: a
            // containment oracle stays green when the op TYPE is dropped from the
            // line, when source→destination is reversed, when an entry appears
            // twice, when `executed` precedes `executing`, and when the two ops
            // are reported in DIFFERENT lanes — which is precisely the state that
            // brought the deleted message back (`IOS-QUEUE-008`).
            //
            // `lane0(2)` in the composition line and `pos 1/2` / `pos 2/2` in the
            // per-op lines are the same fact stated twice, deliberately: the
            // composition line is written BEFORE any Task starts and the per-op
            // lines are written by the lane Task itself, so agreeing is evidence
            // that the plan and the execution are the same plan.
            let inverse = unlockedPair.inverse
            let redelete = unlockedPair.redelete
            let expected = [
                "[Queue] Lanes: lane0(2): \(inverse) move TRASH→INBOX ids=[m1]"
                    + " | \(redelete) move INBOX→TRASH ids=[m1]",
                "[Queue] drain lane 0 pos 1/2 — executing \(inverse) move TRASH→INBOX ids=[m1]",
                "[Queue] drain lane 0 pos 1/2 — executed \(inverse) move TRASH→INBOX ids=[m1] outcome=proceed",
                "[Queue] drain lane 0 pos 2/2 — executing \(redelete) move INBOX→TRASH ids=[m1]",
                "[Queue] drain lane 0 pos 2/2 — executed \(redelete) move INBOX→TRASH ids=[m1] outcome=proceed",
            ]
            let observed = Self.laneOrderEntries(in: queueLog)
            #expect(observed == expected,
                    "the exported log does not reconstruct the drain.\nexpected:\n\(expected.joined(separator: "\n"))\nobserved:\n\(observed.joined(separator: "\n"))")

            // ---- Gate OPEN, ARMED FAULT: a lane that HALTS ----------------
            // The m1 phase above can only ever observe `outcome=proceed`, so it
            // does not constrain the field at all: replacing the interpolation
            // with the literal `outcome=proceed` keeps every test in this tree
            // green while the exported log reports a HALTED lane as one that kept
            // draining. `outcome=` is the instrument's only positive statement
            // that a lane stopped — the thing `IOS-QUEUE-008` needed the log to
            // say — so it is witnessed here rather than deleted.
            //
            // The fault is the same retryable one the stable-id fuzzer's
            // `.transientThenClears` mode arms (`ProviderIdQueueFuzzTests`:
            // `setMoveThrowsOnId(targetId, error: ProviderError.notConnected)`).
            // It reaches `executeSingleOp`'s generic transient arm — "Connection/
            // transient error — reset op to queued and mark account failed" — so
            // the predecessor is requeued with `retryCount += 1`, the account
            // enters `failedAccounts`, and `.haltLane` is returned, which makes
            // the drain loop requeue the successor and break the lane. That arm
            // deliberately does NOT set `executedAny`, so the outer pass loop
            // terminates and the drain writes exactly one lane-composition line.
            AppLogStore.clear()
            let armedPair = try queuePair(messageId: "m3")
            await provider.setMoveThrowsOnId("m3", error: ProviderError.notConnected)
            await AccountManager.shared.drainPendingQueue()

            let armedInverse = armedPair.inverse
            let armedRedelete = armedPair.redelete
            // Equality, not containment, for the same reason as the m1 phase —
            // and here it carries a second fact: NOTHING is reported for pos 2/2.
            // The successor never went out, and a log that named it would be
            // describing a wire event that did not happen.
            let armedExpected = [
                "[Queue] Lanes: lane0(2): \(armedInverse) move TRASH→INBOX ids=[m3]"
                    + " | \(armedRedelete) move INBOX→TRASH ids=[m3]",
                "[Queue] drain lane 0 pos 1/2 — executing \(armedInverse) move TRASH→INBOX ids=[m3]",
                "[Queue] drain lane 0 pos 1/2 — executed \(armedInverse) move TRASH→INBOX ids=[m3] outcome=haltLane",
            ]
            let armedObserved = Self.laneOrderEntries(in: AppLogStore.read(channel: .queue))
            #expect(armedObserved == armedExpected,
                    "the exported log does not report the halted lane.\nexpected:\n\(armedExpected.joined(separator: "\n"))\nobserved:\n\(armedObserved.joined(separator: "\n"))")

            // The durable state, read independently of the log: the log is the
            // artifact under test, so it cannot also be the evidence that the
            // scenario it describes actually arose.
            let armedAllRows = try await pool.read { db in
                try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
            }
            let armedRows = armedAllRows.filter { $0.messageIds == ["m3"] }
            #expect(armedRows.count == 2,
                    "both m3 ops must survive the halt: \(armedRows.map { "\($0.id.prefix(8)) \($0.folderPath)→\($0.destinationPath ?? "-") \($0.status)" })")
            guard armedRows.count == 2 else { return }
            let haltedOp = armedRows[0]
            let heldOp = armedRows[1]
            #expect(haltedOp.id.hasPrefix(armedInverse) && heldOp.id.hasPrefix(armedRedelete),
                    "createdAt order must still put the inverse first")
            #expect(haltedOp.status == PendingStatus.queued.rawValue)
            #expect(heldOp.status == PendingStatus.queued.rawValue)
            #expect(haltedOp.retryCount == 1, "the halted op was attempted once and requeued")
            #expect(heldOp.retryCount == 0, "the successor was requeued WITHOUT being attempted")
            #expect(haltedOp.everAttempted && heldOp.everAttempted,
                    "both rows were claimed this pass, so both carry the attempted-row proof")

            // `callLog` is the ATTEMPT ledger (appended before the throw hook),
            // `movedIds` the SUCCESS ledger — so together they say the predecessor
            // went out exactly once and landed nothing, and the successor never
            // reached the wire.
            let armedCallLog = await provider.callLog
            let armedMoveCalls = armedCallLog.filter { $0.hasPrefix("move(ids:") && $0.contains("m3") }
            #expect(armedMoveCalls == ["move(ids:[\"m3\"],from:TRASH,to:INBOX)"],
                    "exactly one m3 move attempt, and it is the inverse: \(armedMoveCalls)")
            let armedMoved = await provider.movedIds
            #expect(!armedMoved.contains { $0.ids == ["m3"] },
                    "the armed move must have landed nothing: \(armedMoved.map { "\($0.ids) \($0.from)→\($0.to)" })")

            // The blip clears: the SAME lane now drains to completion, in order,
            // and the log says `proceed` twice — which is what makes the
            // `haltLane` above a discriminating observation rather than a
            // constant.
            await provider.clearMoveThrowsOnId()
            AppLogStore.clear()
            await AccountManager.shared.drainPendingQueue()

            let clearedExpected = [
                "[Queue] Lanes: lane0(2): \(armedInverse) move TRASH→INBOX ids=[m3]"
                    + " | \(armedRedelete) move INBOX→TRASH ids=[m3]",
                "[Queue] drain lane 0 pos 1/2 — executing \(armedInverse) move TRASH→INBOX ids=[m3]",
                "[Queue] drain lane 0 pos 1/2 — executed \(armedInverse) move TRASH→INBOX ids=[m3] outcome=proceed",
                "[Queue] drain lane 0 pos 2/2 — executing \(armedRedelete) move INBOX→TRASH ids=[m3]",
                "[Queue] drain lane 0 pos 2/2 — executed \(armedRedelete) move INBOX→TRASH ids=[m3] outcome=proceed",
            ]
            let clearedObserved = Self.laneOrderEntries(in: AppLogStore.read(channel: .queue))
            #expect(clearedObserved == clearedExpected,
                    "the exported log does not reconstruct the completing retry.\nexpected:\n\(clearedExpected.joined(separator: "\n"))\nobserved:\n\(clearedObserved.joined(separator: "\n"))")

            let clearedMoved = await provider.movedIds
            let m3Moves = clearedMoved.filter { $0.ids == ["m3"] }
            #expect(m3Moves.count == 2,
                    "the retry lands both m3 moves: \(m3Moves.map { "\($0.from)→\($0.to)" })")
            guard m3Moves.count == 2 else { return }
            #expect(m3Moves[0].from == "TRASH" && m3Moves[0].to == "INBOX",
                    "the undo's inverse goes out first")
            #expect(m3Moves[1].from == "INBOX" && m3Moves[1].to == "TRASH",
                    "the user's newest intention goes out second")
            let remainingAllRows = try await pool.read { db in
                try PendingOperation.fetchAll(db)
            }
            let remainingM3 = remainingAllRows.filter { $0.messageIds == ["m3"] }
            #expect(remainingM3.isEmpty,
                    "both m3 ops completed, so neither row remains: \(remainingM3.map { $0.id })")

            // ---- Gate CLOSED (two-sided non-vacuity) ----------------------
            AppLogStore.clear()
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
            let lockedPair = try queuePair(messageId: "m2")
            await AccountManager.shared.drainPendingQueue()

            let lockedLog = AppLogStore.read(channel: .queue)
            #expect(!lockedLog.contains(lockedPair.inverse) && !lockedLog.contains(lockedPair.redelete),
                    "the drain persisted QUEUE lines while debug logging was locked: \(lockedLog)")
            #expect(Self.laneOrderEntries(in: lockedLog).isEmpty,
                    "a lane/order line survived the closed gate: \(lockedLog)")
            // Non-vacuity for THIS half: the drain really ran, so the silence is
            // the gate rather than an absent drain.
            let moved = await provider.movedIds
            #expect(moved.contains { $0.ids == ["m2"] },
                    "the locked-gate half never drained — its silence proves nothing")
        }
    }

    // MARK: - 10d. One undecodable account row must not stall every other account

    /// THE INVARIANT: one bystander `account` row cannot stop OTHER accounts'
    /// queued intentions from draining.
    ///
    /// `AccountProvider` is a closed `String, Codable` enum and the
    /// `account.provider` column is unconstrained text, so a snapshot that
    /// decodes whole `Account` rows throws `DecodingError.dataCorrupted` on one
    /// unrecognised value — before ANY op is claimed. The drain's `catch`
    /// `break`s, every later drain reproduces it identically, and valid ops for
    /// every account stay queued forever behind a debug-gated log nobody sees.
    /// That is the wedge corollary with a bystander, one level up from
    /// `IOS-QUEUE-001`: an op that stays queued but prevents other intentions
    /// executing has not been preserved.
    ///
    /// The fix is to read only the IDS of the rows that MATCH the
    /// account-scoped-id
    /// predicate, which a row that does not match cannot defeat. An unknown
    /// provider is then simply not admitted, which is the SAFE side — it gets the
    /// folder-qualified key the base always used — and it costs nothing anyway:
    /// nothing can construct a provider for it, so its ops are skipped at the
    /// claim loop and no address-space decision is ever acted on for them.
    @Test("drainPendingQueue() (real): an account row whose provider string does not decode cannot stall every other account's ops")
    func drainPendingQueueRealUndecodableAccountRowDoesNotStallOtherAccounts() async throws {
        let (pool, dir, previous) = try makeTestDB()
        let goodAccountId = "acc-known-provider"
        let unknownAccountId = "acc-unknown-provider"
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let provider = MockEmailProvider()
        // Deliberately NOT registered. In production nothing can construct a
        // provider for an account whose provider string does not decode, so
        // `providers[op.accountId]` is nil and its ops are skipped at the claim
        // loop; leaving this mock unregistered reproduces that state, and
        // asserting its call log stays empty pins that the undecodable row never
        // becomes an executing account by some other route.
        let unknownProvider = MockEmailProvider()

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: goodAccountId, provider: provider
        ) {
            try insertStableProviderFixture(accountId: goodAccountId, pool: pool)
            try await pool.writeWithoutTransaction { db in
                try Folder(name: "TRASH", path: "TRASH", role: .trash, accountId: goodAccountId).insert(db)
                // A NORMAL insert first — `Account` cannot ENCODE a provider
                // string its enum does not have — then a raw UPDATE that puts the
                // undecodable value in the column. That is exactly the durable
                // state persistent corruption, or a row written by a newer
                // provider-aware build, leaves behind.
                var future = Account(
                    emailAddress: "future@example.com", displayName: "Future", provider: .gmail)
                future.id = unknownAccountId
                try future.insert(db)
                try db.execute(
                    sql: "UPDATE account SET provider = ? WHERE id = ?",
                    arguments: ["future-provider", unknownAccountId])
            }

            // Precondition, and the whole reason this fixture discriminates: the
            // row really is undecodable. Without it the test would pass against a
            // well-formed database and prove nothing.
            let wholeRowDecodeThrows = try await pool.read { db -> Bool in
                do {
                    _ = try Account.fetchAll(db)
                    return false
                } catch {
                    return true
                }
            }
            #expect(wholeRowDecodeThrows,
                    "the fixture's provider column still decodes — this test cannot discriminate")

            let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
            var goodOp = PendingOperation(
                type: .move, messageIds: ["m-good"], accountId: goodAccountId,
                folderPath: "INBOX", destinationPath: "TRASH")
            goodOp.createdAt = t0
            var unknownOp = PendingOperation(
                type: .move, messageIds: ["m-unknown"], accountId: unknownAccountId,
                folderPath: "INBOX", destinationPath: "TRASH")
            unknownOp.createdAt = t0.addingTimeInterval(1)
            try insertOp(goodOp, pool: pool)
            try insertOp(unknownOp, pool: pool)

            await AccountManager.shared.drainPendingQueue()

            // 1. The valid account's intention executed and left the queue. THIS
            //    is the assertion that goes red when the snapshot decodes whole
            //    `Account` rows.
            let moved = await provider.movedIds
            #expect(moved.contains { $0.ids == ["m-good"] },
                    "the valid account's op never reached its provider — one bystander row stalled the whole drain")
            let goodSurvivor = try fetchOp(goodOp.id, pool: pool)
            #expect(goodSurvivor == nil, "the valid account's op must have left the queue")

            // 2. The undecodable account's op is PRESERVED — never dropped, never
            //    stranded `inFlight`.
            let unknownSurvivor = try fetchOp(unknownOp.id, pool: pool)
            #expect(unknownSurvivor?.status == PendingStatus.queued.rawValue,
                    "the undecodable account's op must stay queued, got \(unknownSurvivor?.status ?? "<deleted>")")

            // 3. And nothing executed on its behalf, on any provider.
            let unknownCalls = await unknownProvider.callLog
            #expect(unknownCalls.isEmpty,
                    "an account whose provider string does not decode must never execute: \(unknownCalls)")
            #expect(!moved.contains { $0.ids.contains("m-unknown") },
                    "the undecodable account's message id reached another account's provider")
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
