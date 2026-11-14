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
            var outcome = await group.next() ?? .timedOut
            // If the timeout fired first, drop the still-pending continuation
            // so the drain doesn't try to resume a stale waiter. When the drain
            // took it first (it signalled between the timeout and this line), its
            // outcome is the answer: `signalCalendarOpOutcome` has already told the
            // drain this caller heard it, and a failure the drain counts as seen
            // must reach the card (`retireAndAnnounce`).
            if case .timedOut = outcome, !self.dropCalendarOpAwaiter(opId: opId) {
                outcome = await group.next() ?? .timedOut
            }
            group.cancelAll()
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
    ///
    /// Returns whether it found the continuation; `false` means a signal took it first.
    private func dropCalendarOpAwaiter(opId: String) -> Bool {
        guard let cont = calendarOpAwaiters.removeValue(forKey: opId) else { return false }
        cont.resume(returning: .timedOut)
        return true
    }

    /// Drain-side notification: resolve any pending awaiter for `opId` with
    /// `outcome`. No-op if no one is waiting.
    ///
    /// 🚨 **THE RETURN VALUE IS THE POINT (R16-1).** This used to return `Void` and
    /// no caller could tell a delivered outcome from one that reached nobody — which
    /// is why the silent case survived so long. Enumerate the drain's SIX production
    /// triggers and only ONE of them (`queueCalendarOperation`'s
    /// `Task { await drainCalendarQueue() }`) is causally paired with an awaiter
    /// registration; `reconcilePendingOperations`, both `NetworkMonitor` arms and both
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
    /// `AppDatabase.init`'s `inFlight` reset, so it can never be re-executed
    /// and can never starve a later op.
    ///
    /// The write is the SAME write that used to delete, so the retirement cannot
    /// outrun its own record. If it throws, the row stays `inFlight`, launch
    /// database recovery can return it to `queued` on a later successful launch
    /// recovery. A persistent storage failure leaves the intention retained.
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
    /// will appear shortly" — still pending, with recovery attempted at the next launch.
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
    /// ⚠️ **THIS TOOK A `caldavReauthAccountId` UNTIL ROUND 18, AND ITS DOC SAID THE
    /// RIDER CARRIED *"the persistent signal that makes it recoverable"*. THAT WAS
    /// FALSE IN BOTH HALVES.** The rider ran
    /// `UPDATE caldavConfig SET needsReauth = 1` in this transaction; nothing ever
    /// cleared that column, its only reader was `AccountManager.createCalDAVProvider`'s
    /// early `return nil`, and no UI read it at all (`CalendarPickerModel`'s
    /// `needsReauth` is a DIFFERENT symbol — a local `AccountEntry` field written
    /// from a live `listCalendars()` probe). So the rider did not make anything
    /// recoverable; it made the account's whole calendar lane UNrecoverable, by
    /// removing the account from `calendarProviders` — which both starved every op
    /// queued on it (`drainCalendarQueue`'s `guard let calProvider … else
    /// { continue }`) and removed the account from the calendar picker, where the
    /// one working re-auth prompt lives. Removed in round 18; see the banner on
    /// `AccountManager.createCalDAVProvider` for the full chain, and
    /// `CalDAVReauthWedgeTests` for the pin.
    private func retireCalendarOperation(
        _ op: PendingCalendarOperation,
        reason: String,
        kind: CalendarFailureKind
    ) async -> Bool {
        BackgroundSyncLogger.logError(
            "[CalendarQueue] TERMINAL \(op.operationType) op=\(op.id) account=\(op.accountId) event=\(op.eventId ?? "new"): \(reason)",
            source: "CalendarQueue")
        do {
            try await retryWrite(dbPool, label: "CalendarQueue") { db in
                guard var row = try PendingCalendarOperation.fetchOne(db, key: op.id) else { return }
                row.status = PendingStatus.failed.rawValue
                row.failureReason = reason
                row.setReservedArguments([PendingCalendarOperation.failureKindKey: .string(kind.rawValue)])
                try row.update(db)
            }
            return true
        } catch {
            // The row stays `inFlight`; `AppDatabase.init` attempts to return it
            // to `queued` at next launch. Recorded, not silent —
            // and reported, so no caller announces `.permanentFailure` over it.
            BackgroundSyncLogger.logError(
                "[CalendarQueue] FAILED to record terminal outcome for op \(op.id) — it will be retried: \(error)",
                source: "CalendarQueue")
            BackgroundSyncLogger.logDebug("[CalendarQueue] Failed to record terminal outcome for op \(op.id): \(error)")
            return false
        }
    }

    /// The single terminal-announcement gate: signal `.permanentFailure` when the
    /// retirement committed, and the truthful `.stillQueued` when it did not.
    ///
    /// 🚨 R17-2 — ALL THE TERMINAL ARMS ROUTE THROUGH THIS (six at R17-2, five since #601
    /// removed the `inconsistentState` arm), so the producer's
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
    ///
    /// A committed retirement then goes to exactly one place the user sees it. When the
    /// tool that queued it was still waiting, it got `.permanentFailure` and turned its
    /// card red, so the row is marked seen (`PendingCalendarOperation.failureSeenKey`) and
    /// stays `failed` as the record of the failure. When nobody was waiting (the chat turn
    /// had ended, or another trigger ran the drain), the inbox shows it until the user
    /// dismisses it (`LateCalendarFailureStore`).
    private func retireAndAnnounce(
        _ op: PendingCalendarOperation,
        reason: String,
        kind: CalendarFailureKind
    ) async {
        let retired = await retireCalendarOperation(op, reason: reason, kind: kind)
        let told = signalCalendarOpOutcome(
            opId: op.id,
            outcome: retired ? .permanentFailure(reason: reason) : .stillQueued)
        guard retired else { return }
        if told {
            do {
                try await retryWrite(dbPool, label: "CalendarQueue") { db in
                    guard var row = try PendingCalendarOperation.fetchOne(db, key: op.id) else { return }
                    row.setReservedArguments([PendingCalendarOperation.failureSeenKey: .bool(true)])
                    try row.update(db, columns: ["argumentsJSON"])
                }
            } catch {
                // The row stays unseen, so the inbox also shows a failure the card
                // already showed: shown twice, never lost.
                BackgroundSyncLogger.logError(
                    "[CalendarQueue] failed to mark op \(op.id) seen after its card showed the failure — the inbox will show it too: \(error)",
                    source: "CalendarQueue")
            }
        } else {
            await LateCalendarFailureStore.shared.reload()
        }
    }

    /// Keep a split's `SplitRecord` on its queued operation (#601): `splitSeries` calls it once
    /// the new part's create is confirmed, and writes the cap only after it returns. The row is
    /// read again and only its `argumentsJSON` is written, with the record under
    /// `SplitRecord.argumentKey` and every other argument as stored. Throws when the row is gone
    /// or can't be written, so the cap is not written: a retry runs the split again, and the
    /// calendar's own answer for the new part it already made decides it there.
    func recordSplit(opId: String, _ record: SplitRecord) async throws {
        try await updateSplitArguments(opId: opId) { object in
            object[SplitRecord.argumentKey] = record.jsonObject
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Recorded split of \(record.seriesId) at \(record.splitAt) on op \(opId)")
        }
    }

    /// The split's `SplitRecorder.partNotFound` (#601): the calendar answered "not found" for a
    /// new part it had reported as already created. Keeps the time of the first such answer on
    /// the operation (`SplitRecord.partNotFoundSinceKey`, written the first time only) and
    /// returns how long ago it was. Throws as `recordSplit` does when the row is gone or can't
    /// be written.
    func noteSplitPartNotFound(opId: String) async throws -> TimeInterval {
        let now = Date()
        let first = try await updateSplitArguments(opId: opId) { object -> Date in
            if let since = object[SplitRecord.partNotFoundSinceKey] as? Double {
                return Date(timeIntervalSince1970: since)
            }
            object[SplitRecord.partNotFoundSinceKey] = now.timeIntervalSince1970
            return now
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Split's new part not found on op \(opId), first at \(first)")
        }
        return now.timeIntervalSince(first)
    }

    /// Reads the queued operation `opId` again, applies `change` to its arguments, and writes
    /// back only its `argumentsJSON`, every other argument as stored. Throws when the row is
    /// gone or its arguments can't be read or written.
    private func updateSplitArguments<T: Sendable>(
        opId: String,
        _ change: @escaping @Sendable (inout [String: Any]) -> T
    ) async throws -> T {
        try await retryWrite(dbPool, label: "CalendarQueue") { db in
            // A row that is gone fails the split before its cap with an error no terminal arm
            // claims; the requeue then finds no row and writes nothing.
            guard var row = try PendingCalendarOperation.fetchOne(db, key: opId) else {
                throw SplitRecord.OperationGone()
            }
            guard let data = row.argumentsJSON.data(using: .utf8),
                  var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CalendarProviderError.notSupported("the queued calendar edit's arguments can't be read, so its split was not finished")
            }
            let result = change(&object)
            let merged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: merged, encoding: .utf8) else {
                throw CalendarProviderError.notSupported("the queued calendar edit's arguments can't be written, so its split was not finished")
            }
            row.argumentsJSON = text
            try row.update(db, columns: ["argumentsJSON"])
            return result
        }
    }

    // MARK: - Calendar Operation Queue

    /// Queue a calendar mutation for async execution.
    /// Persists the operation to GRDB before returning — survives crashes/kills.
    /// `SplitRecord.argumentKey` and `SplitRecord.partNotFoundSinceKey` are reserved for the
    /// queue (`recordSplit`, `noteSplitPartNotFound`); a tool call that carries them has them
    /// removed here. `eventTitle` is the title the confirmation card showed; it names the
    /// event if the change fails after the chat turn (`LateCalendarFailureStore`).
    func queueCalendarOperation(
        type: CalendarOperationType,
        accountId: String,
        eventId: String? = nil,
        calendarId: String? = nil,
        arguments: [String: JSONValue],
        eventTitle: String
    ) async throws -> PendingCalendarOperation {
        var arguments = arguments
        arguments.removeValue(forKey: SplitRecord.argumentKey)
        arguments.removeValue(forKey: SplitRecord.partNotFoundSinceKey)
        let op = PendingCalendarOperation(
            operationType: type,
            accountId: accountId,
            eventId: eventId,
            calendarId: calendarId,
            arguments: arguments,
            eventTitle: eventTitle
        )
        try await queueCalendarOperations([op])
        return op
    }

    /// Queue several calendar mutations in ONE write: every row is persisted, or none is (the
    /// write is one transaction, so a failure rolls back the rows already inserted). One
    /// confirmation that asks for several writes (`calendar_event_edit`'s `exdates_add`, one
    /// delete per occurrence) is never left half queued. Each row then drains as an ordinary
    /// operation of its own.
    func queueCalendarOperations(_ ops: [PendingCalendarOperation]) async throws {
        try await dbPool.write { db in
            for op in ops { try op.insert(db) }
        }
        for op in ops {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Queued \(op.operationType) for account \(op.accountId) (id: \(op.id))")
        }
        Task { await drainCalendarQueue() }
    }

    /// Drain all queued calendar operations in FIFO order.
    /// Pattern mirrors drainPendingQueue — offline skip, per-account failure tracking,
    /// multi-pass re-fetch for ops inserted during drain.
    func drainCalendarQueue() async {
        guard !isDrainingCalendar else {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Skipped drain — already draining")
            return
        }
        guard NetworkMonitor.checkConnected() else {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Skipped drain — offline")
            return
        }
        isDrainingCalendar = true
        defer { isDrainingCalendar = false }

        var failedAccounts = Set<String>()
        // Whether a queued change's wait reason may have been written, cleared, or left the queue
        // with its row, so the inbox's waiting banners are read again after the drain (#865).
        var waitReasonsChanged = false

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
                BackgroundSyncLogger.logDebug("[CalendarQueue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else {
                if pass == 0 { BackgroundSyncLogger.logDebug("[CalendarQueue] No pending calendar ops") }
                break
            }

            if pass == 0 {
                if DebugModeManager.isLoggingEnabled() {
                    let summary = ops.map { "\($0.operationType)(event=\($0.eventId ?? "new"))" }.joined(separator: ", ")
                    BackgroundSyncLogger.logDebug("[CalendarQueue] Draining \(ops.count) calendar operations: \(summary)")
                }
            }

            var executedAny = false

            for op in ops {
                // Re-check if op still exists (may have been cancelled between await points)
                let currentOp: PendingCalendarOperation
                do {
                    guard let fetched = try await dbPool.read({ db in
                        try PendingCalendarOperation.fetchOne(db, key: op.id)
                    }) else {
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Op \(op.id) vanished — skipping")
                        continue
                    }
                    currentOp = fetched
                } catch {
                    BackgroundSyncLogger.logDebug("[CalendarQueue] ERROR: Failed to re-read op \(op.id): \(error)")
                    continue
                }
                if failedAccounts.contains(currentOp.accountId) { continue }
                if currentOp.status == PendingStatus.inFlight.rawValue { continue }

                guard let calProvider = calendarProviders[currentOp.accountId] else {
                    BackgroundSyncLogger.logDebug("[CalendarQueue] No calendar provider for \(currentOp.accountId) — skipping")
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
                    BackgroundSyncLogger.logDebug("[CalendarQueue] WARNING: Could not mark \(currentOp.id) in-flight — skipping: \(error)")
                    continue
                }

                let opType = currentOp.operationType
                BackgroundSyncLogger.logDebug("[CalendarQueue] Executing \(opType) (id: \(currentOp.id), event: \(currentOp.eventId ?? "new"))")

                do {
                    let ids = try await executeCalendarOperation(currentOp, provider: calProvider)
                    if currentOp.waitReason != nil { waitReasonsChanged = true }
                    // Post-execution delete MUST succeed — remote op already completed.
                    //
                    // 🚨 R17b-B2 — OF THE THREE DURABLE BOOKKEEPING WRITES IN THIS
                    // DRAIN, THIS IS THE ONLY ONE WHOSE FAILURE CAN CHANGE WHAT THE
                    // SERVER SEES, AND IT IS DELIBERATELY NOT GATED. (The other two:
                    // mark-in-flight is checked and `continue`s, leaving the op
                    // `queued`; the transient requeue below only delays the op to the
                    // next launch. The TERMINAL arms are gated on
                    // `retireCalendarOperation`'s Bool, R17-2.)
                    // If the delete never commits, the row stays
                    // `inFlight`; after successful recovery in `AppDatabase.init`
                    // on a later launch, the drain RE-EXECUTES work the server already
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
                            "[CalendarQueue] CRITICAL: failed to delete completed op \(currentOp.id) — it stays inFlight and can re-execute after successful startup recovery: \(error)",
                            source: "CalendarQueue")
                        BackgroundSyncLogger.logDebug("[CalendarQueue] CRITICAL: Failed to delete completed op \(currentOp.id) — can re-execute after successful startup recovery")
                    }
                    executedAny = true

                    // Best-effort EventKit refresh so iOS Calendar app picks up changes
                    EKEventStoreHelper.refreshSources()

                    BackgroundSyncLogger.logDebug("[CalendarQueue] Completed \(opType) (id: \(currentOp.id))")
                    signalCalendarOpOutcome(
                        opId: currentOp.id,
                        outcome: .success(newSeriesId: ids.newSeriesId, createdRealId: ids.createdRealId)
                    )
                } catch {
                    let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
                    // A reason the user can act on, kept on the row if it stays queued (#865).
                    let waitReason = Self.calendarWaitReason(error)
                    if currentOp.waitReason != nil || waitReason != nil { waitReasonsChanged = true }

                    // 🚨 R14-F4 — RAISE THE RE-AUTH SIGNAL BEFORE ANY DISPOSITION IS
                    // CHOSEN. The signal is about the ACCOUNT; the arms below decide
                    // about the OP. Those are different questions and conflating them
                    // is how this went unnoticed: `rg -c authFailedAccounts` over this
                    // file returned ZERO, so an OAuth calendar account whose grant had
                    // been revoked produced no persistent, user-visible signal at all.
                    // ⚠️ This sentence continued *"— only CalDAV accounts did, through
                    // their `caldavConfig` `needsReauth` column"*, and round 18
                    // established that CalDAV had no working signal either: nothing
                    // cleared that column, no UI read it, and its one reader wedged
                    // the account's calendar lane permanently. The write is gone.
                    // OAuth is now the only auth family here with a persistent signal;
                    // the CalDAV gap is registered as `IOS-CAL-007`.
                    // `authFailedAccounts` is that OAuth signal:
                    // `AccountManager`'s `didSet` mirrors it into
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
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Event not found for \(opType) — retiring (server wins)")
                        let reason = "event not found on server"
                        await retireAndAnnounce(currentOp, reason: reason, kind: .notFound)
                        executedAny = true
                        continue
                    }
                    if Self.isCalendarMissingScopeError(error) {
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Calendar scope not granted for \(opType) — retiring. User must re-authenticate in Settings.")
                        // 🚨 R16-5 — RAISE THE PERSISTENT RE-AUTH SIGNAL HERE TOO.
                        // This arm's own reason string ends *"user must
                        // re-authenticate in Settings"*, i.e. its remedy is a USER
                        // GESTURE — and until now nothing told the user to make it.
                        // `isCalendarOAuthReauthRequired` is FALSE for both spellings
                        // this arm claims (`missingScope` and a raw `httpError(403,…)`),
                        // so the R14-F4 signal above does not fire. `IOS-CAL-003`'s
                        // stated discharge was therefore false for its own namesake
                        // case — the same shape as R15's `IOS-QUEUE-009` on the mail
                        // lane, one lane fixed and the sibling left (`MIS-006`).
                        // ⚠️ This sentence used to end *"and unlike the CalDAV auth
                        // arm there is no `caldavConfig.needsReauth` write either"*,
                        // which round 18 falsified from the other side: there is now
                        // no such write anywhere, because it was a durable wedge
                        // rather than a signal (see the auth arm below).
                        markAuthFailed(currentOp.accountId)
                        let reason = "calendar permission missing — user must re-authenticate in Settings"
                        await retireAndAnnounce(currentOp, reason: reason, kind: .missingPermission)
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
                    // claim `CalDAVError.authFailed`, which this arm does claim.
                    //
                    // ⚠️ THIS BLOCK SAID *"CalDAV's persistent signal is the
                    // `caldavConfig.needsReauth` write below instead"* UNTIL ROUND
                    // 18, AND THAT WRITE HAS BEEN REMOVED BECAUSE IT WAS A WEDGE,
                    // NOT A SIGNAL — nothing cleared it, no UI read it, and its one
                    // reader removed the account from `calendarProviders` forever
                    // (banner on `AccountManager.createCalDAVProvider`). So the
                    // incomparability is now one-sided in a different way and worth
                    // stating plainly: a CalDAV auth failure retires THIS op and
                    // raises NO persistent signal of its own. The user-facing
                    // channel for it is `CalendarPickerModel`'s live `listCalendars()`
                    // probe, which renders "Calendar Access Required" for the
                    // account the next time the calendar picker opens — and which
                    // only works because the provider still exists. That gap is
                    // registered as `KNOWN_ISSUES.md` `IOS-CAL-007`, which round 18
                    // widened to cover the CalDAV auth class it previously carved
                    // out on the strength of that false sentence. Its retirement
                    // itself now reaches the user like every terminal failure: on the
                    // waiting card, or else as an inbox banner
                    // (`LateCalendarFailureStore`).
                    if Self.isCalendarAuthError(error) {
                        let isCalDAV = Self.isCalDAVAuthError(error)
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Auth failed for \(opType) (\(isCalDAV ? "CalDAV" : "OAuth")) — stopping retries, user must re-authenticate")
                        let reason = Self.calendarAuthFailureReason(error)
                        await retireAndAnnounce(currentOp, reason: reason, kind: .signInFailed)
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
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Unsupported \(opType) (\(reason)) — retiring (no retry)")
                        await retireAndAnnounce(currentOp, reason: reason, kind: .unsupported)
                        executedAny = true
                        continue
                    }

                    // Permanent malformed-request errors — retire terminally.
                    // Retrying the same broken payload never succeeds. The
                    // retirement is recorded at error level through
                    // `BackgroundSyncLogger`, which is what `DebugLogView` renders
                    // (R16-10 — this sentence claimed that before it was true).
                    if Self.isCalendarBadRequestError(error) {
                        BackgroundSyncLogger.logDebug("[CalendarQueue] Bad request for \(opType) (\(error)) — retiring (will not retry)")
                        let reason = badRequestReason(error)
                        await retireAndAnnounce(currentOp, reason: reason, kind: .refused)
                        executedAny = true
                        continue
                    }

                    // Transient errors — always retry. NEVER drop on age alone.
                    // Only confirmed-stale paths above (notFound, missingScope,
                    // authError, unsupported, badRequest) may
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
                    // → 7 at R17-2: the six arms plus the function's own definition;
                    // 6 since #601 removed the `inconsistentState` arm (five arms).
                    // See `retireAndAnnounce`, which is now the single terminal
                    // announcement gate, and `retireCalendarOperation` beneath it.
                    BackgroundSyncLogger.logDebug("[CalendarQueue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
                    // 🚨 R17b-B2 — RECORDED, NOT SWALLOWED. This was `try? await`
                    // until R17b: the requeue is a durable bookkeeping write and a
                    // silently-dropped failure leaves the row `inFlight`, where the
                    // drain's `status == queued` filter skips it for the rest of the
                    // session with nothing in the log to say so. The DISPOSITION is
                    // deliberately unchanged — `AppDatabase.init` attempts to
                    // requeue it at next launch. `.stillQueued` below means the
                    // intention is pending, including when it remains `inFlight`
                    // awaiting successful startup recovery. Same shape as
                    // `retireCalendarOperation`'s catch and the in-flight marker
                    // above; Outbox rule 2 ("never `try?` on queue state
                    // transitions") is the stated precedent.
                    //
                    // The row is read again and only its status and retry count are
                    // written (#601): the attempt may have kept a split's record in
                    // `argumentsJSON` (`recordSplit`), and writing back the row as it was
                    // read before the attempt would erase it. Its wait reason (#865) is set
                    // on that fresh read, and `argumentsJSON` is written only when it changed.
                    do {
                        try await retryWrite(dbPool, label: "CalendarQueue") { db in
                            guard var updated = try PendingCalendarOperation.fetchOne(db, key: currentOp.id) else { return }
                            updated.status = PendingStatus.queued.rawValue
                            updated.retryCount += 1
                            var columns = ["status", "retryCount"]
                            if updated.waitReason != waitReason {
                                updated.setWaitReason(waitReason)
                                columns.append("argumentsJSON")
                            }
                            try updated.update(db, columns: columns)
                        }
                    } catch {
                        BackgroundSyncLogger.logError(
                            "[CalendarQueue] WARNING: failed to requeue transient op \(currentOp.id) — it stays inFlight until database recovery at next launch: \(error)",
                            source: "CalendarQueue")
                        BackgroundSyncLogger.logDebug("[CalendarQueue] WARNING: Could not requeue \(currentOp.id) — stays in-flight until next launch: \(error)")
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

        if waitReasonsChanged { await LateCalendarFailureStore.shared.reload() }
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
            BackgroundSyncLogger.logDebug("[CalendarQueue] Unknown operation type: \(op.operationType) — retiring as a permanent failure")
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
            var input = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: allDay)
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
                BackgroundSyncLogger.logDebug("[CalendarQueue] Created event id=\(created.id ?? "nil")")
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
                BackgroundSyncLogger.logDebug("[CalendarQueue] Google reports our pre-generated id already exists (409 duplicate) — the create already landed")
                createdRealId = op.eventId
            } catch CalDAVError.preconditionFailed {
                // 412 Precondition Failed — CalDAV idempotent create (If-None-Match: *). Event exists. Success.
                // Positive by construction, unlike the two 409s: the provider sent
                // `If-None-Match: *`, so 412 is the server answering the exact
                // question "does this resource already exist?" with yes.
                BackgroundSyncLogger.logDebug("[CalendarQueue] CalDAV event already exists (412) — treating as success")
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
                BackgroundSyncLogger.logDebug("[CalendarQueue] Edit op missing eventId — retiring as a permanent failure")
                throw CalendarProviderError.notSupported(
                    "the queued calendar edit carries no event id and can never be executed")
            }
            var resolvedAllDay = CalendarToolHelpers.boolArg(args, "all_day")
            // 🚨 THE OTHER HALF OF THE OCCURRENCE ADDRESS. `recurrence_id` is a
            // naive wall clock with no offset; on its own it does not name an
            // instant. `calendar_event_edit`'s schema already publishes the frame
            // ("all naive ISO8601 datetime parameters are interpreted in this
            // timezone", default: the device zone), the durable operation already
            // persists the whole argument dictionary including `timezone`, and
            // `formatDetailedEvent` already MINTS `start_iso` in that same zone.
            // The frame was present on both ends the entire time and was simply
            // never carried across — the calendar instance of THE ADDRESS PROBLEM.
            // Resolving it here, once, is what lets every provider agree.
            // A `timezone` the resolver does not recognize is refused here, before
            // the occurrence reads below use it as the frame, through the same
            // function `buildGCalEventInput` uses. The edit tool queues the zone its card used
            // when the assistant gave none (`stampingZone`, #753), so this is that zone, not the
            // device's at the drain; only a row queued before that stamp has none.
            let editZone = try CalendarToolHelpers.resolveWriteTimeZone(
                args, consequence: "it did not change the event")
            // `recurrence_id` is read in the zone the edit tool read it in, the device's at the
            // tool, where the read tools print it, whatever `timezone` names for the new times
            // (#794); the edit's own times stay in `editZone`.
            let recurrenceIdZone = try CalendarToolHelpers.recurrenceIdZone(args, editZone: editZone)
            // 🚨 A SPLIT WHOSE NEW PART WAS WRITTEN IS NEVER RUN AGAIN (#601). An earlier attempt
            // of this operation created the new part and kept its record (`recordSplit`) before
            // the carry and the cap; one of them failed or its answer was lost. Only those are
            // left: they are written from the series as it is now (`finishSplit`), while the new
            // part is there, the carry from the record's mode and fields and the edit's guest
            // change read again from the arguments (#563). A
            // new part the user deleted since is not written again, and nor is the cap: the
            // change is refused with the reason, and the user decides.
            // An edit past the series' last place that an earlier attempt began writes the rest
            // of its edits to the targets it kept, without looking for the occurrence named where
            // it was (the first attempt may have moved it).
            if let record = SplitRecord(args), record.isPastEnd {
                try await provider.finishShownEdit(
                    calendarId: calId, record: record,
                    edit: try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil), guests: AttendeeChange(arguments: args))
                BackgroundSyncLogger.logDebug("[CalendarQueue] Finished the edit past the end of \(record.seriesId)")
                return (nil, nil)
            }
            if let record = SplitRecord(args) {
                guard try await provider.eventExists(calendarId: calId, eventId: record.newPartId) else {
                    throw CalendarProviderError.notSupported(SplitRecord.newPartDeleted)
                }
                try await provider.finishSplit(
                    calendarId: calId, record: record, zone: recurrenceIdZone, guests: AttendeeChange(arguments: args))
                BackgroundSyncLogger.logDebug("[CalendarQueue] Finished split of \(record.seriesId) at \(record.splitAt) — new series id=\(record.newPartId)")
                return (record.newPartId, nil)
            }
            // The same reading and routing the edit tool made before its card
            // (`CalendarSeriesScope`): the event, its series and the occurrence it names, by the
            // provider's own lookup, then where the edit goes. The tool queues the edit as it routed
            // it, which routes to itself, so this decides the same unless the calendar changed since
            // the card. A failed read is thrown as the provider gave it, and the drain classifies it
            // (an occurrence that no longer starts there is the provider's not-found).
            let givenScope = CalendarToolHelpers.stringArgOpt(args, "edit_scope")?.lowercased()
                ?? (CalendarToolHelpers.stringArgOpt(args, "recurrence_id") != nil ? "this_only" : "all")
            let named = try await CalendarSeriesScope.read(
                eventId: eventId, recurrenceId: CalendarToolHelpers.stringArgOpt(args, "recurrence_id"),
                scope: givenScope, calendarId: calId, zone: recurrenceIdZone, provider: provider)
            let routed = try CalendarSeriesScope.route(args, scope: givenScope, named: named, zone: editZone, recurrenceIdZone: recurrenceIdZone)
            // The tool makes an "all" edit that moves a later occurrence to another date a split before
            // its card; one that reaches the queue as "all" was confirmed as a change of every
            // occurrence and the series changed since. It is not split here.
            if givenScope == "all", routed.scope == "this_and_following" {
                throw CalendarProviderError.notSupported(
                    CalendarSeriesScope.laterOccurrenceRefusal(routed.recurrenceId ?? "?"))
            }
            // An edit of every occurrence writes the series (#560), whichever of its occurrences the
            // edit names.
            let writeId = routed.scope == "all" ? named.seriesId : routed.eventId
            // A guest change (`add_attendees` / `remove_attendees`) stays a change: it is never
            // resolved here against one item's list. `buildGCalEventInput` carries it as
            // `GCalEventInput.attendeeChange`, and the provider's write applies it to the stored
            // guests of the item it writes; a whole-series write reaches each changed occurrence as
            // the series' difference, on that occurrence's own guests (`AttendeeChange`, #620).
            // A move to another day of a series whose rule names its days turns those days with it
            // (`CalendarSeriesScope.dayMove`), on the rule each provider writes.
            let ruleDayMove = try CalendarSeriesScope.dayMove(
                routed.args, named: named, scope: routed.scope, zone: editZone)
            // 🚨 AN RRULE `UNTIL`'S VALUE TYPE BELONGS TO THE DTSTART, AND ON AN EDIT THE DTSTART
            // BELONGS TO THE RESOURCE. RFC 5545 §3.3.10: "The value of the UNTIL rule part MUST have
            // the same value type as the DTSTART property." `buildGCalEventInput` renders the UNTIL
            // from the `isAllDay` it is handed, so passing the model's `all_day` verbatim made the
            // value type a property of the TOOL CALL. An edit that changes only the recurrence does
            // not restate `all_day`, so `nil` became `false`, and a UTC DATE-TIME `UNTIL` landed
            // against the server's `DTSTART;VALUE=DATE:` — `mergePatchIntoICS` leaves the start
            // exactly as the server had it when the patch carries none, so nothing downstream can
            // notice the disagreement. On `edit_scope: "this_and_following"` it is worse: CalDAV's
            // split writes `patch.recurrence` over the new part's rule while the new part keeps the
            // series' all-day DTSTART, so the mismatched pair is written as the new part, which the
            // irreversible cap PUT then relies on, with no rollback (ADR-IOS-106).
            //
            // So resolve it from the resource — the only source of the landing DTSTART's value type
            // available before the write. An explicitly stated `all_day` is still taken at its word —
            // stating it is how the agent converts a timed event to all-day and back, and overriding
            // that would break the conversion.
            //
            // **THE SAME FLAG DECIDES A MOVE'S KIND, SO A MOVE RESOLVES IT TOO.**
            // `buildGCalEventInput` renders `start_iso`/`end_iso` as `startDate`/`endDate` only when
            // this flag is true. An edit that moves an all-day event and leaves `all_day` out (the
            // tool documents it as "Omit to keep existing") rendered its dates as
            // `startDateTime`/`endDateTime`: Google's `mergeExistingEventWithPatch` passed them
            // through and Exchange's `toGraphEventJSON` stamped `isAllDay: false`, so the event was
            // saved as a timed one, and on CalDAV `formatDTLine`'s `.allDay` arm reads only
            // `patch.startDate`, so the same edit did not move the event at all. The rule, the
            // Thunderbird add-on's for the same defect: the edit's kind is `all_day` when the edit
            // states it, otherwise the event's own kind. So an all-day event given new dates stays
            // all-day on those dates (a time of day in them is refused below, asking the user), and a
            // timed one given a date alone (`…T00:00:00`) stays timed, at midnight. A stated `all_day`
            // still wins both ways, and `.create` is unchanged (missing means timed).
            //
            // ⚠️ **TYPE-OF-CHECK / TYPE-OF-USE, accepted.** This GET is not the GET the write merges
            // against, so a conversion between the two reads mismatches the pair in EITHER direction
            // — a race in the mirror direction traded for the pre-fix all-day-resource case, not a
            // subset. A rejected write is classified by `isCalendarBadRequestError` and retired by
            // `retireAndAnnounce` rather than retried, so recovery is a fresh user request; read those
            // two symbols for the codes and for what happens when the retire itself cannot persist.
            // Case table and why it stays unfixed: memory 115, residual 4.
            //
            // The gate: an absent `all_day` is resolved when the edit gives `start_iso` or `end_iso`
            // (the flag renders them) or when `recurrenceUntilIsAtStake` (the flag types the UNTIL).
            // It is resolved here, once, before the scope switch, so every provider's edit and every
            // `edit_scope` gets its kind from the same place. The event is the one
            // `CalendarSeriesScope.read` read above: the series for an edit of every occurrence, which
            // is what is written; the occurrence for an edit of one, since one changed on its own can
            // be of the other kind than its series (its kind is kept, never guessed from the series',
            // as in the Thunderbird add-on); else the event the edit names.
            //
            // A failed fetch does NOT guess: the throw propagates and the drain classifies it —
            // transient ⇒ retried, permanent ⇒ retired with a reason. Fail closed, per THE MANTRA; a
            // defaulted value here would be the same wrong-kind write, chosen by us instead of the
            // model.
            let movesTime = CalendarToolHelpers.stringArgOpt(routed.args, "start_iso") != nil
                || CalendarToolHelpers.stringArgOpt(routed.args, "end_iso") != nil
            let written = routed.scope == "all" ? try named.readSeries()
                : routed.scope == "this_only" ? named.occurrence ?? named.event : named.event
            var stored: GCalEvent? = nil
            if resolvedAllDay == nil,
               movesTime || CalendarToolHelpers.recurrenceUntilIsAtStake(routed.args) {
                stored = written
                // `GCalDateTime.date` is populated only for an all-day event, on every provider:
                // `ICSParser.makeGCalDateTime` (CalDAV), `ExchangeCalendarProvider.toGCalDateTime`,
                // `DemoCalendarProvider`, and Google's own JSON all put the timed form in `dateTime`.
                resolvedAllDay = (written.start?.date != nil)
                // Gated per global rule 12 — this is a new diagnostic, and the surrounding ungated
                // `print`s are the pre-existing corpus registered as `IOS-LOG-003`, not a licence.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CalendarQueue] Edit moves the event or sets an RRULE UNTIL with no all_day argument — resolved allDay=\(resolvedAllDay == true) from the resource")
                }
            }
            // Route by edit_scope (calendar_event_edit-v1.5.21+). Default: 'all'
            // when no recurrence_id, 'this_only' when recurrence_id is present
            // (back-compat with the earlier schema where recurrence_id alone
            // implied single-occurrence override).
            let recurrenceId = routed.recurrenceId
            let scope = routed.scope

            // THE EDIT TARGET'S START DATE, resolved once here with the scope: on `this_and_following`
            // the target is the occurrence, whose start is `recurrence_id`'s date (the start the new
            // series keeps), with no read; on `this_only` it is the day the occurrence starts on now,
            // which the provider answers below (`occurrenceStartDay`) for an end given alone on an
            // all-day occurrence, and otherwise `recurrence_id`'s date; on `all` it is the
            // event's stored start, the series read above (`written`). The master's start
            // is earlier than any later occurrence's, so a scoped edit compared with it would pass an
            // end on the occurrence's own start. The KIND a stated `all_day` is compared with is
            // `written`'s and, when the edit names an occurrence, that occurrence's: an occurrence
            // changed on its own can be of the other kind, and a change of either kind needs both a
            // start and an end (`allDayEditRefusal`).

            // An all-day end is the day after the last day, so an all-day edit whose end is on or
            // before its start would write a zero-length event (an all-day event given times of one
            // day without `all_day`, or `all_day: true` with a same-day end). Refused here, before
            // the scope switch and so before a split's first write, as a terminal `notSupported`
            // the drain retires and announces. The start is `start_iso`'s date when the edit gives
            // one, else the target's start date above, which an end-only edit keeps on every
            // provider. A start given alone is never refused: Google, Outlook, the CalDAV
            // whole-series merge and the CalDAV single-occurrence override all carry the end by
            // the event's length. An edit that gives no times is not checked, so an event already
            // stored that way can still be renamed.
            //
            // Before it, the same place refuses an all-day event given a time of day with `all_day`
            // left out: the user may want a timed event or that date all day, and dropping the time
            // (`buildGCalEventInput`'s `prefix(10)`) would choose for them. Only the kind resolved
            // from the stored event is checked; a stated `all_day` is taken at its word, except
            // that one of the other kind needs both `start_iso` and `end_iso`, as in the Thunderbird
            // add-on. Every refusal tells the assistant to ask the user. The edit tool applies the same rule
            // (`allDayEditRefusal`) before its confirmation card; it is applied again here because
            // the event can change between the card and the drain.
            //
            // On `this_only` the start an end-only edit keeps is the occurrence's CURRENT start, which
            // can differ from `recurrence_id`'s date, earlier or later, when the occurrence was moved
            // on its own, so it is read from the provider. A failed read throws and the drain
            // classifies it as any other error: a transport error keeps the edit queued for a retry,
            // while `notSupported` (a `recurrence_id` the series' zone cannot express) and `notFound`
            // (the event is gone) retire it with a reason.
            var occurrenceStartDay: String? = nil
            if let rid = recurrenceId,
               CalendarToolHelpers.needsOccurrenceStartDay(routed.args, storedStart: stored?.start, scope: scope) {
                occurrenceStartDay = try await provider.occurrenceStartDay(
                    calendarId: calId, eventId: writeId, recurrenceId: rid, recurrenceIdZone: recurrenceIdZone)
            }
            if let reason = CalendarToolHelpers.allDayEditRefusal(
                routed.args, storedStart: written.start, scope: scope, recurrenceId: recurrenceId,
                occurrenceStartDay: occurrenceStartDay, namedOccurrenceStart: named.occurrence?.start) {
                throw CalendarProviderError.notSupported(reason)
            }
            var input = try CalendarToolHelpers.buildGCalEventInput(routed.args, isAllDay: resolvedAllDay)
            input.ruleDayMove = ruleDayMove

            switch scope {
            case "this_only":
                guard let rid = recurrenceId else {
                    throw CalendarProviderError.notSupported("edit_scope='this_only' requires recurrence_id")
                }
                _ = try await provider.updateOccurrence(
                    calendarId: calId, eventId: writeId, recurrenceId: rid,
                    recurrenceIdZone: recurrenceIdZone,
                    event: input, sendUpdates: "all"
                )
                BackgroundSyncLogger.logDebug("[CalendarQueue] Updated event id=\(eventId) scope=this_only at \(rid) (\(recurrenceIdZone.identifier))")
            case "this_and_following":
                guard let rid = recurrenceId else {
                    throw CalendarProviderError.notSupported("edit_scope='this_and_following' requires recurrence_id")
                }
                // The record is kept on this operation once the new part's create is
                // confirmed and before the carry and the cap (`SplitRecord`), so a retry takes
                // the branch above.
                let opId = op.id
                let created = try await provider.splitSeries(
                    calendarId: calId, eventId: writeId, recurrenceId: rid,
                    recurrenceIdZone: recurrenceIdZone,
                    patch: input, sendUpdates: "all",
                    record: SplitRecorder(
                        keep: { record in try await self.recordSplit(opId: opId, record) },
                        partNotFound: { try await self.noteSplitPartNotFound(opId: opId) })
                )
                BackgroundSyncLogger.logDebug("[CalendarQueue] Updated event id=\(eventId) scope=this_and_following at \(rid) (\(recurrenceIdZone.identifier)) — new series id=\(created?.id ?? "none")")
                // Surface the new series id so `awaitCalendarOpOutcome` can hand
                // it back to the tool — the LLM needs it to address occurrences
                // in the split's second half. Without this, follow-up edits
                // continue to target the master (now truncated) and silently
                // miss for any occurrence on or after `rid`.
                // An edit past the series' last place makes no new part (nil): nothing to surface.
                return (created?.id, nil)
            case "all":
                _ = try await provider.updateEvent(calendarId: calId, eventId: writeId, event: input, sendUpdates: "all")
                BackgroundSyncLogger.logDebug("[CalendarQueue] Updated event id=\(writeId) scope=all")
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
                BackgroundSyncLogger.logDebug("[CalendarQueue] Delete op missing eventId — retiring as a permanent failure")
                throw CalendarProviderError.notSupported(
                    "the queued calendar delete carries no event id and can never be executed")
            }
            // A delete of an occurrence and every later one ends the series just before the
            // occurrence's place (#695), worked out by the delete tool before its card
            // (`CalendarSeriesScope.followingDelete`) and read here in the zone the tool read it in.
            // Nothing is deleted: the series is capped, from the series as it is now, and a retry
            // after the cap landed writes nothing (`endSeries` never lengthens a series). Guests
            // are told, as for any delete (`sendUpdates` "all").
            if CalendarToolHelpers.stringArgOpt(args, "delete_scope") == "this_and_following" {
                guard let cut = CalendarToolHelpers.stringArgOpt(args, CalendarToolHelpers.deleteCutKey), !cut.isEmpty,
                      let zoneId = CalendarToolHelpers.stringArgOpt(args, CalendarToolHelpers.recurrenceIdZoneKey),
                      let zone = CalendarTimeZoneResolver.zone(named: zoneId, in: .none) else {
                    throw CalendarProviderError.notSupported(
                        "the queued delete of an occurrence and every later one names no place to end the series, and can never be executed")
                }
                try await provider.endSeries(calendarId: calId, seriesId: eventId, before: cut, zone: zone, sendUpdates: "all")
                BackgroundSyncLogger.logDebug("[CalendarQueue] Ended series id=\(eventId) before \(cut)")
                return (nil, nil)
            }
            try await provider.deleteEvent(calendarId: calId, eventId: eventId, sendUpdates: "all")
            BackgroundSyncLogger.logDebug("[CalendarQueue] Deleted event id=\(eventId)")
        }
        return (nil, nil)
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
    /// two are read only for `markAuthFailed` and — since round 18 removed the
    /// `caldavConfig.needsReauth` rider this sentence used to name — for the
    /// CalDAV/OAuth label in the auth arm's log line. (Cited by SYMBOL: the two
    /// `:432` / `:481` line references this sentence carried were already stale,
    /// `feedback_line_citations_go_stale`.)
    ///
    /// For the FOUR that do answer *does SOME terminal arm claim this error?*, an
    /// error no arm claims falls through to the transient arm, which requeues it
    /// and inserts the account into `failedAccounts`, head-of-line-blocking every
    /// later op on that account on every subsequent drain. That starvation is a
    /// wedge, and the wedge corollary sits in the same non-recoverable set as a
    /// dropped intention — it never recovers via sync.
    static func isCalendarUnsupportedError(_ error: Error) -> Bool {
        // Every case is a final refusal: `notSupported`, and a series not in this calendar (#729).
        error is CalendarProviderError
    }

    private func unsupportedReason(_ error: Error) -> String {
        if let refused = error as? CalendarProviderError { return refused.reason }
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

    /// Why a failure that keeps a change queued is one the user can act on, or nil. Only the
    /// transient arm reads it: no terminal arm claims these errors (#865).
    ///
    /// `ExchangeCalendarError.mailboxFull`: Graph refused the write with 403 `ErrorQuotaExceeded`.
    /// Signing in again can't help and the change must not be dropped, so it stays queued, the
    /// account's later calendar changes wait behind it for the drain, and the inbox says the
    /// mailbox is full until a drain after the user freed space makes it.
    static func calendarWaitReason(_ error: Error) -> CalendarWaitReason? {
        if case ExchangeCalendarError.mailboxFull = error { return .mailboxFull }
        return nil
    }

    /// Why the account's still-queued calendar changes wait (#865), or nil: the reason the drain last
    /// stored on the account's FIRST queued row in queue order (`createdAt`). The drain stops an
    /// account at its first failure (`failedAccounts`), so every later change of the account waits
    /// behind that row whether or not it was attempted, and only that row is stamped. Read by a
    /// calendar tool whose change is still queued, so its result can say why. Rows created at the
    /// same instant are one batch (an exdate edit's deletes) whose order the drain does not fix, so
    /// the head is that whole batch. An in-flight row is still in the queue.
    func calendarWaitReason(accountId: String) async -> CalendarWaitReason? {
        let rows: [PendingCalendarOperation]
        do {
            rows = try await dbPool.read { db in
                try PendingCalendarOperation
                    .filter(Column("accountId") == accountId)
                    .filter([PendingStatus.queued.rawValue, PendingStatus.inFlight.rawValue].contains(Column("status")))
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Could not read the calendar queue of \(accountId): \(error)")
            return nil
        }
        guard let head = rows.first else { return nil }
        return rows.prefix { $0.createdAt == head.createdAt }.compactMap(\.waitReason).first
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
    /// `OAuthService.refreshGoogleToken` and
    /// `OAuthService.refreshMicrosoftToken` both raise
    /// `OAuthError.tokenExchangeFailed(response.error ?? "unknown")`, so the payload
    /// is the server's own machine-readable code — the same evidence standard the
    /// calendar queue already applies to Google's 409 bodies.
    ///
    /// 🚨 **DELIBERATELY EXACT-MATCH AND DELIBERATELY THREE.** This predicate is the
    /// gate on a TERMINAL arm, and a terminal arm RETIRES the user's queued calendar
    /// operation — `status = 'failed'` with a reason since R16-1, not the delete this
    /// sentence asserted until R17-7. The row survives (as an inbox banner when no
    /// card showed the failure, `LateCalendarFailureStore`) and is reclaimed after `SyncConfig.retiredCalendarOpRetentionDays`; what does NOT
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
    ///     through THIS predicate. ⚠️ **Until round 18 this bullet ended *"because
    ///     CalDAV's persistent signal is the `caldavConfig.needsReauth` write in
    ///     the same arm rather than `authFailedAccounts`"*, and that reason was
    ///     FALSE.** That write was never a signal — nothing cleared it, no UI read
    ///     it, and its sole reader made `AccountManager.createCalDAVProvider`
    ///     return nil forever, which starved the account's whole calendar lane.
    ///     It has been removed. The bullet's SET MEMBERSHIP is unchanged and still
    ///     correct; only its justification was wrong. A CalDAV auth failure now
    ///     raises no persistent signal at all, which is registered as
    ///     `KNOWN_ISSUES.md` `IOS-CAL-007` rather than papered over here. (The
    ///     retirement it causes is now shown, on the card or as an inbox banner;
    ///     no re-authentication prompt is raised.)
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

    /// True only for the CalDAV spelling of an auth failure.
    ///
    /// ⚠️ **THIS DOC SAID, UNTIL ROUND 18: *"CalDAV accounts own a `caldavConfig`
    /// row whose `needsReauth` column is the persistent, user-visible signal
    /// (`ToolSettingsView` reads it)"*. BOTH HALVES WERE FALSE, and the
    /// parenthetical is the instructive one: `CalendarPickerModel` reads a DIFFERENT
    /// `needsReauth` — a local `CalendarPickerModel.AccountEntry` field set from a
    /// LIVE `listCalendars()` probe's catch arms — and never touches the durable
    /// column. Two unrelated symbols with the same spelling, one of which had a
    /// real UI behind it, is exactly how a dead column read as a working signal
    /// (`MIS-008` — a grep result is a claim about the DATA MODEL it assumes).
    /// The durable write is gone as of round 18; the live probe is the signal, and
    /// it only reaches the user because the provider now still exists.
    ///
    /// What this predicate is still FOR: labelling the auth arm's log line
    /// `CalDAV` vs `OAuth`. It is deliberately kept rather than deleted — the two
    /// failures need different remedies (re-enter an app-specific password vs.
    /// re-run an OAuth grant) and a future credential re-entry flow is the thing
    /// that would consume it.
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
        // Shared by all three arms, and with the CalDAV organizer lookup, so they cannot drift apart.
        let isIndeterminate = CalendarHTTPStatus.isComeBackLater
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

}
