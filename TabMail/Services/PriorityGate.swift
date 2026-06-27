/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Cooperative priority gate that lets a PRIVILEGED path — the NSE→inbox merge /
/// boot critical path — run without contending with everything else for the
/// single GRDB writer, the FTS writer, or the cooperative thread pool.
///
/// ## Two tiers: privileged + normal
///
/// There are exactly two priorities, and they're chosen by CONTEXT, not by a
/// per-call tag:
/// - **privileged** — code running inside `privileged { }` (the merge). It holds
///   the gate AND is exempt from yielding (it's the work everyone else yields TO).
/// - **normal** — everything else. Its async DB writes yield to an active
///   privileged section by DEFAULT. There's nothing to classify and nothing to
///   forget: a new writer is automatically polite to the merge.
///
/// We deliberately do NOT have a separate "background, yields" vs "interactive,
/// never yields" split. Interactive writes are optimistic-UI (the row animates
/// away instantly; the write is already async/queued), so a normal write briefly
/// yielding to a fast merge is invisible — not worth a third tier.
///
/// ## Why a cooperative gate (not QoS, not a GRDB priority lane)
///
/// SQLite serializes writers FIFO and an in-progress transaction can't be
/// preempted; the cooperative thread pool can't be "reserved." QoS only
/// *deprioritizes* — under load it still runs and still holds the writer (tried
/// and reverted). So the privileged path raises a flag and every normal write
/// parks at a SAFE boundary (before it acquires the writer) until it clears. This
/// is the GRDB/FTS-writer analogue of the IMAP priority lock (ADR-IOS-014) and
/// user-activity prioritization (ADR-IOS-002).
///
/// ## Guarantees & bounds
///
/// - `privileged { }` is COUNT-based, so nested/concurrent privileged sections
///   compose; parked writers resume only when the LAST one ends.
/// - A write transaction already mid-flight when the gate is raised runs to
///   completion (SQLite can't be preempted), so the privileged path waits at most
///   ~one transaction — not the whole backfill run.
/// - NO DEADLOCK: code inside `privileged { }` sets the `inPrivilegedContext`
///   task-local, and `yield()` returns immediately for it — so the merge's own
///   writes never wait on the gate the merge itself is holding.
actor PriorityGate {
    static let shared = PriorityGate()

    /// True within a `privileged { }` scope and the tasks it spawns. A write from
    /// such a task NEVER yields — it IS the priority work everyone else yields to.
    /// This is what lets "every normal write yields" coexist with "the merge holds
    /// the gate" without the merge deadlocking against itself.
    @TaskLocal static var inPrivilegedContext = false

    /// Number of active privileged sections. The gate is "clear" at 0.
    private var privilegedCount = 0
    /// Normal writers parked in `yield()`, resumed when the gate clears.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True while any privileged section is active (telemetry/tests).
    var isPrivileged: Bool { privilegedCount > 0 }

    /// Enter a privileged section. Pair with `end()` — prefer `privileged { }`.
    func begin() {
        privilegedCount += 1
    }

    /// Leave a privileged section; wakes parked writers when the LAST one ends.
    func end() {
        guard privilegedCount > 0 else { return }
        privilegedCount -= 1
        guard privilegedCount == 0 else { return }
        let resume = waiters
        waiters.removeAll()
        for c in resume { c.resume() }
    }

    /// Park the caller while a privileged section is active; returns at once when
    /// the gate is clear OR when the caller is itself the privileged context.
    /// Called by `PrioritizedDatabase`'s async writes before they acquire the
    /// writer. Cheap (one actor hop) in the common case (gate clear).
    func yield(_ label: @autoclosure () -> String = "") async {
        // The privileged context is exempt — it's the work everyone yields TO.
        // (Without this the merge's own writes would wait on the gate it holds.)
        if PriorityGate.inPrivilegedContext { return }
        guard privilegedCount > 0 else { return }
        #if DEBUG
        print("[PriorityGate] \(label()) parked — privileged work in flight")
        #endif
        while privilegedCount > 0 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
    }

    /// Bracket privileged work so normal writes yield to it. Count-based, so
    /// concurrent privileged sections (e.g. a foreground merge racing a deep-link
    /// merge) compose. Sets `inPrivilegedContext` for the duration so the body's
    /// own writes are exempt. `body` runs in the caller's isolation — no Sendable
    /// boundary on `body` or its result.
    static func privileged<T>(_ body: () async throws -> T) async rethrows -> T {
        await shared.begin()
        do {
            let result = try await PriorityGate.$inPrivilegedContext.withValue(true, operation: body)
            await shared.end()
            return result
        } catch {
            await shared.end()
            throw error
        }
    }
}

/// Priority-aware wrapper around the GRDB `DatabasePool`. This is the SINGLE
/// chokepoint for app database access: `AppDatabase.dbPool` returns one of these,
/// so EVERY app write flows through here. The raw pool is reachable only via
/// `AppDatabase.rawPool` (for GRDB APIs like `ValueObservation.publisher(in:)`).
///
/// It mirrors the exact `write`/`read`/`writeWithoutTransaction` overload set the
/// app uses, so it's a drop-in for the raw pool — the ONLY behavioral change is:
/// an ASYNC write first `await`s `PriorityGate.shared.yield()`, which is a no-op
/// unless a privileged section is active and the caller isn't it. So normal
/// writes step aside for the merge automatically, with nothing to classify.
/// Reads don't contend the single writer (WAL) and sync writes can't `await`, so
/// both pass straight through.
struct PrioritizedDatabase: Sendable {
    let pool: DatabasePool

    // MARK: Write

    /// Async write — yields to an active privileged section first (no-op for the
    /// privileged context itself, and when the gate is clear).
    @discardableResult
    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        await PriorityGate.shared.yield("db-write")
        return try await pool.write(updates)
    }

    /// Sync write — can't `await`, so it can't yield; passes through. (Rare; used
    /// from non-async contexts like init/tests.)
    @discardableResult
    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try pool.write(updates)
    }

    // MARK: Read (passthrough — concurrent readers never block the writer)

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
        await PriorityGate.shared.yield("db-write")
        return try await pool.writeWithoutTransaction(updates)
    }
}
