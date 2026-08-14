> **✅ RESOLVED 2026-08-12 — the register now HAS an append path, so this file's title and its central
> claim are superseded. Everything below is preserved as the diagnosis that motivated the fix.**
>
> The owner authorised the repair. `Scripts/compact_known_issues.rb` now strips an explicitly
> delimited amendment block (`KNOWN-ISSUES-AMENDMENT-BEGIN` / `-END`) from a file's bytes before the
> byte-comparison, mirroring `exact_body` in the sibling companion script. Post-freeze detail files
> live in `Companion/Process/Current/KnownIssues/Amendments/`, which the orphan check does not glob
> because that glob is non-recursive.
>
> **This was cheaper than any of the three options weighed below**, and the reason is worth keeping:
> the objection to editing the archive was that it rewrites ~140 provenance headers and makes the
> archive's filename a lie, and the objection to a parallel register was that its index line had
> nowhere to live. Both assumed the amendment had to be *reachable by the generator*. It does not —
> it only has to be *invisible to the comparison*. The sibling script had solved exactly that
> problem, in this same tree, and the option was missed because the analysis was framed around where
> a record could be STORED rather than around what the verifier actually READS.
>
> Verified two-sidedly: with no amendments present `verify` is unchanged at exit 0; an amendment
> block prepended to a detail file verifies at 0; and wrapping a line of PRESERVED text is rejected
> at 1, because stripping removes it from the comparison while the regenerated expectation still
> contains it. An amendment can therefore only ADD — the no-content-loss proof is intact.
>
> **First users:** `IOS-IMAP-015` (a new post-freeze record), and corrections on `IOS-IMAP-005` and
> `IOS-IMAP-009` whose mechanism text SwiftMail PR #208 had falsified — `IOS-IMAP-009`'s accepted
> limitation is retired outright by that PR.
>
> ⚠️ **The four `RRULE UNTIL` residuals listed below are still unregistered.** The mechanism that
> blocked them is gone, but registering them is the calendar work's call, not this note's — they are
> another session's residuals and nobody should transcribe them second-hand.

# `KNOWN_ISSUES.md` is byte-frozen and has **no supported path to add a record**

**Discovered:** 2026-08-12, during the calendar `UNTIL` value-type remediation round, when a brief said
"register the residual in `KNOWN_ISSUES.md`" and the register refused it.

## The mechanism, measured

`Scripts/compact_known_issues.rb` rebuilds `KNOWN_ISSUES.md`, `Companion/Process/Current/KnownIssues/README.md`,
`manifest.tsv` and all ~140 detail files **from a hash-pinned archive** and byte-compares:

- `ARCHIVE_REL = "Companion/Process/History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt"`,
  `SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`.
- `generate` reads the archive **whenever it exists** (`source = archived`) and only falls back to the
  live `KNOWN_ISSUES.md` when the archive is absent. So regeneration can never pick up a new row: the
  archive, not the register, is the source of truth, permanently.
- `verify` rebuilds everything in memory from the archive and rejects any divergence. Empirically:
  appending one row to `KNOWN_ISSUES.md` → `content mismatch KNOWN_ISSUES.md`; adding a new
  `ios-cal-010.md` detail file → `orphan detail`.
- Current green state: `Known-issues hierarchy verified: 138 register + 2 historical`.

**So the MANTRA's instruction — "fail closed, register it in `KNOWN_ISSUES.md`, move on" — is currently
unexecutable for any issue discovered after 2026-08-09.** That is a real gap between a governing rule and
its artifact, not a mistake by whoever hit it. Since the 2026-08-09 split, exactly one commit has touched
the register (`629b6f642`, the split itself), which is why nobody had noticed.

## Do not "fix" it by either obvious route without the owner

1. **Editing the archive + `generate`** rewrites the provenance header of every detail file (each one
   cites the archive SHA) and makes the filename `known-issues-pre-hierarchy-2026-08-09` a lie — the file
   would no longer be the pre-hierarchy source it is named for. ~140 files churn per new issue.
2. **A parallel register** needs its index one-liner somewhere, and both `KNOWN_ISSUES.md` and the
   KnownIssues `README.md` are rebuilt-and-compared, so the pointer cannot live in either.

