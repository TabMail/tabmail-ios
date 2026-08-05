/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import os

/// Cooperative gate that lets the privileged NSE→inbox merge run without heavy
/// BACKGROUND LOOPS (reply precompute, embedding, body/header backfill, FTS
/// self-heal) contending for the cooperative thread pool. The loops call
/// `yield()` at their chunk boundaries; it parks them while a merge section is
/// active, so a CPU-heavy loop pauses BETWEEN iterations for the merge.
///
/// DB-write ORDERING is a separate concern, owned by `DatabaseWriteQueue`: every
/// `PrioritizedDatabase.write` runs through that serial, priority-ordered
/// scheduler, so a `.priority` write (merge / user action / badge) jumps ahead of
/// queued background writes in the single GRDB writer. This gate no longer does
/// write ordering — it only governs the loop-boundary yields.
///
/// Tiers for writes are chosen by CONTEXT (see `PrioritizedDatabase.effectivePriority`):
/// - the privileged merge (`privileged { }`, sets `inPrivilegedContext`) → `.priority`;
/// - an explicit override (`background { }` / `normal { }`, sets
///   `writePriorityOverride`) for code shared across tiers (drain loops, the
///   shared `BodyFetchProcessor`, foreground sync);
/// - otherwise the pool's own tier (`PrioritizedDatabase.priority`).
///
/// NO DEADLOCK: code inside `privileged { }` sets `inPrivilegedContext`, and
/// `yield()` returns immediately for it — so the merge's own work never waits on
/// the gate it holds.
actor PriorityGate {
    static let shared = PriorityGate()

    /// True within a `privileged { }` scope and the tasks it spawns. A `yield()`
    /// from such a task NEVER parks — it IS the work everyone else yields to — and
    /// the read-through merge skips itself when this is set (recursion guard).
    @TaskLocal static var inPrivilegedContext = false

    /// Write-tier override for a `background { }` / `normal { }` scope and the
    /// structured tasks it spawns. Lets code shared across tiers (the drain loops,
    /// `BodyFetchProcessor`, foreground sync) pick its write tier without changing
    /// which pool it writes through. `nil` → use the pool's own tier.
    @TaskLocal static var writePriorityOverride: WritePriority? = nil

    /// Active privileged (merge) sections. Background loops yield while > 0.
    private var privilegedCount = 0
    /// Background loops parked in `yield()`, resumed when the gate fully clears.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True while a privileged (merge) section is active (telemetry/tests).
    var isPrivileged: Bool { privilegedCount > 0 }

    // MARK: - Privileged (merge) section

    /// Enter a privileged section. Pair with `end()` — prefer `privileged { }`.
    func begin() {
        privilegedCount += 1
    }

    /// Leave a privileged section; wakes parked loops when the gate fully clears.
    func end() {
        guard privilegedCount > 0 else { return }
        privilegedCount -= 1
        if privilegedCount == 0 {
            let resume = waiters
            waiters.removeAll()
            for c in resume { c.resume() }
        }
    }

    // MARK: - Yield (background loops)

    /// Park the caller while a merge section is active; returns at once when clear
    /// OR when the caller is itself the privileged context. Called by background
    /// loops at their chunk boundaries (NOT by `DatabaseWriteQueue`). Cheap (one
    /// actor hop) when clear.
    func yield(_ label: @autoclosure () -> String = "") async {
        // The privileged context is exempt — it's the work everyone yields TO.
        if PriorityGate.inPrivilegedContext { return }
        guard privilegedCount > 0 else { return }
        #if DEBUG
        print("[PriorityGate] \(label()) parked — merge in flight")
        #endif
        while privilegedCount > 0 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
    }

    // MARK: - Brackets

    /// Bracket privileged (merge) work. Raises the gate (so background loops
    /// yield), reserves the `DatabaseWriteQueue` privileged section (so background
    /// writes don't split the merge's writes), and sets `inPrivilegedContext` for
    /// the duration. `body` runs in the caller's isolation.
    static func privileged<T>(_ body: () async throws -> T) async rethrows -> T {
        await shared.begin()
        await DatabaseWriteQueue.shared.enterPrivileged()
        do {
            let result = try await PriorityGate.$inPrivilegedContext.withValue(true, operation: body)
            await DatabaseWriteQueue.shared.exitPrivileged()
            await shared.end()
            return result
        } catch {
            await DatabaseWriteQueue.shared.exitPrivileged()
            await shared.end()
            throw error
        }
    }

    /// Run `body` (and the structured tasks it spawns) with its DB writes tagged
    /// `.background`. The task-local counterpart of `AppDatabase.backgroundPool`,
    /// for code paths shared with higher-tier callers (e.g. `BodyFetchProcessor`,
    /// used by both the on-demand fetch and the backfill queue; the drain loops).
    /// NOTE: task-locals do NOT cross `Task.detached`; tag inside the detached body.
    static func background<T>(_ body: () async throws -> T) async rethrows -> T {
        try await PriorityGate.$writePriorityOverride.withValue(.background, operation: body)
    }

    /// Run `body`'s DB writes at `.normal` (foreground inbox catch-up). Used to
    /// tag delta/full sync above the deep background queues without giving it its
    /// own pool.
    static func normal<T>(_ body: () async throws -> T) async rethrows -> T {
        try await PriorityGate.$writePriorityOverride.withValue(.normal, operation: body)
    }
}

