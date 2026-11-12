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
all-day occurrence named by its date in the series' zone (Rule 3 on Outlook, #647),
`eventSelect`, first occurrence, later occurrence, time of day, this-and-following, split, phantom
occurrence, `RecurrenceTail.isCapped`, `isOwnSplitCap`, `splitCapUntil`, `afterOwnSplitCap`, `splitting`,
own split cap, interrupted split, `routeSeriesTimeChange`, Google Calendar behaviour, retry, lost
response, not found, Graph series start before the first occurrence,
`queuedEventId`, `ruleChangeResetNote`, reset note, invariant property, #559, #560, #563, #613, #679,
#680, #683, #687, #720, `usesSeries`, `readSeries`, `seriesNotRead`, `seriesNotInThisCalendar`,
`holdsOnlyChangedOccurrences`, override-only, changed occurrences only, invitation to single
occurrences, series not in this calendar, `parseError`, No VEVENT found, wedge, `failedAccounts`.

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
refusal: no dedicated wording and no work to order it before the card (ruled
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
zone TabMail does not recognize is edited and split like any other. On Outlook the same zone, as the
range names it, is also the label of every start and end written to the series, timed (#719) or all
day (#747: another label is stored two days longer; memory 140).

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
  in the series' zone), then `wasMoved`. `eventSelect` names `originalStart`. For an all-day series
  `resolveInstanceId` reads `/instances` in the series' zone too and gives each occurrence as its DATE
  (#647, "An all-day occurrence is named by its date" below).
- CalDAV: `CalDAVProvider.occurrence` through `CalDAVOccurrences.scopedEdit` (returns `(key, slot)`)
  and #613's `scopedEditSlot`. That check also refuses a series whose STORED zone TabMail does not
  recognize ("which TabMail does not recognize"), so a CalDAV edit or split of such a series is refused
  before the card through this one path; the check is not copied, and listings and `getEvent` do not
  refuse (#649). `originalStartTime` is filled from the occurrence's key (`originalStart(ofKey:in:)`),
  so a moved CalDAV occurrence carries its place and its current start.

The lookup takes no scope: it is made as the one-occurrence edit makes it (CalDAV:
`scopedEdit(forSplit: false)`), for every scope. `forSplit` stays only on CalDAV's own check, which its
`splitSeries` makes with `true` (the rule read without its end, a moved occurrence refused, a resource
holding only changed occurrences refused).
[Superseded 2026-11-11 (#720): "So a split of a resource holding only changed occurrences (an
invitation to single occurrences) is refused at the drain, after its card, as on `main` before #560."
It is now refused before the card; see "A series that is not in this calendar" below.]

`read` runs for every scope (one extra read per edit; a rename included), since only the event says
whether it is an occurrence. **Amended 2026-11-11 (#720):** the event is read for every scope; the
SERIES of an occurrence is read only for a scope that uses it (`CalendarSeriesScope.usesSeries`: "all"
and `this_and_following`). `read` takes the given `scope` (the tool's `resolvedScope`, the queue's
`givenScope`); a `this_only` edit reads the event and the provider's lookup (`occurrence(...)`) only, and
`Named.series` is nil. No `this_only` path used the series (`route` returns it as given,
`dayMoveRefusal` passes it, the card shows the event, the queue writes `routed.eventId`).

## A series that is not in this calendar (#720)

A CalDAV resource can hold only changed occurrences, with no series VEVENT: an invitation to single
occurrences of someone else's series (RFC 4791 §4.1; ADR-IOS-108). A listing gives each occurrence
`recurringEventId` = the resource href, so `read` took it for a readable series and GET the href:
`getEvent` threw `CalDAVError.parseError("No VEVENT found")`, which no terminal arm of the calendar queue
claims. Through the tool it was a misleading refusal before the card (and ADR-IOS-108's `this_only` edit
of such an occurrence, written before #560, was refused); at the drain it was requeued on every drain and
held the account's later calendar operations through `failedAccounts` (the never-drop wedge corollary).

The fix is in the read and at the address, not in the queue's classification (a `parseError` stays
transient: an empty 2xx body is indeterminate, `CalendarBadRequestClassificationTests`):
- `read` does not read the series for `this_only` (above), so that edit is written again, before the
  card and at the drain, through CalDAV's own one-occurrence lookup and write.
- `CalDAVProvider.getEvent` of such a resource's own id throws the final answer
  `CalendarProviderError.notSupported(CalDAVOccurrences.seriesNotInThisCalendar)`: the series is not in
  this calendar, so it can't be changed as a whole or split; one of its occurrences can be changed with
  `this_only`, by the id listed for it and its `start_iso`. `scopedEdit`'s no-series branch (the resource's
  own id, or a split) throws the same reason. A resource with no VEVENT at all stays `parseError`.
  **Since #694 (2026-11-11; the lines above are kept as history):** the refusal is the neutral case
  `CalendarProviderError.seriesNotInThisCalendar`, thrown at the same two places, so no caller above
  `CalendarProvider` names a CalDAV constant. An edit words it with
  `CalendarProviderError.seriesNotInThisCalendarReason` (the text above, unchanged for the user, read
  through `CalendarProviderError.reason`); the queue's unsupported arm takes every `CalendarProviderError`
  and retires with that `reason`; `exdates_add` words it for removing dates (memory 144).
- So "all" (or no scope and no `recurrence_id`) and `this_and_following` named by such an occurrence are
  refused before the card, and a row that reaches the drain (the resource rewritten between the card and
  the drain) is retired by the unsupported arm in that drain; never requeued.
- **Invariant: an "all" edit never reaches `updateEvent(href)` on this shape.** `Named.series` is
  optional; `route` gets it through `Named.readSeries()`, which throws for a scope that uses the series
  when it was not read (`seriesNotRead`), so such an edit is never routed as given; `dayMoveRefusal`
  refuses with the same reason; the queue's written event and the tool's card take it through
  `readSeries()`. `series` is never filled with the occurrence.
- The id a listing gave while the resource held its series still names the occurrence after the server
  rewrites it to hold only that occurrence (the key is the instant, UTC, or the date, read from the
  RECURRENCE-ID either way), so a `this_only` row drained after such a rewrite is written.

Tests: `CalDAVOccurrenceEditToolToWireTests.overrideOnlyResourceWriteMatchesTheCardOrIsRefusedBeforeIt`
(RECURRENCE-ID forms tzid, utc, date × every scope, from the tool to the wire: `this_only` written as its
card said, every other scope no card, nothing queued, the resource byte for byte),
`RewrittenAfterTheCardTests` (`CalendarSeriesScopeTests.swift`: the resource rewritten between the card
and the drain, and a `this_only` row already queued against the shape, each with a second operation on
the account: after ONE drain nothing is queued, the second operation ran, the edit written or retired),
and `CalDAVOccurrenceWireTests.overrideOnlyResourceRefusesWhatItCannotAddress` (a read of the own id).

Not measured, carried separately: whether Google or Outlook give an invitee to one occurrence an instance
whose series that account can't read (the twin of this shape). Their own lookup and write already GET the
series (`resolveToMaster`), so `read`'s series GET adds no new failure there.

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

**An all-day occurrence's place is read in the series' own zone, as Graph names it** (ruled
2026-11-11, on the measurement of that day). Measured on a work account (all-day
series every two days in Pacific Standard Time, Tokyo Standard Time and Asia/Kathmandu, +5:45; a plain
occurrence and one moved a day earlier each; read by id and through `/instances`, identical): with
`Prefer: outlook.timezone` naming the series' zone, `originalStart` is local midnight with that zone's
offset (`2026-11-20T00:00:00+09:00`), and its date is the original day, for a plain occurrence equal to
its start's date. With no `Prefer` or `Prefer` UTC it is the UTC instant (`2026-11-19T15:00:00Z`), the day
before for a zone ahead of UTC. Graph accepted an IANA name for a series' zone (and gave it back as
given) and refused a made-up one (400 `TimeZoneNotSupportedException`). It also refuses a series
PATCH whose timed start is labelled with a zone other than the series' own (400
`ErrorPropertyValidationFailure`, measured 2026-11-11 with `America/Vancouver` and `America/New_York`
on a series kept in Pacific Standard Time), so the series' zone governs writes too: every timed time
written to an Outlook series is labelled with that zone as Graph names it (#719, memory 140). So the provider's occurrence
lookup (`occurrence`, which `CalendarSeriesScope.read` and `splitSeries` use) reads an all-day series'
occurrence by its id with `Prefer` naming `recurrenceTimeZoneName` exactly as Graph gave it, with no
device lookup of the zone (`allDayOccurrence`, `request(timeZoneName:)`), and takes the date part of
`originalStart` as text (`allDayPlace`). `CalendarSeriesScope.place` and `wasMoved` then compare dates
and need no zone, and the refusal of an all-day series whose zone TabMail does not recognize is gone.
`/instances` (`resolveInstanceId`) selects only `id,start` and is unchanged. [Superseded 2026-11-11 by
#647 for an all-day series, next paragraph.] A series whose range names
no zone at all is refused by the lookup, nothing written: Graph has named one on every series read so
far (a range written without one is read back as UTC, measured 2026-11-07), so this is not expected to
be reached.

**An all-day occurrence is named by its date (#647).** `resolveInstanceId` read every candidate as an
instant from `start` under `Prefer` naming the device's zone, with `dateOnly` nil even for all-day
instances, so the resolver's Rule 3 (an all-day candidate answers only to its literal date) never applied
on Outlook. Graph returns an all-day start as midnight of its own date labelled with the read's zone (see
the measurement below), so the candidate was midnight of that date ON THE DEVICE. An edit whose `timezone`
differs from the device's matched it in another frame: from a zone west of the device's, a date named the
next day's occurrence of a daily series (a weekly one: not found), and the read tools' `DT00:00:00` form
(`allDayNaiveISO`), and an occurrence id given alone (`shownStart`), matched nothing. With #694's
`exdates_add` the same lookup picks which occurrence is DELETED. Now, for an all-day series, each start
is read as its date the way every all-day start is (`toGCalDateTime(_:isAllDay: true)`, its first ten
characters), so each candidate is a DATE and Rule 3 applies, whatever zone the edit names. `/instances`
is read in the device's zone, as before: Graph only relabels an all-day start, so the zone changes no date.
[Superseded the same day: the first build also read `/instances` with `Prefer` naming the series' zone
(`allDayZoneName`); its mutants survived, since no date depends on that zone, so it was deleted and
`allDayOccurrence` keeps its own no-zone refusal.] Every caller gets it: `updateOccurrence`
(this_only), `occurrence(...)` (the edit tool's and the queue's `read`, #694's delete lookup) and
`splitSeries` (through `occurrence`). Timed series are unchanged; Google and CalDAV were already by date.

**Measured (2026-11-11, work account): Graph RELABELS an all-day start, it does not convert it.** An
all-day series kept in a zone east of the reading zone, read through `/me/calendarView`,
`/me/events/{id}` and `/me/events/{id}/instances`, with `Prefer: outlook.timezone` naming the series'
zone, a zone west of it, and no `Prefer` at all: every read gave `start` (and `end`) as midnight of the
occurrence's own date, and only `timeZone` changed (the zone `Prefer` named; `UTC` with none). Its
`originalStart` IS converted as an instant (above). So the read tools (device zone) and the lookup show
the same date. `FakeGraphCalendar` renders all-day starts and ends that way on every read.
`ExchangeAllDayOccurrenceDateTests` pins the invariant with zones chosen from the device's, so every row
crosses a date boundary on any host (the series east of the device; the edit naming the device's zone or
one west of it), daily and weekly: a date, and the `DT00:00:00` form, name exactly their own date's
occurrence (this_only edit and the occurrence read); the start the read tools show (the listing and a read
by id, through `formatDetailedEvent`), given with the series' id or the occurrence's own, changes exactly
that occurrence; and an edit of every occurrence named by an occurrence id alone (`shownStart`) finds it
and renames the series, no occurrence. Still assumed (unchanged):
`/instances`' `startDateTime`/`endDateTime`, sent without an offset, are read as UTC whatever `Prefer`
names. [Superseded the same day: the first version of this paragraph assumed Graph converts an all-day
`start` like `originalStart`, named a London series edited from New York as the failing case, and had the
fake convert it (`allDayTimesFollowPrefer`, deleted).]

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

**Superseded by #658 (2026-11-11): a series on named days moves them with it, as Google Calendar does.**
`dayMoveRefusal` is replaced by `CalendarSeriesScope.dayMove`, which returns the move
(`RecurrenceDayShift.Move`, from and to days in the series' frame) under the same conditions the
refusal used (scope, new date, named-day RRULE, no rule given, series' zone). A split's move is judged
"another date?" on where its occurrence is now, but counted from its place in the series
(`originalStartTime ?? start`); a split with no occurrence read gets no move (the scope switch refuses
the missing `recurrence_id`). The queue puts the move on `GCalEventInput.ruleDayMove`; each provider
turns the rule IT writes: Google `turned` (whole series) and the split's `splitTailRule` result;
CalDAV `mergePatchIntoICS` (whole series and the split's new part); Outlook `turned` on the stored
Graph pattern (`graphPatchJSON`, `newPartRecurrence`). A split's COUNT stays each provider's own #474
computation, turned afterwards. Rules (`RecurrenceDayShift.shifted`): weekdays turn by the days moved
(WKST too for weekly INTERVAL>1); BYMONTHDAY by the change in day of month, BYMONTH by the change in
month; a positional day (numbered BYDAY, BYSETPOS, Graph relative patterns) keeps the WHOLE rule;
BYYEARDAY, BYWEEKNO, a negative BYMONTHDAY and one moved out of 1..31 are refused before the card.
When the written rule differs from the stored one (`canonicalRRULE`), exceptions reset: Google's split
new part drops its EXDATE lines and keeps RDATE; CalDAV drops EXDATE and override VEVENTs and keeps RDATE;
Outlook's pattern change already resets. The card asks `CalendarProvider.dayMovedRules` (built by the
same functions the write uses) and, in "all" and `this_and_following` alike, lists `repeat → <rule>`
plus `CalendarToolHelpers.dayMoveResetNote` only when a rule actually turns; a positional rule shows
neither. Rebuilt on #754's split (#601 `SplitRecord`): a split interrupted after its new part exists
is finished by `finishSplit` from its record, which writes only the cap and never asks `dayMove`
again, so the new part keeps the rule turned on the first attempt (test
`SplitInterruptedBetweenItsWritesTests.dayMoveSplitFinishedFromItsRecord`). The first build's
retry-after-own-cap dating from `recurrence_id` and its Outlook `capEndDate`→`noEnd` case went with
`afterOwnSplitCap`. The picked day is converted into the series' zone before its weekday is read, a
deliberate difference from Google's web app. On Outlook the move's days
(`GCalEvent.seriesZone` frame) and #747's `seriesDay` (the split's `newDay`, the date-move step's
check) are both series-zone days; `splitNewPartJSON` turns the pattern in `newPartRecurrence`, then
relabels start and end with `inSeriesZone` as #747 does.

## A split starts at one of the series' own occurrences

Google's and Outlook's `splitSeries` find the occurrence among the series' instances by its current
start (the same lookup as `occurrence`), and refuse with nothing written when none is there (a time
between two, a date off its days, a deleted occurrence), so no phantom part is written. CalDAV's split is
checked by #613.

**A split retried after its own cap is finished, not looked up again** (ruled
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

**Amendment (2026-11-11, #601): superseded by the split record.** The own-cap rule above is gone:
`isOwnSplitCap`, `RecurrenceTail.isCapped`, `splitCapUntil`, `afterOwnSplitCap` and the queue `read`'s
`splitting` are deleted. Every provider writes the new part first and keeps a `SplitRecord` on the queued
row before the cap (memory 142, amendment; ADR-IOS-106, amendment). A retry with a record skips `read` and
`route` entirely: `eventExists` on the new part, then `finishSplit`, or the refusal
`SplitRecord.newPartDeleted` when the user deleted it. A retry without a record reads and looks the
occurrence up like any edit, and a series that already ends on this split's cap is refused, not finished
(`RecurrenceTail.newSeriesRule` on Google and CalDAV; on Outlook the occurrence lookup, since Graph lists no
occurrence past the range's end). An Outlook split named by an OCCURRENCE id
and interrupted after its create now ends complete on its retry: the record names the series and the new
part, so the occurrence Graph no longer lists after the cap is never read again.

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

Since #601 (2026-11-11): `SplitInterruptedBetweenItsWritesTests` (a split interrupted between its writes:
finished by its record while the new part is there, by series or occurrence id; refused with nothing written
once the user deleted it; the next queued change drains) replaces the suite named below. History:
A split interrupted after its cap ends complete on its retry (`SplitRetriedAfterItsOwnCapTests`: Outlook,
cap applied and its response lost, so no new part, then retried: the new part exists and the row is not
retired; Google, the cap's response lost on a series on named days given a new time; and
`CalDAVOccurrenceEditToolToWireTests.splitWhoseCapResponseWasLostEndsComplete`). The fakes model it:
`loseNextResponse` applies a write and drops its response; Graph's `/instances` leaves out occurrences
past a range's `endDate` in its `recurrenceTimeZone` (measured), Google's rule-changing PATCH drops the
stored instances. `drainEdit(..., drains:)` drains once per attempt.

## Known limits

1. One extra provider read per edit (amended #720: for "all" and `this_and_following`; `this_only` reads
   no series).
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
8. **Closed 2026-11-11 (#720).** Was: "A split of a CalDAV resource that holds only changed occurrences
   is refused after its card, at the drain, as on `main` (its lookup no longer takes the split's scope):
   refused at the write, nothing written." Now refused before the card, as is an edit of every
   occurrence there: the series is not in this calendar (`seriesNotInThisCalendar`).
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
    **Amendment (2026-11-11, #601): closed.** A split interrupted after its create keeps a `SplitRecord`
    naming the series and the new part; its retry never reads the occurrence again, by either id, and
    ends complete (`SplitInterruptedBetweenItsWritesTests` T3). Limit 6's own-cap clause is gone with it.
11. Outlook's occurrence lookup enumerates 25 hours either side of the named date's midnight in the
    edit's zone. An all-day occurrence lasts from midnight in the series' zone, so when the edit's zone
    is 25 hours or more east of the series' (Kiritimati or Tonga against Pago Pago, Niue or Baker
    Island) the named date's occurrence is outside the window and the edit is refused as not found,
    nothing written (#647).

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
  it before the card. Replaced by the ruling of 2026-11-11: a plain error, nothing written,
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
