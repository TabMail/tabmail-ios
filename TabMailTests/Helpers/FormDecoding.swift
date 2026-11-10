/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Reads a query string or an `application/x-www-form-urlencoded` body the way
/// a server does: `&` separates fields, the first `=` ends a name, `+` is a
/// space, and then percent escapes are decoded. A value that cannot be decoded
/// reads as `<undecodable>`.
enum FormDecoding {
    static func fields(_ raw: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decoded(parts[0]) ?? "<undecodable>"
            let value = parts.count == 2 ? decoded(parts[1]) ?? "<undecodable>" : ""
            fields[name, default: []].append(value)
        }
        return fields
    }

    private static func decoded(_ raw: Substring) -> String? {
        raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
