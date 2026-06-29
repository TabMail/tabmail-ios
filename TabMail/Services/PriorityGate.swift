/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Cooperative priority gate that lets FOREGROUND / UI work — the NSE→inbox
/// merge, the badge recount, the inbox reload, optimistic user actions — run
/// without contending with heavy BACKGROUND queues for the single GRDB writer,
/// the FTS writer, or the cooperative thread pool.
///
/// ## Two tiers, line drawn at "foreground/UI vs. background queues"
///
/// Priority is the DEFAULT and is chosen by CONTEXT, not by a per-call tag:
/// - **priority** — everything that isn't explicitly background. Its async DB
///   writes open a short priority section (so background work yields to them)
///   and never yield themselves. This is the badge recount, the inbox reload,
///   optimistic action writes, sync, etc. — anything the user can perceive.
/// - **privileged** — the NSE→inbox merge / boot critical path, run inside
///   `privileged { }`. A STRONGER priority section: it also sets the
///   `inPrivilegedContext` task-local, which (a) exempts the merge's own writes
///   from yielding to the gate it holds and (b) guards the read-through merge in
///   `PrioritizedDatabase.read` against re-entering itself.
/// - **background** — the heavy queues (reply precompute, embedding, body/header
///   backfill), tagged via `AppDatabase.backgroundPool` (a stored flag) or
///   `PriorityGate.background { }` (a task-local, for code shared with priority
///   callers like `BodyFetchProcessor`). Their async writes YIELD — they park at
///   a SAFE boundary (before acquiring the writer) while ANY priority or
///   privileged section is active.
///
/// Earlier this gate only knew "merge vs. everything," so background work yielded
/// to the merge but a UI write (e.g. the unread-badge recount) still queued
/// behind an in-flight background batch in the single-writer FIFO — a visible
/// lag. Moving the line so all foreground/UI work is priority and the heavy
/// queues opt OUT is the fix: there's nothing to classify on the UI side (a new
/// UI write is automatically priority), and only the finite set of background
/// queues is tagged.
///
/// ## Why a cooperative gate (not QoS, not a GRDB priority lane)
///
/// SQLite serializes writers FIFO and an in-progress transaction can't be
/// preempted; the cooperative thread pool can't be "reserved." QoS only
/// *deprioritizes* — under load it still runs and still holds the writer (tried
/// and reverted). So a priority write raises the gate (a count) and every
/// background write parks at a SAFE boundary (before it acquires the writer)
/// until it clears. This is the GRDB/FTS-writer analogue of the IMAP priority
/// lock (ADR-IOS-014) and user-activity prioritization (ADR-IOS-002).
///
/// ## Guarantees & bounds
///
/// - Priority sections are COUNT-based, so nested/concurrent sections (a merge,
///   several UI writes) compose; parked background writers resume only when the
///   LAST one ends.
/// - A write transaction already mid-flight when the gate is raised runs to
///   completion (SQLite can't be preempted), so a priority write waits at most
///   ~one transaction — not the whole backfill run.
/// - NO DEADLOCK: code inside `privileged { }` sets the `inPrivilegedContext`
///   task-local, and `yield()` returns immediately for it — so the merge's own
///   writes never wait on the gate it holds. A priority (`priority { }`) write
///   never calls `yield()` either, so it can't wait on itself.
actor PriorityGate {
    static let shared = PriorityGate()

    /// True within a `privileged { }` scope and the tasks it spawns. A write from
    /// such a task NEVER yields — it IS the work everyone else yields to — and the
    /// read-through merge skips itself when this is set. This is what lets
    /// "background writes yield" coexist with "the merge holds the gate" without
    /// the merge deadlocking against itself.
    @TaskLocal static var inPrivilegedContext = false

    /// True within a `background { }` scope and the structured tasks it spawns.
    /// Marks code (e.g. the shared `BodyFetchProcessor`, when called from the
    /// backfill path) whose async DB writes should YIELD to priority work. The
    /// alternative tag is the stored `PrioritizedDatabase.isBackground` flag
    /// (`AppDatabase.backgroundPool`), for queues with clean pool access.
    @TaskLocal static var inBackgroundContext = false

    /// Active privileged (merge) sections. The merge is special — see
    /// `inPrivilegedContext`. Kept separate from `priorityCount` so `isPrivileged`
    /// (telemetry/tests) keeps meaning exactly "a merge is in flight."
    private var privilegedCount = 0
    /// Active priority (foreground/UI) sections — one per in-flight non-background
    /// async write. Background writers yield while this OR `privilegedCount` is > 0.
    private var priorityCount = 0
    /// Background writers parked in `yield()`, resumed when the gate fully clears.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True while any priority or privileged section is active.
    private var gateRaised: Bool { privilegedCount > 0 || priorityCount > 0 }

    /// True while a privileged (merge) section is active (telemetry/tests).
    var isPrivileged: Bool { privilegedCount > 0 }
    /// True while any section (priority or privileged) holds the gate (telemetry/tests).
    var isGateRaised: Bool { gateRaised }

    // MARK: - Privileged (merge)

    /// Enter a privileged section. Pair with `end()` — prefer `privileged { }`.
    func begin() {
        privilegedCount += 1
    }

    /// Leave a privileged section; wakes parked writers when the gate fully clears.
    func end() {
        guard privilegedCount > 0 else { return }
        privilegedCount -= 1
        wakeIfClear()
    }

    // MARK: - Priority (foreground/UI)

    /// Enter a priority section. Pair with `endPriority()` — prefer `priority { }`.
    func beginPriority() {
        priorityCount += 1
    }

    /// Leave a priority section; wakes parked writers when the gate fully clears.
    func endPriority() {
        guard priorityCount > 0 else { return }
        priorityCount -= 1
        wakeIfClear()
    }

    private func wakeIfClear() {
        guard !gateRaised else { return }
        let resume = waiters
        waiters.removeAll()
        for c in resume { c.resume() }
    }

    // MARK: - Yield (background)

    /// Park the caller while any priority/privileged section is active; returns at
    /// once when the gate is clear OR when the caller is itself the privileged
    /// context. Called by `PrioritizedDatabase`'s async writes from a BACKGROUND
    /// context before they acquire the writer. Cheap (one actor hop) when clear.
    func yield(_ label: @autoclosure () -> String = "") async {
        // The privileged context is exempt — it's the work everyone yields TO.
        // (Without this the merge's own writes would wait on the gate it holds.)
        if PriorityGate.inPrivilegedContext { return }
        guard gateRaised else { return }
        #if DEBUG
        print("[PriorityGate] \(label()) parked — priority work in flight")
        #endif
        while gateRaised {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
    }

    // MARK: - Brackets

    /// Bracket privileged (merge) work so background AND priority-comparison stays
    /// correct. Count-based, so concurrent privileged sections (a foreground merge
    /// racing a deep-link merge) compose. Sets `inPrivilegedContext` for the
    /// duration so the body's own writes are exempt. `body` runs in the caller's
    /// isolation — no Sendable boundary on `body` or its result.
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

    /// Bracket a foreground/UI async write so background work yields to it. Does
    /// NOT set `inPrivilegedContext` — a UI write isn't the merge; it just needs
    /// the gate raised for its duration. Used internally by `PrioritizedDatabase`.
    static func priority<T>(_ body: () async throws -> T) async rethrows -> T {
        await shared.beginPriority()
        do {
            let result = try await body()
            await shared.endPriority()
            return result
        } catch {
            await shared.endPriority()
            throw error
        }
    }

    /// Run `body` (and the structured tasks it spawns) as BACKGROUND work — its
    /// async DB writes yield to priority/privileged sections. The task-local
    /// counterpart of `AppDatabase.backgroundPool`, for code paths shared with
    /// priority callers (e.g. `BodyFetchProcessor`, used by both the on-demand /
    /// active body fetch — priority — and the backfill queue — background). NOTE:
    /// task-locals do NOT cross `Task.detached`; tag inside the detached body.
    static func background<T>(_ body: () async throws -> T) async rethrows -> T {
        try await PriorityGate.$inBackgroundContext.withValue(true, operation: body)
    }
}

/// Priority-aware wrapper around the GRDB `DatabasePool`. This is the SINGLE
/// chokepoint for app database access: `AppDatabase.dbPool` returns a priority
/// instance and `AppDatabase.backgroundPool` returns a background one, so EVERY
/// app write flows through here. The raw pool is reachable only via
/// `AppDatabase.rawPool` (for GRDB APIs like `ValueObservation.publisher(in:)`).
///
/// It mirrors the exact `write`/`read`/`writeWithoutTransaction` overload set the
/// app uses, so it's a drop-in for the raw pool. The ONLY behavioral change is on
/// ASYNC writes:
/// - a **background** write (`isBackground`, or inside `PriorityGate.background`)
///   first `await`s `PriorityGate.shared.yield()` — it parks while any
///   priority/privileged section is active;
/// - a **priority** write (the default — UI, badge, reload, sync) brackets the
///   write in `PriorityGate.priority { }` so background work yields to it;
/// - the **privileged** merge context writes straight through (exempt — it holds
///   the gate already).
/// Reads don't contend the single writer (WAL) and sync writes can't `await`, so
/// both pass straight through.
struct PrioritizedDatabase: Sendable {
    let pool: DatabasePool
    /// When true, this wrapper's async writes are BACKGROUND — they yield to
    /// priority/privileged sections. `AppDatabase.backgroundPool` sets it; the
    /// default (`AppDatabase.dbPool`) is priority.
    var isBackground: Bool = false

    // MARK: Write

    /// Async write — yields if background, otherwise raises the priority gate so
    /// background work yields to it. The privileged (merge) context writes straight
    /// through (it already holds the gate; it must not wait on itself).
    @discardableResult
    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        if (isBackground || PriorityGate.inBackgroundContext) && !PriorityGate.inPrivilegedContext {
            await PriorityGate.shared.yield("db-write")
            return try await pool.write(updates)
        }
        if PriorityGate.inPrivilegedContext {
            return try await pool.write(updates)
        }
        return try await PriorityGate.priority { try await pool.write(updates) }
    }

    /// Sync write — can't `await`, so it can neither yield nor bracket a priority
    /// section; passes through. (Rare; used from non-async contexts like
    /// init/tests, and the synchronous backfill batch insert. The background
    /// loops' explicit boundary `yield()` calls gate those.)
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
        if (isBackground || PriorityGate.inBackgroundContext) && !PriorityGate.inPrivilegedContext {
            await PriorityGate.shared.yield("db-write")
            return try await pool.writeWithoutTransaction(updates)
        }
        if PriorityGate.inPrivilegedContext {
            return try await pool.writeWithoutTransaction(updates)
        }
        return try await PriorityGate.priority { try await pool.writeWithoutTransaction(updates) }
    }
}
