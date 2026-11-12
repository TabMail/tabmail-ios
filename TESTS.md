# TabMail iOS — Test Reference

This file documents cross-cutting test architecture that spans multiple files/layers. It is not a full test inventory — see individual test files for detailed coverage of a given component.

---

## Interrupted action recovery

`GlobalFifoExecutorTests.interruptedMovesConvergeAfterRestart` captures a real
SQLite snapshot at the provider boundary after the FIFO claim and reopens it
through `AppDatabase.init`. It checks ordered effects across the restart with
zero or two earlier moves completed, plus preserved operation identity, position,
retry count and attempt history. It models process death through a snapshot;
it does not terminate the hosted test process.

`interruptedGraphMoveConverges`, `interruptedGmailMoveConverges`, and
`interruptedIMAPMoveRetainsAuthority` exercise
real providers against stateful servers before and after remote completion,
including changed/unknown IMAP epochs and untouched bystanders.
`interruptedGroupedGmailMoveConverges` snapshots a real claim for one or three
messages and reopens it through both testing and production startup modes, with
existing-release flags, both normally and after a refused recovery UPDATE clears.
It checks preserved intent/history, every target, the bystander and durable queue
settlement through the database returned as usable.
`AccountManagerQueueDrainTests` retains startup-only coverage of cancelled-row
cleanup and unrelated queued work.

## Outlook calendar edits — server-side oracle

