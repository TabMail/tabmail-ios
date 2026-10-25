/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftSoup

/// HTML to plain text in one streaming pass over the UTF-8 bytes (#251). It keeps
/// no tree, only the stack of open elements and their style, so memory stays a
/// small multiple of the output: it runs in the notification extension, where a
/// DOM of a large body does not fit. All HTML syntax characters are ASCII, and an
/// ASCII byte never occurs inside a multi-byte UTF-8 sequence, so reading bytes is
/// exact.
///
/// Elements are hidden by `display: none`. With `keepingSpacing`, the CSS
/// `white-space` property and nonzero vertical margins (a blank line) apply too:
/// the default style sheet below, then the document's `<style>` rules, then the
/// element's `style` attribute. See `HTMLTextStyle` for the CSS read.
enum HTMLText {
    /// Whether a `<style>` with these `type` and `media` attributes styles the screen. A `type`
    /// other than CSS, compared as written, makes no style sheet at all, and a sheet only for
    /// other media (`print`, `speech`) does not apply. A query that is empty or only a prefix
    /// (`print, `, `only`) matches nothing. Media features (`(max-width: ...)`) are not
    /// evaluated: a query for the screen with features counts as applying.
    static func sheetApplies(type: String?, media: String?) -> Bool {
        if let type = type?.lowercased(), !type.isEmpty, type != "text/css" { return false }
        guard let media = media?.lowercased(), !media.allSatisfy(isWhitespace) else { return true }
        return media.split(separator: ",", omittingEmptySubsequences: false).contains { query in
            var words = query.split(whereSeparator: isWhitespace)
            if words.first == "only" { words.removeFirst() }
            let negated = words.first == "not"
            if negated { words.removeFirst() }
            guard let first = words.first else { return false }
            let mediaType = first.hasPrefix("(") ? "all" : String(first)
            let screen = mediaType == "all" || mediaType == "screen"
            return negated ? !screen : screen
        }
    }

    /// HTML's and CSS's white space: ASCII only, so a no-break space is part of a word.
    static func isWhitespace(_ character: Character) -> Bool {
        character.asciiValue.map(Byte.isWhitespace) ?? false
    }

    /// The deepest nesting the converter follows; a deeper element takes its parent's style.
    static let maxOpenElements = 512
    /// The longest entity reference read, `&` and `;` included; the longest HTML name is 33.
    static let maxEntityLength = 40

    /// The browser defaults the conversion relies on.
    static let defaultStyleSheet = HTMLTextStyleSheet(
        "head, template { display: none } p { margin: 1em 0 } pre { white-space: pre }")

    struct ElementKind: OptionSet {
        let rawValue: UInt8
        /// Starts and ends a line.
        static let block = ElementKind(rawValue: 1)
        /// Formatting inside a word or sentence; with `keepingSpacing` it adds no space.
        static let inline = ElementKind(rawValue: 2)
        /// No content and no end tag.
        static let void = ElementKind(rawValue: 4)
        /// Content that is not markup and never shown.
        static let rawText = ElementKind(rawValue: 8)
    }

    /// The elements the conversion treats specially; any other element adds a space.
    static let elementKinds: [String: ElementKind] = {
        var kinds: [String: ElementKind] = [:]
        for name in ["div", "p", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                     "blockquote", "pre", "table", "section", "article", "header", "footer"] {
            kinds[name] = .block
        }
        for name in ["b", "i", "u", "s", "em", "strong", "span", "font", "small", "big", "sub", "sup",
                     "code", "mark", "strike", "del", "ins", "tt", "abbr", "cite", "q", "kbd", "var",
                     "samp", "dfn", "bdi", "bdo",
                     "o"] { // Word HTML's `<o:p>`
            kinds[name] = .inline
        }
        for name in ["img", "br", "input", "meta", "link", "source", "col",
                     "embed", "area", "wbr", "track", "base", "param"] {
            kinds[name] = .void
        }
        kinds["hr"] = [.block, .void]
        for name in ["style", "script", "title"] { kinds[name] = .rawText }
        return kinds
    }()

