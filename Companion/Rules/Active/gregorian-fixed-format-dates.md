# Fixed-format dates are Gregorian, `en_US_POSIX`, with an explicit zone: one builder

**Since:** 2026-11-11 (issue #586, iOS 1.11.4).

## The rule

The Gregorian calendar is the app's single normal form for dates at every boundary: anything sent to a
server (Google, Outlook, CalDAV, the backend), written to storage, handed to or read from a tool
argument, or parsed from any of those. The phone's calendar setting may only ever affect what is
displayed, never what is stored or sent.

1. **Every fixed-format `DateFormatter` comes from `FixedDateFormat.formatter(_:timeZone:)`**
   (`Shared/FixedDateFormat.swift`, compiled into the app and the notification extension). It sets the
   `en_US_POSIX` locale, the Gregorian calendar, and the time zone the caller passes. The zone is a
   required argument; a caller that means the device zone writes `.current`.
2. **No code anywhere else sets `dateFormat`**, in any target: not on a fresh `DateFormatter`, and not
   on one the builder returned (a site that needs a second pattern asks the builder for a second
   formatter). Parse paths count as much as format paths.
3. **Display formatting that should follow the phone** (`dateStyle`, `timeStyle`,
   `setLocalizedDateFormatFromTemplate`) sets no `dateFormat` and does not go through the builder.
4. `ISO8601DateFormatter` is Gregorian already and is not affected.
5. A `YYYY-MM-DD` value read by hand into `DateComponents` is turned into a `Date` with
   `Calendar(identifier: .gregorian)`, never `Calendar.current` (the reminder due-date readers).

## Why

A `DateFormatter` with a `dateFormat` follows the phone's locale and calendar unless both are pinned
(Apple QA1480). On a phone whose calendar is not Gregorian (Buddhist is the default for the Thailand
region; Japanese and Islamic calendars are user settings) `yyyy` writes another year:
`20261201T000000Z` comes out as `25691201T000000Z` (Buddhist), `00081201T000000Z` (Japanese) or
`14480621T000000Z` (Umm al-Qura), and a parse of `2026-11-20` reads a year centuries away. Every
calendar create, edit, series split cap and listing window therefore landed in the wrong year on
Google, Outlook and CalDAV, where other attendees see it, and the assistant's create tool and the
calendar tool helpers did the same. Some locales also write non-ASCII digits. On a fresh formatter the
`en_US_POSIX` locale alone also gives the Gregorian calendar, but a calendar already set on a formatter
survives a later locale change (a Buddhist calendar set before `en_US_POSIX` still writes 2569), so the
builder sets both.

## How it is enforced

- `TabMailTests/Services/FixedDateFormatFenceTests.swift` reads every target folder's Swift source at
  run time (everything at the repository top level except the test target) and fails on a `dateFormat`
  assignment outside `Shared/FixedDateFormat.swift`, with comments and string literals ignored. It was
  red on the pre-fix source (97 sites).
- `TabMailTests/Services/FixedDateFormatTests.swift` presets a formatter to a non-Gregorian phone
  default (Buddhist with `th_TH`/`en_TH`, Japanese, Umm al-Qura with `en_SA`/`ar_SA`) and shows
  `FixedDateFormat.pin` still yields Gregorian, `en_US_POSIX` and the given zone, with exact round
  trips; it also formats a date built in a Buddhist calendar and checks the Gregorian year. The
  simulator's own locale and calendar are never switched.

## Not covered (reviewed, left as is)

`Calendar.current` used for whole-day or hour arithmetic, start-of-day and same-day checks gives the
same instants in every calendar the phone can use, so it is not this bug. A relative offset in years
(the IMAP search's one-year fallback window) is a shorter span on a lunar calendar but still encodes a
correct Gregorian date on the wire; it is a different, minor effect and was not changed.
