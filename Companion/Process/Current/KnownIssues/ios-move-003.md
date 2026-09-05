<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **⚠️ SITE CORRECTED (2026-09-05, #114 round 4) — the disposition below is UNCHANGED; only where it
> runs has moved.** The body is preserved unedited (it is regenerated from the hash-pinned archive
> and byte-compared); this block records the correction instead.
>
> The cell below names `reconcilePendingOperations` as the function that deletes an `inFlight` MOVE
> whose `everAttempted` is true. That sweep now lives in
> `AppDatabase.recoverPreviousSessionResidue(on:)`, called unconditionally from
> `AppDatabase.init(pool:runStartupResets:)` before `AppDatabase.shared` is published.
> `reconcilePendingOperations` keeps its name and callers and is now only
> `drainPendingQueue()` + `reconcileOutbox()` + `reconcileCalendarQueue()`.
>
> **Why it had to move.** The sweep is a BLIND whole-table reset, and its safety rested on the
> premise "nothing has drained yet in this process". That premise was false at the old site:
> `RootView` calls `reconcilePendingOperations` only after EVERY account has finished connecting,
> while a connected account's gestures and the background entry points have already been draining.
> It therefore deleted a `.move` row this LIVE process still held the provider's proven result for,
> which is a dropped intention with no crash at all — outside this row's accepted window
> (`IOS-GRAPH-005`). At the new site the premise is structural: the sole writer of
> `pendingOperation.status = inFlight` is the drain's claim, and no drain can run before `shared` is
> published.
>
> **What this row's own accounting keeps.** The deliberate disposition (an `everAttempted` `.move`
> is deleted rather than replayed, ordinary types reset and retry), the user-visible recovery by
> sync, the reasons for no migration and no receipt table, and every condition that would re-open
> this row all stand exactly as written. One clause of the mechanism is now also structurally
> guaranteed rather than argued: the rows this sweep can see were left by a PREVIOUS process.
>
> **One failure semantic DID change, and it is stricter.** The old site ran the sweep under
> `try? await retryWrite` and drained anyway when the write failed. At the new site a throw
> propagates out of `init` and `AppStartup` refuses to publish the pool — a database that cannot
> take the recovery write never releases new claims into unreconciled state.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
# IOS-MOVE-003

> Routed from `KNOWN_ISSUES.md` line 1432 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `247cfac4f42a233632220ee4e2c36abb824aa554d6a4b58f0cbaf95f1c760ccb`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09, released `v1.7.5` / `9d10c65d1`)** — a process death can drop a MOVE that was durably claimed but had not yet emitted any provider command; sync restores server truth and the user may repeat the move

## Subsystem and search terms

Move; crash recovery; `AccountManagerQueue.drainPendingQueue`; `reconcilePendingOperations`; `PendingOperation.everAttempted`; `inFlight`; claim-before-provider; conservative evidence; deliberate drop; foreground sync; no automatic replay

## Full detail

**THE EXACT WINDOW.** The queue's claim transaction sets `status = inFlight` and `everAttempted = true` before it builds and schedules lane tasks, so `everAttempted` means *"the app crossed the durable claim boundary"*, not *"the provider sent a command"*. A process death after that commit but before the lane reaches `executeOperation` leaves the same durable shape as a death after the server committed MOVE and before TabMail recorded the result. Launch cannot distinguish those states.

**THE DELIBERATE DISPOSITION.** `reconcilePendingOperations` deletes an `inFlight` MOVE whose `everAttempted` is true instead of resetting it to `queued`; ordinary operation types still reset and retry. This may discard an unperformed move in the pre-wire subcase, but it prevents the post-wire subcase from automatically issuing a second destructive command. No destination UID, Message-ID search, or guessed receipt is introduced. This is the owner-approved *drop the move cleanly and let sync win* direction.

**WHAT THE USER SEES / RECOVERY.** If no command reached the server, source/destination sync removes the optimistic local interpretation and the message appears where the server still has it; the user repeats the move once. If the server committed, sync converges on the destination without replay. A custom folder not covered by scheduled sync may defer that reconciliation until the user opens it, as already registered for on-demand folder sync. No message is deleted from the server by the pre-wire subcase, no wrong message is addressed, and no durable queue row wedges an account lane. The non-recovering condition is only *"the relevant folders are never synced or opened"*; then the local optimistic presentation can remain stale, while the server copy remains intact and authoritative.

**WHY NO MIGRATION OR RECEIPT TABLE.** A durable provider-boundary journal cannot close the unavoidable process-death interval between a server commit and the client's next durable write. The conservative one-bit boundary already prevents the catastrophic direction (blind replay); additional state would narrow a harmless dropped-gesture window while adding another crash protocol. **What would re-open this row:** automatic replay of these rows, evidence that ordinary/on-demand sync cannot converge either server outcome, or a provider-native command receipt that durably distinguishes pre-emission from possibly-committed without guessing.
