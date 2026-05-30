/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Backfill Date Alignment")
struct BackfillDateAlignmentTests {

    @Test("UTC midnight alignment rounds down")
    func utcMidnightAlignment() {
        // Create a date with time component
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let components = DateComponents(year: 2024, month: 3, day: 15, hour: 14, minute: 30, second: 45)
        let date = calendar.date(from: components)!

        // Align to UTC midnight
        let midnight = calendar.startOfDay(for: date)
        let midnightComponents = calendar.dateComponents([.hour, .minute, .second], from: midnight)

        #expect(midnightComponents.hour == 0)
        #expect(midnightComponents.minute == 0)
        #expect(midnightComponents.second == 0)
    }

    @Test("1-day overlap between consecutive windows")
    func oneDayOverlap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let windowStart = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15))!
        let searchSince = calendar.date(byAdding: .day, value: -1, to: windowStart)!

        let expectedOverlapDate = calendar.date(from: DateComponents(year: 2024, month: 3, day: 14))!
        #expect(searchSince == expectedOverlapDate)
    }

    @Test("Date alignment uses UTC, not local timezone")
    func usesUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let date = Date()
        let utcMidnight = calendar.startOfDay(for: date)

        // UTC midnight should be at 00:00:00 UTC
        let utcComponents = calendar.dateComponents([.hour, .minute, .second], from: utcMidnight)
        #expect(utcComponents.hour == 0)
    }

    @Test("BackfillProfile inter-batch delay ordering")
    func interBatchDelayOrdering() {
        // More aggressive profiles have shorter delays
        let lowDelay = BackfillProfile.low.imapInterBatchDelay
        let normalDelay = BackfillProfile.normal.imapInterBatchDelay
        let aggressiveDelay = BackfillProfile.aggressive.imapInterBatchDelay
        let turboDelay = BackfillProfile.turbo.imapInterBatchDelay

        #expect(lowDelay >= normalDelay)
        #expect(normalDelay >= aggressiveDelay)
        #expect(aggressiveDelay >= turboDelay)
    }
}
