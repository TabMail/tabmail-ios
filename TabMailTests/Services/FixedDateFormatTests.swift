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
}
