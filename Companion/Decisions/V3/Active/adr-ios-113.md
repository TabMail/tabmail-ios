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
   length, each deleted one is deleted again (only an instance whose `type` is `occurrence`; one
   changed since is left as it is and counted, and the put-back goes on). A put-back that fails for good
   after the `PATCH` retires the operation with "The series was changed, but N events you had changed
   on their own could not be restored. Check them in your calendar." Attendee answers are not restored
   (read-only in Graph).
   **Restore guard (2026-11-14).** Each changed occurrence is read right before its `PATCH`
   (`guardedPatch`): only a plain occurrence (`type` `occurrence`) is written, with the read's
   `@odata.etag` as `If-Match`. Graph's etag is series-wide (measured), so a 412 means something in the
   series moved: it is read and judged again, at most `ExchangeCalendarConfig.putBackConflictReads`
   times, then `ExchangeCalendarError.seriesBusy` keeps the operation queued. An exception that already
   holds what the `PATCH` sends (`holdsValues`, a normalized compare) is done; any other is left as it is
   and counted. A changed occurrence not listed at its place is read by its own id (Graph keeps it
   through the reset): the instances read lists by each occurrence's start now, so one moved since out
   of the window is missing, and only Graph's 404 or 410 for its id proves it deleted (its files are
   then released).
