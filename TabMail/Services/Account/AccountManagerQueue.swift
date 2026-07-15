/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

private enum QueueRecoveryError: LocalizedError {
    case invalidActionTag(String?)

    var errorDescription: String? {
        switch self {
        case .invalidActionTag(let value):
            return "Pending action-tag value is invalid: \(value ?? "<missing>")."
        }
    }
}

extension AccountManager {
    nonisolated private static func recentlyCompletedIdentityKey(
        accountId: String,
        folderPath: String,
        messageId: String,
        scope: MessageFieldScope
    ) -> String {
        switch scope {
        case .account:
            MessageIdentity.recentlyCompletedAccountKey(
                accountId: accountId,
                messageId: messageId
            )
        case .folder:
            MessageIdentity.recentlyCompletedFolderKey(
                accountId: accountId,
                folderPath: folderPath,
                messageId: messageId
            )
        }
    }

    private func recordRecentlyCompletedIdentities(
        messageIds: [String],
        accountId: String,
        folderPath: String,
        scope: MessageFieldScope
    ) {
        recordRecentlyCompleted(messageIds: Self.orderedUniqueMessageIds(messageIds.map {
            Self.recentlyCompletedIdentityKey(
                accountId: accountId,
                folderPath: folderPath,
                messageId: $0,
                scope: scope
            )
        }))
    }

    /// Publish exact directional membership provenance plus the provider-scoped
    /// generic identity. Destination entries carry their own folder so Gmail does
    /// not freeze label X just because a move completed between labels A and B.
    private func recordRecentlyCompletedDestructiveMemberships(
        sourceMessageIds: [String],
        destinationIdentities: [(messageId: String, folderPath: String)],
        accountId: String,
        sourceFolderPath: String,
        scope: MessageFieldScope
    ) {
        var keys: [String] = []
        for messageId in Self.orderedUniqueMessageIds(sourceMessageIds) {
            keys.append(Self.recentlyCompletedIdentityKey(
                accountId: accountId,
                folderPath: sourceFolderPath,
                messageId: messageId,
                scope: scope
            ))
            keys.append(MessageIdentity.membershipKey(
                accountId: accountId,
                folderPath: sourceFolderPath,
                messageId: messageId,
                membership: .removedSource
            ))
        }
        var seenDestinations = Set<String>()
        for destination in destinationIdentities {
            let membershipKey = MessageIdentity.membershipKey(
                accountId: accountId,
                folderPath: destination.folderPath,
                messageId: destination.messageId,
                membership: .addedDestination
            )
            guard seenDestinations.insert(membershipKey).inserted else { continue }
            keys.append(Self.recentlyCompletedIdentityKey(
                accountId: accountId,
                folderPath: destination.folderPath,
                messageId: destination.messageId,
                scope: scope
            ))
            keys.append(membershipKey)
        }
        recordRecentlyCompleted(messageIds: Self.orderedUniqueMessageIds(keys))
    }

    /// Publish field-specific lag protection in addition to the generic identity
    /// keys used by stale-row protection. Sync consumes these keys per field so a
    /// completed read toggle cannot suppress an unrelated remote flag change.
    private func recordRecentlyCompletedFieldState(
        messageIds: [String],
        accountId: String,
        folderPath: String,
        scope: MessageFieldScope,
        value: MessageIdentity.RecentlyCompletedFieldValue
    ) {
        let fieldIds = messageIds.map {
            switch scope {
            case .account:
                MessageIdentity.recentlyCompletedFieldKey(
                    accountId: accountId,
                    messageId: $0,
                    field: value.field
                )
            case .folder:
                MessageIdentity.recentlyCompletedFieldKey(
                    accountId: accountId,
                    folderPath: folderPath,
                    messageId: $0,
                    field: value.field
                )
            }
        }
        let valueIds = messageIds.map {
            switch scope {
            case .account:
                MessageIdentity.recentlyCompletedFieldValueKey(
                    accountId: accountId,
                    messageId: $0,
                    value: value
                )
            case .folder:
                MessageIdentity.recentlyCompletedFieldValueKey(
                    accountId: accountId,
                    folderPath: folderPath,
                    messageId: $0,
                    value: value
                )
            }
        }
        let genericIds = messageIds.map {
            Self.recentlyCompletedIdentityKey(
                accountId: accountId,
                folderPath: folderPath,
                messageId: $0,
                scope: scope
            )
        }
        recordRecentlyCompleted(
            messageIds: Self.orderedUniqueMessageIds(genericIds + fieldIds + valueIds)
        )
    }

    nonisolated private static func orderedUniqueMessageIds(_ messageIds: [String]) -> [String] {
        var seen = Set<String>()
        return messageIds.filter { seen.insert($0).inserted }
    }

