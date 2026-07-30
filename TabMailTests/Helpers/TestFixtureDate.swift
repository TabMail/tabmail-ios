/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// One process-relative date anchor for fixtures that need stable ordering
/// without hardcoding a calendar date that will eventually become stale.
enum TestFixtureDate {
    static let anchor = Date()

    static func daysFromAnchor(_ days: Int) -> Date {
        anchor.addingTimeInterval(TimeInterval(days * 86_400))
    }

    static func milliseconds(daysFromAnchor days: Int = 0) -> Int64 {
        Int64((daysFromAnchor(days).timeIntervalSince1970 * 1_000).rounded())
    }

    static func iso8601(daysFromAnchor days: Int = 0) -> String {
        ISO8601DateFormatter().string(from: daysFromAnchor(days))
    }

    static func iso8601Date(daysFromAnchor days: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: daysFromAnchor(days))
    }

    static func rfc2822(daysFromAnchor days: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: daysFromAnchor(days))
    }
}
