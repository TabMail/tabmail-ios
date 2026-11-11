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
   - Edit, whole series: `updateEvent` is the edit of the whole series (edit_scope `all`). By an
     occurrence id it may set only fields that place nothing in time (title, location, description,
     busy status), which it writes into the SERIES, every occurrence. A start, an end (or their
     zones), guests or a repeat rule given with an occurrence id is REFUSED before any request
     (`CalDAVProvider.setsTimeGuestsOrRule`), nothing written: the assistant takes those values from
     the occurrence it was shown, and written over the series they would move its first date to that
     occurrence's date (and every removed, added and changed occurrence with it) or give every
     occurrence one occurrence's guests. The refusal says to edit just the occurrence with this_only.
     An `all` edit by an occurrence id that changes the time returns with the series time-shift work,
     which reads a new time relative to the occurrence named.
   - Edit, one occurrence or a split: `updateOccurrence` (this_only) and `splitSeries`
     (this_and_following) address the series' resource and make ONE check before they write
     anything, `CalDAVOccurrences.scopedEditSlot`: `recurrence_id` must name an occurrence the series
     has now. With the series id, it must be a place the series puts an occurrence (a rule or `RDATE`
     date not removed by `EXDATE`, or an override's `RECURRENCE-ID`); a moved occurrence's new time is
     not one. With an occurrence id, the key names the occurrence and `recurrence_id` must name the
     same one, by its place in the series or by where it now is (the start the listing showed); the
     write uses the key's place, so an override is changed in place and a split starts where the
     series puts that occurrence, never at where it was moved to. An event that does not repeat, a
     series marked not listed, a resource holding only overrides and a cancelled occurrence are
     refused too, as on Google and Outlook. The check runs after the GET and before any PUT,
     including the split's create and its cap (irreversible wire operation #6). For a split it reads the rule
     without its `COUNT`/`UNTIL`: where the series ends stays `RecurrenceTail.newSeriesRule`'s check,
     which also knows a series this same split already capped (a retry).
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
- Edit scope `all` given an occurrence id sets the whole series' title, location, description and busy
  status on CalDAV, and refuses a time, an end, guests or a rule. The Google and Outlook paths, which
  edit only the instance there, are left as they are.
- For a series the listing expands, no tool output carries the series' own id, so a change of the
  whole series' time, guests or rule, and a delete of the whole series, can't be asked for from one of
  its occurrences; the refusals say the user can make them in their calendar app.
- A one-occurrence edit or a split of a series the device can't expand, or of a resource that holds
  only overrides, is refused where the code before this ADR wrote an override or a split at the given
  time unchecked.
- A retry after a lost response can be refused, with nothing written, when the first attempt changed
  the time of a moved occurrence named by its new time, or capped the series at it.
- Nothing new is stored: the occurrences are worked out per listing from the resource the server
  returns (ADR-004 untouched). `maxResults` trims after the expansion.

**Alternative rejected:** asking the server to expand (RFC 4791 `CALDAV:expand`). Support and output
differ between servers, the expanded instances carry neither the rule nor a link to their series, and
keeping the device expansion for servers that don't expand would be a second route, a fallback.

**Detail:** `CalDAVOccurrences.swift`; tests `CalDAVOccurrenceExpansionTests`,
`CalDAVOccurrenceNotListedTests`, `CalDAVOccurrenceLookupTests`, `CalDAVOccurrenceWireTests`
(no DELETE for an occurrence id, series unchanged; an `all` edit by an occurrence id sets the fields
that place nothing in time and refuses the rest with no request; a moved occurrence listed with its
own id, edited in place and split at its place in the series; a `recurrence_id` that names no
occurrence, or another occurrence than the id's, writes nothing), `CalDAVOccurrenceDeleteToolToWireTests` (the
same from `calendar_read` / `calendar_search` through `calendar_event_delete`) and
`CalDAVOccurrenceToolOutputTests`. `ICSParserTests.skipsRecurrenceExceptions` and
`ICSParserTests.multipleVEventsReturnsFirst` now pin only the series view; the listing contract they
stood in for is pinned by `movedOverridesAreListedWhereTheyNowAre`,
`cancelledOccurrenceIsMarkedCancelled` and `weeklyZonedSeriesKeepsItsWallTimeAcrossDST`. Closes #613.
