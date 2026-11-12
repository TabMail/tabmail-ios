/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// `FixedDateFormat` is the one builder of fixed-format date formatters, so a phone set
/// to another calendar or locale can never change a date the app writes or reads.
///
/// The simulator's own locale and calendar are never switched here. The phone's
/// defaults are simulated by a formatter preset to them, and `FixedDateFormat.pin`
/// is the same code `FixedDateFormat.formatter` runs on a fresh formatter, whose
/// defaults are the phone's. Every date is relative to now.
@Suite("FixedDateFormat pins Gregorian, en_US_POSIX and the given zone")
struct FixedDateFormatTests {

    /// A phone setting that is not Gregorian: the locale and calendar a fresh
    /// `DateFormatter` would start with on such a phone.
    struct PhoneDefault: CustomStringConvertible, Sendable {
        let locale: String
        let calendar: Calendar.Identifier
        var description: String { "\(locale) / \(calendar)" }
    }

    static let phoneDefaults: [PhoneDefault] = [
        PhoneDefault(locale: "th_TH", calendar: .buddhist),
        PhoneDefault(locale: "en_TH", calendar: .buddhist),
        PhoneDefault(locale: "ja_JP", calendar: .japanese),
        PhoneDefault(locale: "en_SA", calendar: .islamicUmmAlQura),
        PhoneDefault(locale: "ar_SA", calendar: .islamicUmmAlQura),
    ]

    static let zones = ["UTC", "Asia/Bangkok", "America/New_York"]

