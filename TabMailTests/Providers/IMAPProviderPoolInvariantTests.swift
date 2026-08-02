/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
import SwiftMail
@testable import TabMail

/// T0.6(a) — the IMAP connection pool's INVARIANT CONTRACT, stage (a).
///
/// Every case here drives the REAL `IMAPProvider` actor against a real
/// (in-process, plain-TCP) `FakeIMAPServer`. That is the point of the file:
/// the pool suites that predate it — those declared in the FILES
/// `IMAPPrimaryConnectionTests.swift` (`MarkDirtyTests`,
/// `LRUEvictionOnLimitTests`, …) and `IMAPActionConnectionTests.swift`
/// (`ActionConnectionDoubleAcquireTests`, …) — assert against hand-copied test
/// doubles (`TestPrimaryProvider` / `TestActionProvider`, private actors
/// declared inside those two files), so nothing they prove is binding on
/// `IMAPProvider` itself and any drift between replica and original is
/// invisible to them. (Those two names are FILENAMES, not types — no
/// `IMAPPrimaryConnectionTests`/`IMAPActionConnectionTests` declaration
/// exists. Write them with `.swift` so they cannot be misread as suites.)
///
/// ── WHAT THIS FILE DOES AND DOES NOT COVER ──
///
/// The reference contract suite (`v2final`,
/// `TabMailTests/Providers/IMAPProviderPoolInvariantTests.swift`) pins ~30
/// invariants, but most of them are *pinning tests for pool race fixes that
/// this base does not contain yet*. Writing them here would mean writing
/// tests that fail, which is worse than no test at all.
///
/// So stage (a) ships exactly the invariants the pool ALREADY honours, each
/// proven red-first by deliberately breaking the production line it depends
/// on (evidence recorded per test). The invariants the base cannot satisfy
/// are enumerated — not written, not `withKnownIssue`d — in the
/// `DEFERRED TO T3.7` block at the bottom of this file. That list is the
/// deliverable for stage (b): each entry lands with the fix it pins.
///
/// ── THE POOL, AS THIS BASE ACTUALLY BEHAVES ──
///
/// (Only the parts the cases below depend on. Line-level detail lives in
/// `IMAPProvider.swift`; this is the behavioural summary the assertions
/// encode.)
///
/// **Epoch.** `generation` is bumped by `markDirty()` and by nothing else —
/// `disconnect()` in this base does NOT bump it (deferred, D-15).
/// `withFolderConnection` snapshots it and refuses to run its release when the
/// value moved, which is what keeps a torn-down task from mutating the
/// successor epoch's state. The action-pool wrapper has NO such snapshot in
/// this base (deferred, D-01).
///
/// **Waiters.** `folderWaiters[folder]` and `actionWaiters` are FIFO queues of
/// parked acquires. A healthy release hands off to exactly one; an unhealthy
/// release, `markDirty()` and `disconnect()` fail them ALL with
/// `ProviderError.notConnected` so no acquire is ever left parked forever.
///
/// **Single-flight.** `folderCreating` makes folder-connection creation
/// single-flighted: a second same-folder acquire arriving during an in-flight
/// creation queues instead of racing its own `createServer()`. The action pool
/// is NOT single-flighted in this base (deferred, D-02).
///
/// **Eviction / keepalive.** `evictLRUFolder()` only considers folders that
/// are not checked out, and the keepalive pass only NOOPs folders that are not
/// checked out. Eviction is fully synchronous, so its check cannot be raced;
/// the keepalive one is made before its NOOP await only, and re-checking after
/// that await is deferred (D-08).
///
/// `.serialized` — `FakeIMAPServer` binds a listening socket, so parallel
/// cases would contend on ephemeral port allocation (same reason as
/// `IMAPActionConnectionSelectionTests` and `FakeIMAPServerOracleTests`).
///
/// **Not `.processGlobalState`, deliberately.** That trait is mandatory for
/// suites touching `AppDatabase.shared`, `AccountManager.shared`, the provider
/// registry or the undo stack. `IMAPProvider` names none of the four anywhere
/// in the file. The only TabMail service type it reaches at all is
/// `BackgroundSyncLogger` (an `enum` of static log helpers), from
/// `parseAndApplyServerLimit` on a `max_userip_connections` rejection that no
/// case here provokes; it names none of the four either. Everything else these
/// cases touch is pure — `SyncEngine.isConnectionError`, `SyncConfig`
/// constants.
/// The one piece of process-global state the provider does read is the
/// per-`host`+`username` learned connection limit in `UserDefaults`
/// (`IMAPProvider.persistedServerLimit(host:username:)`); every case below
/// gives its fake a UNIQUE username so that key is unreachable from any other
/// test and from any previous run.
@Suite("IMAPProvider pool — invariant contract (T0.6 stage a)", .serialized)
struct IMAPProviderPoolInvariantTests {

    // MARK: - Fixtures

