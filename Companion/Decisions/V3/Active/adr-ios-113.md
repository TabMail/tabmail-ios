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
   **Only what it changed on its own (2026-11-14, #878).** The put-back writes a changed occurrence's
   start and end (as the carry's plan gives them: a moved one at its own start lasting the new length;
   an unmoved one gets the series' own from the reset) and only those of the other properties it
   writes (the split's `splitCopiedKeys` but `isAllDay`, and its guests) that it held differently
   from the series when read. Each is compared with the series' master as the SAME `$expand` read gave
   it (`seriesExceptionsRead`, `ExchangeCalendarProvider.ownChanges`): exact JSON, the place
   (`location`, `locations`) as one, guests by address in any case, name and type (answers are
   read-only, not restored either way); a property the series does not hold is kept. What it held as
   the series did is left out of the capture and of the record, so it follows the series as it is
   when the put-back runs: a rename or new room another app gives the series in between stays on the
   occurrence (first build: every captured property was written back, so the old title came back).
   An occurrence with nothing of its own left to write is not `PATCH`ed (`guardedPatch` answers
   `restored`). That holds too when someone changed it after the reset (it reads as an exception):
   it is counted as restored, not as left and counted, since the put-back has nothing of it to write
   and the other change stays as it is (review r1 L1, accepted). A split is unchanged: its new part is a new series, with nothing to follow, so its
   carry writes each changed occurrence whole (`seriesExceptions` keeps every property;
   `carriedWrite` writes guests only when the occurrence's JSON holds them, which a split's read
   always does). A record kept by the first build holds each occurrence whole and is put back whole,
   as before; no record format change (version 3 either way).
3. **The record (C3).** What the put-back needs (the changed occurrences' times, and the titles,
   notes, places and guests they held differently from the series, #878) is kept on the queued
   operation (`SeriesEditRecord`) from before the `PATCH`
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
   **The write is conditional on the capture's series (review r2 C1, 2026-11-14).** The record
   (version 3) keeps the series' `@odata.etag` the capture's read gave (`SeriesEditRecord.seriesEtag`),
   and the series `PATCH` is sent with `If-Match` on it (`sendPatch`). Graph's etag is series-wide and
   moves with any write anywhere in the series, and the master `PATCH` honours `If-Match` (measured
   2026-11-14 on the work test account: the master's current etag gives 200; after an occurrence
   is deleted or changed, the earlier etag gives 412 `ErrorIrresolvableConflict` and writes nothing;
   the master's and an occurrence's etags are the same value, so either serves; the etag in a create's
   201 answer was already stale by the first `GET`). A read that finds nothing changed or deleted
   keeps no record, and its write is sent on that read's etag (review r4): an occurrence the user
   changes between the read and the write is refused with 412, read and kept, and put back. So every
   Outlook write of an edit of every occurrence (`edit_scope` all, which the queue always sends
   through `updateSeries`, a change of the length or not) is conditional on the etag of the read it
   was planned from; a read with no etag refuses it unwritten (`seriesVersionUnreadable`), and
   IOS-CAL-002 is amended for it. So a `sent` write that did not land (a 5xx
   with nothing written), followed by the user deleting or changing a changed occurrence in Outlook
   before the retry, is refused with 412 and writes nothing: the retry reads the occurrences again and
   keeps a new record, so the stale capture is never put back over the user's newer change. When the
   read shows the series already holds the write (an earlier attempt's landed, its answer lost), it
   goes on as landed and puts back the kept record, sending no write: the series holds every value of
   the `PATCH` it would send (`holdsValues`, the rule compared by every value sent, since Graph applies
   a `PATCH` whole and gives back its own defaults besides). Without this check the landed write's own
   etag change would refuse the resend and make the retry re-read a series Graph already reset.
   **The new read keeps what the earlier capture held (review r3 C1, 2026-11-14).** When the record's
   write was `sent` by an earlier attempt and the retry reads again (412), that write may have landed
   and reset every occurrence, and the record is the only copy of their own values. So the new record
   holds this read's changed and deleted occurrences plus the earlier capture's at every place this
   read holds none at (`stillCaptured`); this read's wins at a place both hold. Safe where the write
   did not land too: the put-back leaves alone an occurrence changed since the reset (`guardedPatch`
   writes only a plain occurrence) and deletes a place only while it is a plain occurrence. The re-reads are bounded by
   `ExchangeCalendarConfig.putBackConflictReads`, then `seriesBusy` (stays queued). A record of
   version 1 or 2 holds no etag and is read again before its write. Files of a `sent` record that the
   new read does not name are kept in the new record (`stillHeld`), except those whose occurrence Graph
   answers 404/410 (proven gone): the write may have landed and erased them. Kept, one whose occurrence
   the new record holds as changed (this read's or the earlier capture's) is attached again; one whose
   occurrence it no longer holds as changed is counted as not restored and stays saved for Save File.
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
   occurrence holding a linked file) are released at that throw. A record this build can't read (of a
   later version, or not whole; review r2 R1) holds every file its directory holds, each under no name
   (`CalendarPutBackFiles.unnamed`): never "holds none", so a retirement, the reclaim and a dismissal
   without its warning never delete bytes nobody can account for, and Save File still offers them.
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
   **Google, measured 2026-11-14 on the Workspace test account (decided 2026-11-14):** a series
   `PATCH` sending only a recurrence that changes its rule's `UNTIL` keeps every changed occurrence
   placed on or before the new end (own title and moved time kept), and the ones placed after it are
   left cancelled, decided by the original place, wherever they were moved (as Graph). So Google's
   `editResetsChangedOccurrences` answers no reset when the recurrence the write writes
   (`recurrence(_:withRuleFrom:)`) changes only where the stored rule ends (`changesOnlyUntil`: one
   `RRULE` each, the stored one ending on a date or after a count, the written one on a date,
   otherwise the same rule by `canonicalRRULE`, every `EXDATE`/`RDATE` as stored; the measured series
   was `COUNT`-ended, widened to it the same day) and the start and end are the series' own as Google reads them
   (`googleTimes`, so the write sends neither and nothing is restated). Anything else still warns of a
   reset: a rule that gains or loses an end or is given a count, a new pattern, a new length or start, a
   change of kind. Outlook stays `endDate` to `endDate`. CalDAV still warns for any RRULE change.
8. **Every calendar: an earlier last date says how many meetings it removes (decided
   2026-11-14).** The card shows "N meetings after <date> are removed." ("1 meeting ... is removed.")
   on Google, CalDAV and Outlook alike, beside a reset note where there is one, whenever the edit's
   end (`UNTIL`, or the day of its `COUNT`-th occurrence) is before the stored rule's last occurrence;
   "All meetings after <date> are removed." when the stored rule had no end. The count is ONE function
   above the provider boundary (`CalendarSeriesEndRemoval`, ADR-IOS-060), worked out FROM THE STORED
   RULE (decided 2026-11-14): the in-house expander (`RecurrenceTail.occurrences`) places the
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
   shows no card and the "could not read the repeating event ... Retry." error. **Amended 2026-11-14
   (#880, owner ruling):** the `RDATE` case is not a read that can succeed later, so it has its own
   error at its source (`CalendarSeriesEndRemoval.AddedDates`, thrown where the count meets an `RDATE`;
   no string match) and the edit tool answers it, before the card as before, with "calendar_event_edit
   failed: this repeating event has extra dates added outside its repeat pattern, and TabMail can't
   change the repeat pattern of such an event yet. The event was NOT changed." (no "Retry"). Every other reason
   keeps the generic text. It is the only path that reaches the case (the count runs only in
   `CalendarEventEditTool`, before the card; the queued write does not run it), on Google and CalDAV
   (Outlook has no `RDATE`). Pinned by `googleAddedDatesRefusedPlainly`, `calDAVAddedDatesRefusedPlainly`
   and `googleOtherUnreadableKeepsTheGenericMessage`. Counting added dates is #881. An edit whose end the
   two rules alone show is no earlier (`CalendarSeriesEndRemoval.mayEndEarlier`: the stored pattern
   kept, as a set of parts, and the same end, a `COUNT` no smaller, an `UNTIL` no earlier in the same
   form, or a UTC `UNTIL` past a stored date's end in every zone) shows no line and reads nothing, so a
   rename that re-sends the stored rule never fails on an `RDATE` or a zone it can't read (review r2
   C2). A source check holds the count free of any provider name, cast or listing.
   **CalDAV write, call C1 (decided 2026-11-14):** an edit of every occurrence whose rule is the
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
9. **A split cut on a date added outside the repeat pattern is refused (amended 2026-11-14, #894,
   owner ruling).** A "this and following" change on Google or CalDAV keeps the series' rule on its
   new part (`RecurrenceTail.newSeriesRule`), with only its end rewritten. When the cut is an added
   date (`RDATE`) the rule gives no place at, the new part starts off its rule (RFC 5545 §3.8.5.3:
   the occurrences are then undefined; §3.3.10: the start counts toward `COUNT`), so it loses
   meetings or makes some up (a weekly rule with no day named repeats on the added date's weekday; a
   `COUNT` loses its last meeting), and on Google a time change shows the added date twice. The cut
   lands there when the change names the added date, or when it names a moved meeting and the first
   place at or after where that meeting is now is an added date (`SplitCarry.cut` counts added dates
   as places). Such a split is refused before anything is written, with #880's message from its one
   source (`CalendarSeriesEndRemoval.AddedDates.reason`): "calendar_event_edit failed: this repeating
   event has extra dates added outside its repeat pattern, and TabMail can't change the repeat pattern
   of such an event yet. The event was NOT changed."
   - **Decided from what the series holds, never from the calendar:** one provider-neutral predicate
     `SplitCarry.cutsAtAddedDate(cut, series:, rdates:, zone:, zones:)`: true when the cut equals one
     of the series' added dates (read as `SplitCarry.cut` reads them) and the rule's own first place
     at or after the cut (`ruleCut`, `UNTIL`/`COUNT` honoured) is not the cut. An added date on a rule
     place at the same time is not refused (the new part's start is on its rule). False with no added
     date (nothing more read) and past the end; nil when an added date or the rule can't be read,
     which refuses with the split's "can't be read" text.
   - **Where it sits:** in each calendar's `splitPlan` (Google `GoogleCalendarProvider.splitPlan`,
     right after `splitPoint`; CalDAV `CalDAVProvider.splitPlan`, from `SplitPoint.cutsAtAddedDate`,
     which `splitPoint` works out with the resource's `RDATE` lines and zones), before the first
     write. `splitPlan` is the one plan both the card's check (`refuseSeriesWrite`, decision 5) and
     the queued write (`splitSeries`) run, so the tool refuses before the card and a queued operation
     is retired with the same reason, nothing written. An edit of every occurrence that `route`
     turns into a split reaches it the same way. `finishSplit` is not checked: it runs only with a
     `SplitRecord`, which a split keeps only after its create, so after its own plan passed;
     refusing there would leave the uncapped series and the new part both showing.
   - The wording "change the repeat pattern" is kept for one source: a split ends the series' repeat
     at the cut and starts a new one there. It is broader than the case (a split at a regular meeting
     of the same series is written).
   - **A move of the following meetings that leaves an added date behind (owner ruling 2026-11-14,
     panel, answer A).** A split whose new part starts off its cut (a new time, another day, or the
     other kind) while the new part holds added dates (those at or after the cut) is refused on a
     calendar that does not move added dates with the series, same message, nothing written: Google
     keeps an added date at the time it was written, so one following meeting would stay at the old
     time though every following one was asked to move. CalDAV moves them with the series
     (`seriesSplitResources`), so there the change is written. Decided from the series' contents and
     a provider CAPABILITY, never a provider type above the provider boundary (ADR-IOS-060):
     `CalendarProvider.movesAddedDatesWithSeries` (Google false, CalDAV true, protocol default false;
     Outlook has no `RDATE`) and the pure `SplitCarry.leavesAddedDatesBehind(cut:newPartStart:
     holdsAddedDates:movesAddedDates:)`, false with no added date in the new part or on a calendar
     that moves them, nil (refused with "can't read") when the new part's start can't be read. Run in
     the same `splitPlan`s after the new part is built (Google from the create body `written` and
     `recurrenceParts.tail`; CalDAV from `resources.newPart`), so the card check and the queue refuse
     alike. An added date only before the cut stays with the series and the move is written. Not
     covered: a change of every occurrence's time on Google (`all`, or `this_and_following` at the
     first occurrence, which is the whole series) also leaves added dates at their old time.
   - Splits at a regular meeting are unchanged. Outlook has no `RDATE`. Full support is #881.
   - Pinned by `SplitAtAnAddedDateTests` (Google and CalDAV, named at the added date and at a moved
     meeting cut there, before the card and at the queue, nothing written; a split at a regular
     meeting of the same series written, the meetings its two parts show read back by the app's
     expander against the series' own; a move to a new time or day with an added date after the cut
     refused on Google before the card and at the queue, written on CalDAV with the added date moved,
     and written on Google when the only added date is before the cut) and
     `SplitCarryTests.cutsAtAddedDateReadsTheSeries`. `GoogleSeriesSplitCopyTests` reschedule cases
     and `splitOntoAnotherDayDropsExcludedDates` now use a series with no added date after the cut.

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
- Limits of the conditional series write (review r2): a write that landed with its answer lost, then
  overtaken before the retry by another client's change of the series, is read again and sent again,
  so the edit is written over that client's change (a landed write and one that did not land can't be
  told apart there, and the unlanded one needs the resend), and the earlier capture's occurrences are
  put back (r3). An occurrence the user set back to the series' values in another app after a sent
  write that did not land is changed back to its captured values. A put-back's re-`DELETE` of a deleted place runs on the type read once by
  `instances(around:)`, with no `If-Match` (the rulings ask it only of a `PATCH`): a change the user
  makes to that occurrence between the listing and the `DELETE` is lost; the deletes run first, so the
  window is short. A zoneless or `RDATE` series whose re-sent end is in another form within a day of
  the stored one (a stored date, a UTC time before that date's end in the zone farthest behind UTC)
  still can't be told no earlier from the rules, and fails closed as before.

**Alternatives rejected:**
- Refuse a new length when Outlook would reset something (the old branch's first design): unlike
  Google, and the user loses nothing they can see only if the put-back is done.
- Check before the card with a copy of each write's refusals: the copies drift; one plan per write is
  called by both.
