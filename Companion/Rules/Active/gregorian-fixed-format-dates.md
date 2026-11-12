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
3. **Human-readable dates that leave the device or reach the assistant** (an invite's "When:", a
   reply or forward attribution line, an attached message's "Date:", the calendar tool's day header)
   are in the Gregorian calendar too. Where the text should keep the phone's language and 12/24-hour
   setting it comes from `FixedDateFormat.localized(dateStyle:timeStyle:timeZone:)` (the phone's locale,
   a Gregorian calendar, the styles); where it must match the Thunderbird add-on's English text it is a
   fixed pattern from `FixedDateFormat.formatter`. No `setLocalizedDateFormatFromTemplate` or
   `dateFormat(fromTemplate:)` anywhere: a template is a format too.
4. **On-device display that follows the phone** builds a `DateFormatter` with `dateStyle`/`timeStyle`
   only, or a date `FormatStyle`, at a site listed by name in the fence's display allow-list. A new site
   either uses `FixedDateFormat` or is added to the list with what it shows. SwiftUI
   `Text(date, style:)` is display and not listed.
5. `ISO8601DateFormatter` is Gregorian already and is not affected.
6. A stored `yyyy-MM-dd` day (a reminder's due date) is read with `FixedDateFormat.gregorianDay(_:timeZone:)`,
   and the day arithmetic around it uses `Calendar(identifier: .gregorian)`, never `Calendar.current`.
   The one phone-calendar use on those paths splits a notification's fire instant into the components
   a `UNCalendarNotificationTrigger` matches in the phone's calendar.

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

- `TabMailTests/Services/FixedDateFormatFenceTests.swift` reads the Swift source of every app and
  extension target listed in `project.yml` (test targets skipped) at run time, with comments and string
  contents ignored and interpolations kept as code, and fails on, outside `Shared/FixedDateFormat.swift`:
  a `dateFormat` set by `=`, `+=` (also split across lines), `override var`, key-value coding or a key
  path; a localized template; a `DateFormatter` built (also `= .init()`), subclassed or used through
  `DateFormatter.localizedString`, a `DateIntervalFormatter`, or a date `FormatStyle`
  (`.formatted(date:time:)`, `.dateTime`, `.interval`, `Date.FormatStyle`, `IntervalFormatStyle`,
  `VerbatimFormatStyle`), except at the named display-only sites (file and exact count). It fails on any
  `project.yml` source entry it cannot read (a bare name, an inline list, target templates, `include:`,
  a target without a type or a path), so no target leaves the scan silently, and on any phone-calendar
  reference inside `Shared/FixedDateFormat.swift` itself (the simulator is Gregorian, so behaviour tests
  alone cannot see one). On the four reminder due-date files it also fails on
  `Calendar.current` and its kin beyond the named trigger use, on a `DateComponents` year set by hand, and
  when the file no longer calls `FixedDateFormat.gregorianDay`. A self-test pins each pattern, including
  the comment, string, raw multi-line string and interpolation cases. It was red on the pre-fix source
  (96 `dateFormat` sites, the boundary `FormatStyle` and formatter sites, every due-date file).
- `TabMailTests/Services/FixedDateFormatTests.swift` presets a formatter to a non-Gregorian phone
  default (Buddhist with `th_TH`/`en_TH`, Japanese, Umm al-Qura with `en_SA`/`ar_SA`) and shows
  `FixedDateFormat.pin` still yields Gregorian, `en_US_POSIX` and the given zone, with exact round
  trips; it also formats a date built in a Buddhist calendar and checks the Gregorian year. It checks
  `localized` (Gregorian calendar, the locale's language, the locale's 12- or 24-hour clock) and
  `gregorianDay` (the Gregorian day, the Buddhist year 543 on, malformed values nil). The simulator's
  own locale and calendar are never switched.

## Not covered (reviewed, left as is)

`Calendar.current` used for whole-day or hour arithmetic, start-of-day and same-day checks gives the
same instants in every calendar the phone can use, so it is not this bug. A relative offset in years
(the IMAP search's one-year fallback window) is a shorter span on a lunar calendar but still encodes a
correct Gregorian date on the wire; it is a different, minor effect and was not changed.
