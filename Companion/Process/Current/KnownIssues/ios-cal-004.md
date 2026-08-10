# IOS-CAL-004

> Routed from `KNOWN_ISSUES.md` line 1127 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed`
- Original row SHA-256: `b6ba23af39c48d634738de170c49f15da692c20a4a749de8c3456cd49b6f81ec`

## Status

✅ **FIXED (2026-08-06, round-12 T5)** — Exchange calendar create was non-idempotent, so a retry after the newly-retryable 408 could leave the user with two identical events; it now sends the pre-generated event id as Graph's `transactionId`

## Subsystem and search terms

Calendar; Exchange; Microsoft Graph; idempotency; `transactionId`; `ExchangeCalendarProvider.createEvent`; `createEventJSON`; `toGraphEventJSON`; 408 retry; duplicate event; `GCalEventInput.id`; `GoogleCalendarProvider.createEvent`; `CalDAVProvider.createEvent`; `If-None-Match`; 412

## Full detail

**What was wrong.** `POST /events` carried no client-supplied identity, so a request whose response was lost and then retried created a second event. The two sibling providers were already idempotent and only Exchange was not: `GoogleCalendarProvider.createEvent` posts `event.toJSON()`, which **includes** `id`, and `CalDAVProvider.createEvent` uses `event.id` as the resource filename under `If-None-Match: *` (the drain reads the resulting 412 as success).

**What now holds.** `createEventJSON(_:)` adds the `transactionId` key when the input carries a non-empty pre-generated id of at most 256 characters (Graph's documented cap). Graph rejects a second create bearing a `transactionId` it has already seen, so the retry is a no-op rather than a duplicate. The 256-char guard and the empty-id guard mean a malformed id degrades to the previous behaviour rather than to a 400.

**Counterfactual discharged.** Not sending the key buys nothing — the field is ignored by servers that do not implement it — while the cost of omitting it is a duplicate calendar event, which the user must delete manually on a wire operation whose sibling delete path is `IOS-CALDAV-001`.

**Verification.** `ExchangeCalendarTests.createEventCarriesIdempotencyKey()` (red pre-fix: the `transactionId` value was nil against the input id), with the negative case (no id ⇒ no key) and a sibling-parity assertion that the Google JSON still carries `id`.