    /// The start tags that end an open `<p>` without its end tag, as HTML parses them.
    static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "li", "dd", "dt", "listing", "main", "menu", "nav", "ol", "p",
        "plaintext", "pre", "search", "section", "summary", "table", "ul", "xmp",
    ]
    /// The elements an implied `<p>` end does not reach past.
    static let paragraphScope: Set<String> = [
        "applet", "button", "caption", "html", "marquee", "object", "table", "td", "template", "th",
    ]
    /// The start tags that end an open table cell, row or row group without its end
    /// tag, as HTML parses them, each with the elements it ends: the outermost open one
    /// within the table, and everything inside it.
    static let closesTablePart: [String: Set<String>] = {
        let cells: Set<String> = ["td", "th"]
        let rows = cells.union(["tr"])
        let groups = rows.union(["tbody", "thead", "tfoot"])
        return ["td": cells, "th": cells, "tr": rows, "tbody": groups, "thead": groups, "tfoot": groups]
    }()
    /// The elements an implied table cell, row or row group end does not reach past.
    static let tableScope: Set<String> = ["html", "table", "template"]
    /// The elements an implied `<li>`, `<dd>` or `<dt>` end does not reach past: HTML's
    /// special elements other than `address`, `div` and `p`.
    static let listItemScope: Set<String> = [
        "applet", "article", "aside", "blockquote", "body", "button", "caption", "center", "colgroup",
        "details", "dialog", "dir", "dl", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "html", "iframe", "listing",
        "main", "marquee", "menu", "nav", "object", "ol", "plaintext", "pre", "search", "section",
        "select", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
        "tr", "ul", "xmp",
    ]

    static func plainText(_ html: String, keepingSpacing: Bool) -> String {
        var html = html
        return html.withUTF8 { bytes in
            var scanner = Scanner(bytes: bytes, keepingSpacing: keepingSpacing)
            if keepingSpacing { scanner.readStyleSheets() }
            scanner.run()
            return scanner.writer.finish()
        }
    }

    /// Characters that take no space and join nothing: soft hyphen, combining
    /// grapheme joiner, zero-width space, word joiner, byte order mark.
    static func isInvisible(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x00AD, 0x034F, 0x200B, 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    /// The zero-width non-joiner and joiner shape emoji (`👩‍💻`) and scripts
    /// (Persian `می‌روم`), so they stay between two non-ASCII characters. Anywhere
    /// else they are filler (`&zwnj;&nbsp;` after a preheader) or break up digits
    /// against auto-linking (`1&zwnj;1:59`), and are dropped so search matches.
    static func isJoiner(_ scalar: UInt32) -> Bool {
        scalar == 0x200C || scalar == 0x200D
    }
}

private enum Byte {
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let ampersand: UInt8 = 0x26
    static let slash: UInt8 = 0x2F
    static let semicolon: UInt8 = 0x3B
    static let lessThan: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greaterThan: UInt8 = 0x3E

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}

/// The output, a line at a time. Spaces wait until text follows them, so a line
/// never starts or ends with a collapsible space, and blank lines wait until
/// something follows them, so the output never ends with one.
private struct Writer {
    let keepingSpacing: Bool
    private var out: [UInt8] = []
    /// Whether the current line holds anything visible, a no-break space included:
    /// only such a line is ended by a block.
    private var lineHasContent = false
    /// Line feeds written since the last line with content ended.
    private var lineFeeds = 0
    /// Line feeds the next content needs before it: 2 after a margin.
    private var requiredLineFeeds = 0
    private var collapsibleSpace = false
    private var noBreakSpaces = 0
    private var link: (start: Int, href: String)?
    /// Joiners after a non-ASCII character, written only if one follows.
    private var joiners: [UInt8] = []

