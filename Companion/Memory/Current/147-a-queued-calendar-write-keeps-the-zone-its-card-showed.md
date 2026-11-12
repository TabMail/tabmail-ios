# A queued calendar write keeps the zone its card showed

**Keywords:** `ToolContext.deviceZone`, `deviceZoneOverride`, `resolveWriteTimeZone(deviceZone:)`,
`CalendarToolHelpers.stampingZone`, queued `timezone`, `pendingCalendarOperation` arguments, offline
queue, zone change between confirm and drain, travel, card zone, `timeZoneId`,
`ActionConfirmationCard.eventTimezoneLabel`, `eventZone`, zone row only when not the device's, Google
Calendar behaviour, CalDAV floating write, `formatDTLine` `.floating`, `floatingWriteNeedsZoneMessage`,
`mergePatchKeepingLength`, `CalendarWriteZoneSnapshotTests`, `CalendarCardZoneLabelTests`, snapshot
settings at operation start, #753, #761.

## The rule

**A confirmed `calendar_event_create` or `calendar_event_edit` writes the time its card showed, in
whatever zone the device is in when the queue drains (#753).** The tools read the device's zone ONCE,
as their first step (`ctx.deviceZone`, the snapshot rule), and use that one value for the card, the
routing, the queued arguments and the reply. When the assistant names no `timezone`, the tool stamps
`timezone = <that zone's id>` into the queued arguments (`CalendarToolHelpers.stampingZone`); a zone
the assistant named (IANA or Windows) is queued as given. Before #753 the drain resolved a missing
`timezone` to the device's zone AT THE DRAIN, so "15:00" confirmed in New York and drained in London
was written 15:00 London.

- No column, no migration: the zone rides in `argumentsJSON`. A row queued before #753 has no
  `timezone` and drains in the device's zone at the drain, as it always did (standing order: old rows
  run as today).
- The card names a zone only when it is not the device's zone as the card is shown
  (`ActionConfirmationCard.eventTimezoneLabel`), as Google Calendar does.
- CalDAV floating times (no TZID): `formatDTLine` writes the wall clock of the patch's time in the zone
  the patch is labelled with (every timed value from `buildGCalEventInput` carries one), never in the
  device's zone at the write. An unlabelled floating patch is refused (`floatingWriteNeedsZoneMessage`),
  nothing written. `mergePatchKeepingLength` keeps the patch's labels on a floating copy and names a
  derived end in the start's zone; a zoned copy still drops them.
- Not fixed here: finding ONE occurrence of a floating CalDAV series after a zone change (the lookup
  reads floating frames in the device's zone, ADR-IOS-108): filed as #761.

## Tests

`TabMailTests/Tools/CalendarWriteZoneSnapshotTests.swift` drives the real tools with
`ToolContext(deviceZone:)` set to a zone that is not the host's, drains in the host's zone, and
compares the write on the Google, Graph and CalDAV fakes with the card. The stamp-removal inversion
turns every non-control case red; the floating case is red with the formatter reverted.
