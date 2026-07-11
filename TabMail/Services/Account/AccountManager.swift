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

actor AccountManager {
    static let shared = AccountManager()

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

    /// Guard for pending queue drain (used by AccountManagerQueue).
    var isDraining = false
    /// Set when drainPendingQueue() is called while isDraining — triggers re-drain on completion.
    var needsRedrain = false

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
        let expiresAt = Date().addingTimeInterval(ttl)
        for id in messageIds { recentlyCompleted[id] = expiresAt }
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
    struct PendingMutation: Sendable {
        var isRead: Bool?
        var folderId: String?
        var folderPath: String?
        var isInInbox: Bool?
        var isFlagged: Bool?
        var actionTag: ActionTag??  // nil = no change, .some(nil) = clear tag
    }

    let optimisticOverlay = Mutex<[String: PendingMutation]>([:])

    /// Register an optimistic mutation. Callable synchronously from any isolation domain.
    nonisolated func registerMutation(id: String, mutation: PendingMutation) {
        optimisticOverlay.withLock { overlay in
            var existing = overlay[id] ?? PendingMutation()
            if let v = mutation.isRead { existing.isRead = v }
            if let v = mutation.folderId { existing.folderId = v }
            if let v = mutation.folderPath { existing.folderPath = v }
            if let v = mutation.isInInbox { existing.isInInbox = v }
            if let v = mutation.isFlagged { existing.isFlagged = v }
            if let v = mutation.actionTag { existing.actionTag = v }
            overlay[id] = existing
        }
    }

    /// Remove overlay entries after their DB writes commit.
    nonisolated func removeOverlayEntries(ids: [String]) {
        optimisticOverlay.withLock { overlay in
            for id in ids { overlay.removeValue(forKey: id) }
        }
    }

    /// Snapshot the overlay for use in reloadMessages (snapshot BEFORE DB read).
    nonisolated func snapshotOverlay() -> [String: PendingMutation] {
        optimisticOverlay.withLock { $0 }
    }

    /// Refcounts in-flight gesture ops per message id, so overlay removal can
    /// be tied to the LAST op still touching an id rather than to ANY single
    /// op's completion. `optimisticOverlay` is COALESCED — one `PendingMutation`
    /// per id holding the latest registered intent — so when N ops for the
    /// same id are queued FIFO (e.g. alternating `toggleRead` calls queued
    /// faster than the write lane drains), the FIRST op to complete calling
    /// `removeOverlayEntries` strips the overlay while ops #2..N are still in
    /// flight, exposing intermediate DB truth to `reloadMessages` until the
    /// LAST op lands (log-confirmed 2026-07-10, logmain.log line 1743: a
    /// 10-op drain of alternating markUnread/markRead produced visible
    /// flip-backs mid-drain). Same bug class as
    /// `MessageDetailViewModel.localMovePins` (ADR-IOS-049 amendment, round
    /// 8): "overlay-presence is the wrong proxy for in-flight-ness — a
    /// sibling op's drain ends the window early." That precedent also
    /// motivates the refcount (round 10) over a Set: overlapping ops on the
    /// same id (e.g. toggleRead + toggleFlag queued together) must each
    /// retain/release independently.
    ///
    /// Gesture paths (`InboxViewModel.toggleRead`/`markRead`/`toggleFlag`,
    /// `registerGestureIntent` below) call `retainOverlayEntry` at gesture
    /// time (same call site as `registerMutation`) and `releaseOverlayEntry`
    /// at the end of their queued closure, on every exit path, in place of a
    /// direct `removeOverlayEntries` call. The audit promised above ("pending
    /// their own audit") is DONE: every remaining production call site — the
    /// move family (archive/delete/move, single + thread, both
    /// `InboxViewModel` and `MessageDetailViewModel`), `UndoService.undo()`,
    /// and the inbox/detail `applyManualTag` gesture paths (now routed
    /// through `registerGestureIntent`'s single-retain-per-cycle protocol) —
    /// is converted to retain/release. `removeOverlayEntries` itself is now
    /// called from exactly one production call site: `releaseOverlayEntry`'s
    /// zero-refcount branch below. (Moves also keep an independent
    /// refcounted pin lifecycle via `MessageDetailViewModel.localMovePins`
    /// for the detail view's bubble-snapback window — a separate concern
    /// from this overlay refcount.)
    private let overlayOpRefCount = Mutex<[String: Int]>([:])

    /// Mark one more in-flight gesture op for `id`. Call synchronously at
    /// gesture time, alongside `registerMutation`.
    nonisolated func retainOverlayEntry(id: String) {
        overlayOpRefCount.withLock { counts in
            counts[id, default: 0] += 1
        }
    }

    /// Release one in-flight gesture op for `id`. When the refcount reaches
    /// zero — or `id` was never retained (defensive; the count never goes
    /// negative) — removes `id` from the refcount map AND from the overlay
    /// itself. Call exactly once per `retainOverlayEntry` call, on every exit
    /// path of the owning queued closure.
    nonisolated func releaseOverlayEntry(id: String) {
        let shouldRemoveOverlay = overlayOpRefCount.withLock { counts -> Bool in
            guard let count = counts[id] else {
                // Defensive: unmatched release (no retain on record). Treat as
                // the terminal release so the overlay never strands, but this
                // indicates a retain/release imbalance at a call site.
                BackgroundSyncLogger.logInbox("[AccountManager] releaseOverlayEntry — unmatched release for \(id), no retain on record")
                return true
            }
            if count <= 1 {
                counts.removeValue(forKey: id)
                return true
            }
            counts[id] = count - 1
            return false
        }
        guard shouldRemoveOverlay else { return }
        removeOverlayEntries(ids: [id])
    }

    /// Test seam: snapshot the retain/release refcount map (hygiene checks —
    /// asserting it drains back to empty). Mirrors `NSEDataBridge`'s
    /// `…ForTesting()` convention.
    nonisolated func overlayOpRefCountForTesting() -> [String: Int] {
        overlayOpRefCount.withLock { $0 }
    }

    // MARK: - Latest-Intent Coalescing (ADR-IOS-057)

    /// One in-flight coalesced gesture cycle per message id. Folds repeated
    /// gesture intents registered for the same id (rapid `toggleRead`/
    /// `toggleFlag`/`applyManualTag` taps queued faster than the FIFO write
    /// queue drains) into a SINGLE queued write that executes the NET,
    /// per-field intent — see `registerGestureIntent`/`executeIntentCycle`.
    /// `isReadBaseline`/`isFlaggedBaseline`/`actionTagBaseline` capture the
    /// visualized state the FIRST touch of that field saw this cycle. The
    /// executor's skip decision compares each net target against the
    /// RESOLVED HEADER's current truth, not these baselines (round-3 audit —
    /// see `executeIntentCycle`): for an undisturbed cycle the two are
    /// identical, so a perfect cancel-out still performs zero writes, zero
    /// `PendingOperation`s, zero unread/badge churn. The stored baselines
    /// remain the gesture-time record: `actionTagBaseline` feeds
    /// `applyManualTag`'s previousTag/auto-teach signal, and all three are
    /// groundwork for phase-2 move coalescing
    /// (`PLAN_OVERLAY_CALLSITE_AUDIT.md` §5).
    struct IntentCycle: Sendable {
        var isReadTarget: Bool?      // latest registered target
        var isReadBaseline: Bool?    // visualized state when the field FIRST joined this cycle
        var isFlaggedTarget: Bool?
        var isFlaggedBaseline: Bool?
        var actionTagTarget: ActionTag??    // .some(x) = touched; latest target (x may be nil = clear)
        var actionTagBaseline: ActionTag??  // .some(x) = touched; baseline at first touch
        /// Bumped on EVERY `registerGestureIntent` touch (create or join).
        /// Lets the executor detect intents that joined during a nil header
        /// resolve and grant them the fresh resolve attempt they would have
        /// gotten as their own cycle pre-coalescing — see `executeIntentCycle`'s
        /// retry loop (round-2 audit).
        var generation: Int = 0
    }
    private let pendingIntentCycles = Mutex<[String: IntentCycle]>([:])

    /// A single-field gesture intent registered against an id's open
    /// `IntentCycle`. See `registerGestureIntent`.
    enum GestureIntent: Sendable {
        case isRead(target: Bool, baseline: Bool)
        case isFlagged(target: Bool, baseline: Bool)
        case actionTag(target: ActionTag?, baseline: ActionTag?)
    }

    /// Register a gesture intent for `id` (ADR-IOS-057). Updates the display
    /// overlay (`registerMutation`) synchronously — on-screen state always
    /// reflects the latest intent immediately, unchanged display semantics —
    /// then folds the intent into `id`'s open `IntentCycle` (creating one if
    /// none is in flight). Only when a NEW cycle is created does this take
    /// ONE overlay retain and enqueue ONE executor closure on the FIFO write
    /// queue; later gestures on the same id while a cycle is still queued
    /// only update the register + overlay — no new closure, no new write, no
    /// new `PendingOperation`. Callable synchronously from the MainActor
    /// gesture paths that used to call `retainOverlayEntry` + `registerMutation`
    /// + `enqueueWrite` directly.
    nonisolated func registerGestureIntent(id: String, _ intent: GestureIntent) {
        var mutation = PendingMutation()
        let isNewCycle = pendingIntentCycles.withLock { cycles -> Bool in
            let isNew = cycles[id] == nil
            var cycle = cycles[id] ?? IntentCycle()
            switch intent {
            case .isRead(let target, let baseline):
                if cycle.isReadBaseline == nil { cycle.isReadBaseline = baseline }
                cycle.isReadTarget = target
                mutation.isRead = target
            case .isFlagged(let target, let baseline):
                if cycle.isFlaggedBaseline == nil { cycle.isFlaggedBaseline = baseline }
                cycle.isFlaggedTarget = target
                mutation.isFlagged = target
            case .actionTag(let target, let baseline):
                if cycle.actionTagBaseline == nil { cycle.actionTagBaseline = .some(baseline) }
                cycle.actionTagTarget = .some(target)
                mutation.actionTag = .some(target)
            }
            cycle.generation += 1
            cycles[id] = cycle
            return isNew
        }
        // Retain BEFORE registering (new cycle only — an existing cycle
        // already holds its retain): the overlay entry must not be removable
        // by a sibling op's final release in the instant between
        // `registerMutation` landing the intent and this cycle's retain
        // taking effect. Same invariant the pre-register gesture paths
        // documented at their retain call sites.
        if isNewCycle { retainOverlayEntry(id: id) }
        registerMutation(id: id, mutation: mutation)
        guard isNewCycle else { return }
        Task { await self.enqueueWrite { await self.executeIntentCycle(id: id) } }
    }

    /// Executes the NET per-field intent accumulated in `id`'s coalesced
    /// gesture cycle and releases the cycle's single overlay retain.
    ///
    /// Resolves the header BEFORE consuming the cycle (ADR-IOS-057 round-1
    /// audit): `resolveHeaderForAction` is a `dbPool.read` that can take
    /// seconds under writer starvation. A gesture landing during that read
    /// still finds the cycle open and JOINS it (folded into this executor's
    /// net write) instead of finding no cycle and opening a second one — the
    /// split-cycle window that would otherwise let a possible cancel-out slip
    /// through as two writes. The cycle is consumed (`removeValue`) only
    /// after the read, on EVERY exit path — a gesture registered after that
    /// point starts a fresh cycle with its own retain + closure, executing
    /// strictly later, behind this one. The residual split window is now
    /// only the write section below: a tap landing there genuinely postdates
    /// this in-flight write and its own write is semantically necessary (see
    /// ADR-IOS-057 Consequences — accepted residual).
    ///
    /// Nil-resolve retry (round-2 audit): when the header resolves to nil,
    /// intents that JOINED the cycle during the resolve must not be consumed
    /// and dropped on the strength of a read that predates them — as their
    /// own cycle (pre-coalescing) they would have gotten a fresh
    /// `resolveHeaderForAction` call of their own, and the row can become
    /// resolvable in the interim (e.g. an NSE merge lands). The loop grants
    /// exactly that: re-resolve while the cycle's `generation` moved during
    /// the failed resolve. Each retry requires a NEW gesture to have landed
    /// mid-resolve, so the loop is bounded by the user's actual tap stream —
    /// identical to the pre-coalescing cost of one resolve per gesture.
    func executeIntentCycle(id: String) async {
        var header: MessageHeader?
        var cycle: IntentCycle?
        while true {
            let generationBeforeResolve = pendingIntentCycles.withLock { $0[id]?.generation }
            header = await resolveHeaderForAction(id: id)
            if header != nil {
                // Successful resolve: consume unconditionally. Intents that
                // joined at any point up to this consume are folded into this
                // executor's net write (their baselines are first-touch, so
                // the math stays exact).
                cycle = pendingIntentCycles.withLock { $0.removeValue(forKey: id) }
                break
            }
            // Nil resolve: the generation-stability check and the consume
            // MUST be one atomic lock section (round-3 audit) — with two
            // separate acquisitions, a gesture joining in the instant
            // between "generation unchanged" and `removeValue` would be
            // consumed by a verdict that predates it and silently dropped.
            let (done, consumed) = pendingIntentCycles.withLock { cycles -> (Bool, IntentCycle?) in
                guard let current = cycles[id] else { return (true, nil) }
                guard current.generation == generationBeforeResolve else { return (false, nil) }
                return (true, cycles.removeValue(forKey: id))
            }
            if done {
                cycle = consumed
                break
            }
            BackgroundSyncLogger.logInbox("[AccountManager] executeIntentCycle — nil resolve for \(id) but the cycle changed mid-resolve, retrying resolution")
        }
        guard let cycle else {
            // Defensive: executor ran with no cycle on record (should not
            // happen — registerGestureIntent always creates a cycle before
            // enqueueing). Release so the overlay never strands.
            BackgroundSyncLogger.logInbox("[AccountManager] executeIntentCycle — no cycle on record for \(id)")
            releaseOverlayEntry(id: id)
            return
        }
        guard let header else {
            // Row vanished between gesture and drain (e.g. deleted by an
            // earlier queued op) — no-op, but release THIS cycle's retain so
            // the overlay doesn't strand (mirrors toggleRead's vanished-row
            // branch).
            BackgroundSyncLogger.logInbox("[AccountManager] executeIntentCycle — header resolution failed for \(id), releasing overlay retain")
            releaseOverlayEntry(id: id)
            return
        }
        // Skip condition (round-3 audit): each field compares its net target
        // against the RESOLVED HEADER's current truth, not the cycle's
        // gesture-time baseline. For an undisturbed cycle the two are
        // identical (a pure cancel-out stays a zero-write no-op). They
        // diverge when an out-of-band writer touched the row mid-cycle —
        // `markAllAsRead` (a LOCAL user action that bypasses the register,
        // FIFO-ordered before this executor) or a remote sync flip. In both
        // cases the cycle's net intent is the user's LATEST visualized
        // state, so it must be asserted ("the user's next action always
        // takes priority over stale server state" — core philosophy §4), and
        // skipping instead would flip the row back the moment the overlay
        // releases — the exact symptom class this register exists to kill.
        // Bonus: a write the DB already reflects is skipped as redundant
        // (no PendingOperation, no remote round-trip).
        var wroteAnything = false
        if let target = cycle.isReadTarget, target != header.isRead {
            if target { await markRead([header]) } else { await markUnread([header]) }
            wroteAnything = true
        }
        if let target = cycle.isFlaggedTarget, target != header.isFlagged {
            await markFlagged([header], flagged: target)
            wroteAnything = true
        }
        if case let .some(target) = cycle.actionTagTarget {
            if target != header.actionTag {
                // previousTag semantics: `applyManualTag` reads
                // `message.actionTag` as the "before" value for the LLM
                // auto-teach signal (originalAction). Feed it the
                // gesture-time visualized baseline, not drain-time DB
                // truth — a concurrent AI auto-tag landing in the
                // gesture→drain gap must not masquerade as the tag the user
                // overrode.
                var tagHeader = header
                tagHeader.actionTag = cycle.actionTagBaseline ?? nil  // outer .some guaranteed when touched
                await applyManualTag(tagHeader, tag: target)
                wroteAnything = true
            }
        }
        // Cancel-out (every touched field's target already matches the row):
        // nothing ran above — no local write, no unreadCount churn, no badge
        // recount, no PendingOperation, no remote flip.
        if !wroteAnything {
            BackgroundSyncLogger.logInbox("[AccountManager] executeIntentCycle — cancel-out no-op for \(id)")
        }
        releaseOverlayEntry(id: id)
    }

    /// Test seam: snapshot the intent-cycle register (hygiene checks —
    /// asserting it drains back to empty once every cycle has executed).
    /// Mirrors `overlayOpRefCountForTesting()`.
    nonisolated func pendingIntentCyclesForTesting() -> [String: IntentCycle] {
        pendingIntentCycles.withLock { $0 }
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
