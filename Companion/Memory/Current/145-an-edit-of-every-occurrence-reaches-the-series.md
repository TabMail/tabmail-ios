# An edit of every occurrence reaches the series

**Keywords:** `edit_scope` all, whole series, every occurrence, occurrence id, `CalendarSeriesScope`,
`CalendarSeriesScope.read`, `Named`, `route`, `routeEvery`, `fromHere`, `Routed`, `movedToFirst`,
`askWhichOccurrences`, `laterOccurrenceRefusal`, `dayMoveRefusal`, `namedDayParts`, `namesNoOccurrence`,
`GCalEvent.seriesZone`, `recurrenceTimeZoneName`, `CalendarProvider.occurrence`, `forSplit` (deleted),
`RecurrenceOccurrenceResolver.select`, `namesAnotherOccurrence`, `wasMoved`,
`resolveInstance`, `resolveInstanceId`, `CalDAVOccurrences.scopedEditSlot`, `originalStart(ofKey:in:)`,
moved occurrence, current start, named where it is now, split at a moved occurrence, collision,
`toolInstant`, start without seconds, series zone, BYDAY, BYMONTHDAY, BYYEARDAY, BYWEEKNO, BYMONTH,
BYSETPOS, named days, day move, `recurringEventId`, `seriesMasterId`, `originalStartTime`,
`originalStart`, `GCalEvent.originalStartTime`, `ExchangeCalendarProvider.originalStartTime`,
`allDayOccurrence`, `allDayPlace`, `Prefer: outlook.timezone`, all-day place read in the series' zone,
`eventSelect`, first occurrence, later occurrence, time of day, this-and-following, split, phantom
occurrence, `RecurrenceTail.isCapped`, `isOwnSplitCap`, `splitCapUntil`, `afterOwnSplitCap`, `splitting`,
own split cap, interrupted split, `routeSeriesTimeChange`, Google Calendar behaviour, retry, lost
response, not found, Graph series start before the first occurrence,
`queuedEventId`, `ruleChangeResetNote`, reset note, invariant property, #559, #560, #563, #613, #679,
#680, #683, #687.

## The rule

**An edit of every occurrence changes the series, whichever of its occurrences the event id names
(#560).** On Google, Outlook and CalDAV the listings and `calendar_event_read` give each occurrence its
own id, and `updateEvent` given that id changed that occurrence alone while the result said the change
applied to the entire series. The series is the one the occurrence's `recurringEventId` names (Google's
`recurringEventId`, Graph's `seriesMasterId`, CalDAV's series path).

