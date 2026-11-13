## ADR-IOS-112: A Delete of a Repeating Event Takes a Scope

**Status:** Active (2026-11-13, #695). Protocol 1.10.3 (`calendar_event_delete-v1.10.3`,
`system_prompt_agent-v1.10.3`).

**Context:** `calendar_event_delete` deleted whatever id it was given: an occurrence id deleted that
occurrence, a series id the whole series, and nothing deleted an occurrence and every later one. The
assistant was told to shorten a series with `recurrence.until` instead, which is not what Google
Calendar does and sends guests a change rather than a cancellation. The Thunderbird add-on already
deletes by `delete_scope` (`chat/tools/calendar_event_delete.js`, `chat/fsm/calendarDelete.js`), so
iOS was out of parity (ADR-IOS-008).

**Decision:**
1. **The scope is asked, never defaulted.** A repeating event (one with a rule, or an occurrence that
   names its series) is deleted only with `delete_scope` `this_only`, `this_and_following` or `all`.
   With none, or another value, the tool refuses before the card and tells the assistant to ask the
   user "Just this one, this and following, or all of them?" (the add-on's `ASK_DELETE_SCOPE`). An
   event that does not repeat is deleted as it is; a scope given for it is dropped.
2. **What each scope deletes**, worked out before the card (`CalendarEventDeleteTool.target`):
   - `all`: the series, from any of its occurrences (the occurrence's `recurringEventId`), read for the
     card; the card says every occurrence goes and names the rule.
   - `this_only`: one occurrence. By its own id it is deleted as it is; with a `recurrence_id` it is
     found by the provider's own lookup (`CalendarSeriesScope.read`) and deleted by the id the lookup
     gives. The card says the rest of the series stays.
   - `this_and_following`: that occurrence and every later one. The series is ended just before the
     occurrence's place in the series (`CalendarSeriesScope.followingDelete`): at the series' first
     occurrence it is a delete of the whole series (`all`, its card and result), before it refused.
     The card says "This and every later occurrence will be deleted; earlier ones stay." with the
     rule.
   A scope of occurrences given with the series' id needs a `recurrence_id`, refused before the card
   when missing.
3. **`recurrence_id` is read in the device's zone**, snapshotted at the tool's start
   (`ToolContext.deviceZone`), where the read tools print an occurrence's start, whatever `timezone`
   says (#794, as the edit). The cut is queued with that zone (`delete_cut_at`,
   `recurrence_id_timezone`), so the drain cuts at the place the card showed wherever the device is
   then (#753).
4. **A moved occurrence is cut at its original place** (`originalStartTime`), as Google Calendar and
   the add-on cut it: it goes with the later ones and every earlier occurrence stays. The card shows
   both times: "This and every later occurrence will be deleted (from X, originally Y); earlier ones
   stay." (The split, ADR-IOS-108 and #563, still refuses a moved occurrence; a delete leaves no new
   part to place.)
5. **The write is `CalendarProvider.endSeries`**, the cap a split's finish writes, taken out of each
   provider's `finishSplit` (Google RRULE `UNTIL`, Outlook range end, CalDAV the series cap `PUT`),
   from the series as it is at the write; nothing is written when the series already ends before the
   cut, so a replay never lengthens or rewrites it (IOS-CAL-008 amendment). Guests are told:
   `sendUpdates` "all" on Google, as for every delete; the split's own cap stays silent ("none"),
   because its new part carries the notification.
6. **Irreversible.** On Google and Outlook the series end reached by a delete is wire operation (9)
   (Memory 102 amendment); on CalDAV it is the cap `PUT`, (6).

**Consequences:**
- The assistant must ask the scope for a repeating event whose words leave it open, as for an edit.
- A "this and following" delete never deletes an event; the series' earlier occurrences, and its id,
  stay.
- Changed occurrences after the cut are handled by the calendar. Google, measured live (2026-11-13):
  after the `UNTIL` cap a moved occurrence past the new end is kept but cancelled (gone from the
  instances list, a GET by its id returns `status` cancelled), so a "this and following" delete at a
  moved occurrence needs nothing more. Outlook's handling is not measured.
- A series changed between the card and the drain is still cut at the confirmed place (Google's and
  Outlook's `PATCH` carry no precondition; CalDAV's `PUT` is conditional on its own GET).

**Alternatives rejected:**
- A default scope (`all`, as the tool behaved by a series id): deletes more than the user may mean.
- Refusing a moved occurrence, as the split does: the add-on and Google Calendar cut it at its place,
  and nothing has to be created there.
- `sendUpdates` "none" for the cut, as the split: guests would not learn that the later occurrences
  are cancelled.

**Detail:** `CalendarEventDeleteTool.swift` (`target`, `Target.queuedArguments`),
`CalendarSeriesScope.followingDelete`, `CalendarToolHelpers.followingDeleteLines` / `deleteCutKey`,
`AccountManagerCalendarQueue` (`.delete`), `CalendarProvider.endSeries` (Google, Outlook, CalDAV).
Tests: `CalendarScopedDeleteTests` (in `CalendarWriteZoneSnapshotTests.swift`: every scope named as the
read tools printed it under three different zones, the drain in a fourth; first occurrence; moved
occurrence; no scope; Google, Outlook, CalDAV), `CalendarSeriesDeleteCardTests`,
`CalDAVOccurrenceDeleteToolToWireTests`, `BackendProtocolVersionTests` (protocol pinned at 1.10.3).
