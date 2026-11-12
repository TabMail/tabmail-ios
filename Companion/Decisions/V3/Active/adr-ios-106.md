## ADR-IOS-106: A CalDAV or Google Split Writes the New Part Before the Cap

**Status:** Active (2026-11-10). Replaces the cap-first order with a compensating rollback that
`CalDAVProvider.splitSeries` (`revertMasterCap`) and `GoogleCalendarProvider.splitSeries` (a revert
PATCH) used before. Outlook keeps cap first (see Consequences).
**Amended 2026-11-11 (#601):** every provider now writes the new part first, Outlook included, and a
retry finds its own split through a record kept on the queued operation; see the Amendment below. The
original text is kept as written.

**Context:** a this-and-following split writes two resources: the new part (a new `.ics`,
create-only) and the capped series (a PUT over the existing `.ics`). The cap removes everything at
or after the split: the occurrences the rule makes, and the changed occurrences (override VEVENTs),
excluded dates and added dates that the new part takes over. With the cap first, a cap whose
response was lost (timeout, dropped connection, app suspended) threw before the create. The retry
read the already-capped series and copied the new part from it, so the later changed occurrences
and dates were gone for good: an irreversible replacement (memory 102, item 6) run before its data
had a copy anywhere else.

**Decision:**
1. Create the new part first at its deterministic address: CalDAV create-only (`If-None-Match: *`),
   Google an insert under the deterministic event id.
2. An existing resource there goes on only on positive proof that it is ours (a retry): CalDAV
   `successorIsOurs` (our UID in the body), Google a 409 whose reason is `duplicate` and a proof-GET
   that reads it. Anything else rethrows with nothing written.
3. Then write the cap: CalDAV a PUT with `If-Match` the GET's ETag (`.unconditional` when the server
   sends none), Google the recurrence PATCH.
4. No rollback. A failed cap is rethrown. A 412 (a concurrent edit) or a transient failure is
   retried, and the retry finds its own new part and caps the series as it now stands.

**Consequences:**
- Every interruption leaves, at worst, both parts showing the occurrences after the split until the
  retry writes the cap. Nothing the series held at the split's read is lost; a change another
  client makes to the later occurrences after that read is not on the new part, and the cap
  removes it (the user re-applies it on the new part).
- A cap refused for good (an answer the queue retires as a bad request) leaves both parts showing
  those occurrences. One gesture repairs it: delete the new part, or the later occurrences.
- `revertMasterCap` and Google's revert PATCH are gone. Only Outlook still uses
  `splitRollbackError`. Closes #581 (Google's retry lost the excluded and added dates after the split).
- Outlook stays cap first. Its create is a POST whose only retry guard is Graph's `transactionId`, so
  create first would re-POST after every failed cap. What its retry after a lost cap response can
  lose is only the range end: a range already ending on this split's cap is written as `noEnd`
  (`splitNewPartJSON`'s `capEndDate`) so the new part does not end before it starts; the user can
  edit the end back.

**Alternative rejected:** keep cap first, cap only the RRULE, then trim the later items in a third
PUT conditioned on the cap's ETag. It keeps a window in which every later added date shows twice,
and adds a third write and its own failure arm, where the chosen order deletes one.

**Detail:** memory 142, "Write order and retries"; tests `CalDAVSplitRollbackTests`.

## Amendment (2026-11-11, #601): Outlook creates first; a retry is found by its record

**Context:** the retry guards above (CalDAV `successorIsOurs`, Google's 409 `duplicate`) recognised the
new part by its address. When the user deleted the new part between the two attempts, the retry wrote
it again (CalDAV) or wrote over a cancelled event (Google): a deleted event came back. Outlook still
capped first, so its interrupted split lost the new part and the retry was retired "not found" with the
series truncated.

**Decision (ruled 2026-11-10):**
1. **Every provider writes the new part first, then the cap.** Outlook's `splitSeries` now resolves, checks
   the occurrence, POSTs the new part, then caps (`splitCapJSON`, `writeSplitCap`). Its revert block and
   `splitRollbackError` are deleted; no provider rolls back.
2. **A record between the two writes.** Once the create is confirmed and BEFORE the cap, `splitSeries`
   hands a `SplitRecord` (`series_id`, `new_part_id`, `split_at`: ids and the split point only, no
   event content, ADR-004) to its `SplitRecorder`; the queue keeps it under the reserved
   `_split_record` argument (`AccountManager.recordSplit`, a fresh fetch and an `argumentsJSON`-only
   update). A recorder that throws stops the split before the cap. `queueCalendarOperation` strips the
   key from a tool call.
3. **A retry with a record never creates again.** It asks `CalendarProvider.eventExists` for the new
   part. There: `finishSplit` writes only the cap, from the series as it now stands, or nothing when the
   series already ends before the split (`RecurrenceTail.endsBeforeSplit`, Outlook
   `splitAlreadyEnded`). Deleted (Google `cancelled`, 404 or 410; Graph 404; CalDAV 404 or 410): the
   change is refused with nothing written, with the user-visible reason "This change to the repeating
   event wasn't finished because its new part was deleted. Check the event's later occurrences, and make
   the change again if you still want it." (`SplitRecord.newPartDeleted`). The row fails; the account's
   later changes drain.
4. **The own-cap retry rule is gone.** A series that already ends on this split's cap is no longer read
   as a retry (`isOwnSplitCap`, `RecurrenceTail.isCapped`, `splitCapUntil`, `afterOwnSplitCap`, the
   queue's `splitting` are deleted); without a record it is refused like any series that ends before the
   split. Google's 409 `duplicate` on a create without a record reads the event: live, the split goes on
   to record and cap; `cancelled`, refused with the same reason at once. A 404 or 410 there may be
   read-after-write lag right after Google said the id exists, so the operation stays queued until
   `SyncConfig.splitPartNotFoundGraceMinutes` (10) have passed since the first such answer, and only then
   is refused. The first answer's time is kept on the row under the reserved
   `_split_part_not_found_since` (`SplitRecorder.partNotFound`, `AccountManager.noteSplitPartNotFound`),
   stripped at queue time like the record. Ruled 2026-11-11: elapsed time, not a retry count, bounds it;
   while it waits, the account's later calendar changes wait behind it. A refusal on a retry reaches the
   user only as the failed row and the error log (no chat turn is waiting): open issue #600.

**Trade-offs:**
- The record is the only durable state added: two ids and a naive split time per in-flight split, gone
  with the row. It survives a transient requeue (the requeue updates only `status` and `retryCount`).
- Outlook's create now runs before every cap attempt, but only once per split: a retry with a record
  never POSTs, and a retry without one (the create's answer lost) leans on Graph's `transactionId`
  replay, which answers with the event while it is there.
- **Known limit:** a create that landed whose answer was lost leaves no record. If the user deletes that
  new part before the retry, Google refuses (409 on a gone id, then the read), but Outlook and CalDAV
  create it again: the deleted part appears again. One gesture repairs it.
- **Rows queued before this change:** an Outlook split interrupted after its cap (Outlook capped first
  then) now fails on retry, because the occurrence is no longer listed after the cap; never a false
  success.

**Detail:** memory 142 ("Write order and retries", amendment); memory 146 (amendment to "A split retried
after its own cap"); tests `SplitInterruptedBetweenItsWritesTests`, `SplitRecordIsReservedTests`.
