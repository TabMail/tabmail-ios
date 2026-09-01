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

    /// Bodies retired from automatic indexing with a truthful terminal reason.
    /// These rows are not indexed and are not counted as pending work.
    var unindexedBodyCount: Int = 0

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
        if isFullyComplete { return 1.0 }
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
    /// is local and self-terminating (empty/404 bodies confirm-empty; deterministic
    /// protocol failures enter the separate terminal-unindexed state),
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

enum BodyIndexingProgressText {
    static func completion(unindexedCount: Int) -> String {
        guard unindexedCount > 0 else { return "Sync complete" }
        let noun = unindexedCount == 1 ? "message" : "messages"
        return "Sync complete with \(unindexedCount.formatted()) \(noun) not indexed"
    }

    /// Shared presentation decision for aggregate and per-account sync views.
    /// Returning nil keeps in-progress/index-count branches separate while
    /// ensuring every completed-with-omissions surface uses the exact wording.
    static func terminalCompletion(isComplete: Bool, unindexedCount: Int) -> String? {
        guard isComplete, unindexedCount > 0 else { return nil }
        return completion(unindexedCount: unindexedCount)
    }
}

/// Deduplicates concurrent OAuth refresh calls for a single account.
/// Prevents race where mail + calendar providers both get 401 and refresh the same token.
/// Microsoft rotates refresh tokens on use — second caller with the old token would fail.
actor OAuthRefreshCoordinator {
    private var inFlightTask: (id: UUID, task: Task<OAuthTokens, any Error>)?
    /// Once invalidated, all future refresh attempts immediately fail.
    /// Prevents stale closures from refreshing tokens after account removal.
    private var invalidated = false

    init(invalidated: Bool = false) {
        self.invalidated = invalidated
    }

    /// Mark this coordinator as invalidated. Cancels any in-flight refresh.
    func invalidate() {
        invalidated = true
        inFlightTask?.task.cancel()
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

        let taskId: UUID
        let task: Task<OAuthTokens, any Error>
        if let existing = inFlightTask {
            print("[OAuth] Awaiting in-flight refresh for \(email)...")
            taskId = existing.id
            task = existing.task
        } else {
            taskId = UUID()
            task = Task<OAuthTokens, any Error> {
                guard let refreshToken = KeychainHelper.loadString(key: KeychainHelper.refreshTokenKey(accountId: accountId)) else {
                    print("[OAuth] Auth failed for \(email): refresh token missing from keychain")
                    throw ProviderError.authenticationFailed
                }
                print("[OAuth] Refreshing access token for \(email)...")
                return try await refresher(refreshToken)
            }
            inFlightTask = (taskId, task)
        }

        do {
            let tokens = try await task.value
            if inFlightTask?.id == taskId { inFlightTask = nil }

            // `invalidate()` can run while the network refresh is suspended.
            // Persist only after returning to this actor and re-checking the
            // terminal bit; no await exists between this guard and the writes.
            guard !invalidated else {
                print("[OAuth] Discarding refreshed token for \(email): account removed")
                throw ProviderError.authenticationFailed
            }
            try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: accountId))
            if let newRefresh = tokens.refreshToken {
                try KeychainHelper.save(newRefresh, for: KeychainHelper.refreshTokenKey(accountId: accountId))
            }
            return tokens.accessToken
        } catch {
            if inFlightTask?.id == taskId { inFlightTask = nil }
            throw error
        }
    }
}

