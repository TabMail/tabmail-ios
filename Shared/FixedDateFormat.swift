/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The one place a fixed-format `DateFormatter` is built.
///
/// A `DateFormatter` with a `dateFormat` follows the phone's locale and calendar
/// unless both are pinned. On a phone set to the Buddhist calendar (the default
/// for the Thailand region) `yyyy` writes 2569 for 2026, and a parse of
/// `2026-11-20` reads a year 543 years back; the Japanese and Islamic calendars
/// give other wrong years, and some locales give non-ASCII digits. Every date the
/// app writes to or reads from a server, a stored record or a tool argument is
/// therefore formatted and parsed in the Gregorian calendar with the
/// `en_US_POSIX` locale (Apple QA1480), whatever the phone's settings are.
///
/// The time zone is a required argument so no caller inherits the device zone
/// by accident; a caller that means the device zone passes `.current`.
///
/// Human-readable dates that leave the device or reach the assistant (an invite's
/// "When:", a reply's attribution line, an attached message's "Date:") keep the
/// phone's language and 12/24-hour setting but count years in the Gregorian
/// calendar too: `localized(dateStyle:timeStyle:timeZone:)`. A stored `yyyy-MM-dd`
/// day is read by `gregorianDay(_:timeZone:)`.
///
/// `FixedDateFormatFenceTests` reads every target's source and fails on a
/// `dateFormat` set, a localized template, or a date `FormatStyle` outside this
/// file, and on a `DateFormatter` built outside it except at the named
/// display-only sites, which follow the phone.
enum FixedDateFormat {

    /// A formatter for `format`: `en_US_POSIX`, the Gregorian calendar, and `timeZone`.
    /// A new instance per call, so a caller may cache it or use it once.
    static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        pin(DateFormatter(), format: format, timeZone: timeZone)
    }

    /// Pins `formatter`, whatever locale and calendar it started with (the phone's,
    /// in production), to `en_US_POSIX`, Gregorian and `timeZone`, then sets
    /// `format`. Both are set: the locale fixes the digits and month names, and
    /// the calendar the year. A calendar already set on a formatter survives a
    /// later locale change, so the locale alone would not undo it.
    static func pin(_ formatter: DateFormatter, format: String, timeZone: TimeZone) -> DateFormatter {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// A localized formatter in the Gregorian calendar: `locale`'s language, order and
    /// 12/24-hour setting (the phone's by default), `dateStyle`/`timeStyle`, `timeZone`.
    /// For human-readable text that leaves the device or reaches the assistant.
    static func localized(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        timeZone: TimeZone,
        locale: Locale = .autoupdatingCurrent
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    /// The start, in `timeZone`, of the day a stored Gregorian `yyyy-MM-dd` names (a
    /// reminder's due date). Nil unless the value is three `-`-separated integers; an
    /// out-of-range month or day rolls over, as `Calendar.date(from:)` does. Read in the
    /// Gregorian calendar whatever the phone's calendar is.
    static func gregorianDay(_ ymd: String, timeZone: TimeZone) -> Date? {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
