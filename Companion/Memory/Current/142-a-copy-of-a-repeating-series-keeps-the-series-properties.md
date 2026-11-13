# A copy of a repeating series keeps the series' properties

**Keywords:** `splitSeries`, this-and-following, new part, capped series, occurrence override,
`seriesSplitResources`, `occurrenceOverrideResource`, `CalDAVEventCopies`, `splitNewPartJSON`,
`serverOwnedEventKeys`, `splitCopiedKeys`, `splitSelect`, `splitReschedules`, `applyAttendeeRule`, `insertEventJSON`,
`conferenceDataVersion`, `supportsAttachments`, `splitRecurrence`, `keptAttendeesJSON` (retired), `editJSON`, `filterDateList`, `RecurrenceTail`,
`newSeriesEnd`, `occurrencesLeft`, `numberOfOccurrences`, numbered range, `Anchor`, `patternStart`, WKST, `firstDayOfWeek`,
`MissingMonthDay`, `lastDay`, month end, 31st, February 29, leap day, `absoluteMonthly`, `absoluteYearly`,
`rangeDays`, #474, #562,
`AttendeeChange`, `attendeeChange`, `applyAttendeeChange`, guest change, `resolveAttendeeDelta` (retired), #620,
`seriesDifference`, series difference, remove everyone, `"*"`, `mailto:*`, re-add, cancelled occurrence,
EXDATE, RDATE, COUNT, recurrenceTimeZone, attendee answers, `needsAction`, write order,
create first cap last, lost cap response, retry, own cap, `successorIsOurs`, `capEndDate`,
RFC 6638 §3.2.8, PARTSTAT reset, `this_only` move asks again, Thunderbird add-on split only,
LOCATION, `changedOccurrenceKeepsItsOwnProperties`, #604, VALARM, alarm, `ICSParser`, `topLevel`,
`masterTopLevelLines`, `masterVEventLines` (retired), trailing whitespace, #603.

## The rule

A this-and-following edit writes two things: the capped series and a new part that starts at the
split. A CalDAV one-occurrence edit writes an override. **Each copy is built from the stored
series, not from the narrowed `GCalEvent` or the edit's fields.** So every property the edit does
not change arrives as the server stored it. Rebuilding a copy from the fields we model drops
everything we don't: categories, class and sensitivity, importance, reminders and alarms,
attachments, conferences, extended and X-properties, attendee roles and parameters.

## Per provider

- **CalDAV** (`CalDAVEventCopies.swift`):
  - `seriesSplitResources` and `occurrenceOverrideResource` copy the master VEVENT's top-level
    property lines (`masterTopLevelLines`) and change only what they must: UID,
    DTSTART/DTEND/DURATION, RRULE, RECURRENCE-ID, EXDATE/RDATE and the fields the edit sets. A
    split's new part gets a new DTSTAMP and drops SEQUENCE, CREATED and LAST-MODIFIED; a new
    override gets a new DTSTAMP; an existing override is reused as stored.
  - An override never takes a repeat rule from the edit: a rule belongs to the series, as on
    Google (`instancePatch.recurrence = nil`) and Outlook.
  - An override with an unsupported shape throws `notSupported` rather than writing a partial
    copy.
- **Google** (`splitNewPartJSON`):
  - The new part is the stored event JSON minus `serverOwnedEventKeys` (ids, etag, sequence,
    links, creator and organizer, `hangoutLink`, …), under the deterministic id. `privateCopy` is
    not among them: it can be set on insert, so a series that is a private copy gives a new part
    that is one too.
  - It is created with `insertEventJSON`, which adds `conferenceDataVersion=1` and
    `supportsAttachments=true`. Without these flags Google drops the conference and the
    attachments from a create.