/// Priority-aware wrapper around the GRDB `DatabasePool`. This is the SINGLE
/// chokepoint for app database access: `AppDatabase.dbPool` / `.syncPool` /
/// `.backgroundPool` return instances tiered `.priority` / `.normal` /
/// `.background`, so EVERY app write flows through `DatabaseWriteQueue` at the
/// right tier. The raw pool is reachable only via `AppDatabase.rawPool` (for GRDB
/// APIs like `ValueObservation.publisher(in:)`).
///
/// It mirrors the exact `write`/`read`/`writeWithoutTransaction` overload set the
/// app uses, so it's a drop-in for the raw pool — but NOT a transparent one, and
/// the two async overloads each add behaviour:
/// - ASYNC WRITES run through `DatabaseWriteQueue.execute(priority:)`, where a
///   higher-tier write jumps ahead of queued lower-tier writes.
/// - ASYNC READS run the NSE read-through staging merge first and await it. See
///   the banner on `read` — this is a genuine, potentially multi-second
///   suspension, not a passthrough.
/// The SYNCHRONOUS overloads of both cannot `await`, so those do pass straight
/// through.
struct PrioritizedDatabase: Sendable {
    let pool: DatabasePool
    /// This wrapper's default write tier. `AppDatabase.dbPool` is `.priority`,
    /// `.syncPool` is `.normal`, `.backgroundPool` is `.background`. A
    /// `writePriorityOverride` (or the privileged merge) takes precedence.
    var priority: WritePriority = .priority

    /// The tier this write should run at: the privileged merge is always
    /// `.priority`; an explicit `background { }` / `normal { }` override wins next;
    /// otherwise the pool's own tier.
    private var effectivePriority: WritePriority {
        if PriorityGate.inPrivilegedContext { return .priority }
        if let override = PriorityGate.writePriorityOverride { return override }
        return priority
    }

    // MARK: Write

    /// Async write — runs through `DatabaseWriteQueue` at `effectivePriority`, so a
    /// higher-tier write jumps the lower-tier backlog instead of waiting behind it
    /// in SQLite's writer FIFO.
    ///
    /// `label` (diagnostic): names this write in a long `DBwrite EXEC` mark. The
    /// closure-entry timestamp captured here splits the EXEC into sched (GRDB
    /// writer-queue wait — a bypass sync write or busy writer connection) vs body
    /// (the closure's own execution) — see `DatabaseWriteQueue.execute`.
    @discardableResult
    func write<T: Sendable>(
        label: String? = nil,
        _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
        let bodyStart = OSAllocatedUnfairLock(initialState: 0.0)
        return try await DatabaseWriteQueue.shared.execute(
            priority: effectivePriority, label: label, bodyStart: bodyStart
        ) {
            try await pool.write { db in
                bodyStart.withLock { if $0 == 0 { $0 = CFAbsoluteTimeGetCurrent() } }
                return try updates(db)
            }
        }
    }

    /// Sync write — can't `await`, so it can't enter the queue; passes through.
    /// (Rare; used from non-async contexts like init/tests, and the synchronous
    /// backfill batch insert. The background loops' boundary `yield()` calls and
    /// their async writes gate those paths.)
    @discardableResult
    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try pool.write(updates)
    }

    // MARK: Read
    //
    // ⚠️ THE ASYNC OVERLOAD IS NOT A PASSTHROUGH. This banner used to read
    // "Read (passthrough — concurrent readers never block the writer)", and the
    // WAL half of that is still true: a read never blocks the single GRDB
    // writer. The false half is "passthrough". `read` below runs a full NSE
    // staging merge — durable header/body writes, an FTS flush — BEFORE it
    // reads, and awaits all of it. Stated negatively, because the wrong reading
    // of this banner cost a real defect: an `await dbPool.read` is NOT a cheap
    // operation, it is NOT bounded by the closure you passed it, and it does NOT
    // preserve your caller's actor isolation across the call. On an actor, it
    // is a suspension long enough for other actor-isolated work to run to
    // completion — measured at 7.6 s on a cold-I/O boot, and staging is pending
    // precisely on foreground return. Any latch, snapshot or claim your caller
    // established before it may be stale by the time the closure runs. The
    // synchronous overload IS a passthrough (it cannot await the merge).
    //
    // The defect this comment exists to prevent: `AccountManager.reconcileOutbox`
    // read the "no drain is in flight" latch, awaited this function, and by the
    // time it wrote, a drain had claimed a row and put its SMTP transaction on
    // the wire.

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        // READ-THROUGH staging merge: NSE staging is the delta of just-arrived mail.
        // Draining it here — before ANY async read — means every consumer (UI
        // render, silent push, BGAppRefresh, BGProcessing) sees it without a
        // per-call-site merge or any timing guesswork. Flag-gated, so it's ~µs
        // when nothing is staged; recursion-guarded so the merge's own reads pass
        // straight through. Sync reads can't await this; their one UI consumer
        // (the cold-boot sidebar) merges explicitly in `AppStartup.runIfNeeded`.
        await NSEDataBridge.mergeIfStagingPending()
        return try await pool.read(value)
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try pool.read(value)
    }

    // MARK: writeWithoutTransaction

    @discardableResult
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) rethrows -> T {
        try pool.writeWithoutTransaction(updates)
    }

    @discardableResult
    func writeWithoutTransaction<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        try await DatabaseWriteQueue.shared.execute(priority: effectivePriority) {
            try await pool.writeWithoutTransaction(updates)
        }
    }
}