3. **The record (C3).** What the put-back needs (the changed occurrences' times, titles, notes,
   places and guests) is kept on the queued operation (`SeriesEditRecord`) from before the `PATCH`
   until the operation completes, so a retry after a lost answer puts back what the first attempt
   read. It is event content, not email content (ADR-004 covers email content), pending-operation
   scope, and is cleared with the operation.
   **The write's state is kept, never re-derived (review r1 C1, 2026-11-14).** The record (version 2)
   keeps how far the series' `PATCH` got (`SeriesEditRecord.Write`): `sent` before it, `landed` once
   answered, `notSent` again when Graph answers this attempt's first send with a refusal (a 4xx, or a
   refusal before sending, `refusedUnwritten`; a lost answer or a 5xx may have landed and stays
   `sent`). A retry decides from that alone: once `sent` the kept record is put back and never replaced
   or shrunk but by the put-back's own read-backs; a `sent` write is sent again (`patchEdit` sends
   nothing when the read shows it there), a `landed` one is not. Only a `notSent` record is read and
   kept again. The first build re-derived "landed" from a read (`!movesSeriesTime`), which takes "can't
   judge" (a zone label that does not resolve) or a series another client moved since for "not landed",
   and then replaced the record and released the only copies of the files. A version 1 record reads as
   `sent`.
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
6. **Files of changed occurrences: saved on the device and attached again (option C, 2026-11-14).**
   Outlook's reset erases a changed occurrence's whole attachment set (measured). Before the series
   `PATCH`, `ownFiles` reads each changed occurrence's attachments: a linked file
   (`lengthChangeLinkedFileRefusal`) or an Outlook item the series does not hold
   (`lengthChangeItemRefusal`) refuses the change, before the card and at the drain, nothing written; a
   file it holds of its own (not paired with the series' files by name, kind and content,
   `AttachmentPairing.unpaired`, #863) is saved beside the database
   (`CalendarPutBackFiles`, `calendar_put_back/<operation id>/<sha256>`) and named in the record
   (`SeriesEditRecord.files`, `PutBackFile`, versioned: a record this build can't read leaves the
   operation queued as it is). After the put-back of its occurrence, each file is attached again,
   add-only (`reattach`, the split's `ExchangeProvider.addFileAttachment`, inline placement kept), also
   on an occurrence left as it is. Saved bytes are deleted only by a read showing the file back, a
   proven-gone occurrence, the user's warned dismissal of the failed change, or the user's warned
   removal of its account (`PutBackLedger` keeps the record before releasing bytes). A missing or
   corrupt saved copy is skipped, counted and dropped; Outlook's `ErrorMessageSizeExceeded` retires the
   operation ("<file> could not be put back on <date>: too large for Outlook."); a file answered but
   not read back keeps it queued (`putBackNotConfirmed`), for at most
   `ExchangeCalendarConfig.putBackUnconfirmedAttempts` attempts (counted in the record; each re-adds the
   file), then retires it with the file counted as not restored and kept (review r1 R1); a full mailbox
   keeps it queued (#865). A failed operation that still holds files says "The series was changed, but
   N files attached to events you had changed on their own are not restored yet." and is shown until
   dismissed; its banner and the account-removal alert offer Save File (the share sheet) and warn
   before deleting (owner ruling 2026-11-14). Account removal counts the saved files again inside its
   delete transaction and refuses, changing nothing, when there are more than the user was warned of;
   Settings then warns again with the new count. The 30-day reclaim spares a row holding files; the
   drain-start sweep removes only bytes whose row is gone.
   **One definition of "holds files" (review r1 R2, C2):** `CalendarPutBackFiles.held(row)`, the
   record's files once its write is `sent` or `landed`, while its bytes are on the device. The banner,
   its warning, account removal, the reclaim and the queue's retirement all read it. Before the write
   is sent, or once Graph refused it, the calendar still holds every file: a retirement then (the series
   gone, 404; no permission, 403) deletes the copies and shows the ordinary failure, never "The series
   was changed". Files a capture saved before a later refusal or error of the same plan (a second
   occurrence holding a linked file) are released at that throw.
   **The put-back's outcome reaches the inbox (review r1 C3):** a put-back that can't finish after the
   series was written throws `CalendarProviderError.seriesPutBackIncomplete` with the user's words
   (`putBackOutcome`, `putBackTooLarge`); the queue retires it as `CalendarFailureKind.putBackIncomplete`,
   whose banner shows that stored text ("A calendar change wasn't finished: <title>. <outcome>"),
   where every other kind's stored reason stays text for the assistant.
7. **Outlook: a new last date alone is no reset (2026-11-14).** Measured on a work account: a series
   `PATCH` whose recurrence differs from the stored one only in its range's `endDate` (both ending on a
   date), with the stored start and end, keeps every changed occurrence (id, time, title, own file)
   and every deleted one deleted, earlier or later; an earlier end removes the occurrences placed after
   it, changed ones with them (404 by id). So `editResetsChangedOccurrences` answers no reset for it
   (`newRangeEnd`: the edit's rule in Graph's form, `sameRule` with the end left out) only when the
   start and end the write restates are the stored ones exactly, zone label included
   (`restatesStoredTimes`, against `originalStartTimeZone` and `originalEndTimeZone`): a start the
   write would relabel under another name of its zone was not measured, so it stays a reset. A rule
   that gains or loses an end, or ends after a count, is still a rule change and warned of as a reset;
   a new length together with a new last date moves the series' time and resets (no put-back).
   Google and CalDAV still warn of a reset for any RRULE change, an `UNTIL` alone included (not
   measured there). (Superseded for Google the same day, below.)
   **Google, measured 2026-11-14 on the Workspace test account (master-agent's call):** a series
   `PATCH` sending only a recurrence that changes its rule's `UNTIL` keeps every changed occurrence
   placed on or before the new end (own title and moved time kept), and the ones placed after it are
   left cancelled, decided by the original place, wherever they were moved (as Graph). So Google's
   `editResetsChangedOccurrences` answers no reset when the recurrence the write writes
   (`recurrence(_:withRuleFrom:)`) changes only where the stored rule ends (`changesOnlyUntil`: one
   `RRULE` each, the stored one ending on a date or after a count, the written one on a date,
   otherwise the same rule by `canonicalRRULE`, every `EXDATE`/`RDATE` as stored; the measured series
   was `COUNT`-ended, widened to it by master-agent the same day) and the start and end are the series' own as Google reads them
   (`googleTimes`, so the write sends neither and nothing is restated). Anything else still warns of a
   reset: a rule that gains or loses an end or is given a count, a new pattern, a new length or start, a
   change of kind. Outlook stays `endDate` to `endDate`. CalDAV still warns for any RRULE change.
8. **Every calendar: an earlier last date says how many meetings it removes (master-agent,
   2026-11-14).** The card shows "N meetings after <date> are removed." ("1 meeting ... is removed.")
   on Google, CalDAV and Outlook alike, beside a reset note where there is one, whenever the edit's
   end (`UNTIL`, or the day of its `COUNT`-th occurrence) is before the stored rule's last occurrence;
   "All meetings after <date> are removed." when the stored rule had no end. The count is ONE function
   above the provider boundary (`CalendarSeriesEndRemoval`, ADR-IOS-060), worked out FROM THE STORED
   RULE (master-agent's ruling): the in-house expander (`RecurrenceTail.occurrences`) places the
   occurrences after the new last date up to the stored end (an `UNTIL`'s day, or the `COUNT`-th
   occurrence's), in the series' zone, with the calendar's own counting conventions carried on the read
   (`GCalEvent.recurrenceAnchor`, `recurrenceMissingDay`, `recurrenceFirstDayOfWeek`: Outlook counts from
   the range start and holds a missing month day on the month's last day), less the ones deleted one by
   one: the series' `EXDATE` lines, and the places its calendar gives through ONE new protocol read,
   `CalendarProvider.deletedOccurrencePlaces` (Google: its cancelled instances, as the series'
   `recurrence` gets no `EXDATE` when one is deleted, measured; Outlook: `cancelledOccurrences`; CalDAV:
   a `RECURRENCE-ID` VEVENT whose status is `CANCELLED`). A changed occurrence counts at its place,
   however far it was moved; no listing, no calendar lookup. Fails closed, never a silent 0: a stored
   rule, zone, first date or end that can't be read or expanded, an `RDATE`, or a failed deletions read
   shows no card and the "could not read the repeating event ... Retry." error. A source check holds the
   count free of any provider name, cast or listing.
   **CalDAV write, master-agent's call C1 (2026-11-14):** an edit of every occurrence whose rule is the
   stored one with an earlier end also drops, in the same single `PUT` as the rule, every changed
   occurrence (override VEVENT) whose place (`RECURRENCE-ID`) is on a day after the new last date in
   the series' zone, wherever it was moved; one placed on or before that date stays, even when moved
   past it, as Outlook keeps it (`CalDAVProvider.earlierEndResource`; the new last date read by
   `RecurrenceTail.lastDay`, the reading the count uses, so the card's place-based count is what the
   write removes). Excluded dates (`EXDATE`) are left; one past the new end is harmless. Before C1 the
   write kept every override, so one placed after the new end stayed visible at its moved time.
   The census counts this drop, with the earlier end on Google and Outlook, as irreversible
   operation (12): twelve operations (2026-11-14, decision 7's census paragraph and memory 102).
   *Superseded first build (5c96b802, 2026-11-14):* the count listed the calendar's occurrences
   (`listEvents`) within a 7-day margin; it undercounted (a default-calendar listing gave a silent 0 for
   a series on another calendar, a far-moved occurrence was missed) and was replaced the same day.

**Consequences:**
- Outlook attendees get the series update and then one update or cancellation per put-back write
  (Google sends one update). During the put-back the reset is briefly visible to other readers.
- Outlook's resetting series `PATCH` is irreversible operation (11), and the put-back `DELETE` widens
  (10) (memory 102).
- A series whose zone TabMail can't read is refused for a new length when an occurrence was moved or
  deleted on its own, and for a following delete, before the card (#746 lifts it).
- A changed occurrence's own attachments are lost by Outlook's reset (measured); its files are saved
  on the device and attached again (decision 6); a linked file or an Outlook item of its own refuses
  the change. A series file the user had removed from a changed occurrence comes back with the reset
  (the put-back only adds). The saved bytes are new on-device data of pending-operation scope (event
  attachments, not email content: ADR-004), in the app's default protection class and the backup, as
  the database is.

**Alternatives rejected:**
- Refuse a new length when Outlook would reset something (the old branch's first design): unlike
  Google, and the user loses nothing they can see only if the put-back is done.
- Check before the card with a copy of each write's refusals: the copies drift; one plan per write is
  called by both.
