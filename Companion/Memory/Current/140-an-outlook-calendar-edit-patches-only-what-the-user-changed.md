# An Outlook calendar edit PATCHes only what the user changed

Found 2026-11-07 (#421, from a provider API audit; the same line also caused #423, confirmed live the same day).

## What happened

`ExchangeCalendarProvider.updateEvent` and `updateOccurrence` read the event, merged the edit onto it
with `GoogleCalendarProvider.mergeExistingEventWithPatch`, and PATCHed every property back. A comment
called this a defensive full payload. But the read is a narrowed `GCalEvent`:

- `description` is the plain-text `bodyPreview`, never `body`;
- `transparency` collapses `showAs` (tentative, oof and workingElsewhere all become busy);
- `location` is one display name, and Graph replaces `locations` when `location` is written;
- `GCalAttendee` has no type, so every attendee was written back as `required`;
- `recurrence` is rebuilt from an RRULE, which drops `recurrenceTimeZone` and forces
  `firstDayOfWeek: sunday` (#423).

Measured on a test Outlook.com account on 2026-11-07 (#423): on a weekly series with one occurrence
deleted and one moved, a subject-only PATCH and a PATCH writing back the stored recurrence exactly
changed nothing, but a PATCH with the app's rebuilt recurrence (firstDayOfWeek sunday, no
recurrenceTimeZone) brought the deleted occurrence back, moved the moved one back, and changed the
series' recurrenceTimeZone and originalStartTimeZone to UTC. So any recurrence write that differs from
the stored one resets a series' exceptions.

So every edit, even a rename, replaced the body with its preview (losing HTML, links, everything past
the preview and an online meeting's join block), narrowed the rest, and reset a series' exceptions.
Tests missed it because nothing drove these methods over HTTP and
`ExchangeCalendarTests.fullyPopulated` treats `description == bodyPreview` as correct.

## The rule

Follow Graph's event-update: "supply only the values for properties to update. Existing properties
that aren't included in the request body maintain their previous values".

- `graphPatchJSON` writes only the properties the edit sets, plus what a changed property needs with
  it: start and end together when either moves (the side the user did not give still comes from
  `mergeExistingEventWithPatch`'s duration derivation); start and end beside a written `recurrence`
  (Graph rewrites a master's start and end to UTC midnight at the range's `startDate` when
  `recurrence` is PATCHed alone). An edit that changes nothing sends no PATCH.
- A whole-series edit that gives no rule writes no `recurrence`, unless its start moves to another
  date: then the stored recurrence is written exactly as Graph holds it (from `fetchForEdit`'s raw
  read), with only the range's `startDate` moved to the new date, because the two must match. The
  date is the device's (`day`), the zone `request` asks Graph to read starts in; a start written
  without an offset (the tools pass `…T10:00` through as given) is taken at its own date, as written.
  `day` reads the device's zone while the stored range keeps its `recurrenceTimeZone`; where the two
  disagree on the date, the range start can be a day off (#463).
- A rule the edit gives is written as before (rebuilt from the RRULE by `toGraphEventJSON`). It still
  drops the series' `recurrenceTimeZone` and `firstDayOfWeek` (#423, open), and the calendar tool's
  own recurrence format is #513.
- An occurrence edit never writes `recurrence` (an instance cannot carry a rule; Graph refuses it).
- `fetchForEdit` keeps the Graph JSON of the read beside the `GCalEvent` (`EditSnapshot`): existing
  attendees keep their Graph type (matched by lowercased address); a new one is `required`.
- A description edit writes the user's text as the body. For an online meeting that still replaces
  the join block (#511, open). A split's new series is still built from the narrowed read (#512, open).

`GCalEvent` is a lossy view for the agent and the merge helpers. Never write a narrowed read back to
the provider.

## Pinned by

`TabMailTests/Providers/ExchangeCalendarEditPreservationTests.swift`: `FakeGraphCalendar` applies
Graph's documented PATCH semantics (unsent properties keep their values; `location` replaces
`locations`; `$select` returns only what it names) and the measured #423 recurrence behaviour (a range
written without a zone is stored as UTC; a written rule that differs from the stored one counts as a
series reset; a `recurrence` written without `start` moves the series to UTC midnight; a range with no
`startDate` is refused). Six edit kinds (rename, move an hour, move only the end, change the room,
add an attendee, mark busy) on a single event, a whole series and one occurrence assert that every
property they did not edit comes back unchanged on the server; a whole-series edit that
gives no rule sends no `recurrence` and resets nothing; a series moved to another date (timed and
all day, or by a start written without an offset) keeps its stored recurrence but for the range's
start date; a series given a new rule and a new date gets the new rule; the date compared is the
device's, not UTC's. `GraphFixture` stores its UTC
start at the hour that puts the device on the same date, so the suite holds at any host offset from
-12 to +14 hours.
