/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit

// MARK: - Backfill Progress Model

struct BackfillProgress {
    let accountId: String
    let email: String
    var startedAt: Date
    var isPaused: Bool
    /// True once all folders have finished header backfill (UID/page-token walk complete).
    var headersDone: Bool

    /// Total emails in FTS for this account (denominator — grows while headers are crawled)
    var totalEmails: Int = 0
    /// Emails with non-empty FTS body for this account (numerator)
    var ftsIndexed: Int = 0

    /// UID-based progress (IMAP): total UIDs across all folders (sum of UIDNEXT-1)
    var uidTotal: Int = 0
    /// UID-based progress (IMAP): UIDs already walked (UIDNEXT-1 minus cursor for each folder)
    var uidWalked: Int = 0

    /// Count of body-eligible headers still awaiting fetch — `headerComplete=1`,
    /// no body yet, not confirmed-empty. Matches the selection criteria the body
    /// queues use (BackfillBodyQueue/ActiveBodyQueue). The backfill body phase is
    /// done when this reaches 0. Used for completion INSTEAD of `ftsIndexed >=
    /// totalEmails`, because `totalEmails` can be a server-reported count that
    /// counts a different population than what we store (see `isFullyComplete`).
    var pendingBodyCount: Int = 0

    // EMA rate tracking — messages per second.
    var lastIndexedCount: Int = 0
    var lastRateUpdate: Date = .distantPast
    var emaRate: Double = 0
    var emaUpdateCount: Int = 0
    private static let emaWindowSize: Int = 10_000

    /// Linear progress: uses UID walk during header phase, FTS indexing after.
    /// UID walk progress is more accurate during backfill because UIDNEXT gives
    /// a known total scope, unlike FTS where the denominator keeps growing.
    var fractionComplete: Double {
        if !headersDone && uidTotal > 0 {
            return min(1.0, Double(uidWalked) / Double(uidTotal))
        }
        guard totalEmails > 0 else { return 0.0 }
        return min(1.0, Double(ftsIndexed) / Double(totalEmails))
    }

    /// True when the header crawl is done AND every fetchable body is indexed.
    ///
    /// Gates on `pendingBodyCount == 0` rather than `ftsIndexed >= totalEmails`.
    /// `totalEmails` is a server-reported denominator for Gmail/Exchange that
    /// counts a DIFFERENT population than the mail headers we store — for
    /// Exchange it's `SUM(folder.totalItemCount)` (incl. Deleted Items, Junk,
    /// hidden/system folders, and non-mail items dropped on parse); for Gmail
    /// it's the dedup'd `messagesTotal` vs. our per-label rows. It can permanently
    /// exceed what we can ever store, so an `ftsIndexed >= totalEmails` gate would
    /// never be satisfiable and "Sync Complete" would never fire. `pendingBodyCount`
    /// is local and self-terminating (empty/404/oversized bodies confirm-empty),
    /// so it reaches 0 once the body queues have nothing fetchable left.
    var isFullyComplete: Bool {
        headersDone && totalEmails > 0 && pendingBodyCount == 0
    }

    /// ETA in seconds based on exponential moving average of indexing rate.
    var estimatedSecondsRemaining: Double? {
        let remaining = totalEmails - ftsIndexed
        guard remaining > 0, emaRate > 0.01 else { return nil }
        return Double(remaining) / emaRate
    }

    /// Update EMA rate based on new indexed count. Call after each progress update.
    mutating func updateRate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateUpdate)
        let delta = ftsIndexed - lastIndexedCount
        if elapsed >= 1.0 && delta > 0 {
            let instantRate = Double(delta) / elapsed
            emaUpdateCount = min(emaUpdateCount + 1, Self.emaWindowSize)
            let alpha = 1.0 / Double(emaUpdateCount)
            emaRate = alpha * instantRate + (1 - alpha) * emaRate
            lastIndexedCount = ftsIndexed
            lastRateUpdate = now
        } else if delta > 0 && lastRateUpdate == .distantPast {
            lastIndexedCount = ftsIndexed
            lastRateUpdate = now
        }
    }
}

/// Deduplicates concurrent OAuth refresh calls for a single account.
/// Prevents race where mail + calendar providers both get 401 and refresh the same token.
/// Microsoft rotates refresh tokens on use — second caller with the old token would fail.
actor OAuthRefreshCoordinator {
    private var inFlightTask: Task<String, any Error>?
    /// Once invalidated, all future refresh attempts immediately fail.
    /// Prevents stale closures from refreshing tokens after account removal.
    private var invalidated = false

    /// Mark this coordinator as invalidated. Cancels any in-flight refresh.
    func invalidate() {
        invalidated = true
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    func refresh(
        accountId: String,
        email: String,
        using refresher: @escaping @Sendable (_ refreshToken: String) async throws -> OAuthTokens
    ) async throws -> String {
        // SECURITY: Refuse to refresh after account has been removed
        guard !invalidated else {
            print("[OAuth] Refusing refresh for \(email): coordinator invalidated (account removed)")
            throw ProviderError.authenticationFailed
        }

        // Dedup: if another refresh is already in flight, await it
        if let existing = inFlightTask {
            print("[OAuth] Awaiting in-flight refresh for \(email)...")
            return try await existing.value
        }

        let task = Task<String, any Error> {
            guard let refreshToken = KeychainHelper.loadString(key: KeychainHelper.refreshTokenKey(accountId: accountId)) else {
                print("[OAuth] Auth failed for \(email): refresh token missing from keychain")
                throw ProviderError.authenticationFailed
            }
            print("[OAuth] Refreshing access token for \(email)...")
            let tokens = try await refresher(refreshToken)
            try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: accountId))
            if let newRefresh = tokens.refreshToken {
                try KeychainHelper.save(newRefresh, for: KeychainHelper.refreshTokenKey(accountId: accountId))
            }
            return tokens.accessToken
        }
        inFlightTask = task

        do {
            let result = try await task.value
            inFlightTask = nil
            return result
        } catch {
            inFlightTask = nil
            throw error
        }
    }
}