    static func phoneFormatter(_ phone: PhoneDefault) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: phone.locale)
        formatter.calendar = Calendar(identifier: phone.calendar)
        return formatter
    }

    /// A moment a week ahead, whole seconds, so string round trips are exact.
    static func sampleDate() -> Date {
        let now = Date().addingTimeInterval(7 * 86_400)
        return Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    static func gregorianParts(_ date: Date, _ zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// The expected `yyyy-MM-dd'T'HH:mm:ss` text, built from Gregorian components
    /// rather than by any `DateFormatter`.
    static func expectedWall(_ date: Date, _ zone: TimeZone) -> String {
        let p = gregorianParts(date, zone)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
    }

    @Test("the simulated phone default really writes a non-Gregorian year (the premise)",
          arguments: phoneDefaults)
    func phoneDefaultIsNonGregorian(_ phone: PhoneDefault) throws {
        let formatter = Self.phoneFormatter(phone)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy"
        let date = Self.sampleDate()
        let gregorianYear = try #require(Self.gregorianParts(date, .gmt).year)
        #expect(formatter.calendar.identifier == phone.calendar)
        #expect(formatter.string(from: date) != String(gregorianYear),
                "\(phone) writes the Gregorian year already; this suite would prove nothing")
    }

    @Test("pin overrides a non-Gregorian phone default: calendar, locale and zone",
          arguments: phoneDefaults, zones)
    func pinIgnoresPhoneDefaults(_ phone: PhoneDefault, _ zoneID: String) throws {
        let zone = try #require(TimeZone(identifier: zoneID))
        let formatter = FixedDateFormat.pin(Self.phoneFormatter(phone),
                                            format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.timeZone == zone)
        #expect(formatter.calendar.timeZone == zone)
        #expect(formatter.dateFormat == "yyyy-MM-dd'T'HH:mm:ss")

        let date = Self.sampleDate()
        let wall = Self.expectedWall(date, zone)
        #expect(formatter.string(from: date) == wall)
        #expect(formatter.date(from: wall) == date)
    }

    @Test("the iCalendar UTC form carries the Gregorian year and ASCII digits",
          arguments: phoneDefaults)
    func icsUTCFormIsGregorian(_ phone: PhoneDefault) {
        let formatter = FixedDateFormat.pin(Self.phoneFormatter(phone),
                                            format: "yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt)
        let date = Self.sampleDate()
        let p = Self.gregorianParts(date, .gmt)
        let expected = String(format: "%04d%02d%02dT%02d%02d%02dZ",
                              p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
        #expect(formatter.string(from: date) == expected)
    }

    @Test("formatter(_:timeZone:) returns a pinned formatter in the given zone", arguments: zones)
    func formatterIsPinned(_ zoneID: String) throws {
        let zone = try #require(TimeZone(identifier: zoneID))
        let formatter = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone)
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.timeZone == zone)
        let date = Self.sampleDate()
        #expect(formatter.string(from: date) == String(Self.expectedWall(date, zone).prefix(10)))
    }

    @Test("a date built in the Buddhist calendar formats with its Gregorian year and round-trips",
          arguments: zones)
    func buddhistDateRoundTripsAsGregorian(_ zoneID: String) throws {
        let zone = try #require(TimeZone(identifier: zoneID))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = zone
        let reference = Self.sampleDate()
        let parts = buddhist.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: reference)
        let buddhistDate = try #require(buddhist.date(from: parts))
        let gregorianYear = try #require(Self.gregorianParts(buddhistDate, zone).year)
        // The Buddhist era runs 543 years ahead of the Gregorian one.
        #expect(parts.year == gregorianYear + 543)

        let formatter = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)
        let text = formatter.string(from: buddhistDate)
        #expect(text == Self.expectedWall(buddhistDate, zone))
        #expect(text.hasPrefix(String(format: "%04d-", gregorianYear)))
        #expect(formatter.date(from: text) == buddhistDate)
    }

    @Test("gregorianDay reads a stored yyyy-MM-dd as that Gregorian day in the zone", arguments: zones)
    func gregorianDayIsTheGregorianDay(_ zoneID: String) throws {
        let zone = try #require(TimeZone(identifier: zoneID))
        let p = Self.gregorianParts(Self.sampleDate(), zone)
        let stored = String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
        let day = try #require(FixedDateFormat.gregorianDay(stored, timeZone: zone))

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        #expect(day == gregorian.startOfDay(for: Self.sampleDate()))
        #expect(Self.gregorianParts(day, zone).year == p.year)
        // The same instant in the Buddhist calendar is 543 years on: the stored year
        // was read as Gregorian, not as a Buddhist year.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = zone
        #expect(buddhist.component(.year, from: day) == p.year! + 543)
    }

    @Test("gregorianDay returns nil unless the value is three dash-separated integers",
          arguments: ["", "2026-11", "a-b-c", "2026/11/20", "2026-11-20-1"])
    func gregorianDayRejectsMalformed(_ value: String) {
        #expect(FixedDateFormat.gregorianDay(value, timeZone: .gmt) == nil)
    }

    @Test("localized keeps the locale's language but counts years in the Gregorian calendar",
          arguments: phoneDefaults, zones)
    func localizedIsGregorian(_ phone: PhoneDefault, _ zoneID: String) throws {
        let zone = try #require(TimeZone(identifier: zoneID))
        let locale = Locale(identifier: phone.locale)
        let formatter = FixedDateFormat.localized(dateStyle: .long, timeStyle: .short,
                                                  timeZone: zone, locale: locale)
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.calendar.timeZone == zone)
        #expect(formatter.timeZone == zone)
        #expect(formatter.locale.identifier == phone.locale)
        #expect(formatter.dateFormat.isEmpty == false)

        let date = Self.sampleDate()
        let phoneStyle = Self.phoneFormatter(phone)
        phoneStyle.timeZone = zone
        phoneStyle.dateStyle = .long
        phoneStyle.timeStyle = .short
        #expect(formatter.string(from: date) != phoneStyle.string(from: date),
                "\(phone): the localized form matches the phone's own calendar")
        if locale.numberingSystem.identifier == "latn" {
            let year = try #require(Self.gregorianParts(date, zone).year)
            #expect(formatter.string(from: date).contains(String(year)))
        }
    }

    @Test("localized honours the locale's 12- or 24-hour clock")
    func localizedHonoursHourCycle() throws {
        let date = Self.sampleDate()
        let twelve = FixedDateFormat.localized(dateStyle: .none, timeStyle: .short, timeZone: .gmt,
                                               locale: Locale(identifier: "en_US")).string(from: date)
        let twentyFour = FixedDateFormat.localized(dateStyle: .none, timeStyle: .short, timeZone: .gmt,
                                                   locale: Locale(identifier: "en_GB")).string(from: date)
        #expect(twelve.contains("AM") || twelve.contains("PM"), "en_US short time: \(twelve)")
        #expect(!twentyFour.contains("AM") && !twentyFour.contains("PM"), "en_GB short time: \(twentyFour)")
    }
}
