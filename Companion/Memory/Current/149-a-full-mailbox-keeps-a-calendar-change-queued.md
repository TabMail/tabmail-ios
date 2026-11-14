# An Outlook calendar change refused for a full mailbox stays queued (#865)

**Keywords:** Outlook; Microsoft Graph; 403; `ErrorQuotaExceeded`; mailbox full; quota; storage quota;
`ExchangeCalendarError.mailboxFull`; `missingScope`; `GraphAPI.isMailboxFull`; `GraphAPI.errorCodes`;
`innerError`; upload session; range PUT; `ExchangeProvider.addFileAttachment` `rangeRefused`;
calendar queue; transient arm; `CalendarWaitReason`; `PendingCalendarOperation.waitReasonKey`
(`_wait_reason`); `WaitingCalendarChangeBanner`; `LateCalendarFailureStore.waiting`; sign in again;
never drop; `IOS-CAL-003` accepted residual reversed; chat tool result; `CalendarToolHelpers.waitLine`;
`AccountManager.calendarWaitReason(accountId:)`; `toolClause`; still queued; queued behind; queue head;
`failedAccounts`; derived, not stamped.

## What was wrong

Graph answers a write to a mailbox over its storage quota with HTTP 403 and the error code
`ErrorQuotaExceeded`, the same status it gives a missing permission. `ExchangeCalendarProvider.request`
threw `ExchangeCalendarError.missingScope` for EVERY 403 without reading the body, so the calendar
queue's missing-permission arm raised "sign in again" (`markAuthFailed`) and retired the change
(`retireAndAnnounce(kind: .missingPermission)`). Signing in again cannot free space, and the user's
change was dropped. The upload session's range PUTs (`ExchangeProvider.addFileAttachment`, used by an
Outlook split to copy a file of 3 MB or more onto the new part) dropped the refusal's body entirely and
threw an anonymous `ProviderError.networkError` with the status only.

`IOS-CAL-003`'s "Accepted residual" (a 403 for quota or org policy is retired as a scope failure) was
written before this was seen; for the quota case it is reversed (see the amendment on that row).

## What holds now

