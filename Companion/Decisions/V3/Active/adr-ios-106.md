## ADR-IOS-106: A CalDAV or Google Split Writes the New Part Before the Cap

**Status:** Active (2026-11-10). Replaces the cap-first order with a compensating rollback that
`CalDAVProvider.splitSeries` (`revertMasterCap`) and `GoogleCalendarProvider.splitSeries` (a revert
PATCH) used before. Outlook keeps cap first (see Consequences).

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
