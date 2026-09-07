/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Debug-gated through the existing queue logging facade.
func queueLog(_ message: @autoclosure () -> String) {
    BackgroundSyncLogger.logQueue(message())
}

extension AccountManager {
    struct QueueDrainState {
        var suppressedAccountIds: Set<String> = []
        var deferredOperationIds: Set<String> = []
    }

    /// One global owner claims and settles one job before claiming another.
    /// Strict progress can yield and resume; a refusal defers its entire component
    /// once for this drain. Unresolved local writes stop before the next claim.
    func drainPendingQueue() async {
        guard !isDraining else {
            needsRedrain = true
            return
        }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                Task { await drainPendingQueue() }
            }
        }
        operationExecutor.beginDrain(using: self)
        guard await operationExecutor.recoverPendingSettlement(using: self) else { return }
        guard await recoverPendingRequeues() else { return }
        guard NetworkMonitor.checkConnected() else { return }
        operationExecutor.prepareDrain(using: self)

        var state = QueueDrainState()
        var claimedThisDrain = 0
        executor: while true {
            if operationExecutor.hasPendingSettlement || !pendingRequeues.isEmpty { break }
            switch await claimFrontierOperation(state: &state) {
            case .exhausted:
                queueLog("[Queue] drain complete — \(claimedThisDrain) operation(s) claimed this drain")
                break executor
            case .stop:
                break executor
            case .claimed(let job):
                claimedThisDrain += 1
                let disposition = await operationExecutor.attempt(operationId: job.id, using: self)
                guard await applyQueueDisposition(disposition, job: job, state: &state) else {
                    break executor
                }
            }
        }
        await operationExecutor.finishDrain(using: self)
    }

    enum FrontierClaim: Sendable {
        case exhausted
        case stop
        case claimed(QueueJob)
    }

    /// Policy, metadata projection and claim write share one snapshot. In-flight
    /// ownership is checked before eligibility; no later job can overtake it.
    private func claimFrontierOperation(state: inout QueueDrainState) async -> FrontierClaim {
        let policy = operationExecutor.schedulingPolicy(using: self)
        let suppressed = state.suppressedAccountIds
        let alreadyDeferred = state.deferredOperationIds
        struct WalkResult {
            var claimed: QueueJob?
            var newlyDeferred: Set<String> = []
            var stop = false
        }
        do {
            let result = try await dbPool.write { db -> WalkResult in
                var out = WalkResult()
                var deferred = alreadyDeferred
                let rows = try policy.rows(db)
                var componentById: [String: [String]] = [:]
                for chain in QueueScheduling.relatedChains(rows) {
                    let ids = chain.map(\.id)
                    for id in ids { componentById[id] = ids }
                }
                func deferChain(_ job: QueueJob, reason: String) {
                    let ids = componentById[job.id] ?? [job.id]
                    deferred.formUnion(ids)
                    out.newlyDeferred.formUnion(ids)
                    queueLog("[Queue] frontier \(job.id.prefix(8)) not attempted — \(reason); deferring \(ids.count) related row(s), no claim or retry charge")
                }
                for job in rows {
                    if deferred.contains(job.id) { continue }
                    if job.status == PendingStatus.cancelled.rawValue {
                        _ = try PendingOperation.deleteOne(db, key: job.id)
                        queueLog("[Queue] cancelled job \(job.id.prefix(8)) deleted")
                        continue
                    }
                    if job.status == PendingStatus.inFlight.rawValue {
                        queueLog("[Queue] frontier \(job.id.prefix(8)) is inFlight — stopping")
                        out.stop = true
                        return out
                    }
                    if suppressed.contains(job.accountId) {
                        deferChain(job, reason: "its account is suppressed for this drain")
                        continue
                    }
                    switch try policy.eligibility(id: job.id, db: db) {
                    case .notReady(let reason):
                        deferChain(job, reason: reason)
                        continue
                    case .retire(let diagnostic):
                        _ = try PendingOperation.deleteOne(db, key: job.id)
                        if let diagnostic { BackgroundSyncLogger.log(diagnostic) }
                        continue
                    case .ready:
                        break
                    }
                    // Column-only lifecycle write cannot overwrite domain operands.
                    try db.execute(sql: "UPDATE pendingOperation SET status = ?, everAttempted = 1 WHERE id = ?",
                        arguments: [PendingStatus.inFlight.rawValue, job.id])
                    var claimed = job
                    claimed.status = PendingStatus.inFlight.rawValue
                    out.claimed = claimed
                    return out
                }
                return out
            }
            state.deferredOperationIds.formUnion(result.newlyDeferred)
            if result.stop { return .stop }
            guard let job = result.claimed else { return .exhausted }
            return .claimed(job)
        } catch {
            queueLog("[Queue] ERROR: frontier claim failed: \(error) — this drain stops")
            return .stop
        }
    }

    /// The executor decides retry scope and charge; scheduling owns the resulting
    /// lifecycle write, tail order and per-drain suppression.
    func applyQueueDisposition(_ disposition: QueueAttemptDisposition,
        job: QueueJob, state: inout QueueDrainState) async -> Bool {
        switch disposition {
        case .completed, .progressed:
            return true
        case .blockedOnCommit:
            return false
        case .retryLater(let scope, let chargeRetry):
            if scope == .account { state.suppressedAccountIds.insert(job.accountId) }
            return await deferRelatedChainToTail(id: job.id, incrementRetryCount: chargeRetry, state: &state)
        }
    }

    /// Re-read live opaque dependencies so committed handoffs cannot leave a
    /// follower behind. All members move together in their current FIFO order.
    private func deferRelatedChainToTail(id: String, incrementRetryCount: Bool,
        state: inout QueueDrainState) async -> Bool {
        let policy = operationExecutor.schedulingPolicy(using: self)
        do {
            let movedIds = try await retryWrite(dbPool, label: "Queue deferral") { db -> [String] in
                let live = try policy.rows(db, excludingCancelled: true)
                guard live.contains(where: { $0.id == id }) else { return [] }
                let chain = QueueScheduling.relatedChains(live).first { $0.contains { $0.id == id } } ?? []
                let ids = chain.map(\.id)
                try PendingOperation.appendToTail(db, ids: ids, chargeRetryTo: incrementRetryCount ? id : nil)
                return ids
            }
            state.deferredOperationIds.formUnion(movedIds.isEmpty ? [id] : movedIds)
            queueLog("[Queue] deferral — moved \(movedIds.count) related row(s) after \(id.prefix(8)), preserving order; deferred for this drain")
            return true
        } catch {
            queueLog("[Queue] deferral — tail write for \(id.prefix(8)) failed: \(error); requeueing and stopping")
            await requeueOrRetain(id, incrementRetryCount: incrementRetryCount)
            return false
        }
    }

    /// RETURN A CLAIMED-BUT-UNEXECUTED OPERATION TO `queued`, AND KEEP OWNING IT
    /// IF THAT WRITE FAILS.
    ///
    /// The one implementation of a shape that used to be written out eight times
    /// as `try? await retryWrite(dbPool, label: "Queue") { PendingOperation
    /// .markQueued(...) }` — with the write's error discarded at every one of
    /// them. Discarding it is the defect: the producers of that failure are
    /// database-wide (GRDB suspension while backgrounded, ADR-IOS-041; a full
    /// disk; an I/O error at COMMIT), the row stays `inFlight`, the claim loop
    /// refuses `inFlight`, and no later pass in this process can ever pick it up.
    /// At the next launch `AppDatabase.recoverPreviousSessionResidue` deletes it
    /// if it is an `everAttempted` `.move` — a gesture that never reached the
    /// provider, lost with no crash at all.
    ///
    /// On success the id is released; on a throw this process KEEPS it, with the
    /// caller's own retry-count choice, and `recoverPendingRequeues` finishes the
    /// job at the top of the next drain. The write itself is unchanged: same
    /// `retryWrite`, same `markQueued`, same column semantics.
    ///
    /// `removeValue` on the success path matters as much as the insert: a site
    /// that requeues an id this process was still holding has resolved that
    /// ownership, and leaving a stale entry behind would stop later drains for a
    /// row that is already `queued`.
    func requeueOrRetain(_ id: String, incrementRetryCount: Bool = false) async {
        do {
            try await retryWrite(dbPool, label: "Queue") { db in
                try PendingOperation.markQueued(
                    db, id: id, incrementRetryCount: incrementRetryCount)
            }
            pendingRequeues.removeValue(forKey: id)
        } catch {
            pendingRequeues[id] = incrementRetryCount
            queueLog(
                "[Queue] requeue of \(id.prefix(8)) failed: \(error); this process keeps the row "
                    + "(retry charge: \(incrementRetryCount)) and recovers it at the next drain")
        }
    }

    /// FINISH EVERY REQUEUE THIS PROCESS COULD NOT COMMIT, BEFORE THE DRAIN
    /// CLAIMS ANYTHING.
    ///
    /// ⚠️ IT RUNS BEFORE THE `NetworkMonitor` CHECK, for the same reason
    /// `recoverPendingSettlement` does: the work is entirely LOCAL, and making
    /// it wait for connectivity would strand a claimed row behind an offline
    /// window it has nothing to do with.
    ///
    /// The write is `requeueIfInFlight`, not `markQueued`, and the guard is the
    /// point. This runs an unbounded time after the claim, so the row may since
    /// have been cancelled by the user, deleted by a local wipe or reset, or
    /// already requeued by the retained retirement that owns the same suffix.
    /// Only `inFlight` means "still claimed by this process and never executed".
    /// A ZERO-ROW UPDATE IS SUCCESS: whatever the row's state is now, this
    /// process no longer owns it, so the entry is released.
    ///
    /// A failure STOPS THE DRAIN with ownership retained. A database that cannot
    /// take this one-column write cannot claim, execute or retire anything else
    /// safely either, and starting a claim pass while an unresolved claimed row
    /// is invisible to the claim loop is exactly how a follower gets admitted
    /// alone ahead of its predecessor. It schedules no redrain of its own: the
    /// next drain from any ordinary entry point runs this again, first.
    ///
    /// - Returns: `false` when the drain must stop.
    private func recoverPendingRequeues() async -> Bool {
        guard !pendingRequeues.isEmpty else { return true }
        for (opId, incrementRetryCount) in pendingRequeues {
            do {
                try await retryWrite(dbPool, label: "Queue") { db in
                    try PendingOperation.requeueIfInFlight(
                        db, id: opId, incrementRetryCount: incrementRetryCount)
                }
                pendingRequeues.removeValue(forKey: opId)
                queueLog(
                    "[Queue] requeue recovery — released \(opId.prefix(8)); it is claimable again "
                        + "(or was already cancelled, wiped or requeued)")
            } catch {
                queueLog(
                    "[Queue] requeue recovery — \(opId.prefix(8)) still cannot be returned to "
                        + "`queued`: \(error); this process keeps the row and this drain stops")
                return false
            }
        }
        return true
    }

}
