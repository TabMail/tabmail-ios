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

Measured again on 2026-11-10 (#423), on a work-tenant account (consumer Outlook.com unmeasured, assumed
the same): a whole-series PATCH of `start` and `end` ONLY, with no `recurrence`, also reset everything.
The deleted occurrence came back and the moved one became a plain occurrence at the series' new time;
the stored recurrence was unchanged. So on Outlook ANY whole-series start or end change resets the
series' changed occurrences, not only a rule change. Writing back an identical start and end was not
measured.

Google does the same (measured 2026-11-10 on a personal Google account): a master PATCH moving a
weekly `COUNT=5` series from 08:00 to 13:00 reset everything. The deleted occurrence came back, and a
moved one (09:00, its slot 08:00) became a plain occurrence at 13:00; the series' `recurrence` was the
same before and after. The request body was not saved: that it was a time-only PATCH rests on the
checker's report, and the before and after instance data is the evidence. Measured again on Google the
same day, with the request bodies saved: a series PATCH that re-sends the series' unchanged start, end
and recurrence with a new summary does NOT reset changed occurrences (the deleted occurrence stays
deleted, the moved one keeps its time and `originalStartTime`), and neither does a summary-only PATCH.
So Google resets only when the times actually change; its write, which sends the merged start and end
on every edit, needs no change. Google: a change of only the zone label on the same instant is treated
as a move (warn side); Google's reset for it is unmeasured.

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
- A whole-series edit sends `start` and `end` only when `movesSeriesTime` says they move (or beside a
  written rule), the same decision the card takes (#423, found in review: the write sent any start or
  end the edit gave, so the series' own times sent back were PATCHed while the card, comparing
  instants, said nothing moved; and the same instant under another label was a write the card missed).
  Same instants means no time change (2026-11-10): a timed start and end are compared as the instants
  they name, so the same instant under any zone name sends no start or end. So a rename that re-sends
  the series' own wall times with an IANA label for its stored Windows zone sends no start or end
  (`zoneLabelsCompareByResolvedZone`, with the same wall time in another zone and an unresolvable
  label as moves, each sent, warned of and reset); a series at 00:00 UTC made all-day on the same date,
  and the reverse, is sent and warned of (`allDayChangeIsAMove`); a series Graph keeps in a zone with
  daylight saving (Eastern), read on a device in one without (Tokyo), and the reverse, renamed with
  the read times echoed in the device's zone, sends no start, end or recurrence, is not warned of,
  resets nothing and keeps its stored zone (`readTimesEchoedAreNoMove`); and the card's stand-in for
  the stored rule (`storedRuleBaseline`, the RRULE rebuilt in Graph's form) is `sameRule` with the raw
  stored recurrence for every stored rule kind (`cardBaselineIsTheStoredRule`). Not supported: an
  explicit re-zone of a series to another zone at the same instant (iOS #667); it is no move, so it is
  not written.
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
  **Superseded by #543 (2026-11-10):** the tool boundary now reads every start and end one way
  (`CalendarToolHelpers.toolInstant`, used by `toRFC3339` and the create tool): a wall time without an offset
  (with or without seconds) is the wall time in the edit's zone, and a time with a UTC offset or `Z` is the
  instant it spells, as Google Calendar reads it. Either is handed on spelled with the label's own offset, so
  `graphNaiveDateTime`'s dropped offset always matches the label, the start-only end derivation and the weekly
  BYDAY fill read the same instant, and the seconds-less padding in `graphNaiveDateTime` was deleted as
  unreachable. An all-day value is a plain calendar date taken as spelled (its first ten characters,
  `toolAllDayDate`), never the day its instant falls on in the label's zone. The paragraph above records the
  earlier reading.
  `day` reads the device's zone while the stored range keeps its `recurrenceTimeZone`; where the two
  disagree on the date, the range start can be a day off (#463).
- A rule the edit gives is written as before (rebuilt from the RRULE by `toGraphEventJSON`). It still
  drops the series' `recurrenceTimeZone` and `firstDayOfWeek` (#423, open), and the calendar tool's
  own recurrence format is #513.
  Fixed for #423 (2026-11-10): a whole-series edit's rule is first compared, as `toGraphEventJSON`
  would write it (beside the start it is written with), against the stored recurrence from
  `fetchForEdit`'s raw read (`ExchangeCalendarProvider.sameRule`). Graph fills unused pattern and range
  properties with defaults, so only the properties the rebuilt rule names are compared (days of the
  week as a set), leaving out `firstDayOfWeek` (an RRULE does not carry it) and the range's
  `startDate` (it follows the start). An equal rule counts as no rule: nothing is written for it, and
  the date-move step above runs as for an edit with no rule (the assistant re-sends the rule it read,
  which before this reset the series' exceptions on every edit). A rule that differs is written
  rebuilt with the stored `pattern.firstDayOfWeek` and `range.recurrenceTimeZone` copied in; with no
  stored zone (absent or empty), the range is labelled with the zone the edit writes the start in
  (`start.timeZone` of the same PATCH; `UTC` for an all-day start, as `toGraphEventJSON` writes it).
  The changed rule is also dated in the stored zone: the stored `recurrenceTimeZone` is read through
  `CalendarTimeZoneResolver.zone(named:in: .none)` (IANA, Windows CLDR names) and passed to
  [Superseded for the first day, #513 rebase: an RRULE now carries `WKST`. The stored
  `firstDayOfWeek` is an encoder input (`toGraphEventJSON(_:rangeZone:firstDayOfWeek:)` →
  `parseRRULEToGraphRecurrence`), written unless the rule names its own `WKST`, and `sameRule`
  compares it like every other property: a rule without `WKST` matches the stored day by
  construction, a changed `WKST` is a rule change, written and warned of on the card. The card's
  baseline reads the stored day from `GCalEvent.recurrenceFirstDayOfWeek`. Whether Graph resets
  exceptions on a first-day-only change is unmeasured; assumed yes (warn side), and the test fake
  counts it.]
  `toGraphEventJSON(_:rangeZone:)`, which converts the start's wall time into that zone
  (`ExchangeCalendarProvider.wallTime(_:from:to:)`) before `parseRRULEToGraphRecurrence` /
  `graphEndDate` date an `UNTIL`; the range's `startDate` is that converted wall time's date, since Graph
  reads it in the stored zone and requires it to match the start (found in review: it was the start's
  date as written, a day off for a Tokyo series whose start Graph gives at 20:00 UTC). With no stored
  zone the start's zone is used, as before. The weekday, day and month `parseRRULEToGraphRecurrence`
  fills in for a rule that names none are the start's in that same range zone (its `timeZone`), not the
  device's (#655: `cal.timeZone = .current` gave a series in another zone that starts near midnight the
  device's weekday, for good; `toGraphEventJSON` now passes the start as its wall time in the range
  zone, an all-day start as its date there). A stored name the resolver does not know refuses the edit by name, before the equality
  check and before any PATCH, through the resolver's write refusal
  (`CalendarProviderError.unrecognizedTimeZone(name, consequence: "it did not change the event")`), so an
  equal re-sent rule is refused too: deciding equality in a guessed zone could drop a real change.
  A changed rule still resets the series' exceptions: that is Graph's behaviour whenever the pattern
  changes (measured above), and reapplying them was not built. So does a moved start or end (measured
  2026-11-10 above). The confirmation card says so instead: every whole-series (`scope` "all") edit of
  an event that has a rule asks the series' calendar, and gets the line
  `CalendarToolHelpers.ruleChangeResetNote` ("Occurrences you changed individually may be reset.") when
  it says the edit resets changed occurrences: `CalendarProvider.editResetsChangedOccurrences(_:edit:)`
  (named `ruleChanged` and asked only for an edit that gave a rule until the 2026-11-10 measurement),
  given the same
  `GCalEventInput` the write is given (`buildGCalEventInput`), pure (no request; it reads only the event
  the tool already read), so the tool stays provider-neutral. Outlook answers true when the merged write
  moves the series' start or end (`ExchangeCalendarProvider.movesSeriesTime`: a series' time moves when
  the instant of its start or end changes, or its all-day date, or anything else the encoder writes
  beside them. The start and end the write would send, `toGraphEventJSON` of the merge, against the
  ones it would send for the series' own (the read), each timed start and end read as its instant: its
  wall time in the zone `CalendarTimeZoneResolver` resolves its label to (`graphTimes`); all-day dates
  stay dates. So a new instant or date is a move, a label or wall time that does not resolve or parse
  is one, and the same instant under any zone name is not: the series' own wall times sent back under
  another name for the same zone (the tools' IANA name for Graph's Windows name), and the read times
  echoed in the device's zone. Reads ask for the device's zone (`Prefer: outlook.timezone`), and an
  instant does not depend on the zone it is read in, so no stored zone is needed. Found in review:
  comparing labels byte for byte made a rename that re-sent the series' own times with an IANA label
  a PATCH of start and end, and a reset. The whole of what `toGraphEventJSON` writes for the times is
  compared, only each timed start and end replaced by its instant, so `isAllDay` and anything the
  encoder later writes beside the times is compared by construction (found in a consult: a key list
  of start and end let a series at 00:00 UTC made all-day on the same date compare equal, and the
  write dropped the change). Replaced (2026-11-10, coverage review): a version that re-expressed the
  series' side in the zone Graph keeps it in (`storedTimes`, from `originalStartTimeZone` and
  `originalEndTimeZone` selected with every read) and compared wall time plus resolved zone; it made
  an edit echoing the read times in the device's zone a move, sent and reset, for any series kept in
  another zone. Deleted with its select fields and the `GCalEvent.originalStartTimeZoneName`,
  `originalEndTimeZoneName` fields; the explicit same-instant re-zone it wrote is iOS #667),
  false for an edit with no rule that
  keeps them (a rename), and otherwise with the write's own rule decision, `ExchangeCalendarProvider.seriesRuleToWrite`, the one function `graphPatchJSON` calls for
  the rule: it merges the edit with the series as the write does (`mergeExistingEventWithPatch`: the
  edit's start, zone and rule), builds the rule beside that start and compares it with the stored one
  (`sameRule`). The card's stored rule is the event's RRULE in Graph's form, in the series' zone:
  `GCalEvent.recurrenceTimeZoneName`, filled from the `recurrenceTimeZone` Graph returns with the event
  (`MSRecurrenceRange`), in memory only; an unknown zone answers "changed" (the write refuses it). A
  stored pattern its RRULE does not say exactly also answers "changed": its RRULE, read back into
  Graph's form and out again (`ExchangeCalendarProvider.rrule(_:)`, `toGCalEvent`'s mapping), is not
  the same (a weekly pattern with no days, a relative one with no index); the write, comparing with the
  stored pattern, writes the rule for those too. Left: an undocumented Graph pattern or range type that
  maps to an RRULE which does round-trip (`rrule(_:)` falls back to a bare weekly, and to no end).
  Found in review: the first `ruleChanged(_:to:)` compared beside the stored start, so an edit that
  also moved the start (a rule naming no day, an UNTIL earlier in its day than the new start time)
  could get a card answer the write did not take. Google writes the `recurrence` array it is given in
  place of the stored one, so it answers "changed" unless the two hold the same lines
  (`GoogleCalendarProvider.recurrenceLinesDiffer`, RRULEs read by `canonicalRRULE`), and, since the
  Google measurement above, true when the edit moves the series' start or end
  (`GoogleCalendarProvider.movesSeriesTime` with `googleTimes`, the date or instant and the zone Google
  reads, so its own times spelled otherwise are no move and the same instant in another zone is one;
  Outlook shared this function until a consult gave it its own comparison, now by instant, above). Google's write sends the merged start and end every time, unchanged; CalDAV replaces
  only the RRULE line, so it answers by that line alone; the demo calendar stores no rule. Replaced in
  review: a card-side normaliser (`CalendarToolHelpers.ruleChanges` over a `RuleMeaning` of the two
  RRULEs) that could disagree with the write, deleted. Creates and the split's new
  part are unchanged (they send no `recurrenceTimeZone`, or the stored one as copied). Pinned in
  `ExchangeCalendarEditPreservationTests` (`ruleChangeKeepsZoneAndFirstDay`,
  `resentRuleResetsNothing`, `resentRuleInAnotherDayOrder`, `resentRuleWithDateMove`,
  `ruleChangeEndsInTheStoredZone` (its end and its range's start date in Tokyo), `endOnlyChangeIsWritten`
  (a new COUNT, an UNTIL added to an open series, COUNT changed to UNTIL: each a rule change),
  `cardAnswerIsTheWrites` (every stored rule kind, re-sent or with a new end, interval or kind: the
  card's answer is whether the write wrote a rule), `cardAnswerIsTheWritesWithStartMove` (a bare weekly
  moved to another weekday, a bare monthly to another day, an UNTIL whose end day shifts with the start
  time), `unmappedPatternAnswersChanged`, `bareWeeklyIsTheSeriesWeekday` (#655, a Tokyo
  series), `ruleEditInUnrecognizedZoneIsRefused`, `ruleChangeWithNoStoredZone`),
  `ExchangeCalendarTests.weeklyNoByDayInEventZone` (#655 on a create), `CalendarProviderRuleChangedTests`
  (Google and CalDAV by the rule; `timeMoveWithNoRule`: CalDAV answers no reset for a time move;
  `googleTimeEdit`: Google's answer is whether `FakeGoogleCalendar`, which now drops a series' stored
  occurrences on a PATCH that changes its rule, start or end, reset the series, for a later start, a
  rename, its own times spelled otherwise, the same instant in another zone, a later end alone, and an
  all-day series given a new date or its own) and
  `CalendarToolResolvedAccountTests` (`resettingEditCardWarns`: a rule change and a time-only move,
  `quietEditCardHasNoWarning`: a re-sent rule and a rename, `noLineEditCardHasNoWarning`: an event with no
  rule, part of a series). `cardAnswerIsTheWrites` also covers a time-only move, a time move with
  the rule re-sent, the series' own start and end sent back and the same instant under another zone
  label (neither a PATCH of start, end or recurrence nor a reset), each of the last two with and
  without a rename, and the series' own start with a later end (a reset):
  Outlook's answer is whether the fake counted a reset, and whether the PATCH carries start and end
  (one decision for the card and the body). CalDAV still answers by the rule alone;
  whether a CalDAV server resets changed occurrences on a time move was not measured.
- An occurrence edit never writes `recurrence` (an instance cannot carry a rule; Graph refuses it).
- `fetchForEdit` keeps the Graph JSON of the read beside the `GCalEvent` (`EditSnapshot`). An edit
  that changes who attends (whole event or one occurrence) writes each attendee it keeps exactly as
  the read holds them: type, answer (`status`) and name, matched by lowercased address
  (`editAttendeesJSON`). A new one is `required` and unanswered:
  `status {"response": "none", "time": "0001-01-01T00:00:00Z"}`.
- Measured on an Outlook.com account (2026-11-10, #622):
  - Graph refuses with **405 `UnknownError`, empty message**, an attendee PATCH in which any entry
    has no `status`. The earlier `{emailAddress, type}` shape failed on every guest change there.
  - With every entry carrying its status, the PATCH returns 200, and a kept attendee keeps their
    answer and its time. Graph stores the new attendee's time as `1601-01-01`.
  - A POST (create, split) accepts attendees without `status`, so `splitNewPartJSON` still writes
    `toGraphEventJSON`'s shape with `attendeeTypes`.
  - Whether Exchange Online (work accounts) refuses the no-status shape too is unmeasured. The
    status-carrying shape is the documented form either way.
- Every read (`listEvents`, `getEvent`, `fetchForEdit`: one `eventSelect`) selects `body` and
  `onlineMeeting`. The description is the stored body's notes as text at full length
  (`ExchangeCalendarProvider.notes(of:)`, `EmailFilter.htmlToPlainText` keeping spacing), never
  `bodyPreview` (cut at 255 characters, join section rendered as text); an online meeting's notes stop
  at its join section, and its join link is `GCalEvent.conferenceUrl`, shown to the assistant as its own
  `conference_url:` line (the Thunderbird add-on's field name; the add-on does not fill it on read).
  `isEmptySurfaceEvent` still reads `bodyPreview`. An event pill's popover notes put the join link
  first (`CalendarToolHelpers.eventPillNotes`, at every pill-cache writer built from an event), since
  the description no longer holds it and the popover is where the user copies a meeting link from.
- A description edit writes the user's notes as an HTML body (`GraphNotesHTML`, #577), the reverse of
  the read: each line break a `<br>`, each `[label](destination)` link the read gives
  (`EmailFilter.markdownPieces`, the grammar `unwrapMarkdownLinks` parses) an `<a>` when its scheme is
  web, mail or phone (`GraphNotesHTML.linkSchemes`; any other stays as its text, so a `javascript:`
  destination never becomes a link), the href escaped as an attribute, and a space that starts a line,
  follows a space or ends a line a `&nbsp;` (Outlook's editor may drop a `white-space` style; a
  no-break space survives every client). A read of what it writes gives the same notes again, up to
  white space at the ends of lines and of the notes. Text and the href
  are escaped one Unicode scalar at a time, so a quote or `<` joined to a combining mark is escaped too.
  Before #577 the notes were written as escaped text, so after one edit every link was literal
  `[label](url)` text and runs of spaces collapsed. For an online meeting it replaces only the
  notes in the stored HTML body and keeps the join
  section as stored (`onlineMeetingBody`, `GraphOnlineMeetingBody`, #511): Graph's event-update warns
  that removing the "meeting blob" from the body turns the online meeting off. The join section is
  recognised by the join link (`onlineMeeting.joinUrl`, as written or with `&amp;`) and the last line of
  underscores before it; the section starts at the outermost element opening directly before that line.
  The anchor is the FIRST copy of the link that has such a line before it, so a copy of the link in the
  notes (the assistant is shown it and can be asked to put it there) is passed over, and a line of
  underscores in the notes above the real section is not taken for its separator. The one shape it
  cannot tell apart (a line of underscores in the notes above a copy of the link) places the section too
  early, which keeps the join section whole; it never places it inside the section. The body is the
  organizer's, so the search stays linear in it: a link has such a line before it exactly when it starts
  after the first line of underscores is complete, so one search from there finds the anchor (a search
  that restarted from the notes for each copy was quadratic in the copies). New notes drop
  trailing line breaks, since a `<br>` just before the section would be read as part of it.
  Checked live on a Teams meeting on a work account (#555): a text body write turned the meeting off
  (`isOnlineMeeting` false, `onlineMeetingProvider` `unknown`, `onlineMeeting` null); an HTML write that
  changed only the notes kept it. That layout: notes, then `<div>` + three `<br>` holding
  `<div class="me-email-text">`, which starts and ends with an `aria-hidden` div of 80 underscores, with a
  short "Join:" link and the long `meetup-join` "System reference" link (which one `joinUrl` is was not
  recorded; both are recognised). Graph's online-meeting samples show an older layout, also recognised.
  A join section that is not recognised gets the description as the whole body, as every description edit of an
  online meeting did before #511, which turns the meeting off; the read then gives the whole body,
  join section included, as the description.
  A split's new series is copied from the stored series, not the narrowed read (#512; [memory 142](142-a-copy-of-a-repeating-series-keeps-the-series-properties.md)).

`GCalEvent` is a lossy view for the agent and the merge helpers. Never write a narrowed read back to
the provider.

## Pinned by

`TabMailTests/Providers/ExchangeCalendarEditPreservationTests.swift`: `FakeGraphCalendar` applies
Graph's documented PATCH semantics (unsent properties keep their values; `location` replaces
`locations`; `$select` returns only what it names) and the measured #423 recurrence behaviour (a range
written without a zone is stored as UTC; a written rule that differs from the stored one, or a series
start or end that differs from the stored one, counts as a series reset; a `recurrence` written without `start` moves the series to UTC midnight; a range with no
`startDate` is refused). Seven edit kinds (rename, move an hour, move only the end, change the room,
add an attendee, remove an attendee, mark busy) on a single event, a whole series and one occurrence
assert that every property they did not edit comes back unchanged on the server (the enum also has a
description edit and a rule edit, run on a plain event and a series); a whole-series edit that
gives no rule sends no `recurrence` and resets nothing unless it moves the series' start or end (the
fake counts a reset for a whole-series start or end that differs from the stored one, as measured
2026-11-10); a series moved to another date (timed and
all day, or by a start written without an offset) keeps its stored recurrence but for the range's
start date; a series given a new rule and a new date gets the new rule; the date compared is the
device's, not UTC's; a series moved by a start spelled `Z`, `.000Z`, `+00:00`, `HH:mm` or `HH:mmZ` but labelled with a
zone 14 hours ahead (`seriesMovedByOffsetSpelledStart`, built by `buildGCalEventInput`) is dated
where Graph stores it; an all-day edit that gives only the end keeps the start. `GraphFixture` stores its UTC
start at the hour that puts the device on the same date, so the suite holds at any host offset from
-12 to +14 hours.

`TabMailTests/Providers/GraphOnlineMeetingBodyTests.swift` pins the join-section split (#511): a notes
edit keeps the stored join section byte for byte, a notes-only body is written as HTML, and a body with
thousands of link copies is split in linear time (`manyLinkCopies`). `ExchangeCalendarEditPreservationTests`
pins the edit end to end on the fake Graph calendar. `ToolCachingTests` pins the pill's join link at every
cache site: the read tool's cached-calendar path, its scan of every calendar
(`scannedReadCachesTheJoinLink`), and the live re-fetch (`liveFetchShowsTheJoinLink`);
`CalendarToolHelpersTests` pins `eventPillNotes(from:)`. The notes writer (#577):
`GraphOnlineMeetingBodyTests` pins links by scheme, the read's escapes reversed, other schemes kept as
text, a label or destination that can't add markup, and kept spacing; `ExchangeCalendarEditPreservationTests`
reads back what it wrote (`notesReadBackAsWritten`, online and plain) and checks that a read link is
written back as a link (`onlineDescriptionRoundTrip`, `plainDescriptionRoundTrip`); `EmailFilterTests`
pins `markdownPieces`.

Correction to memory 064 (frozen fragment, not edited): an event pill's notes no longer come from
`GCalEvent.description` alone. Every cache site and the live re-fetch use
`CalendarToolHelpers.eventPillNotes(from:)`, which puts `Join: <conferenceUrl>` on the first line,
because an Outlook online meeting's description is its notes without the join section.

Series end date (#551): Graph's `recurrence.range.endDate` is an inclusive date read in the event's
zone (a create sends no `recurrenceTimeZone`; since #423 an edit's changed rule carries the stored one, see above). `ExchangeCalendarProvider.graphEndDate(until:in:startWallTime:)`
dates a UTC-instant `UNTIL` in the event's zone, then applies the time-of-day rule: an `UNTIL` earlier
in the day than the series' start ends the series the day before, as Google Calendar does. A date-only
end arrives as 23:59:59 local, so it always stays the day the user named. A bare date or a floating
value keeps its own date digits; there is no branch for the floating form, since no producer emits it
for Outlook.