    /// RFC 5322 `Date:` header, generated from the current clock — never a
    /// literal, so it cannot go stale (Testing Rule 7).
    private static let rfc5322DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: t0.6a-pool-fixture\r
        Date: \(rfc5322DateFormatter.string(from: Date()))\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        pool invariant probe body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    /// A username no other test (or earlier run of this one) can collide with.
    /// `IMAPProvider.init` seeds `serverConnectionLimit` from
    /// `IMAPProvider.persistedServerLimit(host:username:)`, whose `UserDefaults`
    /// key is derived from host+username — a shared username would let a limit
    /// learned elsewhere silently shrink this suite's pool.
    private static func uniqueUsername() -> String {
        "t06a-\(UUID().uuidString.lowercased())"
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    // MARK: - Harness

    /// Bounded cooperative-yield poll for a synchronous condition.
    ///
    /// Returns whether the condition held before the deadline, so a
    /// never-satisfied condition FAILS or falls through — it never hangs the
    /// test. The bound is a liveness backstop, not a timing assumption: no
    /// assertion here depends on how long anything takes, only on whether it
    /// happens at all.
    ///
    /// NO caller discards the returned value. Callers either `#expect` it —
    /// setup preconditions, and the sequencing barrier in
    /// `concurrentSameFolderAcquiresOpenExactlyOneConnection`, which is asserted
    /// as a precondition precisely so a timeout cannot silently make that case
    /// vacuous (see the comment there) — or, in `joinBounded`, turn a `false`
    /// into a recorded `Issue`. A bounded wait whose result is dropped is
    /// exactly how a concurrency case stops exercising its own scenario without
    /// anyone noticing.
    ///
    /// This covers polls only. Joining a `Task` is the other way this file can
    /// hang; use `joinBounded` for that, never a bare `await task.value`.
    private func waitUntil(timeoutSeconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    /// Async-condition sibling of `waitUntil`, for actor-isolated reads.
    private func waitUntilAsync(timeoutSeconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while await !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    /// Bounded join for a task this file spawned. **Records a test issue if the
    /// task does not finish** — a missed deadline is never silent.
    ///
    /// **Never write `await task.value` here.** Every task in this file
    /// completes only if the pool code UNDER TEST resumes it, so a regression
    /// that leaves a waiter parked turns a recorded expectation failure into a
    /// HUNG test process — which takes the entire suite down (no results at
    /// all) instead of reporting one red test. Concretely: revert the fail-all
    /// sweep in `markDirty()` or `disconnect()` and the parked waiters in
    /// `markDirtyFailsEveryParkedWaiterOnBothPools` /
    /// `disconnectFailsEveryParkedWaiterOnBothPools` are never resumed; break
    /// the healthy-release handoff and
    /// `healthyFolderReleaseHandsOffToExactlyOneWaiter`'s two waiters are never
    /// resumed. In both cases the holder's own release is a no-op
    /// (the epoch moved / the connection is gone), so nothing else frees them.
    ///
    /// A task that misses the deadline is ABANDONED, not awaited. Cancelling
    /// cannot help: these tasks park in `withCheckedContinuation`, which is not
    /// cancellation-aware, so `cancel()` then re-awaiting would hang
    /// identically — `watcher.cancel()` below therefore only drops our interest
    /// in the result, it does not stop the underlying task.
    ///
    /// **Why abandoning is acceptable here** — note this is NOT an argument
    /// from `.serialized`, which orders test CASES and says nothing about an
    /// unstructured task that outlives one: every case builds its own
    /// `FakeIMAPServer` and its own `IMAPProvider` over a `uniqueUsername()`,
    /// so the only process-global state the provider reads (the learned
    /// connection limit in `UserDefaults`, keyed by host+username) is
    /// unreachable from any other case — for reads AND for writes.
    ///
    /// That is deliberately not the stronger claim that a survivor is inert.
    /// It is not: a survivor resumed normally that finds
    /// `folderServers[folder] == nil` falls through to
    /// `createFolderConnection` → `createServer()`, i.e. a real TCP connect to
    /// `127.0.0.1:<port>`, and `FakeIMAPServer` authenticates ANY credentials —
    /// so on a recycled ephemeral port a stray session could in principle be
    /// counted by a later case's `liveSessionCount()`/`abandonedSessionCount()`.
    /// What makes abandonment acceptable anyway is the ORDER: `joinBounded`
    /// only abandons a task AFTER it has already recorded an `Issue`, so a
    /// survivor exists only on a run that is already red.
    @discardableResult
    private func joinBounded<Success: Sendable>(
        _ task: Task<Success, Never>,
        timeoutSeconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let done = Mutex(false)
        let watcher = Task { _ = await task.value; done.withLock { $0 = true } }
        let finished = await waitUntil(timeoutSeconds: timeoutSeconds) { done.withLock { $0 } }
        watcher.cancel()
        if !finished {
            Issue.record(
                "a spawned task never finished within \(timeoutSeconds)s — it is still parked, which means the pool never resumed it; abandoning it so the suite reports this instead of hanging",
                sourceLocation: sourceLocation
            )
        }
        return finished
    }

    /// `joinBounded` for a throwing task whose outcome the test asserts on.
    /// Returns `nil` if the task did not finish before the deadline, and records
    /// the issue itself so a caller cannot silently read `nil` as "no result".
    private func joinBounded<Success: Sendable>(
        _ task: Task<Success, Error>,
        timeoutSeconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<Success, Error>? {
        let slot = Mutex<Result<Success, Error>?>(nil)
        let watcher = Task { let r = await task.result; slot.withLock { $0 = r } }
        let finished = await waitUntil(timeoutSeconds: timeoutSeconds) { slot.withLock { $0 != nil } }
        watcher.cancel()
        if !finished {
            Issue.record(
                "a spawned acquire never finished within \(timeoutSeconds)s — it is still parked; abandoning it so the suite reports this instead of hanging",
                sourceLocation: sourceLocation
            )
        }
        return slot.withLock { $0 }
    }

    /// The pool epoch, read out of `poolStateSnapshotForTesting()`'s leading
    /// `generation=` field. The reference exposes the epoch the same way, so no
    /// dedicated getter is needed — an earlier draft of this file invented a
    /// dedicated epoch getter that merely duplicated this; it was removed, and
    /// there is no such accessor on `IMAPProvider` (do not look for one).
    private func epoch(of provider: IMAPProvider) async -> Int? {
        let snapshot = await provider.poolStateSnapshotForTesting()
        guard let field = snapshot.split(separator: " ").first(where: { $0.hasPrefix("generation=") })
        else { return nil }
        return Int(field.dropFirst("generation=".count))
    }

    /// A parking slot for a task held inside a pool test hook.
    private typealias ParkSlot = Mutex<CheckedContinuation<Void, Never>?>

    /// Resume a parked task, taking the continuation out of the slot in the
    /// same critical section so a second call is a no-op.
    ///
    /// Every park slot MUST be unparked on every exit path — a
    /// `CheckedContinuation` that is deallocated without being resumed traps
    /// the whole test process. Callers therefore register `defer { unpark(…) }`
    /// immediately after arming the hook, and the take-and-nil shape is what
    /// makes that safe alongside the explicit unpark on the happy path.
    /// `borrowing` because `Mutex` is `~Copyable` — the slot cannot be passed
    /// by value, and this helper only needs read access to take the stored
    /// continuation out.
    private func unpark(_ slot: borrowing ParkSlot) {
        let taken = slot.withLock { (stored: inout CheckedContinuation<Void, Never>?) -> CheckedContinuation<Void, Never>? in
            let value = stored
            stored = nil
            return value
        }
        taken?.resume()
    }

    /// AWAITED teardown for a `defer` (which cannot itself `await`).
    ///
    /// Ported from the reference suite, which recorded the reason: a
    /// fire-and-forget `defer { Task { try? await provider.disconnect() } }`
    /// let a test return while its pool was still tearing down, so — even in a
    /// `.serialized` suite — the NEXT test began against a still-draining
    /// provider. Blocking is safe here: the suite is serialized, so at most one
    /// thread is ever blocked, and the disconnect Task always has a free
    /// cooperative thread.
    private func awaitDisconnect(_ provider: IMAPProvider) {
        let done = DispatchSemaphore(value: 0)
        Task { try? await provider.disconnect(); done.signal() }
        done.wait()
    }

    private func isNotConnected(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return false }
        if case .notConnected = providerError { return true }
        return false
    }

    // MARK: - Invariant 1: a torn-down epoch never mutates its successor's state

    /// **The property.** When `markDirty()` tears the pool down while a task is
    /// mid-`withFolderConnection`, that task becomes a zombie: its connection
    /// is already logged out and a *different* task may already hold a fresh
    /// pinned connection for the same folder under the new epoch. The zombie's
    /// release must therefore touch NOTHING — otherwise it strips a live
    /// holder's `folderInUse` mark and logs out a connection that holder is
    /// still using.
    ///
    /// This is the invariant `withFolderConnection`'s
    /// `guard generation == acquiredGeneration` pair exists to enforce, and the
    /// only reason the pool's `generation` counter is load-bearing rather than
    /// bookkeeping.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** With BOTH generation
    /// guards in `withFolderConnection` deleted (the success-path one and the
    /// catch-path one), the zombie's `releaseFolderConnection(healthy:)` runs
    /// against the successor epoch: the run failed on
    /// `folderInUseForTesting("INBOX")` (expected true, got false) and on the
    /// instance-identity expectation (the successor's slot had been removed
    /// outright). Restoring the guards turns it green.
    @Test("a folder task whose epoch was torn down mid-body must release NOTHING — the successor epoch's holder keeps its connection and its mark")
    func zombieFolderReleaseNeverTouchesSuccessorEpochHolder() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [Self.message(uid: 11, id: "t06a-gen-1@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // task1 parks HOLDING the pinned INBOX connection of epoch N.
        let zombiePark = ParkSlot(nil)
        defer { unpark(zombiePark) }
        await provider.setFolderConnectionTestHookForTesting { [provider] _ in
            await provider.setFolderConnectionTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                zombiePark.withLock { $0 = cont }
            }
        }
        let zombie = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let zombieParked = await waitUntil { zombiePark.withLock { $0 } != nil }
        #expect(zombieParked, "setup: the first task never parked holding the pinned INBOX connection")
        guard zombieParked else { return }

        // Tear epoch N down out from under it.
        let epochBefore = await epoch(of: provider)
        await provider.markDirty()
        let epochAfter = await epoch(of: provider)
        #expect(epochBefore != nil && epochAfter != nil, "the pool snapshot stopped reporting a `generation=` field")
        // `guard let`, not `.map`: `#expect` is non-fatal, so on a snapshot that
        // stopped emitting `generation=` BOTH optionals are nil and
        // `epochAfter == epochBefore.map { $0 + 1 }` compares `nil == nil` —
        // which is TRUE. The epoch assertion would then pass precisely when the
        // thing it measures had disappeared, and every guard below keys off that
        // move. Unwrapping first makes the comparison reachable only when there
        // is something to compare.
        guard let epochBefore, let epochAfter else { return }
        #expect(epochAfter == epochBefore + 1, "markDirty() must advance the pool epoch — every guard below keys off that move")

        // markDirty() logs the held connection out on a detached Task. Waiting
        // for the wire to confirm makes the zombie's body GUARANTEED to fail on
        // resume, so this case deterministically exercises the catch-path guard
        // rather than racing between the two.
        let torndown = await waitUntil { server.logoutFdLog().count >= 1 }
        #expect(torndown, "setup: markDirty() never logged the pre-teardown connection out")

        // A successor acquires a FRESH pinned INBOX connection under epoch N+1
        // and parks holding it.
        let successorPark = ParkSlot(nil)
        defer { unpark(successorPark) }
        let successorInstance = Mutex<IMAPServer?>(nil)
        await provider.setFolderConnectionTestHookForTesting { [provider] folder in
            await provider.setFolderConnectionTestHookForTesting(nil)
            let held = await provider.currentFolderServerForTesting(folder: folder)
            successorInstance.withLock { $0 = held }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                successorPark.withLock { $0 = cont }
            }
        }
        let successor = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let successorParked = await waitUntil { successorPark.withLock { $0 } != nil }
        #expect(successorParked, "setup: the successor never parked holding its fresh pinned connection")
        guard successorParked else { return }

        let successorServer = successorInstance.withLock { $0 }
        #expect(successorServer != nil, "setup: the successor's own pinned connection was not tracked")

        // Let the zombie run to completion against its dead connection.
        unpark(zombiePark)
        await joinBounded(zombie)

        // THE INVARIANT: the successor is untouched.
        let stillHeld = await provider.folderInUseForTesting(folder: "INBOX")
        let snapshot = await provider.poolStateSnapshotForTesting()
        #expect(stillHeld, "the zombie stripped the successor's in-use mark — \(snapshot)")
        let trackedNow = await provider.currentFolderServerForTesting(folder: "INBOX")
        #expect(trackedNow != nil, "the zombie removed the successor's tracked connection — \(snapshot)")
        if let successorServer, let trackedNow {
            #expect(trackedNow === successorServer, "the tracked INBOX connection is no longer the successor's own instance — \(snapshot)")
        }

        // The successor must still be able to finish normally.
        unpark(successorPark)
        await joinBounded(successor)
        let released = await waitUntilAsync { await provider.folderInUseForTesting(folder: "INBOX") == false }
        #expect(released, "the successor's own release never ran — its lane is wedged")
    }

    // MARK: - Invariant 2: no teardown ever leaves an acquire parked forever

    /// **The property.** `markDirty()` may run at any moment (iOS suspension,
    /// push wakeup, background refresh). Any acquire parked on a pool waiter
    /// queue at that instant has no connection to be handed and no event left
    /// that would ever hand it one — so the teardown MUST fail it explicitly.
    /// A missed fail-all is not a slow test, it is a permanently wedged lane:
    /// the caller never returns, and with it the sync/backfill task that owns
    /// it never returns either.
    ///
    /// Both queues are covered because they are independent code paths in
    /// `IMAPProvider.markDirty()` (the `folderWaiters` sweep and the
    /// `actionWaiters` sweep) that fail independently.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Commenting out the
    /// `folderWaiters` fail-all sweep in `markDirty()` leaves the folder waiter
    /// parked: the run failed on "the parked folder acquire never returned"
    /// (the bounded wait expired) and on the residual-waiter expectation
    /// (`folderWaiterCountForTesting` stayed 1). Replacing the sweeps'
    /// `resume(throwing: ProviderError.notConnected)` with a plain `resume()`
    /// instead lets both waiters rebuild and succeed, failing the two
    /// "must FAIL … not succeed" expectations. Deleting `folderInUse
    /// .removeAll()` and `actionInUse = false` from `markDirty()` fails the two
    /// marks⇔holders expectations. Every variant restored ⇒ green.
    @Test("markDirty() fails EVERY parked acquire on both pools — a teardown never wedges a waiting caller")
    func markDirtyFailsEveryParkedWaiterOnBothPools() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [
                Self.message(uid: 21, id: "t06a-wait-1@example.com"),
                Self.message(uid: 22, id: "t06a-wait-2@example.com"),
            ]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // A holder on each pool, so a second caller on each pool must queue.
        let folderPark = ParkSlot(nil)
        defer { unpark(folderPark) }
        await provider.setFolderConnectionTestHookForTesting { [provider] _ in
            await provider.setFolderConnectionTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                folderPark.withLock { $0 = cont }
            }
        }
        let folderHolder = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let folderHeld = await waitUntil { folderPark.withLock { $0 } != nil }
        #expect(folderHeld, "setup: no task ever parked holding the pinned INBOX connection")
        guard folderHeld else { return }

        let actionPark = ParkSlot(nil)
        defer { unpark(actionPark) }
        await provider.setActionConnectionTestHookForTesting { [provider] in
            await provider.setActionConnectionTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                actionPark.withLock { $0 = cont }
            }
        }
        let actionHolder = Task {
            try? await provider.markRead(ids: ["21"], folder: "INBOX", admittedUidValidity: 1)
        }
        let actionHeld = await waitUntil { actionPark.withLock { $0 } != nil }
        #expect(actionHeld, "setup: no task ever parked holding the action connection")
        guard actionHeld else { return }

