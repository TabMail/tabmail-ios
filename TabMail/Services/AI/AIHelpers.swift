/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension AIService {

    // MARK: - Date Formatting (matches TB's formatTimestampForAgent in helpers.js)

    /// Delegates to the shared `PromptFormatters` — single source of truth for both
    /// main app and NSE. Keeps the existing AIService.formatTimestampForAgent call
    /// sites (ComposeView, AIReply) compiling without churn.
    static func formatTimestampForAgent(_ date: Date) -> String {
        PromptFormatters.formatTimestampForAgent(date)
    }

    // MARK: - Unicode Normalization (matches TB's normalizeUnicode in utils.js)

    /// Normalizes Unicode to standard ASCII equivalents: NFKC normalization,
    /// curly quotes→straight, em/en-dashes→hyphen, special spaces→space, ellipsis→"...".
    static func normalizeUnicode(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping // NFKC
        // Dashes: en-dash, em-dash, figure dash, horizontal bar, minus sign, etc.
        s = s.replacingOccurrences(of: #"[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]"#,
                                   with: "-", options: .regularExpression)
        // Single curly quotes → straight
        s = s.replacingOccurrences(of: #"[\u{2018}\u{2019}\u{201B}\u{2032}\u{2035}]"#,
                                   with: "'", options: .regularExpression)
        // Double curly quotes → straight
        s = s.replacingOccurrences(of: #"[\u{201C}\u{201D}\u{201E}\u{201F}]"#,
                                   with: "\"", options: .regularExpression)
        // Fullwidth brackets
        s = s.replacingOccurrences(of: "\u{3010}", with: "[")
        s = s.replacingOccurrences(of: "\u{3011}", with: "]")
        // Various space characters → regular space
        s = s.replacingOccurrences(of: #"[\u{00A0}\u{202F}\u{2007}\u{2008}\u{2009}\u{200A}\u{200B}\u{2028}\u{2029}\u{205F}\u{3000}]"#,
                                   with: " ", options: .regularExpression)
        // Ellipsis → three dots
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")
        return s
    }
}