- **Outlook** (`splitSelect`, `splitCopiedKeys`):
  - The split reads the series with every copied property selected, then overlays the edit with
    `toGraphEventJSON`, keeping each attendee's stored type.
  - The stored `recurrence.pattern` is written verbatim on both parts, together with the stored
    range's zone. The cap is the stored range with type `endDate`, sent with the stored pattern's
    `firstDayOfWeek` and the range's `recurrenceTimeZone` (asserted on the cap as sent in
    `ExchangeSeriesSplitCopyTests.cappedSeriesKeepsItsPattern`: a live cap that sent a range with no
    zone and `firstDayOfWeek` "sunday" moved a Pacific series to UTC, in the shape the split wrote
    before #610). The new part's range starts on
    its own date; a numbered range stays numbered with what is left of its number
    (`occurrencesLeft`, #474), and `endDate` is kept verbatim only for an `endDate` range. (Before
    #474 a numbered range became `noEnd`.)
  - The create body is built **before** the cap is written, so a series that can't be copied is
    refused while nothing has changed.
  - The revert after a failed create writes the stored recurrence back exactly.
  - New notes on an online series replace only the notes in the copied HTML body, keeping its
    join section as stored (`onlineMeetingBody`, as for an edit of the series). The new part is
    not an online meeting of its own (no `isOnlineMeeting` is sent): its body carries the series'
    join link, which still joins the series' meeting. Making it a meeting of its own would mean
    sending `isOnlineMeeting` with a body that already has a join section; what Graph writes then
    has not been checked live.

## Write order and retries

A retry reads the series as the previous attempt left it. If that attempt's cap landed and its
response was lost, the series it reads is already capped.

- **CalDAV and Google write the new part first and the cap last** (`CalDAVProvider.splitSeries`,
  `GoogleCalendarProvider.splitSeries`; ADR-IOS-106). The cap
  removes the changed occurrences (override VEVENTs), excluded dates and added dates after the
  split, which the new part takes over. Cap first, a lost cap response meant the retry copied the
  new part from a series that no longer held them, and they were gone for good. Create first,
  every interruption leaves at worst both parts showing the later occurrences until the retry
  writes the cap, and nothing the series held at the split's read is lost (a change another client
  makes to the later occurrences after that read is not on the new part, and the cap removes it).
  The retry finds its own new part (CalDAV: the create-only PUT 412s and
  `successorIsOurs` proves the UID; Google: the insert's 409 is a proven `duplicate` of the
  deterministic id and the proof-GET reads it) and goes on to the cap. There is no rollback: a
  failed cap is rethrown. A cap refused for good (a 400-class answer the queue retires) leaves both
  parts showing the later occurrences; deleting the new part is one gesture. (Before 2026-11-10 both
  capped first, with `revertMasterCap` and Google's revert PATCH; on Google a lost cap response then
  lost the later excluded and added dates, #581.)
- **Outlook still caps first and reverts on a failed create** (`splitRollbackError`). Its new part
  copies nothing the cap removes except the range end, and its create is a POST whose only retry
  guard is Graph's `transactionId`: create first would re-POST on every failed cap, leaning on that
  guard far more often. A retry after a lost cap response reads a range that already ends on this
  split's cap (`capEndDate`); kept, the new part would end before it starts, so `splitNewPartJSON`
  writes it as `noEnd`, the own-cap rule `RecurrenceTail.newSeriesRule` applies. Such a new part
  repeats with no end where the series had an end date; editing its end repairs it. The same holds
  for a numbered series (#474): its number is gone once the cap is written, so such a retry's new
  part has no end either, until #601 moves Outlook to create first.
- **Amendment (2026-11-11, #601, ADR-IOS-106 amendment): every provider writes the new part first, and a
  retry finds its split through a record.** The Outlook bullet above is history: Outlook now POSTs the
  new part, then caps (`splitCapJSON`, `writeSplitCap`); its revert and `splitRollbackError` are gone,
  and `splitNewPartJSON` no longer takes `capEndDate`. An end-dated range is kept verbatim; a split whose
  edit moves the new part's start past that end date is refused with nothing written ("already ends
  before"): a new part would start after its own end. It is reached only that way, since the occurrence
  lookup already refuses a split past the range's end. Between the two writes `splitSeries` hands a `SplitRecord`
  (`series_id`, `new_part_id`, `split_at`) to its `SplitRecorder`; the queue keeps it under
  `_split_record` (`AccountManager.recordSplit`) before the cap is sent. A retry with a record never
  creates: `eventExists` on the new part, then `finishSplit` (the cap alone, or nothing when the series
  already ends before the split), or, the new part deleted, a refusal with `SplitRecord.newPartDeleted`
  and nothing written. The address-based guards (`successorIsOurs`, Google's 409 `duplicate`) still run
  on a retry WITHOUT a record (the create's answer was lost); Google then reads the event, and a
  `cancelled` one is refused at once, a 404 or 410 one only once `SyncConfig.splitPartNotFoundGraceMinutes`
  have passed since the first such answer (kept on the row as `_split_part_not_found_since`; until then
  it may be read-after-write lag and the operation stays queued). Limit: on Outlook and CalDAV a create that landed with its answer lost,
  then deleted by the user, is created again on the retry.
- **A rule from the edit replaces only the RRULE line on every provider** (#513): Google's
  `GoogleCalendarProvider.recurrence(_:withRuleFrom:)` keeps the excluded and added dates after the
  split (and on a whole-series edit, the series' own), as CalDAV does. Before #513 Google wrote the
  patch's rule alone and dropped them.

## Dates and rules

- **Excluded and added dates** (EXDATE, RDATE) before the split stay with the capped series;
  those at or after it go to the new part (`splitRecurrence`, `CalDAVProvider.filterDateList`).
  A date whose zone can't be read refuses the split **before any write**.
- **The new part's end:** on CalDAV and Google it ends where the series did, with the same UNTIL
  or what is left of its COUNT (`RecurrenceTail.newSeriesRule`, computed before any write); the
  copy builders take that rule as given. On Outlook the end lives only in the range, which
  `ExchangeCalendarProvider.splitNewPartJSON` rewrites from the stored one: an `endDate` range
  keeps its end date verbatim, and a numbered range stays numbered with what is left of its
  number (#474, `occurrencesLeft`). A rule in the edit replaces the stored recurrence instead.
  (Superseded text, kept for the record: "a numbered range becomes `noEnd`, because the number
  left after the split is not known there yet.")
- **What is left of a number is one rule for every provider** (`RecurrenceTail.newSeriesEnd`):
  the number less the occurrences the rule generates before the split, refused with nothing
  written when none is left or it can't be counted. Google and CalDAV write it as COUNT, Outlook
  as `numberOfOccurrences`. Occurrences that were deleted or moved still count: RFC 5545 counts
  an EXDATE'd occurrence, and on Outlook a weekly series of six with its third occurrence deleted
  and its fourth moved still read `numbered` six and still ended on its sixth week (measured
  2026-11-10). A numbered range reads `endDate` as the placeholder "0001-01-01" (measured), so
  that value is never an end.
- **How Outlook is counted** (`occurrencesLeft`): from the range's `startDate`, which Graph
  documents as "the date to start applying the recurrence pattern", the first occurrence being that
  date or later (`RecurrenceTail.Anchor.patternStart`: the start day counts only when the pattern
  names it, where RFC 5545's DTSTART always counts). Measured 2026-11-11: a weekly Tuesday and
  Thursday series of four created with its `startDate` and start on a Monday had four occurrences,
  all on Tuesdays and Thursdays, so the Monday did not count; Graph had also moved the event's start
  and the range's `startDate` to the Tuesday on create, so a stored series normally starts on a
  pattern day. Then: the split occurrence's day in the series' zone
  (`GCalEvent.seriesZone`; an all-day split's date as given); weeks starting on the pattern's
  `firstDayOfWeek`, sent as the counted rule's WKST; and a month without the pattern's
  `dayOfMonth` holding the occurrence on its last day, counted (`RecurrenceTail.MissingMonthDay.lastDay`,
  passed only by `occurrencesLeft`). Measured 2026-11-11: `absoluteMonthly` on the 31st, numbered 4,
  gave January 31, February 28, March 31 and April 30; `absoluteYearly` on February 29, numbered 3,
  gave the leap day, then February 28 twice. RFC 5545 skips such a month and does not count it
  (`.skip`, the default), and Google and CalDAV keep that. An unrecognized range zone or an
  uncountable pattern is refused before the cap. The cap's own date is still worked out in the operation's
  zone (#681).
- **A split that moves the start (CalDAV):** the edit lands on the new part through
  `CalDAVProvider.mergePatchIntoICS`, the same merge as a whole-series edit, so its start shift
  (`shiftSeriesAnchoredValues`, #558) also moves the new part's EXDATE and RDATE, its UNTIL (unless
  the edit wrote its own rule) and its changed occurrences' RECURRENCE-IDs; a changed occurrence's
  own DTSTART stays where the user put it. The capped series is never merged with the edit. A
  one-occurrence override is merged without its RECURRENCE-ID and holds no dates or rule, so the
  shift has nothing to move there.

## Attendee answers

- **CalDAV** (`applyAttendeeRule`, `reschedules`): each attendee keeps their line. If the edit
  moves the copy (its start, end, rule or place differs, or that can't be read), everyone but the
  organizer gets `PARTSTAT=NEEDS-ACTION;RSVP=TRUE`, keeping their other parameters. An added
  attendee is asked.
- **Google:** each attendee keeps their entry. If the edit moves the new part (its start, end,
  all-day form, rule or place differs, or that can't be told), everyone but the organizer goes back
  to `needsAction`. An added attendee is asked; one left out is removed.
- **Outlook:** the new part's attendees start unanswered. Graph lets only the attendee write a
  response, and Outlook's own split does the same.

**Amendment (2026-11-10, #604): which copies ask again, compared with the Thunderbird add-on and
the servers.** The CalDAV bullet above is unchanged and holds for both copies. The doc comment on
`CalDAVEventCopies.swift` called it "one rule shared with the Thunderbird add-on" until this
amendment; that was true of the split only.

- The add-on asks attendees again only on a split's new part and the changed occurrences carried
  into it (`tmCalendar.sys.mjs`), a new event that no server's reset reaches. Its one-occurrence
  edit leaves the stored answers as they were.
- iOS also asks again when a one-occurrence edit moves the occurrence. A scheduling CalDAV server
  does the same to the stored answers itself: RFC 6638 §3.2.8 has it reset every attendee but the
  organizer to `NEEDS-ACTION` on a change of start, end, duration or rule that moves an occurrence.
  On a server that does not schedule, nothing else resets them, and the attendees then show as not
  yet answered for the new time.
- A change of place (`LOCATION`) asks again too. That is the CalDAV-side behaviour mirrored here:
  RFC 6638 lets the organizer's client reset the answers on a change of place, and the add-on's
  split counts a place change as a reschedule. Google's behaviour for a change of place has not
  been checked. For a change of date or time, user reports (not Google's documentation) say Google
  asks guests again.
- #604 (an occurrence edit that reset every answer and dropped the occurrence's alerts and status)
  described the override builder before #610; the copy above already fixed it.
  `changedOccurrenceKeepsItsOwnProperties` pins it.

**Amendment (2026-11-10, #603): the reader sees a VEVENT through `topLevel`, as the writer does.**
The copies above already kept an alarm inside its VALARM. The leak that remained was on the read
side: `ICSParser` took every line between `BEGIN:VEVENT` and `END:VEVENT`, last value winning, and
RFC 5545 puts alarms last. So a DISPLAY alert's text was read as the event's notes, an EMAIL
alert's subject and recipient as its title and an attendee, and a repeating alert's `DURATION` as
its length. Those values then went back to the server through edits (an attendee added wrote the
alert's recipient as an attendee; notes "added to" overwrote the event's own with the alert text).

- `ICSParser.components` reads each VEVENT through `CalDAVProvider.icsUnits`, `veventBlocks` and
  `topLevel`: one depth rule shared by reader and writer, for masters and overrides alike. Every
  caller reads the same way: `getEvent`, the split's read-back in `splitSeries`, the occurrence
  listing and lookups (`CalDAVOccurrences`), and the demo import
  (`ICSCalendarImporter.importIntoDemoCalendar`). The demo import used to take a DISPLAY alarm's
  text as the event's notes, and ADR-IOS-052's sanitizer gives every DISPLAY alarm a
  `DESCRIPTION`, so every imported event with an alert showed its text as notes.
- `masterVEventLines` (a whole-block reader) is gone; `extractUID`, `extractRRule`,
  `masterDTStartDay`, `icsIsAllDay`, `masterDTStartKind` and `masterStartWallTime` read
  `masterTopLevelLines`, and so does `recurrenceIdKind`'s check for a series VEVENT. Its fallback
  for a resource that holds only changed occurrences still scans the whole resource with
  `icsLines` for the first `RECURRENCE-ID` (no nested component carries one). An alarm's own `UID`
  (RFC 9074) placed before the event's no longer answers `successorIsOurs`.
- `CalDAVProvider.isMarker` (and `ICSUnit.isMarker`) is the one rule for matching `BEGIN:VEVENT`,
  `END:VEVENT` and `END:VCALENDAR` in the CalDAV path: trailing whitespace ignored, leading not (on
  a physical line it makes a folded continuation). The shared helpers, `replaceRRule`,
  `spliceOrReplaceOverride` and `shiftSeriesAnchoredValues` all use it. Before, a padded line hid
  the VEVENT from those three: a new rule or a moved start was not written, and
  `spliceOrReplaceOverride` lost a new one-occurrence change, wrote a second override for a changed
  one, or (padded `END:VEVENT` on the series) replaced the whole resource with the override.
- Not moved, each with its own rule outside the CalDAV path: `ICSBuilder.parseIncoming` and
  `ICSSanitizer` (Shared, trimmed and case-insensitive already), and the diagnostic VEVENT count
  in `ICSCalendarImporter`'s debug log line.
- Tests: `CalDAVAlarmIsNotTheEventTests`; the padded-line pins in `CalDAVMergePatchTests`
  (`PaddedSeries`: rule, moved start, one-occurrence change, split, and a continuation that reads
  `END:VEVENT`); `ICSParserTests.lowercaseAlarmIsNotTheEvents`; `TESTS.md`, "Repeating events —
  copies keep the series' properties".

**Amendment (2026-11-11, #711, ADR-IOS-109): the organizer moved from the override copy to the
PUT.** `occurrenceOverrideResource` used to give an override with guests and no organizer the
series' organizer, and nothing else wrote one. That rule is deleted. Every CalDAV PUT (create,
whole-event edit, one-occurrence edit, one-occurrence delete, both PUTs of a split) now goes through
`CalDAVProvider.putEvent`, which runs `organized(_:own:)` on the final body: once a VEVENT has its own
ATTENDEE and no ORGANIZER, every VEVENT without an ORGANIZER (a guest-less series too, RFC 6638
§3.1) takes the resource's own organizer (the series', else the first
override's, copied byte for byte), else the address the server advertises in
`calendar-user-address-set` (only for a resource with a series VEVENT), else none. The copies above
are unchanged otherwise. Tests: `CalDAVOrganizerTests`, `CalDAVOrganizerStepTests`; the old pin
`CalDAVOccurrenceOverrideTests.overrideGetsOrganizer` moved to the wire as
`CalDAVOrganizerTests` test 3b.

## Google attendee edits (#564)

The same attendee rule holds for an ordinary Google edit. Google stores the attendee list it is
sent as sent, so an edit that adds or removes someone (`updateEvent`, `updateOccurrence`) writes
each attendee it keeps as the stored event holds them (`keptAttendeesJSON`, via `editJSON`),
matched by address in any letter case, and only a new one by address and name. An occurrence edit
matches against that occurrence's own stored attendees. An edit that names no attendee change
sends no attendee list. Tests: `GoogleAttendeeEditTests`.

**Since #620 (2026-11-11) an edit carries the guest change, never a list.** `add_attendees` /
`remove_attendees` (`"*"` for everyone) become `GCalEventInput.attendeeChange`
(`AttendeeChange(arguments:)`, in `buildGCalEventInput`); the queue no longer reads one item and
works out one full list (`resolveAttendeeDelta` is deleted). Each write applies the change with the
one function `AttendeeChange.apply` to the stored guests of the item it writes, read for that
write: removals first, every other stored guest kept as stored (one with no address too), each new
address appended once and unanswered (a guest removed and added back keeps their stored entry).

**The whole-series rule is the series' DIFFERENCE (Google is the reference; owner decision,
option A of review round 2, 2026-11-11).** A change of a whole series reaches each changed
occurrence as `AttendeeChange.seriesDifference(before:after:address:)`: from the series' list
before and after the change, removes = before - after and adds = after - before (by lowercased
address; an add keeps the change's new entry, a guest with no address is in neither), applied on
top of the occurrence's own guests. Measured on Google AND Outlook, organizer side, 2026-11-11:
series [X] -> [] left an occurrence holding [X, Y] (its own extra Y) as [Y]; series [X, Y] written
back unchanged left an occurrence that had dropped Y on its own as [X]. It differs from applying
the change itself only for `"*"`, for an add of a guest the series already holds (or a remove
and re-add of one), and for a removal of a guest the series does not hold (an occurrence's own
guest stays): "remove everyone" leaves an occurrence the guests it added on its own, "add B" does
not invite B back to an occurrence that dropped B, when the series held B, and "remove C" leaves C
on an occurrence that invited C on its own when the series never held C (as Google does; one
`this_only` removal on that occurrence takes C off).
- **CalDAV** (`mergePatchIntoICS` → `CalDAVProvider.applyAttendeeChange`): the series VEVENT gets
  the change itself; every override VEVENT in the same resource gets the series' difference. A
  one-item write keeps the change itself: a `this_only` override is merged on its own as the
  series VEVENT of a resource of one (`occurrenceOverrideResource`, #596). A split's new part
  (`seriesSplitResources`) is a whole-series write for the changed occurrences it carries, as on
  Google: its series VEVENT gets the change, the carried overrides the new series' difference. A
  resource with no series VEVENT has no series to take a difference from, so each VEVENT gets the
  change itself. A cancelled occurrence (`STATUS:CANCELLED`) is changed like any other, as the
  add-on changes it (the cancelled skip and `isCancelled` were deleted in review round 2), and a
  VEVENT the change leaves as it was goes back byte for byte. A new line is
  `ATTENDEE;CN="…";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE`. No ORGANIZER is written
  there: `putEvent` adds it (ADR-IOS-109).
- **History (superseded 2026-11-11, review round 2, kept for the record):** the CalDAV rule was
  "every VEVENT of the resource the write covers: the series and each changed occurrence, a
  split's new part and the changed occurrences it carries, a one-occurrence override (#596). A
  changed occurrence takes the change on its OWN guests, the Thunderbird add-on's rule: a guest it
  added on its own stays, one it dropped on its own is not invited back." It was wrong for `"*"`
  and for an add of a guest the series held, where Google and Outlook give the difference. (Until
  review on 2026-11-11 a switch named `AttendeeChange.changedOccurrenceGuests` offered a second
  rule, `.seriesGuests`; nothing used it and it was deleted, with `applyToChangedOccurrence`.) A
  `STATUS:CANCELLED` occurrence was left as stored.
- **Google and Outlook:** the change is applied to the event or occurrence the write reads
  (`GoogleCalendarProvider.applied` via `editJSON` and `splitNewPartJSON`;
  `ExchangeCalendarProvider.appliedAttendeesJSON` and the split's `splitNewPartJSON`). A series
  write is the app's only write for a change of every occurrence; the server carries it to the
  occurrences:
  - **Google** (measured 2026-11-11, test account, API PATCH and Google Calendar web "All events"
    alike): the series' resulting difference (stored list vs written list) is applied on top of
    EVERY occurrence's own guests, those with guest differences of their own included, moved and
    renamed ones too: a guest an occurrence added stays, even when the series is emptied; one it
    removed comes back only when the series gains them. Measured for an added and a removed
    guest, a series emptied ([X] -> []) and a series list written back unchanged. This is the
    rule every provider follows, so the app writes no occurrence. `FakeGoogleCalendar` models it.
    (Earlier the same day this read "the series' change is applied ... one it removed stays
    removed unless the change adds them. The same rule as the app's": wrong for `"*"` and for an
    add of a guest the series held, where the change and the difference differ; corrected after
    the second measurement.)
  - **Outlook** (measured 2026-11-11, test account, Graph PATCH of the series, for an added and a
    removed guest, a series emptied and a series list written back unchanged): the same as
    Google, the series' resulting difference: the emptied series left an exception its own extra
    guest, and the unchanged list did not give back a guest an exception had dropped. An
    exception stays an exception. So the app writes no occurrence. `FakeGraphCalendar` models it.
    (The first note, kept: "The series' change is applied on top of EVERY occurrence's own
    guests, exceptions with guest differences of their own included, renamed and moved ones too,
    and an exception stays an exception: an exception that had dropped a series guest on its own
    still lacked them after the series added another guest (it took only the added guest, not the
    series' whole new list)." Earlier the same day only occurrences that held the series' guests
    were measured, and an occurrence with guests of its own was recorded as NOT measured and left
    as stored by the fake; the second measurement closed that.)
- **Demo** (`DemoCalendarProvider.updateEvent`) applies the same function to the stored guests
  (an event left with none stores no list); the edit card (`CalendarEventEditTool`) shows the
  change itself (`AttendeeChange.cardLines`: the people added, as "Name <address>" or the address
  alone, and removed, three of each and "and N more"), never a resulting list. A guest added twice
  (any letter case) is one add (`init(adds:removes:)` dedupes), so the card never repeats a line
  (its rows are keyed by text).
- **Where the add-on differs:** only the whole-series rule. The add-on applies the change itself
  to each exception (`applyGuestChangeToSeries`); the app follows Google, the difference (the
  Thunderbird twin is tabmail-thunderbird#379; the card twin is tabmail-thunderbird#378). A cancelled occurrence and `mailto:*` now match
  the add-on: the cancelled one is changed, and `mailto:*` names nobody (only a trimmed `"*"` is
  "everyone": `AttendeeChange.init` and `parseAttendeeRemoves`). (Until review round 2 the app
  left a cancelled CalDAV occurrence as stored and read `mailto:*` as everyone.)
- A debug-gated line (`BackgroundSyncLogger.logDebug`) where the change is applied
  (`applyAttendeeChange`, `editJSON`, `graphPatchJSON`) gives the items and the guest counts
  before and after, never an address.
Tests: `CalendarGuestChangeTests` (on each fake server after the real queue drains),
`AttendeeChangeTests` (the function), `DemoGuestChangeTests`, the card test in
`CalendarToolResolvedAccountTests`.

## Exceptions after the split (#563, #687)

Google Calendar's rule, measured on a test calendar, now followed on Google, Outlook and CalDAV
(`SplitCarry`, one provider-neutral source the card and every write call):
- A split starts at the PLACE of the occurrence named (`originalStartTime`), not where it was moved
  to; the series is capped before that place, and the moved occurrence is carried like any other
  changed one (#687; the old "split at a moved occurrence" refusal is gone).
- **Reset** (`SplitCarry.Mode.reset`) when the edit gives a start other than the place (another
  instant or day, or the same instant in another time zone: Google's own web "this and following"
  resets for a zone-only change, measured on the Workspace test calendar 2026-11-12; Outlook is
  unmeasured and follows the same rule) or another rule (`ruleDayMove`, or a RRULE other than the stored one): nothing is
  carried, deleted occurrences come back, changed ones lose their change, and the new part's EXDATE
  lines go (RDATE stays). The card shows `CalendarToolHelpers.exceptionsResetNote`.
- **Carry** otherwise: a deleted occurrence stays deleted (Google: an EXDATE in the create; Outlook:
  the new part's occurrence DELETEd, 404/410 = done; CalDAV: EXDATE and overrides kept); EVERY changed
  one is carried WHOLE (amended 2026-11-12, review C1: a fixed field diff lost a guest's own decline,
  a colour, a reminder): everything it holds that the organizer can write, except the fields the
  edit sets (`SplitCarry.Field`, which the new part holds already); its own times, an end given alone
  giving its own start plus the new part's length; its guests (answers included) with the edit's
  change applied as the series' difference. Google: `carriedJSON` = the exception's JSON minus
  `serverOwnedEventKeys`, times, status and guests, PATCHed with `conferenceDataVersion=1` and
  `supportsAttachments=true` as the create is. Outlook: `carriedJSON` = the exception's
  `splitCopiedKeys` but `isAllDay`. CalDAV: the override VEVENT is kept byte for byte (`carryPatch`
  only overwrites the set fields and, for an end given alone, DTEND).
- **Not carried (the provider gives the organizer no way to write it):** Google: the keys the server
  owns (`creator`, `organizer` outside an import, `hangoutLink`, `locked`, attendees' `self`/`id`/
  `organizer`); an attendee's `responseStatus` IS written (Google documents it writable), how it
  reaches the attendee's own copy is unmeasured. Outlook: attendees' answers (`status` is read-only
  to an update: the new part's occurrence starts unanswered), the exception's own online meeting
  (`onlineMeeting`/`isOnlineMeeting`: the new part has its own), its attachments (a separate
  endpoint, not copied, as the split's own copy does not), and extensions/extended properties.
- **Outlook reads every page** of the new part's `/instances` (`@odata.nextLink`, refused if it
  leaves Graph, review C2). A deleted place not listed is done; a CHANGED one not listed is refused
  before the cap. `exceptionOccurrences` is read with a plain `$expand` and no `$select`: measured,
  not documented (Graph documents it with both).
- The mode and set fields are on `SplitRecord` (`mode`, `fields`), so a retry (`finishSplit`) carries
  as the first attempt did, before the cap. A carry write that fails for good stops before the cap
  (owner ruling); the residual case is iOS #769.
- Outlook writes the DELETEs first, then the moves in `carryOrder`, so none lands on a date another
  occurrence still holds (`ErrorOccurrenceCrossingBoundary`).
- Carry writes send the providers' usual update emails to attendees (owner ruling: accepted).
- A numbered series keeps its remaining COUNT on the new part (Google's own 8 -> 11 is not copied).

**Split at a moved occurrence (amended 2026-11-12, owner ruling, supersedes "starts at the PLACE"
above):** the split cuts where the named occurrence is now shown (`SplitCarry.cut`: its current start,
or the next rule date on or after it; COUNT/UNTIL/RDATE honoured; an all-day one on the same date
counts as after). `SplitCarry.partition` sorts every exception by where it is shown: at or after the
cut goes to the new part (`tail`), before it stays on the capped series untouched (`kept`, written
whole at its own times when the cap would drop its place), and the named one is `edited`.
(a) an occurrence at exactly the cut changes; (b) a typed start shifts the later ones by the same
amount (`partEdit`: t -> cut + (t - namedStart)); (c) a reset leaves those shown before untouched;
(d) deletions between its old place and the cut stay deleted, even on a reset; (e) moved past the
series' last occurrence (`Cut.pastEnd`): no new part, only it is edited (`editShown`), a rule change
refused; (f) all-day same date = after. The shift and per-occurrence edits are on `SplitRecord`
(`named_place`, `named_start`, `edits`), so a retry does not shift twice. Rows queued before this
parse without them and are read as named at the cut. Tests: `SplitCarryTests` cut/partition,
`movedSplit*` in `CalendarEditToolSeriesScopeTests` and `ExchangeSplitCarryTests`,
`SplitCarryTests.calDAVMovedSplit*`/`calDAVPastEnd`.

**One split point per calendar (amended 2026-11-12, review of #687):** the card's repeat line
(`dayMovedRules`) and the write (`splitSeries`) both call the calendar's own `splitPoint`, so the cut
the card shows is the cut written (CalDAV with the resource's `RDATE` lines; Outlook from the range
start, a missing month day on the month's last). A date or local `UNTIL` is read in the series' zone
(`SplitCarry.endsBefore`). A floating CalDAV series is read in the operation's zone
(`CalendarTimeZoneContext.readingFloating(in:)`, `ICSParser.components(floatingZone:)`,
`CalDAVOccurrences.occurrence(floatingZone:)`), by the split and by its retry (`finishSplit`) alike. Outlook writes the edits of occurrences where they
are in Graph's move order (`editOrder`, the same `moveOrder` as `carryOrder`). Past the end (e),
Google and Outlook keep `SplitRecord.pastEnd` (`split_at` "", `new_part_id` the named occurrence,
absolute `edits`, `edit_length`) before the first write; the queue finishes such a record with
`finishShownEdit` without looking for the named occurrence again. Unmeasured: whether Graph keeps an
exception moved past the capped range's new `endDate` (measure: split a weekly series at a moved
occurrence whose earlier-placed neighbour is shown after the cut, then GET the capped series'
`/instances` and `exceptionOccurrences`). Tests: `SplitCarryTests` (RDATE, UNTIL, floating,
`shownEdits*`, reset keeps deleted), `ExchangeSplitCarryTests` (`pastEndRetryMovesOnce`,
`shownEditsAreOrderedOffHeldDays`, `movedSplitRetryMovesEditedOnce`, `movedSplitKeptItemKeepsItsGuests`).

**The card asks the write's cut (amended 2026-11-12, review rounds 3-4):** the card of a split named
at a moved occurrence asks `CalendarProvider.splitCut` (each calendar's `splitPoint`, nothing written).
Past the end it shows no reset note and refuses a rule or day change before the card
(`SplitCarry.pastEndRuleRefusal`). `splitSeries` returns `GCalEvent?`: nil when no new part is made,
and the queue's past-end retry answers nil, so the tool prints no `new_series_event_id`. Outlook:
`moveOrder` neither dates nor orders a stay (no target, or a target at the instant it is at); moves are
dated in `GCalEvent.seriesZone` (range zone, else the start's); a past-end edit is ordered before its
record; the carry's listing window is dated in UTC; a timed series with no readable zone is refused
before the POST only when `movesAnOccurrence` (a time-setting edit, or a changed occurrence away from
its place), so a rename still works. A zone-less timed series is still refused, with nothing written, when it has a deleted occurrence (Graph's `cancelledOccurrences` names it by date only, so placing it needs the zone) or when the occurrence named was moved (its cut is placed in the zone). Zone fallback REJECTED (2026-11-12): Outlook's `start.timeZone` is only the zone a read asked for (`request` sends `Prefer: outlook.timezone`, the device's by default), so it never stands in for the series' zone (`GCalEvent.startZoneIsDisplay`, set by `toGCalEvent`; `seriesZone` is then the range zone or nil). A fallback to Graph's `originalStartTimeZone` was tried and removed: whether Graph dates `cancelledOccurrences` in the requested zone is unmeasured, and the creation zone can differ from the range zone (a series moved to another zone keeps its creation zone), so a deleted date could be placed a day off, a silent wrong delete, worse than a refusal. A timed series whose range zone is custom is refused with nothing written; an all-day one is read in its stored range name as it always was. Tests: `customRangeZoneIsRefused`, `SplitCarryTests.displayZoneNeverStandsIn`. Accepted limits (owner, 2026-11-12), all on an Outlook series whose range zone is missing or custom, none writing anything wrong; the narrower fix is tabmail-ios #806 (P4): (1) a "this and following" edit is refused when any occurrence of the series was deleted, when a changed occurrence was moved, or when the edit changes the time and any occurrence was changed or deleted (`deletedPlace`, `movesAnOccurrence`); a split that changes no time over only renamed occurrences goes through; (2) a whole-series time change with no occurrence named is refused, and the message names the time zone (`CalendarSeriesScope.unreadableSeriesZone`), not a date; (3) a whole-series move named from a later occurrence becomes a split there, so earlier occurrences keep the old time; (4) a "this and following" zone change keeps the later one-off changes, where Google resets them: every timed edit names a zone (`buildGCalEventInput`), so without the series' own zone a real zone change can't be told from a restated one, and resetting on every restated start would drop one-off changes the user never touched. Tests: `noRangeZoneIsNotReadInTheDisplayZone` (deleted and moved), `unreadableZoneTimeChangeNamesTheZone`, `unknownZoneTakesTheRefusingSide`. `MockCalendarProvider.splitCut` cuts at
`recurrenceId` unless set. Tests: card and answer past the end on Google, Outlook and CalDAV;
`movedSplitCardShowsTheWrittenRule`; Google `pastEndKeepsItsRecordFirstAndRetryNotifies`; queue
`pastEndRetryWritesOnlyItsEdits`; `ExchangeSplitCarryTests` `zoneless*`, `splitEditsAreOrderedOffHeldDays`;
`SplitCarryTests` `moveOrderNeedsNoZoneForStays`, `malformedEditLengthIsNotRead`.

Tests: `SplitCarryTests`, `ExchangeSplitCarryTests` (whole copy, every page, failure before the cap
and `finishSplit`, `carryOrder` against the fake's opt-in same-day refusal, deletes before moves,
guests, end only), `CalendarEditToolSeriesScopeTests.renameSplitCarriesLaterExceptions` /
`followingAtAMovedLaterOccurrenceCarriesIt` / `carryKeepsGuestAnswerAndColour` /
`carryFailureStopsBeforeTheCapAndTheRetryCarries` / `zoneOnlySplitResets` / `outlookResetNoteFollowsTheMode`, the Google/Outlook invariant matrices (moved states now
split at the place), `CalDAVOccurrenceWireTests.splitIsAtThePlaceInEveryFrame`.

## Tests

`CalDAVEventCopiesTests`, `CalDAVSplitRefusedBeforeWriteTests` and `CalDAVSplitRollbackTests`
(in `CalDAVSplitHelpersTests`, against `FakeCalDAVStore`; the write order, the partition of
changed occurrences and dates, and the retry after a lost cap response), `SeriesSplitCopyTests` (Google and Outlook, against
`FakeGraphCalendar`; the Outlook create body is checked as sent).
`ExchangeNumberedSplitTests` (#474, in `SeriesSplitCopyTests.swift`): an Outlook numbered series'
two parts hold exactly the series' occurrences (`FakeGraphCalendar.rangeDays`, the fake's own
range expansion), with deleted and moved occurrences before the split, a range starting before its
first occurrence, every-other-week series with either first day of the week, and an all-day series
ahead of UTC, and the two measured month-end shapes split after a short month (`monthEndSeries`);
nothing left, or an unrecognized range zone, writes nothing. `RecurrenceTailNewSeriesEndTests` pins
the two anchors; `RecurrenceTailMissingMonthDayTests` pins the measured month end against RFC 5545's
skip.
`CalDAVOccurrenceOverrideTests.changedOccurrenceKeepsItsOwnProperties` (#604): an occurrence
changed on its own keeps its status, alert, categories, link, revision, `X-` line and attendees
through a rename, an attendee added and a move.
See `TESTS.md`, "Repeating events — copies keep the series' properties".