    init(keepingSpacing: Bool, capacity: Int) {
        self.keepingSpacing = keepingSpacing
        out.reserveCapacity(capacity)
    }

    mutating func text(_ byte: UInt8) {
        beginText(byte)
        out.append(byte)
    }

    mutating func text(_ bytes: UnsafeBufferPointer<UInt8>.SubSequence) {
        guard let first = bytes.first else { return }
        beginText(first)
        out.append(contentsOf: bytes)
    }

    mutating func text(_ string: String) {
        guard let first = string.utf8.first else { return }
        beginText(first)
        out.append(contentsOf: string.utf8)
    }

    /// A zero-width joiner or non-joiner: kept only right after a non-ASCII character.
    mutating func joiner(_ bytes: some Sequence<UInt8>) {
        guard lineFeeds == 0, !collapsibleSpace, noBreakSpaces == 0, link?.start != out.count,
              let last = out.last, last >= 0x80 else { return }
        joiners.append(contentsOf: bytes)
    }

    mutating func space() {
        collapsibleSpace = true
        joiners = []
    }

    /// With `keepingSpacing` every no-break space is a space, as the page shows it;
    /// otherwise it is white space like any other.
    mutating func noBreakSpace() {
        lineHasContent = true
        joiners = []
        guard keepingSpacing else { collapsibleSpace = true; return }
        // A collapsible space before it stays unless it would start the line.
        if collapsibleSpace, !atLineStart || noBreakSpaces > 0 { noBreakSpaces += 1 }
        collapsibleSpace = false
        noBreakSpaces += 1
    }

    /// Ends a line holding something; a block never adds an empty line.
    mutating func endLine() {
        joiners = []
        guard lineHasContent else { return }
        let labelIsEmpty = link?.start == out.count
        defer { if labelIsEmpty { link?.start = out.count } }
        if out.isEmpty || lineFeeds > 0 {
            // Only no-break spaces: a blank line (TinyMCE's `<p>&nbsp;</p>`), which
            // the margins around it join rather than add to.
            let feeds = max(lineFeeds + 1, out.isEmpty ? 0 : requiredLineFeeds)
            out.append(contentsOf: repeatElement(Byte.lineFeed, count: feeds - lineFeeds))
            lineFeeds = feeds
        } else {
            out.append(Byte.lineFeed)
            lineFeeds = 1
        }
        requiredLineFeeds = 0
        dropSpaces()
        lineHasContent = false
    }

    /// `<br>`, or a preserved line feed: always ends the line, empty or not.
    mutating func lineBreak() {
        if lineHasContent { return endLine() }
        joiners = []
        let labelIsEmpty = link?.start == out.count
        defer { if labelIsEmpty { link?.start = out.count } }
        writeRequiredLineFeeds()
        dropSpaces()
        out.append(Byte.lineFeed)
        lineFeeds += 1
    }

    mutating func requestBlankLine() {
        requiredLineFeeds = 2
    }

    mutating func startLink(_ href: String) {
        joiners = []
        link = (out.count, href)
    }

    /// Writes the link as `[label](destination)`, the label on one line.
    mutating func finishLink() {
        joiners = []
        guard var active = link else { return }
        if active.start == out.count {
            // An empty label: anything waiting goes before the link.
            beginText(0)
            active.start = out.count
        }
        link = nil
        let written = String(decoding: out[active.start...], as: UTF8.self)
        out.removeSubrange(active.start...)
        let label = keepingSpacing
            ? written.split(separator: "\n").map { $0.trimmingCharacters(in: [" "]) }.filter { !$0.isEmpty }.joined(separator: " ")
            : written.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let labelPunctuation = CharacterSet(charactersIn: "\\[]`*_<>~")
        var escapedLabel = ""
        for scalar in label.unicodeScalars {
            if scalar == "&" {
                escapedLabel += "&amp;"
            } else {
                if labelPunctuation.contains(scalar) { escapedLabel.append("\\") }
                escapedLabel.unicodeScalars.append(scalar)
            }
        }
        let encoded = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        let escaped = CharacterSet(charactersIn: "\\()<>;")
        var destination = ""
        for scalar in active.href.unicodeScalars {
            if encoded.contains(scalar) {
                for byte in String(scalar).utf8 {
                    destination += String(format: "%%%02X", byte)
                }
            } else {
                // Escaping semicolons prevents Markdown from decoding an entity twice.
                if escaped.contains(scalar) { destination.append("\\") }
                destination.unicodeScalars.append(scalar)
            }
        }
        out.append(contentsOf: "[\(escapedLabel)](\(destination))".utf8)
        lineHasContent = true
        lineFeeds = 0
        // A line the label ended (a block inside the link) ends after the link, and
        // the margin that block left still applies.
        if written.last == "\n" {
            let required = requiredLineFeeds
            endLine()
            requiredLineFeeds = required
        }
    }

