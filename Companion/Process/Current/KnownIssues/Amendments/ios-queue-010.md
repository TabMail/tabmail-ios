# IOS-QUEUE-010

- Register classification: `not-defect`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **NOT A DEFECT (2026-08-14)** — the race premise was re-audited before implementation and is false.
The lane tasks overlap provider I/O, but every `DrainContext` read and write runs on the serial
`AccountManager` actor. GitHub [#17](https://github.com/TabMail/tabmail-ios/issues/17) should close as a
false positive; no runtime change or race-shaped regression test is warranted.

## Subsystem and search terms

`AccountManager.DrainContext`; `drainPendingQueue`; `executeSingleOp`; `ProviderWorkQueue.execute`;
`@unchecked Sendable`; `@Sendable`; inherited actor context; `@isolated(any)`; `hop_to_executor`;
`foldersToSync`; `failedAccounts`; `evidenceRefused`; `diagnosedOpIds`; `executedAny`; `enteredInbox`;
per-lane `Task`; actor reentrancy; logical interleaving; physical concurrency; Swift 6 strict
concurrency; false-positive data race; v1.6.38; v1.7.8

## Full detail

### Executor trace

`AccountManager` is an actor. `drainPendingQueue` creates each lane with `Task { [self] in … }` from an
actor-isolated method, so Swift's `Task` initializer inherits the actor context. The closure itself proves
that contract at compile time: it reads actor-isolated `self.workQueues` and `dbPool` without an `await`.
The project builds under Swift 6 with complete strict concurrency; moving the same access into
`Task.detached` is rejected.

The closure passed to `ProviderWorkQueue.execute` is genuinely `@Sendable` and can run away from the
`AccountManager` executor, but it does not read or mutate the context. Its only context-bearing operation
is `await self.executeSingleOp(…, context: capturedCtx)`, which hops back to `AccountManager` before the
first access. Provider calls can therefore overlap across actor suspension points while the shared
bookkeeping remains physically serialized.

An independent Swift 6 strict-concurrency probe reproduced this shape, and emitted SIL marked the lane
closure `@sil_isolated Owner` with `hop_to_executor`. A `Task.detached` negative control failed to compile.

### Mechanical class and access census

`DrainContext` has exactly five plain mutable stored properties:

- `failedAccounts`
- `foldersToSync`
- `evidenceRefused`
- `executedAny`
- `diagnosedOpIds`

It also has the `let enteredInbox = Mutex<…>` value and the immutable nested `InboxEntry` type. Every
production access to the five plain fields is inside `drainPendingQueue`, its actor-inheriting lane task,
`executeSingleOp`, or `retirePartiallyCompletedOp`; none is inside `Task.detached`, a task-group child, a
GRDB closure, or a `nonisolated` function. The outer-pass and post-drain reads happen only after
`for task in tasks { await task.value }` joins every lane.

Test seams construct a fresh context, await the actor-isolated operation, and only then inspect it. No
test or production caller shares one context between independent concurrent callers.

### Logical interleaving is not a memory race

Actor reentrancy lets lane B make progress while lane A awaits its provider, but the actor totally orders
the synchronous `Set` and `Bool` accesses. There is no pair of physically overlapping accesses, so the
original copy-on-write/heap-corruption escalation does not apply.

The only meaningful cross-lane timing effect is already benign: another lane may pass the
`failedAccounts` check before the first failure is recorded and make one extra provider attempt. A mutex
around the set cannot close that check-to-provider-call window because it spans an `await`.

### Durable fallback and retry audit

The queue's recovery mechanics do not make a real data race acceptable, but they were traced as a
separate validity check:

- claim status is persisted as `inFlight` in its own GRDB transaction;
- provider-evidence refusal and generic transient failure requeue the current operation, and `.haltLane`
  requeues the remaining claimed lane members;
- `evidenceRefused` prevents a same-drain repeat while the durable row remains for a later drain;
- successful retirement and partial narrowing are transactional;
- launch reconciliation returns ordinary stale `inFlight` operations to `queued`; under the accepted
  `IOS-MOVE-003` limitation, a durably claimed MOVE is dropped rather than blindly replayed.

For the MOVE case, `everAttempted` is set at claim time before any provider I/O. A process death can
therefore drop an intention that never emitted a command. Foreground sync restores server truth, not the
gesture; the user must repeat the move if it did not land. That accepted recovery narrows a hypothetical
crash's consequences but does not make memory unsafety acceptable.

Those fallbacks materially bound failures, but they do not establish the disposition. Actor serialization
does: the hypothesized corruption cannot occur.

### Shipped-release comparison

`v1.6.38` and `v1.7.8` already have the same owning sequence: `actor AccountManager`, an actor-inheriting
`Task { [self] in … }`, direct actor-property access inside that task, and actor-isolated
`executeSingleOp`. The isolation guarantee is not a new repair at `v1.7.9`; the alleged race did not exist
in those shipped releases either.

### What `@unchecked Sendable` actually means here

The annotation is required by the current shape because `capturedCtx` is captured by the `@Sendable`
closure passed to `ProviderWorkQueue.execute`; removing it produces a Swift 6 sendable-capture error even
though the closure only forwards the reference back to the actor. It is therefore misleading but not
evidence of a current race: the annotation pays for the isolation crossing, while actor discipline makes
the accesses safe.

The type does not encode that discipline. Because the class is `@unchecked Sendable`, a future
context-only mutation inside the provider-work closure, `Task.detached`, a task-group child, or a GRDB
closure would compile without an isolation diagnostic. A detached copy that also touches actor-isolated
`self` is rejected, but that does not guard the actual field-level hazard.

⚠️ **Policy deviation, recorded rather than hidden:** resilience rule 5 currently permits
`@unchecked Sendable` only for a Mutex-protected inner value or a wrapper around an inherently
thread-safe API. `DrainContext` is neither. The current runtime is safe by actor ownership, but the
annotation falls outside that rule's stated exceptions. Reclassifying the race as `not-defect` does not
silently waive the policy: this record inventories the deviation. A future hygiene change can remove the
annotation by keeping the context wholly actor-owned and eliminating the `@Sendable` capture; until then,
every new access must be censused and must restore the actor hop or protect moved state with `Mutex`.

`enteredInbox` keeps its existing `Mutex` as deliberate value-level future-proofing; its lock is not
evidence that the actor-isolated sibling fields are racy. Preserve it and protect consistency upward if a
sibling ever moves off-actor—never remove this lock merely because the plain siblings currently rely on
actor discipline.

### Why there is no source fix or red-first fuzz test

Adding locks would make a falsified premise appear confirmed, add overhead, and still not close the only
real TOCTOU across the provider `await`. A race fuzz test cannot go red on the parent revision because its
required precondition—two simultaneous field mutations—is prohibited by the actor executor. There is no
compiler guard on a future context-only off-actor mutation because `@unchecked Sendable` admits it; the
current invariant is proven by the complete access census and remains review-enforced until the
annotation is eliminated or the stored state gains value-level synchronization.

### Retracted original report

The 2026-08-13 record inferred physical concurrency from the facts that all lane tasks are created before
any is awaited and that they share one `@unchecked Sendable` reference. It then escalated concurrent
`Set.insert` to copy-on-write heap corruption and prescribed `Mutex` for every field. That inference
omitted inherited actor isolation and is retracted. Task lifetime overlap is not executor overlap.

## Related

- `IOS-QUEUE-001` — the lane key omitting the folder; same `buildLanes` neighbourhood, different defect.
- `IOS-QUEUE-004` — a census in this same file's comments that was wrong and is recorded as corrected;
  the precedent for fixing documentation about the drain in place rather than silently.
- `IOS-AI-004` — the ADR-IOS-008 decision-3 restoration whose new field prompted the false-positive
  report.
- `IOS-PERF-012` — the other pre-existing defect found in the same pass.
