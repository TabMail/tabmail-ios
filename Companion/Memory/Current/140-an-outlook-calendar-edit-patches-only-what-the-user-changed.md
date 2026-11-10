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
  date is the device's (`day`), the zone `request` asks Graph to read starts in, of the instant Graph
  stores: `toGraphEventJSON` writes the wall time with any offset or `Z` dropped, not converted
  (`graphNaiveDateTime`), labelled with the start's zone. So `day` reads that wall time in that
  label, never the offset: the tools pass an offset-spelled start through as given, and `…T00:30Z`
  labelled with the device's zone is 00:30 on the device, not the evening before (found in review:
  reading the offset as the instant wrote a recurrence, resetting exceptions, for a same-day time
  change, and missed or misdated a real date move). A start whose offset matches its label (`Z` with
  `UTC`) is the instant it spells. A wall time without seconds (`…T10:00`, bare or with an offset) is
  read the same way: `graphNaiveDateTime` writes it with `:00` (the form Graph's example and
  responses use) and `day` reads that same string, so the writer and the date check share one form (found
  in review: dating it as written misdated a seconds-less start labelled with another zone). A string in
  none of these forms (no wall time, or a one-digit hour) is dated as written. The tools still pass unknown start
  spellings through unparsed; reading them once at the tool boundary is #543.
  `day` reads the device's zone while the stored range keeps its `recurrenceTimeZone`; where the two
  disagree on the date, the range start can be a day off (#463).
- A rule the edit gives is written as before (rebuilt from the RRULE by `toGraphEventJSON`). It still
  drops the series' `recurrenceTimeZone` and `firstDayOfWeek` (#423, open), and the calendar tool's
  own recurrence format is #513.
- An occurrence edit never writes `recurrence` (an instance cannot carry a rule; Graph refuses it).
- `fetchForEdit` keeps the Graph JSON of the read beside the `GCalEvent` (`EditSnapshot`): existing
  attendees keep their Graph type (matched by lowercased address); a new one is `required`.
- Every read (`listEvents`, `getEvent`, `fetchForEdit`: one `eventSelect`) selects `body` and
  `onlineMeeting`. The description is the stored body's notes as text at full length
  (`ExchangeCalendarProvider.notes(of:)`, `EmailFilter.htmlToPlainText` keeping spacing), never
  `bodyPreview` (cut at 255 characters, join section rendered as text); an online meeting's notes stop
  at its join section, and its join link is `GCalEvent.conferenceUrl`, shown to the assistant as its own
  `conference_url:` line (the Thunderbird add-on's field name; the add-on does not fill it on read).
  `isEmptySurfaceEvent` still reads `bodyPreview`. An event pill's popover notes put the join link
  first (`CalendarToolHelpers.eventPillNotes`, at every pill-cache writer built from an event), since
  the description no longer holds it and the popover is where the user copies a meeting link from.
- A description edit writes the user's text as the body. For an online meeting it replaces only the
  notes in the stored HTML body and keeps the join
  section as stored (`onlineMeetingBody`, `GraphOnlineMeetingBody`, #511): Graph's event-update warns
  that removing the "meeting blob" from the body turns the online meeting off. The join section is
  recognised by the join link (`onlineMeeting.joinUrl`, as written or with `&amp;`) and the last line of
  underscores before it; the section starts at the outermost element opening directly before that line.
  The anchor is the FIRST copy of the link that has such a line before it, so a copy of the link in the
  notes (the assistant is shown it and can be asked to put it there) is passed over, and a line of
  underscores in the notes above the real section is not taken for its separator. The one shape it
  cannot tell apart (a line of underscores in the notes above a copy of the link) places the section too
  early, which keeps the join section whole; it never places it inside the section. New notes drop
  trailing line breaks, since a `<br>` just before the section would be read as part of it.
  Checked live on a Teams meeting on a work account (#555): a text body write turned the meeting off
  (`isOnlineMeeting` false, `onlineMeetingProvider` `unknown`, `onlineMeeting` null); an HTML write that
  changed only the notes kept it. That layout: notes, then `<div>` + three `<br>` holding
  `<div class="me-email-text">`, which starts and ends with an `aria-hidden` div of 80 underscores, with a
  short "Join:" link and the long `meetup-join` "System reference" link (which one `joinUrl` is was not
  recorded; both are recognised). Graph's online-meeting samples show an older layout, also recognised.
  A join section that is not recognised gets the description as text, as every description edit of an
  online meeting did before #511, which turns the meeting off; the read then gives the whole body,
  join section included, as the description.
  A split's new series is still built from the narrowed read (#512, open).

`GCalEvent` is a lossy view for the agent and the merge helpers. Never write a narrowed read back to
the provider.

## Pinned by

`TabMailTests/Providers/ExchangeCalendarEditPreservationTests.swift`: `FakeGraphCalendar` applies
Graph's documented PATCH semantics (unsent properties keep their values; `location` replaces
`locations`; `$select` returns only what it names) and the measured #423 recurrence behaviour (a range
written without a zone is stored as UTC; a written rule that differs from the stored one counts as a
series reset; a `recurrence` written without `start` moves the series to UTC midnight; a range with no
`startDate` is refused). Seven edit kinds (rename, move an hour, move only the end, change the room,
add an attendee, remove an attendee, mark busy) on a single event, a whole series and one occurrence
assert that every property they did not edit comes back unchanged on the server (the enum also has a
description edit and a rule edit, run on a plain event and a series); a whole-series edit that
gives no rule sends no `recurrence` and resets nothing; a series moved to another date (timed and
all day, or by a start written without an offset) keeps its stored recurrence but for the range's
start date; a series given a new rule and a new date gets the new rule; the date compared is the
device's, not UTC's; a series moved by a start spelled `Z`, `.000Z`, `+00:00`, `HH:mm` or `HH:mmZ` but labelled with a
zone 14 hours ahead (`seriesMovedByOffsetSpelledStart`, built by `buildGCalEventInput`) is dated
where Graph stores it; an all-day edit that gives only the end keeps the start. `GraphFixture` stores its UTC
start at the hour that puts the device on the same date, so the suite holds at any host offset from
-12 to +14 hours.
