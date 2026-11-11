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
     the occurrence, never where it was moved to; the series id and an occurrence id name a split's
     new part alike. An event that does not repeat and a series marked not listed are refused. The
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
   - Delete: `deleteEvent` by an occurrence id is REFUSED before any request ("Deleting one
     occurrence of a repeating CalDAV event is not supported yet, so nothing was deleted. The user can
     delete it in their calendar app."). The queue retires it as unsupported and the card and the
     tool say the event was not deleted. Deleting by the series id is unchanged.
   - No series id is added to the tools' output. `calendar_event_read` shows `event_id` only, on every
     provider, exactly as before this ADR (a `series_event_id` line was tried and pulled back: on
     Google and Outlook it handed the assistant a series id it would edit with an occurrence's date,
     moving the whole series). What still names a CalDAV series itself: the row of a series marked
     not listed, and a split's `new_series_event_id`.

**Consequences:**
- A day asked about lists that day's occurrence with its own id, as on Google and Outlook; changed
  occurrences show where they now are.
- One occurrence of a CalDAV series can't be deleted yet; that is an `EXDATE` written into the series
  (a later change). The whole series still can be, by its own id.
- Edit scope `all`, or no scope and no `recurrence_id`, given an occurrence id is refused on CalDAV
  with nothing written, whatever it sets. The Google and Outlook paths, which edit only the instance
  there, are left as they are.
- For a series the listing expands, no tool output carries the series' own id, so a change of the
  whole series, and a delete of the whole series, can't be asked for from one of its occurrences; the
  refusals say the user can make them in their calendar app.
- A one-occurrence edit or a split of a series the device can't expand is refused where the code
  before this ADR wrote an override or a split at the given time unchecked. A resource that holds only
  overrides takes a one-occurrence edit by the occurrence's id, where the code before this ADR could
  not list it at all, and refuses a split.
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
overrides), `CalDAVOccurrenceWireTests` (no DELETE for an occurrence id, series unchanged; an `all`
edit by an occurrence id, a moved occurrence's included, refused with no request whatever it sets; a
moved occurrence listed with its own id, edited in place and split at its place in the series; a
`recurrence_id` that names no occurrence, one after a `COUNT` series' end or a cancelled one, not
found with nothing written; another occurrence than the id's refused; a resource that holds only
overrides edited in place by the occurrence's id, its own id and splits refused),
`CalDAVOccurrenceEditToolToWireTests` (the invariant over every scope and both id kinds, from
`calendar_event_edit` to the wire: the write matches the card, or the edit is refused with nothing sent
after the user confirmed), `CalDAVOccurrenceDeleteToolToWireTests` (the same from `calendar_read` /
`calendar_search` through `calendar_event_delete`) and `CalDAVOccurrenceToolOutputTests`. `ICSParserTests.skipsRecurrenceExceptions` and
`ICSParserTests.multipleVEventsReturnsFirst` now pin only the series view; the listing contract they
stood in for is pinned by `movedOverridesAreListedWhereTheyNowAre`,
`cancelledOccurrenceIsMarkedCancelled` and `weeklyZonedSeriesKeepsItsWallTimeAcrossDST`. Closes #613.
