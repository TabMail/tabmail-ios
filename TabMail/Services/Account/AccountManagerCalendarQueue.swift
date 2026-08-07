/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Outcome of a single calendar drain attempt for one queued operation.
/// Returned to `calendar_event_create` so the agent can react in-turn.
enum CalendarOpOutcome: Sendable {
    /// Server accepted the write — op deleted.
    /// - `newSeriesId`: non-nil only after a `this_and_following` split —
    ///   the id of the freshly-created new series. Without surfacing it the
    ///   LLM keeps using the truncated master's id and subsequent edits to
    ///   occurrences in the new half of the series silently miss.
    /// - `createdRealId`: non-nil only after a `.create` — the REAL id the
    ///   provider returned (Graph/CalDAV assign their own; Google echoes
    ///   our pre-id). The tool returns this in its result so
    ///   `processToolOutputForLLM` assigns the numericId to the REAL id,
    ///   not the optimistic pre-id (which the server then 400s on edit).
    case success(newSeriesId: String? = nil, createdRealId: String? = nil)
    /// Permanently bad request (HTTP 4xx outside auth/quota, or notFound/scope).
    /// `reason` is a short string we surface to the LLM verbatim so it can
    /// adjust the next call (e.g. fix a missing field).
    case permanentFailure(reason: String)
    /// Transient — retried, still queued. The LLM should treat this as
    /// "the action is in flight, the user will see it appear shortly".
    case stillQueued
    /// We waited but the drain didn't reach this op in time.
    case timedOut
}

extension AccountManager {