/// Serializes every bounded mutation of the durable message-action queue.
///
/// The permit protects queue selection and GRDB mutation only. Callers must
/// never perform provider I/O, callbacks, sleeps, or retry delays while holding
/// it. Cancellation removes a queued waiter; if cancellation races with a
/// handoff, the acquired permit is returned before the error escapes.
final class PendingOperationMutationGate: Sendable {
    /// Opaque process-local ownership proof. It is never persisted or used as
    /// message/Undo identity.
    struct Lease: Sendable {
        fileprivate let ownerID: UUID
    }

    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State: Sendable {
        var ownerID: UUID?
        var waiters: [Waiter] = []
    }

    private enum Resumption: Sendable {
        case cancelled(CheckedContinuation<Bool, Never>)
        case granted(CheckedContinuation<Bool, Never>)
        case none

        func resume() {
            switch self {
            case .cancelled(let continuation):
                continuation.resume(returning: false)
            case .granted(let continuation):
                continuation.resume(returning: true)
            case .none:
                break
            }
        }
    }

    private let state = Mutex(State())

    /// Acquires the process-wide permit. Callers must immediately install
    /// `defer { gate.release(lease) }` before any other throwing operation.
    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()

        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = state.withLock { state -> Bool? in
                    if Task.isCancelled {
                        return false
                    }
                    if state.ownerID == nil {
                        state.ownerID = id
                        return true
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            self.cancelAcquisition(id: id)
        }

        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            releaseIfOwner(id: id)
            throw CancellationError()
        }
        return Lease(ownerID: id)
    }

    /// Synchronous so release is safe from `defer` on every exit path. A stale
    /// or duplicated lease is rejected and cannot release a successor's permit.
    @discardableResult
    func release(_ lease: Lease) -> Bool {
        release(ownerID: lease.ownerID, beforeResumingWaiter: nil)
    }

    private func cancelAcquisition(id: UUID) {
        let resumption = state.withLock { state -> Resumption in
            if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                let waiter = state.waiters.remove(at: index)
                return .cancelled(waiter.continuation)
            }

            // Release may have transferred ownership before resuming this
            // continuation. Reclaim that exact handoff synchronously.
            guard state.ownerID == id else { return .none }
            guard !state.waiters.isEmpty else {
                state.ownerID = nil
                return .none
            }

            let next = state.waiters.removeFirst()
            state.ownerID = next.id
            return .granted(next.continuation)
        }
        resumption.resume()
    }

    private func releaseIfOwner(id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.ownerID == id else { return nil }
            guard !state.waiters.isEmpty else {
                state.ownerID = nil
                return nil
            }

            let next = state.waiters.removeFirst()
            state.ownerID = next.id
            return next.continuation
        }
        continuation?.resume(returning: true)
    }

    private func release(
        ownerID: UUID,
        beforeResumingWaiter: (@Sendable () -> Void)?
    ) -> Bool {
        let result = state.withLock {
            state -> (released: Bool, continuation: CheckedContinuation<Bool, Never>?) in
            guard state.ownerID == ownerID else {
                return (false, nil)
            }
            guard !state.waiters.isEmpty else {
                state.ownerID = nil
                return (true, nil)
            }

            let next = state.waiters.removeFirst()
            state.ownerID = next.id
            return (true, next.continuation)
        }
        if result.continuation != nil {
            beforeResumingWaiter?()
        }
        result.continuation?.resume(returning: true)
        return result.released
    }

    #if DEBUG
    var isHeldForTesting: Bool {
        state.withLock { $0.ownerID != nil }
    }

    var waiterCountForTesting: Int {
        state.withLock { $0.waiters.count }
    }

    /// Forces the ownership-transfer/cancellation interleaving without sleeps.
    @discardableResult
    func releaseForTesting(
        _ lease: Lease,
        beforeResumingWaiter: @escaping @Sendable () -> Void
    ) -> Bool {
        release(ownerID: lease.ownerID, beforeResumingWaiter: beforeResumingWaiter)
    }
    #endif
}

