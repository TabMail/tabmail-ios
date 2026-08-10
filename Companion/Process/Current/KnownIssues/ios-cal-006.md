# IOS-CAL-006

> Routed from `KNOWN_ISSUES.md` line 1130 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed`
- Original row SHA-256: `4a577449f1df25af94311adf73d7560e09ac129eabfb214d64a6096adf6d0da3`

## Status

✅ **FIXED (2026-08-06, round-12 T8)** — three arms of `executeCalendarOperation` retired an op they had just declared unexecutable through the drain's **success** path, so the agent and the user were told the calendar operation had completed

## Subsystem and search terms

Calendar queue; `AccountManagerCalendarQueue.executeCalendarOperation`; `CalendarOperationType(rawValue:)`; missing `eventId`; success path; `signalCalendarOpOutcome`; `.permanentFailure`; `CalendarProviderError.notSupported`; `isCalendarUnsupportedError`; unresolvable identity; `eff3ded9d`; production-unreachable

## Full detail

**What was wrong.** An unrecognised persisted `operationType`, an edit with no `eventId`, and a delete with no `eventId` each logged *dropping* and then returned a nil pair. A normal return from that `throws` function IS the drain's success path: the row is deleted **and** `signalCalendarOpOutcome(.success(…))` fires, so `CalendarEventDeleteTool` reported *Calendar event deleted successfully.* for an operation that never touched the wire. The logs said one thing and the mechanism said the opposite.

**Reachability: none today, and it is fixed anyway.** All three producers are agent tools passing a non-optional `eventId: String` and a typed `CalendarOperationType`; the code is byte-identical to shipped. It is in scope because round 11 fixed exactly this shape at `eff3ded9d` **by classification rather than by relying on the caller never producing the value**, and that commit's body states the rule verbatim: an unresolvable identity is retryable, never a provider-authoritative stale result.

**What now holds.** Each arm throws `CalendarProviderError.notSupported(<reason>)` — the classification the same function already uses three times for malformed persisted requests — which `isCalendarUnsupportedError` claims, so the drain RETIRES the row and signals `.permanentFailure(reason:)`. ⚠️ **This said *"the drain deletes the row"* until R17-7.** R16-1 changed every terminal arm from `PendingCalendarOperation.deleteOne` to `retireCalendarOperation` (`status = 'failed'` with a durable reason), leaving the success arm as the only `deleteOne` in the file. The disposition is unchanged — the op leaves the queue unexecuted — only its mechanism is.

**Counterfactual discharged, both directions.** Success lies to the agent and to the user. A transient-classified throw is the **mirror image**: a genuinely unrecognisable persisted `operationType` is unrecognisable on every retry, so the op would starve and wedge the account's calendar lane forever. A permanent failure with a reason is the only arm that is honest and terminating.

**Verification.** `CalendarQueueOutcomeTests.unexecutableOpIsNotReportedAsSuccess()` — a durable `PendingCalendarOperation` of type `.delete` with a nil `eventId` inserted directly, then drained (red pre-fix: the awaited outcome was success). Non-vacuity is two-sided: the wire mock is asserted empty AND the durable queue is asserted to hold no CLAIMABLE row. ⚠️ **This said *"the durable queue is asserted empty"* until R17-7 and was stale from R16-1.** The test itself records the correction in full: `remaining.isEmpty` would have passed vacuously on a `deleteOne` that never ran, so it now asserts no row is left at `queued` or `inFlight` — the two statuses the drain and `reconcileCalendarQueue` re-claim — which is the property that actually pins the wedge shut.