A third option exists — an amendments surface *outside* the census (mirroring `DECISIONS/V3/` and the
Memory `amendments-manifest.tsv`), indexed from `PROJECT_MEMORY.md` rather than from a frozen file — but
choosing it is a governance decision about how this repo's register grows, and it belongs to the owner.
**Until it is decided, record post-freeze residuals here and at the code site**, and say plainly in the
commit that the register could not accept them.

## Residuals currently unregistered because of this

From the `RRULE UNTIL` value-type work (`6a1dab5a0`, `656980f4d`). Residuals 1–3 are stated at the code in
`CalendarToolHelpers.validatedRRuleUntil` and `recurrenceUntilIsAtStake`; residual 4 is stated at
`AccountManagerCalendarQueue`'s `.edit` case, which is neither of those symbols (the preamble said "all
three … in `validatedRRuleUntil` and `recurrenceUntilIsAtStake`" above a four-item list until
2026-08-12):

1. **The all-day arm drops a supplied time.** `validatedRRuleUntil(_:allDay:zone:)` returns `datePart`
   for an all-day event, so `20261231T235959Z` becomes `20261231`. Deliberate — the date is the part the
   user meant, and RFC 5545 §3.3.10 forbids a DATE-TIME `UNTIL` against a `VALUE=DATE` `DTSTART`.
2. **A floating `DTSTART` has no representable `UNTIL`.** `CalDAVProvider.MasterDTStartKind` models
   `.floating` (`DTSTART:20260520T170000` — no `TZID`, no `Z`), and §3.3.10 wants a floating `UNTIL`
   against it. `allDay` is a `Bool`, so there is no value a caller can pass to ask for that third form;
   the timed arm emits UTC against a floating start. Not handled, and **not** claimed to be impossible.
3. **An explicit `all_day` is still taken at its word.** `all_day: true` with no `start_iso` on a *timed*
   resource still yields a bare-DATE `UNTIL` against a zoned `DTSTART`. Deliberately unfixed: stating
   `all_day` is how the agent converts a timed event to all-day and back, so overriding it would break
   the conversion. Only an **absent** `all_day` is resolved from the resource.