actor AccountManager {
    static let shared = AccountManager()

    /// One process-wide permit for durable message-action queue mutations.
    nonisolated let pendingOperationMutationGate = PendingOperationMutationGate()

    var providers: [String: any EmailProvider] = [:]
    var workQueues: [String: ProviderWorkQueue] = [:]
    var calendarProviders: [String: any CalendarProvider] = [:]
    /// Per-op outcome awaiters used by `calendar_event_create` to surface drain
    /// results back to the LLM in the same turn (so it can correct args on
    /// permanent failure). Key = `PendingCalendarOperation.id`. Resumed exactly
    /// once by the drain at every terminal branch (success/notFound/scope/
    /// auth/badRequest) and on transient retry-back-to-queued.
    var calendarOpAwaiters: [String: CheckedContinuation<CalendarOpOutcome, Never>] = [:]
    let syncEngine = SyncEngine()
    private var _oauthService: OAuthService?
    /// OAuthService is @MainActor (uses ASWebAuthenticationSession).
    /// Created lazily on first use from MainActor context. All callers
    /// are async and hop to MainActor for the OAuth UI flow anyway.
    var oauthService: OAuthService {
        get async {
            if let existing = _oauthService { return existing }
            let service = await MainActor.run { OAuthService() }
            _oauthService = service
            return service
        }
    }
    let backendClient = BackendClient()

    /// Per-account OAuth refresh coordinators — shared between mail + calendar providers
    /// to prevent concurrent refresh token rotation races.
    private var oauthCoordinators: [String: OAuthRefreshCoordinator] = [:]

    private func oauthCoordinator(for accountId: String) -> OAuthRefreshCoordinator {
        if let existing = oauthCoordinators[accountId] {
            return existing
        }
        let coordinator = OAuthRefreshCoordinator()
        oauthCoordinators[accountId] = coordinator
        return coordinator
    }

    /// Account IDs that failed authentication (shown in settings)
    var authFailedAccounts: Set<String> = [] {
        didSet {
            let copy = authFailedAccounts
            Task { @MainActor in AccountManagerState.shared.authFailedAccounts = copy }
        }
    }

    /// Check if an error is a genuine authentication failure (not a timeout or network error).
    nonisolated func isAuthError(_ error: Error) -> Bool {
        if case ProviderError.authenticationFailed = error { return true }
        let msg = "\(error)"
        // IMAP LOGIN failures contain "NO [AUTHENTICATIONFAILED]" or "LOGIN failed"
        if msg.contains("AUTHENTICATIONFAILED") { return true }
        if msg.contains("LOGIN failed") || msg.contains("login failed") { return true }
        // Reject app-specific password errors
        if msg.contains("Application-specific password required") { return true }
        return false
    }

    /// Account IDs where Gmail backfill hit the message ID cap (shown in settings)
    var backfillCapReachedAccounts: Set<String> = [] {
        didSet {
            let copy = backfillCapReachedAccounts
            Task { @MainActor in AccountManagerState.shared.backfillCapReachedAccounts = copy }
        }
    }

    // processingAccounts and aiProcessingTasks removed — AI processing now handled by
    // ActiveBodyQueue + ActiveAIQueue actors (event-driven, decoupled from sync).

    var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    // MARK: - Demo Mode provider injection

    /// Plug a demo email + calendar provider into the active provider lookup.
    /// `DemoModeService.completeSetup()` calls this after seeding GRDB.
    /// Existing provider entries for the same accountId are replaced.
    func registerDemoProviders(email: any EmailProvider, calendar: any CalendarProvider, accountId: String) {
        providers[accountId] = email
        calendarProviders[accountId] = calendar
        print("[AccountManager] Registered demo providers for accountId=\(accountId)")
    }

    /// Remove the demo providers. Called by `DemoModeService.exit()`.
    func unregisterDemoProviders(accountId: String) {
        providers.removeValue(forKey: accountId)
        calendarProviders.removeValue(forKey: accountId)
        print("[AccountManager] Unregistered demo providers for accountId=\(accountId)")
    }

    // MARK: - Test-only provider injection

    /// Test seam: populate `providers`/`workQueues` for `accountId` exactly as
    /// `connectAccount` does (same `ProviderWorkQueue` construction), without
    /// the network `provider.connect()` call or `syncEngine.register` —
    /// neither is needed to exercise `drainPendingQueue()`/`executeSingleOp`
    /// against a `MockEmailProvider`. Overwrites any existing provider/queue
    /// for `accountId` (mirrors `registerDemoProviders`'s replace-on-call
    /// semantics). Mirrors the `…ForTesting()` naming convention
    /// (`intentionJournal.recordsForTesting()`).
    func registerProviderForTesting(accountId: String, provider: any EmailProvider) {
        providers[accountId] = provider
        workQueues[accountId] = ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling)
    }

    /// Test seam: undo `registerProviderForTesting`. Tests should call this in
    /// their teardown so a registered mock provider/queue doesn't leak into a
    /// later test that reuses the same accountId (the primary defenses are
    /// `.serialized` suites + unique accountIds per test — this closes the
    /// gap for tests that want an explicit unregister).
    func unregisterProviderForTesting(accountId: String) {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)
    }

    /// Test seam: populate `calendarProviders` for `accountId` — mirrors
    /// `registerProviderForTesting`'s email-side seam, but for
    /// `reconcileCalendarQueue()`/`drainCalendarQueue()`, which look up
    /// `calendarProviders` directly (no `ProviderWorkQueue`; the calendar
    /// queue has no per-account concurrency ceiling).
    func setCalendarProviderForTesting(_ provider: any CalendarProvider, accountId: String) {
        calendarProviders[accountId] = provider
    }

    /// Test seam: undo `setCalendarProviderForTesting`.
    func unsetCalendarProviderForTesting(accountId: String) {
        calendarProviders.removeValue(forKey: accountId)
    }

    /// Guard for pending queue drain (used by AccountManagerQueue).
    var isDraining = false
    /// Set when drainPendingQueue() is called while isDraining — triggers re-drain on completion.
    var needsRedrain = false

    /// One finite pre-execution cutover shared by every message-queue drain caller.
    /// Keying both the ready marker and the in-flight task to the actual
    /// AppDatabase instance keeps process-global database swaps isolated without
    /// adding any durable migration token. The flight retains its database while
    /// work is active; the ready marker is weak so replacing the process database
    /// does not keep the old pool alive. A weak identity cannot be retargeted by
    /// address reuse, while the flight id prevents an older waiter from clearing
    /// or publishing over a newer flight.
    struct PendingQueuePreparationFlight: Sendable {
        let id: UUID
        let database: AppDatabase
        let task: Task<Void, any Error>
        var participantCount: Int
    }

    weak var pendingQueuePreparedDatabase: AppDatabase?
    var pendingQueuePreparationFlight: PendingQueuePreparationFlight?
    var pendingQueueAuthorizationHookForTesting: (@Sendable () async -> Void)?
    /// Test-only seam awaited at the START of a new preparation flight
    /// (before crash recovery). Captured once at flight creation. Exists so
    /// database-lifecycle tests can hold a specific database's preparation
    /// open deterministically — the deleted legacy identity converter used to
    /// provide that suspension point via its provider lookups.
    var pendingQueuePreparationHookForTesting: (@Sendable () async -> Void)?

    // MARK: - FIFO Local Write Queue

    /// Serial queue for ALL local DB writes from user actions.
    /// Ensures writes commit in the same order the user performed them,
    /// eliminating races between concurrent Tasks (e.g., markRead + move).
    private var writeQueue: [@Sendable () async -> Void] = []
    private var isDrainingLocalWrites = false

    /// Enqueue a local DB write. Executes FIFO. Never blocks caller.
    func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        writeQueue.append(work)
        if !isDrainingLocalWrites {
            isDrainingLocalWrites = true
            Task { await drainLocalWrites() }
        }
    }

    private func drainLocalWrites() async {
        while !writeQueue.isEmpty {
            let work = writeQueue.removeFirst()
            await work()
        }
        isDrainingLocalWrites = false
    }

    /// FIFO barrier — returns once every closure enqueued before this call
    /// has run. Appends a continuation-resuming closure to the back of
    /// `writeQueue`; because the queue is strictly FIFO, every write enqueued
    /// earlier is guaranteed to have drained by the time this returns.
    /// `AccountManager` is an actor and `enqueueWrite` is a same-actor call,
    /// so no `Task` hop is needed here (contrast the test-only mirror of this
    /// pattern, which hops via `Task` because it's called from `@MainActor`
    /// test code). Used by `AppDelegate`'s background durability checkpoint
    /// to flush queued writes (including ADR-IOS-057 intent-cycle executors)
    /// before the WAL fsync.
    func awaitWriteQueueDrain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enqueueWrite { cont.resume() }
        }
    }

    /// Races `awaitWriteQueueDrain()` against a deadline: returns as soon as
    /// EITHER the drain barrier resumes OR `timeoutSeconds` elapses, whichever
    /// is first — never blocks past the deadline. On timeout the barrier's
    /// continuation isn't lost, just abandoned by this call: it still resumes
    /// later once the queue actually drains (per `awaitWriteQueueDrain`'s own
    /// contract) — its result is simply discarded because nobody is waiting
    /// on it anymore. Extracted as a standalone static func (rather than
    /// inlined at the call site) so both production (`AppDelegate`'s
    /// background durability checkpoint) and tests exercise the exact same
    /// race code.
    ///
    /// Deliberately NOT a `withTaskGroup` race of two child tasks. Verified
    /// empirically: `withTaskGroup` implicitly awaits every child task before
    /// its closure scope returns — even after `cancelAll()` — and cancellation
    /// is cooperative, so a child parked on `awaitWriteQueueDrain()`'s bare
    /// `CheckedContinuation` (which never observes cancellation) is NOT
    /// forcibly finished; the outer call blocks until it actually resumes,
    /// i.e. until the queue genuinely drains. That reintroduces the exact
    /// "pathological queue holds the background budget hostage" failure this
    /// method exists to prevent. Instead, race two UNSTRUCTURED `Task`s (which
    /// are allowed to outlive this function) against a single shared
    /// continuation, guarded so it resumes exactly once: whichever finishes
    /// first — the drain or the timer — resumes the caller; the loser keeps
    /// running harmlessly to completion (a no-op second `finishOnce()` call)
    /// once the queue actually drains later.
    static func awaitWriteQueueDrainOrTimeout(timeoutSeconds: Double) async {
        await withCheckedContinuation { (outer: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            let finishOnce: @Sendable () -> Void = {
                guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                outer.resume()
            }
            Task {
                // Journal-aware drain (ADR-IOS-058 rounds 8-9): a bare FIFO
                // barrier misses a `record()` whose fold-enqueue Task hasn't
                // reached the actor yet (unstructured Tasks give no
                // creation-order arrival guarantee) — the exact race class
                // round 2 hardened in the TEST drain helpers. Loop the
                // barrier until the intention journal is fully drained so a
                // gesture recorded moments before backgrounding gets its
                // local write + PendingOperation committed BEFORE the WAL
                // checkpoint fsyncs. The racing TIMER below is the SOLE
                // bound (never-block-past-deadline, unchanged) — round 9
                // removed the defensive iteration cap: on an idle queue with
                // records parked in a read-error retry window
                // (`intentionResolveRetryDelaySeconds`), near-instant
                // barrier round-trips exhausted the cap BEFORE the retry
                // re-enqueued, resuming early and reopening the gap. The
                // poll interval paces the loop across that window instead
                // of spinning.
                repeat {
                    await AccountManager.shared.awaitWriteQueueDrain()
                    if AccountManager.shared.intentionJournal.isFullyDrained() { break }
                    try? await Task.sleep(nanoseconds: UInt64(SyncConfig.backgroundFlushDrainPollSeconds * 1_000_000_000))
                } while !resumed.withLock({ $0 })
                finishOnce()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finishOnce()
            }
        }
    }

    // MARK: - Recently Completed Protection (per-entry expiry)

    /// Message IDs recently protected from sync stale-deletion/overwrite, keyed to
    /// their EXPIRY date (not insertion date — each entry carries its own TTL).
    /// Two distinct callers use different TTLs:
    /// - PendingOperation completion (`AccountManagerQueue`) bridges the gap between
    ///   PendingOp deletion and server-side state propagation — default TTL
    ///   `SyncConfig.recentlyCompletedTTLSeconds` (30s).
    /// - NSE push-merge arrival (`NSEDataBridge`) protects a message that just became
    ///   durable via push-merge from a transient server-fetch miss — longer TTL
    ///   `SyncConfig.pushMergeStaleProtectionTTLSeconds` (120s), because push-merged
    ///   rows are upserted ONLY by the merge (sync deliberately skips their upsert
    ///   while protected), so a miss needs more margin to self-correct than an
    ///   action-completion propagation gap.
    /// Sync writes check this to avoid overwriting/deleting just-arrived rows with
    /// stale server data.
    private(set) var recentlyCompleted: [String: Date] = [:]

    func recordRecentlyCompleted(messageIds: [String], ttl: TimeInterval = SyncConfig.recentlyCompletedTTLSeconds) {
        let now = Date()
        let expiresAt = now.addingTimeInterval(ttl)
        for id in messageIds {
            // Live protection is monotonic: a later 30-second action completion
            // must not truncate a push merge's 120-second stale-data shield.
            // Non-positive TTL remains an intentional test/cleanup expiry.
            if expiresAt <= now {
                recentlyCompleted[id] = expiresAt
            } else if let existing = recentlyCompleted[id] {
                recentlyCompleted[id] = max(existing, expiresAt)
            } else {
                recentlyCompleted[id] = expiresAt
            }
        }
    }

    func pruneRecentlyCompleted() {
        let now = Date()
        recentlyCompleted = recentlyCompleted.filter { $0.value > now }
    }

    func isRecentlyCompleted(_ msgId: String) -> Bool {
        guard let expiresAt = recentlyCompleted[msgId] else { return false }
        return Date() < expiresAt
    }

    // MARK: - Optimistic Overlay

    /// Pending mutations registered by user actions before their DB writes commit.
    /// Readable synchronously from MainActor (Mutex, no await needed).
    /// `reloadMessages()` snapshots this BEFORE its DB read and applies on top.
    struct PendingMutation: Sendable, Equatable {
        var isRead: Bool?
        var folderId: String?
        var folderPath: String?
        var isInInbox: Bool?
        var isFlagged: Bool?
        var actionTag: ActionTag??  // nil = no change, .some(nil) = clear tag
    }

    /// Intention journal (ADR-IOS-058): the in-memory, totally-ordered record
    /// of pending user intentions that `record(...)` appends to and
    /// `executeFold(triggerId:)` consumes. The display overlay
    /// (`snapshotOverlay()`) is DERIVED from it —
    /// `IntentionJournal.derivedOverlay()` folds every pending + in-flight
    /// record's display, replacing the formerly-imperative overlay dict. See
    /// `AccountManagerIntentions.swift`. `nonisolated`: `IntentionJournal` is
    /// itself `Sendable` and self-synchronizing (Mutex-guarded), so exposing
    /// the reference without an actor hop is safe — and required for
    /// synchronous test seams (`recordsForTesting()`/
    /// `isFullyDrainedForTesting()`/`seedDisplayForTesting(id:mutation:)`/
    /// `resetForTesting()`) called from non-isolated test contexts.
    nonisolated let intentionJournal = IntentionJournal()

    /// The overlay is DERIVED (ADR-IOS-058): `snapshotOverlay()` returns the
    /// intention journal's fold of pending + in-flight records
    /// (`IntentionJournal.derivedOverlay()`), not an imperatively maintained
    /// dict. Entry lifetime = "id has pending or in-flight records" — an id
    /// with no records simply isn't present in the returned dictionary; there
    /// is no separate removal step. All 8 production consumers —
    /// `InboxListReader` ×2, `InboxViewModel.flushAIBatch`/
    /// `insertUndoneMessages`/`insertStagedRows`,
    /// `MessageDetailViewModel.applyOverlay` ×2, `NavigationStore.refreshFolders`
    /// — read this synchronously and are unchanged by the interface; only the
    /// SOURCE moved from an imperatively-maintained dict to a derived read.
    nonisolated func snapshotOverlay() -> [String: PendingMutation] {
        intentionJournal.derivedOverlay()
    }

    /// Undo snapshots must capture the VISUALIZED state (act-on-visualized-state
    /// rule): a still-pending intention's isRead/isFlagged/actionTag exist only in
    /// the derived overlay until the fold executes, and a DB-fresh row predates
    /// them — an undo restoring that row would silently revert the user's most
    /// recent gesture. Folder fields are deliberately NOT taken from the overlay
    /// (a pending move's dest must not leak into a snapshot that records the
    /// pre-move location).
    ///
    /// MUST be called BEFORE the call site's own `record()` call — `record()`
    /// appends THIS action's own overlay mutation (e.g. the F6 tag-clear on
    /// inbox exit) into the journal, and the derived overlay folds it into the
    /// SAME coalesced entry this reads. Calling it after would capture this
    /// action's own not-yet-executed mutation as if it were pre-existing state.
    nonisolated func overlayAdjustedSnapshot(_ header: MessageHeader) -> MessageHeader {
        guard let m = snapshotOverlay()[header.id] else { return header }
        var h = header
        if let isRead = m.isRead { h.isRead = isRead }
        if let isFlagged = m.isFlagged { h.isFlagged = isFlagged }
        if let actionTag = m.actionTag {
            h.actionTag = actionTag
            h.tagSortOrder = actionTag?.sortOrder ?? 99
        }
        return h
    }

    // MARK: - Gesture Intent Adapter (ADR-IOS-058)

    /// A single-field gesture intent for `id`. This is the call-site-facing
    /// shape `registerGestureIntent` accepts — the 8 production toggle/tag
    /// call sites (`InboxViewModel.toggleRead`/`toggleFlag`/`applyManualTag`,
    /// `MessageDetailViewModel.toggleRead`/`applyManualTag`/
    /// `markReadOnOpenIfNeeded` ×2/`toggleReadForThread`) construct this enum
    /// unchanged across the ADR-IOS-058 reset; only `registerGestureIntent`'s
    /// internals moved onto `record()`.
    enum GestureIntent: Sendable {
        case isRead(target: Bool, baseline: Bool)
        case isFlagged(target: Bool, baseline: Bool)
        case actionTag(target: ActionTag?, baseline: ActionTag?)
    }

    /// Thin adapter over `record()` (ADR-IOS-058, `AccountManagerIntentions.swift`):
    /// maps a `GestureIntent` to one `record(...)` call and does nothing
    /// else — `record()` already appends the journal record (which the
    /// derived overlay reads) and enqueues the fold-executor closure; this
    /// adapter must not duplicate any of that bookkeeping itself. This
    /// supersedes the ADR-IOS-057 `IntentCycle` register (per-id coalescing
    /// at enqueue time) — that coalescing now happens at drain time in
    /// `IntentionFold.fold`/`executeFold`.
    nonisolated func registerGestureIntent(id: String, _ intent: GestureIntent) {
        switch intent {
        case .isRead(let target, _):
            record(ids: [id], kind: .isRead(target), displays: [id: PendingMutation(isRead: target)], origin: .gesture)
        case .isFlagged(let target, _):
            record(ids: [id], kind: .isFlagged(target), displays: [id: PendingMutation(isFlagged: target)], origin: .gesture)
        case .actionTag(let target, let baseline):
            record(ids: [id], kind: .actionTag(target: target, baseline: baseline), displays: [id: PendingMutation(actionTag: .some(target))], origin: .gesture)
        }
    }

    /// Guard for outbox drain (used by AccountManagerOutbox).
    var isDrainingOutbox = false

    /// Guard for calendar operation queue drain (used by AccountManagerCalendarQueue).
    var isDrainingCalendar = false

    // MARK: - Backfill Progress

    /// Per-account backfill progress, keyed by accountId. Empty when no backfill is active.
    /// UI reads this; writes are throttled to avoid excessive SwiftUI re-renders.
    var backfillProgressByAccount: [String: BackfillProgress] = [:] {
        didSet {
            let copy = backfillProgressByAccount
            Task { @MainActor in AccountManagerState.shared.backfillProgressByAccount = copy }
        }
    }

    /// Non-observable backing store — written on every backfill iteration without triggering SwiftUI.
    var _backfillBacking: [String: BackfillProgress] = [:]
    /// Timestamp of last publish to the observable dict.
    private var _lastProgressPublish = Date.distantPast
    /// Minimum interval between observable mutations (seconds).
    private let _progressThrottleInterval: TimeInterval = 1.0

    /// User-requested fast sync mode. Overrides BackfillProfile to .aggressive,
    /// bypasses battery gate, idle-wait, and cellular gate. Not persisted — resets on app restart.
    var fastSyncModeActive = false {
        didSet {
            let val = fastSyncModeActive
            Task { @MainActor in AccountManagerState.shared.fastSyncModeActive = val }
        }
    }

    /// True when ActiveBodyQueue has pending items. Drives sidebar indexing indicator.
    /// Only toggles on empty↔non-empty transitions — no render pings for count changes.
    var isBodyFetchActive = false {
        didSet {
            let val = isBodyFetchActive
            Task { @MainActor in AccountManagerState.shared.isBodyFetchActive = val }
        }
    }

    /// Called by SyncEngine workers to report current backfill state.
    /// Writes to a non-observable backing store on every call; only publishes to the
    /// observable dict every 2 seconds to avoid janking gesture animations.
    func updateBackfillProgress(accountId: String, email: String, headersDone: Bool,
                                isPaused: Bool, totalEmails: Int = 0, ftsIndexed: Int = 0,
                                uidTotal: Int = 0, uidWalked: Int = 0,
                                pendingBodyCount: Int = 0) {
        if var existing = _backfillBacking[accountId] {
            existing.headersDone = headersDone
            existing.isPaused = isPaused
            existing.totalEmails = totalEmails
            existing.ftsIndexed = ftsIndexed
            existing.uidTotal = uidTotal
            existing.uidWalked = uidWalked
            existing.pendingBodyCount = pendingBodyCount
            existing.updateRate()
            _backfillBacking[accountId] = existing
        } else {
            var progress = BackfillProgress(
                accountId: accountId, email: email,
                startedAt: Date(), isPaused: isPaused, headersDone: headersDone,
                totalEmails: totalEmails, ftsIndexed: ftsIndexed
            )
            progress.uidTotal = uidTotal
            progress.uidWalked = uidWalked
            progress.pendingBodyCount = pendingBodyCount
            progress.lastIndexedCount = ftsIndexed
            progress.lastRateUpdate = Date()
            _backfillBacking[accountId] = progress
        }
        // Bypass throttle on completion so UI updates immediately
        let isComplete = _backfillBacking[accountId]?.isFullyComplete == true
        let now = Date()
        guard isComplete || now.timeIntervalSince(_lastProgressPublish) >= _progressThrottleInterval else { return }
        _lastProgressPublish = now
        backfillProgressByAccount = _backfillBacking
    }

    /// Called when backfill fully completes for an account (folders + FTS + snippets all done).
    func clearBackfillProgress(accountId: String) {
        _backfillBacking.removeValue(forKey: accountId)
        backfillProgressByAccount = _backfillBacking // publish immediately on completion
    }

    // MARK: - State Mutation Helpers (for cross-actor callers)

    func markAuthFailed(_ accountId: String) {
        authFailedAccounts.insert(accountId)
    }

    func clearAuthFailed(_ accountId: String) {
        authFailedAccounts.remove(accountId)
    }

    func setFastSyncMode(_ active: Bool) {
        fastSyncModeActive = active
    }

    func markBackfillCapReached(_ accountId: String) {
        backfillCapReachedAccounts.insert(accountId)
    }



    private init() {}

    // MARK: - Provider Management

    func provider(for account: Account) -> (any EmailProvider)? {
        providers[account.id]
    }

    func connectAccount(_ account: Account) async throws {
        // Calendar-only accounts skip email provider creation
        if account.calendarOnly {
            switch account.provider {
            case .gmail:
                calendarProviders[account.id] = await createGoogleCalendarProvider(for: account)
            case .outlook:
                calendarProviders[account.id] = await createExchangeCalendarProvider(for: account)
            case .caldav:
                if let caldavProvider = try await createCalDAVProvider(for: account) {
                    calendarProviders[account.id] = caldavProvider
                }
            default:
                break
            }
            return
        }

        let provider: any EmailProvider

        switch account.provider {
        case .gmail:
            provider = await createGmailProvider(for: account)
            calendarProviders[account.id] = await createGoogleCalendarProvider(for: account)
        case .outlook:
            provider = await createExchangeProvider(for: account)
            calendarProviders[account.id] = await createExchangeCalendarProvider(for: account)
        case .imap:
            provider = try createIMAPProvider(for: account)
            // Check for linked CalDAV config
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                calendarProviders[account.id] = caldavProvider
            }
        case .icloud:
            provider = try createIMAPProvider(for: account)
            // iCloud accounts always check for linked CalDAV
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                calendarProviders[account.id] = caldavProvider
            }
        case .caldav:
            // Pure calendar-only — should have been handled above
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                calendarProviders[account.id] = caldavProvider
            }
            return
        }

        // Boot-timeline tag — provider type + short account-id prefix (NOT the
        // email address: keeps the downloadable boot log free of the full address
        // while still distinguishing parallel per-account connects).
        let acctTag = "\(account.provider):\(account.id.prefix(6))"
        BootProfiler.mark("connectAccount[\(acctTag)]: provider created (token/keychain resolved)")

        // Store provider + work queue BEFORE connecting. This ensures the queue's
        // cooldown logic applies even if the first connection fails (e.g., max_userip_connections).
        // Without this, accounts that can't connect never get a queue, so cooldown never kicks in.
        providers[account.id] = provider
        let concurrency: Int
        switch account.provider {
        case .gmail: concurrency = SyncConfig.gmailWorkQueueConcurrency
        case .outlook: concurrency = SyncConfig.exchangeWorkQueueConcurrency
        case .imap, .icloud: concurrency = SyncConfig.imapMaxConnectionCeiling
        case .caldav: concurrency = SyncConfig.imapMaxConnectionCeiling
        }
        // Create queue if not already present. Queue is removed by disconnectAccount,
        // so this only runs on first connect or after explicit disconnect.
        // Each provider instance has its own pool — queue + pool are 1:1.
        if workQueues[account.id] == nil {
            // All providers use fixed concurrency. For IMAP, the pool's checkout is the
            // real gate — if no connections available, callers wait in the pool's waiter queue.
            // The work queue provides priority scheduling on top.
            let queue = ProviderWorkQueue(provider: provider, maxConcurrency: concurrency)
            workQueues[account.id] = queue
            await syncEngine.register(accountId: account.id, provider: provider, workQueue: queue)
        }

        let connectT0 = CFAbsoluteTimeGetCurrent()
        BootProfiler.mark("connectAccount[\(acctTag)]: provider.connect() START (network — timeout \(Int(SyncConfig.connectTimeoutSeconds))s)")
        do {
            try await withTimeout(seconds: SyncConfig.connectTimeoutSeconds) {
                try await provider.connect()
            }
            authFailedAccounts.remove(account.id)
            BootProfiler.mark("connectAccount[\(acctTag)]: provider.connect() DONE in \(Int((CFAbsoluteTimeGetCurrent() - connectT0) * 1000))ms")
        } catch {
            BootProfiler.mark("connectAccount[\(acctTag)]: provider.connect() FAILED in \(Int((CFAbsoluteTimeGetCurrent() - connectT0) * 1000))ms (auth=\(isAuthError(error)))")
            if isAuthError(error) {
                print("[AccountManager] Auth failed for \(account.emailAddress): \(error)")
                authFailedAccounts.insert(account.id)
            } else {
                print("[AccountManager] Connect failed for \(account.emailAddress) (non-auth): \(error)")
            }
            throw error
        }
    }

    /// Create a CalDAVProvider from stored CalDAVConfig for an account. Returns nil if no config exists.
    func createCalDAVProvider(for account: Account) async throws -> CalDAVProvider? {
        guard let config = try await dbPool.read({ db in
            try CalDAVConfig.filter(Column("accountId") == account.id).fetchOne(db)
        }) else {
            return nil
        }

        if config.needsReauth {
            print("[AccountManager] CalDAV config for \(account.emailAddress) needs re-auth — skipping provider creation")
            return nil
        }

        guard let password = KeychainHelper.loadString(key: "caldav_password_\(config.id)") else {
            print("[AccountManager] No CalDAV password in Keychain for config \(config.id)")
            return nil
        }

        let client = CalDAVClient(username: config.username, password: password)

        // Use cached discovery URLs if available, otherwise run discovery
        let calendarHomeURL: URL
        if let cachedHome = config.calendarHomeURL, let url = URL(string: cachedHome) {
            calendarHomeURL = url
        } else {
            guard let serverURL = URL(string: config.serverURL) else { return nil }
            let discovery = try await CalDAVDiscovery.discover(serverURL: serverURL, client: client)
            // Cache discovery results
            try await dbPool.write { db in
                var updated = config
                updated.principalURL = discovery.principalURL.absoluteString
                updated.calendarHomeURL = discovery.calendarHomeURL.absoluteString
                try updated.save(db)
            }
            calendarHomeURL = discovery.calendarHomeURL
        }

        guard let serverURL = URL(string: config.serverURL) else { return nil }
        return CalDAVProvider(client: client, calendarHomeURL: calendarHomeURL, serverBaseURL: serverURL)
    }

    /// Await completion of all in-flight AI processing (both body fetch and AI queues).
    func awaitAIProcessing() async {
        await ActiveBodyQueue.shared.awaitDrain()
        await ActiveAIQueue.shared.awaitDrain()
    }

    /// Cancel all in-flight AI processing. Called on sign-out / account deletion.
    func cancelAllAIProcessing() {
        // ActiveBodyQueue and ActiveAIQueue are singletons that self-manage —
        // items for deleted accounts will be skipped when provider lookup fails.
    }

    func disconnectAccount(_ account: Account) async {
        // SECURITY: Invalidate OAuth coordinator FIRST — prevents stale closures
        // (captured by old providers) from refreshing tokens after account removal.
        if let coordinator = oauthCoordinators[account.id] {
            await coordinator.invalidate()
        }
        oauthCoordinators.removeValue(forKey: account.id)

        if let provider = providers[account.id] {
            try? await provider.disconnect()
        }
        providers.removeValue(forKey: account.id)
        workQueues.removeValue(forKey: account.id)
        calendarProviders.removeValue(forKey: account.id)
        await syncEngine.remove(accountId: account.id)
        // AI processing is now handled by ActiveBodyQueue + ActiveAIQueue actors
        // Clean up stale backfill progress
        clearBackfillProgress(accountId: account.id)
    }

    /// Reset backfill state for a single account so it re-crawls from scratch.
    func resetBackfill(accountId: String) async {
        await syncEngine.resetBackfill(accountId: accountId)
    }

    /// Mark all providers as dirty. Called on session start (foreground return, BGAppRefresh,
    /// push wakeup, BGProcessingTask). IMAP providers will drain and reseed their connection pool
    /// on the next checkout. HTTP providers (Gmail/Exchange) are no-ops (ephemeral sessions).
    func markAllProvidersDirty() async {
        let snapshot = providers
        for (_, provider) in snapshot {
            await provider.markDirty()
        }
        // DeviceSync WebSocket — same lifecycle as providers.
        // Force reconnect clears stale TCP, creates fresh session.
        await MainActor.run { DeviceSyncService.shared.markDirty() }
        BackgroundSyncLogger.log("[AccountManager] marked \(snapshot.count) providers + DeviceSync dirty")
    }

    // MARK: - Token Access

    /// Return a fresh OAuth access token for the given account, refreshing if needed.
    /// Uses the shared OAuthRefreshCoordinator to deduplicate concurrent refreshes.
    /// Callers outside provider factory (e.g. PushNotificationService) should use this
    /// instead of reading raw Keychain tokens that may be expired.
    func freshAccessToken(for account: Account) async throws -> String {
        let coordinator = oauthCoordinator(for: account.id)
        let oauthService = await self.oauthService

        let refresher: @Sendable (_ refreshToken: String) async throws -> OAuthTokens
        switch account.provider {
        case .gmail:
            refresher = { refreshToken in
                try await oauthService.refreshGoogleToken(refreshToken: refreshToken)
            }
        case .outlook:
            refresher = { refreshToken in
                try await oauthService.refreshMicrosoftToken(refreshToken: refreshToken)
            }
        default:
            throw ProviderError.authenticationFailed
        }

        return try await coordinator.refresh(accountId: account.id, email: account.emailAddress, using: refresher)
    }

    // MARK: - Provider Factory

    /// Build a `@Sendable` access token closure that uses the shared OAuthRefreshCoordinator
    /// for this account. Mail + calendar providers for the same account share one coordinator,
    /// preventing concurrent refresh token rotation races.
    private func makeOAuthAccessor(
        accountId: String,
        email: String,
        refresher: @escaping @Sendable (_ refreshToken: String) async throws -> OAuthTokens
    ) -> @Sendable (_ forceRefresh: Bool) async throws -> String {
        let coordinator = oauthCoordinator(for: accountId)
        return { @Sendable forceRefresh in
            if !forceRefresh,
               let token = KeychainHelper.loadString(key: KeychainHelper.accessTokenKey(accountId: accountId)) {
                return token
            }
            return try await coordinator.refresh(accountId: accountId, email: email, using: refresher)
        }
    }

    private func createGmailProvider(for account: Account) async -> GmailProvider {
        let oauthService = await self.oauthService
        let accessor = makeOAuthAccessor(accountId: account.id, email: account.emailAddress) { refreshToken in
            try await oauthService.refreshGoogleToken(refreshToken: refreshToken)
        }
        return GmailProvider(userEmail: account.emailAddress, accessToken: accessor)
    }

    private func createGoogleCalendarProvider(for account: Account) async -> GoogleCalendarProvider {
        let oauthService = await self.oauthService
        let accessor = makeOAuthAccessor(accountId: account.id, email: account.emailAddress) { refreshToken in
            try await oauthService.refreshGoogleToken(refreshToken: refreshToken)
        }
        return GoogleCalendarProvider(accessToken: accessor)
    }

    private func createExchangeProvider(for account: Account) async -> ExchangeProvider {
        let oauthService = await self.oauthService
        let accessor = makeOAuthAccessor(accountId: account.id, email: account.emailAddress) { refreshToken in
            try await oauthService.refreshMicrosoftToken(refreshToken: refreshToken)
        }
        return ExchangeProvider(userEmail: account.emailAddress, accessToken: accessor)
    }

    private func createExchangeCalendarProvider(for account: Account) async -> ExchangeCalendarProvider {
        let oauthService = await self.oauthService
        let accessor = makeOAuthAccessor(accountId: account.id, email: account.emailAddress) { refreshToken in
            try await oauthService.refreshMicrosoftToken(refreshToken: refreshToken)
        }
        return ExchangeCalendarProvider(accessToken: accessor)
    }

    func createIMAPProvider(for account: Account, passwordOverride: String? = nil) throws -> IMAPProvider {
        guard let host = account.imapHost else {
            throw ProviderError.authenticationFailed
        }
        let password = passwordOverride ?? KeychainHelper.loadString(key: KeychainHelper.passwordKey(accountId: account.id))
        guard let password else {
            throw ProviderError.authenticationFailed
        }

        return IMAPProvider(
            host: host,
            port: account.imapPort ?? 993,
            username: account.imapUsername ?? account.emailAddress,
            password: password,
            senderEmail: account.emailAddress,
            smtpHost: account.smtpHost ?? host.replacingOccurrences(of: "imap", with: "smtp"),
            smtpPort: account.smtpPort ?? 587
        )
    }
}
