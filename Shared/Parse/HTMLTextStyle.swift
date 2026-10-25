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
    /// The properties set by an `!important` declaration, which only another one overrides.
    fileprivate var important: Properties = []

    fileprivate struct Properties: OptionSet {
        let rawValue: UInt8
        static let hidden = Properties(rawValue: 1)
        static let whiteSpace = Properties(rawValue: 2)
        static let marginTop = Properties(rawValue: 4)
        static let marginBottom = Properties(rawValue: 8)
    }

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
            var important = false
            if let bang = value.lastIndex(of: "!"),
               CSSText.trimmed(Array(value[value.index(after: bang)...].utf8)[...]).elementsEqual("important".utf8) {
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
                important = true
            }
            // An invalid value is ignored, so it never undoes an earlier valid one.
            switch name {
            case "display":
                let keywords = value.split(whereSeparator: \.isWhitespace)
                if keywords == ["none"] {
                    set(\.hidden, .hidden, true, important: important)
                } else if Self.isDisplayValue(keywords.map(String.init)) {
                    set(\.hidden, .hidden, false, important: important)
                }
            case "white-space":
                switch value {
                case "pre", "pre-wrap", "break-spaces": set(\.whiteSpace, .whiteSpace, .preserve, important: important)
                case "pre-line": set(\.whiteSpace, .whiteSpace, .preserveLineFeeds, important: important)
                case "normal", "nowrap": set(\.whiteSpace, .whiteSpace, .collapse, important: important)
                default: break
                }
            case "margin":
                // One to four values: top, then right, bottom, left; bottom repeats top when absent.
                let values = CSSText.split(Array(value.utf8)[...], at: CSSText.isWhitespace).filter { !$0.isEmpty }
                guard (1...4).contains(values.count),
                      let top = Self.isNonzero(CSSText.text(values[0])),
                      let bottom = Self.isNonzero(CSSText.text(values[values.count >= 3 ? 2 : 0])) else { break }
                set(\.marginTop, .marginTop, top, important: important)
                set(\.marginBottom, .marginBottom, bottom, important: important)
            case "margin-top":
                set(\.marginTop, .marginTop, Self.isNonzero(value), important: important)
            default:
                set(\.marginBottom, .marginBottom, Self.isNonzero(value), important: important)
            }
        }
    }

    private static let properties = ["display", "white-space", "margin", "margin-top", "margin-bottom"]

    /// The `display` keywords, by their part in the grammar (CSS Display 3, `math` from MathML Core).
    private static let displayOutside: Set<String> = ["block", "inline", "run-in"]
    private static let displayInside: Set<String> = ["flow", "flow-root", "table", "flex", "grid", "ruby", "math"]
    /// The values that are one keyword alone: internal, `contents`, legacy and global.
    private static let displayAlone: Set<String> = [
        "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell",
        "table-column-group", "table-column", "table-caption", "ruby-base", "ruby-text",
        "ruby-base-container", "ruby-text-container", "contents",
        "inline-block", "inline-table", "inline-flex", "inline-grid",
        "inherit", "initial", "unset", "revert", "revert-layer",
    ]

    /// Whether `keywords` is a valid `display` value other than `none`, so it shows the element:
    /// one keyword, an outside and an inside one (`inline flex`), or `list-item` with at most an
    /// outside one and `flow` or `flow-root`, each once, in any order.
    private static func isDisplayValue(_ keywords: [String]) -> Bool {
        if keywords.count == 1, let keyword = keywords.first {
            return displayAlone.contains(keyword) || displayOutside.contains(keyword)
                || displayInside.contains(keyword) || keyword == "list-item"
        }
        let outside = keywords.filter(displayOutside.contains)
        let inside = keywords.filter(displayInside.contains)
        let listItem = keywords.filter { $0 == "list-item" }
        guard outside.count <= 1, inside.count <= 1, listItem.count <= 1,
              outside.count + inside.count + listItem.count == keywords.count, (2...3).contains(keywords.count) else { return false }
        if listItem.isEmpty { return keywords.count == 2 }
        return inside.allSatisfy { $0 == "flow" || $0 == "flow-root" }
    }

    /// Each property `other` sets replaces this one's, except an `!important` one
    /// that `other` sets without `!important`.
    mutating func override(with other: HTMLTextStyle) {
        set(\.hidden, .hidden, other.hidden, important: other.important.contains(.hidden))
        set(\.whiteSpace, .whiteSpace, other.whiteSpace, important: other.important.contains(.whiteSpace))
        set(\.marginTop, .marginTop, other.marginTop, important: other.important.contains(.marginTop))
        set(\.marginBottom, .marginBottom, other.marginBottom, important: other.important.contains(.marginBottom))
    }

    fileprivate mutating func set<Value>(_ property: WritableKeyPath<HTMLTextStyle, Value?>, _ flag: Properties,
                                     _ value: Value?, important isImportant: Bool) {
        guard let value, isImportant || !important.contains(flag) else { return }
        self[keyPath: property] = value
        if isImportant { important.insert(flag) }
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
/// specificity: a later rule overrides an earlier one, `!important` aside. Class and
/// id match exactly, as in the standards-mode page TabMail shows.
struct HTMLTextStyleSheet {
    /// A property's value, the position of the rule that set it, and whether it is `!important`.
    private struct Declared<Value: Sendable>: Sendable {
        let value: Value
        let position: Int
        let important: Bool

        /// The one that wins: an `!important` declaration over another, then the later one.
        static func winner(_ a: Declared?, _ b: Declared?) -> Declared? {
            guard let a else { return b }
            guard let b else { return a }
            if a.important != b.important { return a.important ? a : b }
            return a.position > b.position ? a : b
        }
    }

    /// The winning declaration of each property among some rules. Only winners are kept, so an
    /// element combines one entry per selector it matches, however many rules name it.
    private struct Winners {
        var hidden: Declared<Bool>?
        var whiteSpace: Declared<HTMLTextStyle.WhiteSpace>?
        var marginTop: Declared<Bool>?
        var marginBottom: Declared<Bool>?

        init() {}

        init(_ style: HTMLTextStyle, position: Int) {
            hidden = style.hidden.map { Declared(value: $0, position: position, important: style.important.contains(.hidden)) }
            whiteSpace = style.whiteSpace.map { Declared(value: $0, position: position, important: style.important.contains(.whiteSpace)) }
            marginTop = style.marginTop.map { Declared(value: $0, position: position, important: style.important.contains(.marginTop)) }
            marginBottom = style.marginBottom.map { Declared(value: $0, position: position, important: style.important.contains(.marginBottom)) }
        }

        mutating func add(_ other: Winners) {
            hidden = Declared.winner(hidden, other.hidden)
            whiteSpace = Declared.winner(whiteSpace, other.whiteSpace)
            marginTop = Declared.winner(marginTop, other.marginTop)
            marginBottom = Declared.winner(marginBottom, other.marginBottom)
        }

        var style: HTMLTextStyle {
            var style = HTMLTextStyle()
            style.set(\.hidden, .hidden, hidden?.value, important: hidden?.important == true)
            style.set(\.whiteSpace, .whiteSpace, whiteSpace?.value, important: whiteSpace?.important == true)
            style.set(\.marginTop, .marginTop, marginTop?.value, important: marginTop?.important == true)
            style.set(\.marginBottom, .marginBottom, marginBottom?.value, important: marginBottom?.important == true)
            return style
        }
    }

    /// The rules read so far, which give each rule its position.
    private var count = 0
    /// The winners by the tag, class, `tag.class` or id the selector names. `tag.class` is keyed by
    /// tag, then class, so a lookup never builds a key holding the tag once per class.
    private var byTag: [String: Winners] = [:]
    private var byClass: [String: Winners] = [:]
    private var byTagClass: [String: [String: Winners]] = [:]
    private var byID: [String: Winners] = [:]

    var isEmpty: Bool { count == 0 }

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
            // The end of the input closes a block left open.
            let close = CSSText.blockClose(in: text, open: stop)
            if text[i] != UInt8(ascii: "@") {
                let style = HTMLTextStyle(declarations: text[(stop + 1)..<close])
                for selector in text[i..<stop].split(separator: UInt8(ascii: ",")) {
                    add(String(decoding: CSSText.trimmed(selector), as: UTF8.self), style)
                }
            }
            i = close + 1
        }
    }

    /// The style this sheet's rules give an element.
    func style(tag: String, classes: [Substring], id: Substring?) -> HTMLTextStyle {
        var winners = byTag[tag] ?? Winners()
        let tagClasses = byTagClass[tag]
        for className in classes {
            let className = String(className)
            if let rule = byClass[className] { winners.add(rule) }
            if let rule = tagClasses?[className] { winners.add(rule) }
        }
        if let id, let rule = byID[String(id)] { winners.add(rule) }
        return winners.style
    }

    /// Adds the rule for `selector`, trimmed, when it is a form this sheet reads.
    private mutating func add(_ selector: String, _ style: HTMLTextStyle) {
        let rule = Winners(style, position: count)
        if selector.first == "#" {
            let id = String(selector.dropFirst())
            guard Self.isIdentifier(id) else { return }
            byID[id, default: Winners()].add(rule)
            count += 1
            return
        }
        let parts = selector.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return }
        let tag = parts[0].isEmpty ? nil : parts[0].lowercased()
        let className = parts.count == 2 ? String(parts[1]) : nil
        guard tag != nil || className != nil,
              tag.map(Self.isIdentifier) ?? true, className.map(Self.isIdentifier) ?? true else { return }
        switch (tag, className) {
        case let (tag?, className?): byTagClass[tag, default: [:]][className, default: Winners()].add(rule)
        case let (nil, className?): byClass[className, default: Winners()].add(rule)
        case let (tag?, nil): byTag[tag, default: Winners()].add(rule)
        case (nil, nil): return
        }
        count += 1
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
                // A comment separates what is around it: `dis/**/play` is two words.
                out.append(UInt8(ascii: " "))
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

    /// The index of the `}` that closes the block opened at `open`, or `text.count`.
    static func blockClose(in text: [UInt8], open: Int) -> Int {
        var depth = 0
        var i = open
        while i < text.count {
            i = index(in: text, from: i, of: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "}") })
            guard i < text.count else { break }
            depth += text[i] == UInt8(ascii: "{") ? 1 : -1
            if depth == 0 { return i }
            i += 1
        }
        return text.count
    }
}