**An occurrence is named by where it is now** (the #613 contract). A `recurrence_id` is always the
occurrence's current start as the read tools show it; nothing rewrites it to the occurrence's place in
the series. An occurrence id given with no `recurrence_id` names that occurrence at the start it has now.

**A time change of every occurrence goes where Google Calendar takes it (#559)**, the Thunderbird
add-on's `routeSeriesTimeChange`, done in `CalendarSeriesScope.route`:

- Named from the series' first occurrence, the whole series moves (a plain move, its `recurrence_id`
  kept).
- Named from a later occurrence, a new time of day on the date it is on now is the whole series' new
  time: the new start and end are moved back to the first occurrence's date, times of day kept
  (`movedToFirst`), and the edit is written as "all" with the series' id and no `recurrence_id`.
- Named from a later occurrence, a new date changes that occurrence and the ones after it
  (`this_and_following` at its current start, through the existing split). The earlier ones stay.
- With no occurrence named and the new start (or, for an end-only edit, the new end) on another date
  than the series' own, nothing is written; the assistant is told to ask the user
  (`askWhichOccurrences`, the add-on's words).
- An explicit `this_and_following` at the series' first occurrence is the whole series ("all", its
  `recurrence_id` kept). One before the first occurrence is refused.
- The series is never shifted by the distance from a later occurrence.

First or later is judged on the occurrence's PLACE in the series (`originalStartTime`); same date or
not, and the move back to the first date, on where it is NOW (`start`).

**A split at an occurrence moved from its place in the series is not supported** (owner ruling,
option A; #563 tracks splitting there, #687 the follow-up). It is a plain thrown error with nothing
written (`CalendarProviderError.notSupported("split at a moved occurrence")`). It is thrown ONLY by
`splitSeries`' own check, where a split is written, on all three providers, never by the occurrence
lookup (`occurrence(...)` finds a moved occurrence like any other). On CalDAV that check is #613's
`scopedEditSlot(forSplit: true)`, untouched, with its own words. It is deliberately NOT a finished
refusal: no dedicated wording and no work to order it before the card (coordinator rulings,
2026-11-11). So, on Google, Outlook and CalDAV alike:
- a split at a moved LATER occurrence (`this_and_following` named there, or an "all" new date named
  there, which `route` makes a split) shows its card, then the queued split throws at the drain, nothing
  written and the row left failed;
- `this_and_following` at a moved FIRST occurrence is routed to "all" (from the first occurrence on is
  every occurrence) and is written as an edit of the whole series; no split is written.
`wasMoved(_:)` compares the occurrence's `start` with its `originalStartTime`: a timed one by instant, an
all-day one by date, as text (every provider gives an all-day place as a date, see "Outlook's
`originalStart`"); an all-day place that is no date counts as moved. No zone is needed (option B, 2026-11-11).

**Dates are the series' own, in its zone** (`GCalEvent.seriesZone` = `recurrenceTimeZoneName ??
start.timeZone`, resolved by `CalendarTimeZoneResolver` alone; ONE source for every caller). Outlook
names its zone on the series' range (`recurrenceTimeZone`, mapped to `recurrenceTimeZoneName`); Google
names its IANA zone on `start`; CalDAV its TZID. When the zone is not known (an unrecognized name; a
CalDAV floating time; a CalDAV time written in UTC with no `TZID`, #679), a timed series' new start is
taken to be on another date: the side that splits, asks or refuses, never a wrong write. An all-day
series needs no zone: its places are dates on every provider (`CalendarSeriesScope.place`), so one in a
zone TabMail does not recognize is edited and split like any other.

Also refused, with nothing written: an occurrence whose place or start can't be read; a series whose
start can't be read; a deleted (`cancelled`) occurrence (the provider's lookup lists none: its
not-found, so the queue retires it; no separate status check); an occurrence id with a `recurrence_id`
naming ANOTHER occurrence (`namesAnotherOccurrence`); a `recurrence_id` at which two occurrences start,
named by the series' id (ambiguous).

## How the occurrence is found: one provider lookup

`CalendarProvider.occurrence(calendarId:eventId:recurrenceId:recurrenceIdZone:)` is the
provider's own lookup, the one its one-occurrence edit and split make; its default throws
`notSupported`. So what the write would refuse is refused by `read`, before the card, and nothing above
the provider layer asks which provider it is (ADR-IOS-060).

- Google: `resolveInstance` (returns `(id, instance)`) over `events.instances`, by current start;
  `RecurrenceOccurrenceResolver.select(...naming:)` prefers the occurrence the event id names, so an
  occurrence moved onto another's time, named by its own id and that time, names itself (S3).
- Outlook: `resolveInstanceId(...naming:)`, then `getEvent` (an all-day series: `allDayOccurrence`, read
  in the series' zone), then `wasMoved`. `eventSelect` names `originalStart`.
- CalDAV: `CalDAVProvider.occurrence` through `CalDAVOccurrences.scopedEdit` (returns `(key, slot)`)
  and #613's `scopedEditSlot`. That check also refuses a series whose STORED zone TabMail does not
  recognize ("which TabMail does not recognize"), so a CalDAV edit or split of such a series is refused
  before the card through this one path; the check is not copied, and listings and `getEvent` do not
  refuse (#649). `originalStartTime` is filled from the occurrence's key (`originalStart(ofKey:in:)`),
  so a moved CalDAV occurrence carries its place and its current start.

The lookup takes no scope: it is made as the one-occurrence edit makes it (CalDAV:
`scopedEdit(forSplit: false)`), for every scope. `forSplit` stays only on CalDAV's own check, which its
`splitSeries` makes with `true` (the rule read without its end, a moved occurrence refused, a resource
holding only changed occurrences refused). So a split of a resource holding only changed occurrences (an
invitation to single occurrences) is refused at the drain, after its card, as on `main` before #560.

`read` runs for every scope (one extra read per edit; a rename included), since only the event says
whether it is an occurrence.

## Where it is applied

- `CalendarEventEditTool.execute`, before the card: `read`, `route`, `dayMoveRefusal`. The card, the
  queued edit and the result all carry the routed scope; an "all" edit is queued with the series' id
  (`queuedEventId`). The card's reset note (`editResetsChangedOccurrences`, #423) is asked of
  `named.series` with the ROUTED arguments (PROOF P2): asked of the occurrence (no rule on Google and
  Outlook) with the edit as given, the card would show no note while the write resets. Google's check
  (`GoogleCalendarProvider.googleTimes`) keys each zone with `googleZone` at that time's instant: two
  zones are the same when `CalendarTimeZoneResolver` resolves them to one zone (an edit's "UTC", which
  the write names "GMT", is the series' own "UTC"), or when neither changes its clocks after that
  instant and both are at the same offset there ("Etc/UTC" and "UTC"; Atlantic/Reykjavik too). Two
  clock-changing zones at one offset today (America/New_York, America/Toronto) are never the same:
  their rules may part. No alias list. The Google fake resets on the same key. When the times are the
  series' own under that comparison, the write sends no start or end (`patchEvent`, 2026-11-11), so the
  stored zone stays and nothing resets; when either differs, both are sent.
  [Superseded 2026-11-11: "whether Google itself resets a series whose zone is only renamed to an equal
  one at the same instant is unmeasured" — the write no longer sends that rename.]
- `AccountManagerCalendarQueue`, `.edit`: the same `read` and `route` again, writing `writeId`. An "all"
  edit that `route` sends to a later occurrence is refused (`laterOccurrenceRefusal`): it reaches the
  queue as "all" only when the series changed after the card, and the user confirmed every occurrence.

## Outlook's `originalStart`

Graph's documentation calls it a `DateTimeOffset` in UTC. Measured live (2026-11-10,
`/me/events/{id}/instances`): every instance carries it as ISO 8601 with the event's own offset; a moved
exception shows its original slot there while `start` shows the moved time. An all-day instance's
`originalStart` is a UTC instant at local midnight in the series' zone (Tokyo's December 1 is
`…-11-30T15:00:00Z`). `ExchangeCalendarProvider.originalStartTime` maps every occurrence to the instant
(nil when no ISO 8601 date-time with a zone designator) on every ordinary read.

**An all-day occurrence's place is read in the series' own zone, as Graph names it** (option B,
coordinator ruling 2026-11-11, on the measurement of that day). Measured on a work account (all-day
series every two days in Pacific Standard Time, Tokyo Standard Time and Asia/Kathmandu, +5:45; a plain
occurrence and one moved a day earlier each; read by id and through `/instances`, identical): with
`Prefer: outlook.timezone` naming the series' zone, `originalStart` is local midnight with that zone's
offset (`2026-11-20T00:00:00+09:00`), and its date is the original day, for a plain occurrence equal to
its start's date. With no `Prefer` or `Prefer` UTC it is the UTC instant (`2026-11-19T15:00:00Z`), the day
before for a zone ahead of UTC. Graph accepted an IANA name for a series' zone (and gave it back as
given) and refused a made-up one (400 `TimeZoneNotSupportedException`). So the provider's occurrence
lookup (`occurrence`, which `CalendarSeriesScope.read` and `splitSeries` use) reads an all-day series'
occurrence by its id with `Prefer` naming `recurrenceTimeZoneName` exactly as Graph gave it, with no
device lookup of the zone (`allDayOccurrence`, `request(timeZoneName:)`), and takes the date part of
`originalStart` as text (`allDayPlace`). `CalendarSeriesScope.place` and `wasMoved` then compare dates
and need no zone, and the refusal of an all-day series whose zone TabMail does not recognize is gone.
`/instances` (`resolveInstanceId`) selects only `id,start` and is unchanged. A series whose range names
no zone at all is refused by the lookup, nothing written: Graph has named one on every series read so
far (a range written without one is read back as UTC, measured 2026-11-07), so this is not expected to
be reached.

Also measured: on Outlook a PATCH of the whole series' start or end resets its changed occurrences,
even with no recurrence sent. #560 makes an "all" time edit named by an occurrence id reach the series,
so it now has that effect; the card warns (#423, #680).

## A series on named days is not moved to another date without its new rule

`CalendarSeriesScope.dayMoveRefusal` is the one place this is decided. Refused when: scope "all" or
`this_and_following`; a `start_iso` on another date than what it moves (an "all" edit: the series'
start; a `this_and_following` edit: its occurrence's CURRENT start); the RRULE has a part in
`namedDayParts`; and the edit gives no `recurrence` the builder writes. Passes: another time on the
same date, an end alone, `this_only`, a rule naming no days. Dates in the series' zone; unknown zone:
refused. Runs before the card and before the write. Graph's weekly, monthly and yearly patterns always
name days, so on Outlook only a daily series moves to another date without a new rule.

## A split starts at one of the series' own occurrences

Google's and Outlook's `splitSeries` find the occurrence among the series' instances by its current
start (the same lookup as `occurrence`), and refuse with nothing written when none is there (a time
between two, a date off its days, a deleted occurrence), so no phantom part is written. CalDAV's split is
checked by #613.

**A split retried after its own cap is finished, not looked up again** (coordinator ruling, option X,
2026-11-11). Once the cap is written the series ends before the occurrence the split starts at, so a
lookup of it reports it not found. ONE predicate says "this split already capped the series":
`CalendarProvider.isOwnSplitCap(of:at:zone:)` (a protocol extension): the series' RRULE ends with the
`UNTIL` this provider's split writes at that `recurrence_id`, `RecurrenceTail.isCapped` over
`splitCapUntil(beforeNaiveISO:allDay:zone:)`, a pure protocol requirement (Google and CalDAV:
`googleUntilString`; Outlook: `graphEndDateBefore` without its dashes, the `UNTIL` its rule mapping
writes for a range ending on that date; default nil, no split). Called from both places:
- Google's and Outlook's `splitSeries` skip their occurrence lookup on it (Outlook's raw-range check is
  replaced by this equivalent one on the mapped rule). CalDAV's split has no such skip:
  `scopedEditSlot(forSplit: true)` reads the rule without its end, and `RecurrenceTail.newSeriesRule`
  knows its own cap.
- The queue's `read` (`splitting: true`, set for a given `this_and_following`) asks it right after the
  series is read, before the occurrence's own status and lookup, and returns `Named` with no occurrence
  and `afterOwnSplitCap`. `route` sends a split with no occurrence as given; `dayMoveRefusal` is not asked
  (the attempt that wrote the cap passed it, and the occurrence it would date is past the cap); the queue
  goes on to `splitSeries`, which writes what was not written. The edit tool passes `splitting: false`: a
  split asked for at a series that already ends there has nothing to split.
No provider's write order changed (#601 owns moving Outlook to create first). Outlook caps first, so its
interrupted split had lost the new part: the retry was retired "not found" with the series truncated.
Google and CalDAV write the cap last, so theirs had lost only the row's success.

The queue's `read` is still made on every retry and still looks the occurrence up where it starts now
for every other edit. So a retried first-occurrence date shift whose first response was lost can report
"not found" though the calendar holds the change (the series no longer starts where the edit named it;
the #683 class). An Outlook split queued with an OCCURRENCE id is not finished by its retry either: after
the cap Graph no longer has the occurrences from the split on, so the retry's first read of that id is
not found (as on `main`, where `splitSeries` read it through `resolveToMaster`); the tool queues a split
with the id it was given.

## The invariant property (tests)

For every (event_id, start_iso) pair the listing shows, an edit is either refused before the card (no
card, nothing queued, nothing written) or, once the queue has drained, the calendar holds what the card
said. Never a refusal after confirmation, except a split at a moved later occurrence: its card, then an
error at the write with nothing written and the row left failed (#563, #687). `this_and_following` at a
moved first occurrence is a written whole-series edit. `CalendarSeriesScopeTests.swift`
(`GoogleSeriesScopeInvariantTests`, `ExchangeSeriesScopeInvariantTests`) runs it table-driven over
states (unmoved, moved far, moved onto another (Google only), first moved, deleted), naming forms (own
id; own id and start; series id and start), scopes, and changes (rename, time of day, date with named
days, date with a plain rule, date with a new rule). CalDAV is covered by the occurrence matrix
(`CalDAVOccurrenceEditToolToWireTests`: a split at a moved later occurrence shows its card, then errors
at the write with nothing PUT or deleted; `this_and_following` at a moved first occurrence renames the
series with one PUT) and the unrecognized-zone row. The fakes filter `/instances` by where an occurrence is NOW, leave a
cancelled Google instance out of the list, and Graph refuses a PATCH moving an occurrence onto another
(`ErrorOccurrenceCrossingBoundary`).

A split interrupted after its cap ends complete on its retry (`SplitRetriedAfterItsOwnCapTests`: Outlook,
cap applied and its response lost, so no new part, then retried: the new part exists and the row is not
retired; Google, the cap's response lost on a series on named days given a new time; and
`CalDAVOccurrenceEditToolToWireTests.splitWhoseCapResponseWasLostEndsComplete`). The fakes model it:
`loseNextResponse` applies a write and drops its response; Graph's `/instances` leaves out occurrences
past a range's `endDate` in its `recurrenceTimeZone` (measured), Google's rule-changing PATCH drops the
stored instances. `drainEdit(..., drains:)` drains once per attempt.

## Known limits

1. One extra provider read per edit.
2. CalDAV "all" with no occurrence named and a new date asks the user.
3. A CalDAV series written in UTC with no `TZID` has no known zone (#679).
4. A split at a moved occurrence is not supported: a plain error, nothing written (#563, #687).
5. An Outlook "all" time edit resets the series' changed occurrences; the card warns (#680).
6. A retried edit whose first response was lost can report "not found" after the change applied (the
   #683 class): a first-occurrence date shift. A split interrupted after its cap is finished by its retry
   (`isOwnSplitCap`), except a split queued with an occurrence id: Outlook's id Graph no longer has
   after the cap (as on `main`), and Google's may read as not found though both writes landed (limit 10).
7. Graph's series start can fall before the series' first occurrence. First or later is judged against
   the series' start (`firstPlace`), so a date move named from the real first occurrence is taken as a
   later one and becomes a split there.
8. A split of a CalDAV resource that holds only changed occurrences is refused after its card, at the
   drain, as on `main` (its lookup no longer takes the split's scope): refused at the write, nothing
   written.
9. An Outlook all-day series with no recurrence zone name is refused by the occurrence lookup, nothing
   written. Expected unreachable: Graph reads a range written without a zone back labelled UTC
   (measured 2026-11-07).
10. A "this and following" split queued with an occurrence's own id and interrupted after its cap is not
    finished cleanly by its retry. Outlook: the retry is retired as not found, as on `main`: Graph no
    longer has that occurrence once the series is capped. #601 (create the new part first) closes it in
    the same release. Google (which creates the new part first): the retry may be reported "not found"
    although both writes landed; no data is lost. Whether Google answers a read of an instance past the
    new UNTIL with 404 (not found) or with the instance `cancelled` (handled: the own-cap check runs
    before the occurrence lookup) is unmeasured (#601).

## Superseded (rebuilt from main, 2026-11-10)

The first build of #559/#560 (not merged) is kept here for the record; each item was replaced by the
rule above when #613 settled that an occurrence is named where it is now.

- "The event id comes first": a `recurrence_id` equal to the current start of the occurrence the event
  id names was rewritten to its PLACE (`placeOfNamedOccurrence`), and splits ran at the place. Replaced:
  the `recurrence_id` stays the current start, and the providers' lookup resolves it.
- The card named a moved occurrence "now at X, originally Y" (`movedOccurrenceStart`). Replaced: the
  card names one time, where it is now.
- `GCalEvent.ownZone` / `ownTimeZone` (Outlook's `originalStartTimeZone`). Replaced by
  `GCalEvent.seriesZone` from the series' range zone (`recurrenceTimeZoneName`).
- Google and Outlook splits found the occurrence by PLACE (`resolveInstanceId(byPlace:)`,
  `.series(allDayZone:)`). Replaced: by current start; a moved occurrence's split throws a plain error.
- A split-producing "all" at a moved later occurrence threw at the queue; then (in the rebuild's first
  commit) a dedicated `movedSplitRefusal` before the card in `route`, with a proof that CalDAV refused
  it before the card. Replaced by the coordinator ruling (2026-11-11): a plain error, nothing written,
  no dedicated wording, no before-the-card ordering.
- That plain error was first thrown by the Google and Outlook occurrence lookup when `forSplit` was set,
  so `read` threw it before the card, and `this_and_following` at a moved FIRST occurrence (a whole-series
  edit) failed too. Replaced (review r1 ruling, 2026-11-11): only `splitSeries`' own check throws it.
- CalDAV's lookup kept `forSplit` (the protocol's `occurrence(...forSplit:)`, set for a GIVEN
  `this_and_following`), so CalDAV refused a split at a moved occurrence, and `this_and_following` at a
  moved FIRST occurrence, before the card. Replaced (round-2 ruling, 2026-11-11): `forSplit` deleted
  from the protocol and from `read` (and `read`'s `scope`); CalDAV's split refuses at the write, like
  Google's and Outlook's, and a moved first occurrence is a whole-series edit on all three.
- An Outlook all-day place, an instant, was dated in the series' zone (`seriesZone`) by
  `CalendarSeriesScope.place` and `wasMoved(_:seriesZone:)`, and an all-day series whose zone TabMail did
  not recognize was refused before the card and not split (`allDaySeriesWithoutAZoneIsNotSplit`).
  Replaced (option B, 2026-11-11): the provider reads the place in the series' zone as Graph names it and
  gives a date.
- The superseded items of the first build's own review (a later occurrence's new time of day split; the
  place compared in the edit's zone; Outlook's all-day `originalStart` read as a date) stay superseded.

## Known differences from the Thunderbird add-on

1. The add-on refuses a new rule given together with a day move (specific to its writer); here a new
   rule given with the move is what lets a series on named days move to another date.
