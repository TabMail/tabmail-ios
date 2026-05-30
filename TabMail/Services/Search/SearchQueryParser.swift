/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// FTS5 query builder with email-specific syntax handling.
// Ported from tabmail-native-fts/src/fts/query.rs.

enum SearchQueryParser {

    /// Build an FTS5 MATCH expression from a user query string.
    /// Handles field aliases, quoted phrases, synonym expansion, auto-wildcards.
    static func buildFTSMatch(_ query: String?) -> String {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ""
        }
        let q = query.trimmingCharacters(in: .whitespaces)

        // 1. Translate field aliases: from: → from_:, to: → to_:
        var translated = translateAliases(q)

        // 2. Extract field:"quoted value" segments before splitting by quotes
        var fieldQuotedMatches: [(String, String)] = []
        translated = extractFieldQuoted(translated, store: &fieldQuotedMatches)

        // 3. Split by unescaped quotes
        let parts = translated.components(separatedBy: "\"")
        var output: [String] = []

        for (idx, part) in parts.enumerated() {
            let isQuoted = idx % 2 == 1
            if isQuoted {
                output.append("\"\(part)\"")
                continue
            }

            let tokens = part.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var mapped: [String] = []

            let willHaveOrGroups = tokens.contains { willExpandToOrGroup($0, fieldQuotedMatches: fieldQuotedMatches) }

            for tok in tokens {
                // Check for field-quoted placeholder
                if let (field, val) = placeholderFieldQuoted(tok, store: fieldQuotedMatches) {
                    mapped.append("\(field):\"\(val)\"")
                    continue
                }

                // Skip pure punctuation
                if isPurePunctuation(tok) {
                    continue
                }

                let (field, rawValue) = splitField(tok)
                var value = rawValue

                // If value already quoted, preserve as-is
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    var fv = ""
                    if let f = field { fv += "\(f):" }
                    fv += value
                    mapped.append(fv)
                    continue
                }

                // Check for existing wildcard
                let hasWildcard = value.hasSuffix("*")
                if hasWildcard {
                    value = String(value.dropLast())
                }

                // Trim trailing slashes and question marks
                let core = trimTrailingSlashQuestion(value)

                // Remove apostrophes for FTS5 compatibility
                var escapedCore = core.replacingOccurrences(of: "'", with: "")

                // Handle naked wildcard "*": convert to "."
                if escapedCore.isEmpty && hasWildcard {
                    escapedCore = "."
                }

                let needsQuote = hasSpecialCharsRequiringQuotes(escapedCore)

                let finalToken: String
                if needsQuote {
                    let escaped = escapedCore.replacingOccurrences(of: "\"", with: "\"\"")
                    finalToken = "\"\(escaped)\""
                } else {
                    // Auto-add wildcard for tokens >= 4 chars, but avoid if OR groups exist
                    if !hasWildcard && escapedCore.count >= 4 && !willHaveOrGroups {
                        finalToken = "\(escapedCore)*"
                    } else if hasWildcard {
                        finalToken = "\(escapedCore)*"
                    } else {
                        finalToken = escapedCore
                    }
                }

                if let f = field {
                    mapped.append("\(f):\(finalToken)")
                } else if !hasWildcard && !needsQuote && !finalToken.isEmpty {
                    let expanded = SearchSynonyms.expand(finalToken)
                    mapped.append(expanded)
                } else {
                    mapped.append(finalToken)
                }
            }