- **One predicate at the boundary.** `GraphAPI.isMailboxFull(statusCode:errorBody:)`: the status is
  `GraphAPI.mailboxFullStatusCode` (403) and some code in the error body is
  `GraphAPI.mailboxFullErrorCode` (`ErrorQuotaExceeded`). `GraphAPI.errorCodes` reads `error.code` and
  each nested `error.innerError.code` (Graph's error resource: code against `code`, never `message`).
- **`request` tells the two 403s apart**, on the first response and on the retry after a forced token
  refresh: a full mailbox throws `ExchangeCalendarError.mailboxFull`; every other 403 is unchanged
  (`missingScope` first, raw `httpError(403, …)` after a refresh, both still the missing-permission arm).
- **The range PUT keeps the refusal.** `addFileAttachment` takes `rangeRefused(status, body)`, which
  turns a refused range into the caller's error. The draft caller passes
  `ExchangeProvider.uploadRangeRefusal` (the old `ProviderError.networkError`, unchanged); the calendar
  passes a closure that gives `mailboxFull` for a full mailbox and the same old error otherwise. The
  single attachment POST and `createUploadSession` already go through `request`.
- **The queue keeps the change.** No terminal arm claims `mailboxFull`, so it takes the transient arm: the
  row goes back to `queued`, `retryCount` grows, the account's other calendar changes wait behind it for
  that drain (`failedAccounts`, decided 2026-11-14), and nothing asks the user to sign in.
  `CalendarBadRequestClassificationTests`' roster pins it as not terminal.
- **The user sees why.** The requeue writes the reserved argument `_wait_reason`
  (`PendingCalendarOperation.waitReasonKey`, a `CalendarWaitReason`, today only `mailboxFull`) and clears
  it when a later attempt fails for another reason. `LateCalendarFailureStore.reload` also reads every
  `queued` or `inFlight` row with a wait reason into `waiting`, and the inbox shows one
  `WaitingCalendarChangeBanner` per row, laid out like the failure banner, with NO button: *"A calendar
  change is waiting: <title>. Your Outlook mailbox is full. Free up space and it will go through."*
  (wording decided 2026-11-14). It goes when the
  change is made (the row is deleted) or fails for good. The drain reloads the store when a wait reason was
  written, cleared, or its row left the queue. No column, no migration, nothing new persisted beyond the
  queue row the change already had.
- **The chat is told why, derived from the account's queue head.** A calendar tool whose change did not
  complete in-turn (create, edit, delete, and every occurrence of an exdate edit) reads the wait reason
  of its ACCOUNT's first queued calendar change in queue order (`createdAt`; queued or in flight), via
  `AccountManager.calendarWaitReason(accountId:)`, and adds one line, `CalendarToolHelpers.waitLine`:
  *"This change is waiting because the Outlook mailbox is full."* (per occurrence: `; waiting because …`).
  The reason is NOT stamped on the rows held back (decided 2026-11-14): the drain stops an
  account at its first failure (`failedAccounts`), so a change queued behind a mailbox-full change is never
  tried and waits for the same space; the head's reason is its reason too. This also covers an exdate
  edit's occurrences after the first. Rows created at the same instant (one exdate batch) are all the head,
  since the drain does not fix their order. When the head's reason is cleared (a later attempt fails for
  another reason), the line goes with it. The drain signals `.stillQueued` only after the requeue wrote the
  reason, so the head's own tool reads it; a change behind it learns the reason when its wait times out.
  (Superseded: the first version read only the change's own row, so a change queued behind got no line.)

## Not measured

Where Graph refuses an upload session for a full mailbox (at `createUploadSession`, a POST through
`request`, or at a range PUT) and whether the code arrives on the outer error or an `innerError`. Both
places and both nestings are handled; a live probe on a full mailbox would settle which one Graph uses.

## Tests

`CalendarMailboxFullTests` (the real queue against `FakeGraphCalendar`'s `refuseWrites`, for a create
POST, an edit PATCH, a split's single attachment POST and a split's upload-session range PUT: queued
through two drains, no sign-in prompt, no failure banner, the waiting banner shown, and the change made
once `acceptWrites` frees space; a full mailbox seen on the retry after a forced token refresh; a later
409 clearing the reason; and a 403 for another code still retired as missing permission with the sign-in
prompt), `GraphAPIMailboxFullTests` (`errorCodes` and `isMailboxFull` on the outer code, a nested
`innerError`, another code and another status), `CalendarBadRequestClassificationTests` (`mailboxFull` in
the roster and the transient list, not terminal) and `ExchangeCalendarErrorTests` (the exhaustive case
switch). `CalendarToolMailboxFullTests` runs the create, edit and delete tools, confirmed, against the
real queue with the write refused for a full mailbox (the result says why) and with a 409 (it does not),
and a create queued behind an older mailbox-full edit (it says why; once the head's reason is cleared by a
409, a later create does not). `CalendarEditExdatesOutlookTests.fullMailboxIsReportedForEveryOccurrence`
asserts the clause on both occurrences of an exdate edit, the second never attempted.
`CalendarWaitReasonQueryTests` pins the head query with fixed creation times: another account's
mailbox-full head does not answer, an in-flight head does, a stamp on either of two rows created at the
same instant answers, and a stamp on a row behind an unstamped head does not.

Red first on main (the four-write suite, before the fix): the create, PATCH and single attachment POST
cases were retired as `failed`/`missingPermission` with "sign in again" raised, 24 issues. The
upload-session case was already kept on main, as an anonymous transient (`ProviderError.networkError`),
so on main only its missing "mailbox full" reason was wrong, which no main-compatible test can name.