        // One parked acquire on each queue.
        let folderWaiterResult = Mutex<Result<Void, Error>?>(nil)
        let folderWaiter = Task {
            do {
                _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
                folderWaiterResult.withLock { $0 = .success(()) }
            } catch {
                folderWaiterResult.withLock { $0 = .failure(error) }
            }
        }
        let folderQueued = await waitUntilAsync { await provider.folderWaiterCountForTesting(folder: "INBOX") == 1 }
        #expect(folderQueued, "setup: the second folder acquire never queued as a waiter")
        guard folderQueued else { return }

        let actionWaiterResult = Mutex<Result<Void, Error>?>(nil)
        let actionWaiter = Task {
            do {
                try await provider.markRead(ids: ["22"], folder: "INBOX", admittedUidValidity: 1)
                actionWaiterResult.withLock { $0 = .success(()) }
            } catch {
                actionWaiterResult.withLock { $0 = .failure(error) }
            }
        }
        let actionQueued = await waitUntilAsync { await provider.actionWaiterCountForTesting() == 1 }
        #expect(actionQueued, "setup: the second action acquire never queued as a waiter")
        guard actionQueued else { return }

        // THE EVENT.
        await provider.markDirty()

        // THE INVARIANT: both parked acquires come back, and come back as the
        // retryable "not connected" shape rather than silently succeeding
        // against a connection the teardown already destroyed.
        let folderReturned = await waitUntil { folderWaiterResult.withLock { $0 } != nil }
        #expect(folderReturned, "the parked folder acquire never returned — markDirty() wedged the folder lane")
        let actionReturned = await waitUntil { actionWaiterResult.withLock { $0 } != nil }
        #expect(actionReturned, "the parked action acquire never returned — markDirty() wedged the action lane")

        if case .failure(let error)? = folderWaiterResult.withLock({ $0 }) {
            #expect(isNotConnected(error), "the folder waiter must fail with ProviderError.notConnected (the retry shape), got \(error)")
        } else {
            #expect(Bool(false), "the folder waiter must FAIL after its transfer was voided, not succeed")
        }
        if case .failure(let error)? = actionWaiterResult.withLock({ $0 }) {
            #expect(isNotConnected(error), "the action waiter must fail with ProviderError.notConnected (the retry shape), got \(error)")
        } else {
            #expect(Bool(false), "the action waiter must FAIL after its transfer was voided, not succeed")
        }

        let snapshot = await provider.poolStateSnapshotForTesting()
        #expect(await provider.folderWaiterCountForTesting(folder: "INBOX") == 0, "markDirty() left a folder waiter behind — \(snapshot)")
        #expect(await provider.actionWaiterCountForTesting() == 0, "markDirty() left an action waiter behind — \(snapshot)")

        // Marks ⇔ holders. A teardown destroys every connection, so it must
        // also drop every checkout mark: a surviving mark has no holder left to
        // release it, and the next acquire on that lane queues behind it
        // forever.
        #expect(await provider.folderInUseForTesting(folder: "INBOX") == false, "markDirty() left INBOX marked checked-out with no holder — the folder lane is wedged — \(snapshot)")
        #expect(await provider.actionInUseForTesting() == false, "markDirty() left the action connection marked checked-out with no holder — the action lane is wedged — \(snapshot)")