    // MARK: - Persistent Action Queue

    /// Shared mutable state for a single drain owner's pass. Reference type
    /// so it can be threaded through sequential `executeSingleOp` calls
    /// without re-allocating. `internal` (not `private`) so tests can
    /// construct it directly to call `executeSingleOp`.
    final class DrainContext: Sendable {
        private struct State: Sendable {
            // op.id values that have already produced a [QueueDiag] deep-dump this drain.
            // Prevents log-spam on the same stuck op that retries every drain cycle.
            var diagnosedOpIds = Set<String>()
        }

        private let state = Mutex(State())

        func markDiagnosedIfNew(operationId: String) -> Bool {
            state.withLock { $0.diagnosedOpIds.insert(operationId).inserted }
        }
    }

    /// Outcome of a single claimed-op execution (`executeSingleOp`), used by
    /// the global FIFO drain loop in `drainPendingQueue` to decide whether it
    /// is safe to claim and execute the next frontier op.
    enum SingleOpOutcome: Sendable, Equatable {
        /// The op reached a terminal state this pass — either it completed
        /// successfully, or it was CONFIRMED stale/invalid and dropped
        /// (deleted). The drain may claim and execute the next frontier op.
        case proceed
        /// The op was restored to `.queued`, payload unchanged, for retry
        /// (its staleness/success could NOT be confirmed this pass). The
        /// drain MUST stop: this row is the protected frontier (§9.1), and a
        /// later row must never overtake an unresolved predecessor — running
        /// it would race the predecessor's eventual retry on the wire.
        case stopDrain
    }

