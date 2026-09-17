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

    /// The timestamp of one `Received:` trace header (RFC 5322 §3.6.7:
    /// `"Received:" *received-token ";" date-time CRLF`). The date is everything
    /// after the LAST `;` that sits OUTSIDE a comment — received-tokens and the
    /// CFWS around the date may both carry comments, comments nest, and a
    /// quoted-pair (`\)`) inside one does not close it (§3.2.2). Comments are
    /// then removed from the tail before `RFC5322Parse.parseRFC5322Date` reads
    /// it, so `+0000 (UTC)`, `(envelope-from x; y)` and folded whitespace all
    /// parse.
    ///
    /// Returns nil when the header carries no top-level `;` or the tail does not
    /// parse. Callers decide what a nil means; on Gmail `GmailParse.parseMessage`
    /// keeps `internalDate` (the owner-approved fallback), never `Date()`.
    static func receivedHeaderDate(_ raw: String) -> Date? {
        // One pass: track comment depth and quoted-pairs; remember the last
        // top-level `;`. A second pass over the tail drops the comments.
        var depth = 0
        var escaped = false
        var lastTopLevelSemicolon: String.Index? = nil
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth = max(0, depth - 1)
            } else if ch == ";" && depth == 0 {
                lastTopLevelSemicolon = index
            }
            index = raw.index(after: index)
        }
        guard let semicolon = lastTopLevelSemicolon else { return nil }

        var tail = ""
        depth = 0
        escaped = false
        index = raw.index(after: semicolon)
        while index < raw.endIndex {
            let ch = raw[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                tail.append(ch)
            }
            index = raw.index(after: index)
        }
        var tokens = tail
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        normalizeObsoleteYear(&tokens)
        guard !tokens.isEmpty else { return nil }
        return RFC5322Parse.parseRFC5322Date(tokens.joined(separator: " "))
    }

    /// RFC 5322 §4.3 `obs-year`: a two-digit year is 1900-based when ≥ 50 and
    /// 2000-based otherwise; a three-digit year is 1900-based. Left as-is, the
    /// shared formatter accepts `26` as the year 26 AD, which would sink the
    /// message to the bottom of the folder instead of falling back to the
    /// provider date. Only the token in the `day month YEAR` position is touched.
    private static func normalizeObsoleteYear(_ tokens: inout [String]) {
        guard tokens.count >= 3 else { return }
        for i in 0..<(tokens.count - 2) {
            let day = tokens[i], month = tokens[i + 1], year = tokens[i + 2]
            guard (1...2).contains(day.count), day.allSatisfy(\.isNumber),
                  month.count == 3, month.allSatisfy(\.isLetter),
                  (2...3).contains(year.count), year.allSatisfy(\.isNumber),
                  let value = Int(year) else { continue }
            let normalized = year.count == 2 ? (value >= 50 ? 1900 + value : 2000 + value) : 1900 + value
            tokens[i + 2] = String(normalized)
            return
        }
    }
}
