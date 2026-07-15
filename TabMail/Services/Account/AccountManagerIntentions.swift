/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// Grouping key for `executeFold`'s phase-3 `.folder` move batching:
/// destination path AND whether the move is an Undo's inverse (ADR-IOS-060).
/// An Undo move must stay in its OWN `move()` call, separate from an ordinary
/// move that happens to share a destination within one connected component —
/// only an Undo-origin call triggers the bounded durable-admission
/// reconciliation in `optimisticMoveToFolder`.
private struct FoldMoveGroupKey: Hashable {
    let folderPath: String
    let isUndo: Bool
}

// MARK: - Intention Journal (ADR-IOS-058)

/// In-memory, Mutex-ordered journal of pending intention records, plus the
/// materialized derived overlay. The journal is the single choke point every
/// surface appends through (`AccountManager.record`); appends are synchronous
/// and totally ordered (one lock), which deletes the unstructured-Task
/// reorder race class between sibling gesture paths outright.
///
/// Lifetime model: a record lives from `append` until the fold executor that
/// consumed it COMPLETES its writes. Between consume and completion the
/// record's merged display is held in `inFlightDisplays` so the derived
/// overlay keeps covering the row while its write is in flight — the same
/// release-at-completion timing the overlay refcount provided (ADR-IOS-057).
/// The FIFO write queue is serial, so at most one component is ever in
/// flight; `inFlightDisplays` never sees cross-component contention.
final class IntentionJournal: Sendable {

    struct State {
        var records: [Intention] = []
        /// Ids covered by an already-enqueued (or in-retry) fold closure —
        /// appends to covered ids do NOT enqueue a second closure; the
        /// pending fold's component consume reaches them.
        var foldQueuedIds: Set<String> = []
        /// Consumed-but-executing display hold (see class doc).
        var inFlightDisplays: [String: AccountManager.PendingMutation] = [:]
        var inFlightSeqs: Set<UInt64> = []
        /// Receipts awaited by tools/notifications, keyed by record seq.
        var receipts: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextSeq: UInt64 = 0
    }

    private let state = Mutex<State>(State())

    // MARK: Append

    /// Append one record. Returns the record and whether the caller must
    /// enqueue a fold closure (false when an already-queued fold's component
    /// covers any of the record's ids — that fold will consume this record).
    func append(
        ids: [String],
        kind: Intention.Kind,
        displays: [String: AccountManager.PendingMutation],
        origin: IntentionOrigin
    ) -> (record: Intention, needsFold: Bool) {
        state.withLock { s in
            let record = Intention(ids: ids, kind: kind, displays: displays, origin: origin, seq: s.nextSeq)
            s.nextSeq += 1
            s.records.append(record)
            let covered = ids.contains { s.foldQueuedIds.contains($0) }
            s.foldQueuedIds.formUnion(ids)
            return (record, !covered)
        }
    }

    // MARK: Consume / complete

    /// Atomically remove and return the connected component of records
    /// reachable from `triggerId` (records sharing any member id,
    /// transitively — a batch record [A,B] bridges A's and B's records).
    /// Returned in seq order. Consumed records' merged displays move to the
    /// in-flight hold; their ids leave `foldQueuedIds` so later appends start
    /// a fresh fold that executes strictly after this one.
    func consumeComponent(triggerId: String) -> [Intention] {
        state.withLock { s in
            var componentIds: Set<String> = [triggerId]
            var consumedIndices: Set<Int> = []
            var changed = true
            while changed {
                changed = false
                for (index, record) in s.records.enumerated() where !consumedIndices.contains(index) {
                    guard record.ids.contains(where: { componentIds.contains($0) }) else { continue }
                    consumedIndices.insert(index)
                    if !componentIds.isSuperset(of: record.ids) {
                        componentIds.formUnion(record.ids)
                    }
                    changed = true
                }
            }
            guard !consumedIndices.isEmpty else {
                s.foldQueuedIds.remove(triggerId)
                return []
            }
            let consumed = consumedIndices.sorted().map { s.records[$0] }
            s.records = s.records.enumerated()
                .filter { !consumedIndices.contains($0.offset) }
                .map(\.element)
            s.foldQueuedIds.subtract(componentIds)
            for record in consumed {
                s.inFlightSeqs.insert(record.seq)
                for (id, mutation) in record.displays {
                    s.inFlightDisplays[id] = Self.merge(s.inFlightDisplays[id], mutation)
                }
            }
            return consumed
        }
    }

