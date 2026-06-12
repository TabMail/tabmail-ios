/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure, GRDB-free email filtering and parsing utilities.
/// Compiled into both the main app and the NSE via the Shared/ glob in project.yml.
///
/// Main-app-only functions that need GRDB (e.g. `isSelfSent`, which reads user
/// emails from AppDatabase) live in TabMail/Helpers/EmailFilter.swift as an extension.
enum EmailFilter {
    /// Convert plain-text email bodies to HTML preserving:
    /// - RFC 3676 `format=flowed` soft/hard line breaks (trailing space = soft wrap,
    ///   no trailing space = hard break; `"-- "` is always a hard break per the
    ///   signature-separator convention).
    /// - `>`-prefixed lines → `<blockquote>` (lets the quote-collapse JS find them).
    /// - Blank lines → `<div><br></div>` paragraph break.
    /// Wraps the result in `<div style="white-space:pre-wrap;">` so multiple
    /// spaces are preserved without extra escaping.
    static func plainTextToHTML(_ text: String) -> String {
        func escapeHTML(_ str: String) -> String {
            str.replacingOccurrences(of: "&", with: "&amp;")
               .replacingOccurrences(of: "<", with: "&lt;")
               .replacingOccurrences(of: ">", with: "&gt;")
        }

        let lines = text.components(separatedBy: "\n")
        var html = ""
        var quoteLines: [String] = []
        var pendingLines: [String] = []

        func flushQuotes() {
            guard !quoteLines.isEmpty else { return }
            html += "<blockquote>" + quoteLines.joined(separator: "<br>") + "</blockquote>"
            quoteLines = []
        }

        func flushPending() {
            guard !pendingLines.isEmpty else { return }
            html += "<div>" + pendingLines.joined() + "</div>"
            pendingLines = []
        }

        for line in lines {
            let stripped = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(">") {
                flushPending()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                quoteLines.append(escapeHTML(content))
            } else {
                flushQuotes()
                if trimmed.isEmpty {
                    flushPending()
                    html += "<div><br></div>"
                } else {
                    pendingLines.append(escapeHTML(stripped))
                    let isSoftWrap = stripped.hasSuffix(" ") && stripped != "-- "
                    if !isSoftWrap { flushPending() }
                }
            }
        }
        flushQuotes()
        flushPending()

        return "<div style=\"white-space:pre-wrap;\">" + html + "</div>"
    }

    /// Normalize an RFC 2822 Message-ID by stripping angle brackets and whitespace.
    /// Ensures consistent format for DB storage and comparison.
    static func normalizeMessageId(_ id: String) -> String {
        var s = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return s
    }