    /// Atomically claim the protected frontier row — the first active
    /// (non-cancelled) row in durable SQLite insertion order (`rowid`; §9.1).
    /// Wall-clock `createdAt` is diagnostic metadata only and never
    /// participates in this ordering.
    ///
    /// Acquires the shared mutation gate exactly once and performs exactly
    /// one bounded GRDB write transaction — no provider I/O, no sleep, no
    /// retry. Walking from the front:
    ///   - a legacy `.cancelled` row (Undo's pre-Round-D status-cancellation
    ///     path) is physically deleted and the walk continues;
    ///   - an `.inFlight` row means another owner already holds the
    ///     frontier — return nil rather than steal or skip past it (single-
    ///     owner drain + startup `inFlight -> queued` reset should make this
    ///     unreachable, but the protected-frontier law is absolute);
    ///   - the first `.queued` row is claimed (`status = .inFlight`) and
    ///     returned.
    /// Returns nil when nothing is claimable, or when the gated transaction
    /// itself throws (logged, debug-gated) — either way the caller's drain
    /// loop stops advancing.
    private func claimFrontierOperation(database: PrioritizedDatabase) async -> PendingOperation? {
        let lease: PendingOperationMutationGate.Lease
        do {
            lease = try await pendingOperationMutationGate.acquire()
        } catch {
            return nil
        }
        defer { pendingOperationMutationGate.release(lease) }
        do {
            return try await database.write { db -> PendingOperation? in
                let ops = try PendingOperation.fetchAll(
                    db,
                    sql: "SELECT * FROM pendingOperation ORDER BY rowid ASC"
                )
                for var candidate in ops {
                    if candidate.status == PendingStatus.cancelled.rawValue {
                        _ = try PendingOperation.deleteOne(db, key: candidate.id)
                        print("[Queue] Op \(candidate.id.prefix(8)) cancelled by undo, deleted")
                        continue
                    }
                    if candidate.status == PendingStatus.inFlight.rawValue {
                        return nil
                    }
                    candidate.status = PendingStatus.inFlight.rawValue
                    try candidate.save(db)
                    return candidate
                }
                return nil
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] ERROR: Failed to claim frontier operation: \(error)")
            }
            return nil
        }
    }

    /// Retried gated GRDB write for durable queue-row lifecycle mutations
    /// (completion delete, stale/invalid drop, transient requeue, crash
    /// recovery). The backoff sleep between attempts runs OUTSIDE the gate —
    /// `attemptOnce()` acquires, writes, and releases (via `defer`) entirely
    /// within one iteration before the `catch` branch that sleeps is reached.
    /// Never call this with a body that performs provider I/O, and never call
    /// it while already holding the gate — it is not reentrant.
    ///
    /// This is also the durable-admission transaction wrapper (§9.3): every
    /// site that appends a `PendingOperation` — not just drain's own
    /// lifecycle writes — routes its local optimistic mutation plus the
    /// insert through this same gated helper, so local state, queue state,
    /// and the drain frontier stay one linearizable sequence. It is
    /// `nonisolated` (not `private`) so callers outside this file (actions,
    /// outbox, view models, notification routing) can call it directly —
    /// `AccountManager` being an actor does not by itself provide the
    /// mutual-exclusion this gate provides (§9.2). It is NOT reentrant:
    /// never call it from inside another gated region (another
    /// `retryGatedQueueWrite` body, or any other holder of
    /// `pendingOperationMutationGate`) — a second acquire from the same
    /// logical caller would deadlock against itself.
    ///
    /// The attempts run on a detached task so they do NOT inherit the
    /// caller's cancellation. This is load-bearing, not defensive: the gate's
    /// `acquire()` throws immediately once the calling task is cancelled, so
    /// a drain cancelled while completing its claimed frontier would leave
    /// that row `inFlight` forever. Under the protected-frontier rule (§9.1)
    /// `claimFrontierOperation` refuses to steal or skip an `inFlight` row,
    /// so one stranded row would wedge the ENTIRE global FIFO until the next
    /// process start re-ran crash recovery (§9.4 — a live process never
    /// re-runs that reset). Every body passed here is a bounded, idempotent
    /// terminal write that must land regardless of why the drain is ending.
    nonisolated func retryGatedQueueWrite<T: Sendable>(
        _ database: PrioritizedDatabase,
        label: String,
        maxAttempts: Int = 3,
        retryDelay: Duration = .milliseconds(100),
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        let gate = pendingOperationMutationGate
        // `Task.detached` does not inherit task-locals, and `PriorityGate`'s
        // write-tier selection IS a task-local. Re-bind both so detaching for
        // cancellation immunity cannot silently re-tier a queue write if a
        // caller is ever wrapped in `PriorityGate.background { }`/`normal { }`.
        let writePriorityOverride = PriorityGate.writePriorityOverride
        let inPrivilegedContext = PriorityGate.inPrivilegedContext
        return try await Task.detached {
            try await PriorityGate.$inPrivilegedContext.withValue(inPrivilegedContext) {
                try await PriorityGate.$writePriorityOverride.withValue(writePriorityOverride) {
                    func attemptOnce() async throws -> T {
                        let lease = try await gate.acquire()
                        defer { gate.release(lease) }
                        return try await database.write(body)
                    }
                    for attempt in 1...maxAttempts {
                        do {
                            return try await attemptOnce()
                        } catch {
                            print("[\(label)] Gated write failed (attempt \(attempt)/\(maxAttempts)): \(error)")
                            if attempt == maxAttempts { throw error }
                            try? await Task.sleep(for: retryDelay)
                        }
                    }
                    fatalError("Unreachable")
                }
            }
        }.value
    }

    /// Reset any `inFlight` row abandoned by a previous owner of the queue —
    /// generalizing the startup `inFlight -> queued` reset (§9.4,
    /// `recoverPendingMessageQueueAfterCrash`) from *process* start to
    /// *ownership* start.
    ///
    /// Why this is safe: §9.4 already establishes that resetting `inFlight`
    /// rows is sound "before any drain owner or provider call can exist". At
    /// process start that precondition is trivially true (nothing has run
    /// yet). But exactly one drain owner exists at a time — `drainPendingQueue`
    /// guards on `isDraining` and turns a second caller into a `needsRedrain`
    /// signal rather than a second claimant — so the SAME precondition holds
    /// at the start of EVERY ownership, not just the first one ever:
    ///   - a previous owner cannot still have a provider call outstanding —
    ///     `drainPendingQueue` awaits `queue.execute(...)` for each claimed
    ///     op, and `executeSingleOp`'s completion/requeue writes go through
    ///     `retryGatedQueueWrite`'s detached task, whose `.value` is awaited
    ///     before that call returns — so all of a previous owner's work has
    ///     landed before `isDraining` flips back to `false` in its `defer`;
    ///   - a concurrent owner cannot exist by construction of the
    ///     `isDraining` guard above.
    ///
    /// Therefore any row still `inFlight` when a NEW ownership begins was
    /// claimed by an owner that is now definitely gone without reaching its
    /// terminal write — a terminal GRDB write that failed every retry
    /// attempt, or any other unexpected early return between claim and
    /// completion (the cancellation case is already healed immediately by
    /// the detached write in `retryGatedQueueWrite`; this is the backstop for
    /// every OTHER cause). Under the protected-frontier rule (§9.1)
    /// `claimFrontierOperation` refuses to steal or skip such a row, and
    /// crash recovery does not re-run mid-session (`preparePendingQueueForExecution`
    /// caches successful preparation per `AppDatabase` instance) — so leaving
    /// one stranded would wedge the ENTIRE global FIFO until the next process
    /// start. This reset closes that wedge class regardless of cause.
    ///
    /// Runs once per ownership — immediately after `isDraining` is set, before
    /// the frontier-claiming loop below — rather than once per outer
    /// `while true` re-drain iteration: the SAME owner already resolves its
    /// previously claimed row via the ordinary per-op completion path before
    /// looping again, so a later iteration can never find a NEW abandoned row
    /// that this single upfront reset would have missed. Running it again per
    /// iteration would be harmless but purely redundant gated writes.
    private func resetAbandonedInFlightRowsAtOwnershipStart(
        database: PrioritizedDatabase
    ) async {
        do {
            let reset = try await retryGatedQueueWrite(database, label: "Queue ownership reset") { db in
                try Self.resetInFlightRowsToQueued(db)
            }
            if DebugModeManager.isLoggingEnabled(), reset > 0 {
                print("[Queue] Ownership-start reset: requeued \(reset) abandoned in-flight operation(s)")
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] Ownership-start reset failed: \(error)")
            }
        }
    }

    /// Drain the durable message-action queue: one global FIFO, one job at a
    /// time, in SQLite insertion (`rowid`) order (§9.1/§9.4). No lanes, no
    /// per-account concurrency, no batch splitting — a transient failure at
    /// the protected frontier stops the whole drain rather than letting a
    /// later row overtake it.
    ///
    /// Claim and completion/requeue both go through the shared
    /// `pendingOperationMutationGate`, but never while provider I/O (or a
    /// retry sleep) is in flight — `executeSingleOp`'s call to
    /// `executeOperation` runs entirely outside any gated region.
    ///
    /// The inner loop naturally re-observes ops inserted during the drain
    /// (each claim re-queries the table), so no separate "extra pass" step
    /// is needed. Skips drain when offline to prevent retry storms.
    func drainPendingQueue() async {
        guard NetworkMonitor.checkConnected() else { return }
        // No drain owner, claim, or action-provider call may exist before
        // crash recovery succeeds. Released bare provider-ID rows need no
        // conversion: they are token members by shape and execute through the
        // adapters' token path directly (PLAN_IDENTITY_HYBRID §5).
        guard var queueDatabase = await preparePendingQueueForExecution() else { return }
        let authorizationHook = pendingQueueAuthorizationHookForTesting
        pendingQueueAuthorizationHookForTesting = nil
        if let authorizationHook {
            await authorizationHook()
        }
        guard !Task.isCancelled else { return }
        guard !isDraining else {
            needsRedrain = true
            return
        }
        isDraining = true
        defer {
            isDraining = false
            needsRedrain = false
        }

        // Single-owner ownership-start reset (see doc comment above): must
        // run BEFORE the first `claimFrontierOperation`/provider call of this
        // ownership so a row stranded `inFlight` by a now-gone previous owner
        // can never wedge the frontier for the rest of the process lifetime.
        await resetAbandonedInFlightRowsAtOwnershipStart(database: queueDatabase)

        while true {
            needsRedrain = false
            pruneRecentlyCompleted()
            let ctx = DrainContext()
            let passDatabase = queueDatabase

            while !Task.isCancelled {
                guard let claimed = await claimFrontierOperation(database: passDatabase) else { break }
                guard let queue = workQueues[claimed.accountId] else {
                    // Cannot execute the frontier without its provider. Return it
                    // and stop: a later job must never overtake an unexecuted
                    // frontier. This blocks the drain only on a not-yet-connected
                    // provider — account removal already purges that account's
                    // rows (AccountManagerSetup.removeAccount), so a missing
                    // provider here is transient state, not an orphaned row.
                    print("[Queue] No provider for \(claimed.accountId) — returning frontier op \(claimed.id.prefix(8)) to queued and stopping drain")
                    await requeueClaimedOperation(id: claimed.id, database: passDatabase)
                    break
                }
                let provider = queue.provider
                // Outcome captured via Mutex (not a plain var) — the closure
                // passed to queue.execute is @Sendable, so it cannot capture a
                // mutable local var directly under Swift 6 strict concurrency.
                let outcomeBox = Mutex<SingleOpOutcome>(.proceed)
                await queue.execute(priority: .userAction) {
                    let result = await self.executeSingleOp(
                        claimed,
                        provider: provider,
                        context: ctx,
                        database: passDatabase
                    )
                    outcomeBox.withLock { $0 = result }
                }
                if outcomeBox.withLock({ $0 }) == .stopDrain { break }
            }

            // One owner remains visibly active across every requested re-drain.
            // Re-prepare here because a concurrent trigger may have installed a
            // replacement AppDatabase while this pass was awaiting provider I/O.
            guard needsRedrain, NetworkMonitor.checkConnected() else { break }
            var nextDatabase: PrioritizedDatabase?
            repeat {
                // Consume the request being prepared. A replacement-database caller
                // that arrives during this await sets the flag again, forcing a retry
                // against the newest AppDatabase if this preparation becomes obsolete.
                needsRedrain = false
                nextDatabase = await preparePendingQueueForExecution()
            } while nextDatabase == nil
                && needsRedrain
                && NetworkMonitor.checkConnected()
            guard let nextDatabase else { break }
            queueDatabase = nextDatabase
        }
    }

    /// Return a claimed (`.inFlight`) row to `.queued`, payload unchanged.
    /// Used when the drain cannot execute the claimed frontier (e.g. no
    /// registered provider yet) and by `executeSingleOp`'s transient-failure
    /// path. `internal` (not `private`) so tests can call it directly.
    @discardableResult
    func requeueClaimedOperation(
        id: String,
        database: PrioritizedDatabase? = nil
    ) async -> Bool {
        let queueDatabase = database ?? dbPool
        do {
            return try await retryGatedQueueWrite(queueDatabase, label: "Queue") { db -> Bool in
                guard var latest = try PendingOperation.fetchOne(db, key: id),
                      latest.status == PendingStatus.inFlight.rawValue else {
                    return false
                }
                latest.status = PendingStatus.queued.rawValue
                try latest.update(db)
                return true
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] CRITICAL: Failed to requeue claimed op \(id): \(error)")
            }
            return false
        }
    }

    func executeSingleOp(
        _ claimedOp: PendingOperation,
        provider: any EmailProvider,
        context: DrainContext,
        database: PrioritizedDatabase? = nil
    ) async -> SingleOpOutcome {
        let queueDatabase = database ?? dbPool
        let currentOp = claimedOp
        let opType = currentOp.type.rawValue

        do {
            try await withTimeout(
                seconds: SyncConfig.pendingOperationTimeoutSeconds
            ) {
                try await self.executeOperation(
                    currentOp,
                    provider: provider,
                    database: queueDatabase
                )
            }
            // TOCTOU fix: publish recent protection BEFORE deleting PendingOp.
            // Sync engine has two guards against re-inserting moved messages:
            //   1. pendingDestructiveIds — sampled before the actor map and reloaded
            //      inside the sync write transaction
            //   2. exact directional membership keys in recentlyCompleted — sampled
            //      between them
            // Publishing first and consuming DB→actor→DB keeps at least one visible:
            //   - Before step 3 (delete): one pending snapshot catches it
            //   - After step 2 (record): the exact source-membership key catches it
            // If app crashes between steps 2 and 3, the PendingOp re-executes (idempotent).

            // Step 1: Record in recentlyCompleted (30s TTL) BEFORE deleting PendingOp.
            // Bridges the gap between PendingOp deletion and server-side state propagation.
            // Durable message actions already contain canonical RFC Message-IDs, so
            // protection never reads or publishes transient provider resource IDs.
            let completedIds = claimedOp.messageIds
            switch currentOp.type {
            case .archive, .delete, .move:
                let destinationIdentities: [(messageId: String, folderPath: String)]
                if let destinationPath = currentOp.destinationPath {
                    destinationIdentities = completedIds.map { ($0, destinationPath) }
                } else {
                    destinationIdentities = []
                }
                recordRecentlyCompletedDestructiveMemberships(
                    sourceMessageIds: completedIds,
                    destinationIdentities: destinationIdentities,
                    accountId: currentOp.accountId,
                    sourceFolderPath: currentOp.folderPath,
                    scope: provider.messageFieldScope
                )
            case .markRead, .markUnread:
                recordRecentlyCompletedFieldState(
                    messageIds: completedIds,
                    accountId: currentOp.accountId,
                    folderPath: currentOp.folderPath,
                    scope: provider.messageFieldScope,
                    value: .read(currentOp.type == .markRead)
                )
            case .markFlagged, .markUnflagged:
                recordRecentlyCompletedFieldState(
                    messageIds: completedIds,
                    accountId: currentOp.accountId,
                    folderPath: currentOp.folderPath,
                    scope: provider.messageFieldScope,
                    value: .flagged(currentOp.type == .markFlagged)
                )
            case .setTag, .removeTag:
                let completedTag: String?
                if currentOp.type == .setTag {
                    guard let tagValue = currentOp.tagValue,
                          ActionTag(rawValue: tagValue) != nil else {
                        throw QueueRecoveryError.invalidActionTag(currentOp.tagValue)
                    }
                    completedTag = tagValue
                } else {
                    completedTag = nil
                }
                recordRecentlyCompletedFieldState(
                    messageIds: completedIds,
                    accountId: currentOp.accountId,
                    folderPath: currentOp.folderPath,
                    scope: provider.messageFieldScope,
                    value: .actionTag(completedTag)
                )
            default:
                recordRecentlyCompletedIdentities(
                    messageIds: completedIds,
                    accountId: currentOp.accountId,
                    folderPath: currentOp.folderPath,
                    scope: provider.messageFieldScope
                )
            }

            // Step 3: Delete PendingOp. MUST succeed — remote op already completed.
            // If we don't delete, it re-executes on next drain (idempotent but wasteful).
            do {
                try await retryGatedQueueWrite(queueDatabase, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
            } catch {
                print("[Queue] CRITICAL: Failed to delete completed PendingOperation \(currentOp.id) after retries — will re-execute on next drain")
            }
            return .proceed
        } catch {
            // Law 4/5: the provider adapter — not the queue — normalizes an
            // authoritative stale/no-op outcome to a normal return. Once a
            // provider action method throws at all, the queue treats it
            // uniformly as transient/uncertain: NEVER drop on age or on a
            // guessed error shape. Staleness is confirmed only by the
            // provider's normal return; a throw here always means retry. The
            // frontier is protected (§9.1): stopping the drain here prevents
            // any later row from overtaking this unresolved one.
            let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
            print("[Queue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
            // Deep diagnostic on the failing op — fires once per (drain, opId) so a
            // stuck op that retries every drain doesn't fill the log. Dumps full op
            // fields, error structural unwrap, and the DB rows scoped to the exact
            // message + the involved folders.
            if context.markDiagnosedIfNew(operationId: currentOp.id) {
                await logStuckOpDiagnostic(
                    currentOp,
                    error: error,
                    database: queueDatabase
                )
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
                let destMissing: Bool = (try? await queueDatabase.read { db in
                    try Folder.fetchOne(db, key: "\(currentOp.accountId):\(destPath)") == nil
                }) ?? false
                if destMissing {
                    print("[Queue] Self-heal: dropping \(opType) — destination Folder missing locally: \(currentOp.accountId):\(destPath)")
                    try? await retryGatedQueueWrite(queueDatabase, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    return .proceed
                }
            }
            try? await retryGatedQueueWrite(queueDatabase, label: "Queue") { db in
                var updated = currentOp
                updated.status = PendingStatus.queued.rawValue
                // Bump retryCount on each failure so the value matches reality (and
                // is visible in [QueueDiag] dumps). Previously this stayed at 0
                // forever, masking the runaway-retry case where we observed
                // `retryCount=0 ageHours=217` on the same op. Diagnostics-only —
                // never a drop policy.
                updated.retryCount += 1
                try updated.save(db)
            }
            return .stopDrain
        }
    }

    /// Delete a single messageHeader (identified by its full primary key) that has
    /// been structurally confirmed gone from the server. FK CASCADE removes the
    /// MessageBody + MessageReference children. The FTS row is removed out-of-band.
    /// Safe to call with a headerId that isn't in the local DB — DELETE returns 0
    /// rows and FTS remove is idempotent.
    ///
    /// Scoped to the exact (accountId, folderPath, messageId) combination, NOT
    /// (accountId, messageId) alone: for IMAP, UIDs are per-folder so the same
    /// messageId can identify completely different messages across folders, and
    /// a broader delete would orphan unrelated rows.
    ///
    /// ONLY call this on a structurally confirmed permanent-gone signal
    /// (`isHttpGoneStatus` — Exchange/Gmail HTTP 404/410) or the IMAP-backfill
    /// miss-count threshold reached after an rfc822 confirmation. Never call
    /// on a transient connection error. The generic `PendingOperation` drain
    /// no longer calls this (Round E/Law 5 — the queue does not interpret
    /// provider error types or delete local headers); `BackfillBodyQueue` and
    /// `ActiveBodyQueue` remain the callers.
    func deleteConfirmedGoneHeader(
        headerId: String,
        reason: String,
        database: PrioritizedDatabase? = nil
    ) async {
        let queueDatabase = database ?? dbPool
        let existed: Bool
        do {
            existed = try await queueDatabase.write { db in
                try MessageHeader.deleteOne(db, key: headerId)
            }
        } catch {
            print("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        print("[Gone] Deleted header \(headerId) — reason=\(reason)")
        do {
            try await SearchIndex.shared.removeMessages(headerIds: [headerId])
        } catch {
            print("[Gone] FTS remove failed for \(headerId): \(error)")
        }
    }

    /// Deep-dive log for a failing PendingOperation. Gated by `context.diagnosedOpIds`
    /// so it fires at most once per drain per opId. Logs:
    ///   - Full op fields (accountId, folderPath, destinationPath, retryCount, …)
    ///   - Error structural unwrap (ProviderError → HTTPError statusCode, NSError domain/code)
    ///   - DB rows scoped to the exact message + the involved folders:
    ///       * MessageHeader rows for each msgId in the op (any folder, same account)
    ///       * Source Folder row (accountId:folderPath)
    ///       * Destination Folder row (accountId:destinationPath)
    ///       * All Folders with role=.trash for the account (sanity check role lookup)
    func logStuckOpDiagnostic(
        _ op: PendingOperation,
        error: Error,
        database: PrioritizedDatabase? = nil
    ) async {
        let queueDatabase = database ?? dbPool
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        print("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        print("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        print("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — diagnostic only (Round E/Law 5: the queue
        // no longer interprets provider error types to make decisions).
        print("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            print("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                print("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            print("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        // No provider-error classifier verdicts to print here (Round E/Law
        // 5): the generic queue no longer interprets provider error types —
        // ANY throw is uniformly transient/uncertain. The structural unwrap
        // above is diagnostic only.

        // Message-scoped DB dump — only rows relevant to this op + its folders.
        do {
            try await queueDatabase.read { db in
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

    func executeOperation(
        _ op: PendingOperation,
        provider: any EmailProvider,
        database: PrioritizedDatabase? = nil
    ) async throws {
        switch op.type {
        case .archive, .delete:
            // Legacy enum cases — all new ops use .move. No-op for any stale rows.
            break
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
            try await provider.markReplied(ids: op.messageIds, folder: op.folderPath)
        case .markForwarded:
            try await provider.markForwarded(ids: op.messageIds, folder: op.folderPath)
        case .saveDraft:
            // messageIds[0] = local Draft table key (draftId)
            // folderPath = server-side Drafts folder path
            guard let draftId = op.messageIds.first else { return }
            try await DraftStore.shared.pushDraftToServer(
                draftId: draftId,
                provider: provider,
                draftsFolderPath: op.folderPath,
                database: database ?? dbPool
            )
        case .deleteDraft:
            // messageIds[0] = serverDraftId (IMAP UID / Gmail ID)
            // folderPath = server-side Drafts folder path
            guard let serverDraftId = op.messageIds.first else { return }
            // Every provider normalizes "already gone" (Gmail auto-deletes a
            // draft when its message sends; Exchange/IMAP likewise) to a
            // normal return internally (Law 4) — no queue-side string match.
            try await provider.deleteDraft(draftId: serverDraftId, draftsFolderPath: op.folderPath)
        case .addUserLabel:
            guard let labelId = op.userLabelId else { return }
            try await provider.setUserLabel(
                ids: op.messageIds,
                labelId: labelId,
                present: true,
                folder: op.folderPath
            )
        case .removeUserLabel:
            guard let labelId = op.userLabelId else { return }
            try await provider.setUserLabel(
                ids: op.messageIds,
                labelId: labelId,
                present: false,
                folder: op.folderPath
            )
        }
    }

    /// Shared preparation flight for every message-queue execution entry
    /// point: crash recovery (`inFlight -> queued` reset + legacy row cleanup)
    /// bound to the exact active `AppDatabase` instance. No row has been
    /// claimed and `isDraining` is still false while it runs. A failed flight
    /// publishes no readiness; the next external drain trigger retries the
    /// complete preparation.
    private func preparePendingQueueForExecution() async -> PrioritizedDatabase? {
        guard !Task.isCancelled else { return nil }
        guard let appDatabase = AppDatabase.shared.withLock({ $0 }) else {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] Preparation deferred: app database is unavailable")
            }
            return nil
        }
        if let preparedDatabase = pendingQueuePreparedDatabase,
           preparedDatabase === appDatabase {
            return PrioritizedDatabase(pool: appDatabase.dbPool)
        }

        let flight: PendingQueuePreparationFlight
        if var existing = pendingQueuePreparationFlight,
           existing.database === appDatabase {
            existing.participantCount += 1
            pendingQueuePreparationFlight = existing
            flight = existing
        } else {
            let database = PrioritizedDatabase(pool: appDatabase.dbPool)
            let preparationHook = pendingQueuePreparationHookForTesting
            let task = Task { [self] in
                try Task.checkCancellation()
                if let preparationHook {
                    await preparationHook()
                    try Task.checkCancellation()
                }
                try await recoverPendingMessageQueueAfterCrash(using: database)
            }
            flight = PendingQueuePreparationFlight(
                id: UUID(),
                database: appDatabase,
                task: task,
                participantCount: 1
            )
            pendingQueuePreparationFlight = flight
        }

        let result = await flight.task.result
        let isCurrentDatabase = AppDatabase.shared.withLock {
            $0.map { $0 === flight.database } ?? false
        }
        guard pendingQueuePreparationFlight?.id == flight.id else {
            guard isCurrentDatabase,
                  pendingQueuePreparedDatabase.map({ $0 === flight.database }) == true,
                  !Task.isCancelled else {
                return nil
            }
            return PrioritizedDatabase(pool: flight.database.dbPool)
        }

        pendingQueuePreparationFlight = nil
        switch result {
        case .success where isCurrentDatabase:
            pendingQueuePreparedDatabase = flight.database
            guard !Task.isCancelled else { return nil }
            return PrioritizedDatabase(pool: flight.database.dbPool)
        case .success:
            return nil
        case .failure(let error):
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] Preparation deferred: \(error)")
            }
            return nil
        }
    }

    /// Shared UPDATE for both the once-per-process startup recovery
    /// (`recoverPendingMessageQueueAfterCrash`) and the once-per-ownership
    /// reset (`resetAbandonedInFlightRowsAtOwnershipStart`). Deliberately
    /// does NOT include the legacy `.cancelled`/`.archive`/`.delete`/
    /// `.setTag`/`.removeTag` row deletion below — that cleanup is a
    /// startup-only concern and must never run at ordinary ownership start.
    nonisolated private static func resetInFlightRowsToQueued(_ db: Database) throws -> Int {
        try db.execute(
            sql: "UPDATE pendingOperation SET status = ? WHERE status = ?",
            arguments: [PendingStatus.queued.rawValue, PendingStatus.inFlight.rawValue]
        )
        return db.changesCount
    }

    /// Runs before any drain owner exists, but gated anyway (§9.4) so a
    /// concurrent enqueue cannot interleave with this reset/cleanup write.
    private func recoverPendingMessageQueueAfterCrash(
        using database: PrioritizedDatabase
    ) async throws {
        let counts = try await retryGatedQueueWrite(database, label: "Queue preparation") { db in
            let recoveredCount = try Self.resetInFlightRowsToQueued(db)
            try db.execute(
                sql: """
                    DELETE FROM pendingOperation
                    WHERE status = ? OR type IN (?, ?, ?, ?)
                    """,
                arguments: [
                    PendingStatus.cancelled.rawValue,
                    OperationType.archive.rawValue,
                    OperationType.delete.rawValue,
                    OperationType.setTag.rawValue,
                    OperationType.removeTag.rawValue,
                ]
            )
            return (recovered: recoveredCount, deletedLegacy: db.changesCount)
        }
        if DebugModeManager.isLoggingEnabled(),
           counts.recovered > 0 || counts.deletedLegacy > 0 {
            print(
                "[Queue] Startup recovery: requeued \(counts.recovered) in-flight "
                    + "operation(s), deleted \(counts.deletedLegacy) legacy no-op/cancelled row(s)"
            )
        }
    }

    /// Test-only process-restart seam for a database instance that remains open.
    /// Call only after the queue is quiescent; database-identity keying handles
    /// ordinary per-test database replacement automatically.
    func resetPendingQueuePreparationForTesting() async {
        precondition(!isDraining, "pending queue must be idle before resetting preparation")
        let oldTask = pendingQueuePreparationFlight?.task
        pendingQueuePreparationFlight = nil
        pendingQueuePreparedDatabase = nil
        pendingQueueAuthorizationHookForTesting = nil
        pendingQueuePreparationHookForTesting = nil
        oldTask?.cancel()
        if let oldTask {
            _ = await oldTask.result
        }
    }

    /// Narrow gate-primitive test seam: proves a concurrent caller actually
    /// joined the shared preparation flight before the test cancels it.
    func pendingQueuePreparationParticipantCountForTesting() -> Int {
        pendingQueuePreparationFlight?.participantCount ?? 0
    }

    /// Narrow test seam for proving that awaiting a drain also joins any
    /// requested re-drain instead of leaving unstructured queue work behind.
    func pendingQueueIsQuiescentForTesting() -> Bool {
        !isDraining && !needsRedrain
    }

    /// One-shot gate seam between successful preparation and the first queue
    /// access. It exists only to prove that a process-global database replacement
    /// cannot redirect an already-authorized drain onto the unprepared replacement.
    func setPendingQueueAuthorizationHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        pendingQueueAuthorizationHookForTesting = hook
    }

    /// Companion seam to the authorization hook above: suspends a NEW
    /// preparation flight at its start (captured at flight creation, so
    /// clearing it never affects an already-started flight).
    func setPendingQueuePreparationHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        pendingQueuePreparationHookForTesting = hook
    }

    /// On app launch, recover from a previous crash, then drain the queue.
    /// Outbox and calendar recovery are independent and continue even when
    /// message-queue preparation fails transiently.
    func reconcilePendingOperations() async {
        if await preparePendingQueueForExecution() != nil {
            await drainPendingQueue()
        }
        await reconcileOutbox()
        await reconcileCalendarQueue()
    }
}