    /// Put consumed records back after a resolve READ ERROR (ADR-IOS-058
    /// throwing-resolve contract: read-error keeps the intention; vanished
    /// drops it). Re-marks their ids as fold-covered — the caller owns the
    /// single delayed retry re-enqueue, and interim appends must not
    /// double-enqueue. The in-flight display hold is left in place: the
    /// reinserted records re-derive the same field values, and the field-wise
    /// merge is idempotent, so the double-merge is harmless by construction.
    func reinsertAfterReadError(_ records: [Intention]) {
        guard !records.isEmpty else { return }
        state.withLock { s in
            s.records.append(contentsOf: records)
            s.records.sort { $0.seq < $1.seq }
            for record in records {
                s.foldQueuedIds.formUnion(record.ids)
                s.inFlightSeqs.remove(record.seq)
            }
        }
    }

    /// Mark consumed records fully executed: drop their in-flight display
    /// hold for ids with no remaining pending records, and collect the
    /// receipts to resume. Caller resumes the returned continuations OUTSIDE
    /// the lock.
    func completeExecution(_ consumed: [Intention]) -> [CheckedContinuation<Void, Never>] {
        state.withLock { s in
            var resumed: [CheckedContinuation<Void, Never>] = []
            for record in consumed {
                s.inFlightSeqs.remove(record.seq)
                if let receipt = s.receipts.removeValue(forKey: record.seq) {
                    resumed.append(receipt)
                }
            }
            let consumedIds = Set(consumed.flatMap(\.ids))
            for id in consumedIds {
                let stillPending = s.records.contains { $0.ids.contains(id) }
                if !stillPending {
                    s.inFlightDisplays.removeValue(forKey: id)
                }
            }
            return resumed
        }
    }