`ExchangeCalendarEditPreservationTests` drives `ExchangeCalendarProvider.updateEvent` and
`updateOccurrence` over `FakeHTTP` against `FakeGraphCalendar`, which applies Graph's documented
event-update semantics (unsent properties keep their values; writing `location` replaces
`locations`; `$select` returns only what it names). For seven edit kinds (rename, move an hour, move
only the end, change the room, add an attendee, remove an attendee, mark busy) on a single event, a whole series and one
occurrence, and a description edit of a plain event and a rule edit of a series, it asserts on the
stored event, not on our payload: every property the edit did not set (body, `showAs`, `locations`, attendees, recurrence, start and end) comes back
unchanged, and the edited property holds what was asked (a removed attendee is gone, each kept attendee's whole stored entry, type, answer and its time,
is unchanged, and an added one is `required` and unanswered). The fake refuses with 405, as measured
on Outlook.com for #622, an attendee PATCH in which any entry has no `status`
(`fakeRefusesAttendeeWithoutStatus`). It refuses with 400 `ErrorPropertyValidationFailure`, as
measured on a work account for #719, a series PATCH whose timed start is labelled with a zone that
resolves to another zone than the series' stored `recurrenceTimeZone` (`seriesStartZoneRefusal`; an
end alone, one occurrence, an all-day `UTC` date and an unrecognized stored zone are not checked).
`ExchangeSeriesZoneLabelTests` drives series edits through the queue against it: a time change of
every occurrence from a Vancouver device and named in New York, a split from the device's zone, and a
split whose new part fails (the revert is accepted) are written at the card's instant under the
series' stored zone name; a rename and the same instant under another name send no start; an
unrecognized stored zone keeps the write's earlier label (#746). The fake also stores an all-day
series write whose start or end is labelled with a zone other than the range's two days longer, as
measured for #747 (`allDaySeriesLengthened`); `ExchangeAllDaySeriesLengthTests` holds a whole-series
move, a length edit and a split of an all-day series kept in Pacific, Tokyo or an IANA zone to the
series' length and zone. `ExchangeSeriesDayTests` holds a series kept in Tokyo, moved or split
across midnight in only one of the series' and the device's zones, to a range `startDate` on the
written start's day in the series' zone.
`ExchangeSeriesZoneHelperTests` pins `inSeriesZone` (the British Columbia change, DST edges, the date
line, fractional offsets, a stored IANA name, an unknown zone, an all-day relabel, and the instant property).
The fake also models the recurrence
behaviour measured live for #423 (a range written without a zone is stored as UTC; a written rule
that differs from the stored one resets the series' exceptions; a `recurrence` PATCHed without
`start` moves the series to UTC midnight; a range without `startDate` is refused with a 400) and the
2026-11-10 measurement on a work-tenant account (a whole-series start or end that differs from the
stored one resets the series' exceptions, with no `recurrence` written): a
whole-series edit that gives no rule writes no `recurrence`, and resets nothing unless it moves the
series' start or end (`wholeSeriesKeepsRule` expects the reset for its time moves); a series moved to
another date, timed and all day (its end moving with it), keeps its stored recurrence but for the
range's start date; a whole-series edit that re-sends the series' own rule (weekly with no end,
relative monthly to a date, absolute yearly and every other day for a count; alone or with a
rename) resets nothing and leaves the series as it was (`resentRuleResetsNothing`, and with its days in
another order `resentRuleInAnotherDayOrder`), and with a date
move keeps the stored recurrence but for the range's start date (`resentRuleWithDateMove`); a rule
change keeps the series' stored `recurrenceTimeZone` and `firstDayOfWeek`
(`ruleChangeKeepsZoneAndFirstDay`), a changed rule's end and its range's start date are dated in the
stored Windows zone when it differs from the start's (`ruleChangeEndsInTheStoredZone`), a change of
only the series' end (a new COUNT, an UNTIL added to an open series, COUNT changed to UNTIL) is
written as a rule change (`endOnlyChangeIsWritten`), a rule edit of a series whose stored zone
TabMail does not recognize is refused by that name with nothing written
(`ruleEditInUnrecognizedZoneIsRefused`, where the card's `editResetsChangedOccurrences` answers true), a series
with no stored zone (absent or empty) gets the zone its start is written in
(`ruleChangeWithNoStoredZone`), a weekly rule with no day for a Tokyo series is the start's weekday
in Tokyo and the stored rule (`bareWeeklyIsTheSeriesWeekday`; on a create,
`ExchangeCalendarTests.weeklyNoByDayInEventZone`), and for every stored rule kind, re-sent or with a
new end, interval or kind, or a time-only move (alone or with the rule re-sent), or the series' own
start and end sent back or the same instant under another zone label (each with and without a
rename; same instants means no time change, so neither sends start, end or recurrence nor resets),
or the series' own start with a later end, and a series
stored with a Windows zone name renamed with its own wall times under the IANA name is no move (no
start, end or recurrence sent, no warning) while the same wall time in another zone or an
unresolvable label is one, sent, warned of and reset (`zoneLabelsCompareByResolvedZone`), a series at
00:00 UTC made all-day on the same date or the reverse is sent and warned of
(`allDayChangeIsAMove`; the fake resets a series on an `isAllDay` change), a series kept in a zone
with daylight saving (Eastern) read on a device in one without (Tokyo), and the reverse, renamed with
the read times echoed in the device's zone sends no start, end or recurrence, is not warned of,
resets nothing and keeps its stored zone (`readTimesEchoedAreNoMove`; the explicit same-instant
re-zone is not supported, iOS #667), the card's rebuilt stored rule is `sameRule` with
the raw stored recurrence for every stored rule kind (`cardBaselineIsTheStoredRule`),
`editResetsChangedOccurrences` answers whether the fake counted a reset and whether the PATCH carries
start and end (`cardAnswerIsTheWrites`), also when the edit moves the start (a bare weekly to another weekday, a
bare monthly to another day, an UNTIL whose end day shifts with the start time;
`cardAnswerIsTheWritesWithStartMove`, where the rule is also written), and a stored pattern its RRULE
does not say exactly answers true (`unmappedPatternAnswersChanged`); Google's and CalDAV's
`editResetsChangedOccurrences` (`CalendarProviderRuleChangedTests`: Google resets unless the lines are
the same, however spelled; CalDAV by its RRULE line alone, and not for a time move with no rule,
`timeMoveWithNoRule`; Google for a moved start or end too, its answer matching whether
`FakeGoogleCalendar`, which drops a series' stored occurrences on a PATCH that changes its rule, start
or end as measured on Google 2026-11-10, reset the series: a later start, a later end alone, the same
instant in another zone and an all-day series' new date reset, a rename, its own times spelled
otherwise and an all-day series' own date do not, `googleTimeEdit`); the edit tool's confirmation card says occurrences changed individually may be
reset when the series' calendar says the whole-series edit resets them, whatever the rule, and for a
time-only move (`CalendarToolResolvedAccountTests`: `resettingEditCardWarns`), and not when it says the
edit resets nothing, a re-sent rule or a rename (`quietEditCardHasNoWarning`), or, without asking it,
for an event with no rule or part of a series (`noLineEditCardHasNoWarning`); an
occurrence edit never writes a rule or the master. Also covered: an event made recurring, a series
given a new rule and a new date (the new rule is written), a series moved by a start written
without an offset, a series moved by a start spelled with an offset (`Z`, `.000Z`, `+00:00`) or
without seconds (`…T10:00`, bare or with `Z`) but labelled with another zone, as the tools pass one
through (dated where Graph stores it: within the device's day no recurrence, to another day the
range at that day; a start without seconds is written with `:00`), an all-day end-only edit (the
start stays), a move across UTC midnight within the device's day (no recurrence) and across
the device's midnight within one UTC date (range start = the device's date; both skipped within
about an hour of UTC), an occurrence named by its own id, an empty edit writing nothing, a PATCH
retried after a 401 with a refreshed sign-in, and an attendee stored in mixed case keeping its
type. The fixtures hold at any host offset from -12 to +14 hours.

Online meetings (#511): the online fixture's body follows the layout a Teams meeting on a work
account stored when checked live (notes, then a join section between two lines of underscores with a
short "Join:" link and the long `meetup-join` one; every link, id, number and passcode a
placeholder), and the fake models what that check measured: a body written without the join link
turns the online meeting off (`isOnlineMeeting` false, `onlineMeetingProvider` `unknown`,
`onlineMeeting` null). A description edit is one of the edit kinds on the online single event,
series and occurrence: the notes are replaced, the join section and everything after it are kept byte
for byte, and the meeting stays on. Also: a read gives the stored notes as the description at full
length (past the 255-character preview), an online meeting's without its join section and with its
join link as `conferenceUrl`, by `getEvent` and by a `calendarView` listing (the fake lists single
events and occurrences, never a series master); a description read, added to and written back keeps
the notes and the meeting; after the join link is written into the notes, the next description edit
still keeps the meeting; clearing the notes keeps the join section; and a layout without a separator
line gets the description as text, as before.
`GraphOnlineMeetingBodyTests` pins the recogniser over the live layout (found by either join link) and
the older layout of Graph's online-meeting samples: bare-text and element notes, escaping and line
breaks, a `<body>` tag with attributes or none, a join link
written raw, a separator nested in several elements, the cases it does not recognise (no link, the
separator only after it, a line shorter than `separatorMinUnderscores`, an unclosed `<body` tag, an
empty link) and where the notes end; a copy of the join link in the notes (as written and with
`&amp;`) and a line of underscores in the notes are part of the notes; with both, the join section is
still kept whole; trailing line breaks in new notes are dropped, so repeated edits do not grow the
body; and thousands of copies of the join link in the notes, with or without a join section after
them, are recognised as the clean body is, within a time limit a scan that restarts for each copy
exceeds. `ExchangeCalendarTests` maps an HTML, text or missing body to the
description; `CalendarToolHelpersTests` pins the `conference_url:` line after the description and an
event pill's notes (join link first); `ToolCachingTests` checks that the search and direct-read pill
caches carry the join link (including a read that finds the event by scanning every calendar), and
that in a new session a pill tap that fetches the event live shows it.
Notes written back as HTML (#577): `GraphOnlineMeetingBodyTests` writes a web, mail or phone link in
new notes as a link (with the read's escapes reversed), keeps a link to any other kind of destination
as its text (escaped, so markup in its label or destination stays text), writes a link whose
destination holds more colons (a port, a path, a query) as a link, escapes a label or destination so it can't add markup or leave the link (also a quote or
`<` joined to a combining, joining, spacing or Prepend mark), and keeps runs of spaces and spaces that
start or end a line; `ExchangeCalendarEditPreservationTests` reads back notes with links (web, mail,
phone, and one carrying every escape a read writes in a label or destination) and runs of spaces
exactly as written, for an online meeting and a plain event, and checks
that a description read and written back keeps its link as a link; `EmailFilterTests` pins
`markdownPieces` (unescaped label and destination, and the pieces joining back to the text).

## Repeating events — copies keep the series' properties

A this-and-following edit splits a series into the capped series and a new part, and a CalDAV
one-occurrence edit writes an override. Both copies must carry what the stored series has.
These tests read what each provider sent, or what the fake server ends up holding.

- `CalDAVEventCopiesTests` covers both CalDAV copies, `seriesSplitResources` and
  `occurrenceOverrideResource`, built from one rich series. The series has class, categories,
  priority, URL, alarms, attendee parameters, organizer and X-properties; excluded and added dates
  are checked on other fixtures. Every property line the edit does not change must come through as
  stored, the attendees' types (`CUTYPE`) included; a one-occurrence override also keeps the
  series' `SEQUENCE`, which a split's new part starts without.
  - When the edit moves the meeting (a new start and end, end alone, an earlier start with the
    same end, place, or a split's new rule), attendees are asked again, keeping their role and type.
  - An occurrence changed on its own (`CalDAVOccurrenceOverrideTests`,
    `changedOccurrenceKeepsItsOwnProperties`, #604): cancelled, with its own alert, categories,
    link, revision, `X-` line and attendee answers and parameters, none of them the series'. A
    rename, an attendee added and a move each keep all of them; an added attendee is asked, and a
    move asks Alice and the room again while keeping their role and type. Dates are relative to
    today.
  - An all-day series with no end lasts its one day (`ICSParser.impliedEndValue`, RFC 5545
    §3.6.1): restating the date keeps the answers, moving it asks again (both copies), and the
    series can be split. A timed series with no end still can't be split, and a one-occurrence edit
    of a zoned one keeps no length and every answer, in zones at both ends of the offsets.
  - A one-occurrence edit that gives a repeat rule writes no rule and keeps every answer, for a
    new override and for one changed before; a series with a start and no end can be changed.
  - Excluded and added dates stay with the part they fall in; a changed occurrence and an added
    date exactly at the split go to the new part only.
  - A split that moves the new part's start moves its excluded and added dates, its UNTIL and its
    changed occurrences' RECURRENCE-IDs with it (a changed occurrence's own time stays); the capped
    series keeps its own.
  - A whole-series edit keeps attendees and alarms.
  - A series with an alert and no notes, renamed or moved, gives a copy of one occurrence or a
    split's new part with no notes and the alert as stored (`alertOnlySeriesCopyHasNoNotes`, #603).
- `CalDAVAlarmIsNotTheEventTests` (#603): an alarm's properties are never the event's.
  - Reading: `ICSParser.parse`, `getEvent` and `listEvents` (no range, and a range that expands the
    series into occurrences) give the event's own title, notes, attendees and length, with a
    DISPLAY, EMAIL, repeating or UID-carrying alarm placed after or before the event's properties;
    `extractUID` gives the event's UID when an alarm with its own comes first.
  - Writing, through the real calendar queue on `all`, `this_only` and `this_and_following`: adding
    an attendee never writes the alarm's recipient as one, adding to the notes builds on the
    event's own notes, and a rename leaves every alarm byte for byte.
  - Pins of how a VEVENT is read, kept green across the move of `ICSParser` onto the writer's
    helpers: trailing whitespace, CRLF and bare-LF folding, the series read when a changed
    occurrence comes first, a lower-case nested component, a `BEGIN:VEVENT`/`END:VEVENT` line with
    trailing whitespace (read by `ICSParserTests`; read and written by `CalDAVMergePatchTests`,
    through the merge, `replaceRRule`, a moved start's `shiftSeriesAnchoredValues`, a new or
    repeated one-occurrence change's `spliceOrReplaceOverride` (also with a padded `END:VCALENDAR`)
    and a split's `seriesSplitResources`; a folded continuation reading ` END:VEVENT` is not a
    component line), a lower-case EMAIL alarm after the event's properties (`ICSParserTests`),
    the master readers (`extractUID` … `masterStartWallTime`) across frames and layouts
    (`CalDAVRecurringHelpersTests`), and `ICSParserOutputPinTests`, a field-by-field pin of
    `ICSParser.parse` for alarm-free resources.
- `CalDAVSplitRefusedBeforeWriteTests` (`CalDAVSplitHelpersTests`, against `FakeCalDAVStore`): a
  series whose excluded dates can't be read is refused with no PUT and the resource unchanged.
- `CalDAVSplitRollbackTests` (same file): the new part is written before the cap. A failed new
  part, or a foreign resource at its URL, leaves the series untouched; a concurrent edit between
  the two writes survives and the retry caps it; excluded dates, added dates and changed
  occurrences each end up in exactly one part, also when the cap's response is lost and the split
  is retried.
- `SeriesSplitCopyTests`, Google: the new part is the stored event JSON without the keys the
  server owns. The test checks:
  - the conference and attachment query flags;
  - the capped and new rules, with excluded and added dates split at the slot, timed and all day;
  - the attendee rule: entries are kept, a reschedule (new start, earlier start with the same end,
    new end alone, new rule alone, new place) asks everyone but the organizer again, the organizer
    is known by the attendee flag or by the address alone, an added attendee is asked, and a dropped
    one is removed; `splitReschedules` is also checked trigger by trigger, including timed to all day;
  - an excluded or an added date exactly at the split going to the new part only;
  - a new rule on the new part keeping the excluded and added dates after the split (the rule
    line alone is replaced);
  - `privateCopy` kept on the new part;
  - a refusal before any write when a date can't be read.
- `SeriesSplitCopyTests`, Outlook, against `FakeGraphCalendar`: every property in a literal list
  (`GraphSplitFixture.keptKeys`) is copied, and the create as sent carries no key outside that list
  and what the split writes. The test also checks:
  - attendee names and types;
  - a new place replacing the stored places;
  - the stored pattern written verbatim on both parts;
  - the range rules for noEnd, endDate and numbered series (a numbered one stays numbered with
    what is left; the stored 0 count of a noEnd or endDate range is not sent back), and a range already ending on this split's cap (a retry after the cap landed)
    written with no end;
  - the cap of each of those three series as sent: an end date at the split and no count, with the
    stored range's `recurrenceTimeZone` and the stored pattern's `firstDayOfWeek`;
  - the transaction id;
  - a rule in the edit becoming the new part's rule while the capped series keeps its own;
  - new notes on an online series keeping its join section as stored;
  - a split whose new start can't be dated refused before the series is capped;
  - the stored recurrence restored exactly when the create fails.

## Google attendee edits — the others stay as stored

Google stores the attendee list an edit sends as it is sent, so an attendee sent by address alone
loses their optional flag, answer, comment and additional guests. `GoogleAttendeeEditTests` reads
the PATCH body the fake calendar received:

- adding an attendee sends every other attendee exactly as stored (organizer, optional, resource,
  additional guests) and the new one by address and name;
- removing one drops only that attendee;
- an address in another letter case still matches its stored entry, on either side; a guest
  removed and added back in one change keeps their stored entry, at the end of the list;
- adding the first attendee to an event with none sends just that attendee;
- an edit that names no attendee change sends no attendee list;
- an occurrence edit keeps that occurrence's own stored attendees.

## A guest change reaches every item it covers, each from its own guests (#620)

An edit carries the guest change itself (`AttendeeChange`), and each write applies it to the stored
guests of the item it writes; a whole-series change reaches each changed occurrence as the series'
resulting difference (`AttendeeChange.seriesDifference`: the guests the series lost removed, the
guests it gained added, on the occurrence's own guests). That is Google's rule and Outlook's,
measured on both (2026-11-11) for an added and a removed guest, a series emptied of its guests (an
occurrence kept the extra guest it held on its own) and a series list written back unchanged (an
occurrence that had dropped a guest stayed without them); Google is the reference, so CalDAV gives
its changed occurrences the same difference. `CalendarGuestChangeTests` checks, on each fake server
after the real calendar queue drains the edit, that the item written holds the change applied to
its OWN guests, every changed occurrence of a whole-series edit the series' difference on its own
(kept guests byte-identical, new ones unanswered, removed ones gone; `GuestChangeOracle`), and
every item outside the scope is untouched: CalDAV (every VEVENT: series, changed occurrences, a
split's new part and the occurrences it carries, a one-occurrence edit by the series id), Google
and Outlook (the item the write reads, the server carrying the series' change; `FakeGoogleCalendar`
and `FakeGraphCalendar` model the measured difference), plus pins that held before the fix. Case 3
runs, on all three providers (and case 19 on a CalDAV split), the five shapes where the difference
is not the change itself: `"*"`, `"*"` with a guest added back, an add of a guest the series holds
that an occurrence dropped, a remove and re-add of such a guest, and a removal of a guest only a
changed occurrence holds (the series does not, so the occurrence keeps them); each also checks weeks 4 and 5
against addresses worked out by hand. The Google and Outlook whole-series cases check that the app
writes no occurrence. `AttendeeChangeTests` covers the function itself (order, `"*"` and
`mailto:*`, letter case, `mailto:` prefixes, a guest with no address, re-adding, an add or removal
given twice, a changed occurrence's own guests, the series' difference);
`CalDAVWholeSeriesEditTests` a cancelled occurrence changed like any other, a VEVENT the change
leaves byte for byte (attendee lines between other properties too), and a new attendee's double
quote written as a single quote; `GoogleSeriesSplitCopyTests` the first guest a split adds to a
series with none; `DemoGuestChangeTests` the demo calendar (an event left with no guests stores no
list); `CalendarToolResolvedAccountTests` the edit card, which names the people added ("Name
<address>") and removed, each once, three and "and N more", and shows no list.

## Inbox list — layered test architecture

the unified inbox read (ADR-IOS-055) replaced four disagreeing inbox-list read paths with one unified reader (`InboxListReader` → `InboxListComposer.compose`). Getting this right — and *keeping* it right as the code evolves — needs coverage at four distinct layers, each catching a different class of bug. A 5-round adversarial audit of the refactor found two HIGH-severity findings (F1, F2) that lived entirely *between* layers, invisible to any single layer's test suite — that's why the fourth layer (E2E) exists.

### Layer 1 — Pure composer harness (logic, thousands of cases)

**File:** `TabMailTests/ViewModels/InboxComposeScenarioTests.swift`

Drives `InboxListComposer.compose` — a pure function, no I/O, no GRDB, no clocks — over a value-type `SimWorld` state machine standing in for the whole pipeline (NSE staging → merge phases → sync → user actions → overlay drain). Each `SimWorld.Step` mirrors exactly one real-world event at FINE granularity (`stagePush`, `phase1Commit`, `ftsFlushCommit`, `phase2Commit`, `drainStaging`, `userMove`, `undo`, `uidRemap`, `reStage`, …).

Invariants I1–I7 (no-resurrection, no-vanish, AI-monotonic, undo-visible, no-duplicates, move-hides, window-sanity) are asserted after **every single step** of every named scenario, plus commutable-pair permutations and a seeded `SplitMix64` fuzz over hundreds of random legal step sequences per run. Because there's no I/O, this is cheap enough to run thousands of compositions per second — this layer is where lifecycle-interleaving bugs (the ones that would otherwise need a flaky on-device repro) get caught for pennies.

### Layer 2 — Reader integration (GRDB seams)

**File:** `TabMailTests/ViewModels/InboxListReaderIntegrationTests.swift`

Thin by design — only what the pure layer can't see: `DurableIdentityLookup` behavior against a real temp GRDB pool (exact-folder match, rfc822 fallback, UID-remap re-key), the P-step's by-id overlay fetch, and a contract-parity test asserting the shell's identity lookup matches the merge's own lookup helper over a shared fixture set (§4.4 risk 1 — divergence here reintroduces I1/I5-class bugs). One end-to-end smoke per fetch site (`fetchFullRange`/`fetchPage`/`resetMessages`) proves they all actually route through the reader.

### Layer 3 — Pinning suite (VM contracts)

**File:** `TabMailTests/ViewModels/InboxListBehaviorPinningTests.swift`

Exercises `InboxViewModel`'s public surface only (`insertStagedRows`/`reloadMessages`/`resetMessages`/`insertUndoneMessages`/`loadMoreMessages`/`lookupMessage` + `loadedMessages`/`displayGroups`) against a real temp `AppDatabase` swapped in for `AppDatabase.shared`. Originally written test-first (to pin current behavior) as the safety net for the composer refactor; now pins the reader's structural guarantees (staged-row survival, AI carry-over, undo-survives-reload, filter/pagination/triage-order parity) directly through the VM, independent of the pure layer's value-world model.

### Layer 4 — E2E invariant layer (orchestration + cross-layer ordering)

**File:** `TabMailTests/E2E/InboxEndToEndInvariantTests.swift`

The SAME scenario histories as Layer 1, driven through the REAL pipeline instead of a value world: a real temp `AppDatabase` + a real NSE staging SQLite file merged via `NSEDataBridge.mergeNSEStagingData(stagingPathOverride:)` + real `AccountManager` overlay mutations + real `NotificationCenter` posts + a real `InboxViewModel`. Assertions run against `vm.loadedMessages`/`displayGroups` (what the user's screen actually shows), not `compose`'s return value.

**Why this layer exists — F1 and F2.** Both were HIGH findings from the 5-round audit, and both slipped past Layers 1–3 with everything green:

- **F1 (signal-orchestration gap):** a "scrub-only" merge wake (re-staging an already-archived message finds nothing durable to write, only a staging scrub) has no `endOfMergeChanged` signal — before the fix, this left a phantom row the pre-detection `.messagesStaged` post had already inserted with no eviction trigger. Layer-local tests can't catch this because it's not about what `compose` returns or what the VM's *methods* do in isolation — it's about whether a *signal actually fires* to wake a real consumer after a mutation. **Invariant I8 (signal-liveness)** generalizes this: any step that changes what SHOULD be visible must be followed by an actual `.inboxDataDidChange`/`.messagesStaged` post — captured via a real `NotificationCenter` observer. The `scrubOnlyWakeStillConverges` scenario runs in WIRED mode (`vm.start()`, no manual reload) specifically so a regression shows up as "the screen never converges," not just "a flag was false."
- **F2 (cross-layer ordering gap):** `compose`'s `targetCount` trim and the VM's `loadedIds` pagination dedup were each tested individually, but their *composition* — trim running before dedup vs. after — was not. In triage mode (non-date-monotonic sort), an already-loaded row re-entering a later page's D query could eat a trim slot meant for a not-yet-loaded row, silently shrinking a page and flipping `hasMoreMessages` false with reachable mail still unread. **Invariant I9 (pagination-completeness)** generalizes this: driving `loadMoreMessages` to true exhaustion must surface every reachable id exactly once, with `hasMoreMessages` going false only at genuine exhaustion — dedicated scenarios (`paginationCompletenessNormal`, `paginationCompletenessTriage`) seed 2+ pages across multiple folders and drive to exhaustion rather than checking a single page transition.

**Invariant I10 (screen-truth convergence)**, checked at every settle point, is the general backstop for both classes: `Set(vm.loadedMessages.map(\.id))` must equal a fresh direct `InboxListReader.fetchSync` call built with the VM's own query shape. Running the SAME named scenarios at the pure (Layer 1) and E2E (Layer 4) layers turns any `SimWorld`-vs-reality fidelity drift into a loud, immediate disagreement instead of a silent blind spot.

**Granularity note:** the E2E step vocabulary is coarser than the pure layer's — staging a terminal (header+body+AI) row and running one `mergeNSEStagingData` call performs phase-1, the FTS flush, phase-2, and the staging drain all within one real "wake" (the merge awaits its own FTS flush). This is deliberate: Layer 1 proves invariants hold at every micro-step; Layer 4 proves they hold across real wake boundaries, which is the actual unit of observability a production reload/render cycle has. Scenarios that need to observe an in-between state (e.g. `aiNeverFlashesAcrossWakes`) drive two explicit gradual-staging wakes instead of relying on sub-wake granularity that doesn't exist at this layer.

**Retro-fit discipline:** a harness that can't re-catch a known bug isn't done. Both F1 and F2 were deliberately re-introduced (scrub-branch post disabled; `excludeIds` moved to post-trim) against this layer and confirmed to fail `scrubOnlyWakeStillConverges`/I8 and `paginationCompletenessTriage`/I9 respectively before the fixes were restored.

## Gmail moves and the labels Gmail maintains

Gmail keeps the `SENT` and `DRAFT` labels itself and refuses any
`messages.modify` that adds or removes them with 400 "Invalid label".
`TabMailTests/Infrastructure/StatefulGmailActionServer.swift` refuses them the
same way, refuses a new label on a draft's message, and serves
`/messages/{id}/trash` and `/untrash`.
`TabMailTests/Services/GmailMaintainedLabelMoveTests.swift` asserts, over every
source and destination pair, that the move reaches Gmail's end state (the kept
label stays, Trash is entered and left with trash/untrash, a draft's message
takes no new label) and that no request ever names a maintained label. It also
asserts that delete from Sent or Drafts and its Undo land on the server through
trash/untrash; that every real member of a delete from Sent and of its Undo
lands when the first member is an invalid or missing id;
the agent's draft delete lands; a move the server refuses stays queued rather
than counted as done; a delete from Sent, and its Undo, that Gmail refuses with a
503 or an unclassified 400 on trash/untrash stays queued with the server
unchanged and lands once the failure clears; a user move into Sent or Drafts is refused on Gmail and
queued on IMAP. `MoveFolderPickerTests.gmailOmitsTheLabelsGmailKeeps` covers the
picker. That an "Invalid label" refusal stays queued rather than being
recorded as done is pinned end to end by
`GmailMaintainedLabelMoveTests` ("A move Gmail refuses with Invalid label stays
queued rather than being recorded as done").

## Local placeholder rows never reach the provider

A `sent-…` row (the optimistic Sent copy of a sent message, written before sync
lists the server's copy) or a `draft-…` row (a draft the server has not saved
yet) has no address on a server.
`TabMailTests/Services/PlaceholderActionAdmissionTests.swift` runs these producers
of a message action (the agent's delete, a user move, mark unread, flag, applying
and removing a label from the label menu, removing a label from the row, and the
reply and forward flags set when a reply or forward finishes sending) on Gmail,
Outlook and IMAP. Mark read and undo move go through the same admission check but have no case here.
On a placeholder alone, each action queues nothing and changes nothing locally,
and the agent's delete reports the row pending; the same action on a real row
queues an op for it. For the actions that take several rows, a placeholder and a
real message together reach the provider with only the real id, and the
placeholder row stays as it was.

An open message shows what was stored. When a read toggle from the message view
(the focused message, or a message in its thread) is refused for a placeholder,
the view returns to the stored row; on a real row it keeps the toggled state.

The same file covers what happens once a draft save lands. On Gmail, Outlook and
IMAP the row takes the server's id, its search entry moves to that id, and an
agent delete reaches that id. A Gmail
save that returns no contained message id leaves the placeholder, which an agent
delete reports pending. An Outlook re-save onto a server row the Drafts sync had
already listed drops the placeholder row, its cached body and its search entry,
and an agent delete reaches the server id. When the re-keyed row cannot be
written, the draft records no server copy (the save and the re-key are one
write), and the retry lands both.

On the demo account the mailbox is the local database and nothing ever replaces
a placeholder, so `DemoProvider` is the one provider that can act on one
(`EmailProvider.placeholderIdsAreAddressable`). With the real `DemoProvider`, the
Sent copy of a demo send can be marked unread, flagged and deleted, and a saved
demo draft's row can be deleted.

## Server-draft dismissal UI

`TabMailScreenshots/ServerDraftCloseUITests.swift` runs in the existing
`TabMailScreenshots` UI-test scheme. Its six cases cover unavailable and failed
resolution in full-screen, pushed, and collapsed detail-column presentations.
The Debug fixture seeds disposable account, folder, and header rows and mounts the
production `MailNavigationView`. Cover cases tap the real Drafts row; push and detail
cases emit the existing email-pill and notification input events. No substitute
navigation stack or cover owns the loader. Each opens and closes twice, checks the
real mailbox is usable, and checks that the fixture rows remain intact. Failure
cases also verify that Try Again invokes the injected dependency again. The
resolver seam is a Debug-only environment value, defaulting to nil. These are
mailbox-presentation integration tests, not provider-resolution integration tests.

## Dictation upload — one bitstream pinned in two repositories

`FLACEncoderTests.writesTheStreamTheReferenceDecoderWasCheckedAgainst` pins the SHA-256 of the FLAC
stream for a deterministic speech-like signal; TabMail Voice's `apps/desktop/test/flac.test.ts`
pins the same hash for the same signal, which the reference `flac` decoder accepted. The signal is
computed in doubles with JavaScript's rounding so both produce identical samples. A change to either
encoder's choices fails its own suite, and the two apps keep uploading the same bytes. Losslessness
is checked by two independent decoders: `FLACTestDecoder` (every CRC checked) and Core Audio.
`decodesToTheSameSamplesWhateverLengthTheLastFrameIs` sweeps every last-frame length 1–40 and 127,
255, 1001, alone and after a full block, over noise, a tone (a high predictor order) and quiet audio
with a full-scale burst and a step (the largest Rice parameter): each of the encoder's predictor-order,
partition-order and Rice-parameter guards, removed, fails it (a trap or a stream that does not
decode to the samples). The size tests hold digital silence to a few bytes a frame (the constant
subframe) and full-scale audio to its PCM plus a frame's overhead (the verbatim fallback the upload's
size bound rests on).

## Device Sync — labelled bullets, shared with Thunderbird and Voice

`DeviceSyncVectorsTests` runs the conformance vectors Thunderbird and TabMail Voice run too
(`TabMailTests/Fixtures/DeviceSync/device-sync-vectors.json` and the bundled default catalog, both
SHA-256 pinned, so a change to the shared files fails all three suites until each re-pins). Each
scenario runs on simulated devices (`BulletDevices.swift`): every device runs the real `PromptBulletSync`,
`BulletSync`, `Bullets` and `UserDefaultsBulletStore` on its own `UserDefaults` suite, connected through a
relay the scenario delivers, reorders or drops. `DeviceSyncFuzzTests` runs seeded random devices, edits,
resets, failed saves, restores and deliveries, and asserts at every delivery that no bullet a user did not
delete is lost, at the end that the devices converge and stop sending, and that no message exceeds the
relay's budget (8 seeds by default; `DEVICE_SYNC_FUZZ_SEEDS` sets more, 30 pass).

`PromptSemaphoreTests` covers the prompt store's one semaphore: a hold is released when its body
returns, throws or is cancelled; a hold past its lease loses it, hands the semaphore on and does not move
the counter; a call made inside a hold, and from a child task of the holder, is refused as busy at once; a
task created under the cleared mark waits instead; waiters take the semaphore in the order they asked, a
request made as the holder releases queues behind the line, a cancelled waiter and one past its wait leave
the line and are never granted. `PromptStoreBoundaryTests` pins the AI write (read, call holding nothing,
write carrying the counter) being dropped after a local edit, a reset, a restore or a lapsed lease, with
the stored state, the rendered text and the history unchanged; the counter moving only on a saved change;
a hung model call blocking nothing; and the two gesture-order inversions (delete then add, add then
delete) ending as the user's last gesture. `DeviceSyncReceiveTests` covers arrival order with the busy
re-apply, the connection end dropping everything waiting, the bound (messages plus held parts) renewing
the connection, and an older `prompt_state` never landing on a newer edit. `DeviceSyncSocketBoundaryTests`
runs a loopback WebSocket server to show a message read after its connection was replaced is dropped.

## Gmail thread binding — Send and draft uploads

Gmail files a message or draft in a conversation only when the request's `message` resource names the
`threadId`, the raw message's In-Reply-To/References name the parent, and the Subject matches.
`GmailSendBodyTests` covers the Send body. `GmailReplyDraftThreadTests` drives production
`DraftStore.pushDraftToServer` against a real `GmailProvider` on `FakeHTTP` and reads both
`drafts.create` and `drafts.update` off the wire: each carries the `threadId` that
`ThreadUtils.outgoingThreadHeaders` gives Send for the same reply (the parent's id for a matching
subject, none for a changed one) beside the headers that name the parent. A reply draft saved in a
different Gmail account than its parent sends no `threadId` on either request, as Send from that
account would not, and still names the parent in its headers. Both cases run with and without a
stored attachment, so the multipart upload is held to the same binding and keeps the body and the
attachment bytes.

## Gmail history pages and the delta work bound

`GmailHistoryPaginationTests` drives production `SyncEngine.performDeltaSync` end to end against a
real `GmailProvider` on `FakeHTTP`. The property: the Gmail delta applies every history record after
the stored cursor before the cursor moves, and never moves it past a page it did not read. Covered:
every page applied with the first page's `historyId` as the cursor and the page token percent-encoded
on the wire; each of three page requests carrying the original query, a `maxResults` Gmail accepts and
only the current page token; a deletion on a later page applied (the deleted row removed, a bystander
kept, a message added then deleted never fetched or kept); a later page that fails (error status,
transport failure, cancellation, or a 200 whose body is not a history page) applies nothing and keeps
the cursor; a later-page 404 and a history past the page limit clear the cursor for the full sync. The
work bound, which stops a delta from committing to more message GETs than the sync deadline can
carry: the record budget on its own (records that name nothing to fetch), and the distinct-message
budget for every record kind that makes the delta fetch a message, on one page and across pages,
each at exactly the budget (applied) and one past it (no GET, cursor cleared); a message named by two records on different pages counts once. A page without
`history`, Gmail's answer to a quiet poll, is an empty delta that moves the cursor.

## Gmail search text on the wire

`GmailProviderMockTests.searchTextReachesGmailIntact` decodes the recorded
search request the way Gmail reads a query string (`&` separates parameters,
`=` splits name from value, `+` is a space) and asserts that the user's text,
including `&`, `+`, `=`, `%`, `#`, non-ASCII characters, literal percent escapes
such as `%26` (which must not be decoded first) and a `from:` address with a `+`
tag, comes back as exactly one `q`, with no stray parameter. Search text holding
the synthetic All Mail marker is sent as typed: `GmailProviderMockTests.syntheticFolderGuard`
asserts the guard refuses the marker in the path and in folder parameters such as
`labelIds`, and never in `q`.

## Delta detail fetches — a failed fetch is never taken for a deleted message

`DeltaDetailFetchFailureTests` drives production `SyncEngine.performDeltaSync` end to end on
`FakeHTTP` for Gmail and Outlook, whose deltas fetch each changed message by id. A message whose
fetch fails (a 5xx, a non-gone 4xx, a transport failure, a body that does not decode, a 200 whose
record has no usable date) fails the delta and keeps the cursor (the Gmail history id, the Outlook delta link); on the next pass the
fetch succeeds and the change lands. A message that answers 404 is gone and is skipped: the rest of
the delta is applied and the cursor moves. A Graph refusal on the detail fetch is still logged with
its error code and message. Called directly with the gone message first (404 or 410), the detail fetch still
returns the readable one. Through the foreground poll `SyncEngine.sync(account:)` on a registered
work queue, with a full sync due, a Gmail message whose fetch never succeeds does not stop sync: the
full sync completes past it (its row kept), the capture moves the cursor, and on the next ordinary
poll (no full sync due) the delta lands later changes. A dropped connection, a 401 the token refresh does not cure, or a cancellation
during the rate-limit backoff still fails that folder's fetch. On Outlook, a message whose fetch
never succeeds is bounded by the poll's cursor capture after its full sync, which walks the inbox's
delta pages to the final link; the next ordinary poll's delta from that link lands what changed after
it.
The Gmail detail fetch keeps the request gate's full width of gets in flight (so a delta of a few
dozen messages fits the background deadline), never more: a later request on the same account waits
behind at most one window of gets, not the whole delta: with the first window held, a request waiting
at the gate takes the first slot one answer frees, ahead of any further get. A fetch larger than its window still fails on
one message's failure, and gone messages filling the whole first window do not end it early: every
readable message after them is still fetched. Cancelled while its gets wait out a 429 backoff, the fetch
throws the cancellation (never a partial list), sends nothing more, and a full window can run after it.
`GmailDetailWindowFuzzTests` runs seeded schedules (latency; readable, gone, failing, dropped and
rate-limited answers; a request joining the full gate; a cancel while a get awaits its answer or its
backoff) and checks the first window is all on the wire before any answer, the first freed slot,
the returned multiset, throw semantics, termination and gate reuse
(`GMAIL_DETAIL_FUZZ_ITERATIONS`, `GMAIL_DETAIL_FUZZ_SEED`, `TEST_RUNNER_` prefix on the CLI).

## Calendar chat tools — the resolved calendar account

`CalendarProviderDispatchResolveTests` pins which calendar
`CalendarProviderDispatch.resolve` names: the demo calendar or nothing in demo
mode, never the demo calendar outside it, an active preferred account first,
otherwise the first active registered one. `CalendarToolResolvedAccountTests`
pins what the tools do with that answer, through the real tool entry points: a
confirmed create reaches the resolved account's calendar and no other registered
calendar, and with nothing resolvable it says so and queues nothing; an edit or
delete given a bare event id reads the event through the resolved calendar (the
card shows the real event) but still queues nothing and sends nothing, and with
nothing resolvable it is refused before any card.

## Google Calendar search text and OAuth token bodies on the wire

`GoogleCalendarSearchEncodingTests.searchTextReachesGoogleCalendarIntact`
decodes the recorded `listEvents` request the same way and asserts that the
event search text (with `&`, `+`, `=`, `%`, `#`, non-ASCII characters and
literal percent escapes) comes back as exactly one `q`, with no stray parameter.
`OAuthTokenRequestTests` builds the Google and Microsoft code-exchange and
refresh requests and reads each body as a form, asserting that a code,
verifier or refresh token holding `+`, `&`, `=`, `/` or a literal `%2B` arrives
exactly as given, every field appears once, and the endpoint, method and
content type are the token endpoint's. The same suite drives the four real
sign-in and refresh calls (`OAuthService` with a fake token transport) and
asserts each sends its own grant, once, to its own provider's endpoint.
`GmailProviderExactDraftResourceTests` serves a later drafts page only for the
exact page token it issued (one holding `+`, `/`, `=`, `&` and a space) and
reads the second request's query as a form. `CredentialRefreshContractTests` reads
the notification extension's refresh body the same way, with a grant holding
`+`, `&`, `=` and `/`. All four use `FormDecoding` (test helper). Every one of
these values, and Graph ids and search text, Gmail search and the Gmail
drafts.list and history.list page tokens, is encoded by the single
`StrictPercentEncoding` in `Shared/HTTP`. A synthetic folder marker that reaches
the bad-request-preserving entry (`modifyMessage`) is refused before any network
call, as at the ordinary request entry.

## Gmail older-mail paging — one failed message does not stop the page

`GmailOlderPageFailureTests` drives `GmailProvider.fetchOlderMessagesWithCoverage` on `FakeHTTP`. A
page where messages answer 404, 410, 400, 503 and an unreadable body still loads every other
message, reports those five as named but not loaded, and counts the whole page as covered. A 401
the token refresh does not cure, or a dropped connection, still fails the page, and so does a page
cancelled while a message waits out the rate-limit backoff: it never reports coverage and asks for
nothing more. Through the real caller, `GmailReceivedDateBoundaryTests` pulls older mail with
`SyncEngine.fetchOlderMessages` the way the scroller does: a full page with one message Gmail cannot
serve still says there may be more, so the next pull loads the message beyond it, the unreadable
message gets no row, and the stored rows stay.

## On-demand folder sync — a folder the provider reports gone

`FolderSyncGoneStatusTests` drives `AccountManager.syncFolders(_:)` over two folders of one account
whose provider throws the Gmail and Outlook HTTP error shape (`ProviderError.networkError` around
`HTTPError.networkError(statusCode:)`). A 404 or 410 skips the folder: no error reaches the caller
and the next folder is still synced. Any other status (500) still reaches the caller.

## Gmail label create — a name Gmail already has

`UserLabelCreateExistingNameTests` creates a label through `UserLabelMenuModel.createAndApply(name:)`
against `StatefulGmailActionServer`, which answers 409 "Label name exists or conflicts" when a user
label with that name (compared without case) exists. A name Gmail already has applies Gmail's
existing label: the gesture succeeds, Gmail is asked to add that label's id, the stored row and the
menu entry carry Gmail's spelling of the name, and a label already in the menu, under an older name, is
listed once under Gmail's name. A 409 for a name the label listing no longer has (deleted elsewhere in
between) fails the gesture and writes nothing: no label row, no menu entry, no queued label change. A
create that fails with any other status (a 500) is refused the same way and writes nothing, even
though Gmail lists a label by that name, so only the 409 leads to the lookup. A
free name still creates and applies a new label. The 409 is read through `httpStatus(of:)`; a check of the
bridged `NSError` code on the thrown error never sees the HTTP status.

## Plan picker — no in-app purchase while a web subscription is live

`WebSubscriptionGateTests` decodes `/whoami` bodies through the real `AccountInfo` parser. A web
subscription that is active, trialing, past due, cancelled but not yet ended, unpaid, incomplete,
paused, or has no status counts as live, and `PlanPickerView.webManagedNote(for:)` then returns the
one plain sentence that replaces the purchase options. An ended or never-completed web subscription,
an Apple subscription, a signup trial (running or ended), no subscription, and an account not yet
loaded all leave the plans on sale. A status the app does not know counts as live.
`viewHidesEveryPurchaseOptionBehindTheGate` reads the view's source (a hosted `PlanPickerView`
fetches its own account) and pins the two gates: the billing toggle, plan cards, footnotes and Apple
disclosure sit in the `else` of the sentence, Restore Purchases sits inside its own gate, and Cancel /
Manage Subscription sits outside both.

## Draft placeholders and the Drafts sync window

`DraftPlaceholderStaleWindowTests` saves a draft through `AccountManager.queueDraftSave`, lets that
save land with no server address, re-saves it ten days later, and then runs the production sync
merge over a full Drafts page whose oldest draft is newer than the first save but older than the
latest one. The placeholder is not on the page and its latest save is inside it, so sync removes it
and the draft is not shown twice. The second case leaves the latest save queued: the same sync keeps
the placeholder, because the queued save names it, and the sync after that save lands removes it.

## Recurring series split — the new series' end

`RecurrenceTailCountTests` checks `RecurrenceTail.occurrences` against the worked examples of
RFC 5545 §3.8.5.3, whose occurrence lists are the oracle (the expected counts were also checked
against python-dateutil), plus the edges the RFC states in prose and every rule shape the counter
refuses, including INTERVAL above `RecurrenceTail.maxInterval` and BY values of `Int.min`, which would
otherwise overflow or trap. `RecurrenceTailNewSeriesRuleTests` covers the rule a split's new series
gets: COUNT reduced in place, a used-up or uncountable COUNT refused (the message names unreadable
dates or the uncountable rule, whichever it was), an UNTIL at or after the split kept, one before it
refused, a DATE UNTIL covering its whole day, and an UNTIL equal to the split's own cap refused like
any UNTIL before the split (#601: a retry finds its split through `SplitRecord`, never through the
series' end; until then the own cap was read as a retry). `GoogleSplitSeriesTailTests` and `CalDAVSplitSeriesTailTests` drive the real providers on
`FakeHTTP` with a series zoned to Pacific/Auckland at 07:00 and the split declared in UTC, so a rule
read in the wrong frame counts other weekdays. A refused split sends no write: Google sends only the
master GET, and CalDAV sends no PUT. `RecurrenceTailNewSeriesEndTests` pins the count's two anchors:
RFC 5545's DTSTART always counts, Outlook's range `startDate` only when the pattern names its day.
`RecurrenceTailMissingMonthDayTests` pins the measured Outlook month end (`MissingMonthDay.lastDay`:
monthly on the 31st gives January 31, February 28, March 31, April 30; yearly on February 29 gives
the leap day, then February 28 twice; the month end counts toward the number) against RFC 5545's
skip, which Google and CalDAV keep (the control also writes a Google/CalDAV COUNT across short
months). Years are the next common or leap year from today.
`ExchangeNumberedSplitTests` splits an Outlook numbered series on `FakeGraphCalendar` and holds the
two parts to the series through the fake's own range expansion (`rangeDays`): the capped part's
occurrences followed by the new part's are exactly the series', with an occurrence before the split
deleted, moved, or both (as measured, they still count), the split at the last occurrence, a range
starting the day before its first occurrence, every-other-week series whose weeks start on Sunday
and on Monday, a `relativeMonthly` series on the second Tuesday (plain, and with its range starting
the day before, a day the pattern does not name), the two measured month-end shapes split after a
short month (`monthEndSeries`: the fake's `absoluteMonthly`/`absoluteYearly` expansion first
reproduces the measurement, then the new part must be numbered N less the occurrences before it,
month ends included), and all-day series in a zone ahead of UTC and in
one behind it (a daily series split at midnight UTC, so a split day read in a zone moves back a day). A split with nothing left, or in a range zone
TabMail does not recognize, sends only GETs and creates nothing. A Google split asked to send the user's invitations sends them
only with the new series' create; the cap of the original goes out with `sendUpdates=none`.

## Outlook sends carry the Outbox's Message-ID

`ExchangeSentMessageIdTests` reads the requests `ExchangeProvider.send` makes on `FakeHTTP`. The
Outbox keys its optimistic Sent row by the Message-ID it generated, and sync replaces that row only
with a Sent Items copy whose `internetMessageId` matches; Graph answers a send with no id of its own.
A send without files asks `sendMail` for that id as the message's `internetMessageId`, in angle
brackets whether or not the stored id has them, and it normalizes to the key the row holds. A send
with files creates its draft carrying the id, then sends that draft. A reply, on either route, carries
the id together with In-Reply-To (`String 0x1042`) and References (`String 0x1039`) and no other
extended property. A draft save (create and update) does not set the id: `DraftStore` gives every
save a fresh one, and a Message-ID once set should stay constant. `ExchangeOutboxSentMessageIdTests`
drives the real Outbox send (`sendClaimedOutboxMessageForTesting`) for an Outlook account over
`FakeHTTP`, on both routes, and checks that the id Graph is asked for, the optimistic Sent row's key
and the claim's `sentMessageId` are one id. Its refusal case runs the real claim and send three times
while Graph refuses the send at `sendMail`, at the files route's draft create, or at its `/send`: every
claim reuses the first claim's id, every attempt asks Graph for it, each refusal is counted, the row
is shown as failed after the third, it is never marked sent, and no Sent row is written.

## Agent tool arguments — whole numbers

`ToolArgumentWholeNumberTests` covers `JSONValue.wholeNumber`, the one way a tool reads an integer
argument. A JSON number `Int` cannot hold decodes as `.double`, so the accessor accepts an `.int`
or a `.double` holding a whole number in `Int`'s range, and nothing else. It then drives every tool
that reads an integer argument with values outside `Int` either way and with a fraction: the
message tools' `unique_id`, `EmailDeleteTool.parseUniqueIds`, the settings value, the template id,
the contact-search `limit` and the calendar-search `page_index`. Each one refuses the value rather
than truncating it. The calendar-search reply for the largest page is checked too. The recurrence
`interval` and `count` must be whole numbers of 1 or more: the event builder throws on anything
else, and calendar create and edit refuse it before the confirmation card. A source check fails if
a new `.double` binding appears under `Services/AI` or `Services/Account`, the one allowed being
the PDF tool's page number, which is bounded before it converts. `CalendarQueueArgumentValidationTests`
stores a create and an edit carrying such a count, as an earlier build could have queued them. The
drain retires each one with its reason and sends nothing to the provider. `MemoryReadToolTests`
refuses a `timestamp` that is not a whole number (including `"1e300"`, `"nan"` and a fraction) and
answers whole numbers at the ends of `Int`, with tolerances whose window edge falls past Int64's
range, by leaving that side of the window unbounded; `MemoryIndexTests` reads a turn with no session
through a window whose upper or lower edge falls past that range. The delete tests check that a fractional id
in `unique_ids` is dropped, not truncated.

## CalDAV series edits — moving a series' time

`CalDAVSeriesStartShiftTests` checks what an edit that moves a repeating
CalDAV series' start does to the values tied to that start. `SeriesOracle`
reads a weekly series independently of the code under test (occurrences on
the wall clock from `DTSTART`, cut by `UNTIL` or `COUNT`, matched against
`EXDATE` and each override's `RECURRENCE-ID` as instants), and each move must
keep every occurrence in the same state: deleted, changed, or shown, the last
one included. Cases cover a same-day time change, a one-week move across a
daylight-saving change, values a server stored in UTC, all-day and floating
series, an RRULE the edit writes itself, `RDATE` and `PERIOD` values, a
folded `EXDATE`, and a zone the device does not know (moved on the wall clock
when no conversion is needed, refused when one is).
`CalDAVSeriesStartShiftWireTests` drives the same through `updateEvent` over
the fake CalDAV store: a movable series lands whole in one `PUT`; an
unmovable one is refused with no `PUT` and the server keeps the original.

## Calendar edits keep the event's kind

`CalendarEditKeepsKindTests.swift` drains real `.edit` rows through `AccountManager.drainCalendarQueue`.
An edit that leaves `all_day` out keeps the event's kind: an all-day event given new dates stays all-day on
those dates, a start alone carries the end by whole days, and a timed event given a date alone stays timed
at midnight. A stated `all_day` changes the kind either way, and `all_day: true` with a time of day keeps
the date. An all-day event given a time of day with `all_day` left out is refused with nothing written and
retired with a reason that tells the assistant to ask the user whether it stays all-day or becomes timed:
on Google, on the CalDAV split (no cap `PUT`), and in the queue suite on every `edit_scope` for a start, an
end alone, both, and a midnight start with a timed end; a timed event given a time is written. A date at
midnight, with or without seconds, an offset or a fraction, names no time of day (`namesTimeOfDay`). The Google
and Outlook suites run the providers against stateful fakes on `FakeHTTP` (PATCH replaces the properties it
names) and assert on the stored event, for a single event, one occurrence and, on Google, a split's new
series. The CalDAV suite asserts on the stored `.ics`: a move lands as `VALUE=DATE` lines, and a split's new
series starts on the date given; a start given alone moves `DTEND` with it, so an all-day event keeps its
days and a timed one its length across the March daylight-saving change. `CalDAVSeriesStartShiftTests` checks
the same on the merge alone, plus a `DTEND` in another zone from `DTSTART`, a `DURATION` master (no `DTEND`
added), an end the patch gives (written as given, even over a `DTEND` that could not be moved), and a `DTEND`
that cannot be read or converted (refused). An all-day edit whose end date is on or before its start date is
refused before any write on every `edit_scope`, including a split's cap `PUT`, and retired with a reason
that tells the assistant to ask the user how many days it should last.
An end given alone is compared with the start the edit keeps: the stored start (a timed one's date included)
on `all`, the occurrence's own date on `this_only` and `this_and_following`; a start the edit gives is what the
end is compared with on every scope. On `this_only` the occurrence's date is the day it starts on now
(`CalendarProvider.occurrenceStartDay`): CalDAV addresses an occurrence by its original slot, so one moved on
its own is read from the resource (its own `DTSTART`), and an end on or before the moved start is refused while
an end after it is written, including one on the original day when the occurrence was moved earlier, both with
`all_day` left out and with a stated `all_day: true` (which skips the queue's read of the event, so the stated
kind alone asks for the occurrence's day); Google and
Outlook address an occurrence by its current start, so the default is `recurrence_id`'s date: through the real
providers, an end alone on one all-day occurrence's own day is refused with no write, and one two days later is
written with the occurrence's start unchanged. The queue and the
tool read it only for an end given alone on one all-day occurrence (an edit of one occurrence that gives no end,
even with `all_day: true`, reads nothing; in the tool a rename goes through though the read would fail); a
failed read in transport keeps the edit queued (queue) or shows no card (tool). The tool reads it on the
calendar it knows for a numeric event id, in the edit's zone. An edit that gives no times
still saves an all-day event stored with its end on its start. The queue suite counts
`getEvent` calls: an edit that moves nothing and sets no UNTIL makes only the one that finds the series, and a failed read on a move writes
nothing and stays queued. `calendar_event_edit` applies the same rule (`allDayEditRefusal`, one function for
the tool and the queue) to the event it reads before its confirmation card: an all-day event given a time of
day without `all_day`, and a stated `all_day: true` with a same-day end, are refused there with nothing
queued and no card shown, also for a scoped end on the occurrence's own day (`this_only`,
`this_and_following`), so the assistant asks the user before any card; an allowed move of an all-day or a timed
event reaches the card and is written. Controls on the shared rule: a timed event given a
time, an event that was not read, a stated conversion, midnight dates and an edit giving no times are not
refused.

A stated `all_day` that differs from the stored kind, on CalDAV (`CalDAVCalendarEditKeepsKindTests`): with a
start and an end, an all-day event becomes timed at those times and a timed one (stored with `DTEND` or with
`DURATION`) becomes all-day on those dates, with the rest of the event kept, and a zoned event stored with a
VTIMEZONE whose own rules repeat converts with the VTIMEZONE kept byte for byte. A change that gives only a
start or only an end, in both directions, a change on a repeating event on every `edit_scope` in both
directions (a timed series made all-day, an all-day series given times of one day), and a change on an event
that repeats only by `RDATE` or only by a changed occurrence (a master with no rule plus a VEVENT with
`RECURRENCE-ID`, on `all`), are refused
with nothing written and the stored event byte-identical. `CalDAVOccurrenceOverrideTests` refuses times on an
all-day occurrence rather than writing their dates.

A stated `all_day` of the other kind that gives no `start_iso` or `end_iso` (`CalendarEditToolAllDayEndTests`):
the shared rule refuses it, in both directions and on every scope, and refuses nothing when the stated kind is
the stored one, when the edit gives times, or when the event was not read. Through `calendar_event_edit`, for
the event as Google's, Outlook's and CalDAV's own `getEvent` read it from their fakes, it is refused before the
card, reported as not changed, and nothing is queued.

## An edit of every occurrence reaches the series

`CalendarSeriesScopeTests.swift` pins the system properties of a series edit (`CalendarSeriesScope`). An
edit of every occurrence changes the series, whichever occurrence the event id names (#560). A time change of
every occurrence goes where Google Calendar takes it (#559):
- named from the first occurrence, the whole series moves;
- named from a later one, a new time of day on the date it is on now is the whole series' new time (moved to
  the first occurrence's date); a new date changes that occurrence and the ones after it, through the split;
- with no occurrence named and a new date other than the series' own, nothing is written and the assistant
  is told to ask the user (`askWhichOccurrences`);
- an explicit `this_and_following` at the first occurrence is the whole series, a plain move.

An occurrence is named where it is now (its current start, the #613 contract), found by the provider's own
lookup (`CalendarProvider.occurrence`) before the card. A split at an occurrence moved from its place in the
series is not supported (#563, #687): the split's card is shown, then `splitSeries`' own check throws a plain
error with nothing written. `this_and_following` at a moved FIRST occurrence is an edit of the whole series. Whether a new start keeps an occurrence's date
is judged in the series' own zone (`GCalEvent.seriesZone`); a series whose zone is not known takes the
refusing side.

**The property** (`GoogleSeriesScopeInvariantTests`, `ExchangeSeriesScopeInvariantTests`): for every
(event_id, start_iso) pair the listing shows, `calendar_event_edit` is either refused before its card (no
card, nothing queued, nothing written) or, after the drain, the calendar holds what the card said, and the
output never carries a refusal after confirmation. Table-driven over occurrence states (unmoved; moved more
than a day; moved onto another occurrence's time, Google only since Graph refuses that move; the first
moved; deleted), naming forms (own id; own id and current start; series id and current start), scopes
(all, `this_and_following`, `this_only`) and changes (rename; a new time of day; another date on a named-day
rule; another date on a rule naming no days; another date with a new rule). The oracle is Google Calendar's
behaviour; the card's scope line is the extent checked (whole series, one occurrence, from here on). One
exception: a split at a later occurrence moved from its place (`this_and_following` there, and an "all" new
date from it) is not supported (#563, #687); its rows expect the split's card, then an error at the write
with nothing written and the row left failed. `this_and_following` at a moved first occurrence expects a
written whole-series edit (named-day date moves excepted, refused before the card).

The Google and Outlook queue suites (`GoogleCalendarSeriesScopeTests`, `ExchangeCalendarSeriesScopeTests`)
drain real `.edit` rows against `FakeGoogleCalendar` and `FakeGraphCalendar`, whose occurrences carry their
own ids, their series' id and their place (`originalStartTime` / `originalStart`; the Graph fake returns only
the `$select`ed fields; both fakes list `/instances` by where an occurrence is NOW; the Google fake leaves a
cancelled instance out of the list; the Graph fake refuses a PATCH moving an occurrence onto another,
`ErrorOccurrenceCrossingBoundary`). They assert on what the fake stores:
- a rename given an occurrence's id renames the series and not that occurrence;
- the first occurrence's id moves the series, on its own date and to another;
- a later occurrence's id moved to another date writes nothing and is retired, telling the assistant to use
  `this_and_following` at that occurrence; given a new time of day on its date it moves the series to that
  time (one `PATCH` of the series), moved occurrence included;
- `this_and_following` at the first occurrence moves the series; before the first, between two occurrences
  or off the series' days it is refused as not found, with nothing written;
- an occurrence moved onto another's time, named by its own id and that time, is the one changed; the
  series' id with that time is refused (ambiguous); an occurrence id with a time that is its place, or
  another occurrence's start, is refused (not found / `namesAnotherOccurrence`);
- a new date with no occurrence named is refused with the question; the series' own date moves it
  (control); a `recurrence_id` under "all" is honoured;
- Outlook all-day: an occurrence named by its id is dated by its `originalStart` read in the series' range
  zone, named as Graph gives it (`recurrenceTimeZone`: Tokyo, Kathmandu, Pacific, and a zone the server
  knows by a name TabMail does not), and is read with that `Prefer` zone.

`CalendarSeriesDayMoveTests` drains real `.edit` rows of series on named days: Google (`BYDAY`) moves to
another date refused, another time on the date moves (rule kept) or splits, a new rule moves it, the dates
are the series' own (Asia/Tokyo); Outlook weekly refused; CalDAV `BYDAY` refused with no `PUT`, a rule naming
no days moves (control).

`CalendarEditToolSeriesScopeTests` runs `calendar_event_edit` against the real providers: a later occurrence
to another date becomes a split on Google and Outlook; a new time of day on its date moves the whole series;
`this_and_following` at the first occurrence moves the series; the question and named-day refusals come
before any card with nothing queued; the card names an occurrence by one time, where it is now (no
"originally"). A split at a later occurrence moved from its place (#563) shows its card, then errors at the
write with nothing written and the row failed: `this_and_following` named there (Google) and an "all" new date
named there (Outlook), one test per path. `this_and_following` at a moved FIRST occurrence is shown and
written as an edit of the whole series (Google; red before the moved check left the occurrence lookup).

`CalendarSeriesScopeResetNoteTests` (PROOF P2, red-first against asking the occurrence with the edit as
given): an "all" time edit named by a later occurrence's id, or a shift from the first occurrence's id, shows
`ruleChangeResetNote` on the card and the fake counts one series reset (Google and Outlook); an occurrence's
own time given back with a rename shows no note and resets nothing.

`CalendarSeriesScopeRouteTests` and `CalendarSeriesScopeDayMoveRefusalTests` cover `route` and
`dayMoveRefusal` alone with `Named` values: as-given cases; a later occurrence's split at its current start
in the edit's zone; the first occurrence is the series; a new time
of day moved to the first date (calendar days across DST); the series' zone decides the date (Tokyo near
midnight), Outlook's recurrence zone wins, an unknown zone takes the refusing side; all-day by date, needing
no zone (a series in a zone TabMail does not recognize routes as any other; a time given as an all-day
place is refused as not comparable); date-only `recurrence_id`; end-only edits; starts without
seconds; refusals for no place, an unreadable start and before the first; each named rule part, given rules,
`this_and_following` compared with its occurrence's current start.

`ExchangeOriginalStartTests` maps Graph's `originalStart` on an ordinary read (an instant whatever its
offset; all-day the instant Graph gives; the all-day place as a date comes only from the lookup's read in
the series' zone), the series' zone from its range's `recurrenceTimeZone`, and a read selecting
`originalStart`. `CalDAVSeriesScopeTests` pins that a CalDAV occurrence carries its place
(`originalStartTime` from its key: a moved one at its place, `start` where it is), and that every naming form
and scope of an edit of a series whose stored zone TabMail does not recognize is refused before the card by
#613's `scopedEditSlot` (no card, nothing `PUT`, nothing queued), while the listing still shows it (#649).

A split starts at one of the series' own occurrences (`GoogleSeriesSplitCopyTests`,
`ExchangeSeriesSplitCopyTests`): a `recurrence_id` between two occurrences, off the series' days, at a
deleted occurrence or at a moved occurrence's place is refused with only `GET`s on the wire (not found). An
Outlook all-day series' occurrence is read in the series' own zone as Graph names it
(`allDayOccurrenceIsReadInTheSeriesZone`, from the measured values: Tokyo Standard Time, Asia/Kathmandu and
Pacific Standard Time, each with a plain occurrence, split at, and one moved a day earlier, a plain error
with nothing written; red for the zones ahead of UTC when the read does not name the series' zone), and a
series in a zone TabMail does not recognize is split like any other
(`allDaySeriesInAZoneTabMailDoesNotRecognizeIsSplit`). `FakeGraphCalendar` returns `originalStart` in the
zone `Prefer: outlook.timezone` names (its `zones`, else the resolver), as a UTC instant when none is
named, and records the zone of each read by id (`readZones`). A series that already ends on this
split's cap is not split again on any provider (#601; `ownCapIsNotSplitAgain` on Outlook, `ownCapIsRefused`
on Google, CalDAV and in `RecurrenceTailTests`): refused with nothing written. Before #601 a retry after
this split's own cap was not checked again (`CalendarProvider.isOwnSplitCap`, over `RecurrenceTail.isCapped`;
on Outlook `ownCapRetryDoesNotLookTheOccurrenceUp`); both are gone.

A split interrupted between its writes (#601, `SplitInterruptedBetweenItsWritesTests` in
`CalendarSeriesScopeTests.swift`, through the real queue on all three providers' wire fakes, with a later
change queued on the same account): once the new part is written, a retry never writes it again. The new
part there, the retry writes only the cap (`finishSplit`) and the split ends complete whether the cap
failed or its answer was lost, named by the series or its occurrence (T2, T3); the user deleted it (Google
read as `cancelled`, 404 or 410; CalDAV 404 or 410), the retry writes nothing, the row is failed with the ruled reason
(`SplitRecord.newPartDeleted`) and the next change drains in the same drain (T1; T7, Google's lost create
answer: `cancelled` refused at once; 404 or 410 keeps the row queued within
`SyncConfig.splitPartNotFoundGraceMinutes` and is refused past it, with the next change draining; the
first not-found answer's time is kept on the row and a later one within the grace does not move it); Outlook's numbered or end-dated range is kept on the new part (T4); a transient cap failure keeps
the record on the requeued row (T5); the record is on the row when the cap arrives (T6); Outlook POSTs once,
before every PATCH (T8); a series that already ends before the split is finished with no write (T10).
`SplitRecordIsReservedTests` (T9): `queueCalendarOperation` drops a `_split_record` a tool call carries.
`CalendarSplitConflictDispositionTests` (`CalendarConflictDispositionTests.swift`), Google's proven
duplicate 409: a proof read of 404 or 410 keeps the row queued with nothing capped within the grace (the
first such answer, or one a minute ago), is refused past it, and `cancelled` is refused at once.
Provider level: `SeriesSplitCopyTests.failedCreateLeavesTheSeriesUntouched` and
`failedRecordStopsBeforeTheCap` (Outlook writes nothing to the series before its create and its record).
`newStartPastTheEndDateIsRefused`: an Outlook split whose edit moves the new part's start past the series'
end date is refused with nothing written.
The fakes model it: `FakeGoogleCalendar.userDeletes(_:reads:)`/`failNext`/`beforeWrite` (a POST of a held or
gone id is 409 `duplicate`), `FakeGraphCalendar` `transactionId` replay, `userDeletes`, `writes`,
`beforeWrite`, `store`, `FakeCalDAVStore.failNextPUT`/`beforePUT`/`userDeletes(path:reads:)` (404 or 410).

History, before #601: a split interrupted after its cap ended complete on its retry (`SplitRetriedAfterItsOwnCapTests`, red before
the queue's `read` asked `isOwnSplitCap`): Outlook, the cap applied and its response lost (so no new part),
then retried: one new part at the split with the edit, the series ending before it, no row left; Google, the
cap's response lost on a series on its weekday given a new time on the split's date (the retry does not ask
`dayMoveRefusal`): the new part at the new time, the series capped, no row left; CalDAV
(`splitWhoseCapResponseWasLostEndsComplete`): every occurrence listed once where it was, the edit on those
from the split on, nothing queued or failed. `FakeGraphCalendar` and `FakeGoogleCalendar` take
`loseNextResponse` (the write applied, its response dropped); the Graph fake's `/instances` leaves out the
occurrences past a range's `endDate` in its `recurrenceTimeZone` (measured); `drainEdit(..., drains:)` drains
once per attempt.
`CalDAVOccurrenceEditToolToWireTests`: "all" and no `edit_scope` by a CalDAV occurrence id write the series
(#560); a moved later occurrence's `this_and_following`, by either id, shows the split's card, then errors at
the write with nothing `PUT` or deleted and the row left failed (#563; CalDAV's #613 check in its
`splitSeries`); `this_and_following` at a moved FIRST occurrence, by either id, is shown and written as an
edit of the whole series, one `PUT` of the series (`followingAtAMovedFirstOccurrenceEditsTheSeries`, red
while CalDAV's lookup took the split's scope).

The queue suite's `getEvent` counts are one per edit: that read tells an occurrence from its series. A
Google or Outlook occurrence edit or split adds one instances read.

## ICS value types — `VALUE=DATE-TIME` is timed

`ICSValueTypeTests` checks that a `DTSTART` stating `VALUE=DATE-TIME` (the default, which another client may
spell out) is read as timed by every ICS reader: `ICSParser` (CalDAV event reads), `ICSBuilder.parseIncoming`
(invitations in mail), and `CalDAVProvider`'s `icsIsAllDay`, `masterDTStartKind` and `parseICSDateTime`; for the
invitation reader and `parseICSDateTime` the instant is also checked against one computed independently. The CalDAV
split helpers (`extractMasterDuration`, `seriesSplitResources` with an empty patch) read such a master as timed with its real length, and a changed occurrence of such a series keeps a timed end of its length.
`VALUE=DATE`, in any case, is still a day at each of them. All of them match the
parameter through `ICSValueType.statesDate`, which compares it whole, never as a substring. In
`CalendarEditKeepsKindTests`, a CalDAV event stored with `VALUE=DATE-TIME` and moved with a start alone lands as a
timed event and keeps its length, and such a weekly series split this-and-following is capped with a date-time
`UNTIL` and continues as a timed series at the new time, in its own zone, with the same length.

## Calendar zone names — one resolver, per-resource context

Every calendar zone name is read through `CalendarTimeZoneResolver` over a per-resource
`CalendarTimeZoneContext`: an IANA name, a Windows name (CLDR table), or the `X-LIC-LOCATION` of the
resource's own VTIMEZONE. Fixtures name every zone and use dates in 2099.

- `CalendarTimeZoneContextTests` (`TabMailTests/Shared/`, new): `CalendarTimeZoneResolverTests` (IANA and
  Windows names, every CLDR target exists, a name before the location, a location tried as a name, a rules-only
  zone unrecognised); `CalendarTimeZoneContextTests` (folded and quoted TZIDs, first definition wins, only direct
  VTIMEZONE children, a hostile resource bounded in time); `CalendarToolHelpersWriteTimeZoneTests` (a Windows
  argument, an unknown zone refused with the exact message, the device zone as default).
- `CalDAVEventTimeZoneTests` (`TabMailTests/Providers/`, new): `ICSParserTimeZoneTests` and
  `ICSBuilderTimeZoneTests` read at the zone's instant (Tokyo, Windows, X-LIC zone; every name of the old
  14-name map reads the same; an unrecognised zone is still shown). `CalDAVTimeZoneWireTests`, against the
  fake CalDAV server: a time edit, series move, override and split land at the right instants and keep the
  stored TZID; an unrecognised zone is refused on each write, naming the zone, while a title-only edit lands.
  `CalendarTimeZoneResolverFenceTests` fails on any zone lookup outside the resolver and pins every
  context construction site (one per resource entry point).
- Changed: `CalDAVRecurringHelpersTests` (`parseICSDateTimeUnknownTZID`, `extractMasterDurationUnknownTZID`)
  and `CalDAVOccurrenceFrameTests` (`unknownMasterZoneFailsClosed`) expect the named refusal;
  `windowsMasterZoneIsRecognized` re-expresses a Windows master zone. Added: Exchange and Google Windows-zone
  reads, splits and patches (`ExchangeCalendarTests`, `GoogleCalendarTypesTests`, `GCalEventInputICSTests`);
  tool and queue refusals of an unrecognised `timezone` (`CalendarEventToolTests`, `CalendarToolHelpersTests`,
  `CalendarQueueArgumentValidationTests`, which also checks a Windows zone is written in that zone).

## Catch-up of older mail (IMAP and the generic apply)

`IMAPCatchUpTests` drives the real `IMAPProvider.catchUp` against `FakeIMAPServer` (with `CONDSTORE`)
and applies through the real `SyncEngine.runCatchUp`. Each test asserts the local rows the user sees.
The property: a server-side change to mail older than every sync window reaches the device, and
nothing is ever decided about a UID whose numbering is unproven (ADR-IOS-107). Covered:

- **Flags.** A read or flag change made elsewhere is applied, and unchanged messages stay as they are.
- **Removals.** A removal applies only when the server proves it: an expunged UID goes, while a UID
  whose FETCH record is missing (a short FETCH) but which `UID SEARCH` still finds stays.
- **Queued ops.** A queued flag op wins over the server's value, per message.
- **Budget.** An exhausted budget resumes on the next pass from the stored UID cursor. No request
  starts after the budget is spent, the removal proof included.
- **Not the backfill.** With a partial backfill, no command names a UID below the lowest local UID or
  above the highest, and no row is inserted.
- **Always-expensive network.** After `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` without a
  completed listing, a folder lists on an expensive network: one never listed, one on a server
  without CONDSTORE, and one whose listing was parked. The first sight of a folder on an expensive
  network writes when the wait began and makes no request.
- **A new folder.** A folder the full sync itself created follows an older-mail change on the next
  pass.
- **A just-completed user action** wins over a stale listing, per message.
- **Order.** Under budget pressure the folder whose listing was tried longest ago goes first.
  A folder whose request fails on every pass goes behind the others, and so does one that completes
  and is due again, so the folder behind is listed on the next pass (`failingFolderGoesToTheBack`,
  `completedFolderGoesToTheBack`).
- **A request that stalls or fails.** A stalled listing or removal proof is abandoned at the request
  timeout and applies nothing (`FakeIMAPServer.stallNextCommand`). A failed listing keeps what earlier
  ranges proved and resumes at the failed range; a failed proof removes nothing and is retried; one
  folder's failure does not cost the next folder its pass.
- **Epoch.**
  - A state from another UIDVALIDITY restarts the listing at UID 1.
  - A turnover seen on the wire applies nothing (no row removed even though none of the local UIDs
    exists in the new numbering), writes no state and raises the turnover reaction.
  - A folder with an unknown epoch gets no listing.
- **The first-stamp invariant (required).** A flag change made mid-listing to an already-listed
  range is applied by the re-list that the moved counter triggers. It fails if the completion stamp
  is the last range's.
- **Nothing due.** No request is sent when HIGHESTMODSEQ is unchanged and the daily check is not due.
- **Network.** The daily check waits for a non-expensive network, while a HIGHESTMODSEQ change still
  lists on an expensive one.
- **Turnover shapes.** A turnover that reuses the same UIDs applies no flags; one that lands between
  a range's listing and its removal proof removes nothing.
- **The pure plan.** `catchUpPlan` is checked for the cheap check, the interval, the network, a
  server without CONDSTORE, a listing in progress keeping its first stamp and waiting on an expensive
  network, and the bounded wait.

`CatchUpApplyTests` covers the generic apply on stub results:

- flag updates, a removal and the new state all land together, and no row is added;
- a folder whose numbering is being reset accepts nothing;
- a result from another epoch is reported as a turnover and applies nothing;
- a `.uid` result that names no epoch applies nothing, and neither does a folder whose stored epoch
  is unknown;
- the default provider returns nothing and nothing is written;
- the local-row reader reads by numeric range (numeric order), first id, id list and ordered scan.

`FolderCatchUpStateMigrationTests` checks that v98 adds a nullable `TEXT` column and leaves existing
folders without state.

## Outlook series end — the last day in the event's zone

Graph's `recurrence.range.endDate` is a date, read inclusively in the event's zone. A timed series'
`UNTIL` reaches the writer as a UTC instant (`CalendarToolHelpers.validatedRRuleUntil` turns a date
into 23:59:59 in the event's zone, then UTC), so `ExchangeCalendarProvider.graphEndDate` dates it in
that zone, and an `UNTIL` earlier in its day than the series' start time ends the series the day
before (RFC 5545 bounds the last occurrence's start inclusively, as Google Calendar expands it).
`ExchangeCalendarRecurringTests.timedSeriesEndsOnItsLastOccurrenceDay` drives the real producer and
writer for a 10:00 series in five zones on both sides of UTC (half-hour offsets and UTC+14 included)
and five ways of naming the end: a date, 23:30 and 10:00 end on the day named, 09:59:59 and 05:00 on
the day before; `secondsLessStartKeepsTheStartTimeRule` does the same for a start written `…T10:00`.
`allDaySeriesEndsOnTheNamedDay` keeps an all-day series' bare date (its input has no
zone label, so it runs in the simulator's zone). `graphEndDateForms` pins each `UNTIL` form in fixed
zones: a UTC instant moves to its local day and ends the day before a start time it does not reach
(inclusive at the start time itself), a floating time and a bare date keep their date whatever the
start, an unparsable 16-character `Z` value keeps its own date digits, and a start in
no wall-time form leaves the `UNTIL`'s local day. `graphEndDateRoundTrips` brings the rule
`toGCalEvent` derives from Graph's own `endDate` back to the same date in every zone. All dates are
relative to today, read once per test.

## Calendar repeat rules — every field written, or refused by name

`TabMailTests/Tools/CalendarRecurrenceDaysTests.swift` pins that `calendar_event_create` and
`calendar_event_edit` write every repeat field (`freq`, `interval`, `count`, `until`, `byDay`,
`byMonthDay`, `byMonth`, `wkst`) on every calendar, or refuse the call before the confirmation card
naming the field and the value, with nothing sent.

- `RecurrenceDaysWriterTests`: the writer and the card per field and combination; the card's words
  for a day counted from the month's end, the last day and a fifth weekday; every invalid token
  (including a malformed or impossible `until`, which is refused, never dropped) refused by both.
- `GraphRecurrenceRefusalTests`: everyday rules map to Graph patterns; rules outside Graph's pattern
  types are refused naming the field; `byMonthDay: -1` is named "the last day of the month".
- `GoogleRecurrenceDaysWireTests`, `ExchangeRecurrenceDaysWireTests`, `CalDAVRecurrenceDaysWireTests`:
  create and edit through the calendar queue against the fakes write the whole rule; Google and
  CalDAV keep EXDATE and RDATE; Outlook's create, edit and this-and-following writers each refuse a
  rule Graph can't hold with no POST or PATCH.
- `RecurrenceDaysToolTests`: the cards name the days; every invalid field, and an invalid `until`
  on Google, Outlook and CalDAV, is refused before both cards with nothing sent; a rule Outlook
  can't hold is refused before both cards.

## Calendar writes queued across a zone change — written as the card showed

`TabMailTests/Tools/CalendarWriteZoneSnapshotTests.swift` pins #753: a confirmed
`calendar_event_create` or `calendar_event_edit` writes the time its card showed, whatever zone the
device is in when the queue drains. Each case runs the real tool with `ToolContext(deviceZone:)` set
to a zone that is not the host's (the zone the user confirmed in), drains the real queue in the
host's zone, and compares the write on the fake with the card.

- `CalendarWriteZoneSnapshotTests`: timed create on Google, Outlook and CalDAV (start and end); a
  whole-series time change on Google, Outlook and CalDAV; one occurrence (`this_only`) on Google,
  Outlook and CalDAV; Google `this_and_following` (the new part starts at the card's start, the old
  part is capped); a zone change between two creates applies to the second; a CalDAV event with
  floating times is written at the card's wall clock. Controls: an assistant-named zone (IANA or
  Windows) is shown on the card and written in that zone; an all-day create keeps its date; a row queued with no zone (before
  #753) drains in the device's zone. Red-first: with the zone stamp removed every non-control case
  but the floating one fails; with the floating formatter reverted the floating case fails.
- `CalendarCardZoneLabelTests`: the card names a zone only when it is not the device's; a Windows
  name is the zone it names.
- `CalendarQueuedZoneStampTests`: the queued arguments name the card's zone when the assistant gave
  none (or an empty one) and change nothing else; a zone the assistant named (IANA or Windows) is
  queued as given; with no zone given the write resolves to the snapshotted zone. (The queue deletes
  a done row, and the tool starts a drain of its own, so the integration cases check the write, not
  the row.)
- Floating CalDAV series (#761, folded into #753): `this_only` and `this_and_following` of a weekly
  floating series confirmed in one zone and drained in the host's change the occurrence at the named
  wall clock, at the card's wall clock; an edit of every occurrence named by an occurrence id alone
  (no `recurrence_id`) drained in another zone is written and not retired as not found;
  control: an HOURLY floating series (which CalDAV does not expand) is refused before the card in any
  zone, nothing written.
- `CalDAVFloatingOccurrenceMatchTests`: `CalDAVOccurrences.scopedEdit` finds a floating occurrence by
  its wall clock in a zone that is not the host's (by `recurrence_id`, and with its occurrence id for a
  split), a moved changed copy where it is now, a changed copy held without its series, and a DAILY
  series named from zones a day apart (Kiritimati, Pago Pago) never lands on the day before or after. Controls:
  a wall clock no occurrence starts at names none; a listing still shows a moved floating occurrence
  at its wall clock on the device. Also `exdates_add` reads its dates in the tool's snapshot zone.
- `CalDAVWholeSeriesEditTests.floatingWholeEventNeedsTheEditsZone`: `mergePatchIntoICS` writes a
  floating time at the wall clock of the zone the patch names, and refuses an unlabelled one
  (`floatingWriteNeedsZoneMessage`).

## CalDAV organizer — every event with guests names its organizer

`TabMailTests/Providers/CalDAVOrganizerTests.swift` pins ADR-IOS-109 (#711): every CalDAV PUT runs
one organizer step, so a VEVENT with its own attendees is written with an organizer whenever the
resource names one or the server advertises the user's address, and never with a guessed one.

- `CalDAVOrganizerTests`: the real calendar queue against `FakeCalDAVStore` in its iCloud-like mode
  (a VEVENT with attendees and no organizer is refused with 403, `refusesAttendeesWithoutOrganizer`)
  and `FakeCalDAVPrincipal` (`calendar-user-address-set`, configurable or absent). The invariant is
  checked on the stored resource: a create, a first guest on the whole series, on one occurrence
  (the guest-less series gets the organizer too, RFC 6638 §3.1) and on a split, and a title-only split of a series whose stored guests have no organizer all land with
  the advertised address; an existing organizer stays byte for byte (a folded one too) and is copied
  to the VEVENT that needs it, with no lookup; the sign-in is written only when advertised, in the
  server's spelling, else the first advertised `mailto:`; nothing advertised writes nothing (a
  lenient server stores it, a refusing one retires the edit with the 403 reason and no change); a
  lookup 503 or transport error writes nothing and leaves the edit queued; a lookup 404 is never
  "event not found"; no guests, or only an alarm's recipient, makes no lookup; a resource of someone
  else's changed occurrences never gets the account's address (test 16, the one test written
  through the provider's one-occurrence edit rather than the queue, because the queue's series read
  can't read such a resource; it moves back to the queue path when #720 is fixed); the address set is read once per
  provider, while an answer read as none is not kept and the next guest write asks again; an
  advertised href with a line break is skipped; a replay after a lost PUT response
  leaves the server unchanged. The lookup's error classes (T1-T6): a 403, 405 or 400 means none
  advertised; a 408, 409, 423, 425 or 429 keeps the edit queued with nothing written; a failed
  lookup is never kept, so the retry asks again; an answer that is not XML, or a server with no
  principal, means none; a principal answered 404 is never "event not found"; a split whose capped
  series alone needs the address looks it up before its first PUT; a lookup answered 401 sends no
  PUT and is retired by the auth arm with its reason (T7). Deleting one occurrence of a series whose
  guests have no organizer writes its `EXDATE` PUT with the advertised address (test 20).
- `CalDAVOrganizerStepTests`: the pure step (`organized`) returns a body that needs nothing byte for
  byte (a series with its organizer and guests beside a changed occurrence with neither too),
  gives every VEVENT without an organizer the same one once any VEVENT needs it (one that has
  its own keeps it), inserts after `UID`, copies every physical line of a folded organizer, reads only a VEVENT's
  own properties, never gives an override-only resource the own address, and is idempotent; the
  chooser (`organizerHref`, the sign-in matched in any letter case and with surrounding spaces);
  and a source fence: one `CalDAVClient.put` call site, inside `putEvent` after the organizer step
  (the site is looked for after `putEvent`'s declaration, so a stray call fails the test instead of
  trapping it).
- `MultistatusParserTests.parsePropertyWithSeveralHrefs`: a property with several hrefs gives every
  one, in order (`propertyHrefs`); `properties` is unchanged.
