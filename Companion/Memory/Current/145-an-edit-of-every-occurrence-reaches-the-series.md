# An edit of every occurrence reaches the series

**Keywords:** `edit_scope` all, whole series, every occurrence, occurrence id, `CalendarSeriesScope`,
`CalendarSeriesScope.read`, `Named`, `route`, `routeEvery`, `fromHere`, `Routed`, `movedToFirst`,
`askWhichOccurrences`, `laterOccurrenceRefusal`, `dayMoveRefusal`, `namedDayParts`, `namesNoOccurrence`,
`GCalEvent.seriesZone`, `recurrenceTimeZoneName`, `CalendarProvider.occurrence`, `forSplit`,
`RecurrenceOccurrenceResolver.select`, `namesAnotherOccurrence`, `wasMoved`,
`resolveInstance`, `resolveInstanceId`, `CalDAVOccurrences.scopedEditSlot`, `originalStart(ofKey:in:)`,
moved occurrence, current start, named where it is now, split at a moved occurrence, collision,
`toolInstant`, start without seconds, series zone, BYDAY, BYMONTHDAY, BYYEARDAY, BYWEEKNO, BYMONTH,
BYSETPOS, named days, day move, `recurringEventId`, `seriesMasterId`, `originalStartTime`,
`originalStart`, `GCalEvent.originalStartTime`, `ExchangeCalendarProvider.originalStartTime`,
`eventSelect`, first occurrence, later occurrence, time of day, this-and-following, split, phantom
occurrence, `RecurrenceTail.isCapped`, `routeSeriesTimeChange`, Google Calendar behaviour,
`queuedEventId`, `ruleChangeResetNote`, reset note, invariant property, #559, #560, #563, #613, #679,
#680, #687.

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
written (`CalendarProviderError.notSupported("split at a moved occurrence")`, thrown by the Google and
Outlook occurrence lookup with `forSplit`; CalDAV's #613 check refuses it in `scopedEditSlot`). It is
deliberately NOT a finished refusal: no dedicated wording and no work to order it before the card
(coordinator ruling, 2026-11-11). On the `this_and_following` path the lookup runs in `read`, so it
throws there; on the "all" path (a new date named at a moved later occurrence, which `route` makes a
split there) the card is shown and the queued split throws at the drain, nothing written and the row
left failed. `wasMoved(_:seriesZone:)` compares the occurrence's `start` with its `originalStartTime`
(all-day: by date in the series' zone).

**Dates are the series' own, in its zone** (`GCalEvent.seriesZone` = `recurrenceTimeZoneName ??
start.timeZone`, resolved by `CalendarTimeZoneResolver` alone; ONE source for every caller). Outlook
names its zone on the series' range (`recurrenceTimeZone`, mapped to `recurrenceTimeZoneName`); Google
names its IANA zone on `start`; CalDAV its TZID. When the zone is not known (an unrecognized name; a
CalDAV floating time; a CalDAV time written in UTC with no `TZID`, #679), a timed series' new start is
taken to be on another date: the side that splits, asks or refuses, never a wrong write. An all-day
series whose zone is not known is refused when an Outlook all-day place (an instant) has to be dated.

Also refused, with nothing written: an occurrence whose place or start can't be read; a series whose
start can't be read; a deleted (`cancelled`) occurrence; an occurrence id with a `recurrence_id`
naming ANOTHER occurrence (`namesAnotherOccurrence`); a `recurrence_id` at which two occurrences start,
named by the series' id (ambiguous).

## How the occurrence is found: one provider lookup

`CalendarProvider.occurrence(calendarId:eventId:recurrenceId:recurrenceIdZone:forSplit:)` is the
provider's own lookup, the one its one-occurrence edit and split make; its default throws
`notSupported`. So what the write would refuse is refused by `read`, before the card, and nothing above
the provider layer asks which provider it is (ADR-IOS-060).

- Google: `resolveInstance` (returns `(id, instance)`) over `events.instances`, by current start;
  `RecurrenceOccurrenceResolver.select(...naming:)` prefers the occurrence the event id names, so an
  occurrence moved onto another's time, named by its own id and that time, names itself (S3).
- Outlook: `resolveInstanceId(...naming:)`, then `getEvent`, then `wasMoved`. `eventSelect` names
  `originalStart`.
- CalDAV: `CalDAVProvider.occurrence` through `CalDAVOccurrences.scopedEdit` (returns `(key, slot)`)
  and #613's `scopedEditSlot`. That check also refuses a series whose STORED zone TabMail does not
  recognize ("which TabMail does not recognize"), so a CalDAV edit or split of such a series is refused
  before the card through this one path; the check is not copied, and listings and `getEvent` do not
  refuse (#649). `originalStartTime` is filled from the occurrence's key (`originalStart(ofKey:in:)`),
  so a moved CalDAV occurrence carries its place and its current start.

`forSplit` is set when the GIVEN scope is `this_and_following`, so a moved occurrence named with
`this_and_following` (the first one included) throws the plain error in `read`.

`read` runs for every scope (one extra read per edit; a rename included), since only the event says
whether it is an occurrence.

## Where it is applied

- `CalendarEventEditTool.execute`, before the card: `read`, `route`, `dayMoveRefusal`. The card, the
  queued edit and the result all carry the routed scope; an "all" edit is queued with the series' id
  (`queuedEventId`). The card's reset note (`editResetsChangedOccurrences`, #423) is asked of
  `named.series` with the ROUTED arguments (PROOF P2): asked of the occurrence (no rule on Google and
  Outlook) with the edit as given, the card would show no note while the write resets.
- `AccountManagerCalendarQueue`, `.edit`: the same `read` and `route` again, writing `writeId`. An "all"
  edit that `route` sends to a later occurrence is refused (`laterOccurrenceRefusal`): it reaches the
  queue as "all" only when the series changed after the card, and the user confirmed every occurrence.

## Outlook's `originalStart`

Graph's documentation calls it a `DateTimeOffset` in UTC. Measured live (2026-11-10,
`/me/events/{id}/instances`): every instance carries it as ISO 8601 with the event's own offset; a moved
exception shows its original slot there while `start` shows the moved time. An all-day instance's
`originalStart` is a UTC instant at local midnight in the series' zone (Tokyo's December 1 is
`…-11-30T15:00:00Z`). `ExchangeCalendarProvider.originalStartTime` maps every occurrence to the instant
(nil when no ISO 8601 date-time with a zone designator); an all-day place is dated only in
`CalendarSeriesScope`, in the series' zone.

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
between two, a date off its days, a deleted occurrence), so no phantom part is written. A retry after
the split's own cap is not checked again (Google: `RecurrenceTail.isCapped`; Outlook: the stored range
ends on the cap). CalDAV's split is checked by #613.

## The invariant property (tests)

For every (event_id, start_iso) pair the listing shows, an edit is either refused before the card (no
card, nothing queued, nothing written) or, once the queue has drained, the calendar holds what the card
said. Never a refusal after confirmation, except a split at a moved occurrence: an error with nothing
written and no write left queued, wherever it is thrown (#563, #687). `CalendarSeriesScopeTests.swift`
(`GoogleSeriesScopeInvariantTests`, `ExchangeSeriesScopeInvariantTests`) runs it table-driven over
states (unmoved, moved far, moved onto another (Google only), first moved, deleted), naming forms (own
id; own id and start; series id and start), scopes, and changes (rename, time of day, date with named
days, date with a plain rule, date with a new rule). CalDAV is covered by the occurrence matrix and
the unrecognized-zone row. The fakes filter `/instances` by where an occurrence is NOW, leave a
cancelled Google instance out of the list, and Graph refuses a PATCH moving an occurrence onto another
(`ErrorOccurrenceCrossingBoundary`).

## Known limits

1. One extra provider read per edit.
2. CalDAV "all" with no occurrence named and a new date asks the user.
3. A CalDAV series written in UTC with no `TZID` has no known zone (#679).
4. A split at a moved occurrence is not supported: a plain error, nothing written (#563, #687).
5. An Outlook "all" time edit resets the series' changed occurrences; the card warns (#680).

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
- The superseded items of the first build's own review (a later occurrence's new time of day split; the
  place compared in the edit's zone; Outlook's all-day `originalStart` read as a date) stay superseded.

## Known differences from the Thunderbird add-on

1. The add-on refuses a new rule given together with a day move (specific to its writer); here a new
   rule given with the move is what lets a series on named days move to another date.
