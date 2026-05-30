/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EKEventStoreHelper Date Formatting")
struct EKEventStoreHelperTests {

    @Test("toNaiveISO round-trips with parseNaiveISO")
    func roundTrip() {
        let date = Date(timeIntervalSince1970: 1710500400) // 2024-03-15 some time
        let iso = EKEventStoreHelper.toNaiveISO(date)
        let parsed = EKEventStoreHelper.parseNaiveISO(iso)
        #expect(parsed != nil)
        // Round-trip should produce same time (within 1 second due to format truncation)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince(date)) < 1)
        }
    }

    @Test("toNaiveISO format is yyyy-MM-ddTHH:mm:ss")
    func naiveISOFormat() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01
        let iso = EKEventStoreHelper.toNaiveISO(date)
        // Should contain T separator and no timezone offset
        #expect(iso.contains("T"))
        #expect(!iso.contains("Z"))
        #expect(!iso.contains("+"))
    }

    @Test("parseNaiveISO handles date-only format")
    func parseDateOnly() {
        let parsed = EKEventStoreHelper.parseNaiveISO("2024-03-15")
        #expect(parsed != nil)
    }

    @Test("parseNaiveISO handles full datetime")
    func parseFullDatetime() {
        let parsed = EKEventStoreHelper.parseNaiveISO("2024-03-15T10:30:00")
        #expect(parsed != nil)
    }

    @Test("parseNaiveISO returns nil for invalid input")
    func parseInvalid() {
        #expect(EKEventStoreHelper.parseNaiveISO("not-a-date") == nil)
        #expect(EKEventStoreHelper.parseNaiveISO("") == nil)
    }

    @Test("dayKey format is yyyy-MM-dd")
    func dayKeyFormat() {
        let date = Date(timeIntervalSince1970: 1710500400)
        let key = EKEventStoreHelper.dayKey(date)
        #expect(key.count == 10) // yyyy-MM-dd
        #expect(key.contains("-"))
        #expect(!key.contains("T"))
    }

    @Test("prettyDate returns non-empty string")
    func prettyDateNonEmpty() {
        let date = Date()
        let pretty = EKEventStoreHelper.prettyDate(date)
        #expect(!pretty.isEmpty)
    }

    @Test("prettyDate contains day name")
    func prettyDateContainsDayName() {
        // Create a known date: March 15, 2024 is a Friday
        let components = DateComponents(year: 2024, month: 3, day: 15)
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        let pretty = EKEventStoreHelper.prettyDate(date)
        #expect(pretty.contains("Friday") || pretty.contains("friday"))
    }

    @Test("dayKey same for dates on same day")
    func dayKeySameDay() {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        #expect(EKEventStoreHelper.dayKey(morning) == EKEventStoreHelper.dayKey(evening))
    }

    @Test("preferredCalendarKey is defined")
    func preferredCalendarKey() {
        #expect(!EKEventStoreHelper.preferredCalendarKey.isEmpty)
    }
}

@Suite("EKEventStoreHelper Timezone-Aware Overloads")
struct EKEventStoreHelperTimezoneTests {

    @Test("parseNaiveISO with explicit timezone differs from device timezone")
    func parseWithTimezone() {
        // Parse "2024-06-15T12:00:00" in Tokyo (UTC+9) vs LA (UTC-7)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let dateTokyo = EKEventStoreHelper.parseNaiveISO("2024-06-15T12:00:00", timeZone: tokyo)
        let dateLa = EKEventStoreHelper.parseNaiveISO("2024-06-15T12:00:00", timeZone: la)
        #expect(dateTokyo != nil)
        #expect(dateLa != nil)
        // Same naive string in different timezones should produce different absolute times
        // Tokyo noon is 16 hours earlier in absolute UTC than LA noon
        if let t = dateTokyo, let l = dateLa {
            let diffHours = l.timeIntervalSince(t) / 3600
            #expect(abs(diffHours - 16) < 1) // ~16 hours apart (9 ahead + 7 behind)
        }
    }

    @Test("parseNaiveISO timezone overload handles date-only format")
    func parseTimezoneDate() {
        let tz = TimeZone(identifier: "Europe/London")!
        let parsed = EKEventStoreHelper.parseNaiveISO("2024-03-15", timeZone: tz)
        #expect(parsed != nil)
    }

    @Test("toNaiveISO with explicit timezone round-trips")
    func toNaiveISOTimezone() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let date = Date(timeIntervalSince1970: 1710500400)
        let iso = EKEventStoreHelper.toNaiveISO(date, timeZone: tz)
        let parsed = EKEventStoreHelper.parseNaiveISO(iso, timeZone: tz)
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince(date)) < 1)
        }
    }

    @Test("dayKey with explicit timezone differs across date boundary")
    func dayKeyTimezone() {
        // 2024-03-15 23:30 UTC = 2024-03-16 08:30 Tokyo
        let date = Date(timeIntervalSince1970: 1710545400)
        let utc = TimeZone(identifier: "UTC")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let keyUTC = EKEventStoreHelper.dayKey(date, timeZone: utc)
        let keyTokyo = EKEventStoreHelper.dayKey(date, timeZone: tokyo)
        #expect(keyUTC == "2024-03-15")
        #expect(keyTokyo == "2024-03-16")
    }

    @Test("prettyDate with explicit timezone returns non-empty")
    func prettyDateTimezone() {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let pretty = EKEventStoreHelper.prettyDate(Date(), timeZone: tz)
        #expect(!pretty.isEmpty)
    }
}