4. **The resolving GET is not the GET the write merges against** — added 2026-08-12 from the R2 review;
   **mechanism corrected the same day (R3), after two independent reviewers found three false claims in
   this entry.** `AccountManager.executeCalendarOperation`'s `.edit` case resolves the value type from
   `provider.getEvent`, but `CalDAVProvider.updateEvent` and `CalDAVProvider.splitSeries` each fetch the
   `.ics` again to merge, and the ETag they send protects only their own snapshot. A second client
   converting the event between the two reads reintroduces a mixed pair — type-of-check/type-of-use.

   **NOT "strictly narrower", and NOT a subset.** On CalDAV the DTSTART that lands is always the MERGE
   GET's kind (`formatDTLine` either re-emits in that kind or returns nil and leaves the line alone),
   while the UNTIL's kind comes from the RESOLVING GET. Work the four cases as (resolving-GET kind →
   merge-GET kind); pre-fix there was no resolving GET and the UNTIL was always timed:

   | case | pre-fix | post-fix |
   |---|---|---|
   | all-day → all-day | MISMATCH — the common, non-race case | consistent |
   | all-day → timed | consistent (right by accident) | MISMATCH — race only |
   | timed → all-day | MISMATCH | MISMATCH — race only |
   | timed → timed | consistent | consistent |

   The fix removes the only non-race case and introduces the mirror one; the two mismatch sets overlap on
   `timed → all-day` instead of nesting. Honest claim: **vastly smaller in probability, opposite in
   direction, not a subset.** The quantifier was wrong too — only an absent-`all_day` edit **on an
   all-day resource** produced a mismatch pre-fix, not "every absent-`all_day` edit"; `6a1dab5a0`'s own
   red evidence shows the timed test failing on `getEventCalls` only, never on the UNTIL value.

   **A rejected `PUT` is RETIRED, not retried.** `AccountManager.isCalendarBadRequestError` classifies a
   non-indeterminate 4xx as permanent and the drain then calls `retireAndAnnounce`. Read those two
   symbols for the exact code sets and for the case where the retire cannot persist — do not restate
   them here; the two attempts to do so were both wrong (the first transplanted a failed **GET**'s
   handling onto a rejected **PUT**; the second, on 2026-08-12, omitted that the indeterminate codes are
   excluded on the Google and Exchange arms too, and stated the `.permanentFailure` signal
   unconditionally when `retireAndAnnounce` announces `.stillQueued` if the durable write fails — which
   fails SAFE, leaving the row retryable). This entry said the `PUT`
   was "visibly rejected and retried … with a fresh GET" until 2026-08-12: that was `6a1dab5a0`'s
   statement about a failed **GET** transplanted onto a rejected **PUT**, which the drain classifies the
   opposite way. Recovery is therefore a fresh user request, which still clears THE MANTRA's
   one-ordinary-gesture bar, so the disposition is unchanged — only the mechanism. On
   `edit_scope: "this_and_following"` it is the pre-existing `splitSeries` cap-`PUT` hazard (irreversible
   wire operation #6, best-effort rollback), neither created nor widened here. Deliberately unfixed:
   closing it means threading each provider's merge snapshot back out to the queue across three
   providers, which is a mechanism for a rare recoverable edge.

   The fifth, smaller item lives at the code rather than here because it is not a residual:
   `resolvedAllDay` also switches `buildGCalEventInput`'s start/end renderer. **What that costs is
   per-provider, and this file had CalDAV backwards.** `mergePatchIntoICS` computes
   `let kind = masterDTStartKind(from: result)` — the RESOURCE's value type — and `formatDTLine`'s
   `.allDay` arm reads only `patch.startDate` / `patch.endDate`, returning nil for a timed patch. So
   pre-fix, a timed `start_iso` against an all-day master left DTSTART **unreplaced** while the RRULE
   **was** replaced: `DTSTART;VALUE=DATE:` against `UNTIL=…T…Z`, which IS the §3.3.10 mismatch, not the
   "already self-consistent" pair claimed here until 2026-08-12. On CalDAV the fix therefore **closes**
   that mismatch and additionally makes the date half of the move land, where pre-fix nothing landed.
   The claimed recovery — "one further edit stating `all_day: false`" — also does not work on CalDAV:
   with `all_day: false` the patch sets `startDateTime` and leaves `startDate` nil, so `formatDTLine`
   returns nil again and the resource stays all-day. An all-day↔timed conversion is **not expressible
   through `CalDAVProvider.updateEvent` at all** — `formatDTLine` re-emits in the master's kind by design
   (its comment cites RFC 5545 §3.8.4.4). That is pre-existing, not this train's doing, and it means
   resolving `allDay` from the resource agrees with what the merge would have done anyway. The narrowing
   is real on **Google and Exchange**: `GoogleCalendarProvider.mergeExistingEventWithPatch` copies
   `patch.startDateTime` straight through when the patch carries a start, and Google's `toJSON` /
   `ExchangeCalendarProvider.toGraphEventJSON` emit `start.dateTime` (Graph additionally stamps
   `isAllDay: false`), so there a timed `start_iso` used to convert the event and now does not.

**Also corrected at the code on 2026-08-12 (R3), recorded here because the argument is not needed at the
call site.** `validatedRRuleUntil`'s note claimed the pre-fix alternative on the split path was "a capped
master plus a failed successor create under a best-effort rollback, i.e. destroyed occurrences".
`CalDAVProvider.revertMasterCap` PUTs `originalICS` back and **rethrows the cause**, so occurrences
survive the ordinary path; they are destroyed only when the revert ALSO fails
(`CalDAVError.inconsistentState`) or under the `capETag == nil` + concurrent-editor case already
registered as `IOS-CAL-002`. The same sentence's "nothing written" was loose as well — the cap `PUT` has
landed by then, and it is the revert that restores the master. The `20261340` example went with that
paragraph: it held on the all-day and already-UTC arms, but the naive arm's `DateFormatter` already
rejected month 13 pre-fix, so it was false for the arm the paragraph was about. The surviving inline note
keeps only what an omitted UNTIL costs a `this_and_following` successor.

Reachability for the first three: agent-initiated recurring-event edits only; the update `PUT` fails visibly on
a strict server, and on `edit_scope: "this_and_following"` the malformed rule lands in the successor
series *after* `CalDAVProvider.splitSeries`' cap `PUT` — one of the six irreversible wire operations —
under a best-effort rollback. Residual 4 is narrower still: it needs a second client to convert the
event's value type inside the window between one edit's two GETs. Attribution class: accepted recoverable
limitation (1, 3, 4) and unhandled form (2).

Related: [[113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation]] for the same shape
of problem — a rule whose artifact does not support it.