    /// Extract and normalize the first message ID from a potentially multi-value header.
    /// RFC 2822 In-Reply-To may contain multiple bracketed IDs:
    /// `<id1@example.com> <id2@example.com>` → `"id1@example.com"`
    /// Falls back to normalizeMessageId for single bare IDs.
    static func extractFirstMessageId(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try to extract the first angle-bracketed ID
        if let openIdx = trimmed.firstIndex(of: "<"),
           let closeIdx = trimmed[trimmed.index(after: openIdx)...].firstIndex(of: ">") {
            let inner = String(trimmed[trimmed.index(after: openIdx)..<closeIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        // No brackets — treat as single bare ID, normalize
        let normalized = normalizeMessageId(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    /// Matches TB's isNoReplyAddress() in messagePrefilter.js — same pattern list.
    /// When adding patterns, add tests — but NEVER with real-world sender
    /// addresses (real companies/orgs/domains); use generic placeholder domains.
    static func isNoReply(_ address: String) -> Bool {
        let lower = address.lowercased()
        // TB checks: noreply, no-reply, no_reply, donotreply, do-not-reply, do_not_reply,
        // auto-confirm, auto_confirm, autoconfirm,
        // notifications, automated, invitations, announcements, updates, newsletters,
        // newsletter, digests, digest
        let patterns = [
            "noreply", "no-reply", "no_reply",
            "donotreply", "do-not-reply", "do_not_reply",
            "auto-confirm", "auto_confirm", "autoconfirm",
            "notifications", "automated", "invitations",
            "announcements", "updates", "newsletters",
            "newsletter", "digests", "digest",
        ]
        return patterns.contains { lower.contains($0) }
    }

    /// Matches TB's hasUnsubscribeLink() in messagePrefilter.js.
    /// TB checks: List-Unsubscribe header, Precedence: bulk/list header, body text patterns.
    /// iOS doesn't have MIME headers at this point, so we check HTML body with the same
    /// text patterns TB uses (plus "list-unsubscribe" for header-in-body forwarding).
    static func hasUnsubscribeLink(_ html: String?) -> Bool {
        guard let html = html?.lowercased() else { return false }
        // Check for List-Unsubscribe header (may appear in raw HTML for forwarded/displayed headers)
        if html.contains("list-unsubscribe") { return true }
        // TB's body text patterns — require nearby http/www/click to avoid false positives
        let patterns = ["unsubscribe", "opt out", "opt-out",
                        "update your preferences", "manage your subscription",
                        "manage subscription", "email preferences"]
        let hasPattern = patterns.contains { html.contains($0) }
        if hasPattern && (html.contains("http") || html.contains("www") || html.contains("click")) {
            return true
        }
        return false
    }

    /// Decodes common HTML entities in a string (e.g. Gmail API snippets).
    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        return result
    }

    /// Uniform cleanup for provider-supplied snippets (IMAP, Gmail, Exchange).
    /// Decodes HTML entities, collapses whitespace/newlines, strips invisible chars, truncates.
    /// All header-creation sites MUST use this instead of raw `info.snippet`.
    static func cleanSnippet(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        return snippetFromPlainText(decodeHTMLEntities(raw))
    }

    /// Collapse whitespace in plain text and take first `maxChars` characters.
    /// Use for snippet extraction from textBody (already plain text, but may contain
    /// newlines, tabs, signature separators, etc. that need collapsing).
    static func snippetFromPlainText(_ text: String, maxChars: Int = 150) -> String {
        // Truncate early — only need ~500 chars to guarantee 150 clean chars
        let truncated = text.prefix(500)
        var result = ""
        result.reserveCapacity(maxChars)
        var lastWasSpace = true
        var lastChar: Character = " "
        for c in truncated {
            if c.isWhitespace || c.isNewline {
                if !lastWasSpace { result.append(" "); lastWasSpace = true; lastChar = " " }
            } else if let scalar = c.unicodeScalars.first, isInvisibleScalarValue(scalar.value) {
                // Skip invisible Unicode characters (zero-width spaces, soft hyphens, etc.)
                continue
            } else if c == lastChar && (c == "-" || c == "_" || c == "=" || c == "*") {
                // Collapse repeated separator characters (e.g. "------------" → "-")
                continue
            } else {
                result.append(c)
                lastWasSpace = false
                lastChar = c
            }
            if result.count >= maxChars { break }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Extract plain text from a fetched message body for FTS indexing.
    /// HTML is source of truth — uses `htmlToPlainText()` (the battle-tested UTF-8
    /// byte-level parser that handles display:none, <style>/<script>/<head> skipping,
    /// HTML entity decoding, block-level newlines).
    /// text/plain is fallback only when HTML is absent.
    /// Returns nil if both are empty/nil (confirmed empty body).
    static func extractPlainText(htmlBody: String?, textBody: String?) -> String? {
        if let html = htmlBody, !html.isEmpty {
            return htmlToPlainText(html)
        }
        if let text = textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Guard: don't trust the declared content type — some senders put the
            // full HTML document into the text/plain part (the snippet/FTS would
            // otherwise index tag soup). Display path is unaffected (BodyRenderer).
            return looksLikeHTMLDocument(text) ? htmlToPlainText(text) : text
        }
        return nil
    }

    /// True when a "plain text" body is actually a full HTML document — some
    /// senders put the entire HTML document into the text/plain MIME part.
    /// Only a document marker at the very start counts (`<!DOCTYPE` / `<html`):
    /// that is never legitimate prose, so ordinary plain text containing angle
    /// brackets (`<user@example.com>`, `List<String>`, `a < b`) can never match.
    /// Deliberately narrower than a generic "looks like HTML" tag heuristic —
    /// see BodyRenderer's display-path comment for why broad guessing is unsafe.
    /// Mirrors `looksLikeHtmlDocument` in the TB addon's fts/bodyExtract.js.
    static func looksLikeHTMLDocument(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0.isWhitespace })
        if trimmed.prefix(9).lowercased() == "<!doctype" { return true }
        if trimmed.prefix(5).lowercased() == "<html" {
            let next = trimmed.dropFirst(5).first
            return next == ">" || next?.isWhitespace == true
        }
        return false
    }

    /// Strips HTML to plain text suitable for FTS indexing.
    /// Single-pass UTF-8 byte scanner — O(1) extra memory (no copy of the input).
    /// Skips <style>/<script>/<head> block content, strips tags, decodes entities,
    /// and collapses whitespace in one pass.
    /// All HTML structural characters (< > & ; / ! -) are ASCII, so byte-level
    /// comparison is always correct — ASCII bytes never appear inside multi-byte
    /// UTF-8 sequences.
    static func htmlToPlainText(_ html: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(html.utf8.count / 4)
        var lastWasSpace = true

        // Zero-copy access to the string's UTF-8 bytes via withUTF8.
        // Falls back to a 1x copy only for bridged NSStrings (rare).
        var mutableHTML = html
        mutableHTML.withUTF8 { buf in
            let bytes = buf.baseAddress!
            let count = buf.count
            var i = 0

            while i < count {
                let b = bytes[i]

                // Tag or comment start: '<'
                if b == 0x3C, i + 1 < count {
                    // Comment: <!-- ... -->
                    if i + 3 < count, bytes[i+1] == 0x21, bytes[i+2] == 0x2D, bytes[i+3] == 0x2D {
                        i = skipPastBytes(bytes, count: count, from: i, marker: (0x2D, 0x2D, 0x3E), len: 3) // "-->"
                        if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                        continue
                    }

                    // Read tag name (skip '/' for closing tags)
                    var ns = i + 1
                    if ns < count, bytes[ns] == 0x2F { ns += 1 }
                    let (tagName, tagLen) = readTagNameBytes(bytes, count: count, from: ns)

                    // Block-level tags that suppress all content until closing tag
                    if tagLen > 0 && (tagName == "style" || tagName == "script" || tagName == "head" || tagName == "title") {
                        // Skip past opening tag '>'
                        while i < count, bytes[i] != 0x3E { i += 1 }
                        if i < count { i += 1 }
                        // For <head>: also stop at <body> — HTML5 allows implicit </head>.
                        // Without this, a missing </head> causes skipPastCloseTag to consume
                        // the entire document, producing an empty snippet.
                        if tagName == "head" {
                            i = skipPastCloseTagOrBody(bytes, count: count, from: i)
                        } else {
                            i = skipPastCloseTag(bytes, count: count, from: i, tag: tagName)
                        }
                        if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                        continue
                    }

                    // Opening tags with display:none — skip all content to matching close tag
                    let isClosing = (i + 1 < count && bytes[i + 1] == 0x2F)
                    if tagLen > 0 && !isClosing {
                        // Scan tag attributes (between tag name and '>') for display:none
                        let tagAttrStart = ns + tagLen
                        var tagEnd = tagAttrStart
                        while tagEnd < count, bytes[tagEnd] != 0x3E { tagEnd += 1 }
                        if tagEnd > tagAttrStart && hasDisplayNone(bytes, from: tagAttrStart, to: tagEnd) {
                            // Skip past opening tag '>'
                            i = tagEnd
                            if i < count { i += 1 }
                            // Void elements (img, br, hr, input, meta, link, source, col, embed,
                            // area, wbr, track) have no closing tag — just skip past the opening
                            // tag. Calling skipPastCloseTagNested on them would scan to EOF.
                            let isVoid: Bool
                            switch tagName {
                            case "img", "br", "hr", "input", "meta", "link", "source", "col",
                                 "embed", "area", "wbr", "track", "base", "param":
                                isVoid = true
                            default:
                                isVoid = false
                            }
                            if !isVoid {
                                // Skip past </tagname>, handling nested same-tag elements
                                i = skipPastCloseTagNested(bytes, count: count, from: i, tag: tagName)
                            }
                            if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                            continue
                        }
                    }

                    // Check if this is a block-level tag or <br> — emit newline
                    let isBlockTag: Bool
                    switch tagName {
                    case "div", "p", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                         "blockquote", "pre", "hr", "table", "section", "article", "header", "footer":
                        isBlockTag = true
                    default:
                        isBlockTag = false
                    }
                    let isBlock = tagLen > 0 && isBlockTag
                    let isBr = tagLen > 0 && tagName == "br"

                    // Regular tag — skip to '>'
                    while i < count, bytes[i] != 0x3E { i += 1 }
                    if i < count { i += 1 }

                    if isBr || (isBlock && isClosing) {
                        // Block-level close tags and <br> → newline
                        out.append(0x0A) // '\n'
                        lastWasSpace = true
                    } else if !lastWasSpace {
                        out.append(0x20)
                        lastWasSpace = true
                    }
                    continue
                }

                // Entity: '&'
                if b == 0x26, i + 1 < count {
                    let (decoded, advance) = decodeEntityBytes(bytes, count: count, from: i)
                    if let decoded {
                        if decoded.utf8.count == 1, decoded.utf8.first == 0x20 {
                            // space
                            if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                        } else if decoded == "\u{00A0}" {
                            // non-breaking space → space
                            if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                        } else if Self.isInvisibleScalar(decoded) {
                            // Invisible chars (soft hyphen, zero-width spaces, etc.) — skip
                        } else {
                            for byte in decoded.utf8 { out.append(byte) }
                            lastWasSpace = false
                        }
                        i += advance
                        continue
                    }
                }

                // ASCII whitespace: space, tab, LF, CR
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                    i += 1
                    continue
                }

                // Non-ASCII byte — copy through entire UTF-8 sequence
                if b >= 0x80 {
                    // U+00A0 (no-break space) = 0xC2 0xA0
                    if b == 0xC2, i + 1 < count, bytes[i+1] == 0xA0 {
                        if !lastWasSpace { out.append(0x20); lastWasSpace = true }
                        i += 2
                        continue
                    }
                    // 2-byte invisible characters — skip entirely
                    // U+00AD (soft hyphen) = 0xC2 0xAD
                    // U+034F (combining grapheme joiner) = 0xCD 0x8F
                    if b == 0xC2, i + 1 < count, bytes[i+1] == 0xAD {
                        i += 2; continue
                    }
                    if b == 0xCD, i + 1 < count, bytes[i+1] == 0x8F {
                        i += 2; continue
                    }
                    // 3-byte invisible characters
                    if b == 0xE2, i + 2 < count {
                        let b1 = bytes[i+1], b2 = bytes[i+2]
                        // U+200B (zero-width space), U+200C (ZWNJ), U+200D (ZWJ)
                        if b1 == 0x80, b2 >= 0x8B, b2 <= 0x8D {
                            i += 3; continue
                        }
                        // U+2060 (word joiner)
                        if b1 == 0x81, b2 == 0xA0 {
                            i += 3; continue
                        }
                    }
                    // U+FEFF (BOM / zero-width no-break space) = 0xEF 0xBB 0xBF
                    if b == 0xEF, i + 2 < count, bytes[i+1] == 0xBB, bytes[i+2] == 0xBF {
                        i += 3; continue
                    }
                    let seqLen = utf8SeqLen(b)
                    let end = min(i + seqLen, count)
                    for j in i..<end { out.append(bytes[j]) }
                    lastWasSpace = false
                    i = end
                    continue
                }

                // Regular ASCII content
                out.append(b)
                lastWasSpace = false
                i += 1
            }
        }

        // Trim trailing whitespace (space, newline, CR, tab)
        while let last = out.last, last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 {
            out.removeLast()
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    // MARK: - UTF-8 byte scanner helpers

    /// Length of a UTF-8 multi-byte sequence given the leading byte.
    /// Returns true if `v` is an invisible Unicode scalar value (zero-width spaces,
    /// soft hyphen, combining grapheme joiner, word joiner, BOM).
    private static func isInvisibleScalarValue(_ v: UInt32) -> Bool {
        switch v {
        case 0x00AD, 0x034F, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    /// Returns true if `s` is a single invisible Unicode scalar.
    /// Used to skip invisible characters decoded from HTML entities.
    private static func isInvisibleScalar(_ s: String) -> Bool {
        guard s.unicodeScalars.count == 1, let v = s.unicodeScalars.first?.value else { return false }
        return isInvisibleScalarValue(v)
    }

    private static func utf8SeqLen(_ lead: UInt8) -> Int {
        if lead < 0xC0 { return 1 }      // continuation or ASCII (shouldn't happen here)
        if lead < 0xE0 { return 2 }      // 110xxxxx
        if lead < 0xF0 { return 3 }      // 1110xxxx
        return 4                           // 11110xxx
    }

    /// Read an ASCII tag name starting at `from`. Returns (lowercased name, length).
    private static func readTagNameBytes(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int) -> (String, Int) {
        var end = from
        while end < count {
            let b = bytes[end]
            let isAlpha = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) // A-Z, a-z
            let isDigit = b >= 0x30 && b <= 0x39 // 0-9
            guard isAlpha || isDigit else { break }
            end += 1
        }
        let len = end - from
        guard len > 0 else { return ("", 0) }
        // Build lowercased name (tag names are always short ASCII)
        var name = ""
        name.reserveCapacity(len)
        for j in from..<end {
            let b = bytes[j]
            name.append(Character(UnicodeScalar(b >= 0x41 && b <= 0x5A ? b + 32 : b)))
        }
        return (name, len)
    }

    /// Skip past a 3-byte ASCII marker (e.g. "-->"). Returns index after marker, or `count` if not found.
    private static func skipPastBytes(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int, marker: (UInt8, UInt8, UInt8), len: Int) -> Int {
        var j = from
        while j + 2 < count {
            if bytes[j] == marker.0, bytes[j+1] == marker.1, bytes[j+2] == marker.2 {
                return j + 3
            }
            j += 1
        }
        return count
    }

    /// Scan tag attribute bytes for `display` `:` (optional whitespace) `none` (case-insensitive).
    /// Catches inline styles like `style="display: none"`, `style="display:none; ..."`, etc.
    /// Operates on raw bytes between tag-name end and `>`.
    private static func hasDisplayNone(_ bytes: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool {
        // "display" = 7 bytes, ":" = 1, "none" = 4 → min 12 bytes needed
        guard to - from >= 12 else { return false }
        // Search for "display" (case-insensitive) then ":" then "none"
        let display: [UInt8] = [0x64, 0x69, 0x73, 0x70, 0x6C, 0x61, 0x79] // "display"
        let none: [UInt8] = [0x6E, 0x6F, 0x6E, 0x65] // "none"
        var j = from
        while j + 11 < to {
            // Match "display" (case-insensitive)
            var match = true
            for k in 0..<7 {
                let b = bytes[j + k]
                let lower = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
                if lower != display[k] { match = false; break }
            }
            guard match else { j += 1; continue }
            // Skip whitespace after "display"
            var p = j + 7
            while p < to, bytes[p] == 0x20 || bytes[p] == 0x09 { p += 1 }
            // Expect ':'
            guard p < to, bytes[p] == 0x3A else { j += 1; continue }
            p += 1
            // Skip whitespace after ':'
            while p < to, bytes[p] == 0x20 || bytes[p] == 0x09 { p += 1 }
            // Match "none" (case-insensitive)
            guard p + 4 <= to else { j += 1; continue }
            var noneMatch = true
            for k in 0..<4 {
                let b = bytes[p + k]
                let lower = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
                if lower != none[k] { noneMatch = false; break }
            }
            if noneMatch {
                // Verify word boundary: next char must not be alphanumeric (e.g. reject "none-block")
                let afterNone = p + 4
                if afterNone >= to { return true }
                let next = bytes[afterNone]
                let isAlpha = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
                let isDigit = next >= 0x30 && next <= 0x39
                let isHyphen = next == 0x2D // '-'
                if !isAlpha && !isDigit && !isHyphen { return true }
            }
            j += 1
        }
        return false
    }

    /// Skip past a closing tag, handling nested same-tag elements (e.g. `<div><div>...</div></div>`).
    /// Tracks nesting depth: increments on `<tag`, decrements on `</tag>`, returns after depth reaches 0.
    private static func skipPastCloseTagNested(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int, tag: String) -> Int {
        let tagBytes = Array(tag.utf8)
        let tagLen = tagBytes.count
        var depth = 1
        var j = from
        while j < count, depth > 0 {
            guard bytes[j] == 0x3C else { j += 1; continue } // '<'
            if j + 1 < count, bytes[j+1] == 0x2F { // '</'
                if matchesTag(bytes, count: count, at: j + 2, tagBytes: tagBytes, tagLen: tagLen) {
                    depth -= 1
                    // Skip past '>'
                    j += 2 + tagLen
                    while j < count, bytes[j] != 0x3E { j += 1 }
                    if j < count { j += 1 }
                    continue
                }
            } else {
                // Opening tag: skip '/' check position
                let ns = j + 1
                if matchesTag(bytes, count: count, at: ns, tagBytes: tagBytes, tagLen: tagLen) {
                    // Verify it's followed by whitespace, '>', or '/' (self-closing) — not a longer tag name
                    let afterTag = ns + tagLen
                    if afterTag < count {
                        let c = bytes[afterTag]
                        if c == 0x3E || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F {
                            depth += 1
                        }
                    }
                }
            }
            j += 1
        }
        return j
    }

    /// Check if bytes at `at` match `tagBytes` (case-insensitive).
    private static func matchesTag(_ bytes: UnsafePointer<UInt8>, count: Int, at: Int, tagBytes: [UInt8], tagLen: Int) -> Bool {
        guard at + tagLen <= count else { return false }
        for k in 0..<tagLen {
            let b = bytes[at + k]
            let lower = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
            if lower != tagBytes[k] { return false }
        }
        return true
    }

    /// Skip past a closing tag like </style> (case-insensitive). Returns index after the tag.
    private static func skipPastCloseTag(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int, tag: String) -> Int {
        let tagBytes = Array(tag.utf8)
        let tagLen = tagBytes.count
        // Looking for: '<' '/' tagBytes '>'
        let patternLen = 2 + tagLen + 1 // </ + tag + >
        var j = from
        while j + patternLen <= count {
            if bytes[j] == 0x3C, bytes[j+1] == 0x2F { // '</'
                var match = true
                for k in 0..<tagLen {
                    let a = bytes[j + 2 + k]
                    let aLower = (a >= 0x41 && a <= 0x5A) ? a + 32 : a
                    if aLower != tagBytes[k] { match = false; break }
                }
                if match, bytes[j + 2 + tagLen] == 0x3E { // '>'
                    return j + patternLen
                }
            }
            j += 1
        }
        return count
    }

    /// Skip past `</head>` OR `<body` (whichever comes first).
    /// HTML5 allows implicit `</head>` — `<body>` starts the body section automatically.
    /// Returns index after `</head>` or at the `<` of `<body`, so the main loop processes `<body>` normally.
    private static func skipPastCloseTagOrBody(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int) -> Int {
        let headBytes: [UInt8] = [0x68, 0x65, 0x61, 0x64] // "head"
        let bodyBytes: [UInt8] = [0x62, 0x6F, 0x64, 0x79] // "body"
        var j = from
        while j < count {
            guard bytes[j] == 0x3C else { j += 1; continue } // '<'
            // Check for </head>
            if j + 6 < count, bytes[j + 1] == 0x2F { // '</'
                var match = true
                for k in 0..<4 {
                    let b = bytes[j + 2 + k]
                    let lower = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
                    if lower != headBytes[k] { match = false; break }
                }
                if match {
                    // Skip past '>'
                    var end = j + 6
                    while end < count, bytes[end] != 0x3E { end += 1 }
                    if end < count { end += 1 }
                    return end
                }
            }
            // Check for <body (opening tag — implicit </head>)
            if j + 5 <= count, bytes[j + 1] != 0x2F { // not '</'
                var match = true
                for k in 0..<4 {
                    let b = bytes[j + 1 + k]
                    let lower = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
                    if lower != bodyBytes[k] { match = false; break }
                }
                if match {
                    // Verify word boundary: next char must be space, '>', '/' or end
                    let afterTag = j + 5
                    if afterTag >= count || bytes[afterTag] == 0x3E || bytes[afterTag] == 0x20 || bytes[afterTag] == 0x09 || bytes[afterTag] == 0x0A || bytes[afterTag] == 0x0D || bytes[afterTag] == 0x2F {
                        return j // return at '<body' so main loop processes it
                    }
                }
            }
            j += 1
        }
        return count
    }

    /// Decode an HTML entity at `from` (pointing to '&'). Returns (decoded string, bytes consumed).
    private static func decodeEntityBytes(_ bytes: UnsafePointer<UInt8>, count: Int, from: Int) -> (String?, Int) {
        var end = from + 1
        let limit = min(from + 12, count)
        while end < limit {
            if bytes[end] == 0x3B { break } // ';'
            end += 1
        }
        guard end < limit, bytes[end] == 0x3B else { return (nil, 1) }

        let bodyLen = end - from - 1
        guard bodyLen > 0 else { return (nil, 1) }
        // Extract entity body as ASCII string (entities are always ASCII)
        var entityBody = ""
        entityBody.reserveCapacity(bodyLen)
        for j in (from + 1)..<end {
            entityBody.append(Character(UnicodeScalar(bytes[j])))
        }
        let advance = end - from + 1

        // Numeric entities
        if entityBody.hasPrefix("#x") || entityBody.hasPrefix("#X") {
            let hex = String(entityBody.dropFirst(2))
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                return (String(scalar), advance)
            }
            return (" ", advance)
        }
        if entityBody.hasPrefix("#") {
            let dec = String(entityBody.dropFirst(1))
            if let code = UInt32(dec), let scalar = Unicode.Scalar(code) {
                return (String(scalar), advance)
            }
            return (" ", advance)
        }

        // Named entities (common ones)
        switch entityBody {
        case "amp": return ("&", advance)
        case "lt": return ("<", advance)
        case "gt": return (">", advance)
        case "quot": return ("\"", advance)
        case "apos": return ("'", advance)
        case "nbsp": return (" ", advance)
        case "ndash": return ("\u{2013}", advance)
        case "mdash": return ("\u{2014}", advance)
        case "lsquo": return ("\u{2018}", advance)
        case "rsquo": return ("\u{2019}", advance)
        case "ldquo": return ("\u{201C}", advance)
        case "rdquo": return ("\u{201D}", advance)
        case "bull": return ("\u{2022}", advance)
        case "hellip": return ("\u{2026}", advance)
        case "copy": return ("\u{00A9}", advance)
        case "reg": return ("\u{00AE}", advance)
        case "trade": return ("\u{2122}", advance)
        case "shy": return ("\u{00AD}", advance)
        case "zwj": return ("\u{200D}", advance)
        case "zwnj": return ("\u{200C}", advance)
        default: return (" ", advance)
        }
    }

    // MARK: - Embedded .eml Section Metadata

    /// Envelope metadata carried on a `.tm-eml-section` marker div as `data-*`
    /// attributes. Parsed in Swift so `EmlAttachmentPreview` can render a native
    /// message-card-style header.
    struct EmlSectionMetadata: Sendable, Equatable {
        var filename: String
        var partSection: String?
        var subject: String?
        var from: String?
        /// ISO-8601 string as emitted by the renderer. `date` parses it on demand.
        var dateISO: String?
        var toList: String?
        var ccList: String?

        var date: Date? {
            guard let iso = dateISO else { return nil }
            return Date.fromISO8601(iso)
        }
    }

    /// Find the `<div class="tm-eml-section">` marker whose `data-filename` matches
    /// `filename` and parse its `data-*` attributes. Returns `nil` if no matching
    /// marker is found — caller should fall back to rendering without a header.
    static func parseEmlSectionMetadata(html: String, filename: String) -> EmlSectionMetadata? {
        let scalars = Array(html.unicodeScalars)
        let count = scalars.count
        var i = 0
        while i < count {
            if scalars[i].value == 0x3C,
               let openEnd = matchEmlSectionOpen(scalars, count: count, from: i) {
                let openTagStart = i
                let openTagEnd = openEnd // points AFTER `>`
                let attrsRegion = (openTagStart + 4)..<(openTagEnd - 1) // inside `<div` … `>`
                if let fn = attrValue(scalars, range: attrsRegion, name: "data-filename"),
                   decodeHTMLEntities(fn) == filename {
                    let sec = attrValue(scalars, range: attrsRegion, name: "data-part-section").map(decodeHTMLEntities)
                    let subj = attrValue(scalars, range: attrsRegion, name: "data-subject").map(decodeHTMLEntities)
                    let from = attrValue(scalars, range: attrsRegion, name: "data-from").map(decodeHTMLEntities)
                    let dateISO = attrValue(scalars, range: attrsRegion, name: "data-date").map(decodeHTMLEntities)
                    let to = attrValue(scalars, range: attrsRegion, name: "data-to").map(decodeHTMLEntities)
                    let cc = attrValue(scalars, range: attrsRegion, name: "data-cc").map(decodeHTMLEntities)
                    return EmlSectionMetadata(
                        filename: filename,
                        partSection: sec,
                        subject: subj,
                        from: from,
                        dateISO: dateISO,
                        toList: to,
                        ccList: cc
                    )
                }
                i = openEnd
                continue
            }
            i += 1
        }
        return nil
    }

    /// Find `name="…"` or `name='…'` inside `range`. Returns the raw attribute value
    /// (HTML-entity-decoded by the caller). Whitespace before the attribute name is
    /// required to avoid matching `data-filename` inside `xyzdata-filename`.
    private static func attrValue(_ scalars: [Unicode.Scalar], range: Range<Int>, name: String) -> String? {
        let nameScalars = Array(name.unicodeScalars)
        let nLen = nameScalars.count
        let from = range.lowerBound
        let to = range.upperBound
        guard to - from >= nLen + 3 else { return nil } // name="" minimum
        var j = from
        while j + nLen < to {
            // Require whitespace or start-of-region before attribute name
            if j > from {
                let prev = scalars[j - 1].value
                let isBoundary = prev == 0x20 || prev == 0x09 || prev == 0x0A || prev == 0x0D
                if !isBoundary { j += 1; continue }
            }
            var match = true
            for k in 0..<nLen {
                let v = scalars[j + k].value | 0x20
                if v != (nameScalars[k].value | 0x20) { match = false; break }
            }
            guard match else { j += 1; continue }
            var p = j + nLen
            while p < to, scalars[p].value == 0x20 || scalars[p].value == 0x09 { p += 1 }
            guard p < to, scalars[p].value == 0x3D else { j += 1; continue }
            p += 1
            while p < to, scalars[p].value == 0x20 || scalars[p].value == 0x09 { p += 1 }
            guard p < to else { return nil }
            let q = scalars[p].value
            guard q == 0x22 || q == 0x27 else { j += 1; continue }
            let valueStart = p + 1
            var valueEnd = valueStart
            while valueEnd < to, scalars[valueEnd].value != q { valueEnd += 1 }
            guard valueEnd <= to else { return nil }
            var out = ""
            out.reserveCapacity(valueEnd - valueStart)
            for k in valueStart..<valueEnd {
                out.unicodeScalars.append(scalars[k])
            }
            return out
        }
        return nil
    }

    // MARK: - Embedded .eml Section Stripping

    /// Remove `<div class="tm-eml-section">…</div>` blocks from HTML.
    /// Used by reply/forward quoting so only the primary message body is quoted —
    /// forwarded-as-attachment emails stay as attachments, not quoted text.
    ///
    /// FTS indexing does NOT use this — it wants the full text for searchability.
    ///
    /// The marker div is emitted by `IMAPProvider.renderBodyWithEmbeddedHeaders`
    /// in the exact form `<div class="tm-eml-section" data-filename="…" …>`. This
    /// helper matches `<div class="tm-eml-section"` as a prefix (whitespace-insensitive
    /// between `<div` and `class`, case-insensitive for tag), then walks forward
    /// counting nested `<div>` openings until the matching `</div>` is reached.
    static func stripEmbeddedEmlSections(_ html: String) -> String {
        // Fast path: no marker anywhere
        if html.range(of: "tm-eml-section", options: [.caseInsensitive]) == nil {
            return html
        }

        var result = ""
        result.reserveCapacity(html.count)

        let scalars = Array(html.unicodeScalars)
        let count = scalars.count
        var i = 0

        while i < count {
            let c = scalars[i].value
            // Look for '<'
            if c == 0x3C {
                // Try to match opening marker: <div ...class="tm-eml-section"... >
                if let openEnd = matchEmlSectionOpen(scalars, count: count, from: i) {
                    // Skip this entire block: walk forward counting <div>/</div> depth
                    var depth = 1
                    var j = openEnd
                    while j < count, depth > 0 {
                        guard scalars[j].value == 0x3C else { j += 1; continue }
                        // </div>
                        if isCloseDiv(scalars, count: count, from: j) {
                            depth -= 1
                            // Skip to after '>'
                            while j < count, scalars[j].value != 0x3E { j += 1 }
                            if j < count { j += 1 }
                            continue
                        }
                        // <div ...>
                        if isOpenDiv(scalars, count: count, from: j) {
                            depth += 1
                            // Skip to after '>'
                            while j < count, scalars[j].value != 0x3E { j += 1 }
                            if j < count { j += 1 }
                            continue
                        }
                        j += 1
                    }
                    i = j
                    continue
                }
            }
            // Copy scalar through
            result.unicodeScalars.append(scalars[i])
            i += 1
        }

        return result
    }

    /// Try to match `<div ... class="tm-eml-section" ... >` starting at `from` (which
    /// must point at `<`). Returns the index just after the closing `>` on success, or
    /// `nil` if this is not an opening `.tm-eml-section` div.
    private static func matchEmlSectionOpen(_ scalars: [Unicode.Scalar], count: Int, from: Int) -> Int? {
        // Require "<div" followed by whitespace
        guard from + 4 < count else { return nil }
        guard scalars[from].value == 0x3C else { return nil }
        let d0 = scalars[from + 1].value | 0x20
        let d1 = scalars[from + 2].value | 0x20
        let d2 = scalars[from + 3].value | 0x20
        guard d0 == 0x64, d1 == 0x69, d2 == 0x76 else { return nil } // "div"
        let after = scalars[from + 4].value
        guard after == 0x20 || after == 0x09 || after == 0x0A || after == 0x0D else { return nil }

        // Find closing '>'
        var end = from + 4
        while end < count, scalars[end].value != 0x3E { end += 1 }
        guard end < count else { return nil }

        // Search the attribute region for class containing tm-eml-section
        let attrStart = from + 4
        guard let classRange = findClassAttr(scalars, from: attrStart, to: end) else { return nil }
        // classRange is the value region (between quotes). Check for "tm-eml-section" token.
        if containsToken(scalars, from: classRange.lowerBound, to: classRange.upperBound, token: "tm-eml-section") {
            return end + 1
        }
        return nil
    }

    /// Locate `class="..."` or `class='...'` in attribute region. Returns the range
    /// of the value (excluding the quotes).
    private static func findClassAttr(_ scalars: [Unicode.Scalar], from: Int, to: Int) -> Range<Int>? {
        let classBytes: [UInt32] = [0x63, 0x6C, 0x61, 0x73, 0x73] // "class"
        var j = from
        while j + 5 < to {
            // Match word "class" at j (requires preceding boundary: start or whitespace)
            if j > from {
                let prev = scalars[j - 1].value
                let prevIsBoundary = prev == 0x20 || prev == 0x09 || prev == 0x0A || prev == 0x0D
                if !prevIsBoundary { j += 1; continue }
            }
            var match = true
            for k in 0..<5 {
                let v = scalars[j + k].value | 0x20
                if v != classBytes[k] { match = false; break }
            }
            guard match else { j += 1; continue }
            var p = j + 5
            // Optional whitespace, then '='
            while p < to, scalars[p].value == 0x20 || scalars[p].value == 0x09 { p += 1 }
            guard p < to, scalars[p].value == 0x3D else { j += 1; continue } // '='
            p += 1
            while p < to, scalars[p].value == 0x20 || scalars[p].value == 0x09 { p += 1 }
            // Expect a quote
            guard p < to else { return nil }
            let q = scalars[p].value
            guard q == 0x22 || q == 0x27 else { j += 1; continue } // " or '
            let valueStart = p + 1
            var valueEnd = valueStart
            while valueEnd < to, scalars[valueEnd].value != q { valueEnd += 1 }
            guard valueEnd <= to else { return nil }
            return valueStart..<valueEnd
        }
        return nil
    }

    /// Check if the space-separated token list in `[from, to)` contains `token`.
    private static func containsToken(_ scalars: [Unicode.Scalar], from: Int, to: Int, token: String) -> Bool {
        let tokenScalars = Array(token.unicodeScalars)
        let tLen = tokenScalars.count
        var j = from
        while j <= to - tLen {
            // Verify boundary at start
            if j > from {
                let prev = scalars[j - 1].value
                let prevIsBoundary = prev == 0x20 || prev == 0x09 || prev == 0x0A || prev == 0x0D
                if !prevIsBoundary { j += 1; continue }
            }
            var match = true
            for k in 0..<tLen {
                if scalars[j + k].value != tokenScalars[k].value { match = false; break }
            }
            if match {
                // Verify boundary at end
                let afterIdx = j + tLen
                if afterIdx >= to { return true }
                let after = scalars[afterIdx].value
                if after == 0x20 || after == 0x09 || after == 0x0A || after == 0x0D { return true }
            }
            j += 1
        }
        return false
    }

    /// Is `<div` (opening tag) at position `from` (pointing at `<`)?
    private static func isOpenDiv(_ scalars: [Unicode.Scalar], count: Int, from: Int) -> Bool {
        guard from + 4 < count else { return false }
        guard scalars[from].value == 0x3C else { return false }
        guard scalars[from + 1].value != 0x2F else { return false } // not '</'
        let d0 = scalars[from + 1].value | 0x20
        let d1 = scalars[from + 2].value | 0x20
        let d2 = scalars[from + 3].value | 0x20
        guard d0 == 0x64, d1 == 0x69, d2 == 0x76 else { return false }
        let after = scalars[from + 4].value
        return after == 0x20 || after == 0x09 || after == 0x0A || after == 0x0D || after == 0x3E || after == 0x2F
    }

    /// Is `</div>` at position `from` (pointing at `<`)?
    private static func isCloseDiv(_ scalars: [Unicode.Scalar], count: Int, from: Int) -> Bool {
        guard from + 5 < count else { return false }
        guard scalars[from].value == 0x3C, scalars[from + 1].value == 0x2F else { return false }
        let d0 = scalars[from + 2].value | 0x20
        let d1 = scalars[from + 3].value | 0x20
        let d2 = scalars[from + 4].value | 0x20
        guard d0 == 0x64, d1 == 0x69, d2 == 0x76 else { return false }
        // Next char must be whitespace or '>'
        let after = scalars[from + 5].value
        return after == 0x20 || after == 0x09 || after == 0x0A || after == 0x0D || after == 0x3E
    }

    // MARK: - Quote Detection Patterns (Single Source of Truth)

    /// Attribution line patterns shared between Swift `splitMessageAndQuotes` and JS `collapseQuotesJS`.
    /// Each entry is a JS-compatible regex string that matches a **single trimmed line** (anchored with ^...$).
    /// Keep in sync with TB's `quoteAndSignature.js` replyBoundaryPatterns.
    /// When adding a new language pattern, add it HERE — both Swift and JS consumers pick it up automatically.
    static let quoteAttributionPatterns: [(regex: String, comment: String, jsRegex: String)] = [
        // English: "On Mon, Jan 1, 2024 at 10:00 AM John wrote:"
        (#"^On\s+.+\s+wrote:\s*$"#, "English attribution (single-line)", #"^On\s+.+\s+wrote:\s*$"#),
        // German: "Am 1. Januar 2024 schrieb Max:"
        (#"^Am\s+.+\s+schrieb\s+.+:\s*$"#, "German attribution", #"^Am\s+.+\s+schrieb\s+.+:\s*$"#),
        // French: "Le 1 janvier 2024, Jean a écrit :"
        ("^Le\\s+.+\\s+a\\s+\u{00e9}crit\\s*:\\s*$", "French attribution", #"^Le\s+.+\s+a\s+\u00e9crit\s*:\s*$"#),
        // Spanish: "El 1 de enero de 2024, Juan escribió:"
        ("^El\\s+.+\\s+escribi\u{00f3}\\s*:\\s*$", "Spanish attribution", #"^El\s+.+\s+escribi\u00f3\s*:\s*$"#),
        // Italian: "Il 1 gennaio 2024, Giovanni ha scritto:"
        (#"^Il\s+.+\s+ha\s+scritto\s*:\s*$"#, "Italian attribution", #"^Il\s+.+\s+ha\s+scritto\s*:\s*$"#),
        // Portuguese: "Em 1 de janeiro de 2024, João escreveu:"
        (#"^Em\s+.+\s+.+\s+escreveu\s*:\s*$"#, "Portuguese attribution", #"^Em\s+.+\s+.+\s+escreveu\s*:\s*$"#),
        // Korean Gmail: "2026년 1월 22일 (목) AM 4:23, Name <email>님이 작성:"
        ("^.+\u{B2D8}\u{C774}\\s*\u{C791}\u{C131}\\s*:\\s*$", "Korean Gmail attribution", #"^.+\uB2D8\uC774\s*\uC791\uC131\s*:\s*$"#),
        // Chinese Gmail: "Name <email> 于2026年3月17日周二 01:16写道："
        ("^.+\u{4E8E}.+\u{5199}\u{9053}[\u{FF1A}:]\\s*$", "Chinese Gmail attribution", #"^.+\u4E8E.+\u5199\u9053[\uFF1A:]\s*$"#),
        // Generic: "NAME wrote:" (keep last — least specific)
        (#"^.+\s+wrote:\s*$"#, "Generic wrote attribution", #"^.+\s+wrote:\s*$"#),
    ]

    /// Structural (non-attribution) quote boundary patterns for full-body matching.
    /// These have complex multi-line logic in JS (lookahead, header scanning) that can't be
    /// expressed as single-line regexes, so they're defined separately for Swift only.
    private static let quoteStructuralPatterns: [String] = [
        // Outlook full: From:/Sent:/To:
        #"\n\s*From:\s*.+?\n\s*(?:Sent|Date):\s*.+?\n\s*To:\s*.+?\n"#,
        // Outlook short: From:/Sent:
        #"\n\s*From:\s*.+?\n\s*(?:Sent|Date):\s*.+?\n"#,
        // Thunderbird forward
        #"\n\s*-{4,}\s*Forwarded Message\s*-{4,}\s*\n"#,
        // Generic forward/original message
        #"\n\s*-{4,}\s*(?:Original Message|Forwarded Message)\s*-{4,}\s*\n"#,
        // Apple Mail forward
        #"\n\s*Begin forwarded message:\s*\n"#,
    ]

    /// Generate JS `if` blocks for attribution pattern matching, for injection into `collapseQuotesJS`.
    /// Uses pre-defined `jsRegex` field (JS-compatible regex with `\uXXXX` escapes).
    /// The output is interpolated via `\(...)` into a `"""` string — interpolated values are NOT
    /// re-processed by Swift's string escape rules, so `jsRegex` is used as-is (no double-escaping).
    static func quoteAttributionPatternsAsJS() -> String {
        quoteAttributionPatterns.map { attr in
            // jsRegex at runtime already contains the correct JS regex escapes (\s, \uXXXX).
            // String interpolation into """ pastes the runtime value verbatim — no extra escaping needed.
            let comment = attr.comment.replacingOccurrences(of: "'", with: "\\'")
            return "if (/\(attr.jsRegex)/i.test(trimmed)) { _log('[QuoteDetect] MATCH \(comment) at line ' + i); boundaryLine = i; break; }"
        }.joined(separator: "\n            ")
    }

    // MARK: - Quote Splitting

    /// Split plaintext email body into (message, quotes).
    /// Matches the backend's `splitMessageAndQuotes` and TB's `splitPlainTextForQuote`.
    /// Returns (mainMessage, quotedSection). If no quote boundary is found, quotes is empty.
    static func splitMessageAndQuotes(_ body: String) -> (message: String, quotes: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        // Build regex list: structural patterns (full-body) + attribution patterns (converted from line to full-body)
        var patternStrings = quoteStructuralPatterns
        for attr in quoteAttributionPatterns {
            // Convert ^...$ per-line pattern to \n\s*...\s*\n full-body pattern
            var p = attr.regex
            if p.hasPrefix("^") { p = String(p.dropFirst()) }
            if p.hasSuffix("$") { p = String(p.dropLast()) }
            patternStrings.append(#"\n\s*"# + p + #"\s*\n"#)
        }

        let regexes = patternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }

        let nsBody = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        var earliestPos = nsBody.length

        for regex in regexes {
            if let match = regex.firstMatch(in: trimmed, range: fullRange) {
                if match.range.location < earliestPos {
                    earliestPos = match.range.location
                }
            }
        }

        // Fallback: consecutive > quoted lines
        if earliestPos == nsBody.length {
            let lines = trimmed.components(separatedBy: .newlines)
            var charOffset = 0
            for i in 0..<lines.count {
                if lines[i].hasPrefix(">") && i + 1 < lines.count && lines[i + 1].hasPrefix(">") {
                    earliestPos = charOffset
                    break
                }
                charOffset += lines[i].count + 1 // +1 for newline
            }
        }

        guard earliestPos < nsBody.length else {
            return (trimmed, "")
        }

        let message = (nsBody.substring(to: earliestPos) as String).trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = (nsBody.substring(from: earliestPos) as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return (message, quotes)
    }
}
