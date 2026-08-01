/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

extension AccountManager {

    // MARK: - Persistent Action Queue

    /// Queue an action tag write for async execution.
    /// Called from AI processing and manual tag application.
    /// Static + nonisolated: the GRDB write is thread-safe and doesn't need MainActor.
    /// Callers can call directly without `await MainActor.run { ... }`.
    nonisolated static func queueTagWrite(accountId: String, messageId: String, rfc822MessageId: String? = nil, tag: ActionTag?, folder: String) {
        // Prefer rfc822MessageId for IMAP messages (numeric UIDs) — survives UIDVALIDITY changes
        let stableId: String
        if UInt32(messageId) != nil, let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            stableId = rfc822
        } else {
            stableId = messageId
        }
        let opType: OperationType = tag != nil ? .setTag : .removeTag
        let op = PendingOperation(type: opType, messageIds: [stableId], accountId: accountId, folderPath: folder, tagValue: tag?.rawValue)
        do {
            try AppDatabase.dbPool.write { db in try op.insert(db) }
        } catch {
            print("[Queue] ERROR: queueTagWrite failed: \(error)")
        }
        Task { @MainActor in await AccountManager.shared.drainPendingQueue() }
    }

    /// Shared mutable state for parallel drain tasks. Reference type so concurrent
    /// lane Tasks (launched from the `AccountManager` actor) see each other's updates
    /// at await points. `internal` (not `private`) so tests can construct it directly
    /// to call `executeSingleOp`.
    class DrainContext: @unchecked Sendable {
        var failedAccounts = Set<String>()
        var foldersToSync: Set<String> = []
        var executedAny = false
        // op.id values that have already produced a [QueueDiag] deep-dump this drain.
        // Prevents log-spam on the same stuck op that retries every drain cycle.
        var diagnosedOpIds: Set<String> = []
    }

    /// Outcome of a single claimed-op execution (`executeSingleOp`), used by the
    /// per-lane drain loop in `drainPendingQueue` to decide whether to keep draining
    /// the lane or halt it for this pass.
    enum SingleOpOutcome: Sendable, Equatable {
        /// The op reached a terminal state this pass — either it completed
        /// successfully, or it was CONFIRMED stale/invalid and dropped (deleted, or
        /// split into fresh individual ops). The lane may proceed to its next op.
        case proceed
        /// The op was reset to `.queued` for retry (its staleness/success could NOT
        /// be confirmed this pass). The REST of this lane must halt: a later op on
        /// the same connected component (e.g. a flag change queued after a move of
        /// the same message) must never run ahead of its unresolved predecessor —
        /// running it would race the predecessor's eventual retry on the wire. The
        /// lane loop requeues the remaining claimed ops in this lane (same as the
        /// existing failedAccounts requeue path) and stops.
        case haltLane
    }

    /// Groups claimed pending operations into serialized "lanes" via connected-
    /// component grouping over shared message ids (scoped per account). Two ops
    /// that share ANY member message id land in the same lane — and transitively,
    /// any op sharing an id with either of those joins too (union-find).
    ///
    /// WHY this matters: `drainPendingQueue` runs one Task per lane CONCURRENTLY,
    /// each drawing from `ProviderWorkQueue` (bounded concurrency > 1 — separate
    /// IMAP connections). The OLD lane key was `"accountId:messageIds.first"`, so a
    /// batch move `[A,B,C]` landed in a lane keyed by A while a LATER single-id op
    /// on B (e.g. a flag change) landed in a SEPARATE lane keyed by B — even though
    /// B is a member of both. The two lanes then ran concurrently, racing on the
    /// wire: a flag STORE on B could race the batch MOVE of B, silently losing the
    /// flag on the MOVE's EXPUNGE, or getting wrongly confirmed-stale by the
    /// `uidResolutionFailed` handling mid-move. Connected-component lanes guarantee
    /// any op sharing a member id with an in-flight op serializes AFTER it.
    ///
    /// Pure and side-effect free (no DB/IO) — `nonisolated static` so it's directly
    /// unit-testable without an actor hop. Callers pass ops in createdAt-asc order;
    /// each lane preserves that relative order (FIFO within its component).
    /// Ops with empty `messageIds` (no id to key on) fall back to a singleton lane,
    /// matching the pre-existing fallback (`messageIds.first ?? op.id`).
    nonisolated static func buildLanes(_ ops: [PendingOperation]) -> [[PendingOperation]] {
        // Union-Find over "accountId:msgId" keys, with path compression.
        var parent: [String: String] = [:]

        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root {
                root = p
            }
            var current = x
            while let p = parent[current], p != root {
                parent[current] = root
                current = p
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        for op in ops {
            let ids = op.messageIds
            guard !ids.isEmpty else { continue }
            let keys = ids.map { "\(op.accountId):\($0)" }
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            for key in keys.dropFirst() {
                union(keys[0], key)
            }
        }

        // Assign each op to its component's lane, in the ORIGINAL (createdAt-asc) order.
        var laneIndexForRoot: [String: Int] = [:]
        var lanes: [[PendingOperation]] = []
        for op in ops {
            guard let firstId = op.messageIds.first else {
                // Empty messageIds — always its own singleton lane.
                lanes.append([op])
                continue
            }
            let root = find("\(op.accountId):\(firstId)")
            if let idx = laneIndexForRoot[root] {
                lanes[idx].append(op)
            } else {
                laneIndexForRoot[root] = lanes.count
                lanes.append([op])
            }
        }
        return lanes
    }

    /// Drain all queued operations with per-message parallelism.
    ///
    /// Ops are grouped into lanes by `buildLanes`: an op joins the lane of ANY op
    /// sharing any member message id (connected components), not just its first id.
    /// Each lane is a FIFO — ops in the same connected component execute
    /// sequentially (preserving ordering like removeTag→move, or a batch move and a
    /// later single-id flag change on one of its members). The drain runs every
    /// lane concurrently, so ops for disjoint messages make progress in parallel.
    ///
    /// Provider-level concurrency is managed by each provider (IMAP connection pool, HTTP pooling).
    ///
    /// Re-fetches after each pass to pick up ops inserted during the drain.
    /// Skips drain when offline to prevent retry storms.
    func drainPendingQueue() async {
        guard !isDraining else {
            needsRedrain = true
            return
        }
        guard NetworkMonitor.checkConnected() else { return }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                Task { await drainPendingQueue() }
            }
        }

        pruneRecentlyCompleted()
        let ctx = DrainContext()

        // Max 3 passes to pick up ops inserted during drain.
        for pass in 0..<3 {
            let ops: [PendingOperation]
            do {
                ops = try await dbPool.read({ db in
                    try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
                })
            } catch {
                print("[Queue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else { break }

            if pass == 0 {
                let summary = ops.map { "\($0.type.rawValue)(\($0.messageIds.count)msgs)" }.joined(separator: ", ")
                print("[Queue] Draining \(ops.count) ops: \(summary)")
            } else {
                print("[Queue] Drain pass \(pass + 1): \(ops.count) ops remaining/new")
            }

            // Claim all valid ops (unchanged: failedAccounts / provider checks / atomic claim).
            var claimed: [PendingOperation] = []
            for op in ops {
                if ctx.failedAccounts.contains(op.accountId) { continue }
                guard providers[op.accountId] != nil else {
                    print("[Queue] No provider for \(op.accountId) — skipping \(op.type.rawValue)")
                    continue
                }

                let currentOp: PendingOperation?
                do {
                    currentOp = try await dbPool.write { db -> PendingOperation? in
                        guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else {
                            return nil
                        }
                        if fetched.status == PendingStatus.cancelled.rawValue {
                            _ = try PendingOperation.deleteOne(db, key: fetched.id)
                            print("[Queue] Op \(op.id.prefix(8)) cancelled by undo, deleted")
                            return nil
                        }
                        if fetched.status == PendingStatus.inFlight.rawValue {
                            return nil
                        }
                        // T4.S6 — PARK (never drop) while this op's source folder is
                        // mid UIDVALIDITY reset. The reaction has purged, or is about
                        // to purge, every header in that folder, and the UIDs this op
                        // addresses belong to a numbering the server has discarded:
                        // executing it now would mutate whichever message the new
                        // epoch put at that address (C3). The row stays `queued` with
                        // its retry counters untouched, so nothing is lost and nothing
                        // ages toward `failed` — Law 5. TRANSIENT: the flag is cleared
                        // by the reaction's step-5 stamp, and full sync re-drives an
                        // interrupted reaction on every cycle.
                        //
                        // ⚠ WHAT MAKES THE UNPARK SAFE — TWO CHECKS, NOT ONE. This
                        // comment used to claim the step-5 transaction alone was enough
                        // ("the same transaction that clears the flag also removes the
                        // address-only ops"). It is NOT: `opIsAddressOnly` is false for
                        // any op carrying a non-numeric id ALONGSIDE a UID, and
                        // `.deleteDraft` is exactly that shape — `queueDraftDelete`
                        // records `[uid, rfc822]` for the sync filter while
                        // `executeOperation` hands `messageIds.first` (the UID) to
                        // `provider.deleteDraft`. Such an op survived the sweep and then
                        // unparked onto a UID the new epoch had reassigned. The
                        // admission-time stamp compared below is the second check, and
                        // the one that does not depend on guessing an op's id shapes.
                        // ⚑ UPDATE (2026-08-01): `IMAPProvider.deleteDraft` no longer
                        // executes a bare UID at all — it verifies an rfc822 identity on
                        // the wire and REFUSES an all-digits id — so that provider is now
                        // guarded at BOTH ends. This check stays: it is provider-agnostic,
                        // it is what keeps an op recorded under a discarded numbering from
                        // running at all, and the reasoning above is what it exists for.
                        let sourceFolderId = MessageIdentity.folderId(
                            accountId: fetched.accountId, folderPath: fetched.folderPath)
                        let sourceFolder = try Folder.fetchOne(db, key: sourceFolderId)
                        if let sourceFolder, sourceFolder.uidValidityResetPendingAt != nil {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Queue] Op \(op.id.prefix(8)) (\(fetched.type.rawValue)) parked — folder \(fetched.folderPath) is mid UIDVALIDITY reset")
                            }
                            return nil
                        }
                        // T4.S6 follow-up — an op RECORDED under a numbering the server
                        // has since discarded NEVER EXECUTES. It is deleted here, not
                        // parked: parking would be a permanent wedge (the old epoch never
                        // comes back), and executing it would address a UID whose referent
                        // changed underneath it — C3. Constraint C5 blesses dropping
                        // intention at an identity-reset boundary: sync reconciles the
                        // surviving server draft and the user redoes the delete.
                        //
                        // Ordered AFTER the park on purpose: during quarantine the folder
                        // still holds the OLD epoch (step 5 owns advancing it), so the
                        // stamp still AGREES and this would not fire anyway — but reading
                        // the park first keeps "mid-reset" a single, unambiguous outcome.
                        //
                        // FAILS OPEN on a nil live epoch (a vanished `Folder` row, or one
                        // `SyncEngine.resetEmptyFolderCrawlEpoch` cleared back to nil):
                        // "unknown" is not "different", and refusing on it would drop
                        // intention for a folder that is merely un-bootstrapped. Same
                        // polarity as the reference's claim-time check.
                        if let stamped = fetched.observedUidValidity,
                           let live = sourceFolder?.lastKnownUidValidity,
                           live != stamped {
                            _ = try PendingOperation.deleteOne(db, key: fetched.id)
                            BackgroundSyncLogger.log("[Queue] UIDVALIDITY changed under op \(fetched.id.prefix(8)) (\(fetched.type.rawValue), \(fetched.folderPath)): recorded under \(stamped), folder now \(live) — dropped without executing (C5)")
                            return nil
                        }
                        fetched.status = PendingStatus.inFlight.rawValue
                        try fetched.save(db)
                        return fetched
                    }
                } catch {
                    print("[Queue] ERROR: Failed to claim op \(op.id): \(error)")
                    continue
                }
                guard let currentOp else { continue }
                claimed.append(currentOp)
            }

            // Connected-component lane grouping (F1) — pure, see buildLanes doc comment.
            let lanes = Self.buildLanes(claimed)
            guard !lanes.isEmpty else { break }

            // Launch one Task per lane. Each task drains its lane sequentially,
            // halting (and requeuing the rest of the lane) on `.haltLane` so a later
            // op never runs ahead of an unresolved predecessor sharing a message id.
            // Different lanes (disjoint connected components) run concurrently.
            var tasks: [Task<Void, Never>] = []
            for lane in lanes {
                let capturedLane = lane
                let capturedCtx = ctx
                let task = Task { [self] in
                    for (index, op) in capturedLane.enumerated() {
                        if capturedCtx.failedAccounts.contains(op.accountId) {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        guard let queue = self.workQueues[op.accountId] else {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        let provider = queue.provider
                        // Outcome captured via Mutex (not a plain var) — the closure
                        // passed to queue.execute is @Sendable, so it cannot capture a
                        // mutable local var directly under Swift 6 strict concurrency.
                        let outcomeBox = Mutex<SingleOpOutcome>(.proceed)
                        await queue.execute(priority: .userAction) {
                            let result = await self.executeSingleOp(op, provider: provider, context: capturedCtx)
                            outcomeBox.withLock { $0 = result }
                        }
                        if outcomeBox.withLock({ $0 }) == .haltLane {
                            // Requeue the REMAINING claimed ops of this lane — exactly
                            // like the failedAccounts requeue path above — then stop.
                            let remaining = capturedLane[(index + 1)...]
                            for remainingOp in remaining {
                                try? await retryWrite(dbPool, label: "Queue") { db in
                                    var updated = remainingOp
                                    updated.status = PendingStatus.queued.rawValue
                                    try updated.save(db)
                                }
                            }
                            break
                        }
                    }
                }
                tasks.append(task)
            }
            for task in tasks { await task.value }

            if !ctx.executedAny { break }
            ctx.executedAny = false
        }

        // Post-drain: sync destination folders so new UIDs are picked up immediately.
        if !ctx.foldersToSync.isEmpty {
            print("[MoveTrace] post-drain sync — syncing \(ctx.foldersToSync.count) destination folders: \(ctx.foldersToSync)")
            for key in ctx.foldersToSync {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let folderPath = String(parts[1])
                guard let queue = workQueues[accountId] else { continue }
                guard let folder = try? await dbPool.read({ db in
                    try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
                }) else {
                    print("[MoveTrace] post-drain sync — folder not found: \(accountId)|\(folderPath)")
                    continue
                }
                do {
                    try await queue.execute(priority: .userAction) {
                        try await self.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                    }
                    print("[MoveTrace] post-drain sync — completed for \(folder.name)")
                } catch {
                    print("[MoveTrace] post-drain sync — failed for \(folder.name): \(error)")
                }
            }
        }
    }

    // MARK: - Drain-barrier Test Seam (T0.8)
    //
    // `ProviderIdQueueFuzzTests` needs a drain barrier, and per the plan's T0.5
    // callout a barrier is only correct if it samples its predicate BEFORE
    // requesting a drain — otherwise every poll lands on `drainPendingQueue()`'s
    // is-draining guard above, sets `needsRedrain` itself, and the barrier keeps
    // its own re-arm alive forever. That corrected shape needs to be able to
    // observe "no drain in flight", which `isDraining`/`needsRedrain`
    // (`AccountManager.swift:274`, `:276`) do not expose to a test on their own.
    //
    // This is a verbatim port of the reference accessor
    // (`v2final:TabMail/Services/Account/AccountManagerQueue.swift:3172-3174`) —
    // same name, same predicate — with the one deviation this file's sibling
    // seams already established (`IMAPProvider.mutLogForTesting` and the
    // T0.6(a) pool-invariant seams; symbol-cited, no line numbers): the
    // reference leaves its `…ForTesting` surface UNGATED, here it is `#if DEBUG`
    // so Release builds carry neither the member nor any call site. Purely
    // additive: nothing above changed, and no production code reads it.
    #if DEBUG

    /// Narrow test seam for proving that awaiting a drain also joins any
    /// requested re-drain instead of leaving unstructured queue work behind.
    ///
    /// The barrier that consumes it MUST read this FIRST and only then ask for a
    /// drain (see `ProviderIdQueueFuzzTests.drainProviderQueue`) — the inverse
    /// ordering is the self-re-arm bug the reference fixed in `f214c704a`.
    func pendingQueueIsQuiescentForTesting() -> Bool {
        !isDraining && !needsRedrain
    }

    #endif

    /// Execute a single claimed op against its provider. Updates shared DrainContext
    /// with results (executedAny, failedAccounts, foldersToSync, recentActions).
    /// Returns the outcome (`.proceed`/`.haltLane`) so the per-lane drain loop knows
    /// whether it's safe to run this lane's next op. `internal` (not `private`) so
    /// tests can call it directly against a `MockEmailProvider`.
    func executeSingleOp(_ currentOp: PendingOperation, provider: any EmailProvider, context: DrainContext) async -> SingleOpOutcome {
        let opType = currentOp.type.rawValue
        let opMsgCount = currentOp.messageIds.count

        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                try await self.executeOperation(currentOp, provider: provider)
            }
            // TOCTOU fix: record recentActions BEFORE deleting PendingOp.
            // Sync engine has two guards against re-inserting moved messages:
            //   1. pendingDestructiveIds — read inside the sync write transaction
            //   2. recentMoveIdsByFolder — snapshot from actor before the sync write
            // If we delete the PendingOp first and record recentAction after, there's
            // a window where neither guard is active (PendingOp gone from DB, recentAction
            // not yet on actor). By recording recentAction first, at every instant at least
            // one guard is active:
            //   - Before step 3 (delete): PendingOp in DB → pendingDestructiveIds catches it
            //   - After step 2 (record): recentAction on actor → recentMoveIdsByFolder catches it
            // If app crashes between steps 2 and 3, the PendingOp re-executes (idempotent).

            // Step 1: Collect rfc822MessageIds (read-only, separate from delete).
            var actionInfos: [(String, String?, String?)] = [] // (opMsgId, rfc822MessageId, numericMessageId)
            let trackedTypes: Set<OperationType> = [
                .archive, .delete, .move,
                .markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag
            ]
            if trackedTypes.contains(currentOp.type) {
                do {
                    actionInfos = try await dbPool.read { db -> [(String, String?, String?)] in
                        var infos: [(String, String?, String?)] = []
                        for msgId in currentOp.messageIds {
                            let normalizedMsgId = EmailFilter.normalizeMessageId(msgId)
                            let header = try MessageHeader
                                .filter(
                                    (Column("messageId") == msgId || Column("rfc822MessageId") == normalizedMsgId) &&
                                    Column("accountId") == currentOp.accountId
                                )
                                .fetchOne(db)
                            infos.append((msgId, header?.rfc822MessageId, header?.messageId))
                        }
                        return infos
                    }
                } catch {
                    print("[Queue] WARNING: Failed to collect rfc822 info for \(currentOp.id): \(error)")
                }
            }

            // Step 2: Record in recentlyCompleted (30s TTL) BEFORE deleting PendingOp.
            // Bridges the gap between PendingOp deletion and server-side state propagation.
            // This ensures sync engine always sees the protection entry.
            var completedIds: [String] = []
            for (msgId, rfc822, numericId) in actionInfos {
                completedIds.append(msgId)
                if let rfc822 { completedIds.append(rfc822) }
                if let numericId, numericId != msgId { completedIds.append(numericId) }
            }
            recordRecentlyCompleted(messageIds: completedIds)

            // Step 3: Delete PendingOp. MUST succeed — remote op already completed.
            // If we don't delete, it re-executes on next drain (idempotent but wasteful).
            do {
                try await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
            } catch {
                print("[Queue] CRITICAL: Failed to delete completed PendingOperation \(currentOp.id) after retries — will re-execute on next drain")
            }
            if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
                context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
            }
            // Sync Drafts folder after draft save/delete so MessageHeaders reflect server state.
            // After saveDraft: the sync's UID remap detection matches our optimistic header
            // (placeholder messageId) to the real server header by rfc822MessageId, migrating
            // the header in-place and preserving the body + local state.
            if [.saveDraft, .deleteDraft].contains(currentOp.type) {
                context.foldersToSync.insert("\(currentOp.accountId)|\(currentOp.folderPath)")
            }
            context.executedAny = true
            return .proceed
        } catch {
            // UID resolution failed on tag ops — skip (best-effort).
            // Tag removal is queued before move to prevent flag copying on IMAP MOVE.
            // If we can't resolve the UID, skipping the tag op is far better than
            // blocking the entire account's drain (including the actual archive/move).
            if case ProviderError.uidResolutionFailed = error,
               [.setTag, .removeTag].contains(currentOp.type) {
                print("[Queue] Tag op UID resolution failed for \(currentOp.messageIds.first ?? "?") — skipping (best-effort)")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return .proceed
            }
            if isMessageNotFoundError(error) {
                if currentOp.messageIds.count > 1 {
                    // Batch op hit messageNotFound — one message is gone but others
                    // may still need processing. Split into individual single-message
                    // ops so each can succeed/fail independently.
                    print("[Queue] Conflict in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
                    do {
                        try await dbPool.write { db in
                            for msgId in currentOp.messageIds {
                                var splitOp = PendingOperation(type: currentOp.type, messageIds: [msgId], accountId: currentOp.accountId, folderPath: currentOp.folderPath, destinationPath: currentOp.destinationPath, tagValue: currentOp.tagValue)
                                // Split ops inherit the batch's queue position — they are
                                // the SAME user intention, re-shaped. Without this, the
                                // default `PendingOperation.init` createdAt (Date()) would
                                // stamp a LATER timestamp than a same-lane sibling op queued
                                // between the batch and the split, starving the split op
                                // behind it on every later buildLanes pass (createdAt-order
                                // invariant).
                                splitOp.createdAt = currentOp.createdAt
                                try splitOp.insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        print("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
                    }
                    context.executedAny = true
                    // Halt the lane rather than .proceed: the split singles are
                    // freshly queued (not yet executed) and a LATER same-lane op
                    // sharing a member id (e.g. a chained move of one of the split
                    // messages) must never run ahead of them this pass — that would
                    // race/misread state the split children haven't written yet and
                    // could get itself wrongly confirmed-stale and dropped. Same
                    // never-run-ahead invariant as the uidResolutionFailed retry
                    // path below; the lane loop requeues the rest of the lane back
                    // to `.queued` so it serializes behind the split ops on a later
                    // pass/drain.
                    return .haltLane
                }
                // Single-message conflict — drop (server wins)
                print("[Queue] Conflict: \(opType) — message not found, dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                // If the error was a structurally-confirmed permanent gone (HTTP 404/410
                // or ProviderError.messageNotFound), also delete the local header. The
                // message is verified gone on the server; retaining a ghost row causes
                // other queues (body fetch, AI) to retry forever.
                // We deliberately DO NOT delete on the string-matching branch of
                // isMessageNotFoundError — too risky for false positives.
                if isConfirmedGoneError(error), let msgId = currentOp.messageIds.first {
                    // Scope delete to the exact (account, folder, messageId) row — broader
                    // matches risk deleting unrelated messages that happen to share a UID
                    // in a different IMAP folder.
                    let hid = MessageIdentity.headerId(accountId: currentOp.accountId, folderPath: currentOp.folderPath, messageId: msgId)
                    await deleteConfirmedGoneHeader(headerId: hid, reason: "\(opType) 404")
                }
                context.executedAny = true
                return .proceed
            }
            // Permanently invalid operation — drop immediately (will never succeed on retry).
            // E.g., Gmail "Invalid label: DRAFT" when a .move op tried to remove the DRAFT label.
            if isPermanentlyInvalidError(error) {
                print("[Queue] Permanently invalid \(opType): \(error) — dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return .proceed
            }
            // UID resolution failed — message not found in source folder via IMAP SEARCH.
            // Confirm staleness by checking destination (for move ops) or drop (for flag ops).
            if case ProviderError.uidResolutionFailed(let failedId) = error {
                // Batch ops: split into singles so each can be confirmed independently.
                if currentOp.messageIds.count > 1 {
                    print("[Queue] UID resolution failed in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
                    do {
                        try await dbPool.write { db in
                            for msgId in currentOp.messageIds {
                                var splitOp = PendingOperation(type: currentOp.type, messageIds: [msgId], accountId: currentOp.accountId, folderPath: currentOp.folderPath, destinationPath: currentOp.destinationPath, tagValue: currentOp.tagValue)
                                // Split ops inherit the batch's queue position — they are
                                // the SAME user intention, re-shaped. See the identical
                                // comment in the messageNotFound split above.
                                splitOp.createdAt = currentOp.createdAt
                                try splitOp.insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        print("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
                    }
                    context.executedAny = true
                    // Halt the lane rather than .proceed — see the identical
                    // never-run-ahead comment on the messageNotFound split above.
                    // A later same-lane op (e.g. a chained move of one of the
                    // split messages) must serialize BEHIND the freshly-queued
                    // split singles, not run ahead of them this pass.
                    return .haltLane
                }

                // Single-message op: confirm staleness.
                if let dest = currentOp.destinationPath, currentOp.type == .move,
                   let imapProvider = provider as? IMAPProvider {
                    // Move op on IMAP: check if message is in destination folder.
                    // Found → confirmed done. Not found → confirmed stale (can't recover). Either way, drop.
                    // Connection error → can't confirm, fall through to retry.
                    do {
                        let existsInDest = try await imapProvider.messageExistsInFolder(rfc822MessageId: failedId, folderPath: dest)
                        if existsInDest {
                            print("[Queue] Confirmed done: \(opType) \(failedId) — already in destination \(dest), dropping")
                        } else {
                            print("[Queue] Confirmed stale: \(opType) \(failedId) — not in source \(currentOp.folderPath) or destination \(dest), dropping")
                        }
                        try? await retryWrite(dbPool, label: "Queue") { db in
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                        context.executedAny = true
                        return .proceed
                    } catch {
                        // If destination folder itself doesn't exist (NONEXISTENT, etc.),
                        // the message can't be in it — confirmed stale.
                        let destCheckDesc = "\(error)"
                        if destCheckDesc.contains("NONEXISTENT") || destCheckDesc.contains("does not exist") || destCheckDesc.contains("Mailbox doesn't exist") {
                            print("[Queue] Confirmed stale: \(opType) \(failedId) — not in source \(currentOp.folderPath), destination \(dest) no longer exists, dropping")
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                            }
                            context.executedAny = true
                            return .proceed
                        }
                        print("[Queue] UID resolution failed for \(opType) \(failedId), destination check failed: \(error) — will retry")
                    }
                } else if currentOp.type != .move {
                    // Flag/mark op: message not in folder via SEARCH. Per resolveUID's
                    // documented contract (IMAPProvider.swift) a SEARCH miss can be
                    // transient (server-side indexing lag, concurrent UID renumbering) —
                    // so retry with a cap (matching move ops' destination-check treatment)
                    // instead of an unconditional drop, so we don't discard user intention
                    // on a false-negative SEARCH.
                    //
                    // Caps on the DEDICATED uidResolutionRetryCount, NOT the shared
                    // retryCount (bumped below by the generic transient-error branch on
                    // every ordinary connection blip). Reading the shared counter here
                    // let a few unrelated blips pre-exhaust this budget before the op's
                    // first real SEARCH miss, causing a false "confirmed stale" drop —
                    // dropping user intention, the exact bug this cap exists to prevent.
                    if currentOp.uidResolutionRetryCount >= SyncConfig.maxUidResolutionRetries {
                        print("[Queue] Confirmed stale: \(opType) \(failedId) — message not in folder \(currentOp.folderPath) after \(currentOp.uidResolutionRetryCount) uidResolution retries, dropping")
                        try? await retryWrite(dbPool, label: "Queue") { db in
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                        context.executedAny = true
                        return .proceed
                    }
                    print("[Queue] UID resolution failed for \(opType) \(failedId) — message not in folder \(currentOp.folderPath), uidResolution retry \(currentOp.uidResolutionRetryCount + 1)/\(SyncConfig.maxUidResolutionRetries) (not blocking account)")
                    try? await retryWrite(dbPool, label: "Queue") { db in
                        var updated = currentOp
                        updated.status = PendingStatus.queued.rawValue
                        updated.uidResolutionRetryCount += 1
                        try updated.save(db)
                    }
                    return .haltLane
                }

                // Fall through: retry (destination check failed or non-IMAP move provider)
                print("[Queue] UID resolution failed for \(opType) \(currentOp.messageIds.first ?? "?") — will retry (not blocking account)")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
                return .haltLane
            }
            // Connection/transient error — reset op to queued and mark account failed.
            // NEVER drop on age alone — transient errors don't confirm the op is stale.
            // Staleness is confirmed by: messageNotFound (server says gone), or
            // uidResolutionFailed + destination check (not in source or destination).
            // failedAccounts prevents hammering within a single drain.
            let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
            print("[Queue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
            // Deep diagnostic on the failing op — fires once per (drain, opId) so a
            // stuck op that retries every drain doesn't fill the log. Dumps full op
            // fields, error structural unwrap, classifier results, and the DB rows
            // scoped to the exact message + the involved folders.
            if !context.diagnosedOpIds.contains(currentOp.id) {
                context.diagnosedOpIds.insert(currentOp.id)
                await logStuckOpDiagnostic(currentOp, error: error)
            }
            // Self-heal: a .move op whose destination Folder doesn't exist locally
            // is unsalvageable on retry. This happens when the account's folder list
            // was re-ingested (e.g., IMAP→OAuth migration changing "Deleted Messages"
            // → "TRASH") after the op was queued, leaving the op pointing at an
            // obsolete path. Drop the op rather than retry forever — the original
            // user intent ("remove from source folder") is honored by remote-state-
            // wins-on-conflict (ADR-IOS-001): if server already moved/deleted the
            // message, sync brings the truth in; if not, the user can re-issue.
            if currentOp.type == .move, let destPath = currentOp.destinationPath {
                let destMissing: Bool = (try? await dbPool.read { db in
                    try Folder.fetchOne(db, key: "\(currentOp.accountId):\(destPath)") == nil
                }) ?? false
                if destMissing {
                    print("[Queue] Self-heal: dropping \(opType) — destination Folder missing locally: \(currentOp.accountId):\(destPath)")
                    try? await retryWrite(dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    context.executedAny = true
                    return .proceed
                }
            }
            try? await retryWrite(dbPool, label: "Queue") { db in
                var updated = currentOp
                updated.status = PendingStatus.queued.rawValue
                // Bump retryCount on each failure so the value matches reality (and
                // is visible in [QueueDiag] dumps). Previously this stayed at 0
                // forever, masking the runaway-retry case where we observed
                // `retryCount=0 ageHours=217` on the same op.
                updated.retryCount += 1
                try updated.save(db)
            }
            context.failedAccounts.insert(currentOp.accountId)
            return .haltLane
        }
    }

    /// Returns true if the error indicates the message no longer exists (conflict — drop op).
    ///
    /// Matches three classes of signal:
    /// 1. `ProviderError.messageNotFound` — providers that classify explicitly.
    /// 2. `ProviderError.networkError` wrapping an HTTP 404. Must unwrap both the
    ///    `HTTPError.networkError(statusCode:)` shape (Exchange/Gmail providers throw
    ///    this — a plain Swift enum that does NOT bridge to `NSError` with code=404)
    ///    AND the `NSError(code: 404)` shape (other paths that throw `NSError` directly).
    /// 3. IMAP server-side rejection strings ("NONEXISTENT", "UID not found", etc.).
    ///
    /// Strict structural matches (1 and 2) are additionally surfaced via
    /// `isConfirmedGoneError`, which gates destructive header deletion.
    nonisolated func isMessageNotFoundError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 404 {
                return true
            }
            if (underlying as NSError).code == 404 { return true }
        }
        let desc = "\(error)"
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }

    /// Stricter sibling of `isMessageNotFoundError` used to decide whether we may also
    /// DELETE the local messageHeader row. Only fires on structural signals that
    /// unambiguously confirm the message is gone from the server:
    ///   - `ProviderError.messageNotFound` (providers that classify explicitly)
    ///   - HTTP 404 / 410 (server responded with a permanent not-found status)
    ///
    /// Deliberately does NOT match the string-matching fallback in
    /// `isMessageNotFoundError` — IMAP error descriptions can be noisy and we never
    /// want a false positive to permanently delete user data.
    nonisolated func isConfirmedGoneError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying,
               statusCode == 404 || statusCode == 410 {
                return true
            }
            let nsCode = (underlying as NSError).code
            if nsCode == 404 || nsCode == 410 { return true }
        }
        return false
    }

    /// Delete a single messageHeader (identified by its full primary key) that has
    /// been structurally confirmed gone from the server. The FK cascade removes the
    /// MessageReference children; the `messageBody` row is reclaimed by the routed
    /// release below (Stage D dropped that cascade — a content key is not a header
    /// id). The FTS row is removed on the same release.
    /// Safe to call with a headerId that isn't in the local DB — DELETE returns 0
    /// rows and FTS remove is idempotent.
    ///
    /// Scoped to the exact (accountId, folderPath, messageId) combination, NOT
    /// (accountId, messageId) alone: for IMAP, UIDs are per-folder so the same
    /// messageId can identify completely different messages across folders, and
    /// a broader delete would orphan unrelated rows.
    ///
    /// ONLY call this when `isConfirmedGoneError` returned true (Exchange/Gmail
    /// 404/410 or ProviderError.messageNotFound) or the IMAP-backfill miss-count
    /// threshold has been reached after an rfc822 confirmation. Never call on a
    /// transient connection error.
    /// 🚨 ORDERING CONTRACT (`MessageContentStore`): the content key and its scope
    /// are captured INSIDE the delete transaction, from the row about to go away,
    /// and the release happens AFTER that transaction commits. Reversed, the header
    /// still exists when owners are counted, the count is always ≥ 1, and the FTS
    /// row is never removed — a silent no-op every outcome-only test still passes.
    func deleteConfirmedGoneHeader(headerId: String, reason: String) async {
        let captured: MessageContentStore.CapturedContent?
        let existed: Bool
        do {
            (existed, captured) = try await dbPool.write {
                db -> (Bool, MessageContentStore.CapturedContent?) in
                guard let header = try MessageHeader.fetchOne(db, key: headerId) else {
                    return (false, nil)
                }
                let captured = try MessageContentStore.capture(header, db: db)
                try header.delete(db)
                return (true, captured)
            }
        } catch {
            print("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        print("[Gone] Deleted header \(headerId) — reason=\(reason)")
        if let captured {
            await MessageContentStore.releaseUnowned(
                captured.contentKey, scope: captured.scope,
                stores: [.searchIndex, .body], pool: dbPool)
        } else {
            // No account row to read a key space from — keep the pre-existing
            // unconditional removal rather than invent an owner. `.body` is part of
            // that pre-existing behaviour: the cascade deleted it here too.
            await MessageContentStore.release(
                ContentKey(rawValue: headerId), stores: [.searchIndex, .body], pool: dbPool)
        }
    }

    /// Deep-dive log for a failing PendingOperation. Gated by `context.diagnosedOpIds`
    /// so it fires at most once per drain per opId. Logs:
    ///   - Full op fields (accountId, folderPath, destinationPath, retryCount, …)
    ///   - Error structural unwrap (ProviderError → HTTPError statusCode, NSError domain/code)
    ///   - Classifier verdicts (isMessageNotFound, isConfirmedGone, isPermanentlyInvalid)
    ///   - DB rows scoped to the exact message + the involved folders:
    ///       * MessageHeader rows for each msgId in the op (any folder, same account)
    ///       * Source Folder row (accountId:folderPath)
    ///       * Destination Folder row (accountId:destinationPath)
    ///       * All Folders with role=.trash for the account (sanity check role lookup)
    func logStuckOpDiagnostic(_ op: PendingOperation, error: Error) async {
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        print("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        print("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        print("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) uidResolutionRetryCount=\(op.uidResolutionRetryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — confirms whether classifiers should/shouldn't match
        print("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            print("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                print("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            print("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        print("[QueueDiag] classifier: isMessageNotFoundError=\(isMessageNotFoundError(error)) isConfirmedGoneError=\(isConfirmedGoneError(error)) isPermanentlyInvalidError=\(isPermanentlyInvalidError(error))")

        // Message-scoped DB dump — only rows relevant to this op + its folders.
        do {
            try await dbPool.read { db in
                for msgId in op.messageIds {
                    let normalized = EmailFilter.normalizeMessageId(msgId)
                    let headers = try MessageHeader
                        .filter(
                            (Column("messageId") == msgId || Column("rfc822MessageId") == normalized) &&
                            Column("accountId") == op.accountId
                        )
                        .fetchAll(db)
                    if headers.isEmpty {
                        print("[QueueDiag] MessageHeader: NONE for msgId=\(msgId) normalized=\(normalized) account=\(op.accountId)")
                    } else {
                        for h in headers {
                            print("[QueueDiag] MessageHeader: id=\(h.id) folderId=\(h.folderId) folderPath=\(h.folderPath) messageId=\(h.messageId) rfc822=\(h.rfc822MessageId ?? "<nil>") isInInbox=\(h.isInInbox) isRead=\(h.isRead) actionTag=\(h.actionTag?.rawValue ?? "<nil>")")
                        }
                    }
                }

                let srcId = "\(op.accountId):\(op.folderPath)"
                if let src = try Folder.fetchOne(db, key: srcId) {
                    print("[QueueDiag] Folder(source): id=\(src.id) name=\(src.name) path=\(src.path) role=\(src.role.rawValue)")
                } else {
                    print("[QueueDiag] Folder(source): NONE for id=\(srcId)")
                }

                if let dest = op.destinationPath {
                    let destId = "\(op.accountId):\(dest)"
                    if let f = try Folder.fetchOne(db, key: destId) {
                        print("[QueueDiag] Folder(destination): id=\(f.id) name=\(f.name) path=\(f.path) role=\(f.role.rawValue)")
                    } else {
                        print("[QueueDiag] Folder(destination): NONE for id=\(destId)")
                    }
                }

                let trashFolders = try Folder
                    .filter(Column("accountId") == op.accountId && Column("role") == FolderRole.trash.rawValue)
                    .fetchAll(db)
                if trashFolders.isEmpty {
                    print("[QueueDiag] Folder(role=trash): NONE for account=\(op.accountId)")
                } else {
                    for f in trashFolders {
                        print("[QueueDiag] Folder(role=trash): id=\(f.id) name=\(f.name) path=\(f.path)")
                    }
                }
            }
        } catch {
            print("[QueueDiag] ERROR: scoped DB read failed: \(error)")
        }
        print("[QueueDiag] === end op=\(op.id) ===")
    }

    /// Returns true if the error indicates the operation is permanently invalid and should be dropped.
    /// E.g., Gmail rejects label modifications on system labels like DRAFT — these will never succeed.
    /// Only matches 400-level errors from REST providers (Gmail/Exchange) to avoid false positives.
    ///
    /// Must accept TWO underlying-error shapes — they come from different throw sites:
    ///   - `HTTPError.networkError(statusCode: 400)` — thrown by `request()` helpers via
    ///     `catch let e as HTTPError { throw ProviderError.networkError(underlying: e) }`.
    ///     This is a plain Swift enum; its NSError bridge gives `domain="TabMail.HTTPError"
    ///     code=1` (the enum case ordinal), NOT `code=400`. So the NSError-domain check
    ///     below would never match this shape — pattern-match the enum directly.
    ///   - `NSError(domain: "Gmail"|"Exchange", code: 400)` — thrown by retry-aware paths.
    nonisolated func isPermanentlyInvalidError(_ error: Error) -> Bool {
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 400 {
                return true
            }
            let ns = underlying as NSError
            if ns.code == 400 && (ns.domain == "Gmail" || ns.domain == "Exchange") {
                return true
            }
        }
        return false
    }

    func executeOperation(_ op: PendingOperation, provider: any EmailProvider) async throws {
        switch op.type {
        case .archive, .delete:
            // Legacy enum cases — all new ops use .move. No-op for any stale rows.
            return
        case .move:
            guard let dest = op.destinationPath else {
                print("[MoveTrace] ERROR: move op missing destinationPath")
                throw ProviderError.messageNotFound
            }
            // Self-move (source == dest) is a no-op — skip the provider call entirely.
            // This happens when archiving from All Mail on Gmail (source and dest both resolve
            // to __GMAIL_ALL_MAIL__). Treating as success lets the op be cleaned up normally.
            guard op.folderPath != dest else {
                print("[MoveTrace] executeOperation.move — no-op (source==dest): \(op.folderPath)")
                return
            }
            let opAgeMin = Date().timeIntervalSince(op.createdAt) / 60
            print("[MoveTrace] executeOperation.move — msgIds=\(op.messageIds) from=\(op.folderPath) to=\(dest) provider=\(type(of: provider)) accountId=\(op.accountId) opId=\(op.id) retryCount=\(op.retryCount) ageMin=\(String(format: "%.1f", opAgeMin))")
            try await provider.move(ids: op.messageIds, from: op.folderPath, to: dest)
            print("[MoveTrace] executeOperation.move — completed successfully")
        case .markRead:
            try await provider.markRead(ids: op.messageIds, folder: op.folderPath)
        case .markUnread:
            try await provider.markUnread(ids: op.messageIds, folder: op.folderPath)
        case .markFlagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: true, folder: op.folderPath)
        case .markUnflagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: false, folder: op.folderPath)
        case .setTag, .removeTag:
            // Action tags are local-only (ADR-IOS-036). Local state is already
            // applied at the call site; the op drains to a no-op so legacy
            // queued rows flush cleanly. No provider write.
            break
        case .markReplied:
            if let imap = provider as? IMAPProvider {
                try await imap.markReplied(ids: op.messageIds, folder: op.folderPath)
            }
            // Gmail/Exchange REST APIs don't support \Answered flag — local state preserved by sync
        case .markForwarded:
            if let imap = provider as? IMAPProvider {
                try await imap.markForwarded(ids: op.messageIds, folder: op.folderPath)
            }
            // Gmail/Exchange REST APIs don't support $Forwarded keyword — local state preserved by sync
        case .saveDraft:
            // messageIds[0] = local Draft table key (draftId)
            // folderPath = server-side Drafts folder path
            guard let draftId = op.messageIds.first else { return }
            try await DraftStore.shared.pushDraftToServer(
                draftId: draftId,
                provider: provider,
                draftsFolderPath: op.folderPath
            )
        case .deleteDraft:
            // messageIds[0] = serverDraftId (IMAP UID / Gmail ID)
            // folderPath = server-side Drafts folder path
            guard let serverDraftId = op.messageIds.first else { return }
            // Silently swallow 404/410: some providers (notably Gmail) auto-
            // delete a draft when the corresponding message is sent, so by the
            // time our queueDraftDelete runs the server row is already gone.
            // Treat "not found" as a successful delete.
            do {
                try await provider.deleteDraft(draftId: serverDraftId, draftsFolderPath: op.folderPath)
            } catch {
                let desc = String(describing: error).lowercased()
                let isNotFound = desc.contains("404") || desc.contains("410")
                    || desc.contains("not found") || desc.contains("notfound")
                    || desc.contains("does not exist")
                if isNotFound {
                    print("[Queue] deleteDraft: server draft \(serverDraftId) already gone — treating as success")
                } else {
                    throw error
                }
            }
        case .addUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, addLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] addUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider {
                try await imap.setUserLabel(messageId: msgId, keyword: labelId, add: true, folder: op.folderPath)
            }
        case .removeUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, removeLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] removeUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider {
                try await imap.setUserLabel(messageId: msgId, keyword: labelId, add: false, folder: op.folderPath)
            }
        }
    }

    /// On app launch, recover from any crash during the previous session.
    /// Resets inFlight ops back to queued (they were mid-execution when app died),
    /// then drains the entire queue. All operations are idempotent, so re-execution is safe.
    func reconcilePendingOperations() async {
        // Crash recovery MUST succeed — inFlight ops from the previous session are stuck
        // and will never drain unless reset to queued.
        try? await retryWrite(dbPool, label: "Queue") { db in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(db)
            if !staleOps.isEmpty {
                print("[Queue] Crash recovery: resetting \(staleOps.count) inFlight ops to queued")
                for op in staleOps {
                    var updated = op
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
            }
            // Clean up cancelled ops from previous session
            let cancelledCount = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(db)
            if cancelledCount > 0 {
                print("[Queue] Crash recovery: cleaned up \(cancelledCount) cancelled ops")
            }
        }
        await drainPendingQueue()
        await reconcileOutbox()
        await reconcileCalendarQueue()
    }
}
