## `await dbPool.read` is NOT a short suspension — the async overload runs a full NSE staging merge first (2026-08-04)

**Any reasoning in this codebase that treats `await dbPool.read { … }` as a brief, bounded
suspension is UNSOUND on the foreground path.** This is a cross-cutting correctness fact, not a
performance note: it decides whether a check-then-act across an `await` is a race.

### The fact

`PrioritizedDatabase` in `TabMail/Services/PriorityGate.swift` carries a section banner reading
**"Read (passthrough — concurrent readers never block the writer)"**. That banner is true of the
**synchronous** overload, which really is `try pool.read(value)` and nothing else. It is **not**
true of the **async** overload, whose first statement is:

```
await NSEDataBridge.mergeIfStagingPending()
return try await pool.read(value)
```

`mergeIfStagingPending` is the read-through NSE staging drain. Called with no
`onSnapshotPublished` callback — which is how `read` calls it — it awaits the **whole** merge,
including phase-1's durable header write. `NSEDataBridge`'s own documentation records that write as
**measured 7.6 s** on a cold-I/O boot (killed-mid-sync WAL debt + cold FS caches, `boot_logs 5`,
2026-07-03); the comment appears twice, at `mergeIfStagingPendingPaintGate` and inside
`mergeNSEStagingData`. The paint gate exists *precisely because* that duration must never gate first
paint — which is the project's own admission of how long the suspension can be.

**Staging is pending exactly when it hurts: on foreground return and after a push.** So the slow
case is not exotic; it is the foreground path's normal case.

### Why it matters beyond latency

An actor method that reads a latch, then `await`s something whose first hop is
`PrioritizedDatabase.read`, has handed the actor over for a window that can be **seconds**, not
microseconds. Any other task can enter the actor and mutate that latch in between. *A latch that
authorises a state transition must be observed no later than the write that performs it* — and a
`dbPool.read` sitting between the check and the write is not a narrow gap. Reviewers have waved
such a gap through as "an await on a read, effectively instantaneous". It is not.

### The negative case — when it IS fast

Do not over-rotate: the merge is `~µs` when nothing is staged. Three fast paths short-circuit it —
`PriorityGate.inPrivilegedContext` recursion guard, `stagingPendingSignature()` returning nil when
staging is empty, and a signature-based skip for a KEPT gradual row (ADR-IOS-047) with a TTL.
**The point is not that every `await dbPool.read` is slow; it is that none of them is BOUNDED**, so
no correctness argument may assume a short suspension. Latency is a distribution; correctness has
to hold on its tail.

### Related

The `read` banner itself **has now been corrected** in `TabMail/Services/PriorityGate.swift`: the
section banner states the negative case explicitly ("the ASYNC overload is NOT a passthrough…"), and
`PrioritizedDatabase`'s type doc no longer claims async writes are the only added behaviour. This
entry records the cross-cutting consequence, which outlives any one comment fix.

The first defect this fact was proven to have caused is routed to
[`104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`](104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md)
(`IOS-OUTBOX-006`) — outbox reconciliation read the "no drain in flight" latch, `await`ed a
`dbPool.read`, and reset a row whose SMTP transaction was on the wire.
