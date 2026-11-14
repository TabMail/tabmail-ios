/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What an edit of every occurrence that moves a repeating series' last date earlier removes, for
/// its confirmation card (#718): `count` meetings after `after`, the new last date as the card
/// shows it.
struct SeriesEndRemoval: Sendable, Equatable {
    let count: Int
    let after: String
}

/// The count behind the card's "N meetings after <date> are removed." line, one function for every
/// calendar (#718, above the provider boundary, ADR-IOS-060): it reads only the series as already
/// read and the calendar's ordinary listing (`CalendarProvider.listEvents`), never which calendar
/// it is.
enum CalendarSeriesEndRemoval {

    private enum Config {
        /// How far before the new last date and after the stored one the listing reaches, in days,
        /// so an occurrence moved on its own a little way from its place is still counted by its
        /// place.
        static let listMarginDays = 7
        /// The most occurrences one listing returns.
        static let listLimit = 2_500
    }

    /// What the whole-series edit `edit` of `series` (`seriesId`, on `calendarId`) removes by
    /// ending the series earlier, nil when it does not: the edit's rule ends on a date (`UNTIL`)
    /// before the last date the stored rule ends on (its `UNTIL`). The occurrences the stored rule
    /// places after the new last date and up to the stored one, as the calendar lists them: each
    /// counted by its place in the series (`originalStartTime`, else its start), so a changed one
    /// counts where the series had it, and a deleted one is not listed, so it is not counted. Dates
    /// are read in the series' zone (`GCalEvent.seriesZone`); nil for a timed series whose zone
    /// can't be read. A series that ends after a count, or never, is not counted.
    static func removal(
        series: GCalEvent, seriesId: String, edit: GCalEventInput, calendarId: String, provider: any CalendarProvider
    ) async throws -> SeriesEndRemoval? {
        guard let editedUntil = untilValue(of: edit.recurrence), let storedUntil = untilValue(of: series.recurrence) else { return nil }
        let allDay = series.isAllDay
        let zone: TimeZone
        if allDay {
            zone = .gmt
        } else {
            guard let seriesZone = series.seriesZone else { return nil }
            zone = seriesZone
        }
        guard let newLast = day(ofUntil: editedUntil, zone: zone), let storedLast = day(ofUntil: storedUntil, zone: zone),
              newLast < storedLast else { return nil }
        let dayFormat = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let lastDate = dayFormat.date(from: newLast), let storedDate = dayFormat.date(from: storedLast),
              let from = calendar.date(byAdding: .day, value: 1 - Config.listMarginDays, to: lastDate),
              let to = calendar.date(byAdding: .day, value: 1 + Config.listMarginDays, to: storedDate) else { return nil }
        let listed = try await provider.listEvents(
            calendarId: calendarId, timeMin: from, timeMax: to, query: nil, singleEvents: true,
            maxResults: Config.listLimit, orderBy: "startTime")
        var removed = Set<String>()
        for event in listed where event.recurringEventId == seriesId && event.status != "cancelled" {
            guard let id = event.id, let place = event.originalStartTime ?? event.start,
                  let date = placeDay(place, allDay: allDay, zone: zone) else { continue }
            if date > newLast && date <= storedLast { removed.insert(id) }
        }
        let after = FixedDateFormat.formatter("MMMM d, yyyy", timeZone: zone).string(from: lastDate)
        return SeriesEndRemoval(count: removed.count, after: after)
    }

    /// The `UNTIL` value of the first RRULE of `lines`, nil when there is none.
    static func untilValue(of lines: [String]?) -> String? {
        guard let rule = lines?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else { return nil }
        for part in rule.dropFirst("RRULE:".count).split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].uppercased() == "UNTIL" { return String(pair[1]) }
        }
        return nil
    }

    /// The date (`yyyy-MM-dd`) an `UNTIL` value ends on in `zone`: a date as written, a UTC time
    /// (`Z`) dated in `zone`, a local time by its own date. Nil when it can't be read.
    static func day(ofUntil value: String, zone: TimeZone) -> String? {
        let compact = value.uppercased()
        if compact.count == 8, let date = FixedDateFormat.formatter("yyyyMMdd", timeZone: .gmt).date(from: compact) {
            return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt).string(from: date)
        }
        if compact.hasSuffix("Z"), let instant = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).date(from: compact) {
            return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone).string(from: instant)
        }
        if let local = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: .gmt).date(from: compact) {
            return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt).string(from: local)
        }
        return nil
    }

    /// The date an occurrence's place is on in the series' zone: an all-day date as written, a
    /// timed instant dated in `zone`.
    private static func placeDay(_ time: GCalDateTime, allDay: Bool, zone: TimeZone) -> String? {
        if let date = time.date { return String(date.prefix(10)) }
        guard let dateTime = time.dateTime else { return nil }
        if allDay { return String(dateTime.prefix(10)) }
        guard let instant = Date.fromISO8601(dateTime) else { return nil }
        return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone).string(from: instant)
    }
}
