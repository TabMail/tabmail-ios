/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// NSE response parser — delegates to shared AIResponseParser.
/// Single source of truth in Shared/AIResponseParser.swift.
enum NSEResponseParser {
    typealias SummaryResult = AIResponseParser.SummaryResult

    static func parseSummary(_ text: String) -> SummaryResult {
        AIResponseParser.parseSummaryResponse(text)
    }
}
