/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared RFC 2822 date parser for email headers. ISO 8601 parsing lives on
/// `Date.fromISO8601` in `DateFormatting.swift` — use that for Graph
/// `receivedDateTime` and other RFC 3339 / ISO 8601 fields.
enum EmailDateParsing {
    /// RFC 2822 §3.3 date format, e.g. `"Wed, 2 Oct 2025 01:50:00 +0000"`.
    /// Source: RFC 2822 / RFC 5322 §3.3.
    static let rfc2822: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return fmt
    }()
}
