## A latch that AUTHORISES a state transition must be HELD across the write that performs it — reading it and then `await`ing proves nothing (2026-08-04)

**This is a CLASS, not a call site.** Any code shaped like

1. read an in-memory ownership latch (`isDraining…`, `isSending`, `isMerging`) to decide *"nobody
   else owns this right now, so I may mutate it"*, then
2. `await` anything at all — a database read, a provider call, an actor hop — then
3. perform the mutation the latch authorised,

is racing. Step 1's answer describes the world at step 1. On an **actor**, step 2 hands the actor to
every other task waiting on it, and the party the latch exists to exclude can enter, set the latch,
and start exactly the work the latch was protecting against. The check has not been skipped; it has
been made **irrelevant**, which is worse, because the code reads as guarded.

**The fix is to ACQUIRE, not to re-check.** Take the latch in the same synchronous run as the check
and hold it across the write. *"Re-check the flag after the await"* is the tempting non-fix: it is
the identical race one frame later, and it produces code that looks even more careful.

### The instance that produced this entry — `IOS-OUTBOX-006`

`AccountManager` is an actor. `AccountManager.reconcileOutbox` (in the FILE
`TabMail/Services/Account/AccountManagerOutbox.swift` — ⚠️ **the file name is not a type qualifier**)
resets `.sending`/`sentAt == nil` outbox rows to `.queued`, because that is what a process killed
mid-send leaves behind. Durable state cannot tell that residue from a row a **live** drain has just
claimed and handed to SMTP: `sentAt` is stamped only after `provider.send()` RETURNS, so an in-flight
send is byte-identical to residue. `isDrainingOutbox` is the ONLY thing that separates them — which
makes it the latch that authorises the reset.

Its first statement is `await dbPool.read`, which on the async overload runs a full NSE staging merge
(see [`103`](103-await-dbpool-read-is-not-a-short-suspension.md) — measured 7.6 s, and staging is
pending precisely on foreground return). A drain starting in that window claimed a row and put its
SMTP transaction on the wire; reconciliation then resumed with that row in its snapshot and reset it.

**The consequence is not academic, and it is worth stating whole because each half alone sounds
survivable.** `discardOutboxMessageConfirmed` refuses only `outboxStatus == .sending` and
`sentAt != nil`. A row reset to `.queued` satisfies neither, so **the user could Discard a message
whose SMTP was already on the wire.** The row and its attachment directory were deleted;
`stampSentAt`'s `UPDATE … WHERE id = ?` then matched zero rows and returned false; and
`sendSingleOutboxMessage` returns at that guard — so no optimistic Sent header, no Sent APPEND, no
finalize. **The recipient received a message the user had been told was discarded, and it never
appeared in Sent.** Outbox Reliability Rule 3 (`sentAt` before delete) and Rule 10 (cannot discard a
`sending` message) both forbid that.

### The class had TWO production entries, and only one was candidate-introduced

- **LAUNCH** — `AccountManager.reconcilePendingOperations` → `reconcileOutbox()`, awaited by
  `RootView`'s startup task. **No ownership check at ALL.** Pre-existing: verbatim in `v2final`
  (`e28dd4edb`) and in shipped `v1.6.38` (`07a4bb703`). Reachable because launch does not gate first
  paint — a held row's deadline can expire, `drainOutbox` claims it, and launch reconciliation is
  still running.
- **FOREGROUND** — `reconcileOutboxOnForeground()`, wired to `RootView`'s `scenePhase → .active`.
  Candidate-introduced by `792048ebd`. It *did* check the latch, and then awaited.

**The first brief for this fix asserted the launch entry was safe** ("no drain has started and no
send can be in flight"). It was wrong, and a fix placed at the foreground wrapper would have closed
one entry of two while its own commit message stated the invariant it did not establish. **Ask
"instance or class?" and enumerate the class mechanically** — here, `rg reconcileOutbox TabMail/`
returns exactly two production entries and the answer takes one minute.

The fix therefore lives where the RESET is performed: `reconcileOutbox` guards **and acquires**
`isDrainingOutbox` in one synchronous run, holds it across `performOutboxReconciliation()`, and
releases it before its trailing `drainOutbox()`.

### Termination and liveness — state them, do not assume them

Two directions, both fail-closed and both recoverable, which is what THE MANTRA requires:

- A **drain** trigger that fires while reconciliation holds the latch is skipped. It is subsumed by
  reconciliation's own trailing `drainOutbox()`, which runs after the release and re-reads the table.
- A **reconciliation** that finds a drain in flight returns without reconciling. It is re-driven by
  the next reconciliation trigger — the next foreground return or launch — which is exactly the
  in-session recoverability `IOS-OUTBOX-001` established. The orphan-attachment sweep it also skips
  is pure byte reclamation and idempotent on the next pass.

No second latch was added. `drainPendingQueue`'s `isDraining`/`needsRedrain` pair and
`ComposeView.isSending` were both audited and are CLEAN — each sets its flag in the same synchronous
run as its check — and were left alone.

### Why v2final's one-transaction shape is NOT the answer here

`v2final`'s `reconcileOutbox` does its classification and its reset inside a single
`retryGatedQueueWrite`. That is a better shape, and it does close a DB-level TOCTOU — but it does not
close **this**. Reconciliation and `atomicClaim` are already serialised by the single GRDB writer, so
the one-transaction version still cannot distinguish a row claimed a millisecond earlier from
residue. Only the in-memory latch carries that information. A reviewer reaching for "just make it one
transaction" should be pointed at this paragraph.

### Testing note — what could and could not be proven red

`TabMailTests/Services/OutboxReconcileInFlightSendTests.swift` pins the SYSTEM property (*a message
whose SMTP is on the wire is never observable as `.queued` and can never be discarded*) via a new
`MockEmailProvider.sendHook`, the in-flight seam that holds `provider.send` open. The **launch**
entry red-proves deterministically (4 failed expectations pre-fix). The **foreground** entry's own
window could NOT be forced: reconciliation snapshots at its first await, which in a test completes in
microseconds, so the drain never wins the race — the production window exists only because that read
runs a seconds-long staging merge. The interleaving sweep is therefore a regression guard, not a red
proof, and says so in its own doc comment. What carries the proof to the second entry is structural:
the wrapper now holds no logic of its own.

### Where to look for more instances

Anywhere an actor method reads an ownership/serialisation flag and then awaits before acting: the
outbox drain, the pending-operation queue, the AI job queue, sync scheduling, NSE merge sections. The
tell is a `guard !isSomethingInFlight else { return }` whose function body's next line contains
`await`, and a comment nearby asserting what the flag PROVES.
