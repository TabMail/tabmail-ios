# IOS-LOG-003

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-10 through the amendment
> surface described in `Scripts/compact_known_issues.rb`. The base record's own bytes are
> hash-pinned and are **not** edited by this file.

- Register classification: **superseded by owner decision, 2026-09-10** (GitHub
  `TabMail/tabmail-ios#72`) — the calendar-family corpus was swept with the rest of the app target.
  Detail of the sweep: `Amendments/ios-log-001.md`.
- Amends: this row's status, and — by this row's OWN negative bound — its home.

## The row's negative bound fired

The base record says: *"If a calendar log is ever routed to `NSELog`, to `os_log(privacy: .public)`,
or to a file, it LEAVES this row and joins `IOS-LOG-002` — the disposition here rests entirely on
(b), and (b) is false for any durable channel."* The six calendar-family files'
`print`s now go to `BackgroundSyncLogger.logDebug`, a file channel, so this corpus has LEFT this row.
Its persisted exposure is recorded in `Amendments/ios-log-002.md` (2026-09-10).

**The worst site is unchanged in content and changed in reach.** `CalDAVClient.put`'s
`body.prefix(4000)` of the outgoing ICS — `SUMMARY`, `DESCRIPTION`, `LOCATION` and every `ATTENDEE`
`mailto:` address — was a `stdout` line on an attached debugger. It is now, for an unlocked allowed
user only, a whole-line-escaped `[DEBUG]` entry in `tabmail.log` that leaves the device when that user
shares App Logs. For every other user the gate is closed and the argument is never rendered. The
reason the site logs the ICS at all — opaque CalDAV `403`/`412` failures with no body — is now
answerable from an exported log rather than only from a tethered session.

## Search terms

calendar-family prints swept; `CalDAVClient.put` ICS body now persisted for unlocked users; row left
for `IOS-LOG-002`; `logDebug`; #72
