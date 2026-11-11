# A copy of a repeating series keeps the series' properties

**Keywords:** `splitSeries`, this-and-following, new part, capped series, occurrence override,
`seriesSplitResources`, `occurrenceOverrideResource`, `CalDAVEventCopies`, `splitNewPartJSON`,
`serverOwnedEventKeys`, `splitCopiedKeys`, `splitSelect`, `splitReschedules`, `applyAttendeeRule`, `insertEventJSON`,
`conferenceDataVersion`, `supportsAttachments`, `splitRecurrence`, `keptAttendeesJSON`, `editJSON`, `filterDateList`, `RecurrenceTail`,
EXDATE, RDATE, COUNT, recurrenceTimeZone, attendee answers, `needsAction`, write order,
create first cap last, lost cap response, retry, own cap, `successorIsOurs`, `capEndDate`,
RFC 6638 §3.2.8, PARTSTAT reset, `this_only` move asks again, Thunderbird add-on split only,
LOCATION, `changedOccurrenceKeepsItsOwnProperties`, #604.

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
    its own date; a numbered range becomes `noEnd`, and `endDate` is kept only for an `endDate`
    range.
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
  repeats with no end where the series had an end date; editing its end repairs it.
- **Google writes a rule from the edit as given:** a rule in the patch replaces the whole
  `recurrence` array, so the excluded and added dates after the split are not carried. CalDAV
  replaces only the RRULE line and keeps them.

## Dates and rules

- **Excluded and added dates** (EXDATE, RDATE) before the split stay with the capped series;
  those at or after it go to the new part (`splitRecurrence`, `CalDAVProvider.filterDateList`).
  A date whose zone can't be read refuses the split **before any write**.
- **The new part's end:** on CalDAV and Google it ends where the series did, with the same UNTIL
  or what is left of its COUNT (`RecurrenceTail.newSeriesRule`, computed before any write); the
  copy builders take that rule as given. On Outlook the end lives only in the range, which
  `ExchangeCalendarProvider.splitNewPartJSON` rewrites from the stored one: an `endDate` range
  keeps its end date and a numbered range becomes `noEnd`, because the number left after the split
  is not known there yet. A rule in the edit replaces the stored recurrence instead.
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

## Google attendee edits (#564)

The same attendee rule holds for an ordinary Google edit. Google stores the attendee list it is
sent as sent, so an edit that adds or removes someone (`updateEvent`, `updateOccurrence`) writes
each attendee it keeps as the stored event holds them (`keptAttendeesJSON`, via `editJSON`),
matched by address in any letter case, and only a new one by address and name. An occurrence edit
matches against that occurrence's own stored attendees. An edit that names no attendee change
sends no attendee list. Tests: `GoogleAttendeeEditTests`.

## Tests

`CalDAVEventCopiesTests`, `CalDAVSplitRefusedBeforeWriteTests` and `CalDAVSplitRollbackTests`
(in `CalDAVSplitHelpersTests`, against `FakeCalDAVStore`; the write order, the partition of
changed occurrences and dates, and the retry after a lost cap response), `SeriesSplitCopyTests` (Google and Outlook, against
`FakeGraphCalendar`; the Outlook create body is checked as sent).
`CalDAVOccurrenceOverrideTests.changedOccurrenceKeepsItsOwnProperties` (#604): an occurrence
changed on its own keeps its status, alert, categories, link, revision, `X-` line and attendees
through a rename, an attendee added and a move.
See `TESTS.md`, "Repeating events — copies keep the series' properties".
