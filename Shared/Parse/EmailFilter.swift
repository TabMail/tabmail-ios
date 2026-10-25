/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

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
                    if !isFlowedSoftBreak(stripped) { flushPending() }
                }
            }
        }
        flushQuotes()
        flushPending()

        return "<div style=\"white-space:pre-wrap;\">" + html + "</div>"
    }

    /// RFC 3676: a line ending in a space is soft-broken (it continues on the next
    /// line); the signature separator `"-- "` is always a hard break. The space is
    /// read as a scalar: as a Character, a Prepend scalar before it (U+0605) would
    /// join it.
    static func isFlowedSoftBreak(_ line: String) -> Bool {
        line.unicodeScalars.last == " " && line != "-- "
    }

    /// The text an RFC 3676 `format=flowed` body stands for, when `contentType`
    /// declares it; any other text is returned unchanged. Each soft-broken line
    /// (`isFlowedSoftBreak`) joins the next line of the same quote depth, unless
    /// that is the signature separator; a space-stuffed line loses its stuffing
    /// space; with `delsp=yes` the space that marked the soft break goes too.
    /// Quoted lines are written back as one `">"` per depth and a space
    /// (`">> text"`).
    static func decodeFormatFlowed(_ text: String, contentType: String) -> String {
        // SwiftMail's MIME parameter reader: quoted values, comments, any name case.
        let part = MessagePart(sectionString: "1", contentType: contentType)
        guard part.contentTypeParameter(named: "format")?.lowercased() == "flowed" else { return text }
        let delSp = part.contentTypeParameter(named: "delsp")?.lowercased() == "yes"

        var lines: [String] = []
        var paragraph: String?
        var paragraphDepth = 0
        func endParagraph() {
            guard let content = paragraph else { return }
            let quote = String(repeating: ">", count: paragraphDepth)
            lines.append(paragraphDepth == 0 || content.isEmpty ? quote + content : quote + " " + content)
            paragraph = nil
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            // Quote marks and the stuffed space are ASCII bytes (RFC 3676 §4.5), read
            // as scalars: as Characters, a combining mark after one would join it.
            var rest = line.unicodeScalars[...]
            let depth = rest.prefix { $0 == ">" }.count
            rest = rest.dropFirst(depth)
            if rest.first == " " { rest = rest.dropFirst() }
            var content = String(Substring(rest))
            // The signature separator is neither fixed nor flowed (RFC 3676 §4.3):
            // it is a line of its own. Read before `delsp=yes` drops a soft break's
            // space, which would turn a flowed "--  " into one.
            let isSignature = content == "-- "
            let isSoft = isFlowedSoftBreak(content)
            if isSoft, delSp { content = String(content.unicodeScalars.dropLast()) }
            if paragraph != nil, depth != paragraphDepth || isSignature { endParagraph() }
            paragraph = (paragraph ?? "") + content
            paragraphDepth = depth
            if !isSoft { endParagraph() }
        }
        endParagraph()
        return lines.joined(separator: "\n")
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
        // Truncate early — the loop below stops at `maxChars`, so only a bounded
        // window of input is ever read. Markdown links are unwrapped INSIDE that
        // window (#148): a link longer than the window degrades to raw Markdown
        // instead of walking the body.
        // The window is counted in UNICODE SCALARS, not Characters: a grapheme
        // cluster can carry hundreds of combining marks, so a Character-counted
        // prefix would admit megabytes for the per-`[` re-walk to copy.
        let window = String(String.UnicodeScalarView(text.unicodeScalars.prefix(snippetLinkScanChars)))
        let truncated = unwrapMarkdownLinks(window)
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
        // Non-empty text that leaves nothing previewable — image-only mail whose
        // links all have empty labels, or whitespace-only bodies — gets a visible
        // placeholder (owner 2026-09-09, #149 review). An EMPTY snippet is the
        // inbox loader's "not derived yet" sentinel and would re-fetch the body on
        // every reload; a derived-but-empty preview must never look like that.
        if result.isEmpty, !text.isEmpty { return noTextSnippet }
        return result
    }

    /// Snippet shown for a message whose text yields nothing previewable.
    /// Same bracketed style as `BodyFetchProcessor`'s `[attachment]` placeholder.
    static let noTextSnippet = "[no text]"

    /// Input Unicode scalars `snippetFromPlainText` reads (and `unwrapMarkdownLinks`
    /// may match within). Scalars, not Characters: a grapheme cluster can carry
    /// hundreds of combining marks. The window must hold an image-heavy newsletter's
    /// full run of empty-label tracking links (~180 scalars each; a 37-image mailer
    /// measured ~6,600) — a link cut at the window edge stops matching and leaks
    /// raw Markdown into the preview (#162). 32,000 holds ~180 such links, and
    /// `unwrapMarkdownLinks` is linear in the window, so the cost is a few ms.
    static let snippetLinkScanChars = 32_000

    /// Renders Markdown links as their bare label for SNIPPET display only (#148):
    /// `[label](destination)` → `label`, reversing the escapes `htmlToPlainText`'s
    /// `finishLink` adds (backslash-escaped punctuation, `&amp;`). The stored FTS
    /// text and the agent read path keep the full link; only the preview drops it.
    ///
    /// The grammar (unchanged since the regex it replaces, whose semantics this
    /// scanner reproduces exactly — fuzzed against it on 600,000 random strings):
    /// a link sits on one line; a label is a run of `\x` escape pairs (`x` not a
    /// line terminator — ICU's seven, VT and FF included) and characters other
    /// than `[`, `]`, `\` and those same terminators, closed by `]`; `(` follows
    /// immediately; a destination is a run
    /// of escape pairs and characters other than `)`, `\` and whitespace, closed
    /// by `)`. Scanning is leftmost, greedy without backtracking, and resumes
    /// after a link; anything else — a bare `[note]`, an unterminated `[label](…`,
    /// `[x] (…)`, a dangling `\` — is not a link and is copied through unchanged.
    ///
    /// LINEAR in the input by construction. Two right-to-left passes precompute,
    /// for every position, where a label scan or a destination scan starting there
    /// would close (or that it fails); the left-to-right pass then decides each `[`
    /// in O(1). A regex over the same grammar is quadratic on hostile bodies —
    /// every `[` in an unclosed run (`[](` × 10,000, or `\[` × 16,000) re-scans the
    /// same suffix to the window's end: measured 3.5–6.8 s at 32,000 scalars on a
    /// Mac, on the main actor (#162 review). This scanner: ~2 ms. Callers bound the
    /// INPUT (`snippetLinkScanChars` scalars).
    static func unwrapMarkdownLinks(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        let n = s.count
        let fail = -1
        // labelEnd[j]: index of the `]` a label scan starting at j stops on, or `fail`.
        // destEnd[j]: index of the `)` a destination scan starting at j stops on, or `fail`.
        var labelEnd = [Int](repeating: fail, count: n + 1)
        var destEnd = [Int](repeating: fail, count: n + 1)
        var j = n - 1
        while j >= 0 {
            let v = s[j].value
            if v == 0x5C { // `\`: an escape pair needs a following non-line-terminator; a dangling `\` fails both scans
                if j + 1 < n, !isVerticalWhitespaceScalar(s[j + 1].value) {
                    labelEnd[j] = labelEnd[j + 2]
                    destEnd[j] = destEnd[j + 2]
                }
            } else {
                labelEnd[j] = v == 0x5D ? j : (v == 0x5B || isVerticalWhitespaceScalar(v)) ? fail : labelEnd[j + 1]
                destEnd[j] = v == 0x29 ? j : s[j].properties.isWhitespace ? fail : destEnd[j + 1]
            }
            j -= 1
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(n)
        var c = 0
        while c < n {
            if s[c].value == 0x5B {
                let k = labelEnd[c + 1]
                if k != fail, k + 1 < n, s[k + 1].value == 0x28, destEnd[k + 2] != fail {
                    // A link: emit the label with its escapes reversed, skip the destination.
                    var label = String.UnicodeScalarView()
                    var i = c + 1
                    while i < k {
                        if s[i].value == 0x5C, i + 1 < k { i += 1 }
                        label.append(s[i])
                        i += 1
                    }
                    out.append(contentsOf: String(label).replacingOccurrences(of: "&amp;", with: "&").unicodeScalars)
                    c = destEnd[k + 2] + 1
                    continue
                }
            }
            out.append(s[c])
            c += 1
        }
        return String(out)
    }

    /// ICU's line terminators — what `.` refuses and what `\v` matches: LF, VT, FF,
    /// CR, NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR. One set serves both the
    /// "an escape never spans a line" rule and the "a label never spans a line" rule.
    private static func isVerticalWhitespaceScalar(_ v: UInt32) -> Bool {
        v == 0x0A || v == 0x0B || v == 0x0C || v == 0x0D || v == 0x85 || v == 0x2028 || v == 0x2029
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

    /// Strips HTML to plain text: FTS indexing, previews, quotes, the text/plain
    /// part of an HTML send, and a draft copy's editable text (#217). Visible links
    /// keep their destinations as Markdown links; see `HTMLText`.
    ///
    /// `keepingSpacing` (a draft's editable text, #217) keeps the spacing as the
    /// page shows it: every no-break space is a space, white space is kept where CSS
    /// keeps it (`<pre>`, `white-space`), a margin is a blank line, and an inline
    /// formatting tag (`<b>`, `<span>`, a link) adds no space. Every other caller
    /// keeps the collapsed form.
    static func htmlToPlainText(_ html: String, keepingSpacing: Bool = false) -> String {
        HTMLText.plainText(html, keepingSpacing: keepingSpacing)
    }

    /// Returns true if `v` is an invisible Unicode scalar value (zero-width spaces,
    /// soft hyphen, combining grapheme joiner, word joiner, BOM).
    private static func isInvisibleScalarValue(_ v: UInt32) -> Bool {
        switch v {
        case 0x00AD, 0x034F, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return true
        default: return false
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