        unpark(folderPark)
        unpark(actionPark)
        await joinBounded(folderHolder)
        await joinBounded(actionHolder)
        await joinBounded(folderWaiter)
        await joinBounded(actionWaiter)
    }

    /// `disconnect()`'s own fail-all sweeps. Same invariant as
    /// `markDirtyFailsEveryParkedWaiterOnBothPools`, different writer: the two
    /// teardowns have completely separate sweep code, so a regression in one is
    /// invisible to the other's test.
    ///
    /// Note the asymmetry this case deliberately does NOT assert: unlike
    /// `markDirty()`, this base's `disconnect()` does not advance `generation`
    /// at all (deferred, D-15). It is still required to leave no waiter parked,
    /// and that is exactly what is pinned here.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Replacing `disconnect()`'s
    /// two fail-all sweeps' `resume(throwing: ProviderError.notConnected)` with
    /// a plain `resume()` lets both waiters succeed, failing the two
    /// "must FAIL … not succeed" expectations. Deleting `folderInUse
    /// .removeAll()` and `actionInUse = false` from `disconnect()` fails the
    /// two marks⇔holders expectations. Both restored ⇒ green.
    @Test("disconnect() fails EVERY parked acquire on both pools — no waiter survives a shutdown")
    func disconnectFailsEveryParkedWaiterOnBothPools() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [
                Self.message(uid: 31, id: "t06a-disc-1@example.com"),
                Self.message(uid: 32, id: "t06a-disc-2@example.com"),
            ]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        let folderPark = ParkSlot(nil)
        defer { unpark(folderPark) }
        await provider.setFolderConnectionTestHookForTesting { [provider] _ in
            await provider.setFolderConnectionTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                folderPark.withLock { $0 = cont }
            }
        }
        let folderHolder = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let folderHeld = await waitUntil { folderPark.withLock { $0 } != nil }
        #expect(folderHeld, "setup: no task ever parked holding the pinned INBOX connection")
        guard folderHeld else { return }

        let actionPark = ParkSlot(nil)
        defer { unpark(actionPark) }
        await provider.setActionConnectionTestHookForTesting { [provider] in
            await provider.setActionConnectionTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                actionPark.withLock { $0 = cont }
            }
        }
        let actionHolder = Task {
            try? await provider.markRead(ids: ["31"], folder: "INBOX", admittedUidValidity: 1)
        }
        let actionHeld = await waitUntil { actionPark.withLock { $0 } != nil }
        #expect(actionHeld, "setup: no task ever parked holding the action connection")
        guard actionHeld else { return }

        let folderWaiterResult = Mutex<Result<Void, Error>?>(nil)
        let folderWaiter = Task {
            do {
                _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
                folderWaiterResult.withLock { $0 = .success(()) }
            } catch {
                folderWaiterResult.withLock { $0 = .failure(error) }
            }
        }
        let folderQueued = await waitUntilAsync { await provider.folderWaiterCountForTesting(folder: "INBOX") == 1 }
        #expect(folderQueued, "setup: the second folder acquire never queued as a waiter")
        guard folderQueued else { return }

        let actionWaiterResult = Mutex<Result<Void, Error>?>(nil)
        let actionWaiter = Task {
            do {
                try await provider.markRead(ids: ["32"], folder: "INBOX", admittedUidValidity: 1)
                actionWaiterResult.withLock { $0 = .success(()) }
            } catch {
                actionWaiterResult.withLock { $0 = .failure(error) }
            }
        }
        let actionQueued = await waitUntilAsync { await provider.actionWaiterCountForTesting() == 1 }
        #expect(actionQueued, "setup: the second action acquire never queued as a waiter")
        guard actionQueued else { return }

        // THE EVENT.
        try await provider.disconnect()

        let folderReturned = await waitUntil { folderWaiterResult.withLock { $0 } != nil }
        #expect(folderReturned, "the parked folder acquire never returned — disconnect() wedged the folder lane")
        let actionReturned = await waitUntil { actionWaiterResult.withLock { $0 } != nil }
        #expect(actionReturned, "the parked action acquire never returned — disconnect() wedged the action lane")

        if case .failure(let error)? = folderWaiterResult.withLock({ $0 }) {
            #expect(isNotConnected(error), "the folder waiter must fail with ProviderError.notConnected, got \(error)")
        } else {
            #expect(Bool(false), "the folder waiter must FAIL once the pool is disconnected, not succeed")
        }
        if case .failure(let error)? = actionWaiterResult.withLock({ $0 }) {
            #expect(isNotConnected(error), "the action waiter must fail with ProviderError.notConnected, got \(error)")
        } else {
            #expect(Bool(false), "the action waiter must FAIL once the pool is disconnected, not succeed")
        }

        let snapshot = await provider.poolStateSnapshotForTesting()

        // Residual waiter queues, the same pair the markDirty() sibling asserts.
        // This case's doc comment claims the SAME invariant ("no waiter survives
        // a shutdown") but was only checking that the two waiters it happens to
        // hold references to came back — it never looked at the queues
        // themselves. A sweep that resumes a waiter and forgets to DEQUEUE it
        // leaves a dangling continuation whose eventual double-resume surfaces
        // as a process-killing `SWIFT TASK CONTINUATION MISUSE`, taking every
        // unrelated result with it, rather than as a clean failure here.
        #expect(await provider.folderWaiterCountForTesting(folder: "INBOX") == 0, "disconnect() left a folder waiter behind — \(snapshot)")
        #expect(await provider.actionWaiterCountForTesting() == 0, "disconnect() left an action waiter behind — \(snapshot)")

        // Marks ⇔ holders, same invariant as the markDirty() case — a separate
        // writer, so a regression in one is invisible to the other's test.
        #expect(await provider.folderInUseForTesting(folder: "INBOX") == false, "disconnect() left INBOX marked checked-out with no holder — the folder lane is wedged — \(snapshot)")
        #expect(await provider.actionInUseForTesting() == false, "disconnect() left the action connection marked checked-out with no holder — the action lane is wedged — \(snapshot)")

        unpark(folderPark)
        unpark(actionPark)
        await joinBounded(folderHolder)
        await joinBounded(actionHolder)
        await joinBounded(folderWaiter)
        await joinBounded(actionWaiter)
    }

    // MARK: - Invariant 3: folder creation is single-flighted

    /// **The property.** Two concurrent acquires for the SAME folder must
    /// produce exactly ONE server connection. The pool is an actor, but
    /// `createFolderConnection` suspends across a real login round-trip, so
    /// reentrancy lets a second caller observe "no connection for this folder"
    /// while the first caller's creation is still in flight. Without the
    /// `folderCreating` mark the second caller starts its own creation, and
    /// whichever plants second silently overwrites — and thereby LEAKS, with no
    /// logout — the other's logged-in session.
    ///
    /// The VERDICT is decided by wire-level oracles alone — exactly one LOGIN,
    /// exactly one live session for the folder, and no logged-in session
    /// abandoned without a LOGOUT. The waiter queue is single-flight's
    /// mechanism, not its property, so nothing below asserts a queue *shape*.
    /// The one thing this case does assert about the queue is a setup
    /// PRECONDITION ("the second acquire reached the pool while the creation was
    /// in flight"); the comment at that line explains why that is not a
    /// mechanism check and why it carries no `guard`.
    ///
    /// The LOGIN count is `v2final`'s oracle for this exact property and is the
    /// only one of the three that is self-controlling — see the block at the
    /// assertion for why a `== 0` leak oracle with no positive control anywhere
    /// in the tree proves nothing about itself.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Dropping
    /// `|| folderCreating.contains(folder)` from `acquireFolderConnection`'s
    /// branch-2 guard (`IMAPProvider.acquireFolderConnection`) sends the second caller down
    /// the create path instead. The decisive failure is the abandoned-session
    /// oracle — `server.abandonedSessionCount()` reads 1 where 0 is required,
    /// because the loser's logged-in session is planted over with no LOGOUT —
    /// alongside the live-session count (2 sessions for one folder). The setup
    /// precondition also goes red on that run, since the second acquire creates
    /// instead of queueing; the invariant assertions still run and still decide
    /// the verdict.
    @Test("two concurrent same-folder acquires open exactly ONE connection — the second queues behind folderCreating instead of racing its own createServer()")
    func concurrentSameFolderAcquiresOpenExactlyOneConnection() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [Self.message(uid: 41, id: "t06a-flight-1@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // Park the FIRST creation between the `folderCreating` mark and the
        // login round-trip — the exact window the single-flight covers.
        let creationPark = ParkSlot(nil)
        defer { unpark(creationPark) }
        await provider.setCreateFolderConnectionCreationTestHookForTesting { [provider] in
            await provider.setCreateFolderConnectionCreationTestHookForTesting(nil)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                creationPark.withLock { $0 = cont }
            }
        }
        let first = Task { try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let creating = await waitUntil { creationPark.withLock { $0 } != nil }
        #expect(creating, "setup: the first acquire never parked inside createFolderConnection")
        guard creating else { return }
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX") == false, "setup: a pinned connection existed before the creation completed")

        // The second acquire arrives while that creation is in flight.
        let second = Task { try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        // SEQUENCING BARRIER — asserted as a SETUP PRECONDITION, and carrying
        // NO `guard`. Both of those are load-bearing.
        //
        // *Why it is asserted.* A barrier that merely times out makes this case
        // VACUOUS. If the second acquire has not reached the pool by the time
        // the creation below is unparked, that creation completes and plants
        // `folderServers["INBOX"]`; the second acquire then arrives to an
        // already-existing connection and is served by an earlier branch of
        // `acquireFolderConnection`, never reaching the single-flight predicate
        // in `IMAPProvider.acquireFolderConnection` that this case exists to pin. With the
        // canonical regression applied, such a run still observes one live
        // session and zero abandoned ones and reports GREEN with the bug
        // present. `secondSucceeded` below does not rescue it: succeeding
        // proves the second acquire eventually ran, not that it arrived while
        // the creation was still in flight.
        //
        // *Why this is not mechanism-pinning.* The expectation answers "did the
        // scenario this case is about actually occur?", not "did the pool
        // implement it the way I expect". The VERDICT is still decided by the
        // session/leak oracles further down, which say nothing about queues —
        // a future pool that parks the loser somewhere other than
        // `folderWaiters` while still opening exactly one connection stays
        // green on them.
        //
        // *Why there is no `guard … else { return }`.* An earlier round of this
        // file short-circuited here, and the canonical regression then failed on
        // this line and RETURNED before reaching the real oracle. Both
        // properties must hold simultaneously: a timed-out barrier can never
        // pass silently (hence the `#expect`), AND the invariant assertions
        // below always run (hence no `guard`).
        let arrived = await waitUntilAsync { await provider.folderWaiterCountForTesting(folder: "INBOX") == 1 }
        #expect(arrived, "setup: the second same-folder acquire never reached the pool while the creation was still in flight — this run did not exercise the concurrency the case exists for")

        unpark(creationPark)
        let firstResult = await joinBounded(first)
        let secondResult = await joinBounded(second)

        var firstSucceeded = false
        if case .success? = firstResult { firstSucceeded = true }
        #expect(firstSucceeded, "the creating acquire must succeed (nil ⇒ it never finished)")
        var secondSucceeded = false
        if case .success? = secondResult { secondSucceeded = true }
        #expect(secondSucceeded, "the queued acquire must be handed the single connection, not fail or hang (nil ⇒ it never finished)")

        // THE INVARIANT: one folder, one session. No `connect()` was called, so
        // there is no action connection and every live session is a folder one.
        // The SESSION half of that is `liveSessionCount()`, asserted at the end
        // of this function; the LOGIN counter below states something narrower,
        // and the difference is worth being exact about.
        //
        // The LOGIN oracle is ported from
        // `v2final:TabMailTests/Providers/IMAPProviderPoolInvariantTests.swift:615`
        // (`ensureServerSingleFlightsConcurrentCreation`, R6-1 Part 2), which
        // stated the property as `loginCount() == 1` on `recordedCommands()`.
        // RULE R0: the reference's shape is preferred here over inventing a
        // companion counter, and its WORDING is adopted verbatim because that
        // wording is careful in a way a paraphrase is not.
        //
        // **LOGIN counts authentication ATTEMPTS, not connections.** A
        // connection opened and then abandoned before it sent LOGIN is
        // invisible to this counter. So the reference does not say "exactly one
        // connection was opened"; it says a SECOND LOGIN MEANS two racing
        // `createServer()` calls. That implication is what holds, and it is all
        // that is claimed here. The connection census is `liveSessionCount()`'s
        // job, and the never-logged-out leak detector is
        // `abandonedSessionCount()`'s — both asserted immediately below.
        //
        // ATTEMPTS, not AUTHENTICATIONS, and the distinction is the fake's, not
        // a hedge: its client loop appends to `commandLog` at LINE-PARSE time,
        // in the same `withState` block that then evaluates the injected-failure
        // countdown — and the append comes FIRST. A matched failure either
        // answers `NO` and `continue`s or `break`s the client loop, so it never
        // reaches `handleCommand`'s `case "LOGIN": authenticated = true`. An
        // injected LOGIN failure and a killed connection are therefore both
        // COUNTED here while being no authentication at all. This test injects
        // neither, so the count is exact for it; the wording matters because a
        // future variant that does inject one would silently change what this
        // number means.
        //
        // Within that narrower scope the assertion is still two-sided, because
        // `recordedCommands()` is MONOTONIC (`commandLog` is appended to at
        // line-parse time, as above, and nothing ever removes from it) and the
        // comparison is an EQUALITY:
        //
        //   * 2+ ⇒ a second `createServer()` raced the single-flight (the bug).
        //   * 0  ⇒ no LOGIN was recorded at all, though both acquires were just
        //          asserted to have succeeded — so the command log itself has
        //          stopped being written. It FAILS rather than certifying the
        //          assertions beneath it.
        //
        // That second property is exactly what `abandonedSessionCount() == 0`
        // lacks on its own. `liveSessionCount()`'s own doc comment records that
        // it reads 0 the instant `closeClientFd` runs for ANY reason, so for an
        // already-closed planted-over leak `abandonedSessionCount()` is the only
        // detector — and it has exactly one call site in the tree, asserting
        // ZERO. If `sessionsEndedWithoutLogout` ever stopped being populated,
        // that assertion would green forever with a real leak present, and
        // nothing anywhere would notice. The sibling wrong-message oracle in
        // `FakeIMAPServerOracleTests` carries three self-tests including an
        // explicit "it fires" case; the session oracles carry none. The LOGIN
        // count supplies the missing falsifiability without needing one, because
        // its own zero is a failure.
        let loginCount = server.recordedCommands().filter { $0.uppercased().hasPrefix("LOGIN") }.count
        #expect(
            loginCount == 1,
            // R0: the reference's sentence is kept byte-identical; the observed
            // count is APPENDED. `v2final`'s message carries no number, so a
            // failure reported none — strictly-additive diagnostic, not a
            // weakened assertion (the predicate above is untouched).
            "both concurrent acquires must share ONE created connection — a second LOGIN means two racing createServer() calls (the overwrite/leak bug); observed \(loginCount) LOGIN(s) on the wire"
        )
        let sessions = server.liveSessionCount()
        #expect(sessions == 1, "two same-folder acquires opened \(sessions) sessions — a second creation raced the single-flight and the loser was leaked")
        #expect(server.abandonedSessionCount() == 0, "a logged-in session was abandoned without a LOGOUT — the classic planted-over leak")
    }

    // MARK: - Invariant 4: a connection in use is never taken away

    /// **The property.** `evictLRUFolder()` frees a slot by logging a pinned
    /// connection out. It must never choose a folder that a task is currently
    /// holding — the holder has no way to learn its connection was closed and
    /// would issue its next command onto a dead socket.
    ///
    /// The case pins both halves: the in-use folder survives *even when it is
    /// the least-recently-used candidate* (so the choice is genuinely driven by
    /// the in-use filter and not by ordering luck), and the eviction still
    /// happens — it falls through to the oldest folder that is actually free.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Removing the
    /// `.filter { !folderInUse.contains($0.key) }` from `evictLRUFolder()`'s
    /// candidate set makes it pick the backdated in-use folder: the run failed
    /// on "the in-use folder's connection was evicted" and on "the oldest FREE
    /// folder should have been evicted instead".
    @Test("evictLRUFolder() never evicts a folder that is checked out — it falls through to the oldest FREE folder")
    func evictionNeverTakesAConnectionOutFromUnderItsHolder() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: [
                "INBOX": [Self.message(uid: 51, id: "t06a-evict-inbox@example.com")],
                "Archive": [Self.message(uid: 52, id: "t06a-evict-archive@example.com")],
                "Sent": [Self.message(uid: 53, id: "t06a-evict-sent@example.com")],
            ]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // Three pinned connections, each created and released normally.
        for folder in ["INBOX", "Archive", "Sent"] {
            _ = try await provider.fetchMessages(folder: folder, limit: 1, offset: 0)
        }
        #expect(await provider.poolMaxConnections() >= 3, "setup: the pool cannot hold the three connections this case needs")
        for folder in ["INBOX", "Archive", "Sent"] {
            #expect(await provider.hasFolderConnectionForTesting(folder: folder), "setup: \(folder) has no pinned connection")
        }

        // Make the CHECKED-OUT folder the most attractive eviction candidate:
        // strictly older than every other, so only the in-use filter can save
        // it. All stamps are derived from the current clock (Testing Rule 7).
        let now = Date()
        await provider.setFolderLastUsedForTesting(now.addingTimeInterval(-3600), folder: "Archive")
        await provider.setFolderLastUsedForTesting(now.addingTimeInterval(-1800), folder: "INBOX")
        await provider.setFolderLastUsedForTesting(now.addingTimeInterval(-60), folder: "Sent")
        await provider.setFolderInUseForTesting(folder: "Archive", inUse: true)

        // THE EVENT.
        let evicted = await provider.evictLRUFolderForTesting()

        // THE INVARIANT.
        let snapshot = await provider.poolStateSnapshotForTesting()
        #expect(evicted, "eviction found no candidate even though two folders were free — \(snapshot)")
        #expect(await provider.hasFolderConnectionForTesting(folder: "Archive"), "the in-use folder's connection was evicted out from under its holder — \(snapshot)")
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX") == false, "the oldest FREE folder should have been evicted instead — \(snapshot)")
        #expect(await provider.hasFolderConnectionForTesting(folder: "Sent"), "the newest free folder must be left alone — \(snapshot)")

        await provider.setFolderInUseForTesting(folder: "Archive", inUse: false)
    }

    /// The keepalive sibling of the eviction invariant, on a different writer.
    ///
    /// **The property.** `keepAlivePinnedConnections()` NOOPs idle pinned
    /// connections and drops any whose NOOP fails. A connection that is
    /// currently checked out must be skipped entirely: probing it would
    /// interleave a NOOP with the holder's own in-flight command on the same
    /// socket, and dropping it on failure would delete a live checkout's
    /// tracking.
    ///
    /// The case is two-sided by construction, which is what makes it
    /// non-vacuous: with the mark set, the armed connection-kill is never
    /// consumed (no NOOP reached the wire at all); with the mark cleared, the
    /// SAME armed kill fires and the connection is dropped. A regression that
    /// simply never NOOPs anything fails the second half.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Removing the
    /// `where !folderInUse.contains(folder)` clause from the keepalive folder
    /// loop makes phase 1 probe the checked-out connection: the run failed on
    /// "keepalive probed a checked-out connection" (the injected kill was
    /// consumed) and on "keepalive dropped a checked-out connection".
    @Test("keepalive never probes or drops a folder connection that is checked out — and still drops a dead one that is free")
    func keepaliveSkipsCheckedOutConnectionsButStillReapsFreeDeadOnes() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [Self.message(uid: 61, id: "t06a-keepalive@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // One pinned connection, created and released normally. No `connect()`,
        // so the keepalive pass has no action connection to probe and every
        // observation below is unambiguously about the folder loop.
        _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX"), "setup: INBOX has no pinned connection")

        // Arm a real socket death on the next NOOP. It stays armed until a NOOP
        // is actually sent, which is what makes it a probe detector.
        server.killConnectionOnNextCommand(containing: "NOOP")

        // Phase 1 — checked out: keepalive must not touch it.
        await provider.setFolderInUseForTesting(folder: "INBOX", inUse: true)
        await provider.keepAlivePinnedConnectionsForTesting()
        var snapshot = await provider.poolStateSnapshotForTesting()
        #expect(server.consumedInjectedFailureCount() == 0, "keepalive probed a checked-out connection — the NOOP raced its holder's own command — \(snapshot)")
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX"), "keepalive dropped a checked-out connection — \(snapshot)")

        // Phase 2 — free: the SAME armed kill must now fire and be reaped.
        await provider.setFolderInUseForTesting(folder: "INBOX", inUse: false)
        await provider.keepAlivePinnedConnectionsForTesting()
        snapshot = await provider.poolStateSnapshotForTesting()
        #expect(server.consumedInjectedFailureCount() == 1, "keepalive never probed the free connection — phase 1's silence proves nothing without this — \(snapshot)")
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX") == false, "keepalive kept a connection whose NOOP proved it dead — \(snapshot)")
    }

    // MARK: - Invariant 5: a healthy release hands off to exactly one waiter

    /// **The property.** When a holder releases a healthy folder connection,
    /// the connection is handed to exactly ONE queued waiter. Waking more than
    /// one would double-check-out a single socket; waking none would strand the
    /// queue behind a connection nobody is using.
    ///
    /// The detector is `holdersEntered`, the number of tasks that reached the
    /// holder window: holder + exactly one successor = 2. The residual
    /// waiter-queue length is reported as diagnostic context only — see the
    /// comment at the assertion.
    ///
    /// **Red-first evidence (recorded 2026-07-30).** Changing
    /// `IMAPProvider.releaseFolderConnection`'s healthy handoff (its
    /// `folderWaiters[folder]` `removeFirst()` resume)
    /// from `removeFirst()` to draining and resuming the whole queue makes both
    /// waiters run at once. The extra entrant arrives asynchronously, so the
    /// assertion that catches it is the bounded NEGATIVE wait below: it
    /// observes `holdersEntered > 2` and fails. The count reads 3 once that
    /// entrant lands, failing the "exactly ONE waiter" expectation too as the
    /// diagnostic-rich restatement. Replacing the handoff with a no-op instead
    /// fails "the handed-off waiter never ran" (and leaves `holdersEntered` at
    /// 1).
    @Test("a healthy folder release hands the connection to exactly ONE queued waiter — the rest stay parked")
    func healthyFolderReleaseHandsOffToExactlyOneWaiter() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [Self.message(uid: 71, id: "t06a-handoff@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { awaitDisconnect(provider) }

        // The holder parks; so does the ONE successor that claims
        // `successorPark` (later entrants only count and return — see the claim
        // gate below), so the waiter that is handed the connection stays
        // visible as a holder instead of immediately releasing and pulling the
        // next one through.
        let holderPark = ParkSlot(nil)
        defer { unpark(holderPark) }
        let successorPark = ParkSlot(nil)
        defer { unpark(successorPark) }
        let holdersEntered = Mutex<Int>(0)

        await provider.setFolderConnectionTestHookForTesting { [provider] _ in
            await provider.setFolderConnectionTestHookForTesting(nil)
            holdersEntered.withLock { $0 += 1 }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                holderPark.withLock { $0 = cont }
            }
        }
        let holder = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let held = await waitUntil { holderPark.withLock { $0 } != nil }
        #expect(held, "setup: no task ever parked holding the pinned INBOX connection")
        guard held else { return }

        // Two waiters queue behind it.
        let waiterA = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let waiterB = Task { _ = try? await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0) }
        let bothQueued = await waitUntilAsync { await provider.folderWaiterCountForTesting(folder: "INBOX") == 2 }
        #expect(bothQueued, "setup: two waiters never queued behind the holder")
        guard bothQueued else {
            unpark(holderPark)
            await joinBounded(holder)
            await joinBounded(waiterA)
            await joinBounded(waiterB)
            return
        }

        // Re-arm the hook so whichever waiter is handed the connection parks
        // as a holder rather than releasing straight through.
        //
        // This successor hook deliberately does NOT disarm itself, for two
        // independent reasons:
        //
        //  1. A self-disarming hook blinds `holdersEntered` to exactly the
        //     regression this case exists for. Under the red mutation — the
        //     healthy handoff in `IMAPProvider.releaseFolderConnection` draining and
        //     resuming the WHOLE queue instead of `removeFirst()` — the second
        //     entrant may read a nil hook, skip the body, and leave the count
        //     at 2, so the count would PASS while one socket was checked out
        //     twice. Counting EVERY entry is what turns `holdersEntered` into a
        //     property oracle: it reads 3 under that mutation.
        //  2. The disarm is racy, and the race TRAPS THE PROCESS.
        //     `IMAPProvider.withFolderConnection` reads
        //     `folderConnectionTestHook` and then awaits it, while the body's own
        //     `setFolderConnectionTestHookForTesting(nil)` needs a fresh hop
        //     back onto the actor — so a second entrant can read a still-armed
        //     hook in that gap. Both bodies then run, both store a
        //     `CheckedContinuation` into `successorPark`, and the second store
        //     drops the first without resuming it: `SWIFT TASK CONTINUATION
        //     MISUSE`, which kills the whole test process rather than failing
        //     this one case.
        //
        // So: count every entry, but park only the entrant that CLAIMS the
        // slot. The claim is a single test-and-set critical section rather than
        // a `successorPark == nil` check followed by a store, because two
        // entrants can both observe an empty slot before either of them has a
        // continuation to put in it.
        let successorParkClaimed = Mutex(false)
        await provider.setFolderConnectionTestHookForTesting { _ in
            holdersEntered.withLock { $0 += 1 }
            let claimedPark = successorParkClaimed.withLock { (claimed: inout Bool) -> Bool in
                if claimed { return false }
                claimed = true
                return true
            }
            guard claimedPark else { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                successorPark.withLock { $0 = cont }
            }
        }

        // THE EVENT: the holder releases healthy.
        unpark(holderPark)
        await joinBounded(holder)

        // THE INVARIANT: exactly one waiter was handed the connection.
        //
        // `holdersEntered` is the oracle: one entry for the original holder
        // plus one for the single successor is 2. A release that woke both
        // waiters checks the same socket out twice and reads 3.
        //
        // The residual waiter-queue length is read for the failure message
        // only — it is `folderWaiters`, this implementation's private
        // mechanism, and a correct pool that queued the loser elsewhere would
        // be false-red by an `#expect` on it (same reasoning as the barrier in
        // `concurrentSameFolderAcquiresOpenExactlyOneConnection`). It must
        // never be the detector.
        let successorRan = await waitUntil { successorPark.withLock { $0 } != nil }
        #expect(successorRan, "the handed-off waiter never ran — the healthy release woke nobody")
        let remaining = await provider.folderWaiterCountForTesting(folder: "INBOX")
        // A NEGATIVE wait, not a sample. The extra entrant is EVIDENCE OF THE
        // BUG and it arrives asynchronously — under the red mutation the second
        // waiter increments `holdersEntered` from a hook body on another
        // executor, ordered only by luck against the single actor round-trip
        // above — so its absence must be WAITED FOR, not read off once. This is
        // not a widened bound: it is a new, deliberately short window whose
        // EXPIRY is the passing outcome, so a slow machine costs a second and
        // never flips the verdict. The race is red-direction only — on the
        // correct implementation the second waiter stays parked in
        // `folderWaiters` until the successor releases, which happens below
        // this point, so `entered` is deterministically 2 and there is no
        // false-red.
        let sawExtraEntrant = await waitUntil(timeoutSeconds: 1) { holdersEntered.withLock { $0 } > 2 }
        #expect(sawExtraEntrant == false, "a second waiter also entered the holder window — the healthy release woke more than one, so the single INBOX socket was checked out concurrently")
        let entered = holdersEntered.withLock { $0 }
        let snapshot = await provider.poolStateSnapshotForTesting()
        #expect(
            entered == 2,
            "a healthy release must hand the connection to exactly ONE waiter: the holder plus one successor is 2 entries into the holder window, and this run saw \(entered) — \(entered - 1) task(s) were checked out onto the single INBOX socket at once. \(remaining) waiter(s) still queued (diagnostic) — \(snapshot)"
        )

        unpark(successorPark)
        await joinBounded(waiterA)
        await joinBounded(waiterB)
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - DEFERRED TO T3.7 — assertions the base cannot satisfy yet
    // ────────────────────────────────────────────────────────────────────────
    //
    // Stage (b). Each line names an invariant from the reference contract
    // (`v2final`, `TabMailTests/Providers/IMAPProviderPoolInvariantTests.swift`
    // plus the pool-state table in `v2final`'s `TabMail/Providers/
    // IMAPProvider.swift`) that THIS base violates, and why. None of them is
    // written as a failing test and none is `withKnownIssue`d: each lands in
    // the same commit as the production fix it pins.
    //
    // Line references are to `TabMail/Providers/IMAPProvider.swift` on this
    // branch as of T0.6(a); they will drift and are given as orientation, not
    // as identifiers.
    //
    // ACTION POOL
    //  D-01  `withActionConnectionSelection` / `withActionConnectionNoSelect`
    //        never capture `generation` at all, so an action task torn down
    //        mid-body still runs `releaseActionConnection` against the
    //        SUCCESSOR epoch — stripping a live holder's `actionInUse` mark and,
    //        on the unhealthy leg, logging out its connection. This is the
    //        exact hazard `zombieFolderReleaseNeverTouchesSuccessorEpochHolder`
    //        pins on the folder pool; the action pool has no equivalent guard.
    //  D-02  `ensureServer()` — the local function nested inside
    //        `acquireActionConnection` — is not single-flighted: two concurrent acquires
    //        that both observe `actionServer == nil` each run `createServer()`,
    //        and the loser's logged-in session is planted over without a
    //        LOGOUT. (Reference: R6-1 Part 2. The folder-pool analogue IS
    //        satisfied and ships now as
    //        `concurrentSameFolderAcquiresOpenExactlyOneConnection`.)
    //
    //        🔴 RED EVIDENCE — PRODUCED BY THE D-19 SEAM PORT, NOT INFERRED.
    //        D-02 was a reasoned-about defect until the plant-over trap landed.
    //        With `assertPoolSlotWasNil(actionServer, "actionServer
    //        (ensureServer create)")` armed at the plant (the reference's
    //        `v2final:…:2387` call site), the T0.8 fuzzer
    //        `ProviderIdQueueFuzzTests` trips it DETERMINISTICALLY — 3 isolated
    //        runs out of 3, plus the first full-suite run — at seed
    //        8131249127217430530. The `mutLog` tail dumped at the trap:
    //
    //          [12] releaseActionConnection(healthy:false) CLEARED actionServer=nil
    //          [13] ensureServer create START                 actionServer=nil
    //          [14] ensureServer create START                 actionServer=nil   ← TWO creators
    //          [15] ensureServer createServer SUCCEEDED        actionServer=nil
    //          [16] ensureServer PLANTED fresh                 actionServer=…ee40
    //          [17] acquire-not-in-use SET actionInUse=true    actionServer=…ee40 actionInUse=true
    //          [18] ensureServer createServer SUCCEEDED        actionServer=…ee40 actionInUse=true
    //          → trap: planted a connection over a non-nil actionServer slot
    //
    //        Reading: an injected fault's unhealthy release nils the slot [12];
    //        two acquires both observe nil and each start their own
    //        `createServer()` [13][14]; creator A plants and its caller checks
    //        the connection out [16][17]; creator B's RTT then returns [18] and
    //        its next statement would overwrite a LIVE, CHECKED-OUT slot —
    //        leaking A's logged-in session (never logged out, still counted
    //        against the server's connection cap) and leaving A's holder using
    //        a connection the pool no longer points at.
    //
    //        This satisfies Testing Rule 12's red-first requirement for D-02 in
    //        advance: the invariant is pinned, the failure was observed on the
    //        pre-fix code, and the fix (the reference's `actionServerCreating` +
    //        `actionServerCreationWaiters` single-flight) must re-arm that ONE
    //        assert line in the SAME commit. Until then the site is
    //        deliberately unarmed — see the comment at the plant in
    //        `TabMail/Providers/IMAPProvider.swift`. It is unarmed because the
    //        assertion is RIGHT and the pool is WRONG; the predicate has not
    //        been weakened anywhere.
    //  D-03  The post-liveness re-`ensureServer()` in `acquireActionConnection`
    //        adopts whatever instance it is handed instead of requiring the
    //        SAME instance it just NOOPed. (Reference: R6-1 Part 3.)
    //  D-04  The waiter resume tail in `acquireActionConnection` rebuilds via
    //        `ensureServer()` with no check that its transfer is still valid,
    //        so a teardown landing in the handoff's resume gap is undetectable
    //        and the resumed waiter proceeds onto a third task's connection.
    //        (Reference: R6-1 Part 1, action pool.) Needs a
    //        `releaseActionConnectionPostDequeueTestHook`, which in turn
    //        requires `releaseActionConnection` to become `async`.
    //  D-05  The "dead — recreating" branch plants `actionServer = fresh`
    //        unconditionally after its `createServer()` round-trip, with no
    //        re-validation that the slot still holds the instance it proved
    //        dead — so it overwrites a concurrent holder's fresh connection.
    //        (Reference: R8-F1 and its fuzzer-found sibling.)
    //  D-06  A healthy `releaseActionConnection` with a NIL slot resumes its
    //        next waiter as if a connection were being transferred; there is
    //        nothing to transfer. (Reference: Round 9 wedge, part 3.)
    //  D-07  `disconnect()`/`markDirty()` do not carry a creation-waiter queue
    //        for the action server at all, so the whole R7-F1 creation-waiter
    //        void family (queue-time generation capture, per-waiter resume
    //        tail) has no state to attach to.
    //
    // FOLDER POOL
    //  D-08  The keepalive folder loop tests `!folderInUse.contains(folder)`
    //        only BEFORE its NOOP await. A concurrent acquire's mark flip has
    //        zero intervening await and lands entirely inside the NOOP window,
    //        so the failure leg can still delete a checkout that began during
    //        the probe. (Reference: R8-F3. The BEFORE-check IS satisfied and
    //        ships now as
    //        `keepaliveSkipsCheckedOutConnectionsButStillReapsFreeDeadOnes`.)
    //  D-09  Keepalive's removal is not identity-guarded: it removes
    //        `folderServers[folder]` by key without checking the slot still
    //        holds the instance whose NOOP failed. (Reference: B-2.)
    //  D-10  `acquireFolderConnection` branch 1 inserts into `folderInUse`
    //        AFTER its liveness `noop()` await, so two concurrent same-folder
    //        acquires can both pass the branch guard and both return the same
    //        connection — a double checkout with no teardown involved.
    //        (Reference: R7-F2.) Its noop-SUCCESS tail also adopts the slot
    //        without an identity re-check (reference: R8-F3 parity with R6-1
    //        Part 3).
    //  D-11  `createFolderConnection`'s limit-retry catch removes the
    //        `folderCreating` mark at catch entry, before the retry's own
    //        eviction and creation — a window in which a concurrent same-folder
    //        acquire sees "nobody creating" and races a second creation.
    //        (Reference: R8-F2.)
    //  D-12  `markDirty()` clears `folderCreating` wholesale. The in-flight
    //        creation it belongs to is NOT cancelled, so clearing the mark
    //        admits a second colliding creation for the same folder.
    //        (Reference: item B / B-1.)
    //  D-13  `createFolderConnection` does not log out a server that logged in
    //        successfully but whose SELECT then failed: the `catch` throws
    //        without touching the local `server`, abandoning a logged-in
    //        session. (Reference: R11-H2. `FakeIMAPServer.abandonedSessionCount()`
    //        is the oracle.)
    //  D-14  Capacity waiters park in `folderWaiters[their-own-folder]`, a
    //        queue only same-folder events serve. A singleton acquire for a
    //        traffic-less folder is structurally never woken by the event it is
    //        waiting for — another folder's slot freeing. (Reference: the
    //        Round 9 `folderCapacityWaiters` queue and R10-F1's two extra wake
    //        sites.)
    //
    // CROSS-CUTTING
    //  D-15  `disconnect()` does not advance `generation` at all, and awaits
    //        each logout INLINE between its slot reads and its wipes. Every
    //        generation-keyed guard is therefore blind to a `disconnect()`, and
    //        an acquire landing mid-teardown adopts a connection `disconnect()`
    //        is about to steal. (Reference: R9-F1 — bump + wipe in ONE
    //        synchronous actor turn, logouts awaited afterwards from captured
    //        locals.) `disconnectFailsEveryParkedWaiterOnBothPools` ships the
    //        part that IS satisfied — the fail-all sweeps.
    //  D-16  `withFolderConnection` / the action wrappers re-validate
    //        `generation` only AFTER `body()` returns, never immediately before
    //        calling it, so `body()` itself can run against a connection a
    //        teardown already logged out. (Reference: cross-field invariant #6,
    //        the NO-LOGOUT-WHILE-HELD oracle's finding.)
    //  D-17  `withFolderConnection` captures `acquiredGeneration` BEFORE
    //        `acquireFolderConnection` rather than after. A teardown landing
    //        during the acquire makes the later release compare against a
    //        pre-teardown value, treat itself as stale, and skip — leaking the
    //        `folderInUse` mark until the next unrelated teardown. (Reference:
    //        R3 R-1, "capture generation AFTER acquire completes".)
    //  D-18  `evictLRUFolder()` draws its candidates from `folderLastUsed`,
    //        which also carries the action pool's `"__action__"` liveness
    //        timestamp. When that key is the oldest, eviction "succeeds"
    //        (returns true) having freed no connection at all, and deletes the
    //        action pool's liveness stamp as a side effect. (Reference: item D
    //        hygiene.) `evictionNeverTakesAConnectionOutFromUnderItsHolder`
    //        avoids the key rather than relying on it.
    //  D-19  🟠 PARTIAL — the seam has landed, but it is PARTIAL DIAGNOSTICS:
    //        3 of this base's 6 non-nil plant sites are armed, and the other 3
    //        are each blocked on a named, still-open defect. Do NOT read this
    //        entry as "the plant-over invariant is now enforced" — it is
    //        enforced on half the surface.
    //        Was: "No plant site asserts its slot was nil beforehand."
    //
    //        THE SIX PLANT SITES, and their status. (Two of them hide behind a
    //        dictionary subscript — `folderServers[folder] = …` — rather than a
    //        scalar field name, so a grep for `actionServer =` alone misses
    //        them.)
    //          1. `createFolderConnection` primary plant .......... ARMED
    //          2. `createFolderConnection` limit-retry plant ...... ARMED
    //          3. action dead-recreate self-replace .............. ARMED
    //                (via `assertActionServerSelfReplace`, the ONE documented
    //                 exception to "never plant over non-nil")
    //          4. nested `ensureServer()` create ............ UNARMED — D-02
    //          5. `setIdleServer(_:)` ...................... UNARMED — D-20
    //          6. `connect()`'s unconditional plant ........ UNARMED — D-23
    //
    //        It already paid for itself even at 3/6: it turned D-02 from a
    //        reasoned-about defect into observed red evidence on its first run
    //        (see D-02 above).
    //
    //        NEAR-VERBATIM, not verbatim. `TabMail/Providers/IMAPProvider.swift`
    //        carries a NEAR-verbatim port of the reference's plant-over trap
    //        system — `assertPoolSlotWasNil` (`v2final:…:494`),
    //        `assertActionServerSelfReplace` (`:524`) and the `mutLog` /
    //        `logMut` / `mutLogForTesting` ring journal (`:629-636`), which is
    //        the ONLY post-mortem channel a trap leaves behind (the `assert`
    //        kills the process before any fuzzer's end-of-round dump can run).
    //        The two assert BODIES are byte-identical to the reference's. Four
    //        things are not:
    //          (a) COVERAGE. The reference arms FOUR call sites (`v2final:…`
    //              `:1767`, `:1839`, `:2387`, `:2586`) and has only four plant
    //              sites to arm, because it eliminated `connect()`'s plant (B-3)
    //              and made the IDLE plant structurally impossible
    //              (`claimIdleServerSlot`). This base has six and arms three.
    //          (b) JOURNAL FIELDS. The reference's `logMut` line also carries
    //              `actionServerCreating=`; this base has no such field to
    //              print, because that field IS D-02's single-flight state.
    //          (c) GATING. The reference leaves the journal family's
    //              DECLARATIONS ungated and gates only `logMut`'s body; here
    //              the whole family and every call site sit inside `#if DEBUG`.
    //              (Already disclosed at the seam block itself.)
    //          (d) CALL SITES. The self-replace call passes the local the
    //              enclosing branch proved dead; the reference additionally
    //              guards `actionServer === deadInstance` BEFORE the plant and
    //              refuses otherwise (its R8-F1 fix), which is deferred here as
    //              D-05 — so the same assert is defense-in-depth there and a
    //              live check here.
    //
    //        WHY THREE SITES ARE UNARMED — and why that is not a weakening of
    //        the assertion (R6). A trap belongs at a plant whose plant-over is
    //        already structurally excluded, so that it catches a FUTURE
    //        regression. Where the exclusion is the very thing still missing,
    //        an armed trap is not a regression detector — it is a guaranteed
    //        debug-build process kill on a defect already on the books, taking
    //        ~7.8k unrelated test results with it every run. The predicate was
    //        not softened anywhere; the arming line is simply absent at three
    //        sites, each recorded with its blocking defect (D-02 above, D-20
    //        and D-23 below).
    //
    //        Why it lands NOW rather than with T3.7's fixes: a trap added AFTER
    //        a pool fix cannot red-prove it, and BOTH of the reference pool
    //        fuzzer's acceptance-gate findings were detected by this trap and
    //        nothing else — so §6.3's Testing-Rule-11 gate ("rediscover a known
    //        defect with its fix reverted") is unmeetable without it in place
    //        first. Deliberately has no dedicated test of its own, for the
    //        reason the reference states in the helper's own doc comment: a
    //        firing `assert` traps the whole process, so a test that provoked it
    //        would kill the run rather than fail one case.
    //
    //        ── IS THE D-02 RE-ARM COUPLING MACHINE-CHECKABLE? Considered, and
    //        deliberately NOT built. Recording the reasoning, because the
    //        question will be asked again.
    //        The coupling at issue is: *D-02's single-flight fix must arm site 4
    //        in the SAME commit, or the red evidence banked under D-02 is
    //        orphaned.* Today that is enforced by prose here and by a comment
    //        at the plant itself. Three candidate checks were weighed:
    //          • PIN THE INVENTORY ("exactly 3 armed call sites in
    //            `IMAPProvider.swift`"). REJECTED — it points the wrong way. It
    //            goes RED on the SAFE transition (someone arms site 4, i.e.
    //            does the right thing) and stays GREEN on the DANGEROUS one
    //            (the single-flight fix lands with site 4 left unarmed — the
    //            count is still 3). A tripwire that is green in exactly the
    //            failure mode it advertises is worse than no tripwire: it is
    //            false assurance, and it taxes the correct action.
    //          • PIN THE FIX'S MECHANISM (`source contains
    //            "actionServerCreating"` ⟺ `site 4 is armed`). Points the right
    //            way, but pins the MECHANISM rather than the invariant — a
    //            differently-shaped single-flight satisfies neither side and
    //            the check stays green while the arming is missed. That is the
    //            specific failure this project has already been burned by twice
    //            (Testing Rule 12's "pin the INVARIANT, not the fix's
    //            mechanism").
    //          • PIN THAT THE THREE ARMED SITES STAY ARMED (a floor, not an
    //            equality). Sound and correctly pointed, but it guards a
    //            DIFFERENT risk (silent disarming) that already has behavioural
    //            detectors — `concurrentSameFolderAcquiresOpenExactlyOneConnection`
    //            and the `abandonedSessionCount()` leak oracle both go red if
    //            those plants regress — so it would add call-site-text
    //            fragility without adding a property.
    //        The only correctly-pointed detector for the actual coupling is
    //        BEHAVIOURAL: an action-pool analogue of
    //        `concurrentSameFolderAcquiresOpenExactlyOneConnection`. It cannot
    //        be written today without being a known-failing or `withKnownIssue`
    //        test — which is what this whole DEFERRED block exists to avoid,
    //        and is the prohibited "test that blesses the bug". It is already
    //        mandated to land in D-02's fix commit, where it will be red-first
    //        against the evidence banked above.
    //        Conclusion: for THIS item, an accurate comment is the honest
    //        ceiling. The overclaim was the defect; it is corrected above.
    //
    // IDLE CONNECTION
    //  D-20  `launchIdleConnection` plants through `setIdleServer(_:)`, which
    //        assigns unconditionally. It does not re-check
    //        `idleEnabled && idleServer == nil` in the same synchronous step as
    //        the plant, so two overlapping launches clobber each other and the
    //        loser's session is leaked. (Reference: R7-F3's
    //        `claimIdleServerSlot`.)
    //        D-19 NOTE — this is site 5 of D-19's six, one of the THREE the
    //        trap does not cover (the others are D-02 and D-23). It is the only
    //        one of the three the reference does not cover either:
    //        `claimIdleServerSlot`
    //        makes the plant-over structurally impossible (`guard idleServer ==
    //        nil` in the SAME synchronous actor step as the assignment), so an
    //        `assertPoolSlotWasNil` there would be dead code in the reference
    //        and a certain trap here. The fix IS the structural guard, and it
    //        leaves no trap gap behind it. Its detector is the leak oracle
    //        (`FakeIMAPServer.abandonedSessionCount()`), not the assert.
    //  D-21  `onIdleStreamEnded(delay:)` takes no owner and clears `idleServer`
    //        unconditionally, so a stale listener's stream-end tears down a
    //        healthy successor. (Reference: R7-F3's `onIdleStreamEnded(owner:)`
    //        identity guard.)
    //  D-22  `markDirty()` logs the IDLE connection out without first sending
    //        DONE, so the LOGOUT goes through SwiftMail's
    //        `IMAPConnection.waitForIdleCompletionIfNeeded(timeoutSeconds:)`
    //        (declared in `IMAPConnection+Idle.swift`, default 15s) instead of
    //        completing promptly. `stopIdle()` in this base DOES send `done()`
    //        first; `markDirty()` does not.
    //
    // NEW, FILED BY THE D-19 SEAM PORT
    //  D-23  `connect()` plants `actionServer = try await createServer()`
    //        UNCONDITIONALLY, overwriting a live non-nil slot (leaking the old
    //        logged-in connection) and racing any concurrent create.
    //        `AccountManagerSync.ensureConnected` calls `connect()` on an
    //        already-connected provider as a matter of course, so this is not a
    //        rare interleaving — it is the normal second sync of a session.
    //        (Reference: finding B-3. Its fix is to route `connect()` through
    //        the single-flighted `ensureServer()` — `v2final:…:2876-2886` — with
    //        staleness left to `markDirty()`, exactly as `ensureConnected`'s own
    //        doc comment already describes.)
    //        This is site 6 of D-19's six — one of the THREE its trap
    //        deliberately leaves unarmed (with D-02 and D-20).
    //        Arming `assertPoolSlotWasNil` here today would not catch a future
    //        regression, it would guarantee a debug-build process kill on an
    //        already-known defect — the reference closed the hole by changing
    //        the code, which a purely-additive seam item may not do. Once the
    //        B-3 fix lands, the plant lives inside `ensureServer()` and is
    //        trapped there automatically, so no separate trap is ever needed.
    //        The `logMut("connect() PLANTED (UNGUARDED — D-23)")` journal entry
    //        is present so a post-mortem can still see this writer.
}