    /// Register a one-shot awaiter for the given op id and resolve as soon as
    /// the drain hits a terminal branch — or after `timeoutSeconds` elapses.
    /// Resumed-exactly-once is enforced by removeValue + nil-check at signal.
    func awaitCalendarOpOutcome(opId: String, timeoutSeconds: Double) async -> CalendarOpOutcome {
        await withTaskGroup(of: CalendarOpOutcome.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<CalendarOpOutcome, Never>) in
                    Task { await self?.registerCalendarOpAwaiter(opId: opId, continuation: cont) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .timedOut
            }
            // First result wins — cancel the rest. Cleanup of any leftover
            // continuation is handled in `signalCalendarOpOutcome` (defensive
            // discard if already resumed).
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            // If the timeout fired first, drop the still-pending continuation
            // so the drain doesn't try to resume a stale waiter.
            if case .timedOut = outcome {
                self.dropCalendarOpAwaiter(opId: opId)
            }
            return outcome
        }
    }

    private func registerCalendarOpAwaiter(opId: String, continuation: CheckedContinuation<CalendarOpOutcome, Never>) {
        // ⚠ R13-U8 — THIS COMMENT USED TO DESCRIBE A MECHANISM THAT DOES NOT
        // EXIST. It read: *"If the drain already finished and signalled before
        // we registered, there's no recorded outcome to read — return
        // stillQueued so the LLM gets a meaningful fallback rather than hanging
        // forever."* There is no recorded-outcome store anywhere in this file:
        // `signalCalendarOpOutcome` resolves the awaiter it finds and RETURNS
        // (`guard let cont = … else { return }`), writing nothing down. The
        // branch below is not a signal-before-register check at all — it fires
        // only on a SECOND registration for the same op id, and it resumes the
        // PRIOR continuation (an awaiter that is provably still suspended,
        // since the map holds exactly the un-resumed ones) so the earlier
        // caller cannot be stranded when its entry is overwritten on the next
        // line. Resumed-exactly-once is upheld by the map being the single
        // ownership token: every resume path (`signal`, `drop`, here) takes the
        // continuation out of the map, or replaces it having just resumed it.
        //
        // The real signal-before-register case is handled by the TIMEOUT, not
        // here: `signalCalendarOpOutcome` no-ops against an empty map, this
        // registration then suspends with nothing left to wake it, and
        // `awaitCalendarOpOutcome`'s sibling sleep task resolves the caller at
        // `timeoutSeconds` (R12-T6 is why that arm must also `dropCalendarOpAwaiter`).
        // Do not "restore" the described behaviour by inventing an outcome
        // cache without deciding its eviction — an outcome kept for an op
        // nobody awaits is a leak, and one evicted too early is this race again.
        if calendarOpAwaiters[opId] != nil {
            // A second register for the same id is a programming error;
            // resume the prior one defensively.
            calendarOpAwaiters[opId]?.resume(returning: .stillQueued)
        }
        calendarOpAwaiters[opId] = continuation
    }

    /// 🚨 THE TIMEOUT ARM MUST RESUME THE CONTINUATION IT TAKES (R12-T6).
    /// This used to be a bare `calendarOpAwaiters.removeValue(forKey: opId)` with
    /// the return value discarded. `signalCalendarOpOutcome` could then never
    /// resume it either (the entry was already gone), `withCheckedContinuation`
    /// is not cancellation-aware so `group.cancelAll()` did not release it, and
    /// `withTaskGroup` awaits its remaining children at scope exit — so
    /// `awaitCalendarOpOutcome` NEVER RETURNED. Every agent calendar
    /// create/edit/delete that reached the timeout hung its chat turn outright,
    /// and nothing above bounds a hung tool (`ToolRegistry.execute` has no
    /// timeout of its own).
    ///
    /// The primary trigger is ORDINARY: `drainCalendarQueue` returns early on
    /// `guard NetworkMonitor.checkConnected()` — i.e. offline — before any
    /// `signalCalendarOpOutcome`. The `!isDrainingCalendar` guard and any
    /// provider round-trip over the caller's 10 s budget do the same.
    ///
    /// ⚠️ THE COUNTERFACTUAL IS EMPTY, which is what makes this unambiguous.
    /// `AccountManager` is an `actor`, so `removeValue` is atomic under actor
    /// isolation: exactly one of drop and signal can obtain the continuation and
    /// a double-resume is structurally impossible. The only behaviour change is
    /// that `.timedOut` becomes DELIVERABLE — which the function's own doc
    /// ("or after `timeoutSeconds` elapses"), the `CalendarOpOutcome.timedOut`
    /// case, and `CalendarEventCreateTool`'s live `case .stillQueued, .timedOut:`
    /// arm all already assumed.
    ///
    /// ⚠️ DELIBERATELY NOT `AgentToolRouter.ContinuationGuard` /
    /// `ComposeContinuationGuard`. Those pair a stored continuation with an
    /// `NSLock` because their owners are NOT isolated — a MainActor router
    /// resumed from arbitrary UI callbacks. Here the dictionary lives on an
    /// actor, so take-and-resume is already serialized; an `NSLock` would add a
    /// second, redundant mutual-exclusion layer over state that cannot race, and
    /// it would not have prevented this defect at all — the bug was a discarded
    /// return value, not a missing lock. Same invariant (exactly-once resume),
    /// enforced by the mechanism this file already has.
    private func dropCalendarOpAwaiter(opId: String) {
        calendarOpAwaiters.removeValue(forKey: opId)?.resume(returning: .timedOut)
    }

    /// Drain-side notification: resolve any pending awaiter for `opId` with
    /// `outcome`. No-op if no one is waiting.
    ///
    /// 🚨 **THE RETURN VALUE IS THE POINT (R16-1).** This used to return `Void` and
    /// no caller could tell a delivered outcome from one that reached nobody — which
    /// is why the silent case survived so long. Enumerate the drain's SIX production
    /// triggers and only ONE of them (`queueCalendarOperation`'s
    /// `Task { await drainCalendarQueue() }`) is causally paired with an awaiter
    /// registration; `reconcileCalendarQueue`, both `NetworkMonitor` arms and both
    /// `SyncScheduler` arms can never have one. So "the tool is told" is not a race
    /// on a 10 s timeout, it is the MINORITY path. The durable retirement in
    /// `retireCalendarOperation` is what makes the outcome survive that; this
    /// boolean only decides how loudly the miss is recorded.
    @discardableResult
    func signalCalendarOpOutcome(opId: String, outcome: CalendarOpOutcome) -> Bool {
        guard let cont = calendarOpAwaiters.removeValue(forKey: opId) else { return false }
        cont.resume(returning: outcome)
        return true
    }

    /// Retire a queued calendar operation TERMINALLY, durably, in one write.
    ///
    /// 🚨 **THIS REPLACES `PendingCalendarOperation.deleteOne` ON EVERY TERMINAL
    /// FAILURE ARM (R16-1).** The old shape deleted the durable row and reported the
    /// failure only into an in-memory continuation, so on the five drain triggers
    /// that can have no awaiter — and on the sixth once the tool's 10 s wait has
    /// elapsed — the user's intention was destroyed with no record at all, *after*
    /// `CalendarEventCreateTool`'s `case .stillQueued, .timedOut:` arm had already
    /// answered "queued successfully … will appear on the calendar shortly". No sync
    /// can recreate the event, reapply the edit or perform the delete: this is a
    /// dropped user intention, which `THE MANTRA` puts in the non-recoverable set.
    ///
    /// ⚠️ **BOTH OBVIOUS REMEDIES ARE EACH OTHER'S MIRROR IMAGE AND THIS IS
    /// NEITHER (`MIS-005`).** Not resuming on timeout restores the R12-T6 hang on
    /// every offline calendar call. Leaving terminal failures QUEUED wedges the
    /// account's calendar lane — the exact `MIS-006` defect R15-FIX-4 was fixing.
    /// `PendingStatus.failed` is a THIRD state: durable, so the outcome outlives the
    /// waiter, and outside `drainCalendarQueue`'s `status == queued` filter and
    /// `reconcileCalendarQueue`'s `inFlight` reset, so it can never be re-executed
    /// and can never starve a later op.
    ///
    /// The write is the SAME write that used to delete, so the retirement cannot
    /// outrun its own record. If it throws, the row stays `inFlight`, launch
    /// reconciliation returns it to `queued`, and the op is retried — a retry loop,
    /// never a drop.
    ///
    /// 🚨 **AND THAT IS WHY THIS RETURNS A `Bool` (R17-2). PRODUCER AND CONSUMER
    /// MUST AGREE ON WHETHER THE OP IS OVER.** This was `-> Void`, so all six
    /// terminal arms ran `signalCalendarOpOutcome(… .permanentFailure(reason:))`
    /// unconditionally — three lines after a catch arm whose own comment says the
    /// op *retries*. The producer said RETRYABLE and the consumer announced
    /// TERMINAL, and the consumer is what the user sees: `CalendarEventEditTool`
    /// turns the confirmation card red and instructs the LLM *"call
    /// calendar_event_edit again"*. The user re-issues, the original row drains
    /// at next launch too, and **two events exist with two sets of invitations
    /// already delivered to other people.** No sync converges them — both are
    /// authoritative server objects and the recipients have both mails.
    ///
    /// So `.permanentFailure` may be signalled ONLY on a committed retirement.
    /// On a failed write the honest outcome is `.stillQueued`, which is what the
    /// transient arm already signals and which every tool renders as "in flight,
    /// will appear shortly" — true, because reconciliation requeues it.
    ///
    /// ⚠️ THE MIRROR IMAGE, stated because it is the obvious alternative
    /// (`MIS-005`): signalling NOTHING on a failed write leaves the awaiter to
    /// its 10 s timeout and `.timedOut`, which the tools treat identically to
    /// `.stillQueued` — so it is not wrong, merely slower and less legible. What
    /// would be wrong in the other direction is deleting the row or leaving it
    /// `queued`-but-announced-terminal; neither is done here.
    ///
    /// - Returns: `true` when the terminal status was durably committed, `false`
    ///   when the write failed and the operation therefore remains retryable.
    ///
    /// Also the honest half of the "the user is told" claim: this is the only place
    /// in this file that reaches `BackgroundSyncLogger`, whose Error Log is what
    /// `DebugLogView` renders. Two doc comments in this file asserted terminal
    /// failures were *"Logged at error level so the user sees this in DebugLog"* /
    /// *"Logged loudly so the user can see"* while the file held raw `print`s and
    /// no logger call at all (R16-10). ⚠️ That sentence carried a bare "39" until
    /// R16-7; the integer was already stale by the time it was committed, because
    /// R16-1's own conversion of the six terminal arms to `retireCalendarOperation`
    /// removed some of them. Predicate instead of an integer, comments excluded so
    /// this paragraph cannot satisfy it:
    ///   `rg -c --pcre2 '^(?!\s*(///|//)).*\bprint\('
    ///    TabMail/Services/Account/AccountManagerCalendarQueue.swift` → **34** at
    ///   the R16 candidate. The number is expected to move; what must not move is
    ///   that every TERMINAL outcome also reaches `BackgroundSyncLogger`.
    ///
    /// - Parameter caldavReauthAccountId: when non-nil, `caldavConfig.needsReauth`
    ///   is set for that account IN THIS SAME TRANSACTION. It rides here rather
    ///   than in its own write because the auth arm's delete and its `needsReauth`
    ///   update were atomic before this change, and splitting them would let the
    ///   retirement land without the persistent signal that makes it recoverable.
    private func retireCalendarOperation(
        _ op: PendingCalendarOperation,
        reason: String,
        caldavReauthAccountId: String? = nil
    ) async -> Bool {
        BackgroundSyncLogger.logError(
            "[CalendarQueue] TERMINAL \(op.operationType) op=\(op.id) account=\(op.accountId) event=\(op.eventId ?? "new"): \(reason)",
            source: "CalendarQueue")
        do {
            try await retryWrite(dbPool, label: "CalendarQueue") { db in
                if let caldavAccountId = caldavReauthAccountId {
                    try db.execute(
                        sql: "UPDATE caldavConfig SET needsReauth = 1 WHERE accountId = ?",
                        arguments: [caldavAccountId]
                    )
                }
                guard var row = try PendingCalendarOperation.fetchOne(db, key: op.id) else { return }
                row.status = PendingStatus.failed.rawValue
                row.failureReason = reason
                try row.update(db)
            }
            return true
        } catch {
            // The row stays `inFlight`; `reconcileCalendarQueue` returns it to
            // `queued` at next launch and the op retries. Recorded, not silent —
            // and reported, so no caller announces `.permanentFailure` over it.
            BackgroundSyncLogger.logError(
                "[CalendarQueue] FAILED to record terminal outcome for op \(op.id) — it will be retried: \(error)",
                source: "CalendarQueue")
            print("[CalendarQueue] Failed to record terminal outcome for op \(op.id): \(error)")
            return false
        }
    }

    /// The single terminal-announcement gate: signal `.permanentFailure` when the
    /// retirement committed, and the truthful `.stillQueued` when it did not.
    ///
    /// 🚨 R17-2 — ALL SIX TERMINAL ARMS ROUTE THROUGH THIS, so the producer's
    /// verdict and the consumer's announcement cannot come apart again. The census
    /// property is *"every call site that announces a terminal calendar outcome"*;
    /// re-derive it with a predicate this comment cannot satisfy (`MIS-033`):
    /// ```
    /// rg -n --pcre2 '^(?!\s*(///|//)).*\.permanentFailure\(' \
    ///    TabMail/Services/Account/AccountManagerCalendarQueue.swift
    /// ```
    /// → exactly one hit, inside this function. The two remaining
    /// `signalCalendarOpOutcome` calls in `drainCalendarQueue` are deliberately
    /// NOT members: `.success` follows a completed provider write (true whatever
    /// the local delete did) and `.stillQueued` is the transient arm, which is
    /// already non-terminal.
    ///
    /// ⚠️ R17b-B2 — that `.success` sentence is TRUE and INCOMPLETE, and the
    /// missing half is what a reader needs: the announcement is honest, but a
    /// failed local delete leaves the row claimable, so the OP re-executes even
    /// though the OUTCOME was reported correctly. The announcement and the
    /// bookkeeping are separate questions; this gate answers only the first.
    /// The second is discharged at the success arm itself and registered as
    /// `IOS-CAL-008`.
    private func retireAndAnnounce(
        _ op: PendingCalendarOperation,
        reason: String,
        caldavReauthAccountId: String? = nil
    ) async {
        let retired = await retireCalendarOperation(
            op, reason: reason, caldavReauthAccountId: caldavReauthAccountId)
        signalCalendarOpOutcome(
            opId: op.id,
            outcome: retired ? .permanentFailure(reason: reason) : .stillQueued)
    }

    // MARK: - Calendar Operation Queue

    /// Queue a calendar mutation for async execution.
    /// Persists the operation to GRDB before returning — survives crashes/kills.
    func queueCalendarOperation(
        type: CalendarOperationType,
        accountId: String,
        eventId: String? = nil,
        calendarId: String? = nil,
        arguments: [String: JSONValue]
    ) async throws -> PendingCalendarOperation {
        let op = PendingCalendarOperation(
            operationType: type,
            accountId: accountId,
            eventId: eventId,
            calendarId: calendarId,
            arguments: arguments
        )
        try await dbPool.write { db in try op.insert(db) }
        print("[CalendarQueue] Queued \(type.rawValue) for account \(accountId) (id: \(op.id))")
        Task { await drainCalendarQueue() }
        return op
    }

    /// Drain all queued calendar operations in FIFO order.
    /// Pattern mirrors drainPendingQueue — offline skip, per-account failure tracking,
    /// multi-pass re-fetch for ops inserted during drain.
    func drainCalendarQueue() async {
        guard !isDrainingCalendar else {
            print("[CalendarQueue] Skipped drain — already draining")
            return
        }
        guard NetworkMonitor.checkConnected() else {
            print("[CalendarQueue] Skipped drain — offline")
            return
        }
        isDrainingCalendar = true
        defer { isDrainingCalendar = false }

        var failedAccounts = Set<String>()

        for pass in 0..<3 {
            let ops: [PendingCalendarOperation]
            do {
                ops = try await dbPool.read { db in
                    try PendingCalendarOperation
                        .filter(Column("status") == PendingStatus.queued.rawValue)
                        .order(Column("createdAt").asc)
                        .fetchAll(db)
                }
            } catch {
                print("[CalendarQueue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else {
                if pass == 0 { print("[CalendarQueue] No pending calendar ops") }
                break
            }

            if pass == 0 {
                let summary = ops.map { "\($0.operationType)(event=\($0.eventId ?? "new"))" }.joined(separator: ", ")
                print("[CalendarQueue] Draining \(ops.count) calendar operations: \(summary)")
            }

            var executedAny = false

            for op in ops {
                // Re-check if op still exists (may have been cancelled between await points)
                let currentOp: PendingCalendarOperation
                do {
                    guard let fetched = try await dbPool.read({ db in
                        try PendingCalendarOperation.fetchOne(db, key: op.id)
                    }) else {
                        print("[CalendarQueue] Op \(op.id) vanished — skipping")
                        continue
                    }
                    currentOp = fetched
                } catch {
                    print("[CalendarQueue] ERROR: Failed to re-read op \(op.id): \(error)")
                    continue
                }
                if failedAccounts.contains(currentOp.accountId) { continue }
                if currentOp.status == PendingStatus.inFlight.rawValue { continue }

                guard let calProvider = calendarProviders[currentOp.accountId] else {
                    print("[CalendarQueue] No calendar provider for \(currentOp.accountId) — skipping")
                    continue
                }

                // Mark in-flight for crash recovery
                do {
                    try await dbPool.write { db in
                        var updated = currentOp
                        updated.status = PendingStatus.inFlight.rawValue
                        _ = try updated.save(db)
                    }
                } catch {
                    print("[CalendarQueue] WARNING: Could not mark \(currentOp.id) in-flight — skipping: \(error)")
                    continue
                }

                let opType = currentOp.operationType
                print("[CalendarQueue] Executing \(opType) (id: \(currentOp.id), event: \(currentOp.eventId ?? "new"))")

                do {
                    let ids = try await executeCalendarOperation(currentOp, provider: calProvider)
                    // Post-execution delete MUST succeed — remote op already completed.
                    //
                    // 🚨 R17b-B2 — OF THE THREE DURABLE BOOKKEEPING WRITES IN THIS
                    // DRAIN, THIS IS THE ONLY ONE WHOSE FAILURE CAN CHANGE WHAT THE
                    // SERVER SEES, AND IT IS DELIBERATELY NOT GATED. (The other two:
                    // mark-in-flight is checked and `continue`s, leaving the op
                    // `queued`; the transient requeue below only delays the op to the
                    // next launch. The six TERMINAL arms are gated on
                    // `retireCalendarOperation`'s Bool, R17-2.)
                    // If the delete never commits, the row stays
                    // `inFlight`, `reconcileCalendarQueue` returns it to `queued` at
                    // next launch, and the drain RE-EXECUTES work the server already
                    // did. Registered as `IOS-CAL-008`; read that row before changing
                    // anything here.
                    //
                    // Why re-execution is tolerable rather than a defect: every
                    // operation this queue can replay is idempotent under a DURABLE,
                    // deterministic id the queue itself pre-generates
                    // (`PendingCalendarOperation.eventId`, and
                    // `GoogleCalendarProvider.deterministicSplitEventId` for the
                    // successor of a `this_and_following` split), so a replay is
                    // recognised by the server rather than duplicated. Re-derive the
                    // provider half with a predicate this comment cannot satisfy
                    // (`MIS-033`):
                    //   rg -n --pcre2 '^(?!\s*(///|//)).*deterministicSplitEventId' \
                    //      TabMail/Providers/
                    // → 4 at R17b: the definition plus one consumer in each of the
                    // Google, Exchange and CalDAV split paths.
                    //
                    // 🚨 DO NOT make this arm terminal-on-failure. Retiring an op
                    // because a LOCAL delete failed drops an intention whose remote
                    // half may not have happened; a duplicate calendar event is
                    // recoverable by one user gesture and a dropped intention is not
                    // (`MIS-005`, and Outbox rule 4 — "prefer double-send over drop").
                    do {
                        try await retryWrite(dbPool, label: "CalendarQueue") { db in
                            _ = try PendingCalendarOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        BackgroundSyncLogger.logError(
                            "[CalendarQueue] CRITICAL: failed to delete completed op \(currentOp.id) — it stays claimable and will re-execute after reconcileCalendarQueue: \(error)",
                            source: "CalendarQueue")
                        print("[CalendarQueue] CRITICAL: Failed to delete completed op \(currentOp.id) — will re-execute on next drain")
                    }
                    executedAny = true

                    // Best-effort EventKit refresh so iOS Calendar app picks up changes
                    EKEventStoreHelper.refreshSources()

                    print("[CalendarQueue] Completed \(opType) (id: \(currentOp.id))")
                    signalCalendarOpOutcome(
                        opId: currentOp.id,
                        outcome: .success(newSeriesId: ids.newSeriesId, createdRealId: ids.createdRealId)
                    )
                } catch {
                    let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600

                    // 🚨 R14-F4 — RAISE THE RE-AUTH SIGNAL BEFORE ANY DISPOSITION IS
                    // CHOSEN. The signal is about the ACCOUNT; the arms below decide
                    // about the OP. Those are different questions and conflating them
                    // is how this went unnoticed: `rg -c authFailedAccounts` over this
                    // file returned ZERO, so an OAuth calendar account whose grant had
                    // been revoked produced no persistent, user-visible signal at all
                    // — only CalDAV accounts did, through their `caldavConfig`
                    // `needsReauth` column. `authFailedAccounts` is the OAuth
                    // equivalent: `AccountManager`'s `didSet` mirrors it into
                    // `AccountManagerState`, which `RootView`, `SettingsView` and
                    // `AccountDetailView` all render as a "re-authenticate" prompt,
                    // and a successful re-auth clears it (`AccountManagerSetup`).
                    //
                    // This is what makes the RETRYABLE half below recoverable rather
                    // than a silent wedge: the op stays queued, the user is told to
                    // re-authenticate, and one ordinary gesture drains it.
                    if Self.isCalendarOAuthReauthRequired(error) {
                        markAuthFailed(currentOp.accountId)
                    }

                    // Permanent errors — retire terminally, no retry.
                    if Self.isCalendarNotFoundError(error) {
                        print("[CalendarQueue] Event not found for \(opType) — retiring (server wins)")
                        let reason = "event not found on server"
                        await retireAndAnnounce(currentOp, reason: reason)
                        executedAny = true
                        continue
                    }
                    if Self.isCalendarMissingScopeError(error) {
                        print("[CalendarQueue] Calendar scope not granted for \(opType) — retiring. User must re-authenticate in Settings.")
                        // 🚨 R16-5 — RAISE THE PERSISTENT RE-AUTH SIGNAL HERE TOO.
                        // This arm's own reason string ends *"user must
                        // re-authenticate in Settings"*, i.e. its remedy is a USER
                        // GESTURE — and until now nothing told the user to make it.
                        // `isCalendarOAuthReauthRequired` is FALSE for both spellings
                        // this arm claims (`missingScope` and a raw `httpError(403,…)`),
                        // so the R14-F4 signal above does not fire, and unlike the
                        // CalDAV auth arm there is no `caldavConfig.needsReauth` write
                        // either. `IOS-CAL-003`'s stated discharge was therefore false
                        // for its own namesake case — the same shape as R15's
                        // `IOS-QUEUE-009` on the mail lane, one lane fixed and the
                        // sibling left (`MIS-006`).
                        markAuthFailed(currentOp.accountId)
                        let reason = "calendar permission missing — user must re-authenticate in Settings"
                        await retireAndAnnounce(currentOp, reason: reason)
                        executedAny = true
                        failedAccounts.insert(currentOp.accountId)
                        continue
                    }
                    // Auth failure — semi-permanent, needs re-authentication (L12).
                    // Covers CalDAV's typed `authFailed`, a POST-REFRESH raw 401 from
                    // Google/Exchange, and (R14-F4) a token-ACQUISITION failure whose
                    // OAuth error code names a dead GRANT. See `isCalendarAuthError`
                    // for why the second is safe to treat as terminal (the providers
                    // force a token refresh and only rethrow the SECOND 401) and
                    // `isGrantLevelOAuthFailure` for why only three codes qualify for
                    // the third.
                    //
                    // ⚠️ THE SIGNAL IS RAISED FOR AN INCOMPARABLE SET, NOT A LARGER
                    // ONE (R16-10). `isCalendarOAuthReauthRequired` above does NOT
                    // claim `CalDAVError.authFailed`, which this arm does claim —
                    // CalDAV's persistent signal is the `caldavConfig.needsReauth`
                    // write below instead. See that predicate's doc for the exact
                    // set difference in both directions.
                    if Self.isCalendarAuthError(error) {
                        let isCalDAV = Self.isCalDAVAuthError(error)
                        print("[CalendarQueue] Auth failed for \(opType) (\(isCalDAV ? "CalDAV" : "OAuth")) — stopping retries, user must re-authenticate")
                        let reason = Self.calendarAuthFailureReason(error)
                        // Only CalDAV accounts have a `caldavConfig` row — running
                        // the UPDATE for an OAuth account would match zero rows and
                        // read as if we had marked something. It travels INSIDE the
                        // retirement write so the two cannot come apart.
                        await retireAndAnnounce(
                            currentOp, reason: reason,
                            caldavReauthAccountId: isCalDAV ? currentOp.accountId : nil)
                        executedAny = true
                        failedAccounts.insert(currentOp.accountId)
                        continue
                    }

                    // Permanent: provider can't perform the requested edit_scope
                    // (e.g. this_only / this_and_following against Exchange or
                    // CalDAV before those backends implement it). Drop the op
                    // and surface a clear reason — retrying won't help.
                    if Self.isCalendarUnsupportedError(error) {
                        let reason = unsupportedReason(error)
                        print("[CalendarQueue] Unsupported \(opType) (\(reason)) — retiring (no retry)")
                        await retireAndAnnounce(currentOp, reason: reason)
                        executedAny = true
                        continue
                    }

                    // Permanent: a multi-step write (series split) failed AND
                    // its rollback also failed — the calendar is in an
                    // inconsistent state. Retrying would re-cap an already-
                    // capped master and create duplicate successor series, so
                    // drop the op and surface the message for manual attention.
                    if case CalDAVError.inconsistentState(let reason) = error {
                        print("[CalendarQueue] Inconsistent calendar state for \(opType) — retiring (no retry): \(reason)")
                        await retireAndAnnounce(currentOp, reason: reason)
                        executedAny = true
                        continue
                    }

                    // Permanent malformed-request errors — retire terminally.
                    // Retrying the same broken payload never succeeds. The
                    // retirement is recorded at error level through
                    // `BackgroundSyncLogger`, which is what `DebugLogView` renders
                    // (R16-10 — this sentence claimed that before it was true).
                    if Self.isCalendarBadRequestError(error) {
                        print("[CalendarQueue] Bad request for \(opType) (\(error)) — retiring (will not retry)")
                        let reason = badRequestReason(error)
                        await retireAndAnnounce(currentOp, reason: reason)
                        executedAny = true
                        continue
                    }

                    // Transient errors — always retry. NEVER drop on age alone.
                    // Only confirmed-stale paths above (notFound, missingScope,
                    // authError, unsupported, inconsistentState, badRequest) may
                    // retire an op, and none of them DELETES it: each moves the row
                    // to `PendingStatus.failed` with a reason.
                    //
                    // ⚠ The names above are the members; the COUNT is re-derived,
                    // not carried (`MIS-031` — this sentence said "SIX arms,
                    // re-derived by grepping `retireCalendarOperation`", and R17-2
                    // moved the arms onto `retireAndAnnounce`, so the stated
                    // predicate stopped returning what the sentence claimed while
                    // the sentence stayed put). Comments excluded so this paragraph
                    // cannot satisfy it (`MIS-033`):
                    //   rg -c --pcre2 '^(?!\s*(///|//)).*retireAndAnnounce\('
                    //      TabMail/Services/Account/AccountManagerCalendarQueue.swift
                    // → 7 at R17-2: the six arms plus the function's own definition.
                    // See `retireAndAnnounce`, which is now the single terminal
                    // announcement gate, and `retireCalendarOperation` beneath it.
                    print("[CalendarQueue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
                    // 🚨 R17b-B2 — RECORDED, NOT SWALLOWED. This was `try? await`
                    // until R17b: the requeue is a durable bookkeeping write and a
                    // silently-dropped failure leaves the row `inFlight`, where the
                    // drain's `status == queued` filter skips it for the rest of the
                    // session with nothing in the log to say so. The DISPOSITION is
                    // deliberately unchanged — `reconcileCalendarQueue` returns the
                    // row to `queued` at next launch, and `.stillQueued` below is
                    // truthful in BOTH branches (the op is still queued, or still
                    // claimable at `inFlight`), so there is nothing to decide here,
                    // only something to see. Same shape as
                    // `retireCalendarOperation`'s catch and the in-flight marker
                    // above; Outbox rule 2 ("never `try?` on queue state
                    // transitions") is the stated precedent.
                    do {
                        try await retryWrite(dbPool, label: "CalendarQueue") { db in
                            var updated = currentOp
                            updated.status = PendingStatus.queued.rawValue
                            updated.retryCount += 1
                            try updated.save(db)
                        }
                    } catch {
                        BackgroundSyncLogger.logError(
                            "[CalendarQueue] WARNING: failed to requeue transient op \(currentOp.id) — it stays inFlight until reconcileCalendarQueue at next launch: \(error)",
                            source: "CalendarQueue")
                        print("[CalendarQueue] WARNING: Could not requeue \(currentOp.id) — stays in-flight until next launch: \(error)")
                    }
                    failedAccounts.insert(currentOp.accountId)
                    // Surface the still-queued status so the agent at least
                    // hears "in flight, will retry" rather than blocking until
                    // timeout.
                    signalCalendarOpOutcome(opId: currentOp.id, outcome: .stillQueued)
                }
            }

            if !executedAny { break }
        }
    }

    // MARK: - Operation Execution

    /// Returns the ids the caller needs to thread into the success outcome:
    /// - `newSeriesId` — non-nil after a `this_and_following` split.
    /// - `createdRealId` — non-nil after a successful `.create` (the real id
    ///   the provider assigned, distinct from our optimistic pre-id).
    /// Both nil for every other code path.
    private func executeCalendarOperation(
        _ op: PendingCalendarOperation,
        provider: any CalendarProvider
    ) async throws -> (newSeriesId: String?, createdRealId: String?) {
        let args = op.arguments
        // 🚨 A NORMAL RETURN FROM THIS FUNCTION IS THE DRAIN'S SUCCESS PATH
        // (R12-T8). The three guards below used to `return (nil, nil)` after
        // logging "dropping" — which deletes the row AND fires
        // `signalCalendarOpOutcome(.success(…))`, so the tool told the LLM
        // "Calendar event deleted successfully." for work that never happened.
        // The log said one thing and the mechanism did the opposite.
        //
        // They now throw `CalendarProviderError.notSupported`, which
        // `isCalendarUnsupportedError` claims → the drain RETIRES the row
        // (`status = 'failed'` with a reason, via `retireAndAnnounce`; it used to
        // DELETE it, and this sentence said so until R17-7) and signals
        // `.permanentFailure(reason:)` with this string surfaced to the
        // agent verbatim. Same disposition, honest outcome. This reuses the
        // classification three sibling guards in this very function already use
        // for a malformed persisted request (`edit_scope='…' is not
        // recognized`) rather than adding a parallel one.
        //
        // ⚠️ THE COUNTERFACTUAL, BOTH WAYS.
        //  * `.success` (what it did): lies to the agent and to the user, and is
        //    exit-2 abuse — nothing provider-authoritative said the work was done
        //    or inapplicable.
        //  * A throw the TRANSIENT arm claims (the naive alternative): a
        //    persisted `operationType` that no `CalendarOperationType` recognises
        //    is deterministic, so it would retry forever, and
        //    `failedAccounts.insert` would head-of-line-block every later op on
        //    that account on every drain. That is a wedge — the mirror image, and
        //    in the same non-recoverable set as a dropped intention.
        // The terminal-with-a-reason disposition is the only one that is neither.
        //
        // Reachability today is NONE — every producer is an agent tool passing a
        // typed `CalendarOperationType` and a non-optional `eventId: String`. It
        // is fixed by classification anyway, exactly as `eff3ddd`'s
        // production-unreachable identity refusal was, because "the caller never
        // produces the value" is a property of today's callers, not an invariant.
        guard let type = CalendarOperationType(rawValue: op.operationType) else {
            print("[CalendarQueue] Unknown operation type: \(op.operationType) — retiring as a permanent failure")
            throw CalendarProviderError.notSupported(
                "the queued calendar operation has an unrecognised type '\(op.operationType)' and can never be executed")
        }

        let calId: String
        if let opCalId = op.calendarId {
            calId = opCalId
        } else {
            calId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
        }

        switch type {
        case .create:
            let allDay = CalendarToolHelpers.boolArg(args, "all_day")
            var input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: allDay)
            // Use the pre-generated event id for idempotent retries.
            //
            // ⚠ THIS SAID "(Google only — Exchange ignores it)" UNTIL R13-U8 AND
            // WAS FALSE ON BOTH HALVES. All THREE providers consume it, each in
            // its own idempotency currency, which is why `op.eventId` is set
            // unconditionally rather than per-provider:
            //  - Google — sent as the resource `id` on `events.insert`; a
            //    replay answers 409 `duplicate`, which
            //    `GoogleCalendarProvider.isDuplicateIdConflict` reads as
            //    "already created" (R13-U3; it lived here as
            //    `isGoogleDuplicateIdConflict` until R14-F2 moved it beside the
            //    other cross-provider split helper, because `splitSeries` needs
            //    the same question answered and two spellings drift).
            //  - Exchange — `ExchangeCalendarProvider.createEventJSON` maps it to
            //    Graph's `transactionId` (skipped past 256 chars, which is Graph's
            //    documented cap; over-long simply degrades to non-idempotent).
            //  - CalDAV — `CalDAVProvider.createEvent` uses it as the `.ics`
            //    RESOURCE FILENAME and PUTs with `If-None-Match: *`, so a replay
            //    lands on the same URL and answers 412 instead of duplicating.
            // What none of them does is echo it back as the id we should keep:
            // Google echoes it, Exchange and CalDAV each assign their own, which
            // is what `createdRealId` below exists to capture.
            if let pregenId = op.eventId {
                input.id = pregenId
            }
            var createdRealId: String? = nil
            do {
                let created = try await provider.createEvent(calendarId: calId, event: input, sendUpdates: "all")
                print("[CalendarQueue] Created event id=\(created.id ?? "nil")")
                // Return the real id so the tool can use it in its result
                // string. Without this, the tool's optimistic `event_id:
                // <pregenId>` line is what `processToolOutputForLLM`
                // translates to a numericId — and the subsequent edit/delete
                // sends Graph the pre-id it doesn't recognize (HTTP 400
                // `ErrorInvalidIdMalformed`). Google echoes our pre-id, so
                // realId == pregenId is harmless there; Exchange and CalDAV
                // each assign their own.
                if let realId = created.id, !realId.isEmpty {
                    createdRealId = realId
                }
            } catch GoogleCalendarError.httpError(409, let body)
                        where op.eventId != nil && GoogleCalendarProvider.isDuplicateIdConflict(body) {
                // 🚨 R13-U3 — POSITIVELY IDENTIFIED, not assumed.
                // Google documents exactly two 409s on `events.insert`
                // (developers.google.com/workspace/calendar/api/guides/errors):
                // reason `"duplicate"` — *"The requested identifier already
                // exists"* — and reason `"conflict"`, an `events.batch`
                // operational conflict. Only the first is proof the event is
                // there. Both arms of this `catch` are required: the reason must
                // be `duplicate` AND we must have supplied the id in the first
                // place (`op.eventId != nil` ⇒ `input.id = pregenId` above), or
                // "the identifier already exists" is not a statement about OUR
                // event. Everything else — including a bare 409 with no body —
                // falls through to the drain, which round 12 deliberately
                // classified as indeterminate-and-retryable.
                //
                // Google echoes the client-supplied id back as the event id, so
                // the duplicate's real id IS our pre-generated one. Recording it
                // is what keeps the agent's follow-up edit/delete addressed at the
                // event instead of at a nil id.
                print("[CalendarQueue] Google reports our pre-generated id already exists (409 duplicate) — the create already landed")
                createdRealId = op.eventId
            } catch CalDAVError.preconditionFailed {
                // 412 Precondition Failed — CalDAV idempotent create (If-None-Match: *). Event exists. Success.
                // Positive by construction, unlike the two 409s: the provider sent
                // `If-None-Match: *`, so 412 is the server answering the exact
                // question "does this resource already exist?" with yes.
                print("[CalendarQueue] CalDAV event already exists (412) — treating as success")
            }
            // ⚠️ THERE IS DELIBERATELY NO `catch ExchangeCalendarError.httpError(409, _)`
            // HERE (R13-U3). It existed until 2026-08-06 and converted EVERY Graph
            // 409 into success — deleting the durable row and reporting the create
            // done, with `createdRealId` nil, on an outcome that is not proof of
            // anything. **Microsoft documents no 409 for a repeated
            // `transactionId`.** The `event` resource defines that property as
            // *"a custom identifier specified by a client app for the server to
            // AVOID REDUNDANT POST OPERATIONS in case of client retries"* — i.e. a
            // deduped retry gets the original success response, not a conflict. A
            // 409 from Graph's calendar POST is a store-level save conflict
            // (`ConcurrentItemSave`, `IrresolvableConflict`), which is exactly the
            // *"we could not determine the answer"* that never-drop clause 2 makes
            // retryable — and which round 12 already classified as indeterminate in
            // `isCalendarBadRequestError`. This catch was silently nullifying that.
            //
            // RETRY-SAFETY CLAIM, stated because making an outcome retryable is one
            // (`MIS-005`): the operation newly admitted to retry is the Exchange
            // `.create`, and it is duplicate-safe because `createEventJSON` stamps
            // `transactionId` from the queue's DURABLE `op.eventId` — stable across
            // every retry of one op, distinct for every distinct user create. That
            // is the whole point of `6ace24d7e`; without it this removal would
            // reinstate the duplicate-event exposure R12-T5 closed.
            return (nil, createdRealId)

        case .edit:
            // See the `operationType` guard above for why this throws a
            // TERMINAL-classified error instead of returning (which is success).
            guard let eventId = op.eventId else {
                print("[CalendarQueue] Edit op missing eventId — retiring as a permanent failure")
                throw CalendarProviderError.notSupported(
                    "the queued calendar edit carries no event id and can never be executed")
            }
            let allDay = CalendarToolHelpers.boolArg(args, "all_day")
            // calendar_event_edit-v1.5.21+: attendees are delta-based. If args carries
            // add_attendees or remove_attendees, fetch the current event and resolve the
            // delta against its attendee list before building the update input — so the
            // existing attendees are preserved instead of being overwritten.
            let resolvedArgs = try await resolveAttendeeDelta(
                args: args, eventId: eventId, calendarId: calId, provider: provider
            )
            let input = CalendarToolHelpers.buildGCalEventInput(resolvedArgs, isAllDay: allDay)

            // Route by edit_scope (calendar_event_edit-v1.5.21+). Default: 'all'
            // when no recurrence_id, 'this_only' when recurrence_id is present
            // (back-compat with the earlier schema where recurrence_id alone
            // implied single-occurrence override).
            let explicitScope = CalendarToolHelpers.stringArgOpt(resolvedArgs, "edit_scope")?.lowercased()
            let recurrenceId = CalendarToolHelpers.stringArgOpt(resolvedArgs, "recurrence_id")
            let scope: String = explicitScope
                ?? (recurrenceId != nil ? "this_only" : "all")

            switch scope {
            case "this_only":
                guard let rid = recurrenceId else {
                    throw CalendarProviderError.notSupported("edit_scope='this_only' requires recurrence_id")
                }
                _ = try await provider.updateOccurrence(
                    calendarId: calId, eventId: eventId, recurrenceId: rid,
                    event: input, sendUpdates: "all"
                )
                print("[CalendarQueue] Updated event id=\(eventId) scope=this_only at \(rid)")
            case "this_and_following":
                guard let rid = recurrenceId else {
                    throw CalendarProviderError.notSupported("edit_scope='this_and_following' requires recurrence_id")
                }
                let created = try await provider.splitSeries(
                    calendarId: calId, eventId: eventId, recurrenceId: rid,
                    patch: input, sendUpdates: "all"
                )
                print("[CalendarQueue] Updated event id=\(eventId) scope=this_and_following at \(rid) — new series id=\(created.id ?? "?")")
                // Surface the new series id so `awaitCalendarOpOutcome` can hand
                // it back to the tool — the LLM needs it to address occurrences
                // in the split's second half. Without this, follow-up edits
                // continue to target the master (now truncated) and silently
                // miss for any occurrence on or after `rid`.
                return (created.id, nil)
            case "all":
                _ = try await provider.updateEvent(calendarId: calId, eventId: eventId, event: input, sendUpdates: "all")
                print("[CalendarQueue] Updated event id=\(eventId) scope=all")
            default:
                // Unknown edit_scope value — reject rather than silently defaulting
                // to a series-wide write (which could surprise the user). The
                // schema's enum should prevent this; this is defense-in-depth.
                throw CalendarProviderError.notSupported("edit_scope='\(scope)' is not recognized — must be 'all', 'this_only', or 'this_and_following'")
            }

        case .delete:
            // See the `operationType` guard above. This one matters most: a
            // `.success` here told the agent "Calendar event deleted
            // successfully." for a delete that never reached the wire.
            guard let eventId = op.eventId else {
                print("[CalendarQueue] Delete op missing eventId — retiring as a permanent failure")
                throw CalendarProviderError.notSupported(
                    "the queued calendar delete carries no event id and can never be executed")
            }
            try await provider.deleteEvent(calendarId: calId, eventId: eventId, sendUpdates: "all")
            print("[CalendarQueue] Deleted event id=\(eventId)")
        }
        return (nil, nil)
    }

    // MARK: - Attendee Delta Resolution (calendar_event_edit-v1.5.21)

    /// When `args` carries `add_attendees` / `remove_attendees`, fetch the current event
    /// and resolve the delta against its attendee list. Returns a copy of `args` with a
    /// flat `attendees` array — which is what `buildGCalEventInput` consumes.
    /// If neither delta key is present, returns `args` unchanged. If the fetch fails
    /// (offline, transient), throws — the caller's retry path keeps the op queued.
    private func resolveAttendeeDelta(
        args: [String: JSONValue],
        eventId: String,
        calendarId: String,
        provider: any CalendarProvider
    ) async throws -> [String: JSONValue] {
        let hasAdds = args["add_attendees"] != nil
        let hasRemoves = args["remove_attendees"] != nil
        guard hasAdds || hasRemoves else { return args }

        let adds = CalendarToolHelpers.parseAttendeeAdds(args["add_attendees"])
        let removes = CalendarToolHelpers.parseAttendeeRemoves(args["remove_attendees"])

        // If the LLM emitted the delta keys but they're empty after parsing
        // (e.g. `add_attendees: []`, or all entries filtered out for missing
        // email), there's no change to apply. Strip the keys without fetching
        // the event — otherwise we'd needlessly re-write the same attendee
        // list, which under sendUpdates="all" re-notifies every existing
        // attendee.
        if adds.isEmpty && removes.isEmpty {
            var out = args
            out.removeValue(forKey: "add_attendees")
            out.removeValue(forKey: "remove_attendees")
            return out
        }

        let current = try await provider.getEvent(calendarId: calendarId, eventId: eventId)
        let base: [(email: String, name: String?)] = (current.attendees ?? []).compactMap { att in
            guard let raw = att.email, !raw.isEmpty else { return nil }
            return (email: CalendarToolHelpers.stripMailto(raw), name: att.displayName)
        }
        let merged = CalendarToolHelpers.applyAttendeeDelta(base: base, adds: adds, removes: removes)

        let mergedJSON: [JSONValue] = merged.map { entry in
            var dict: [String: JSONValue] = ["email": .string(entry.email)]
            if let name = entry.name, !name.isEmpty { dict["name"] = .string(name) }
            return .dictionary(dict)
        }
        var out = args
        out["attendees"] = .array(mergedJSON)
        // Strip the delta keys so downstream code only sees the resolved list.
        out.removeValue(forKey: "add_attendees")
        out.removeValue(forKey: "remove_attendees")
        print("[CalendarQueue] Resolved attendee delta: base=\(base.count) +\(adds.count) -\(removes.count) → \(merged.count)")
        return out
    }

    // MARK: - Error Classification

    /// `CalendarProviderError.notSupported` is permanent for the chosen provider —
    /// no retry will help (Exchange / CalDAV / Demo simply don't implement the
    /// recurring-occurrence + split paths yet). The drain loop RETIRES the op —
    /// `status = 'failed'` with a reason, not a delete (R16-1); either way the
    /// user's queued work never executes — and surfaces the message to the LLM so
    /// it can either pivot (e.g. propose a
    /// whole-series edit) or relay the limitation to the user.
    /// The **six** error classifiers below — predicate, so it can be re-derived
    /// rather than trusted: every `static func …(_ error: Error) -> Bool` between
    /// this line and `isCalendarBadRequestError`, i.e.
    /// `rg -c 'static func is[A-Za-z]+\(_ error: Error\) -> Bool'` over this file
    /// minus `isCalendarBadRequestError` itself, which the sentence names
    /// separately. It read "four" until 2026-08-06, having been written when there
    /// were four and never re-derived as arms were added (R16-7; a sentence that
    /// enumerates is a cache, and a cache with no invalidation is a lie with a
    /// delay). They are `static` (hence nonisolated) for the same
    /// reason `isCalendarBadRequestError` is: the drain's disposition can then be
    /// asserted in tests against real provider error values, rather than inferred
    /// from the drain loop's side effects.
    ///
    /// ⚠️ **FOUR OF THE SIX ANSWER ONE QUESTION; TWO ANSWER A DIFFERENT ONE
    /// (R17-7).** This read *"Every one of them answers the same system-level
    /// question — does SOME terminal arm claim this error?"*, which R16-7 left
    /// standing when it correctly widened the COUNT from four to six. The count was
    /// right and the absolute was wrong, and the exception is not incidental:
    /// `isCalendarOAuthReauthRequired` and `isCalDAVAuthError` answer *"must the
    /// user be told to sign in again?"* — the SIGNAL question, not the DISPOSITION
    /// question — and this same file says 150 lines below that collapsing those two
    /// questions *"is what made the R14-F4 wedge invisible"*. Re-derive rather than
    /// trust: a classifier belongs to the disposition set iff it appears in
    /// `claimedByATerminalArm`'s roster in
    /// `TabMailTests/Queues/CalendarBadRequestClassificationTests.swift`; the other
    /// two are read only for `markAuthFailed` (:432) and for the
    /// `caldavConfig.needsReauth` rider (:481).
    ///
    /// For the FOUR that do answer *does SOME terminal arm claim this error?*, an
    /// error no arm claims falls through to the transient arm, which requeues it
    /// and inserts the account into `failedAccounts`, head-of-line-blocking every
    /// later op on that account on every subsequent drain. That starvation is a
    /// wedge, and the wedge corollary sits in the same non-recoverable set as a
    /// dropped intention — it never recovers via sync.
    static func isCalendarUnsupportedError(_ error: Error) -> Bool {
        if case CalendarProviderError.notSupported = error { return true }
        return false
    }

    private func unsupportedReason(_ error: Error) -> String {
        if case CalendarProviderError.notSupported(let msg) = error { return msg }
        return "operation not supported on this calendar provider"
    }

    /// ⚠️ **THE DEMO PROVIDER IS A PROVIDER (R15-FIX-4).** `DemoCalendarProvider` is
    /// registered into `calendarProviders` by `AccountManager.registerDemoProviders`
    /// (from `DemoModeService`), so it reaches this drain exactly as Google,
    /// Exchange and CalDAV do — and until R15-FIX-4 its "this event does not exist"
    /// was spelled `DemoError.startFailed("event not found")`, which NO terminal arm
    /// claimed. A stale edit therefore wedged the account's whole calendar lane, the
    /// mirror-image shape R12-T8's banner on `executeCalendarOperation` already
    /// names as a defect class.
    ///
    /// 🚨 **ONLY `.eventNotFound` IS CLAIMED, AND THAT NARROWNESS IS THE FIX.**
    /// `DemoError.startFailed` also carries indeterminate demo *initialization*
    /// failures and `.notInDemo` means the database was not up; both are *"we could
    /// not determine the answer"* and stay retryable forever under never-drop clause
    /// 2. Blanket-claiming `DemoError` is the over-correction and must not ship —
    /// the same reasoning, and the same shape, as `isGrantLevelOAuthFailure`'s
    /// deliberately exact three OAuth codes below.
    static func isCalendarNotFoundError(_ error: Error) -> Bool {
        if case GoogleCalendarError.httpError(404, _) = error { return true }
        if case GoogleCalendarError.eventNotFound = error { return true }
        if case ExchangeCalendarError.httpError(404, _) = error { return true }
        if case ExchangeCalendarError.eventNotFound = error { return true }
        if case CalDAVError.notFound = error { return true }
        if case DemoError.eventNotFound = error { return true }
        return false
    }

    /// ⚠️ THE TYPED `.missingScope` IS NOT THE ONLY SPELLING (R12-T1, 2026-08-06).
    /// `GoogleCalendarProvider.request` / `ExchangeCalendarProvider.request` map a
    /// 403 to the typed case only on the FIRST response. When the first response
    /// was a 401, both force a token refresh and re-issue, and the retry's status
    /// is rethrown RAW — `throw GoogleCalendarError.httpError(retry.statusCode, retry.errorBody)`.
    /// So a 401-then-403 arrives here as `httpError(403, …)`, which the typed
    /// match cannot see and which `isCalendarBadRequestError` deliberately excludes
    /// (403 is not a malformed payload). Before this arm covered the raw form, that
    /// error was claimed by NO terminal arm and wedged the account's calendar lane.
    ///
    /// ⚠️ **THE PAYLOAD USED TO BE A LITERAL `nil` ON BOTH REFRESH-RETRY ARMS, AND
    /// IS NOT ANY MORE (R14-F1).** The arms match `_` on the payload, so the change
    /// is inert HERE — but the sentence above named the `nil` explicitly, and every
    /// classifier that DOES read the payload (`GoogleCalendarProvider.isDuplicateIdConflict`,
    /// `badRequestReason`, `parseHttpReason`) was receiving `nil` on **every**
    /// non-2xx, refresh-retry or not: `performHTTPRequest` returns `data: nil` for
    /// any non-2xx and puts the server's bytes in `errorBody`, and both providers
    /// threw `result.data`. Which arm carries what, stated so no future reader has
    /// to re-derive it: **first response and refresh-retry both carry the server's
    /// raw body now; neither carries `nil` unless the response body was empty.**
    static func isCalendarMissingScopeError(_ error: Error) -> Bool {
        if case GoogleCalendarError.missingScope = error { return true }
        if case ExchangeCalendarError.missingScope = error { return true }
        if case GoogleCalendarError.httpError(403, _) = error { return true }
        if case ExchangeCalendarError.httpError(403, _) = error { return true }
        return false
    }

    /// An authentication failure that no amount of retrying can clear — the user
    /// must re-authenticate.
    ///
    /// - **CalDAV:** `CalDAVError.authFailed`, raised by `CalDAVClient` on a 401.
    ///   The stored credentials are rejected outright; there is no refresh to try.
    /// - **Google / Exchange:** a raw `httpError(401, …)`.
    ///
    /// ⚠️ **THE COUNTERFACTUAL — why treating a Google/Exchange 401 as PERMANENT
    /// does not break ordinary token refresh, and what would make it start
    /// breaking it.** Treating the *first* 401 as permanent WOULD break refresh:
    /// an expired access token is the ordinary, expected cause of a 401 and is
    /// cleared by minting a new one. The first 401 never reaches this classifier.
    /// `GoogleCalendarProvider.request` and `ExchangeCalendarProvider.request` both
    /// intercept it, call `accessToken(true)` to FORCE a refresh, re-issue the
    /// request with the fresh token, and only then rethrow — as
    /// `httpError(retry.statusCode, retry.errorBody)` (a literal `nil` until
    /// R14-F1; the payload is irrelevant to this arm, which matches `_`). So a 401
    /// arriving here is the SECOND one, observed with a token minted seconds
    /// earlier: the grant itself is revoked/expired, and every future drain
    /// reproduces it identically.
    ///
    /// **This safety rests entirely on that provider behaviour.** If either
    /// `request` ever stops force-refreshing before rethrowing — or a new calendar
    /// provider is added whose first 401 reaches the queue raw — this arm starts
    /// retiring ops that a token refresh would have fixed. Re-read both `request`
    /// implementations before changing this.
    /// - **Google / Exchange, token ACQUISITION (R14-F4):** an
    ///   `OAuthError.tokenExchangeFailed` whose payload is a GRANT-LEVEL OAuth 2.0
    ///   error code. See `isGrantLevelOAuthFailure` — it is a positively parsed
    ///   reason, never a bare failure, exactly as
    ///   `GoogleCalendarProvider.isDuplicateIdConflict` reads Google's 409 body
    ///   rather than trusting the status.
    static func isCalendarAuthError(_ error: Error) -> Bool {
        if case CalDAVError.authFailed = error { return true }
        if case GoogleCalendarError.httpError(401, _) = error { return true }
        if case ExchangeCalendarError.httpError(401, _) = error { return true }
        if case OAuthError.tokenExchangeFailed(let reason) = error {
            return isGrantLevelOAuthFailure(reason)
        }
        return false
    }

    /// The OAuth 2.0 token-endpoint `error` codes (RFC 6749 §5.2) that describe a
    /// GRANT the server has positively refused, as opposed to a token endpoint that
    /// merely could not answer.
    ///
    /// `GoogleAuthService.refreshGoogleToken` and
    /// `MicrosoftAuthService.refreshMicrosoftToken` both raise
    /// `OAuthError.tokenExchangeFailed(response.error ?? "unknown")`, so the payload
    /// is the server's own machine-readable code — the same evidence standard the
    /// calendar queue already applies to Google's 409 bodies.
    ///
    /// 🚨 **DELIBERATELY EXACT-MATCH AND DELIBERATELY THREE.** This predicate is the
    /// gate on a TERMINAL arm, and a terminal arm RETIRES the user's queued calendar
    /// operation — `status = 'failed'` with a reason since R16-1, not the delete this
    /// sentence asserted until R17-7. The row survives for diagnostics and is
    /// reclaimed after `SyncConfig.retiredCalendarOpRetentionDays`; what does NOT
    /// survive is the work, which never executes. So every value added here is still
    /// an intention that leaves the queue unexecuted — the harm the sentence was
    /// written to guard is unchanged, only its mechanism was.
    /// `temporarily_unavailable`, `server_error`, a 5xx, a dropped connection and the
    /// `"unknown"` fallback (a body with no `error` key at all) are all *"we could not
    /// determine the answer"*, which never-drop clause 2 makes retryable forever —
    /// blanket-terminalizing `tokenExchangeFailed` is the mirror image of this fix and
    /// must not be shipped. `invalid_scope` and `unsupported_grant_type` are permanent
    /// too but describe a REQUEST this client got wrong rather than a dead grant; they
    /// are left retryable because a wrong request is our bug to fix in a release, not
    /// the user's intention to discard.
    static func isGrantLevelOAuthFailure(_ reason: String) -> Bool {
        switch reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "invalid_grant", "invalid_client", "unauthorized_client": return true
        default: return false
        }
    }

    /// True when the error proves the account's OAuth credential can no longer be
    /// obtained or used, so the user has to re-authenticate — **independent of
    /// whether the queued operation is retired.**
    ///
    /// 🚨 **THE SIGNAL AND THE DISPOSITION ARE DIFFERENT QUESTIONS, and this
    /// predicate exists because collapsing them is what made the R14-F4 wedge
    /// invisible.** `isCalendarAuthError` answers *"may this op leave the queue?"*.
    /// This answers *"must the user be told to sign in again?"*.
    ///
    /// ⚠️ **THE TWO SETS ARE INCOMPARABLE, NOT NESTED (R16-10).** This doc claimed
    /// "a strictly larger set" and was wrong in both directions; re-derive it from
    /// the two arm lists rather than trusting either sentence:
    ///   * signal ∖ terminal = `ProviderError.authenticationFailed` — deliberately
    ///     retryable (see below), so it raises the prompt without retiring the op.
    ///   * terminal ∖ signal = `CalDAVError.authFailed` — retired without going
    ///     through THIS predicate, because CalDAV's persistent signal is the
    ///     `caldavConfig.needsReauth` write in the same arm rather than
    ///     `authFailedAccounts`.
    /// Both halves shared: the two raw 401s and the three grant-level OAuth codes.
    /// The behaviour is correct; the SENTENCE was the problem, and it was copied
    /// verbatim into `KNOWN_ISSUES.md`, where a reviewer read it as evidence that
    /// signal coverage had been checked. It is what hid the missing-scope arm's
    /// silence (R16-5) for a whole round.
    ///
    /// ⚠️ **`ProviderError.authenticationFailed` IS DELIBERATELY NOT TERMINAL, and
    /// the round-14 brief's claim that it "is unambiguous and can be claimed
    /// directly" was refuted in the tree.** `OAuthRefreshCoordinator.refresh` raises
    /// it from exactly two guards:
    ///   1. `guard !invalidated` — the account was removed. Those ops cannot wedge
    ///      anything: `pendingCalendarOperation.accountId` is declared
    ///      `.references("account", onDelete: .cascade)`, one of the 10 live
    ///      cascading foreign keys, so deleting the account already deleted them.
    ///   2. `guard let refreshToken = KeychainHelper.loadString(…)` — and
    ///      `KeychainHelper.load` returns `nil` for **any** `SecItemCopyMatching`
    ///      failure, not only "the token is gone". That is an ABSENCE OF EVIDENCE,
    ///      i.e. never-drop clause 2's *"we could not determine the answer"*, which
    ///      is retryable forever and is never a provider-authoritative refusal.
    /// Terminalizing it would trade a wedge that ONE ordinary user gesture clears —
    /// re-authenticate, prompted by the very signal this predicate raises — for a
    /// permanently dropped intention, which nothing recovers. The asymmetry is the
    /// whole argument; see `THE MANTRA` in `CLAUDE.md`.
    static func isCalendarOAuthReauthRequired(_ error: Error) -> Bool {
        if case GoogleCalendarError.httpError(401, _) = error { return true }
        if case ExchangeCalendarError.httpError(401, _) = error { return true }
        if case ProviderError.authenticationFailed = error { return true }
        if case OAuthError.tokenExchangeFailed(let reason) = error {
            return isGrantLevelOAuthFailure(reason)
        }
        return false
    }

    /// The reason string the drain surfaces to the agent and, through it, to the
    /// user when an auth failure retires a calendar operation.
    ///
    /// Each arm of `isCalendarAuthError` describes a DIFFERENT failure and this
    /// string is shown verbatim, so they cannot share one sentence. The text used to
    /// be a two-way ternary whose OAuth branch asserted *"the account's access was
    /// refused again after a token refresh"* — true of a post-refresh 401 and false
    /// of a token that was never minted at all, which is the case R14-F4 added.
    static func calendarAuthFailureReason(_ error: Error) -> String {
        if case CalDAVError.authFailed = error {
            return "CalDAV authentication failed — user must re-authenticate in Settings"
        }
        if case OAuthError.tokenExchangeFailed(let reason) = error {
            return "calendar authentication failed (the account's saved sign-in was rejected by the provider: \(reason)) — user must re-authenticate in Settings"
        }
        return "calendar authentication failed (the account's access was refused again after a token refresh) — user must re-authenticate in Settings"
    }

    /// True only for the CalDAV spelling of an auth failure. CalDAV accounts own a
    /// `caldavConfig` row whose `needsReauth` column is the persistent, user-visible
    /// signal (`ToolSettingsView` reads it); OAuth accounts have no such row, so the
    /// drain must not issue an `UPDATE` that silently matches zero rows and reads as
    /// "we marked it".
    static func isCalDAVAuthError(_ error: Error) -> Bool {
        if case CalDAVError.authFailed = error { return true }
        return false
    }

    /// HTTP 400 / 422 / 415 — the request itself is malformed. Retrying with
    /// the same payload can never succeed, so we retire the op rather than
    /// clogging the queue indefinitely.
    ///
    /// ⚠️ **THIS USED TO SAY "Logged loudly so the user can see what happened" AND
    /// IT WAS FALSE (R16-10).** Until 2026-08-06 this file had 39 raw `print`s and
    /// ZERO calls to `BackgroundSyncLogger` / `DebugLogView` / `DebugModeManager`
    /// (`rg -c 'BackgroundSyncLogger|DebugLogView|DebugModeManager'` over the file:
    /// rc=1, no match), so nothing here reached any surface a user can open. It
    /// mattered beyond tidiness: this sentence and its twin on the bad-request arm
    /// were the stated discharge of the "the user is told" half of the argument that
    /// licensed every terminal drop in this file, and a reviewer who read them
    /// concluded the user had a channel. `retireCalendarOperation` now writes the
    /// retirement to `BackgroundSyncLogger.logError`, whose Error Log
    /// `DebugLogView` renders, so the claim is true where it is made — and the
    /// durable `PendingStatus.failed` row, not the log line, is what actually holds
    /// the intention.
    ///
    /// ⚠️ INDETERMINATE 4xx CODES ARE NOT AUTHORITATIVE (R11-C, 2026-08-06).
    /// `CLAUDE.md`'s never-drop clause 2 retires an op only on a
    /// PROVIDER-AUTHORITATIVE stale/no-op result; *"we could not determine the
    /// answer"* is retryable, never authoritative. `408 Request Timeout`,
    /// `409 Conflict`, `423 Locked` and `425 Too Early` are all of the second
    /// kind — the server is telling us to come back, not that the payload is
    /// broken — so they are excluded from ALL THREE arms and fall through to the
    /// transient/retry arm, exactly where `429` already goes. `423 Locked` is the
    /// WebDAV-native transient code, which is why the CalDAV arm needs the
    /// exclusion most even though its blanket-4xx shape looks deliberate.
    ///
    /// ⚠️ NEGATIVE CASE — the classifier itself STAYS. A genuinely malformed
    /// 400/415/422 that retried forever would wedge the calendar lane, and a wedge
    /// (an op that starves and never recovers) is in the same non-recoverable set
    /// as a dropped intention. The fix narrows the code set; deleting the arm
    /// would be the mirror image of the bug.
    /// `static` (hence nonisolated) so the classification can be table-driven in
    /// tests against real provider error values rather than inferred from the
    /// drain loop's side effects.
    static func isCalendarBadRequestError(_ error: Error) -> Bool {
        // Indeterminate — "come back later", not "your payload is broken".
        // Shared by all three arms so they cannot drift apart.
        func isIndeterminate(_ code: Int) -> Bool {
            code == 408 || code == 409 || code == 423 || code == 425 || code == 429
        }
        if case GoogleCalendarError.httpError(let code, _) = error, (400...499).contains(code), code != 401 && code != 403 && code != 404 && !isIndeterminate(code) { return true }
        if case ExchangeCalendarError.httpError(let code, _) = error, (400...499).contains(code), code != 401 && code != 403 && code != 404 && !isIndeterminate(code) { return true }
        // CalDAV: 401/404/412 already map to dedicated cases (authFailed /
        // notFound / preconditionFailed). Everything else in 4xx arrives here
        // as `httpError(code, body)`. iCloud returns an opaque 403 for many
        // policy violations (adding ATTENDEEs without ORGANIZER, writing to
        // a shared calendar without permission, etc.) — retrying never
        // succeeds, and a stuck retry loop holds up the drain for ALL
        // subsequent ops on the same account (the user sees the chat hang
        // because the next queued create's `awaitCalendarOpOutcome` times
        // out behind it). Treat all unclassified CalDAV 4xx as permanent.
        if case CalDAVError.httpError(let code, _) = error, (400...499).contains(code), !isIndeterminate(code) { return true }
        // A persisted Graph id that cannot be expressed as one strict path
        // segment (R13-U7). Added by the v3 range together with the strict
        // encoder and claimed by NO arm until 2026-08-06. It is a pure function
        // of the stored id — `GraphAPI.encodedGraphPathSegment` is a single
        // `addingPercentEncoding` call with a fixed allowed set — so every
        // retry reproduces it identically and the account's lane wedges. It can
        // never be transient, which is what makes the terminal classification
        // free: there is no population this newly retires that a retry would
        // have fixed. Practically unreachable today (`addingPercentEncoding`
        // returns nil only for invalid Unicode, which a Swift `String` cannot
        // hold), and classified anyway on this file's own stated precedent —
        // *"the caller never produces the value" is a property of today's
        // callers, not an invariant.*
        if case ExchangeCalendarError.invalidPathSegment = error { return true }
        // Google's sibling of the same refusal (R13-U1). Different mechanism —
        // Google keeps `.urlPathAllowed` and rejects on the ENCODED result's
        // structure (a `/` or a dot-segment, i.e. an id that would not stay in one
        // path segment) — but the same disposition and for the same reason: the
        // check is a pure function of the stored id, so it can never be transient.
        // Enumerated by the PROPERTY "an id refused before the request is formed",
        // not by provider name, which is how the Exchange half was missed for a
        // round (`MIS-007`). CalDAV's third sibling is deliberately NOT here: its
        // origin-containment refusal throws `CalendarProviderError.notSupported`,
        // already claimed by `isCalendarUnsupportedError` at the arm above.
        if case GoogleCalendarError.invalidPathSegment = error { return true }
        return false
    }

    /// Best-effort extract of the server's reason string from a 4xx so the LLM
    /// has something concrete to react to (e.g. "Missing end time"). Falls back
    /// to a code-only summary when the body is empty or unparseable.
    private func badRequestReason(_ error: Error) -> String {
        if case ExchangeCalendarError.invalidPathSegment(let context) = error {
            return "the stored \(context) cannot be expressed as a URL path segment, so this request can never be sent — the event id needs to be re-read from the server"
        }
        if case GoogleCalendarError.invalidPathSegment(let context) = error {
            return "the stored \(context) cannot be expressed as a single URL path segment, so this request can never be sent — the event id needs to be re-read from the server"
        }
        if case GoogleCalendarError.httpError(let code, let body) = error {
            return parseHttpReason(code: code, body: body, source: "Google Calendar")
        }
        if case ExchangeCalendarError.httpError(let code, let body) = error {
            return parseHttpReason(code: code, body: body, source: "Exchange Calendar")
        }
        if case CalDAVError.httpError(let code, let body) = error {
            let bodyStr = body.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !bodyStr.isEmpty {
                return "CalDAV HTTP \(code): \(bodyStr.prefix(300))"
            }
            // iCloud frequently returns 403 with an empty body. Surface a
            // pointer at the common causes so the agent can suggest the right
            // remedy to the user instead of just "it failed."
            if code == 403 {
                return "CalDAV HTTP 403 — the server refused the write. Common iCloud causes: (1) the event is on a shared calendar where you can't add attendees, (2) the event has an ATTENDEE but no ORGANIZER, (3) iCloud's iTIP scheduler rejected an attendee on an external domain."
            }
            return "CalDAV HTTP \(code)"
        }
        return "calendar API rejected the request: \(error)"
    }

    private func parseHttpReason(code: Int, body: Data?, source: String) -> String {
        guard let body, !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return "\(source) HTTP \(code)"
        }
        // Google: { "error": { "message": "...", "errors": [{ "message": "..." }] } }
        if let err = json["error"] as? [String: Any] {
            if let msg = err["message"] as? String, !msg.isEmpty {
                return "\(source) HTTP \(code): \(msg)"
            }
            if let arr = err["errors"] as? [[String: Any]],
               let first = arr.first?["message"] as? String, !first.isEmpty {
                return "\(source) HTTP \(code): \(first)"
            }
        }
        return "\(source) HTTP \(code)"
    }

    // MARK: - Crash Recovery

    /// Reset inFlight calendar ops back to queued on app launch. Called from reconcilePendingOperations.
    func reconcileCalendarQueue() async {
        do {
            try await dbPool.write { db in
                let staleOps = try PendingCalendarOperation
                    .filter(Column("status") == PendingStatus.inFlight.rawValue)
                    .fetchAll(db)
                if !staleOps.isEmpty {
                    print("[CalendarQueue] Crash recovery: resetting \(staleOps.count) inFlight calendar ops to queued")
                    for op in staleOps {
                        var updated = op
                        updated.status = PendingStatus.queued.rawValue
                        try updated.save(db)
                    }
                }
            }
        } catch {
            print("[CalendarQueue] ERROR: reconcileCalendarQueue failed: \(error)")
        }
        await drainCalendarQueue()
    }
}