    /// Await the completion of the record with `seq`. Resumes immediately if
    /// the record has already fully executed — the check and the continuation
    /// store are one lock section, so a consume/complete racing this call
    /// cannot strand the continuation.
    func awaitCompletion(of seq: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { s in
                let stillPending = s.inFlightSeqs.contains(seq) || s.records.contains { $0.seq == seq }
                if stillPending {
                    s.receipts[seq] = continuation
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
    }

    // MARK: Derived overlay

    /// The derived overlay: in-flight display holds, then every pending
    /// record's displays merged in seq order. Pure merge of what the surfaces
    /// passed — byte-compatible with the imperative `registerMutation`
    /// semantics. Entry lifetime = "id has pending or in-flight records".
    func derivedOverlay() -> [String: AccountManager.PendingMutation] {
        state.withLock { s in
            var overlay = s.inFlightDisplays
            for record in s.records {
                for (id, mutation) in record.displays {
                    overlay[id] = Self.merge(overlay[id], mutation)
                }
            }
            return overlay
        }
    }

    /// Field-wise merge — the exact `registerMutation` semantics: a set field
    /// in `new` overwrites; an unset field preserves the existing value.
    static func merge(
        _ existing: AccountManager.PendingMutation?,
        _ new: AccountManager.PendingMutation
    ) -> AccountManager.PendingMutation {
        var merged = existing ?? AccountManager.PendingMutation()
        if let v = new.isRead { merged.isRead = v }
        if let v = new.folderId { merged.folderId = v }
        if let v = new.folderPath { merged.folderPath = v }
        if let v = new.isInInbox { merged.isInInbox = v }
        if let v = new.isFlagged { merged.isFlagged = v }
        if let v = new.actionTag { merged.actionTag = v }
        return merged
    }

    // MARK: Test seams

    /// Snapshot of pending (unconsumed) records — hygiene checks assert this
    /// drains back to empty. Mirrors `pendingIntentCyclesForTesting()`.
    func recordsForTesting() -> [Intention] {
        state.withLock { $0.records }
    }

    /// True when nothing is pending OR executing. PRODUCTION consumer: the
    /// journal-aware background flush (`awaitWriteQueueDrainOrTimeout`,
    /// ADR-IOS-058 round-8) loops the FIFO barrier on this so a `record()`
    /// whose fold-enqueue Task hasn't reached the actor is still committed
    /// before the WAL durability checkpoint. Tests use it as the strand-free
    /// post-drain assertion (via `isFullyDrainedForTesting`).
    func isFullyDrained() -> Bool {
        state.withLock { $0.records.isEmpty && $0.inFlightSeqs.isEmpty && $0.inFlightDisplays.isEmpty }
    }

    /// Test-readability alias for `isFullyDrained()` — kept so the dozens of
    /// existing post-drain assertions read as test seams at the call site.
    func isFullyDrainedForTesting() -> Bool {
        isFullyDrained()
    }

    /// TEST-ONLY: seed a derived-overlay display with no backing record —
    /// lets a test put an id "on the overlay" the way the old imperative
    /// `registerMutation` allowed, without appending a record or enqueuing a
    /// fold. Merges into `inFlightDisplays` (the same hold the fold executor
    /// uses to keep a row covered mid-write), so the seeded display appears
    /// in `derivedOverlay()`/`snapshotOverlay()` immediately and persists
    /// until `resetForTesting()` or a real fold's `completeExecution` clears
    /// it (harmless — completion only drops an id with no remaining pending
    /// records, and a test-seeded id has none by construction, so any real
    /// fold that touches the same id will naturally clear the seed too).
    func seedDisplayForTesting(id: String, mutation: AccountManager.PendingMutation) {
        state.withLock { s in
            s.inFlightDisplays[id] = Self.merge(s.inFlightDisplays[id], mutation)
        }
    }

    /// TEST-ONLY: clear ALL journal state — pending records, fold coverage,
    /// in-flight display holds and seqs. Resumes any parked receipt
    /// continuations BEFORE dropping them: a stranded `CheckedContinuation`
    /// hangs its awaiting Task forever, so teardown must never just discard
    /// `state.receipts` — mirrors `completeExecution`'s contract that every
    /// stored receipt is resumed exactly once.
    ///
    /// KNOWN DORMANT RACE (round-3 audit, documented not fixed — no live test
    /// path exercises it): `executeFold`'s throwing-resolve READ ERROR branch
    /// (`AccountManagerIntentions.swift` — `resolveHeadersForActionThrowing`
    /// throws) reinserts the consumed records and spawns an unstructured
    /// `Task` that sleeps `SyncConfig.intentionResolveRetryDelaySeconds`
    /// (1s) before re-enqueuing the fold. That Task is NOT cancelled by
    /// `resetForTesting()` — if a test triggers a read-error resolve and then
    /// calls `resetForTesting()` within the retry window, the in-flight retry
    /// Task survives the reset and re-appends/re-executes against the fresh
    /// (post-reset) journal state once its sleep elapses. Benign today
    /// because no test exercises the throwing-resolve path across a reset,
    /// but a future test that adds that coverage must either await/cancel
    /// the retry Task or sequence past its delay before asserting
    /// post-reset state.
    func resetForTesting() {
        let parkedReceipts = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            let receipts = Array(s.receipts.values)
            s.records = []
            s.foldQueuedIds = []
            s.inFlightDisplays = [:]
            s.inFlightSeqs = []
            s.receipts = [:]
            return receipts
        }
        for receipt in parkedReceipts { receipt.resume() }
    }
}

// MARK: - record() + fold executor (ADR-IOS-058)

extension AccountManager {

    #if DEBUG
    /// TEST-ONLY one-shot fault injection for the PRIMARY resolve in
    /// `executeFold` — exercises the reinsert + paced-retry path (records
    /// stay, one delayed re-enqueue, intent executes on the retry). Consumed
    /// (reset to false) by the injection site on first use.
    /// ID-SCOPED (test-review round 3): the seam holds the TARGET id and
    /// fires only for a fold whose component contains it — a concurrent fold
    /// from another suite (`.serialized` does not cross suites) can neither
    /// consume the injection nor trip the arming test's polls.
    static let simulatePrimaryResolveFailureForTesting = Mutex<String?>(nil)

