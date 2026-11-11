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
carries the series' rule), so its card gets no such line. The stored rule is worded by
`storedRecurrenceSummary`, which shares `recurrenceText` with `recurrenceSummary`, so a stored and
a given rule read the same; a stored UTC `UNTIL` is shown as its day in the device's zone. A stored
`BYMONTH` out of range is left out (`recurrenceDaysText` used to index past the month list, which
validated arguments never reached). The chat popover's `MarkdownChatText.describeRecurrence` is a
separate, shorter wording (frequency and interval only). Pinned by `CalendarSeriesDeleteCardTests`
and `CalDAVOccurrenceDeleteToolToWireTests` (the CalDAV series card before its DELETE; the
occurrence card without the line).

## Pinned by

`TabMailTests/Tools/CalendarRecurrenceDaysTests.swift`: the writer and the card per field and
combination; each invalid token refused by both, naming field and value; create and edit through the
queue on the Google, Graph and CalDAV fakes write the whole rule (Google and CalDAV keep EXDATE and
RDATE); Graph's refusals and everyday mappings; the create and edit tools refuse before the card with
nothing sent and name the days on the card.
