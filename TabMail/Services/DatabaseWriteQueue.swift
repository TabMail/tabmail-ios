/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Priority tier for database WRITE scheduling. The single GRDB writer drains
/// the highest-priority non-empty tier first, so foreground work jumps ahead of
/// background bulk in the writer queue — it never waits behind it in SQLite's
/// un-reorderable writer FIFO. Mirrors `ProviderWorkQueue`'s tiered design
/// (`userAction`/`headerFetch`/`bodyFetch`); this is its DB-writer analogue.
enum WritePriority: Int, Comparable, Sendable {
    /// The user is waiting: the NSE→inbox merge, optimistic user actions
    /// (archive/move/send/tag), the unread-badge recount. Commits first.
    case priority = 0
    /// Foreground inbox catch-up: delta + full sync header writes. More urgent
    /// than deep background work (it populates the visible inbox) but yields to
    /// the merge and to a live user action.
    case normal = 1
    /// Deferrable bulk: header/body/deep backfill, AI + embedding precompute,
    /// maintenance (prune/evict/purge), FTS self-heal, drain-loop reconciliation.
    case background = 2

    static func < (lhs: WritePriority, rhs: WritePriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Serial, priority-ordered scheduler for the single GRDB writer. Every async DB
/// write flows through here (via `PrioritizedDatabase`), so a `.priority` write
/// (merge / user action / badge) JUMPS every queued lower-priority write instead
/// of waiting behind it. This fixes the race the cooperative gate couldn't: a
/// low-priority write that already entered GRDB's writer FIFO can't be reordered,
/// so the backlog has to wait HERE — in our queue — where priority still wins.
///
/// This is the DB-writer analogue of `ProviderWorkQueue`: same tiered-waiter
/// design, but `maxConcurrency = 1` (SQLite serializes writers anyway, so we keep
/// exactly ONE write in flight and let OUR queue decide who runs next).
///
/// Hard limit it cannot beat: SQLite can't preempt the transaction already
/// executing, so a `.priority` write waits ≤ ONE in-flight transaction — never
/// the whole backlog. Keep individual write transactions bounded.
///
/// Privileged (merge) section: while a merge holds the section
/// (`enterPrivileged`/`exitPrivileged`), `.normal` and `.background` waiters are
/// NOT dispatched between the merge's individual writes, so the merge runs
/// uncontended by bulk work (preserves the merge-vs-background invariant). Only
/// `.priority` peers (a live user action) may interleave — they're urgent too.
///
/// Cancellation: `acquire` deliberately does NOT honor Task cancellation — unlike
/// `ProviderWorkQueue`, a write already queued here runs to completion even if its
/// Task is cancelled. Writes are non-cancellable BY DESIGN (never-drop-user-intention:
/// a half-decided DB write must not be abandoned mid-flight). This does not leak a
/// permit or continuation — the waiter is still resumed and still runs `release()`.
/// So "mirrors `ProviderWorkQueue`" above refers to the tiered-waiter DISPATCH design
/// only, NOT that queue's cancellation contract.
actor DatabaseWriteQueue {
    static let shared = DatabaseWriteQueue()

    /// Serial: at most one write in flight (the GRDB writer is serial).
    private var active = false
    /// Depth of nested privileged (merge) sections. While > 0, only `.priority`
    /// waiters are dispatched — bulk work can't split the merge's writes.
    private var privilegedDepth = 0
    /// One waiter list per tier; index == `WritePriority.rawValue`. Drained
    /// highest-priority (tier 0) first.
    private var waiters: [[CheckedContinuation<Void, Never>]] = [[], [], []]

    /// Run `work` as the sole writer once it reaches the front of its tier. The
    /// slot is always released, including on throw.
    @discardableResult
    func execute<T: Sendable>(
        priority: WritePriority,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(priority)
        // DIAGNOSTIC (debug-gated): time the EXECUTION only (after the slot is held,
        // so this excludes queue-wait). A `.priority` write waits ≤ ONE in-flight
        // execution, so the longest exec here is the residual cap on merge latency.
        let execStart = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await work()
            markExec(priority, execStart)
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    /// Debug-gated: flag a write whose EXECUTION (not queue-wait) ran long — that's
    /// what a higher-priority write can't preempt. Threshold keeps the noise down.
    private func markExec(_ priority: WritePriority, _ start: Double) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if ms > 100 {
            BootProfiler.mark("DBwrite EXEC[\(priority)] in \(ms)ms")
        }
    }

    // MARK: - Privileged (merge) section

    /// Enter a privileged section. Pair with `exitPrivileged()`. While active,
    /// non-`.priority` writes don't start, so the merge's writes run back-to-back
    /// (waiting at most one in-flight bulk txn that was already running).
    func enterPrivileged() { privilegedDepth += 1 }

    /// Leave a privileged section; if the writer is idle, releases the bulk work
    /// that parked behind the merge.
    func exitPrivileged() {
        // Underflow guard (mirrors PriorityGate.end()): an unbalanced exit would
        // drive privilegedDepth negative, silently disabling the reservation (the
        // `privilegedDepth > 0` checks in acquire/nextWaiter would read false).
        guard privilegedDepth > 0 else { return }
        privilegedDepth -= 1
        if privilegedDepth == 0, !active, let next = nextWaiter() {
            active = true
            next.resume()
        }
    }

    // MARK: - Slot management (mirrors ProviderWorkQueue)

    private func acquire(_ priority: WritePriority) async {
        // A non-priority write may not START while a merge section is active —
        // even if the writer is momentarily idle between the merge's writes.
        let blockedByMerge = priority != .priority && privilegedDepth > 0
        if !active && !blockedByMerge {
            active = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[priority.rawValue].append(c)
        }
    }

    private func release() {
        if let next = nextWaiter() {
            next.resume()        // slot transfers — `active` stays true
        } else {
            active = false
        }
    }

    /// Highest-priority eligible waiter (tier 0 first). While a merge section
    /// runs, only the `.priority` tier is eligible.
    private func nextWaiter() -> CheckedContinuation<Void, Never>? {
        let lastTier = privilegedDepth > 0 ? WritePriority.priority.rawValue : waiters.count - 1
        for tier in 0...lastTier where !waiters[tier].isEmpty {
            return waiters[tier].removeFirst()
        }
        return nil
    }

    // MARK: - Telemetry (tests)

    /// True while a write holds the single slot.
    var isWriting: Bool { active }
    /// Total writes parked across all tiers.
    var queuedCount: Int { waiters.reduce(0) { $0 + $1.count } }
}