    /// TEST-ONLY recorder for the redundant-isRead SKIP branch's notification
    /// clear in `executeFold` phase 2: when the fold skips the isRead write
    /// because an out-of-band writer already made the row read, the executor
    /// still calls `NSEDataBridge.clearNotification` — this recorder is the
    /// only observable mirror of that side effect (the bridge has no
    /// inspection surface). Invoked with (accountId, messageId) alongside the
    /// `clearNotification` call in that skip branch ONLY. nil in production.
    static let notificationClearRecorderForTesting = Mutex<(@Sendable (String, String) -> Void)?>(nil)
    #endif

    /// ONE append API — every surface calls this and knows nothing else
    /// (ADR-IOS-058). Synchronously appends the record (totally ordered),
    /// updates the display overlay, and enqueues at most ONE fold-executor
    /// closure per open component on the FIFO write queue. Fire-and-forget:
    /// gesture paths call this and return; tools/notifications use
    /// `recordAndWait`. Returns the record's journal seq (discardable) — a
    /// caller that must stay synchronous (cannot itself `await`) but still
    /// needs to know when THIS record's fold completes (e.g.
    /// `MessageDetailViewModel`'s move-pin release, ADR-IOS-058 plan §9k) can
    /// separately `await intentionJournal.awaitCompletion(of: seq)` from an
    /// unstructured Task — that preserves this call's synchronous overlay
    /// update (relied on by callers reading `snapshotOverlay()` immediately
    /// after) while deferring only the completion wait.
    @discardableResult
    nonisolated func record(
        ids: [String],
        kind: Intention.Kind,
        displays: [String: PendingMutation],
        origin: IntentionOrigin
    ) -> UInt64 {
        recordReturningSeq(ids: ids, kind: kind, displays: displays, origin: origin)
    }

    /// `record` variant that awaits durable completion of the appended
    /// record's fold execution (the local GRDB write + `PendingOperation`
    /// insert have committed) — the ONLY tool/user difference: a tool awaits
    /// the receipt to report success; a finger does not.
    nonisolated func recordAndWait(
        ids: [String],
        kind: Intention.Kind,
        displays: [String: PendingMutation],
        origin: IntentionOrigin
    ) async {
        let seq = recordReturningSeq(ids: ids, kind: kind, displays: displays, origin: origin)
        await intentionJournal.awaitCompletion(of: seq)
    }

    @discardableResult
    nonisolated private func recordReturningSeq(
        ids: [String],
        kind: Intention.Kind,
        displays: [String: PendingMutation],
        origin: IntentionOrigin
    ) -> UInt64 {
        let (recorded, needsFold) = intentionJournal.append(ids: ids, kind: kind, displays: displays, origin: origin)
        if needsFold, let triggerId = recorded.ids.first {
            Task { await self.enqueueWrite { await self.executeFold(triggerId: triggerId) } }
        }
        return recorded.seq
    }