            if !mapped.isEmpty {
                let hasOrGroups = mapped.contains { $0.contains("(") && $0.contains(" OR ") }
                if hasOrGroups {
                    output.append(mapped.joined(separator: " AND "))
                } else {
                    output.append(mapped.joined(separator: " "))
                }
            }
        }

        return output.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Field alias translation

    private static func translateAliases(_ q: String) -> String {
        let bytes = Array(q.utf8)
        var out = ""
        var i = 0

        while i < bytes.count {
            if startsWordAt(bytes, i: i, needle: Array("from".utf8)) {
                let end = i + 4
                var j = end
                while j < bytes.count && bytes[j] == 0x20 { j += 1 }  // skip spaces
                if j < bytes.count && bytes[j] == 0x3A {  // ':'
                    out += "from_:"
                    i = j + 1
                    continue
                }
            }
            if startsWordAt(bytes, i: i, needle: Array("to".utf8)) {
                let end = i + 2
                var j = end
                while j < bytes.count && bytes[j] == 0x20 { j += 1 }
                if j < bytes.count && bytes[j] == 0x3A {
                    out += "to_:"
                    i = j + 1
                    continue
                }
            }
            out.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }

        return out
    }

    private static func startsWordAt(_ haystack: [UInt8], i: Int, needle: [UInt8]) -> Bool {
        guard i + needle.count <= haystack.count else { return false }
        // Word boundary check
        if i > 0 {
            let prev = haystack[i - 1]
            let ch = Character(UnicodeScalar(prev))
            if ch.isLetter || ch.isNumber || prev == 0x5F { return false }  // '_'
        }
        for k in 0..<needle.count {
            let h = haystack[i + k]
            let n = needle[k]
            // Case-insensitive compare
            let hLower = (h >= 0x41 && h <= 0x5A) ? h + 32 : h
            let nLower = (n >= 0x41 && n <= 0x5A) ? n + 32 : n
            if hLower != nLower { return false }
        }
        return true
    }

    // MARK: - Field-quoted extraction

    private static func extractFieldQuoted(_ q: String, store: inout [(String, String)]) -> String {
        let bytes = Array(q.utf8)
        var out = ""
        var i = 0

        while i < bytes.count {
            if isIdentStart(bytes[i]) {
                let startIdent = i
                var j = i + 1
                while j < bytes.count && isIdentChar(bytes[j]) { j += 1 }
                if j < bytes.count && bytes[j] == 0x3A && (j + 1) < bytes.count && bytes[j + 1] == 0x22 {
                    // field:"value" pattern
                    var k = j + 2
                    while k < bytes.count && bytes[k] != 0x22 { k += 1 }
                    if k < bytes.count && bytes[k] == 0x22 {
                        let field = String(bytes: Array(bytes[startIdent..<j]), encoding: .utf8) ?? ""
                        let val = String(bytes: Array(bytes[(j + 2)..<k]), encoding: .utf8) ?? ""
                        let placeholder = "__FQ\(store.count)__"
                        store.append((field, val))
                        out += placeholder
                        i = k + 1
                        continue
                    }
                }
            }
            out.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }

        return out
    }

    private static func isIdentStart(_ b: UInt8) -> Bool {
        let ch = Character(UnicodeScalar(b))
        return ch.isLetter || b == 0x5F  // '_'
    }

    private static func isIdentChar(_ b: UInt8) -> Bool {
        let ch = Character(UnicodeScalar(b))
        return ch.isLetter || ch.isNumber || b == 0x5F
    }

    // MARK: - Placeholder handling

    private static func placeholderFieldQuoted(_ tok: String, store: [(String, String)]) -> (String, String)? {
        guard let idx = parsePlaceholder(tok), idx < store.count else { return nil }
        return store[idx]
    }

    private static func parsePlaceholder(_ tok: String) -> Int? {
        guard tok.hasPrefix("__FQ") && tok.hasSuffix("__") else { return nil }
        let inner = tok.dropFirst(4).dropLast(2)
        return Int(inner)
    }

    // MARK: - Token helpers

    private static func isPurePunctuation(_ tok: String) -> Bool {
        tok.allSatisfy { !$0.isLetter && !$0.isNumber && $0 != "_" }
    }

    private static func splitField(_ tok: String) -> (String?, String) {
        guard let colonIdx = tok.firstIndex(of: ":") else {
            return (nil, tok)
        }
        let field = String(tok[tok.startIndex..<colonIdx])
        let rest = String(tok[tok.index(after: colonIdx)...])
        if !field.isEmpty && (field.first!.isLetter || field.first == "_") {
            return (field, rest)
        }
        return (nil, tok)
    }

    private static func trimTrailingSlashQuestion(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c == "/" || c == "?" {
                end = prev
            } else {
                break
            }
        }
        return String(s[s.startIndex..<end])
    }

    private static func hasSpecialCharsRequiringQuotes(_ s: String) -> Bool {
        s.contains(where: { $0 == "-" || $0 == "@" || $0 == ":" || $0 == "+" || $0 == "." })
    }

    private static func willExpandToOrGroup(_ tok: String, fieldQuotedMatches: [(String, String)]) -> Bool {
        if parsePlaceholder(tok) != nil || isPurePunctuation(tok) { return false }
        let (field, rawValue) = splitField(tok)
        if field != nil { return false }
        var value = rawValue
        if value.hasPrefix("\"") && value.hasSuffix("\"") { return false }
        let hasWildcard = value.hasSuffix("*")
        if hasWildcard { value = String(value.dropLast()) }
        let core = trimTrailingSlashQuestion(value)
        let escaped = core.replacingOccurrences(of: "'", with: "")
        if escaped.isEmpty { return false }
        if hasWildcard || hasSpecialCharsRequiringQuotes(escaped) { return false }
        return SearchSynonyms.wouldExpand(escaped)
    }
}
