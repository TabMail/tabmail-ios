## ADR-IOS-113: A New Length of Every Occurrence Keeps the Occurrences Changed on Their Own, and a Series Write Is Checked Before Its Card

**Status:** Active (2026-11-14, #718).

**Context:** An edit of every occurrence that changes only the end ("make the standup 45 minutes")
was judged by the shown occurrence's end, so an end past midnight or a longer all-day series was
refused after the card. On Outlook, the series `PATCH` that moves its time resets every occurrence
changed on its own and brings back every one deleted on its own (measured 2026-11-14); Google keeps
them and gives each the new length; CalDAV left its overrides at their old length. Separately, a
series write the queue's write refuses before writing anything (a zone it can't read, a linked file,
an attached item, a carried occurrence it can't place) was refused only after the user had confirmed
its card.

**Decision:**
1. **An end alone is a length.** With no occurrence named, an end given alone for every occurrence is
   a length counted from the series' start, refused only when it is zero or less; it routes to the
   series, never to a split.
2. **Outlook: put back, not refuse (C1).** A new length alone reads every changed and deleted
   occurrence before the series `PATCH` and puts them back after it with the split's carry
   (`updateSeries`, `putBack`): each changed one keeps its own start and fields and takes the new
   length, each deleted one is deleted again (only an instance whose `type` is `occurrence`; else it
   stops with nothing deleted). A put-back that fails for good after the `PATCH` retires the operation
   with "The series was changed, but N events you had changed on their own could not be restored.
   Check them in your calendar." Attendee answers are not restored (read-only in Graph).
3. **The record (C3).** What the put-back needs (the changed occurrences' times, titles, notes,
   places and guests) is kept on the queued operation (`SeriesEditRecord`) from before the `PATCH`
   until the operation completes, so a retry after a lost answer puts back what the first attempt
   read. It is event content, not email content (ADR-004 covers email content), pending-operation
   scope, and is cleared with the operation.
4. **CalDAV: the same PUT.** A new length alone gives each override the new length from its own
   start in the same conditional `PUT` of the series resource; a field the edit also sets (a title)
   is set on each override too, as Google retitles them. A deleted occurrence (`EXDATE`) stays deleted.
5. **One check before the card (R5).** `CalendarProvider.refuseSeriesWrite(calendarId:write:)` runs,
   for an edit of every occurrence, a split and a delete of an occurrence and every later one, the
   plan the calendar's own write makes before its first write, and throws what that plan throws, in
   the write's own words. The tools call it before the card (`calendar_event_edit failed: <reason>.
   The event was NOT changed.`; `calendar_event_delete failed: <reason> The event was NOT deleted.`);
   a read that fails shows no card and asks for a retry. The write runs the same plan again, since the
   series can change in between. Each write's plan is ONE function its write and the check both call
   (Outlook `splitPlan`, `endPlan`, `lengthChangeExceptions`; Google and CalDAV `splitPlan`). The tool
   and the queue build the write's input with one function (`CalendarSeriesScope.writeInput`), so the
   check plans what the queue writes. Google and CalDAV make no request for an edit of every
   occurrence or a following delete (nothing in those writes refuses before writing).

**Consequences:**
- Outlook attendees get the series update and then one update or cancellation per put-back write
  (Google sends one update). During the put-back the reset is briefly visible to other readers.
- Outlook's resetting series `PATCH` is irreversible operation (11), and the put-back `DELETE` widens
  (10) (memory 102).
- A series whose zone TabMail can't read is refused for a new length when an occurrence was moved or
  deleted on its own, and for a following delete, before the card (#746 lifts it).
- A changed occurrence's own attachments are lost by Outlook's reset (measured); they are handled by
  the attachment rule of the same release, which must land before it ships.

**Alternatives rejected:**
- Refuse a new length when Outlook would reset something (the old branch's first design): unlike
  Google, and the user loses nothing they can see only if the put-back is done.
- Check before the card with a copy of each write's refusals: the copies drift; one plan per write is
  called by both.