actor AccountManager {
    static let shared = AccountManager()

    var providers: [String: any EmailProvider] = [:]
    var workQueues: [String: ProviderWorkQueue] = [:]
    var calendarProviders: [String: any CalendarProvider] = [:]

    /// PORT adaptation of v2final AccountManagerQueue's concrete registered-
    /// provider switch. Persisted Account.provider is never mutation authority.
    nonisolated static func draftRuntimeIdentityKind(
        for provider: any EmailProvider
    ) -> DraftRuntimeIdentityKind {
        switch provider {
        case is GmailProvider: .gmail
        case is ExchangeProvider: .outlook
        case is IMAPProvider: .imap
        case is DemoProvider: .demo
        default: .unknown
        }
    }

    func draftRuntimeIdentityKind(accountId: String) -> DraftRuntimeIdentityKind? {
        providers[accountId].map(Self.draftRuntimeIdentityKind(for:))
    }
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
    /// Process-local terminal fence for rows that committed absent. It is
    /// synchronous because OAuth accessors captured by providers outlive their
    /// AccountManager dictionary entry and must consult it without an actor hop.
    private nonisolated let removedAccountRuntimeFence = Mutex<Set<String>>([])

    nonisolated func isRuntimeRemoved(_ accountId: String) -> Bool {
        removedAccountRuntimeFence.withLock { $0.contains(accountId) }
    }

    private func oauthCoordinator(for accountId: String) -> OAuthRefreshCoordinator {
        guard !isRuntimeRemoved(accountId) else {
            return OAuthRefreshCoordinator(invalidated: true)
        }
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

    // MARK: - UIDVALIDITY reset reaction — trigger channel + single-flight (T4.S6)

    /// The purge-and-resync reaction is wired into this closure. `Mutex`-backed
    /// nonisolated seam (Resilience Rule 5): several detection sites are SYNCHRONOUS
    /// GRDB write closures, which cannot `await`, so firing must not require one.
    /// Test-injectable via `setUidValidityChangeHandlerForTesting`.
    ///
    /// PORTED from `v2final:TabMail/Services/Account/AccountManager.swift`
    /// (`uidValidityChangeHandlerBox`). Its companion there,
    /// `uidValidityLedgerBox` / `recordObservedUidValidity`, does NOT transfer:
    /// that mirror exists so a SELECT-time compare can read the stored epoch
    /// without awaiting a DB read, and every v3 detection site already holds a
    /// `Database` (or a freshly-read `Folder`) and reads `lastKnownUidValidity`
    /// directly. A second, eventually-consistent copy of a value we already have
    /// in hand would only add a way to disagree with it.
    private nonisolated let uidValidityChangeHandlerBox = Mutex<
        @Sendable (_ accountId: String, _ folderPath: String, _ storedValue: UInt32, _ observedValue: UInt32) -> Void
    >(AccountManager.defaultUidValidityChangeHandler)

    /// The real entry point: spawns `runUidValidityResetReaction` on an unstructured
    /// Task (this closure is `nonisolated`/synchronous — it can be invoked from
    /// inside a GRDB write closure, which cannot `await`).
    private static func defaultUidValidityChangeHandler(
        accountId: String, folderPath: String, storedValue: UInt32, observedValue: UInt32
    ) {
        if DebugModeManager.isLoggingEnabled() {
            print("[UIDValidity] CHANGED accountId=\(accountId.prefix(8)) folder=\(folderPath) stored=\(storedValue) observed=\(observedValue) — triggering reset reaction")
        }
        Task {
            await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: folderPath)
        }
    }

    /// Test seam: override the change-reaction closure. Callers restore in `defer`
    /// via `resetUidValidityChangeHandlerForTesting()`.
    nonisolated func setUidValidityChangeHandlerForTesting(
        _ handler: @escaping @Sendable (
            _ accountId: String, _ folderPath: String, _ storedValue: UInt32, _ observedValue: UInt32
        ) -> Void
    ) {
        uidValidityChangeHandlerBox.withLock { $0 = handler }
    }

    /// Restore the production handler (keeps the default `private`).
    nonisolated func resetUidValidityChangeHandlerForTesting() {
        uidValidityChangeHandlerBox.withLock { $0 = AccountManager.defaultUidValidityChangeHandler }
    }

    /// Fire the change-reaction closure. Callable from a synchronous context (a GRDB
    /// write closure) without `await`.
    nonisolated func fireUidValidityChangeHandler(
        accountId: String, folderPath: String, storedValue: UInt32, observedValue: UInt32
    ) {
        uidValidityChangeHandlerBox.withLock { $0 }(accountId, folderPath, storedValue, observedValue)
    }

    /// In-flight set for `runUidValidityResetReaction`, keyed by
    /// `MessageIdentity.folderId(accountId:folderPath:)`. A plain actor-isolated
    /// `Set` (not `Mutex`-boxed) is correct and load-bearing: the membership check
    /// and the insert happen synchronously inside this actor's isolation with no
    /// `await` between them, so reentrancy cannot race the check-and-insert. The
    /// durable `Folder.uidValidityResetPendingAt` flag is RE-DRIVE state, not
    /// admission arbitration — THIS set is the admission gate.
    var uidValidityReactionInFlight: Set<String> = []

    /// A trigger that arrived WHILE its folder's reaction was already running is
    /// recorded here instead of dropped, and consumed at release (which re-spawns a
    /// fresh attempt whose own trigger validation decides whether anything is still
    /// warranted).
    var uidValidityReactionRecheckRequested: Set<String> = []

    /// Test seam: simulate "a reaction for this folder is already running".
    func seedUidValidityReactionInFlightForTesting(folderId: String) {
        uidValidityReactionInFlight.insert(folderId)
    }

    /// Test seam: read side of `uidValidityReactionInFlight`.
    func isUidValidityReactionInFlightForTesting(folderId: String) -> Bool {
        uidValidityReactionInFlight.contains(folderId)
    }

    /// Test seam: clear a single-flight entry (teardown).
    func clearUidValidityReactionInFlightForTesting(folderId: String) {
        uidValidityReactionInFlight.remove(folderId)
    }

    /// Test seam: read side of `uidValidityReactionRecheckRequested`.
    func isUidValidityReactionRecheckRequestedForTesting(folderId: String) -> Bool {
        uidValidityReactionRecheckRequested.contains(folderId)
    }

    /// Test seam: clear a recheck-requested entry (teardown).
    func clearUidValidityReactionRecheckRequestedForTesting(folderId: String) {
        uidValidityReactionRecheckRequested.remove(folderId)
    }

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
    /// (`overlayOpRefCountForTesting`).
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

    /// Test seam: the calendar sibling of `registerProviderForTesting`, so the
    /// calendar tools and `drainCalendarQueue` can be exercised against a
    /// `MockCalendarProvider` without a network account. Same replace-on-call
    /// semantics as `registerDemoProviders`. Deliberately an EXPLICIT
    /// registration rather than a nil-defaulted injection point: a seam that
    /// silently falls back to the real provider lookup fails DANGEROUS.
    func registerCalendarProviderForTesting(accountId: String, provider: any CalendarProvider) {
        calendarProviders[accountId] = provider
    }

    /// Test seam: undo `registerCalendarProviderForTesting`.
    func unregisterCalendarProviderForTesting(accountId: String) {
        calendarProviders.removeValue(forKey: accountId)
    }

    /// Guard for pending queue drain (used by AccountManagerQueue).
    var isDraining = false
    /// Set when drainPendingQueue() is called while isDraining — triggers re-drain on completion.
    var needsRedrain = false

    /// An in-flight IMAP MOVE cannot name its opposite until COPYUID returns
    /// the destination UID. Keep that short-lived opposite in memory; if the
    /// process dies, sync simply exposes the completed forward move.
    struct DeferredMoveSuccessor: Sendable, Equatable {
        let predecessorOperationId: String
        let predecessorDestinationPath: String
        let oldHeaderId: String
        var desiredDestinationPath: String
    }

    /// Old source-address header id -> latest successor.
    var deferredMoveSuccessors: [String: DeferredMoveSuccessor] = [:]

    // MARK: - FIFO Local Write Queue

    /// Serial queue for ALL local DB writes from user actions.
    /// Ensures writes commit in the same order the user performed them,
    /// eliminating races between concurrent Tasks (e.g., markRead + move).
    private var writeQueue: [@Sendable () async -> Void] = []
    private var isDrainingLocalWrites = false

    /// Synchronous admission ledger for callers that cannot `await` the actor
    /// hop into `enqueueWrite`. The token exists before their unstructured
    /// `Task` is spawned and is retired only after that task has appended its
    /// closure to the actor-owned FIFO. `awaitWriteQueueDrain` snapshots this
    /// ledger so its barrier cannot overtake a pre-existing enqueue hop.
    private struct WriteAdmissions: Sendable {
        var nextToken: UInt64 = 0
        var notYetEnqueued: Set<UInt64> = []
    }
    private let writeAdmissions = Mutex(WriteAdmissions())

    /// Enqueue a local DB write. Executes FIFO. Never blocks caller.
    func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        writeQueue.append(work)
        if !isDrainingLocalWrites {
            isDrainingLocalWrites = true
            Task { await drainLocalWrites() }
        }
    }

    /// Admit a FIFO write from a synchronous caller. Unlike an open-coded
    /// `Task { await enqueueWrite(...) }`, this publishes a token before the
    /// actor hop, allowing the production durability barrier and deterministic
    /// tests to wait for work that was requested but not appended yet.
    nonisolated func enqueueWriteFromSynchronousContext(
        _ work: @escaping @Sendable () async -> Void
    ) {
        let token = writeAdmissions.withLock { admissions -> UInt64 in
            admissions.nextToken &+= 1
            let token = admissions.nextToken
            admissions.notYetEnqueued.insert(token)
            return token
        }
        Task {
            await self.enqueueWrite(work)
            _ = writeAdmissions.withLock { admissions in
                admissions.notYetEnqueued.remove(token)
            }
        }
    }

    private func drainLocalWrites() async {
        while !writeQueue.isEmpty {
            let work = writeQueue.removeFirst()
            await work()
        }
        isDrainingLocalWrites = false
    }

    /// User-action quiescence barrier — returns once every closure enqueued
    /// before this call has run, including a gesture intent registered before
    /// the call whose unstructured enqueue hop has not reached this actor yet.
    ///
    /// Each pass appends a continuation-resuming closure to the back of
    /// `writeQueue`; because the queue is strictly FIFO, every write already
    /// enqueued is guaranteed to have drained when that continuation resumes.
    /// Synchronous callers use `enqueueWriteFromSynchronousContext`, which
    /// publishes an admission token before its unstructured actor hop. This
    /// method snapshots the highest token that existed at entry, waits until
    /// every such token has reached the FIFO, then appends one final barrier
    /// behind those closures. Later admissions are outside this call's
    /// contract. This is a condition wait, not a timing retry: no sleep or
    /// widened deadline is involved.
    /// `AccountManager` is an actor and `enqueueWrite` is a same-actor call,
    /// so no `Task` hop is needed here (contrast the test-only mirror of this
    /// pattern, which hops via `Task` because it's called from `@MainActor`
    /// test code). Used by `AppDelegate`'s background durability checkpoint
    /// to flush queued writes (including ADR-IOS-057 intent-cycle executors)
    /// before the WAL fsync.
    func awaitWriteQueueDrain() async {
        let admissionCeiling = writeAdmissions.withLock { $0.nextToken }
        while writeAdmissions.withLock({ admissions in
            admissions.notYetEnqueued.contains { $0 <= admissionCeiling }
        }) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enqueueWrite { cont.resume() }
            }
        }
        // A targeted admission may have reached the FIFO immediately after
        // the preceding barrier and immediately before the ledger check. This
        // final pass is therefore mandatory even when the loop ran.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enqueueWrite { cont.resume() }
        }
    }

    /// Append work after every synchronous admission that already existed at
    /// entry, but do not wait for any queued closure to execute. Undo uses this
    /// to preserve gesture order while returning immediately behind a gated or
    /// slow forward move.
    func enqueueWriteAfterPriorAdmissions(
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let admissionCeiling = writeAdmissions.withLock { $0.nextToken }
        while writeAdmissions.withLock({ admissions in
            admissions.notYetEnqueued.contains { $0 <= admissionCeiling }
        }) {
            await Task.yield()
        }
        enqueueWrite(work)
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
                await AccountManager.shared.awaitWriteQueueDrain()
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

    /// Test seam: drop every protection entry, expired or not.
    ///
    /// `recentlyCompleted` is process-global and keyed by a BARE message id,
    /// which on IMAP is a per-folder UID — so a "1"/"2"/"3" recorded by one test
    /// protects the "1"/"2"/"3" of an unrelated test's folder for the whole
    /// 30 s TTL, and a stale sweep that must delete them silently keeps them
    /// (`IOS-TEST-006`). Production keeps the unscoped key deliberately: the
    /// map's OTHER leg is the RFC 822 Message-ID, which is folder-agnostic by
    /// construction and is what protects an optimistically-moved row at its
    /// destination, and every consumer uses the map only to SKIP a delete or an
    /// overwrite — so an over-broad match costs at most one sync pass and never
    /// removes protection. Scoping the key would narrow it, which is the
    /// dangerous direction. The leak is therefore closed in the test harness:
    /// `ProcessGlobalTestState.withLock` calls this on entry to every scoped
    /// test, which is the only boundary that composes across suites
    /// (`.serialized` does not).
    ///
    /// Mirrors the `…ForTesting()` convention
    /// (`clearUidValidityReactionInFlightForTesting`).
    func clearRecentlyCompletedForTesting() {
        recentlyCompleted.removeAll()
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
        let locationTrace = optimisticOverlay.withLock { overlay -> String? in
            let before = overlay[id]
            var existing = overlay[id] ?? PendingMutation()
            if let v = mutation.isRead { existing.isRead = v }
            if let v = mutation.folderId { existing.folderId = v }
            if let v = mutation.folderPath { existing.folderPath = v }
            if let v = mutation.isInInbox { existing.isInInbox = v }
            if let v = mutation.isFlagged { existing.isFlagged = v }
            if let v = mutation.actionTag { existing.actionTag = v }
            overlay[id] = existing

            guard mutation.folderId != nil || mutation.folderPath != nil
                    || mutation.isInInbox != nil
            else { return nil }
            return "before={\(Self.locationDescription(before))} "
                + "incoming={\(Self.locationDescription(mutation))} "
                + "after={\(Self.locationDescription(existing))}"
        }
        if let locationTrace {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] overlay.register id=\(id) \(locationTrace) "
                    + "retainCount=\(overlayRetainCount(id: id))")
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

    /// Find optimistic state under the durable row's current key, or under a
    /// provider-proven predecessor key while the in-memory mirrors are still
    /// catching up to a committed MOVE re-key. Exact current-key state wins.
    nonisolated func snapshotOverlayMutation(
        forCurrentHeaderId id: String
    ) -> (id: String, mutation: PendingMutation)? {
        let snapshot = snapshotOverlay()
        if let mutation = snapshot[id] { return (id, mutation) }
        for predecessorId in MessageHeaderRekey.predecessorHeaderIds(leadingTo: id) {
            if let mutation = snapshot[predecessorId] {
                return (predecessorId, mutation)
            }
        }
        return nil
    }

    /// Undo snapshots must capture the VISUALIZED state (act-on-visualized-state
    /// rule): a queued intent cycle's isRead/isFlagged/actionTag exist only in the
    /// overlay until the FIFO drains, and a DB-fresh row predates them — an undo
    /// restoring that row would silently revert the user's most recent gesture.
    /// Folder fields are deliberately NOT taken from the overlay (a pending move's
    /// dest must not leak into a snapshot that records the pre-move location).
    ///
    /// MUST be called BEFORE the call site's own `retainOverlayEntry`/
    /// `registerMutation` — those calls write THIS action's own overlay mutation
    /// (e.g. the F6 tag-clear on inbox exit), and `registerMutation` merges into
    /// the SAME coalesced entry this reads. Calling it after would capture this
    /// action's own not-yet-committed mutation as if it were pre-existing state.
    nonisolated func overlayAdjustedSnapshot(_ header: MessageHeader) -> MessageHeader {
        guard let m = snapshotOverlayMutation(
            forCurrentHeaderId: header.id)?.mutation
        else { return header }
        var h = header
        if let isRead = m.isRead { h.isRead = isRead }
        if let isFlagged = m.isFlagged { h.isFlagged = isFlagged }
        // 🚨 `tagSortOrder` IS MIRRORED, NOT DERIVED LATER (R13-U13). The two
        // fields are ONE fact stored twice, and `UndoMember.init(header:)` reads
        // BOTH off this snapshot and restores BOTH durably. Setting the tag
        // without its sort order wrote e.g. `(actionTag: .reply,
        // tagSortOrder: 99)` to the row on undo: the chip says reply, triage
        // files it at the bottom. This is the exact corruption migration `v58`
        // was written to heal once, and a one-time heal does not re-run.
        //
        // Expression is `MessageHeader.setActionTag`'s, verbatim — that is the
        // pairing's source of truth. It is inlined rather than called because
        // `setActionTag` also stamps `actionTagSetAt`, which the overlay does
        // not carry and `UndoMember` does not record; stamping it here would
        // invent a fact rather than mirror one.
        //
        // ⚠️ THIS FUNCTION IS NOT THE ONLY FEEDER OF `UndoMember`, and reading
        // it as one is what left the sibling half open for a day. It covers the
        // six `InboxViewModel` pushes (via `overlayAdjustedForUndo`) and
        // `SettingsView`'s. The three `MessageDetailViewModel` pushes —
        // `archiveMessage` / `deleteMessage` / `moveMessage` — do NOT call it:
        // that view model holds `MessageHeader`s in `message` / `threadMessages`
        // and hands those values straight to `UndoableAction(messages:)`, so the
        // pairing there is enforced at ITS four writers instead (`applyOverlay`
        // ×2, `updateThreadMessageFolder`, `applyManualTag`). Fixing one place
        // does not close the class; the class is "every `actionTag` write on a
        // value that can reach `UndoMember.init(header:)`".
        if let actionTag = m.actionTag {
            h.actionTag = actionTag
            h.tagSortOrder = actionTag?.sortOrder ?? 99
        }
        return h
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

    private nonisolated static func locationDescription(
        _ mutation: PendingMutation?
    ) -> String {
        guard let mutation else { return "absent" }
        let folderId = mutation.folderId ?? "<nil>"
        let folderPath = mutation.folderPath ?? "<nil>"
        let isInInbox = mutation.isInInbox.map { String($0) } ?? "<nil>"
        return "folderId=\(folderId) folderPath=\(folderPath) "
            + "isInInbox=\(isInInbox)"
    }

    /// DEBUG diagnostics for the folder-location overlay and its independent
    /// retain lifecycle. This is deliberately a synchronous snapshot so tap,
    /// guard, Undo, and queued-action logs can compare the same two stores.
    nonisolated func roleActionOverlayDiagnostic(id: String) -> String {
        let mutation = optimisticOverlay.withLock { $0[id] }
        return "overlay={\(Self.locationDescription(mutation))} "
            + "retainCount=\(overlayRetainCount(id: id))"
    }

    private nonisolated func overlayRetainCount(id: String) -> Int {
        overlayOpRefCount.withLock { $0[id] ?? 0 }
    }

    /// Mark one more in-flight gesture op for `id`. Call synchronously at
    /// gesture time, alongside `registerMutation`.
    nonisolated func retainOverlayEntry(id: String) {
        let transition = overlayOpRefCount.withLock { counts -> (Int, Int) in
            let before = counts[id] ?? 0
            counts[id, default: 0] += 1
            return (before, counts[id] ?? 0)
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] overlay.retain id=\(id) "
                + "count=\(transition.0)->\(transition.1) "
                + roleActionOverlayDiagnostic(id: id))
    }

    /// Release one in-flight gesture op for `id`. When the refcount reaches
    /// zero — or `id` was never retained (defensive; the count never goes
    /// negative) — removes `id` from the refcount map AND from the overlay
    /// itself. Call exactly once per `retainOverlayEntry` call, on every exit
    /// path of the owning queued closure.
    nonisolated func releaseOverlayEntry(id: String) {
        let transition = overlayOpRefCount.withLock { counts -> (Int, Int, Bool) in
            guard let count = counts[id] else {
                // Defensive: unmatched release (no retain on record). Treat as
                // the terminal release so the overlay never strands, but this
                // indicates a retain/release imbalance at a call site.
                BackgroundSyncLogger.logInbox("[AccountManager] releaseOverlayEntry — unmatched release for \(id), no retain on record")
                return (0, 0, true)
            }
            if count <= 1 {
                counts.removeValue(forKey: id)
                return (count, 0, true)
            }
            counts[id] = count - 1
            return (count, count - 1, false)
        }
        let beforeRemoval = roleActionOverlayDiagnostic(id: id)
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] overlay.release id=\(id) "
                + "count=\(transition.0)->\(transition.1) "
                + "remove=\(transition.2) \(beforeRemoval)")
        guard transition.2 else { return }
        removeOverlayEntries(ids: [id])
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] overlay.removed id=\(id) "
                + roleActionOverlayDiagnostic(id: id))
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
        enqueueWriteFromSynchronousContext { await self.executeIntentCycle(id: id) }
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
            if !header.isInInbox {
                // Tags are inbox-scoped (ADR-IOS-036) and F6 clears actionTag
                // the moment a row leaves the inbox — both tag-gesture UI
                // entry points are gated on isInInbox, so a legitimate tag
                // intent whose RESOLVED header has already left the inbox
                // means a move (e.g. archive/delete) ran after this gesture:
                // closure-reorder race, since both enqueue via unstructured
                // Tasks with no FIFO ordering guarantee between them. The
                // move is the LATER user action, and its tag-clear wins —
                // this matches serial-replay ordering. Skip reinstating a
                // stale tag on a row that already left the inbox.
                BackgroundSyncLogger.logInbox("[AccountManager] executeIntentCycle — skipping tag write for \(id), header left inbox (isInInbox=false)")
            } else if target != header.actionTag {
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
                                pendingBodyCount: Int = 0,
                                unindexedBodyCount: Int = 0) {
        if var existing = _backfillBacking[accountId] {
            existing.headersDone = headersDone
            existing.isPaused = isPaused
            existing.totalEmails = totalEmails
            existing.ftsIndexed = ftsIndexed
            existing.uidTotal = uidTotal
            existing.uidWalked = uidWalked
            existing.pendingBodyCount = pendingBodyCount
            existing.unindexedBodyCount = unindexedBodyCount
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
            progress.unindexedBodyCount = unindexedBodyCount
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
        guard !isRuntimeRemoved(account.id) else {
            throw ProviderError.notConnected
        }
        // Calendar-only accounts skip email provider creation
        if account.calendarOnly {
            switch account.provider {
            case .gmail:
                let calendar = await createGoogleCalendarProvider(for: account)
                guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
                calendarProviders[account.id] = calendar
            case .outlook:
                let calendar = await createExchangeCalendarProvider(for: account)
                guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
                calendarProviders[account.id] = calendar
            case .caldav:
                if let caldavProvider = try await createCalDAVProvider(for: account) {
                    guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
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
            let calendar = await createGoogleCalendarProvider(for: account)
            guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
            calendarProviders[account.id] = calendar
        case .outlook:
            provider = await createExchangeProvider(for: account)
            let calendar = await createExchangeCalendarProvider(for: account)
            guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
            calendarProviders[account.id] = calendar
        case .imap:
            provider = try createIMAPProvider(for: account)
            // Check for linked CalDAV config
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
                calendarProviders[account.id] = caldavProvider
            }
        case .icloud:
            provider = try createIMAPProvider(for: account)
            // iCloud accounts always check for linked CalDAV
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
                calendarProviders[account.id] = caldavProvider
            }
        case .caldav:
            // Pure calendar-only — should have been handled above
            if let caldavProvider = try await createCalDAVProvider(for: account) {
                guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }
                calendarProviders[account.id] = caldavProvider
            }
            return
        }

        guard !isRuntimeRemoved(account.id) else {
            calendarProviders.removeValue(forKey: account.id)
            throw ProviderError.notConnected
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
            if isRuntimeRemoved(account.id) {
                providers.removeValue(forKey: account.id)
                workQueues.removeValue(forKey: account.id)
                calendarProviders.removeValue(forKey: account.id)
                await queue.invalidate()
                await syncEngine.remove(accountId: account.id)
                throw ProviderError.notConnected
            }
        }

        let connectT0 = CFAbsoluteTimeGetCurrent()
        BootProfiler.mark("connectAccount[\(acctTag)]: provider.connect() START (network — timeout \(Int(SyncConfig.connectTimeoutSeconds))s)")
        do {
            try await withTimeout(seconds: SyncConfig.connectTimeoutSeconds) {
                try await provider.connect()
            }
            guard !isRuntimeRemoved(account.id) else {
                try? await provider.disconnect()
                throw ProviderError.notConnected
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

        // 🚨 `config.needsReauth` IS DELIBERATELY NOT READ HERE (round 18, item B).
        // This used to be `if config.needsReauth { return nil }`, and that gate was
        // a durable wedge rather than a signal. The column had exactly one writer
        // (`AccountManager.retireCalendarOperation`'s
        // `UPDATE caldavConfig SET needsReauth = 1`), exactly one reader (this
        // guard), and NOTHING that ever cleared it — the only other write is
        // `CalDAVConfig.init`'s `false`, reached only when the CalDAV setup path
        // creates a NEW config row. So one auth failure removed the account from
        // `calendarProviders` permanently, and from there:
        //   * `drainCalendarQueue`'s `guard let calProvider = calendarProviders[…]
        //     else { continue }` skipped every op queued on that account on every
        //     subsequent drain, forever — no execution, no retirement, no user
        //     signal. That is the never-drop WEDGE COROLLARY, which sits in the
        //     non-recoverable set and is therefore NOT eligible for
        //     fail-closed-and-register.
        //   * `CalendarPickerModel.loadData` enumerates
        //     `CalendarProviderDispatch.resolveAll()`, which iterates
        //     `AccountManager.calendarProviders` — so the account also vanished
        //     from the calendar picker, and the ONE working re-auth signal
        //     (`CalendarPickerModel`'s live `listCalendars()` probe → its OWN,
        //     unrelated `AccountEntry.needsReauth` field → the "Calendar Access
        //     Required" section) could never render for it. The durable column
        //     defeated the live probe. Two different `needsReauth`s with the same
        //     spelling is why this read as covered.
        // Removing the gate lets the provider be created, so the live probe
        // surfaces the prompt and queued ops keep reaching the drain. It does not
        // create a hammering loop: `drainCalendarQueue`'s LOCAL
        // `var failedAccounts = Set<String>()` is tested before the provider
        // lookup, and the CalDAV auth arm inserts into it, so an account with dead
        // credentials makes at most ONE wire attempt per drain pass.
        // The COLUMN stays in the schema (migrations are immutable, and a future
        // credential re-entry flow is the thing that would read it) — it is simply
        // no longer written and no longer read.

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

    func disconnectAccount(
        _ account: Account,
        deletingCredentials caldavConfigIds: [String]? = nil
    ) async {
        // Detach every actor-owned route in one synchronous AccountManager turn
        // BEFORE the first await. Once this method suspends, a reentrant
        // foreground/sync call can no longer discover this account's provider,
        // queue, calendar provider, or refresh coordinator.
        if caldavConfigIds != nil {
            _ = removedAccountRuntimeFence.withLock { $0.insert(account.id) }
        }
        let coordinator = oauthCoordinators.removeValue(forKey: account.id)
        let provider = providers.removeValue(forKey: account.id)
        let queue = workQueues.removeValue(forKey: account.id)
        calendarProviders.removeValue(forKey: account.id)
        // Synchronous, nonisolated admission close for committed removal: a
        // stale queue reference cannot start work while the actor-level waiter
        // drain is pending. Re-authentication keeps the old queue alive long
        // enough for its captured drain closures to fail/requeue normally.
        if caldavConfigIds != nil { queue?.markInvalidated() }

        // Account removal deletes credentials before the first actor/network
        // await. The synchronous runtime fence above also makes every captured
        // OAuth accessor refuse cached-token and refresh paths immediately.
        if let caldavConfigIds {
            KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: account.id))
            KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: account.id))
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: account.id))
            for configId in caldavConfigIds {
                KeychainHelper.delete(key: "caldav_password_\(configId)")
            }
        }

        // Refuse queued work and discard any refresh result that was already in
        // flight. Delete OAuth keys again after invalidation closes the narrow
        // race where the network result returned just before invalidate ran.
        if let coordinator { await coordinator.invalidate() }
        if caldavConfigIds != nil {
            KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: account.id))
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: account.id))
        }
        if caldavConfigIds != nil, let queue { await queue.invalidate() }

        // Tear down the provider socket before waiting for sync tasks. Their
        // cancellation is cooperative, so a read parked in SwiftMail may not
        // return until disconnect closes the underlying connection.
        if let provider {
            try? await provider.disconnect()
        }
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
        guard !isRuntimeRemoved(account.id) else {
            throw ProviderError.authenticationFailed
        }
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
            guard !self.isRuntimeRemoved(accountId) else {
                throw ProviderError.authenticationFailed
            }
            if !forceRefresh,
               let token = KeychainHelper.loadString(key: KeychainHelper.accessTokenKey(accountId: accountId)) {
                return token
            }
            let token = try await coordinator.refresh(accountId: accountId, email: email, using: refresher)
            guard !self.isRuntimeRemoved(accountId) else {
                throw ProviderError.authenticationFailed
            }
            return token
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
