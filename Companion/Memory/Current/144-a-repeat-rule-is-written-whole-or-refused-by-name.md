# A repeat rule is written whole, or refused by name before the card

Found 2026-11-10 (#513).

## What happened

`calendar_event_create` and `calendar_event_edit` take a repeat rule as fields (`freq`, `interval`,
`count`, `until`, `byDay`, `byMonthDay`, `byMonth`, `wkst`), but the shared writer
`CalendarToolHelpers.buildGCalEventInput` kept only FREQ, INTERVAL, COUNT and UNTIL, on every
provider. A Monday-and-Wednesday series was saved Monday-only, "the first Monday" became a fixed
date, an edit restating the rule removed the dropped days for every attendee, an invalid field was
dropped silently, and the card did not list the days.

## The rule

- **One reader for every field.** `recurrenceFreq` and `recurrenceDayParts` validate each token
  (RFC 5545: BYDAY `[+-]n` 1 to 53 with a weekday, a position only with MONTHLY or YEARLY;
  BYMONTHDAY ±1 to 31, not with WEEKLY; BYMONTH 1 to 12; WKST a weekday) and throw `notSupported`
  naming the field and the value (`recurrence.byDay has an invalid value "XX": …`, the Thunderbird
  add-on's wording). The builder, the card text (`recurrenceSummary`, which names the days) and the
  pre-card provider check (`recurrenceRuleShape`) all read through them, so whatever the builder
  refuses is refused before the card.
- **A rule a provider can't hold is refused by that provider, by name, before the card.**
  `CalendarProvider.recurrenceRuleRefusal(_:)` (default nil) is the capability question; the tools
  ask it through `CalendarToolHelpers.recurrenceProviderRefusal` with the provider they already
  hold, so no tool switches on a provider type. Outlook answers with
  `ExchangeCalendarProvider.graphRecurrenceRefusal`: Graph's pattern types hold one day of the
  month, one numbered weekday (first to fourth or last), one month, and yearly only with the month
  named. Its writers (`createEvent`, `updateEvent`, `splitSeries`) refuse the same rules
  (`refuseUnrepresentableRule`) for an operation queued without the check. Weekly on several days,
  monthly on a date or on the nth or last weekday, and yearly on a date or nth weekday of a month
  hold on every provider. Refused on Outlook: several days of the month, a day counted from the
  month's end, every Monday of a month, several numbered weekdays, a fifth or second-to-last
  weekday, a weekday with a day of the month, BYMONTH outside YEARLY, several months, daily on
  weekdays (offer WEEKLY), yearly without the month.
- **WKST reaches Outlook** as `firstDayOfWeek`; without it the pattern keeps `sunday` (#423 owns that).
  After the rebase onto #423's fix: on an edit, an explicit WKST wins over the series' stored first
  day; without WKST the stored day is kept. One comparison decides both the PATCH and the card (see
  topic 140).
- **Outlook's relative patterns round-trip.** The reader writes a stored `relativeMonthly`/`relativeYearly`
  as plain BYDAY weekdays plus one BYSETPOS (Graph's `index` counts over the union of `daysOfWeek`,
  "the second Thursday or Friday"), and the refusal accepts exactly that: MONTHLY or YEARLY (with BYMONTH),
  plain weekdays, one BYSETPOS of 1 to 4 or -1. Every other BYSETPOS use is refused naming `recurrence.bySetPos`.
  A missing stored `index` is read as `first` (`ExchangeCalendarProvider.storedIndex`, measured: Graph returns
  `first`) by both the reader and `sameRule`. Pinned by `OutlookRuleRoundTripTests` (every pattern, range and
  first day: read, accepted, encoded back the same). The tool's `recurrence` arguments have no `bySetPos` field,
  and an unknown key is ignored, not refused (open finding).
- **A Google rule write keeps the series' EXDATE and RDATE lines**
  (`GoogleCalendarProvider.recurrence(_:withRuleFrom:)`, applied by `updateEvent` and by a split's
  new part in `mergeMasterAndPatch`), as CalDAV's `mergePatchIntoICS` does. Google replaces the whole
  `recurrence` array, so the patch's rule alone brought back deleted occurrences. The split's cap
  writes its computed array exactly (`patchEvent(keepStoredDates: false)`): the shared
  `mergeExistingEventWithPatch` must not add stored dates, or the cap keeps the dates the new part
  took over (caught by `SeriesSplitCopyTests`).
- An invalid `freq`, or day fields without one, is refused too. An invalid `until` is still dropped
  (`validatedRRuleUntil`); not changed here.
  **Superseded 2026-11-10 (same change, review round 1; the line above is kept as history):** an
  invalid `until` (not a string, malformed, or an impossible date or time) is REFUSED by the shared
  reader `CalendarToolHelpers.recurrenceUntil`, naming the field and the value
  (`recurrence.until has an invalid value "…": …`), before the card on create and edit, every
  provider, nothing written. The builder no longer omits the UNTIL clause, so an unbounded series
  is never written in place of a bounded one. The card reads `until` with the strictest reading
  (`allDay: false`, UTC), so it also refuses an all-day event's out-of-range time, which the
  builder would only drop. `validatedRRuleUntil` still returns nil for an unreadable value; its
  doc keeps the old "omitted, unbounded" choice as history. A `count` still wins over `until`.
- Outlook names `byMonthDay: -1` plainly ("on the last day of the month"); other negative days keep
  "on a day counted from the end of the month".

## The delete card names a series' rule too (#639, 2026-11-10)

`calendar_event_delete`'s card says "Repeating event: every occurrence will be deleted"
(`CalendarToolHelpers.seriesDeleteNote`, Google Calendar's question) and `Repeats: <rule>` when the
event it read is a series itself: a repeat rule and no `recurringEventId` (`seriesDeleteLines`). An
occurrence names its series in `recurringEventId` on every provider (a CalDAV occurrence also
carries the series' rule), so its card gets no such line. **Since the #639 follow-up (2026-11-10)**
an occurrence's card says "One occurrence of a repeating event; the rest of the series stays."
(`occurrenceDeleteNote`), keyed on `recurringEventId` alone: true on every provider (Google and
Outlook delete only it; CalDAV, since #661, deletes only it too with an `EXDATE`, and refuses with nothing deleted where it can't, ADR-IOS-108), including a CalDAV row of a resource holding
only changed occurrences, which carries no rule. Do not key it on the rule being absent. The stored rule is worded by
`storedRecurrenceSummary`, which shares `recurrenceText` with `recurrenceSummary`, so a stored and
a given rule read the same; a stored UTC `UNTIL` is shown as its day in the device's zone. A stored
`BYMONTH` out of range is left out (`recurrenceDaysText` used to index past the month list, which
validated arguments never reached).

**One frequency phrase (2026-11-10, #639 follow-up):** the chat's event popover and both cards
(edit and delete) word a rule's frequency and interval with ONE function,
`CalendarToolHelpers.recurrenceIntervalPhrase` (`weekly`, `every 2 weeks`), moved unchanged out of
the popover's former private `EventPillPopover.describeRecurrence`. The popover calls
`popoverRecurrenceLine` (its output unchanged: `Repeats every 2 weeks`, else `Recurring`); the cards
keep their days, count and end on top (`every 2 weeks on Monday, Wednesday (10 times)`; the delete
card's line reads `Repeats every 2 weeks ...`, the edit card's `recurrence → every 2 weeks ...`).
Hourly and finer, which the popover does not name, keep the card's old token (`every 2 hourly`).
Do not add another rule formatter. A CalDAV resource holding only changed occurrences, deleted by
its own id, gets no card at all: `ICSParser.parse` returns no event for it, so the delete tool's
read fails and it refuses before the card, nothing sent. Pinned by `CalendarSeriesDeleteCardTests`
and `CalDAVOccurrenceDeleteToolToWireTests` (the CalDAV series card before its DELETE; the
occurrence card without the line; the override-only resource by its own id refused with no DELETE;
the popover line pinned by `popoverLineUnchanged`).

**The delete card also serves `calendar_event_edit`'s `exdates_add` (#694, 2026-11-11).** Before
#694 no iOS code read `exdates_add`: the edit wrote an unchanged series (or nothing) and answered
"updated successfully". Now (`CalendarEventEditExdates`) it is a call of its own: any argument outside
an allow-list (`event_id`, `calendar_id`, `exdates_add`, `timezone`, and `edit_scope`
only as "all"; `send_invitations` was allowed until #778 retired it, guests always being notified) is refused by name, failing closed for keys outside the schema too, and the refusal tells
the assistant to send the other change FIRST as its own call, then read the event again and send
`exdates_add` alone, naming the occurrences by their starts as they are then. **The order matters:** on
Google and Outlook a change to the series (its times, its rule, a split) brings back occurrences deleted
before it (`editResetsChangedOccurrences`, measured 2026-11-10); CalDAV moves its `EXDATE`s with
`DTSTART`. Every date is looked up before the card against the SERIES (also when
`event_id` names an occurrence) in the call's `timezone`, through `CalendarProvider.occurrence` only (a
date alone on a timed series names the one occurrence that day; none there, already deleted, ambiguous
or malformed refuses the whole call, nothing queued); the card is the delete card, one row per
occurrence with `occurrenceDeleteNote`; the same occurrences are queued as ordinary `.delete` ops in ONE
write (`AccountManager.queueCalendarOperations`, all or none; the executor is unchanged, so guests are
notified as every delete notifies them and CalDAV goes through #661's `EXDATE` write); the answer names
each date beside the start of the occurrence it named (so a date that resolved to another occurrence
shows), deleted, queued or NOT deleted with its reason, never "updated". A CalDAV resource holding
only changed occurrences is refused by the lookup before the card, in the exdates path's own words
(`CalendarEventEditExdates.seriesNotHere`: only changed occurrences are on the server, nothing deleted,
change it in the calendar app), never #729's edit advice to use `edit_scope` this_only. It matches the
neutral `CalendarProviderError.seriesNotInThisCalendar`, never a CalDAV constant (the provider boundary);
a one-off event, and an occurrence
id equal to the series' own, are refused locally. Two dates naming one occurrence delete it once (one
card row, one delete, both dates named). On an Outlook all-day series a date names that date's
occurrence whatever zone the call names, through #647's date lookup (before it, a call zone west of the
series' could name, and now delete, the next day's occurrence; pinned with #647's `GraphAllDaySeries`).
Pinned by `CalendarEditExdatesTests` (Google, Outlook, CalDAV
fakes; the refused keys are pinned against a copy of the published schema's properties).

## The read tools show a rule in the same fields (#552, 2026-11-12)

Before #552 `calendar_event_read` printed `RRULE: <every recurrence line joined by ;>` and
`calendar_search`/`calendar_read` marked a row `(↻ RRULE:…)`, so the assistant had to translate RFC
5545 into the write fields, and a stored UTC `UNTIL` became a date by guesswork. Now one formatter,
`CalendarRecurrenceFormat` (the Thunderbird add-on's format, TB #261/#281), shows the rule in the
fields the tools write:

- `calendar_event_read`: `recurring: yes`, then `recurrence: {"freq":"WEEKLY","byDay":["MO","WE"],"until":"…"}`
  (compact JSON, the tools' field order, `interval` 1 and `wkst` MO left out), then every non-rule line
  (EXDATE, RDATE) verbatim. The search rows: `(↻ {…})`; a series whose occurrences are not listed
  `(↻ {…}; <occurrencesNotListedNote>)`. `ChatIdTranslator`'s pill-title regex strips either form (no
  `)` inside the JSON).
- **`other`**: every part the fields cannot say, as stored, joined by `;`: a FREQ below DAILY, BYHOUR
  and the like, an invalid token, a part given twice, a day field the writer refuses with that FREQ
  (decided by calling the writer's own `recurrenceDayParts`, so reader and writer cannot drift), an
  UNTIL beside a COUNT or in a rule of several times a day, a further RRULE (`RRULE:…`). The read line
  then adds `otherPartsNote` ("the edit tool cannot express these; omit recurrence to keep the rule").
  The writer REFUSES a non-null `other` (`recurrenceFreq`, `recurrence.other has an invalid value …`),
  and `calendar_event_edit` refuses any valid rule for a series whose stored rule has `other` parts,
  for `edit_scope` all and `this_and_following`, before the card, nothing queued
  (`storedOtherRefusal`, the shared table's wording). An edit with no rule keeps the stored one.
- **BYSETPOS fold (2026-11-12):** `BYDAY=<one plain weekday>;BYSETPOS=<one n>` with
  FREQ MONTHLY, or YEARLY with exactly one BYMONTH, and no other day-selecting part, is shown as
  `"byDay":["<n><day>"]` (`foldedSetPosition`): RFC 5545 makes them the same days, so Outlook's
  "second Tuesday" (read as `BYDAY=TU;BYSETPOS=2`) restates without a reset (`sameRule`). Every other
  BYSETPOS (several weekdays, several positions, YEARLY without one month) stays in `other`. The TB
  add-on keeps every BYSETPOS in `other` because Thunderbird 140 to 158 expand the two forms
  differently; iOS never runs that expander. Removing the call in `fields` reverts to the add-on.
- **`until` is the last occurrence's day** (`untilDay`): all-day, the bound's date; timed, the last day
  E whose slot (the start's time of day in the series' zone, from `originalStartTime ?? start`) is
  at or before the bound, a UTC instant, a bare date (Outlook's range end) or a floating wall time in
  the series' zone; a split's cap (one second before a slot) reads as the day before. Shown as the
  date of E's slot in the zone the output prints in when it round-trips: the bound the edit tool
  writes for that date in that zone (`validatedRRuleUntil`, end of day) must keep E and not E+1.
  **Superseded 2026-11-13:** where it does not (near a clock change: a last occurrence just after
  midnight on the day before the clocks change), the UNTIL no longer stays in `other` (which refused
  every restatement); `until` is E's slot itself as a UTC date-time (`2099-03-07T05:30:00Z`), which
  `validatedRRuleUntil` writes unchanged, so the rule restates exactly in any edit zone. `other` keeps
  the UNTIL only when the bound can't be read or placed, or the series' zone is unknown. iOS-only
  (the add-on has no such form yet).
  **Series' zone on CalDAV (2026-11-13):** a start in UTC (`Z`) or floating names no zone, so
  `seriesZone` is nil there (and stays nil: #679's refuse side is unchanged). The zone the rule repeats
  in is carried in memory as `GCalEvent.ruleZone` (UTC; the floating read zone; a TZID through the
  resolver alone, nil when unknown), set by `ICSParser` (series read) and both `CalDAVOccurrences`
  row builders (`Frame.ruleZone`); `untilDay` reads `ruleZone ?? seriesZone`. No write path reads it;
  not encoded.
  **Decided 2026-11-13: the user's day** (the zone the output prints in);
  Thunderbird is moved to match in its own unit, not in #552. `zone` in `untilDay` is the single
  switch point. Known limit: the read by `event_id` prints in the device zone (#794), so an edit
  given a different `timezone` reads the shown date there.

Pinned by `CalendarRecurrenceFormatTests` (field mapping, write-back equality, the fold's
occurrences against the CalDAV expander for every weekday and position, the `until` round-trip
property over five series zones, seven read zones, three times of day, eight bound shapes and days
around clock changes, checked through `CalDAVOccurrences.listing` and, for a bare date,
`graphEndDate`; CalDAV series in UTC and floating, listed rows and the series read) and `RecurrenceDaysToolTests` (Outlook second Tuesday read, restated and drained with
no reset; second Tuesday-or-Thursday refused before the card; the scope matrix; `other` refused as a
field).

## Pinned by

`TabMailTests/Tools/CalendarRecurrenceDaysTests.swift`: the writer and the card per field and
combination; each invalid token refused by both, naming field and value; create and edit through the
queue on the Google, Graph and CalDAV fakes write the whole rule (Google and CalDAV keep EXDATE and
RDATE); Graph's refusals and everyday mappings; the create and edit tools refuse before the card with
nothing sent and name the days on the card.
