## ADR-IOS-108: CalDAV Listings Show Each Occurrence, With an Id of Its Own

**Status:** Active (2026-11-10). Replaces the one-row-per-resource CalDAV listing (`ICSParser.parse`
on each `calendar-query` response), which showed a repeating event once, at its first date.

**Context:** Google (`singleEvents=true`) and Outlook (`calendarView`) list a repeating event as one
row per occurrence in the range, each with its own instance id. A CalDAV `calendar-query` returns the
whole `.ics` resource of any series with an occurrence in the range, and the listing read only its
first VEVENT. So the assistant's calendar tools showed a weekly meeting once, at a date long past,
or not at all on the day asked about, and skipped every changed occurrence. The one id such a row
carried was the resource's: a delete asked for one day of the series would have been a WebDAV DELETE
of the resource, which holds every occurrence (irreversible wire operation #5, no trash).

**Decision:**
1. **One route, on the device.** `CalDAVOccurrences.listing` works out the occurrences that overlap
   the range (RFC 4791 §9.9) from the resource itself; `CalDAVProvider.listEvents` lists those rows.
   - Rule steps come from `RecurrenceTail.Rule`, the expansion the split code already uses.
   - Times stay at the series' wall time in its own zone (`TZID`) across a change of UTC offset; a
     wall time the change skips takes the offset before it, a repeated one the first (RFC 5545
     §3.3.5). Floating times read in the device zone. All-day occurrences are plain dates, no zone.
   - `COUNT` counts the rule's instances before `EXDATE` removes any (RFC 5545 §3.8.5.1). `UNTIL` as
     a date includes that day; as a date-time it is the exact instant. `DTSTART` is always the first.
   - `RDATE` adds dates (DATE, DATE-TIME, PERIOD with its own length). `EXDATE` removes them; an
     `EXDATE` given as a date in a timed series removes that day's occurrence.
   - A changed occurrence (an override VEVENT with `RECURRENCE-ID`) is listed where it now is, in or
     out of the range it came from; the slot it left is not listed. A cancelled one
     (`STATUS:CANCELLED`) is a cancelled row, which `listEvents` drops.
   - The rule may take at most `Config.maxRuleSteps` steps per listing.
2. **A series the device can't work out is one row that says so.** For `EXRULE`, more than one
   `RRULE`, a `RANGE=THISANDFUTURE` override, an unreadable `DTSTART`, `COUNT` or `UNTIL`, `COUNT`
   with `UNTIL`, a rule shape `RecurrenceTail.Rule` does not expand (no common app writes these), a
   listing with no end, or a rule that reaches the step cap: one row for the series at its first date
   with `GCalEvent.occurrencesNotListed = true`. The tools show it as
   `(↻ <RRULE>; repeating event, its occurrences are not listed: …)`
   (`CalendarToolHelpers.occurrencesNotListedNote`), never as an occurrence on that date.
3. **An occurrence's id is its series' resource plus an instance suffix**, as Google's instance ids
   are: `<resource href>#<key>` (`CalDAVOccurrences.OccurrenceId`), key `yyyyMMdd` (all-day),
   `yyyyMMddTHHmmss` (floating) or `yyyyMMddTHHmmssZ` (UTC and zoned); `recurringEventId` is the
   resource href. `#` cannot occur in a resource href the server lists, and a URL would drop it as a
   fragment and address the whole series, so `resolveEventURL` refuses any id that carries it.
   - Read: `getEvent` by an occurrence id returns that occurrence as the listing shows it (`notFound`
     when the series no longer has it); by the series id, the series.
   - Edit, whole event: `updateEvent` is the edit of the whole event: edit_scope `all`, which is also
     the scope an edit given neither edit_scope nor recurrence_id gets. **An occurrence id has no
     series semantics on CalDAV:** every such edit given an occurrence id is REFUSED by the provider
     before it sends any request, whatever it sets, and nothing is written. The user confirmed a card
     showing ONE occurrence, and on CalDAV the whole event is the series, every occurrence; written
     there, even a title misses the one occurrence named when it has an override of its own, and a
     start, an end or guests taken from the occurrence would move or re-invite the whole series. The
     refusal tells the assistant to edit the occurrence with edit_scope this_only and recurrence_id set
     to the start_iso listed for it, and that a whole-series change from an occurrence is not
     supported yet, so it asks the user to make it in their calendar app. The series id edits the
     series exactly as before this ADR. "Before any request" holds at the provider: through the tool
     the card reads the event first (`getEvent`), and the queue may read it again for an attendee
     delta or a move's all-day kind (`resolveAttendeeDelta`, the all-day resolution), so through the
     tool nothing is WRITTEN. A whole-series change from an occurrence returns with the series
     time-shift work, which reads a new time relative to the occurrence named.
     **Amendment (2026-11-11, #620):** the queue no longer reads the event for an attendee delta:
     `resolveAttendeeDelta` is deleted, and an edit carries the guest change itself
     (`GCalEventInput.attendeeChange`), which the provider's write applies to the guests of each
     item it covers. The queue's other read (`CalendarSeriesScope.read`) is unchanged, and so is
     "through the tool nothing is WRITTEN".
     **Amendment (2026-11-11, #620 review round 2):** "applies to the guests of each item it
     covers" is refined: the written item takes the change itself, and a whole-series write gives
     each changed occurrence the series' resulting difference (`AttendeeChange.seriesDifference`),
     Google's and Outlook's measured rule, Google the reference (memory 142).
   - Edit, one occurrence or a split: `updateOccurrence` (this_only) and `splitSeries`
     (this_and_following) address the resource and make ONE check before they write anything,
     `CalDAVOccurrences.scopedEditSlot`. It picks the occurrence `recurrence_id` names with the
     matching Google and Outlook use, `RecurrenceOccurrenceResolver.select`, over the occurrences the
     resource has now within `Config.resolverWindow` of that time, each where the listing shows it (a
     changed one at its own time, a cancelled one not at all): a timed `recurrence_id` names the
     occurrence that starts at that instant, a date alone the one occurrence on that day, and more
     than one is refused as ambiguous. No occurrence there is `CalDAVError.notFound`, the
     authoritative absence Google and Outlook report, which the queue retires as not found (a removed
     or cancelled occurrence, a time between occurrences, one after the series' end, or a moved
     occurrence's old place). With an occurrence id, `recurrence_id` must name the occurrence its key
     names; another is refused. The write uses the named occurrence's place in the series (its key),
     so an override is changed in place, never duplicated, and a split starts where the series puts
     the occurrence; the series id and an occurrence id name a split's new part alike. A split at a
     MOVED occurrence (`CalDAVOccurrences.isMoved`: its start differs from the slot its own key
     names, compared in the series' own frame, a floating time as a wall time in the device's zone,
     an all-day one as a date, a UTC or zoned one as an instant, whatever zone the tool names it
     in) is REFUSED by
     name, by either id, after the GET and before any write: it would start at the occurrence's
     place and also change the occurrences between that place and where it was moved to, a wider
     write than the card shows. The refusal tells the assistant what works: `this_only` on that
     occurrence, or the split in the user's calendar app. The refusal follows the card, since only
     the resource says the occurrence was moved. An event that does not repeat and a series marked not listed are refused. The
     check runs after the GET and before any PUT, including the split's create and its cap
     (irreversible wire operation #6). For a split it reads the rule without its `COUNT`/`UNTIL`: where
     the series ends stays `RecurrenceTail.newSeriesRule`'s check, which also knows a series this same
     split already capped (a retry).
   - A resource that holds only changed occurrences, with no series VEVENT (an invitation to single
     occurrences of another organizer's series, RFC 4791 §4.1), is listed one row per override, keyed
     by its own `RECURRENCE-ID` (`standaloneKey`), and read back by that id. `this_only` by such an
     occurrence's id changes that override in place, through the same check over the resource's own
     overrides: `occurrenceOverrideResource` reuses its existing-override branch and reads the
     `RECURRENCE-ID` frame from the overrides themselves (`CalDAVProvider.recurrenceIdKind`; RFC 5545
     §3.8.4.4 writes every `RECURRENCE-ID` of one event in the same value type and zone), adds no
     VEVENT, and adds no organizer, having no series to copy one from. The resource's own id, which
     names no series, and every split are refused.
     **Amendment (2026-11-11, ADR-IOS-109, #711):** "adds no organizer" becomes "adds only an
     organizer the resource already names". Every CalDAV PUT now runs one organizer step
     (`CalDAVProvider.putEvent`): a changed occurrence with guests and no organizer takes one that
     another VEVENT of the resource names. Such a resource never gets the account's own address,
     which would forge the meeting's identity (ADR-IOS-052).
     **Amended 2026-11-11 (#720).** The series is not in this calendar, and that is the final rule,
     refused in one reason (`CalDAVOccurrences.seriesNotInThisCalendar`; since #694 the neutral
     `CalendarProviderError.seriesNotInThisCalendar`, whose edit wording is
     `CalendarProviderError.seriesNotInThisCalendarReason`, the same text; which names `this_only` by the
     listed id and its `start_iso` as what can be changed): `getEvent` of the resource's own id throws
     it as `notSupported` (was `CalDAVError.parseError("No VEVENT found")`, which the calendar queue
     requeued forever, holding the account's later operations); `scopedEdit`'s own-id and split
     refusal throws the same reason. Since `CalendarSeriesScope.read` reads the series for an edit of
     every occurrence and a split (memory 146), "all" (or no scope and no `recurrence_id`) and
     `this_and_following` named by such an occurrence's id are refused BEFORE the card, nothing
     queued; one that reaches the drain (the resource rewritten after the card) is retired in that
     drain. `this_only` reads no series and is written, before #560's read and after it alike. A
     resource with no VEVENT at all stays a `parseError`.
   - Delete: `deleteEvent` by an occurrence id is REFUSED before any request ("Deleting one
     occurrence of a repeating CalDAV event is not supported yet, so nothing was deleted. The user can
     delete it in their calendar app."). The queue retires it as unsupported and the card and the
     tool say the event was not deleted. Deleting by the series id is unchanged.
     **Amended 2026-11-11 (#661): superseded.** `deleteEvent` by an occurrence id now deletes that
     occurrence alone, as Google Calendar does, and still never sends a DELETE. It GETs the series'
     resource, finds the occurrence by its key as the listing shows it, from one parse of the
     resource (`CalDAVOccurrences.deletion`; an event that does not repeat or a series TabMail can't
     expand is refused as `scopedEditSlot` refuses it, never reported not found), and writes ONE PUT conditional on the GET's ETag (a 412 is thrown as
     `preconditionFailed`, as every conditional CalDAV write throws it): an `EXDATE` added to the
     series VEVENT at the occurrence's place in the series, in the series DTSTART's value type and
     zone (`VALUE=DATE` all-day, `TZID` wall time, UTC `Z`, floating), and the occurrence's changed
     copy removed, matched by occurrence key in that one parse and removed by its position among
     the VEVENTs, framed as the reader frames them (#603), never by RECURRENCE-ID text
     (`CalDAVProvider.occurrenceDeletedResource`). A moved occurrence is excluded at its
     original slot. A missing, excluded or cancelled occurrence is `CalDAVError.notFound` with
     nothing written (so a retry after a lost response is retired as not found, as on Google and
     Outlook); a resource that holds only changed occurrences is refused with nothing written; and
     the built resource must keep the series and every other changed occurrence and no longer have
     the occurrence (`CalDAVOccurrences.requireDeletedAlone`), or nothing is written. The PUT is an
     irreversible wire operation (memory 102). Tests: `CalDAVOccurrenceDeleteWireTests` (every
     series frame; a moved occurrence with another changed one kept, in every frame and with its
     RECURRENCE-ID in the series' form, another form or another zone; missing/cancelled/repeated;
     changed-only; a series changed into one TabMail can't expand or that no longer repeats,
     refused, not not-found; the check before the PUT refusing an EXDATE that would exclude
     nothing, and a rebuilt resource that lost the series or another changed occurrence; a padded
     `END:VEVENT` keeping the next changed occurrence; a series VEVENT after a changed copy; two
     changed copies of one occurrence, the first deciding it and both removed; a series zone
     TabMail does not recognize refused in the delete's own words (`CalDAVProvider.ZoneRefusal`);
     412; a server without ETags), `CalDAVTimeZoneWireTests` (the delete in a zone recognized only
     through its VTIMEZONE, excluded under the series' own TZID; the delete's check naming an
     unrecognized zone before it looks the occurrence up; and the edits' refusal of such a zone,
     word for word, never in the delete's words, also for a changed occurrence held without its
     series), `CalDAVOccurrenceDeleteToolToWireTests` (end to end from the tools).
   - No series id is added to the tools' output. `calendar_event_read` shows `event_id` only, on every
     provider, exactly as before this ADR (a `series_event_id` line was tried and pulled back: on
     Google and Outlook it handed the assistant a series id it would edit with an occurrence's date,
     moving the whole series). What still names a CalDAV series itself: the row of a series marked
     not listed, and a split's `new_series_event_id`.

**Consequences:**
- A day asked about lists that day's occurrence with its own id, as on Google and Outlook; changed
  occurrences show where they now are.
- One occurrence of a CalDAV series can't be deleted yet; that is an `EXDATE` written into the series
  (a later change). The whole series still can be, by its own id. **Amended 2026-11-11 (#661):** that
  later change is made; one occurrence is deleted by an `EXDATE` written into the series (Decision 3,
  Delete).
- Edit scope `all`, or no scope and no `recurrence_id`, given an occurrence id is refused on CalDAV
  with nothing written, whatever it sets. The Google and Outlook paths, which edit only the instance
  there, are left as they are.
- For a series the listing expands, no tool output carries the series' own id, so a change of the
  whole series, and a delete of the whole series, can't be asked for from one of its occurrences; the
  refusals say the user can make them in their calendar app.
- A one-occurrence edit or a split of a series the device can't expand is refused where the code
  before this ADR wrote an override or a split at the given time unchecked. A resource that holds only
  overrides takes a one-occurrence edit by the occurrence's id, where the code before this ADR could
  not list it at all, and refuses a split. **Amended 2026-11-11 (#720):** and refuses a split or an
  edit of every occurrence before the card, as its series not being in this calendar.
- "This and following" at a moved occurrence is refused with nothing written; that occurrence can
  still be changed alone, and the split made in the user's calendar app.
  **Amended 2026-11-12 (#563, #687):** no longer refused. The split is made at the occurrence's place
  in the series (`CalDAVOccurrences.scopedEdit` gives the slot), and the moved occurrence is carried
  onto the new part with its own times, as Google Calendar does (memory 142, "Exceptions after the split").
  **Amended again 2026-11-12 (#687, owner ruling):** the split is made where the occurrence is NOW
  shown, not at its place: the cut is its current start (the next rule date on or after it, a
  same-date all-day counts), and the split changes it and every occurrence shown at or after it,
  leaving those shown before it untouched, on Google, Outlook and CalDAV alike (`SplitCarry.cut`,
  `SplitCarry.partition`). A start given in the edit moves the later ones by the same amount; a reset
  leaves those shown before it alone, and deletions between its old and new place stay deleted. Moved
  past the series' last occurrence, no new part is made: only it is edited, and a rule change there is
  refused. Memory 142, "Split at a moved occurrence".
  **Amended again 2026-11-12 (review of #687):** each calendar works the cut out in ONE provider
  function (`splitPoint`), which both its `splitSeries` and its `dayMovedRules` (the card's repeat
  line) call, so the card can never cut where the write does not (CalDAV reads the resource's
  `RDATE` lines there; Outlook places a pattern from its range start and a missing month day on the
  month's last). A floating CalDAV series is read in the zone the operation was queued with
  (`CalendarTimeZoneContext.readingFloating(in:)`), never the device's at the drain, by the split
  and by its retry (`finishSplit`) alike. Past the end,
  Google and Outlook keep a record (`SplitRecord.pastEnd`) with absolute targets before the first
  write, and a retry finishes from it (`finishShownEdit`), so no occurrence moves twice.
  **Amended 2026-11-12 (review rounds 3-4):** the confirmation card asks the calendar where the write
  cuts (`CalendarProvider.splitCut`, the same `splitPoint`) whenever the occurrence named was moved:
  past the end it shows no reset note and refuses a change of the repeat or its days before the card,
  in the write's words (`SplitCarry.pastEndRuleRefusal`). `splitSeries` returns the new part or nil
  when none is made, so such an edit, and its retry, answer with no new series id. Outlook dates only
  the occurrences that actually move (`moveOrder`; a stay, at the instant it is at, is not dated) in
  the series' zone (`GCalEvent.seriesZone`), dates the carry's listing window in UTC, and refuses a
  timed series with no zone it can read only when the split moves an occurrence
  (`movesAnOccurrence`), before the new part is created; a rename needs no zone. A deleted occurrence (Graph names it by date only) or a moved named occurrence still needs it, and is refused before anything is written. The series' zone is the range's when recognized, else the zone the event was created in (Graph's `originalStartTimeZone`, `GCalEvent.ownZoneName`), and the series is read in that zone's name (`readZoneName`); never the zone a read was given in, which is only a display zone. A series whose range and creation zones are both unrecognized (a desktop Outlook custom zone) is refused before anything is written.
- The series id with a moved occurrence's new time edits that occurrence in place, and with its old
  place is not found, the same as on Google, whose resolver finds no instance there.
- A retry after a lost response is reported not found, with nothing written, when the first attempt
  moved the occurrence it named (a `this_only` that changed its start, as on Google), or capped the
  series at a moved occurrence, or at one that exists only through `RDATE` (the cap took that date
  into the new part, so the capped series no longer has it). The calendar is then as the user asked,
  but the report says the edit failed.
- Nothing new is stored: the occurrences are worked out per listing from the resource the server
  returns (ADR-004 untouched). `maxResults` trims after the expansion.

**Alternative rejected:** asking the server to expand (RFC 4791 `CALDAV:expand`). Support and output
differ between servers, the expanded instances carry neither the rule nor a link to their series, and
keeping the device expansion for servers that don't expand would be a second route, a fallback.

**Detail:** `CalDAVOccurrences.swift`; tests `CalDAVOccurrenceExpansionTests`,
`CalDAVOccurrenceNotListedTests`, `CalDAVOccurrenceLookupTests` (with a resource that holds only
overrides), `CalDAVOccurrenceWireTests` (a delete by an occurrence id sends no DELETE and leaves every other
occurrence of the series in place, #661; an `all`
edit by an occurrence id, a moved occurrence's included, refused with no request whatever it sets; a
moved occurrence listed with its own id and edited in place, and a split at it refused by either id
with nothing written, exactly at moved occurrences in every series frame named from the device's zone
or another; a
`recurrence_id` that names no occurrence, one after a `COUNT` series' end or a cancelled one, not
found with nothing written; another occurrence than the id's refused; a resource that holds only
overrides edited in place by the occurrence's id, its own id, splits and a read of its own id refused
as its series not being in this calendar, #720),
`CalDAVOccurrenceEditToolToWireTests` (the invariant over every scope and both id kinds, from
`calendar_event_edit` to the wire: the write matches the card, or the edit is refused with nothing sent
after the user confirmed, on an unmoved occurrence and on one moved past later ones; on a resource
that holds only changed occurrences, every RECURRENCE-ID form × every scope: `this_only` written,
the rest refused before the card with the resource byte for byte, #720; and a move whose
response is lost retired as not found on its retry, nothing written again, the queue left empty),
`CalDAVOccurrenceDeleteToolToWireTests` (the same from `calendar_read` /
`calendar_search` through `calendar_event_delete`) and `CalDAVOccurrenceToolOutputTests`. `ICSParserTests.skipsRecurrenceExceptions` and
`ICSParserTests.multipleVEventsReturnsFirst` now pin only the series view; the listing contract they
stood in for is pinned by `movedOverridesAreListedWhereTheyNowAre`,
`cancelledOccurrenceIsMarkedCancelled` and `weeklyZonedSeriesKeepsItsWallTimeAcrossDST`. Closes #613.