    /// The fold executor — the single resolution point (ADR-IOS-058).
    /// Consumes the trigger id's connected component, folds it to net intent,
    /// resolves row truth ONCE (throwing: a read error keeps the records and
    /// retries; a vanished row drops its intents), and executes the minimal
    /// writes through the EXISTING action methods — `markRead`/`markUnread`/
    /// `markFlagged`/`applyManualTag`/`move`/`archive`/`delete` — so sibling
    /// rfc822 expansion, unread-count math, `PendingOperation` insertion
    /// (atomic with the local write), notification posts, and badge recounts
    /// are inherited, never reimplemented.
    func executeFold(triggerId: String) async {
        let consumed = intentionJournal.consumeComponent(triggerId: triggerId)
        guard !consumed.isEmpty else {
            // A sibling component's consume already swallowed this trigger's
            // records (batch overlap) — benign no-op, mirrors the pre-existing
            // defensive no-cycle branch.
            return
        }

        var allIds: [String] = []
        var seen = Set<String>()
        for record in consumed {
            for id in record.ids where !seen.contains(id) {
                seen.insert(id)
                allIds.append(id)
            }
        }

        let resolved: [MessageHeader]
        do {
            #if DEBUG
            // TEST-ONLY one-shot, ID-SCOPED fault injection (pins
            // `primaryResolveReadErrorReinsertsAndRetriesWithoutDropping`):
            // fires only for the fold whose component contains the armed id,
            // so concurrent folds from OTHER suites can't consume it
            // (test-review round 3).
            let primaryFault = AccountManager.simulatePrimaryResolveFailureForTesting.withLock { target -> Bool in
                guard let t = target, allIds.contains(t) else { return false }
                target = nil
                return true
            }
            if primaryFault { throw ProviderError.notConnected }
            #endif
            resolved = try await resolveHeadersForActionThrowing(ids: allIds)
        } catch {
            // READ ERROR (not vanished): never drop user intention on a read
            // failure (ADR-IOS-058 throwing-resolve contract). Records go
            // back, and THIS task owns the single delayed retry — appends in
            // the interim are fold-covered and will be consumed by the retry.
            BackgroundSyncLogger.logInbox("[AccountManager] executeFold — resolve READ ERROR for \(allIds.count) id(s), reinserting \(consumed.count) record(s), retrying in \(SyncConfig.intentionResolveRetryDelaySeconds)s: \(error)")
            intentionJournal.reinsertAfterReadError(consumed)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(SyncConfig.intentionResolveRetryDelaySeconds * 1_000_000_000))
                // Task {} here inherits AccountManager isolation, so
                // enqueueWrite is a same-actor synchronous call.
                self.enqueueWrite { await self.executeFold(triggerId: triggerId) }
            }
            return
        }

        let headerById = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let folded = IntentionFold.fold(consumed)

        let vanishedCount = folded.perId.keys.filter { headerById[$0] == nil }.count
        if vanishedCount > 0 {
            // Row genuinely vanished (clean read, no durable row, no staged
            // row — e.g. deleted by an earlier queued op). Its intents drop;
            // the on-screen row is gone too, so dropping is safe (mirrors the
            // pre-existing vanished-row branch). An Undo's own inverse move
            // is folded exactly like any other move (ADR-IOS-060): a vanished
            // id here means it never resolved a member (see
            // `AccountManager.undoMove`), so there is nothing left to drop.
            BackgroundSyncLogger.logInbox("[AccountManager] executeFold — \(vanishedCount) id(s) vanished between record and fold, dropping their intents")
        }

        // Phase 2 — field writes, batched per direction. Each field compares
        // its net target against RESOLVED ROW TRUTH (ADR-IOS-057 round-3
        // semantics, carried): a write the row already reflects is skipped as
        // redundant (a perfect cancel-out is zero writes, zero
        // PendingOperations, zero badge churn); a row an out-of-band writer
        // touched mid-window (markAllAsRead, a sync flip) is corrected to the
        // user's latest visualized intent.
        var markReadBatch: [MessageHeader] = []
        var markUnreadBatch: [MessageHeader] = []
        var flagBatch: [MessageHeader] = []
        var unflagBatch: [MessageHeader] = []
        let orderedIds = folded.perId.keys.sorted()
        for id in orderedIds {
            guard let intents = folded.perId[id], let header = headerById[id] else { continue }
            if let target = intents.isRead {
                if target != header.isRead {
                    if target { markReadBatch.append(header) } else { markUnreadBatch.append(header) }
                } else if target {
                    // Row already read — an out-of-band writer beat the fold,
                    // so the WRITE is skipped as redundant. The gesture's
                    // bundled side effect must not be (round-1 audit): a
                    // delivered notification for this message would linger.
                    // markRead's own path clears it for written ids; this is
                    // the skipped-id mirror — idempotent, local-only.
                    NSEDataBridge.clearNotification(accountId: header.accountId, messageId: header.messageId)
                    #if DEBUG
                    // TEST-ONLY mirror of the clear above (see
                    // `notificationClearRecorderForTesting`) — scoped to THIS
                    // skip branch only, mirroring the finding it pins.
                    AccountManager.notificationClearRecorderForTesting.withLock { $0 }?(header.accountId, header.messageId)
                    #endif
                }
            }
            if let target = intents.isFlagged, target != header.isFlagged {
                if target { flagBatch.append(header) } else { unflagBatch.append(header) }
            }
            if case let .some(target) = intents.actionTag {
                // Tag WRITE gate (two-layer rule, ADR-IOS-058) — distinct from
                // Round D-0's retention-across-moves decision below: this only
                // gates a NEW/CHANGED tag value the user (or AI) is actively
                // setting via this record, not whether an EXISTING tag
                // survives a move (it always does now). The fold recorded the
                // location context the tag was gestured in (`actionTagGate` —
                // the then-pending move's destination); with no pending move
                // the gate falls back to the RESOLVED row's truth (out-of-band
                // eviction: a move by another client ran after the gesture;
                // the later action's clear wins — ADR-IOS-057 carried).
                let gate = intents.actionTagGate ?? header.isInInbox
                if !gate {
                    BackgroundSyncLogger.logInbox("[AccountManager] executeFold — skipping tag write for \(id), effective location is outside the inbox")
                } else if target != header.actionTag {
                    // previousTag semantics: feed applyManualTag the
                    // gesture-time visualized baseline, not drain-time DB
                    // truth (ADR-IOS-057, carried).
                    var tagHeader = header
                    if case let .some(baseline) = intents.actionTagBaseline {
                        tagHeader.actionTag = baseline
                    }
                    await applyManualTag(tagHeader, tag: target)
                }
            }
        }
        if !markReadBatch.isEmpty { await markRead(markReadBatch) }
        if !markUnreadBatch.isEmpty { await markUnread(markUnreadBatch) }
        if !flagBatch.isEmpty { await markFlagged(flagBatch, flagged: true) }
        if !unflagBatch.isEmpty { await markFlagged(unflagBatch, flagged: false) }