    mutating func finish() -> String {
        finishLink()
        while let last = out.last, Byte.isWhitespace(last) { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    /// Writes what waits before text: line feeds, then spaces. Whatever is written
    /// while a link label is still empty goes before the label.
    private mutating func beginText(_ first: UInt8) {
        let labelIsEmpty = link?.start == out.count
        writeRequiredLineFeeds()
        let spaces = (collapsibleSpace && (!atLineStart || noBreakSpaces > 0) ? 1 : 0) + noBreakSpaces
        out.append(contentsOf: repeatElement(Byte.space, count: spaces))
        dropSpaces()
        if labelIsEmpty { link?.start = out.count }
        if !joiners.isEmpty {
            if first >= 0x80 { out.append(contentsOf: joiners) }
            joiners = []
        }
        lineHasContent = true
        lineFeeds = 0
    }

    /// Whether nothing is written on the current line yet. A collapsible space there is
    /// dropped, unless a no-break space waits before it.
    private var atLineStart: Bool { out.isEmpty || lineFeeds > 0 }

    private mutating func writeRequiredLineFeeds() {
        if !out.isEmpty {
            while lineFeeds < requiredLineFeeds {
                out.append(Byte.lineFeed)
                lineFeeds += 1
            }
        }
        requiredLineFeeds = 0
    }

    private mutating func dropSpaces() {
        collapsibleSpace = false
        noBreakSpaces = 0
    }
}

private struct OpenElement {
    let name: String
    let hidden: Bool
    let whiteSpace: HTMLTextStyle.WhiteSpace
    let marginBottom: Bool
}

private struct Scanner {
    let bytes: UnsafeBufferPointer<UInt8>
    let keepingSpacing: Bool
    var writer: Writer
    private var i = 0
    private var stack: [OpenElement] = []
    private var documentSheet = HTMLTextStyleSheet()
    /// The innermost open element's, kept apart from `stack` for the per-byte loop.
    private var hidden = false
    private var whiteSpace = HTMLTextStyle.WhiteSpace.collapse

    init(bytes: UnsafeBufferPointer<UInt8>, keepingSpacing: Bool) {
        self.bytes = bytes
        self.keepingSpacing = keepingSpacing
        writer = Writer(keepingSpacing: keepingSpacing, capacity: bytes.count / 4)
    }

    mutating func run() {
        while i < bytes.count {
            let byte = bytes[i]
            if byte == Byte.lessThan {
                markup()
            } else if hidden {
                i = bytes[i...].firstIndex(of: Byte.lessThan) ?? bytes.count
            } else if byte == Byte.ampersand {
                entity()
            } else if Byte.isWhitespace(byte) {
                // HTML reads a carriage return, alone or before a line feed, as one line feed.
                if byte == Byte.carriageReturn, i + 1 < bytes.count, bytes[i + 1] == Byte.lineFeed {
                    i += 1
                    continue
                }
                writeWhiteSpace(byte == Byte.carriageReturn ? Byte.lineFeed : byte)
                i += 1
            } else if byte >= 0x80 {
                nonASCII()
            } else {
                let end = bytes[i...].firstIndex(where: {
                    $0 >= 0x80 || $0 == Byte.lessThan || $0 == Byte.ampersand || Byte.isWhitespace($0)
                }) ?? bytes.count
                writer.text(bytes[i..<end])
                i = end
            }
        }
    }

    // MARK: - Text

    /// A carriage return here is a character reference's, which CSS treats as a space.
    private mutating func writeWhiteSpace(_ byte: UInt8) {
        switch whiteSpace {
        case .collapse:
            writer.space()
        case .preserve:
            if byte == Byte.lineFeed { writer.lineBreak() } else { writer.text(byte == Byte.carriageReturn ? Byte.space : byte) }
        case .preserveLineFeeds:
            if byte == Byte.lineFeed { writer.lineBreak() } else { writer.space() }
        }
    }

    private mutating func nonASCII() {
        let lead = bytes[i]
        let length = min(lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4, bytes.count - i)
        var scalar = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
        for k in 1..<length { scalar = scalar << 6 | UInt32(bytes[i + k] & 0x3F) }
        if scalar == 0xA0 {
            writer.noBreakSpace()
        } else if HTMLText.isJoiner(scalar) {
            writer.joiner(bytes[i..<(i + length)])
        } else if !HTMLText.isInvisible(scalar) {
            writer.text(bytes[i..<(i + length)])
        }
        i += length
    }

    /// A character reference; one that names no character stays as written.
    private mutating func entity() {
        guard let (decoded, end) = reference(at: i) else {
            writer.text(Byte.ampersand)
            i += 1
            return
        }
        i = end
        switch decoded {
        case " ", "\t", "\n", "\r": writeWhiteSpace(decoded.utf8.first!)
        case "\u{00A0}": writer.noBreakSpace()
        default:
            if decoded.unicodeScalars.count == 1, let scalar = decoded.unicodeScalars.first?.value {
                if HTMLText.isJoiner(scalar) { return writer.joiner(decoded.utf8) }
                if HTMLText.isInvisible(scalar) { return }
            }
            writer.text(decoded)
        }
    }

    /// The character reference at `start`, an `&`, and the index past its `;`; nil if it names no character.
    private func reference(at start: Int) -> (String, Int)? {
        let limit = min(start + HTMLText.maxEntityLength, bytes.count)
        guard start + 1 < limit, let end = bytes[(start + 1)..<limit].firstIndex(of: Byte.semicolon), end > start + 1,
              let decoded = Self.decode(bytes[(start + 1)..<end]) else { return nil }
        return (decoded, end + 1)
    }

    private static func decode(_ body: UnsafeBufferPointer<UInt8>.SubSequence) -> String? {
        if body.first == UInt8(ascii: "#") {
            let digits = String(decoding: body.dropFirst(), as: UTF8.self)
            let hex = digits.first == "x" || digits.first == "X"
            let code = hex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            // A number that is no character is a space, never dropped text.
            return code.flatMap(Unicode.Scalar.init).map { String($0) } ?? " "
        }
        switch String(decoding: body, as: UTF8.self) {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case let name: return Entities.getByName(name: name)
        }
    }

    // MARK: - Markup

    /// A tag, comment or other markup at `<`; a `<` that starts none is text.
    private mutating func markup() {
        let next = i + 1 < bytes.count ? bytes[i + 1] : 0
        if next == UInt8(ascii: "!") {
            // A comment shows nothing; neither does a doctype or CDATA.
            if bytes[i...].starts(with: "<!--".utf8) {
                i = index(after: "-->", from: i + 2)
            } else {
                i = index(after: ">", from: i)
            }
            return
        }
        if next == UInt8(ascii: "?") {
            i = index(after: ">", from: i)
            return
        }
        let closing = next == Byte.slash
        let nameStart = closing ? i + 2 : i + 1
        guard nameStart < bytes.count, Byte.isLetter(bytes[nameStart]) else {
            if closing {
                // `</>` and `</ ...>` show nothing.
                i = index(after: ">", from: i)
            } else {
                if !hidden { writer.text(Byte.lessThan) }
                i += 1
            }
            return
        }
        let (name, nameEnd) = tagName(at: nameStart)
        let end = tagEnd(from: nameEnd)
        // A tag the input ends inside is not a tag.
        guard end < bytes.count else { i = bytes.count; return }
        i = end + 1
        let kind = HTMLText.elementKinds[name] ?? []
        if closing { endTag(name, kind) } else { startTag(name, kind, attributes: nameEnd..<end) }
    }

    /// With `keepingSpacing`, reads every `<style>` before any text is written: a
    /// browser applies a style sheet to the whole document, wherever it sits. A
    /// `<template>`'s content is inert, so a sheet inside one applies to nothing.
    mutating func readStyleSheets() {
        var templates = 0
        while let open = bytes[i...].firstIndex(of: Byte.lessThan) {
            if bytes[open...].starts(with: "<!--".utf8) {
                i = index(after: "-->", from: open + 2)
                continue
            }
            if isEndTag("template", at: open) { templates = max(0, templates - 1) }
            i = open + 1
            guard i < bytes.count, Byte.isLetter(bytes[i]) else { continue }
            let (name, nameEnd) = tagName(at: i)
            i = tagEnd(from: nameEnd)
            guard i < bytes.count else { break }
            let attributes = nameEnd..<i
            i += 1
            if name == "template" { templates += 1 }
            guard HTMLText.elementKinds[name]?.contains(.rawText) == true else { continue }
            let end = rawTextEnd(name)
            if name == "style", templates == 0, HTMLText.sheetApplies(
                type: attribute("type", in: attributes), media: attribute("media", in: attributes)) {
                documentSheet.add(Array(bytes[i..<end]))
            }
            i = end
        }
        i = 0
    }

    private mutating func startTag(_ name: String, _ kind: HTMLText.ElementKind, attributes: Range<Int>) {
        // `<body>` closes a `<head>` left open.
        if name == "body", let head = stack.lastIndex(where: { $0.name == "head" }) { pop(to: head) }
        if kind.contains(.rawText) { return rawText(name) }
        // A list item, or a block in a paragraph, ends the one open without its end tag.
        let items: Set<String>? = name == "li" ? ["li"] : name == "dd" || name == "dt" ? ["dd", "dt"] : nil
        if let items, let open = openElement(items, within: HTMLText.listItemScope) { close(at: open) }
        if HTMLText.closesParagraph.contains(name), let open = openElement(["p"], within: HTMLText.paragraphScope) {
            close(at: open)
        }
        if let parts = HTMLText.closesTablePart[name], let open = outermostOpenElement(parts, within: HTMLText.tableScope) {
            close(at: open)
        }
        let parentHidden = hidden
        let style = parentHidden ? HTMLTextStyle() : self.style(name, attributes: attributes)
        let element = OpenElement(
            name: name,
            hidden: parentHidden || style.hidden == true,
            whiteSpace: keepingSpacing ? style.whiteSpace ?? whiteSpace : .collapse,
            marginBottom: keepingSpacing && style.marginBottom == true
        )
        if !kind.contains(.void), stack.count < HTMLText.maxOpenElements {
            stack.append(element)
            topChanged()
        }
        guard !element.hidden else {
            if !parentHidden { writer.space() }
            return
        }
        // HTML drops a line feed right after `<pre>`, written or as a character reference.
        if name == "pre", i < bytes.count {
            if bytes[i] == Byte.carriageReturn {
                i += 1
                if i < bytes.count, bytes[i] == Byte.lineFeed { i += 1 }
            } else if bytes[i] == Byte.lineFeed {
                i += 1
            } else if bytes[i] == Byte.ampersand, let (decoded, end) = reference(at: i), decoded == "\n" {
                i = end
            }
        }
        boundary(name, kind, margin: keepingSpacing && style.marginTop == true)
        if name == "a", let href = attribute("href", in: attributes)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !href.isEmpty {
            writer.startLink(href)
        }
    }

    private mutating func endTag(_ name: String, _ kind: HTMLText.ElementKind) {
        if let open = stack.lastIndex(where: { $0.name == name }) { return close(at: open) }
        if !hidden { boundary(name, kind, margin: false) }
    }

    /// Ends the open element at `open` and every element inside it.
    private mutating func close(at open: Int) {
        let element = stack[open]
        pop(to: open)
        if !element.hidden { boundary(element.name, HTMLText.elementKinds[element.name] ?? [], margin: element.marginBottom) }
    }

    /// The innermost open element named in `names`, unless an element in `scope` is inside it.
    private func openElement(_ names: Set<String>, within scope: Set<String>) -> Int? {
        for k in stack.indices.reversed() {
            if names.contains(stack[k].name) { return k }
            if scope.contains(stack[k].name) { return nil }
        }
        return nil
    }

    /// The outermost open element named in `names` inside the innermost element in `scope`.
    private func outermostOpenElement(_ names: Set<String>, within scope: Set<String>) -> Int? {
        var outermost: Int?
        for k in stack.indices.reversed() {
            if scope.contains(stack[k].name) { break }
            if names.contains(stack[k].name) { outermost = k }
        }
        return outermost
    }

    /// What the start or end of a visible element writes. Line rules (#217): `<br>`
    /// always ends the line; a block starts and ends a line but never adds an empty
    /// one, so `<div><br></div>`, the blank line every editor writes, is ONE empty
    /// line, and nested block ends do not stack. A margin adds a blank line.
    private mutating func boundary(_ name: String, _ kind: HTMLText.ElementKind, margin: Bool) {
        if name == "a" {
            writer.finishLink()
            if !keepingSpacing { writer.space() }
        } else if name == "br" {
            writer.lineBreak()
        } else if kind.contains(.block) {
            writer.endLine()
            if margin { writer.requestBlankLine() }
        } else if !(keepingSpacing && kind.contains(.inline)) {
            writer.space()
        }
    }

    /// Skips `<style>`, `<script>` or `<title>` content, which `readStyleSheets` read.
    private mutating func rawText(_ name: String) {
        let end = rawTextEnd(name)
        i = end < bytes.count ? index(after: ">", from: end) : bytes.count
        if !hidden { writer.space() }
    }

    /// Where the content of raw text element `name`, starting at `i`, ends: its end tag or the input's end.
    private func rawTextEnd(_ name: String) -> Int {
        var j = i
        while let open = bytes[j...].firstIndex(of: Byte.lessThan) {
            if isEndTag(name, at: open) { return open }
            j = open + 1
        }
        return bytes.count
    }

    /// Whether `</name` starts at `open`, followed by white space, `/` or `>`.
    private func isEndTag(_ name: String, at open: Int) -> Bool {
        let nameStart = open + 2
        let nameEnd = nameStart + name.utf8.count
        guard nameEnd < bytes.count, bytes[open + 1] == Byte.slash,
              zip(bytes[nameStart..<nameEnd], name.utf8).allSatisfy({ $0 | 0x20 == $1 }) else { return false }
        let next = bytes[nameEnd]
        return Byte.isWhitespace(next) || next == Byte.slash || next == Byte.greaterThan
    }

    /// The lowercased tag name starting at `nameStart`, a letter, and the index past it.
    private func tagName(at nameStart: Int) -> (String, Int) {
        var nameEnd = nameStart
        while nameEnd < bytes.count, Byte.isLetter(bytes[nameEnd]) || Byte.isDigit(bytes[nameEnd]) { nameEnd += 1 }
        // Letters and digits only, so setting bit 5 lowercases.
        let name = String(unsafeUninitializedCapacity: nameEnd - nameStart) { name in
            for k in nameStart..<nameEnd { name[k - nameStart] = bytes[k] | 0x20 }
            return nameEnd - nameStart
        }
        return (name, nameEnd)
    }

    private mutating func pop(to index: Int) {
        stack.removeSubrange(index...)
        topChanged()
    }

    private mutating func topChanged() {
        hidden = stack.last?.hidden ?? false
        whiteSpace = stack.last?.whiteSpace ?? .collapse
    }

    // MARK: - Attributes

    private func style(_ name: String, attributes: Range<Int>) -> HTMLTextStyle {
        var style = HTMLText.defaultStyleSheet.style(tag: name, classes: [], id: nil)
        if keepingSpacing, !documentSheet.isEmpty {
            let classes = attribute("class", in: attributes)?.split(whereSeparator: HTMLText.isWhitespace) ?? []
            let id = attribute("id", in: attributes).map { Substring($0) }
            style.override(with: documentSheet.style(tag: name, classes: classes, id: id))
        }
        if let inline = attribute("style", in: attributes) {
            style.override(with: HTMLTextStyle(declarations: inline.utf8))
        }
        return style
    }

    /// An attribute's entity-decoded value. Whole attributes are read, so a name
    /// inside another value cannot masquerade as an attribute.
    private func attribute(_ wanted: String, in range: Range<Int>) -> String? {
        var i = range.lowerBound
        let to = range.upperBound
        while i < to {
            while i < to, Byte.isWhitespace(bytes[i]) || bytes[i] == Byte.slash { i += 1 }
            let nameStart = i
            while i < to, !Byte.isWhitespace(bytes[i]), bytes[i] != Byte.equals { i += 1 }
            let name = bytes[nameStart..<i]
            while i < to, Byte.isWhitespace(bytes[i]) { i += 1 }
            guard i < to, bytes[i] == Byte.equals else { continue }
            i += 1
            while i < to, Byte.isWhitespace(bytes[i]) { i += 1 }
            guard i < to else { return nil }
            let quote = bytes[i] == 0x22 || bytes[i] == 0x27 ? bytes[i] : nil
            if quote != nil { i += 1 }
            let start = i
            while i < to, quote.map({ bytes[i] != $0 }) ?? !Byte.isWhitespace(bytes[i]) { i += 1 }
            let value = bytes[start..<i]
            if quote != nil, i < to { i += 1 }
            if name.count == wanted.utf8.count, zip(name, wanted.utf8).allSatisfy({ $0 | 0x20 == $1 }) {
                let raw = String(decoding: value, as: UTF8.self)
                // This tokenizer throws only for an invalid built-in entity table;
                // malformed references recover.
                return value.contains(Byte.ampersand) ? try! Parser.unescapeEntities(raw, true) : raw
            }
        }
        return nil
    }

    /// The `>` ending a tag; a `>` inside a quoted attribute value does not.
    private func tagEnd(from: Int) -> Int {
        var quote: UInt8?
        var beforeValue = false
        var unquotedValue = false
        var i = from
        while i < bytes.count {
            let byte = bytes[i]
            let whitespace = Byte.isWhitespace(byte)
            if let current = quote {
                if byte == current { quote = nil }
            } else if byte == Byte.greaterThan {
                return i
            } else if unquotedValue {
                if whitespace { unquotedValue = false }
            } else if beforeValue {
                if !whitespace {
                    beforeValue = false
                    if byte == 0x22 || byte == 0x27 { quote = byte } else { unquotedValue = true }
                }
            } else if byte == Byte.equals {
                beforeValue = true
            }
            i += 1
        }
        return bytes.count
    }

    /// The index just past the first `marker` at or after `from`, or the end.
    private func index(after marker: String, from: Int) -> Int {
        let marker = Array(marker.utf8)
        var j = from
        while let first = bytes[j...].firstIndex(of: marker[0]) {
            if bytes[first...].starts(with: marker) { return first + marker.count }
            j = first + 1
        }
        return bytes.count
    }
}
