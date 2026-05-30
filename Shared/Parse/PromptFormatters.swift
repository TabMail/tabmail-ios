/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure date/text formatters shared across main app and NSE for AI prompt construction.
/// Matches TB addon's `formatTimestampForAgent` in `helpers.js` — format parity is
/// required for prompt consistency (backend templates expect this exact shape).
enum PromptFormatters {
    /// Produces "Wednesday 2026/02/20 14:30:45 PT (America/Los_Angeles)" — the
    /// trailing IANA identifier disambiguates abbreviations the model may not
    /// recognize (e.g. KST, JST, GMT+9).
    static func formatTimestampForAgent(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let dayOfWeek = dayNames[(comps.weekday ?? 1) - 1]
        let yyyy = String(comps.year ?? 2026)
        let mm = String(format: "%02d", comps.month ?? 1)
        let dd = String(format: "%02d", comps.day ?? 1)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let min = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let tzAbbr = genericTimezoneAbbr(for: date, timeZone: timeZone)
        return "\(dayOfWeek) \(yyyy)/\(mm)/\(dd) \(hh):\(min):\(ss) \(tzAbbr) (\(timeZone.identifier))"
    }

    /// Weekday name for the given date ("Wednesday"). Used for the
    /// `email_day_of_week` prompt variable.
    static func dayOfWeek(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.weekday], from: date)
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return dayNames[(comps.weekday ?? 1) - 1]
    }

    /// IANA → generic abbreviation map. Mirrors TB's `TIMEZONE_GENERIC_MAP` in
    /// `tabmail-thunderbird/chat/modules/helpers.js`. Hits this map first so the
    /// abbreviation is deterministic regardless of what `TimeZone.abbreviation`
    /// returns on a given OS build.
    private static let timezoneGenericMap: [String: String] = [
        // Pacific Time
        "America/Los_Angeles": "PT",
        "America/Vancouver": "PT",
        "America/Tijuana": "PT",
        "US/Pacific": "PT",
        "Canada/Pacific": "PT",
        // Mountain Time
        "America/Denver": "MT",
        "America/Phoenix": "MST", // Arizona doesn't observe DST
        "America/Edmonton": "MT",
        "US/Mountain": "MT",
        "Canada/Mountain": "MT",
        // Central Time (US/Canada)
        "America/Chicago": "CT",
        "America/Winnipeg": "CT",
        "America/Mexico_City": "CT",
        "US/Central": "CT",
        "Canada/Central": "CT",
        // Eastern Time
        "America/New_York": "ET",
        "America/Toronto": "ET",
        "US/Eastern": "ET",
        "Canada/Eastern": "ET",
        // Other common zones
        "UTC": "UTC",
        "Europe/London": "GMT",
        "Europe/Paris": "CET",
        "Asia/Seoul": "KST",
        "Asia/Tokyo": "JST",
        "Australia/Sydney": "AEST",
    ]

    /// Generic timezone abbreviation (PT not PDT/PST). Mirrors TB's
    /// `getGenericTimezoneAbbr`: explicit DST-pair collapse, never a `hasSuffix`
    /// rule. The old `count == 3 && hasSuffix("ST")` rule corrupted KST→KT,
    /// JST→JT, IST→IT, etc.
    private static func genericTimezoneAbbr(for date: Date, timeZone: TimeZone = .current) -> String {
        if let mapped = timezoneGenericMap[timeZone.identifier] {
            return mapped
        }
        let abbr = timeZone.abbreviation(for: date) ?? "UTC"
        switch abbr {
        case "PDT", "PST": return "PT"
        case "MDT", "MST": return "MT"
        case "CDT", "CST": return "CT"
        case "EDT", "EST": return "ET"
        default: return abbr
        }
    }
}
