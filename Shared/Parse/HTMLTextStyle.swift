/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The CSS the HTML-to-text conversion reads (#251), and nothing else: whether an
/// element is hidden, how it treats white space, and whether its top and bottom
/// margins are zero. A property left nil was not set.
struct HTMLTextStyle: Equatable {
    enum WhiteSpace: Equatable {
        /// `normal`, `nowrap`: a run of white space is one space.
        case collapse
        /// `pre`, `pre-wrap`, `break-spaces`: every space and line feed is kept.
        case preserve
        /// `pre-line`: a run of spaces is one space; line feeds are kept.
        case preserveLineFeeds
    }

    var hidden: Bool?
    var whiteSpace: WhiteSpace?
    /// Whether the margin is nonzero, in any unit. Only zero or not matters.
    var marginTop: Bool?
    var marginBottom: Bool?

    init() {}

    /// Reads a declaration list: a `style` attribute, or the body of a rule.
    /// Text inside quotes, parentheses and comments never splits a declaration.
    init(declarations css: some Collection<UInt8>) {
        for declaration in CSSText.split(CSSText.removingComments(css)[...], at: { $0 == UInt8(ascii: ";") }) {
            let parts = CSSText.split(declaration, at: { $0 == UInt8(ascii: ":") }, maxSplits: 1)
            // Most declarations set something else; only the properties read become strings.
            guard parts.count == 2,
                  let name = Self.properties.first(where: { CSSText.trimmed(parts[0]).elementsEqual($0.utf8, by: CSSText.equalsLowercased) })
            else { continue }
            var value = CSSText.text(parts[1])
            if let bang = value.lastIndex(of: "!"),
               value[value.index(after: bang)...].trimmingCharacters(in: .whitespaces) == "important" {
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            switch name {
            case "display":
                hidden = value.split(whereSeparator: \.isWhitespace).first == "none"
            case "white-space":
                switch value {
                case "pre", "pre-wrap", "break-spaces": whiteSpace = .preserve
                case "pre-line": whiteSpace = .preserveLineFeeds
                case "normal", "nowrap": whiteSpace = .collapse
                default: break
                }
            case "margin":
                // One to four values: top, then right, bottom, left; bottom repeats top when absent.
                let values = CSSText.split(Array(value.utf8)[...], at: CSSText.isWhitespace).filter { !$0.isEmpty }
                guard (1...4).contains(values.count) else { break }
                marginTop = Self.isNonzero(CSSText.text(values[0])) ?? marginTop
                marginBottom = Self.isNonzero(CSSText.text(values[values.count >= 3 ? 2 : 0])) ?? marginBottom
            case "margin-top":
                marginTop = Self.isNonzero(value) ?? marginTop
            default:
                marginBottom = Self.isNonzero(value) ?? marginBottom
            }
        }
    }

    private static let properties = ["display", "white-space", "margin", "margin-top", "margin-bottom"]

    /// Each property `other` sets replaces this one's.
    mutating func override(with other: HTMLTextStyle) {
        hidden = other.hidden ?? hidden
        whiteSpace = other.whiteSpace ?? whiteSpace
        marginTop = other.marginTop ?? marginTop
        marginBottom = other.marginBottom ?? marginBottom
    }

    /// A length in any unit, or `auto`; nil for anything else (`inherit`, `calc(...)`).
    private static func isNonzero(_ length: String) -> Bool? {
        if length == "auto" { return false }
        guard let number = Double(length.prefix(while: { "+-.0123456789".contains($0) })) else { return nil }
        return number != 0
    }
}

/// The rules of a document's `<style>` blocks the conversion applies: those whose
/// selector is a bare tag, `.class`, `tag.class` or `#id`. Any other selector is
/// skipped, and so is every at-rule block (`@media`, `@font-face`, ...). There is no
/// specificity: a later rule overrides an earlier one. A wrong pick costs a blank
/// line, never text.
struct HTMLTextStyleSheet {
    private struct Rule {
        let tag: String?
        let className: String?
        let id: String?
        let style: HTMLTextStyle
    }

    private var rules: [Rule] = []

    var isEmpty: Bool { rules.isEmpty }

    init(_ css: String = "") { add(Array(css.utf8)) }

    mutating func add(_ css: [UInt8]) {
        let text = CSSText.removingComments(css)
        var i = 0
        while i < text.count {
            if CSSText.isWhitespace(text[i]) { i += 1; continue }
            // `<!--` and `-->` around a style sheet (Word HTML) are not part of a rule.
            if text[i...].starts(with: "<!--".utf8) { i += 4; continue }
            if text[i...].starts(with: "-->".utf8) { i += 3; continue }
            let stop = CSSText.index(in: text, from: i, of: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: ";") })
            guard stop < text.count else { return }
            // A statement at-rule (`@import ...;`) or a stray `;`.
            if text[stop] == UInt8(ascii: ";") { i = stop + 1; continue }
            let end = CSSText.blockEnd(in: text, open: stop)
            if text[i] != UInt8(ascii: "@") {
                let style = HTMLTextStyle(declarations: text[(stop + 1)..<max(stop + 1, end - 1)])
                for selector in text[i..<stop].split(separator: UInt8(ascii: ",")) {
                    if let rule = Self.rule(CSSText.text(selector), style) { rules.append(rule) }
                }
            }
            i = end
        }
    }

    /// The style this sheet's rules give an element. `classes` and `id` are as written.
    func style(tag: String, classes: [Substring], id: Substring?) -> HTMLTextStyle {
        var style = HTMLTextStyle()
        for rule in rules {
            if let ruleTag = rule.tag, ruleTag != tag { continue }
            if let className = rule.className, !classes.contains(where: { $0.lowercased() == className }) { continue }
            if let ruleID = rule.id, id?.lowercased() != ruleID { continue }
            style.override(with: rule.style)
        }
        return style
    }

    /// `selector` trimmed and lowercased.
    private static func rule(_ selector: String, _ style: HTMLTextStyle) -> Rule? {
        if selector.first == "#" {
            let id = String(selector.dropFirst())
            return isIdentifier(id) ? Rule(tag: nil, className: nil, id: id, style: style) : nil
        }
        let parts = selector.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        let tag = parts[0].isEmpty ? nil : parts[0]
        let className = parts.count == 2 ? parts[1] : nil
        guard tag != nil || className != nil,
              tag.map(isIdentifier) ?? true, className.map(isIdentifier) ?? true else { return nil }
        return Rule(tag: tag, className: className, id: nil, style: style)
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// CSS text scanning over UTF-8 bytes: quotes, parentheses and backslash escapes
/// hold their content.
private enum CSSText {
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// `bytes` without leading and trailing white space.
    static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let first = bytes.firstIndex(where: { !isWhitespace($0) }),
              let last = bytes.lastIndex(where: { !isWhitespace($0) }) else { return [] }
        return bytes[first...last]
    }

    /// Whether `byte` is `lowercase`, an ASCII lowercase letter or other byte, ignoring case.
    static func equalsLowercased(_ byte: UInt8, _ lowercase: UInt8) -> Bool {
        byte == lowercase || (lowercase >= UInt8(ascii: "a") && lowercase <= UInt8(ascii: "z") && byte | 0x20 == lowercase)
    }

    /// `bytes` as a trimmed, lowercased string.
    static func text(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func removingComments(_ css: some Collection<UInt8>) -> [UInt8] {
        let text = Array(css)
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        var quote: UInt8?
        var i = 0
        while i < text.count {
            let c = text[i]
            if let open = quote {
                out.append(c)
                if c == UInt8(ascii: "\\"), i + 1 < text.count { out.append(text[i + 1]); i += 2; continue }
                if c == open { quote = nil }
            } else if c == UInt8(ascii: "/"), i + 1 < text.count, text[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i < text.count, !(text[i] == UInt8(ascii: "*") && i + 1 < text.count && text[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i += 1
            } else {
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { quote = c }
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// The parts of `text` between top-level separators.
    static func split(_ text: ArraySlice<UInt8>, at isSeparator: (UInt8) -> Bool, maxSplits: Int = .max) -> [ArraySlice<UInt8>] {
        var parts: [ArraySlice<UInt8>] = []
        var start = text.startIndex
        var quote: UInt8?
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if let open = quote {
                if c == open { quote = nil }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                depth = max(0, depth - 1)
            } else if depth == 0, parts.count < maxSplits, isSeparator(c) {
                parts.append(text[start..<i])
                start = i + 1
            }
            i += 1
        }
        parts.append(text[start...])
        return parts
    }

    /// The first top-level byte matching `isStop` at or after `from`, or `text.count`.
    static func index(in text: [UInt8], from: Int, of isStop: (UInt8) -> Bool) -> Int {
        var quote: UInt8?
        var i = from
        while i < text.count {
            let c = text[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if let open = quote {
                if c == open { quote = nil }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if isStop(c) {
                return i
            }
            i += 1
        }
        return text.count
    }

    /// The index just past the `}` that closes the block opened at `open`, or `text.count`.
    static func blockEnd(in text: [UInt8], open: Int) -> Int {
        var depth = 0
        var i = open
        while i < text.count {
            i = index(in: text, from: i, of: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "}") })
            guard i < text.count else { break }
            depth += text[i] == UInt8(ascii: "{") ? 1 : -1
            i += 1
            if depth == 0 { return i }
        }
        return text.count
    }
}
