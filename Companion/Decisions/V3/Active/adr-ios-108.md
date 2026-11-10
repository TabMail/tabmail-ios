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
   - Edit: `updateEvent` is the edit of the whole series (edit_scope `all`), so by an occurrence id
     it edits the SERIES, every occurrence, as the tool promises; a change of the rule through an
     occurrence id is refused with nothing written. `updateOccurrence` (this_only) by an occurrence
     id changes that occurrence alone; it and `splitSeries` (this_and_following) address its series'
     resource exactly as given the series id. The Google and Outlook paths are unchanged.
   - Delete: `deleteEvent` by an occurrence id is REFUSED before any request ("Deleting one
     occurrence of a repeating CalDAV event is not supported yet … by its series id"). The queue
     retires it as unsupported and the card and the tool say the event was not deleted. Deleting by
     the series id is unchanged.
   - `calendar_event_read` shows `series_event_id` for an occurrence of a series (any provider) so the
     refusal's way out can be taken; `ChatIdTranslator` maps it like `event_id`.

**Consequences:**
- A day asked about lists that day's occurrence with its own id, as on Google and Outlook; changed
  occurrences show where they now are.
- One occurrence of a CalDAV series can't be deleted yet; that is an `EXDATE` written into the series
  (a later change). The whole series still can be.
- Edit scope `all` given an occurrence id edits the whole series on CalDAV. The Google and Outlook
  paths, which edit only the instance there, are left as they are.
- Nothing new is stored: the occurrences are worked out per listing from the resource the server
  returns (ADR-004 untouched). `maxResults` trims after the expansion.

**Alternative rejected:** asking the server to expand (RFC 4791 `CALDAV:expand`). Support and output
differ between servers, the expanded instances carry neither the rule nor a link to their series, and
keeping the device expansion for servers that don't expand would be a second route, a fallback.

**Detail:** `CalDAVOccurrences.swift`; tests `CalDAVOccurrenceExpansionTests`,
`CalDAVOccurrenceNotListedTests`, `CalDAVOccurrenceLookupTests`, `CalDAVOccurrenceWireTests`
(no DELETE for an occurrence id, series unchanged; an `all` edit by an occurrence id changes every
occurrence), `CalDAVOccurrenceDeleteToolToWireTests` (the
same from `calendar_read` / `calendar_search` through `calendar_event_delete`) and
`CalDAVOccurrenceToolOutputTests`. `ICSParserTests.skipsRecurrenceExceptions` and
`ICSParserTests.multipleVEventsReturnsFirst` now pin only the series view; the listing contract they
stood in for is pinned by `movedOverridesAreListedWhereTheyNowAre`,
`cancelledOccurrenceIsMarkedCancelled` and `weeklyZonedSeriesKeepsItsWallTimeAcrossDST`. Closes #613.
