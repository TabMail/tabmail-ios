# IOS-QUEUE-010

- Register classification: `open`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-13)** — `AccountManager.DrainContext`'s shared fields are mutated **concurrently and
without synchronisation** by the per-lane drain tasks. Pre-existing; found while adding a field to the
same type for ADR-IOS-008 decision 3, and **not** introduced by it. Registered rather than fixed: the fix
changes the drain's concurrency contract and needs its own red-first coverage.

## Subsystem and search terms

`AccountManager.DrainContext`; `drainPendingQueue`; `executeSingleOp`; `@unchecked Sendable`;
`foldersToSync`; `failedAccounts`; `evidenceRefused`; `diagnosedOpIds`; `enteredInbox`; per-lane `Task`;
`buildLanes`; concurrent `Set` mutation; copy-on-write buffer reallocation; data race; undefined
behaviour; heap corruption; crash inside the drain; missing post-drain folder sync; `Mutex` SE-0433;
iOS resilience rule 5; `nonisolated(unsafe)`; "do not tidy the asymmetry"

## Full detail

**The mechanism.** `drainPendingQueue` builds one `Task` per lane and appends every one of them before
awaiting any:

```swift
tasks.append(task)
…
for task in tasks { await task.value }
```

Each lane task calls `executeSingleOp(_:provider:context:)` with the **same** `DrainContext` instance, and
that function mutates the context directly — `context.foldersToSync.insert(…)`, `context.failedAccounts`,
`context.evidenceRefused`, `context.diagnosedOpIds`. All four are plain stored properties on a
`class DrainContext: @unchecked Sendable`, and **the `@unchecked` is precisely what suppresses the
diagnostic that would otherwise flag this.**

⚠️ **This is undefined behaviour, not a lost update, and the distinction is the reason the row exists.**
It is tempting to read a racy `Set.insert` as "one of the two writes wins" — a benign, recoverable
outcome. **It is not.** Swift's `Set` is copy-on-write: two concurrent writers can both observe a
non-uniquely-referenced buffer, both reallocate, and free or write through the same allocation. The
honest worst case is **heap corruption**, i.e. a crash whose stack need not implicate the drain at all.
**Anyone triaging this must not reason from "we might miss a folder".**

**Blast radius, per outcome.**

- *Lost `foldersToSync` entry* — a destination folder is not post-drain synced, so its new UIDs are picked
  up by the next ordinary sync instead. **Fully recoverable.**
- *Lost `failedAccounts` entry* — one extra provider attempt against a server that is already failing.
  **Harmless.**
- *Heap corruption* — a crash. **No durable state and no user intention is at risk:** every
  `PendingOperation` row is written and deleted through `retryWrite` in its own transaction, none of these
  four fields gates retirement, and the queue re-drains on next launch.

**Reachability.** Requires two or more lanes in one drain — i.e. two queued operations whose members do
not share an address (`buildLanes` groups by connected components over `(account, folder, UID)`), on
accounts that each have a live work queue. That is **ordinary** for a user who acts on several threads
before the drain fires. No field report is known; this is a latent defect found by reading.

**Attribution class:** latent concurrency defect, discovered by inspection, no observed instance.

## Why registered rather than fixed

The fix is to route all four fields through a lock, which touches every mutation site across
`executeSingleOp`'s success and failure arms plus every read in the post-drain phase — **a change to the
drain's concurrency contract, not a local repair.** It belongs in its own commit with its own red-first
coverage, and a concurrency invariant is exactly the kind that needs a **fuzz harness** rather than a unit
test (global testing rule 11). Nothing in THE MANTRA's blocking set is engaged: no dropped intention, no
starving op, no wrong-message mutation, no secret exposure. The crash outcome is brick-*adjacent* but not
a **launch** crash and loses no data.

## ⚠️ The asymmetry is deliberate — do not "tidy" it

The ADR-IOS-008 decision-3 field added alongside these, `DrainContext.enteredInbox`, is
**`Mutex`-protected on its own** rather than joining the unsynchronised group, and it carries a comment
saying so at its declaration.

A future cleanup pass that sees one `Mutex`-protected field among several bare ones will be tempted to
make them consistent — **and the tempting direction is the wrong one.** Consistency here must be achieved
by **protecting the other three, never by unprotecting the one.** Adding a fifth racy field because four
already exist is the "no pre-existing excuses" failure mode.

## Related

- `IOS-QUEUE-001` — the lane key omitting the folder; same `buildLanes` neighbourhood, different defect.
- `IOS-QUEUE-004` — a census in this same file's comments that was wrong and is recorded as corrected;
  the precedent for fixing documentation about the drain in place rather than silently.
- `IOS-AI-004` — the ADR-IOS-008 decision-3 restoration whose new field prompted this discovery.
- `IOS-PERF-012` — the other pre-existing defect found in the same pass.