        // Phase 3 — moves, grouped by destination so batch surfaces keep
        // today's single write transaction + single batch PendingOperation.
        // Flags/tags executed BEFORE moves: flag STOREs target the known
        // source folder before an IMAP MOVE rekeys UIDs, and the resulting
        // PendingOperations' shared global-FIFO ordering (ADR-IOS-060 §9.1)
        // preserves serial-replay order on the wire.
        // Group `.folder` moves by (destination, isUndo) — NOT destination
        // alone: an Undo's inverse move must stay in its OWN `move()` call so
        // only ITS group triggers the bounded durable-admission
        // reconciliation (ADR-IOS-060 §9.3); an ordinary move sharing the
        // same destination within one connected component still batches
        // together as before.
        var byFolderGroup: [FoldMoveGroupKey: [MessageHeader]] = [:]
        var byRole: [FolderRole: [MessageHeader]] = [:]
        for id in orderedIds {
            guard let intents = folded.perId[id], let header = headerById[id],
                  let target = intents.moveTarget else { continue }
            switch target {
            case .folder(_, let folderPath, _):
                // move() re-resolves and same-folder-filters internally; this
                // pre-filter just avoids a pointless call for a row an earlier
                // queued op already landed at the destination.
                if header.folderPath != folderPath {
                    let key = FoldMoveGroupKey(folderPath: folderPath, isUndo: intents.moveOrigin == .undo)
                    byFolderGroup[key, default: []].append(header)
                }
            case .role(let role):
                // Undo never targets a role (its inverse is always an
                // explicit folder — see `UndoAccountCommand`), so no
                // origin-based split is needed here.
                byRole[role, default: []].append(header)
            }
        }
        for key in byFolderGroup.keys.sorted(by: {
            $0.folderPath != $1.folderPath ? $0.folderPath < $1.folderPath : !$0.isUndo && $1.isUndo
        }) {
            await move(byFolderGroup[key] ?? [], to: key.folderPath, isUndo: key.isUndo)
        }
        for role in byRole.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let messages = byRole[role] ?? []
            switch role {
            case .archive: await archive(messages)
            case .trash: await delete(messages)
            default:
                BackgroundSyncLogger.logInbox("[AccountManager] executeFold — unsupported role move \(role.rawValue), no-op")
            }
        }

        // Phase 4 — completion: drop the in-flight display holds and resume
        // awaited receipts.
        let receipts = intentionJournal.completeExecution(consumed)
        for receipt in receipts { receipt.resume() }
    }

}
