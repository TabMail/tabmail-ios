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
    /// curly quotes→straight, line-start dash bullets→hyphen (inline dashes kept),
    /// special spaces→space, ellipsis→"...".
    static func normalizeUnicode(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping // NFKC
        // Dashes: normalize to a standard hyphen ONLY at the start of a line (after
        // optional indentation). LLMs frequently emit en/em-dash bullets ("– item")
        // instead of "- item", and the summary/action/KB parsers rely on the bullet
        // being an ASCII hyphen. Inline dashes (em-dashes used as prose punctuation)
        // are deliberately left intact so proper typography survives in summaries and
        // chat. Mirrors TB's normalizeUnicode in utils.js.
        //
        // NOTE: iOS compose/reply text is intentionally NOT run through
        // normalizeUnicode (see AIReply) — unlike TB there is no inline-autocomplete
        // diff to keep ASCII-clean, and email is sent as HTML, so the model's real
        // typography (em-dashes, curly quotes) should reach the recipient as-is.
        //
        // Uses ICU \x{...} (brace-hex), NOT \u{...}: in a Swift raw string the latter
        // reaches ICU verbatim and is not a valid code-point escape, so the class
        // would silently match nothing.
        s = s.replacingOccurrences(of: #"(^|\n)([ \t]*)[\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]"#,
                                   with: "$1$2-", options: .regularExpression)
        // Single curly quotes + primes → straight apostrophe. ICU \x{...} (see the
        // dash note above) — \u{...} in a raw string silently matches nothing.
        s = s.replacingOccurrences(of: #"[\x{2018}\x{2019}\x{201B}\x{2032}\x{2035}]"#,
                                   with: "'", options: .regularExpression)
        // Double curly quotes → straight
        s = s.replacingOccurrences(of: #"[\x{201C}\x{201D}\x{201E}\x{201F}]"#,
                                   with: "\"", options: .regularExpression)
        // Fullwidth brackets
        s = s.replacingOccurrences(of: "\u{3010}", with: "[")
        s = s.replacingOccurrences(of: "\u{3011}", with: "]")
        // Various space characters → regular space (ICU \x{...}, see dash note).
        s = s.replacingOccurrences(of: #"[\x{00A0}\x{202F}\x{2007}\x{2008}\x{2009}\x{200A}\x{200B}\x{2028}\x{2029}\x{205F}\x{3000}]"#,
                                   with: " ", options: .regularExpression)
        // Ellipsis → three dots
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")
        return s
    }
}
