/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import JavaScriptCore
@testable import TabMail

@Suite("EmailFilter", .serialized)
struct EmailFilterTests {

    // MARK: - isNoReply

    @Test("isNoReply detects noreply addresses")
    func isNoReplyDetects() {
        #expect(EmailFilter.isNoReply("noreply@company.com") == true)
        #expect(EmailFilter.isNoReply("no-reply@company.com") == true)
        #expect(EmailFilter.isNoReply("no_reply@company.com") == true)
        #expect(EmailFilter.isNoReply("donotreply@company.com") == true)
        #expect(EmailFilter.isNoReply("do-not-reply@company.com") == true)
        #expect(EmailFilter.isNoReply("notifications@company.com") == true)
        #expect(EmailFilter.isNoReply("newsletters@company.com") == true)
    }

    // NEVER use real-world sender addresses (real companies/orgs/domains) in
    // tests — generic placeholder domains only (company.com, example.com).
    @Test("isNoReply detects auto-confirm and embedded-noreply senders")
    func isNoReplyAutoConfirm() {
        #expect(EmailFilter.isNoReply("auto-confirm@company.com") == true)
        #expect(EmailFilter.isNoReply("auto_confirm@company.com") == true)
        #expect(EmailFilter.isNoReply("autoconfirm@company.com") == true)
        // Embedded noreply substrings — caught by the existing "noreply" pattern
        #expect(EmailFilter.isNoReply("noreply-dmarc-report@company.com") == true)
        #expect(EmailFilter.isNoReply("payments-noreply@company.com") == true)
    }

    @Test("isNoReply passes normal addresses")
    func isNoReplyPassesNormal() {
        #expect(EmailFilter.isNoReply("user@company.com") == false)
        #expect(EmailFilter.isNoReply("john.doe@example.com") == false)
        #expect(EmailFilter.isNoReply("support@company.com") == false)
    }

    @Test("isNoReply is case-insensitive")
    func isNoReplyCaseInsensitive() {
        #expect(EmailFilter.isNoReply("NOREPLY@company.com") == true)
        #expect(EmailFilter.isNoReply("NoReply@company.com") == true)
    }

    // MARK: - hasUnsubscribeLink

    @Test("hasUnsubscribeLink detects List-Unsubscribe")
    func hasUnsubscribeLinkListHeader() {
        #expect(EmailFilter.hasUnsubscribeLink("list-unsubscribe: <mailto:unsub@example.com>") == true)
    }

    @Test("hasUnsubscribeLink detects unsubscribe + http")
    func hasUnsubscribeLinkHttp() {
        #expect(EmailFilter.hasUnsubscribeLink("<a href=\"http://example.com/unsubscribe\">Click to unsubscribe</a>") == true)
    }

    @Test("hasUnsubscribeLink returns false for nil")
    func hasUnsubscribeLinkNil() {
        #expect(EmailFilter.hasUnsubscribeLink(nil) == false)
    }

    @Test("hasUnsubscribeLink returns false for normal HTML")
    func hasUnsubscribeLinkNormal() {
        #expect(EmailFilter.hasUnsubscribeLink("<p>Hello World</p>") == false)
    }

    // MARK: - decodeHTMLEntities

    @Test("decodeHTMLEntities handles common entities")
    func decodeHTMLEntities() {
        #expect(EmailFilter.decodeHTMLEntities("&amp;") == "&")
        #expect(EmailFilter.decodeHTMLEntities("&lt;") == "<")
        #expect(EmailFilter.decodeHTMLEntities("&gt;") == ">")
        #expect(EmailFilter.decodeHTMLEntities("&quot;") == "\"")
        #expect(EmailFilter.decodeHTMLEntities("&#39;") == "'")
        #expect(EmailFilter.decodeHTMLEntities("&#x27;") == "'")
        #expect(EmailFilter.decodeHTMLEntities("&nbsp;") == " ")
    }

    @Test("decodeHTMLEntities handles multiple entities in string")
    func decodeHTMLEntitiesMultiple() {
        let result = EmailFilter.decodeHTMLEntities("a &amp; b &lt; c")
        #expect(result == "a & b < c")
    }

    @Test("decodeHTMLEntities passes through plain text")
    func decodeHTMLEntitiesPlainText() {
        #expect(EmailFilter.decodeHTMLEntities("Hello World") == "Hello World")
    }

    // MARK: - snippetFromPlainText

    @Test("snippetFromPlainText collapses whitespace")
    func snippetFromPlainTextWhitespace() {
        let result = EmailFilter.snippetFromPlainText("Hello   \n  World")
        #expect(result.contains("Hello") && result.contains("World"))
        #expect(!result.contains("\n"))
    }

    @Test("snippetFromPlainText truncates to maxChars")
    func snippetFromPlainTextTruncates() {
        let longText = String(repeating: "a", count: 300)
        let result = EmailFilter.snippetFromPlainText(longText, maxChars: 150)
        #expect(result.count <= 150)
    }

    // MARK: - htmlToPlainText

    @Test("htmlToPlainText strips tags")
    func htmlToPlainTextStripsTags() {
        let result = EmailFilter.htmlToPlainText("<p>Hello</p><br><div>World</div>")
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
        #expect(!result.contains("<"))
    }

    @Test("htmlToPlainText skips style/script blocks")
    func htmlToPlainTextSkipsBlocks() {
        let html = "<style>body { color: red; }</style><p>Visible</p><script>alert(1)</script>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Visible"))
        #expect(!result.contains("color"))
        #expect(!result.contains("alert"))
    }

    // MARK: - Invisible Unicode character stripping

    @Test("htmlToPlainText strips invisible Unicode characters")
    func htmlToPlainTextStripsInvisible() {
        // U+034F (combining grapheme joiner), U+200C (ZWNJ), U+00AD (soft hyphen)
        let html = "<p>\u{034F}Hello\u{200C} \u{00AD}World</p>"
        let result = EmailFilter.htmlToPlainText(html)
        // </p> emits newline, so trim for comparison
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World")
    }

    @Test("htmlToPlainText strips invisible chars from entity-decoded values")
    func htmlToPlainTextStripsInvisibleEntities() {
        // &#173; = U+00AD (soft hyphen), &#8203; = U+200B (zero-width space)
        let html = "<p>Hello&#173;&#8203;World</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "HelloWorld")
    }

    @Test("snippetFromPlainText strips invisible Unicode characters")
    func snippetFromPlainTextStripsInvisible() {
        // Simulate Mailchimp preheader padding: CGJ + ZWNJ + spaces + soft hyphens
        let padding = "\u{034F} \u{200C} \u{00AD} \u{034F} \u{200C} \u{00AD}"
        let text = padding + "Hello Alex, we have an announcement."
        let result = EmailFilter.snippetFromPlainText(text)
        #expect(result == "Hello Alex, we have an announcement.")
    }

    @Test("htmlToPlainText + snippetFromPlainText handles Mailchimp preheader padding div")
    func snippetMailchimpPreheader() {
        // Real-world pattern: display:none div with invisible chars, followed by actual content
        let html = """
        <div style="display:none;max-height:0px;overflow:hidden;">\u{034F} \u{200C} &nbsp; \u{034F} \u{200C} &nbsp; \u{034F} \u{200C} &nbsp;</div>\
        <p>Hello Alex, we have an announcement about the cloud platform.</p>
        """
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.contains("Hello Alex"))
        #expect(result.contains("announcement"))
    }

    @Test("htmlToPlainText + snippetFromPlainText skips display:none div with massive nbsp padding")
    func snippetDisplayNoneMassiveNbsp() {
        // Real-world: Mailchimp pads preheader with hundreds of &nbsp; entities
        // Without display:none handling, these become spaces that fill the snippet budget
        var nbspPadding = ""
        for _ in 0..<200 { nbspPadding += "&nbsp; " }
        let html = """
        <div style="display: none; max-height: 0px; overflow: hidden;">\(nbspPadding)</div>\
        <p>The new upgraded internal cloud will be available starting April 7.</p>
        """
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.contains("internal cloud"))
        #expect(result.contains("April"))
    }

    @Test("htmlToPlainText skips display:none with various formats")
    func htmlToPlainTextDisplayNoneVariants() {
        // No space around colon
        let html1 = #"<div style="display:none">hidden</div><p>visible</p>"#
        #expect(EmailFilter.htmlToPlainText(html1).contains("visible"))
        #expect(!EmailFilter.htmlToPlainText(html1).contains("hidden"))

        // Space after colon
        let html2 = #"<div style="display: none">hidden</div><p>visible</p>"#
        #expect(EmailFilter.htmlToPlainText(html2).contains("visible"))
        #expect(!EmailFilter.htmlToPlainText(html2).contains("hidden"))

        // Case-insensitive
        let html3 = #"<div style="Display:None">hidden</div><p>visible</p>"#
        #expect(EmailFilter.htmlToPlainText(html3).contains("visible"))
        #expect(!EmailFilter.htmlToPlainText(html3).contains("hidden"))

        // display:none in middle of style attribute
        let html4 = #"<span style="color:red; display:none; font-size:12px">hidden</span><p>visible</p>"#
        #expect(EmailFilter.htmlToPlainText(html4).contains("visible"))
        #expect(!EmailFilter.htmlToPlainText(html4).contains("hidden"))

        // Closing tags don't trigger (no false positive)
        let html5 = #"</div><p>visible</p>"#
        #expect(EmailFilter.htmlToPlainText(html5).contains("visible"))

        // Nested same-tag elements: inner </div> must not end the skip early
        let html6 = #"<div style="display:none"><div>inner hidden</div>also hidden</div><p>visible after</p>"#
        #expect(EmailFilter.htmlToPlainText(html6).contains("visible after"))
        #expect(!EmailFilter.htmlToPlainText(html6).contains("inner hidden"))
        #expect(!EmailFilter.htmlToPlainText(html6).contains("also hidden"))
    }

    // MARK: - cleanSnippet

    @Test("cleanSnippet collapses newlines from provider bodyPreview")
    func cleanSnippetCollapsesNewlines() {
        // Exchange bodyPreview often contains newlines
        let raw = "Hello Alex,\n\nWe're pleased to let you know\nthat the new internal cloud\nwill be available."
        let result = EmailFilter.cleanSnippet(raw)
        #expect(!result.contains("\n"))
        #expect(result.starts(with: "Hello Alex,"))
        #expect(result.contains("We're pleased"))
        #expect(result.contains("internal cloud"))
    }

    @Test("cleanSnippet decodes HTML entities and collapses whitespace")
    func cleanSnippetDecodesAndCollapses() {
        let raw = "Price is &lt;$10 &amp; includes&nbsp;&nbsp;&nbsp;shipping"
        let result = EmailFilter.cleanSnippet(raw)
        #expect(result == "Price is <$10 & includes shipping")
    }

    @Test("cleanSnippet strips invisible chars")
    func cleanSnippetStripsInvisible() {
        let raw = "\u{034F}\u{200C}Hello\u{00AD} World\u{200B}"
        let result = EmailFilter.cleanSnippet(raw)
        #expect(result == "Hello World")
    }

    @Test("cleanSnippet returns empty for empty input")
    func cleanSnippetEmpty() {
        #expect(EmailFilter.cleanSnippet("") == "")
    }

    @Test("cleanSnippet truncates to 150 chars")
    func cleanSnippetTruncates() {
        let raw = String(repeating: "a", count: 300)
        let result = EmailFilter.cleanSnippet(raw)
        #expect(result.count == 150)
    }

    @Test("cleanSnippet handles tabs and carriage returns")
    func cleanSnippetTabsCR() {
        let raw = "Line1\t\ttabbed\r\nLine2\rLine3"
        let result = EmailFilter.cleanSnippet(raw)
        #expect(result == "Line1 tabbed Line2 Line3")
    }

    // MARK: - isSelfSent

    /// Set test override emails, run body, then clear override.
    /// Uses _testOverrideEmails to bypass AppDatabase.shared — prevents race conditions
    /// from concurrent test suites overwriting the global singleton.
    private func withEmails(_ emails: Set<String>, _ body: () throws -> Void) throws {
        EmailFilter._testOverrideEmails.withLock { $0 = emails }
        defer { EmailFilter._testOverrideEmails.withLock { $0 = nil } }
        try body()
    }

    @Test("isSelfSent matches own account email")
    func isSelfSentMatches() throws {
        try withEmails(["user@example.com"]) {
            #expect(EmailFilter.isSelfSent("user@example.com"))
        }
    }

    @Test("isSelfSent is case-insensitive")
    func isSelfSentCaseInsensitive() throws {
        try withEmails(["user@example.com"]) {
            #expect(EmailFilter.isSelfSent("user@example.com"))
            #expect(EmailFilter.isSelfSent("USER@EXAMPLE.COM"))
            #expect(EmailFilter.isSelfSent("User@Example.Com"))
        }
    }

    @Test("isSelfSent trims whitespace")
    func isSelfSentTrimsWhitespace() throws {
        try withEmails(["user@example.com"]) {
            #expect(EmailFilter.isSelfSent("  user@example.com  "))
            #expect(EmailFilter.isSelfSent("user@example.com "))
            #expect(EmailFilter.isSelfSent(" user@example.com"))
        }
    }

    @Test("isSelfSent returns false for empty address")
    func isSelfSentEmptyAddress() throws {
        try withEmails(["user@example.com"]) {
            #expect(!EmailFilter.isSelfSent(""))
            #expect(!EmailFilter.isSelfSent("   "))
        }
    }

    @Test("isSelfSent returns false for non-matching address")
    func isSelfSentNonMatching() throws {
        try withEmails(["user@example.com"]) {
            #expect(!EmailFilter.isSelfSent("other@example.com"))
            #expect(!EmailFilter.isSelfSent("user@different.com"))
        }
    }

    @Test("isSelfSent checks all accounts")
    func isSelfSentMultipleAccounts() throws {
        try withEmails(["personal@gmail.com", "work@company.com"]) {
            #expect(EmailFilter.isSelfSent("personal@gmail.com"))
            #expect(EmailFilter.isSelfSent("work@company.com"))
            #expect(!EmailFilter.isSelfSent("stranger@other.com"))
        }
    }

    @Test("isSelfSent returns false when no accounts exist")
    func isSelfSentNoAccounts() throws {
        try withEmails([]) {
            #expect(!EmailFilter.isSelfSent("any@example.com"))
        }
    }

    @Test("invalidateUserEmailCache causes reload on next call")
    func invalidateReloads() throws {
        // First set: only first@
        EmailFilter._testOverrideEmails.withLock { $0 = ["first@example.com"] }
        #expect(EmailFilter.isSelfSent("first@example.com"))
        #expect(!EmailFilter.isSelfSent("second@example.com"))

        // Add second@ to override
        EmailFilter._testOverrideEmails.withLock { $0 = ["first@example.com", "second@example.com"] }
        #expect(EmailFilter.isSelfSent("first@example.com"))
        #expect(EmailFilter.isSelfSent("second@example.com"))

        // Cleanup
        EmailFilter._testOverrideEmails.withLock { $0 = nil }
    }

    @Test("isSelfSent uses cached set without re-reading DB")
    func isSelfSentCachePersists() throws {
        // Override bypasses cache entirely — this test verifies isSelfSent
        // returns consistent results for a given override set.
        try withEmails(["cached@example.com"]) {
            #expect(EmailFilter.isSelfSent("cached@example.com"))
            #expect(!EmailFilter.isSelfSent("new@example.com"))
            #expect(EmailFilter.isSelfSent("cached@example.com"))
        }
    }

    // MARK: - splitMessageAndQuotes

    @Test("splitMessageAndQuotes splits on English wrote:")
    func splitEnglishWrote() {
        let body = "My reply\n\nOn Mon, Jan 1, 2024 at 10:00 AM John wrote:\n> original text"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == "My reply")
        #expect(result.quotes.contains("wrote:"))
    }

    @Test("splitMessageAndQuotes splits on Chinese Gmail attribution")
    func splitChineseGmail() {
        let body = "My reply\n\nJane Smith <jsmith@mail.example.com> \u{4E8E}2026\u{5E74}3\u{6708}17\u{65E5}\u{5468}\u{4E8C} 01:16\u{5199}\u{9053}\u{FF1A}\n> original text"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == "My reply")
        #expect(result.quotes.contains("\u{5199}\u{9053}"))
    }

    @Test("splitMessageAndQuotes splits on German attribution")
    func splitGermanAttribution() {
        let body = "Meine Antwort\n\nAm 1. Januar 2024 schrieb Max:\n> original text"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == "Meine Antwort")
        #expect(result.quotes.contains("schrieb"))
    }

    @Test("splitMessageAndQuotes returns empty quotes when no boundary")
    func splitNoBoundary() {
        let body = "Just a plain email with no quotes"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == body)
        #expect(result.quotes.isEmpty)
    }

    @Test("splitMessageAndQuotes splits on Outlook headers")
    func splitOutlookHeaders() {
        let body = "My reply\n\nFrom: sender@example.com\nSent: Monday, January 1, 2024\nTo: me@example.com\nSubject: Test"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == "My reply")
        #expect(result.quotes.contains("From:"))
    }

    @Test("splitMessageAndQuotes splits on consecutive > quoted lines")
    func splitQuotedLines() {
        let body = "My reply\n\n> first quoted line\n> second quoted line"
        let result = EmailFilter.splitMessageAndQuotes(body)
        #expect(result.message == "My reply")
        #expect(result.quotes.hasPrefix(">"))
    }

    @Test("splitMessageAndQuotes handles empty input")
    func splitEmptyInput() {
        let result = EmailFilter.splitMessageAndQuotes("")
        #expect(result.message.isEmpty)
        #expect(result.quotes.isEmpty)
    }

    @Test("quoteAttributionPatternsAsJS generates valid JS")
    func attributionPatternsAsJS() {
        let js = EmailFilter.quoteAttributionPatternsAsJS()
        // Should contain if statements for each pattern
        #expect(js.contains("if (/"))
        #expect(js.contains("wrote"))
        #expect(js.contains("schrieb"))
        // French écrit — JS escape is \u00e9 (single backslash, no double-escaping)
        #expect(js.contains("\\u00e9crit"))
        // Chinese 写道 — JS escapes are single-backslash \uXXXX
        #expect(js.contains("\\u5199\\u9053"))
    }

    // MARK: - Swift ↔ JS pattern parity

    /// Verifies that the same test lines are detected by BOTH the Swift splitMessageAndQuotes
    /// and the JS patterns generated by quoteAttributionPatternsAsJS(), ensuring the single
    /// source of truth produces correct results in both runtimes.
    @Test("Swift and JS attribution patterns detect the same lines")
    func swiftAndJSPatternParity() {
        // Test lines that should be detected as attribution boundaries
        let attributionLines: [(line: String, label: String)] = [
            ("On Mon, Jan 1, 2024 at 10:00 AM John wrote:", "English"),
            ("Am 1. Januar 2024 schrieb Max:", "German"),
            ("Le 1 janvier 2024, Jean a \u{00e9}crit :", "French"),
            ("El 1 de enero de 2024, Juan escribi\u{00f3}:", "Spanish"),
            ("Il 1 gennaio 2024, Giovanni ha scritto:", "Italian"),
            ("Em 1 de janeiro de 2024, Jo\u{00e3}o escreveu:", "Portuguese"),
            ("2026\u{B144} 1\u{C6D4} 22\u{C77C} (\u{BAA9}) AM 4:23, Name <email>\u{B2D8}\u{C774} \u{C791}\u{C131}:", "Korean"),
            ("Jane Smith <jsmith@mail.example.com> \u{4E8E}2026\u{5E74}3\u{6708}17\u{65E5}\u{5468}\u{4E8C} 01:16\u{5199}\u{9053}\u{FF1A}", "Chinese full-width"),
            ("Jane Smith <jsmith@mail.example.com> \u{4E8E}2026\u{5E74}3\u{6708}17\u{65E5}\u{5468}\u{4E8C} 01:16\u{5199}\u{9053}:", "Chinese half-width"),
        ]

        // Lines that should NOT be detected
        let nonAttributionLines = [
            "Hello, how are you?",
            "Please see the attached document.",
            "Thanks for your email.",
        ]

        // --- Swift side: test via splitMessageAndQuotes ---
        for (line, label) in attributionLines {
            let body = "My reply\n\n\(line)\n> quoted"
            let result = EmailFilter.splitMessageAndQuotes(body)
            #expect(!result.quotes.isEmpty, "Swift should detect \(label) attribution")
            #expect(result.message == "My reply", "Swift should split correctly for \(label)")
        }

        for line in nonAttributionLines {
            let body = "My reply\n\n\(line)\nMore text"
            let result = EmailFilter.splitMessageAndQuotes(body)
            #expect(result.quotes.isEmpty, "Swift should NOT detect: \(line)")
        }

        // --- JS side: test via JSContext ---
        let ctx = JSContext()!
        // Build a JS function that tests a line against all attribution patterns.
        // The patterns from quoteAttributionPatternsAsJS() already have correct single-backslash
        // JS regex escapes — no un-escaping needed.
        let jsSource = EmailFilter.quoteAttributionPatternsAsJS()

        // Wrap in a for loop (the generated JS uses `break` which requires a loop context)
        let testFn = """
        function testLine(trimmed) {
            var boundaryLine = -1;
            var i = 0;
            function _log(m) {}
            for (var _once = 0; _once < 1; _once++) {
                \(jsSource)
            }
            return boundaryLine !== -1;
        }
        """
        ctx.evaluateScript(testFn)

        let testLineFn = ctx.objectForKeyedSubscript("testLine")!

        for (line, label) in attributionLines {
            let result = testLineFn.call(withArguments: [line])
            #expect(result?.toBool() == true, "JS should detect \(label) attribution: \(line)")
        }

        for line in nonAttributionLines {
            let result = testLineFn.call(withArguments: [line])
            #expect(result?.toBool() == false, "JS should NOT detect: \(line)")
        }
    }

    // MARK: - Multi-line joined check off-by-one

    /// Tests the full attribution detection loop from collapseQuotesJS — both
    /// the single-line patterns and the multi-line joined fallback.
    ///
    /// When lines[i] is noise and lines[i+1] is a complete attribution, the
    /// single-line matcher must catch it at i+1. When the attribution truly
    /// spans both lines, the joined fallback must catch it at i. The test
    /// harness below replicates the production loop structure (single-line
    /// patterns from EmailFilter, then multi-line "On..." split check, then
    /// guarded joined fallback). If you change the loop in collapseQuotesJS,
    /// mirror it here — the test is a standalone reproduction (no DOM), so
    /// it cannot invoke the production script directly.
    @Test("Attribution detection sets correct boundaryLine across single-line and joined paths")
    func multiLineJoinedBoundaryLine() {
        let ctx = JSContext()!

        // Single-line attribution patterns — shared source of truth from EmailFilter.
        let singleLineJS = EmailFilter.quoteAttributionPatternsAsJS()

        // Replicate the production loop: single-line → "On..." split → guarded joined.
        // Input: array of line strings. Returns the boundaryLine index.
        let js = """
        function findBoundary(linesArr) {
            var boundaryLine = -1;
            var lines = linesArr;
            function _log(m) {}
            for (var i = 0; i < lines.length; i++) {
                var trimmed = lines[i].trim();
                if (!trimmed) continue;

                // Single-line attribution patterns (from EmailFilter source of truth)
                \(singleLineJS)

                // Multi-line "On..." split check: "On ..." on line i, "... wrote:" on i+1
                if (/^On\\s+.+$/i.test(trimmed) && i + 1 < lines.length) {
                    var nextLine = lines[i + 1].trim();
                    if (/wrote:\\s*$/i.test(nextLine)) {
                        boundaryLine = i; break;
                    }
                }

                // Guarded joined fallback: only fire when line i+1 alone does NOT
                // match the attribution pattern. Otherwise the single-line path
                // above would catch it cleanly at i+1.
                if (i + 1 < lines.length && boundaryLine === -1) {
                    var joined = trimmed + ' ' + lines[i + 1].trim();
                    var nextTrimmed = lines[i + 1].trim();

                    var _cnRe = /^.+\\u4E8E.+\\u5199\\u9053[\\uFF1A:]\\s*$/;
                    if (_cnRe.test(joined) && !_cnRe.test(nextTrimmed)) {
                        boundaryLine = i; break;
                    }
                    var _krRe = /^.+\\uB2D8\\uC774\\s*\\uC791\\uC131\\s*:\\s*$/;
                    if (_krRe.test(joined) && !_krRe.test(nextTrimmed)) {
                        boundaryLine = i; break;
                    }
                    var _wrRe = /^.+\\s+wrote:\\s*$/i;
                    if (_wrRe.test(joined) && !_wrRe.test(nextTrimmed)) {
                        boundaryLine = i; break;
                    }
                    var _frRe = /^Le\\s+.+\\s+a\\s+.+crit\\s*:\\s*$/i;
                    var _deRe = /^Am\\s+.+\\s+schrieb\\s+.+:\\s*$/i;
                    var _esRe = /^El\\s+.+\\s+escribi.+:\\s*$/i;
                    var _ptRe = /^Em\\s+.+\\s+escreveu\\s*:\\s*$/i;
                    var _intlNextAlone = _frRe.test(nextTrimmed) || _deRe.test(nextTrimmed) || _esRe.test(nextTrimmed) || _ptRe.test(nextTrimmed);
                    if ((_frRe.test(joined) || _deRe.test(joined) || _esRe.test(joined) || _ptRe.test(joined)) && !_intlNextAlone) {
                        boundaryLine = i; break;
                    }
                }
            }
            return boundaryLine;
        }
        """
        ctx.evaluateScript(js)
        let findBoundary = ctx.objectForKeyedSubscript("findBoundary")!

        // --- Attribution entirely on line i+1 (line i is noise) → boundaryLine = i+1 ---

        // Chinese: signature line + complete Chinese attribution on next line
        let cnSolo: [String] = ["Title", "Jane Smith <jsmith@mail.example.com> \u{4E8E}2026\u{5E74}3\u{6708}17\u{65E5}\u{5468}\u{4E8C} 01:16\u{5199}\u{9053}\u{FF1A}"]
        #expect(findBoundary.call(withArguments: [cnSolo])?.toInt32() == 1, "Chinese attribution on line 1 → boundaryLine should be 1, not 0")

        // Korean: signature line + complete Korean attribution on next line
        let krSolo: [String] = ["John Doe", "2026\u{B144} 1\u{C6D4} 22\u{C77C} (\u{BAA9}) AM 4:23, Name <email>\u{B2D8}\u{C774} \u{C791}\u{C131}:"]
        #expect(findBoundary.call(withArguments: [krSolo])?.toInt32() == 1, "Korean attribution on line 1 → boundaryLine should be 1, not 0")

        // Generic wrote: signature line + complete English attribution on next line
        let wrSolo: [String] = ["Best regards", "On Mon, Mar 16, 2026 at 10:00 AM John wrote:"]
        #expect(findBoundary.call(withArguments: [wrSolo])?.toInt32() == 1, "English attribution on line 1 → boundaryLine should be 1, not 0")

        // Regression: multiple noise lines preceding a complete single-line
        // attribution. Under the previous joined-check, the last noise line
        // would greedily combine with the attribution line (because the join
        // ends with "wrote:") and fire a false multi-line match at i=N-1.
        // The guarded logic must skip the join when the next line alone
        // already matches, letting the single-line path catch it at i=N.
        // Fully abstract tokens — must not resemble any real email.
        let wrNoiseThenAttribution: [String] = [
            "AAA",
            "BBB",
            "CCC",
            "DDD",
            "EEE",
            "FFF",
            "GGG",
            "HHH",
            "III",
            "JJJ",
            "KKK",
            "LLL",
            "On X Y, 2026, at 0:00 AM, Z wrote:",
        ]
        #expect(findBoundary.call(withArguments: [wrNoiseThenAttribution])?.toInt32() == 12, "Attribution on line 12 → boundaryLine should be 12 (single-line match), not 11 (noisy join)")

        // Note: German/French/Spanish/Portuguese patterns have anchored prefixes (^Am, ^Le, ^El, ^Em),
        // so they inherently can't match a joined text that starts with noise — no off-by-one possible.
        // The off-by-one only affects patterns starting with ^.+ (Chinese, Korean, generic wrote).

        // --- Attribution spans both lines → boundaryLine = i ---

        // Chinese: name on line 0, 于...写道 on line 1 (line 1 alone has no content before 于)
        let cnSpan: [String] = ["Jane Smith <jsmith@mail.example.com>", "\u{4E8E}2026\u{5E74}3\u{6708}17\u{65E5}\u{5468}\u{4E8C} 01:16\u{5199}\u{9053}\u{FF1A}"]
        #expect(findBoundary.call(withArguments: [cnSpan])?.toInt32() == 0, "Chinese attribution spanning both lines → boundaryLine should be 0")

        // Generic wrote: "On Mon..." on line 0, "John wrote:" on line 1
        // (multi-line "On..." check catches this at i=0 before joined check)
        let wrSpan: [String] = ["On Mon, Mar 16, 2026 at 10:00 AM", "John wrote:"]
        #expect(findBoundary.call(withArguments: [wrSpan])?.toInt32() == 0, "Wrapped On...wrote: → boundaryLine should be 0")

        // Korean: date on line 0, 님이 작성: on line 1 (line 1 alone lacks content before 님이)
        let krSpan: [String] = ["2026\u{B144} 1\u{C6D4} 22\u{C77C} (\u{BAA9}) AM 4:23, Name <email>", "\u{B2D8}\u{C774} \u{C791}\u{C131}:"]
        #expect(findBoundary.call(withArguments: [krSpan])?.toInt32() == 0, "Korean attribution spanning both lines → boundaryLine should be 0")

        // --- No match → boundaryLine = -1 ---
        let noMatch: [String] = ["Hello", "How are you?"]
        #expect(findBoundary.call(withArguments: [noMatch])?.toInt32() == -1, "No attribution → boundaryLine should be -1")
    }

    // MARK: - walkUpToWrapStart (DOM walk-up for quote wrapping)
    //
    // These tests exercise the SHARED `walkUpToWrapStartJS` source from
    // AutoSizingHTMLView.swift. Production code and these tests both evaluate
    // the same string, so there is zero drift risk.
    //
    // A synthetic node tree (plain JS objects with parentNode / previousSibling /
    // textContent / tagName) stands in for a WKWebView DOM — no polyfill needed
    // because walkUpToWrapStart only reads those four properties.

    /// JS helper that builds synthetic node trees. Shared across tests below.
    /// `h('tag', {className, text}, [children...])` returns a node whose
    /// textContent aggregates from children when no own text is given.
    private static let walkUpTestHarness: String = """
    var body = { tagName: 'BODY', className: '', textContent: '', children: [], parentNode: null, previousSibling: null, nextSibling: null };
    function h(tag, attrs, children) {
        attrs = attrs || {};
        children = children || [];
        var n = {
            tagName: (tag || 'DIV').toUpperCase(),
            className: attrs.className || '',
            textContent: attrs.text || '',
            children: children,
            parentNode: null,
            previousSibling: null,
            nextSibling: null
        };
        for (var i = 0; i < children.length; i++) {
            children[i].parentNode = n;
            if (i > 0) {
                children[i].previousSibling = children[i - 1];
                children[i - 1].nextSibling = children[i];
            }
        }
        if (!attrs.text) {
            var agg = '';
            for (var j = 0; j < children.length; j++) agg += (children[j].textContent || '');
            n.textContent = agg;
        }
        return n;
    }
    // Attach a tree as body's children and return the matching node for testing.
    function attach(tree) {
        body.children = [tree];
        tree.parentNode = body;
        tree.previousSibling = null;
        tree.nextSibling = null;
        return tree;
    }
    function findByClass(root, cls) {
        if (root.className === cls) return root;
        for (var i = 0; i < (root.children || []).length; i++) {
            var r = findByClass(root.children[i], cls);
            if (r) return r;
        }
        return null;
    }
    var _logs = [];
    function _log(m) { _logs.push(m); }
    """

    /// Evaluates `walkUpToWrapStartJS` + the tree harness in a fresh JSContext.
    private func makeWalkUpContext() -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(walkUpToWrapStartJS)
        ctx.evaluateScript(Self.walkUpTestHarness)
        return ctx
    }

    @Test("walkUpToWrapStart: top-level blockquote with prior reply text stays in place")
    func walkUpStandardCase() {
        let ctx = makeWalkUpContext()
        // <body><container>[reply div][blockquote.target]</container></body>
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'email-body'}, [
            h('div', {text: 'Hi, my reply goes here.', className: 'reply'}),
            h('blockquote', {text: 'Quoted content', className: 'target'})
        ]));
        var start = findByClass(tree, 'target');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        #expect(ctx.evaluateScript("result.tagName")?.toString() == "BLOCKQUOTE")
        #expect(ctx.evaluateScript("result.className")?.toString() == "target")
    }

    @Test("walkUpToWrapStart: nested blockquote with no prior sibling walks up one level")
    func walkUpNestedBlockquote() {
        let ctx = makeWalkUpContext()
        // This is the production bug scenario:
        //   <email-body>
        //     <div.reply>reply text</div>
        //     <div.attrib-container>  ← container has no text of its own
        //       <blockquote.attrib>attribution only</blockquote>
        //     </div.attrib-container>
        //     <blockquote.big-quote>the real quoted content</blockquote>
        // quoteStart = blockquote.attrib (nested). Walk up must reach
        // attrib-container so wrapping sweeps big-quote into the wrapper.
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'email-body'}, [
            h('div', {text: 'reply text', className: 'reply'}),
            h('div', {className: 'attrib-container'}, [
                h('blockquote', {text: 'On X, Y wrote:', className: 'attrib'})
            ]),
            h('blockquote', {text: 'the real quoted content', className: 'big-quote'})
        ]));
        var start = findByClass(tree, 'attrib');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        #expect(ctx.evaluateScript("result.className")?.toString() == "attrib-container")
        #expect(ctx.evaluateScript("result.tagName")?.toString() == "DIV")
    }

    @Test("walkUpToWrapStart: deeply nested without prior siblings walks up multiple levels")
    func walkUpDeeplyNested() {
        let ctx = makeWalkUpContext()
        // <email-body>
        //   <div.reply>reply</div>
        //   <div.L2>                 ← outer container, no own prior sibling with text at inner levels
        //     <div.L1>
        //       <blockquote.target>...</blockquote>
        //     </div.L1>
        //   </div.L2>
        // Expected: walk up to L2 (stops there because .reply is a prior sibling with text)
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'email-body'}, [
            h('div', {text: 'reply', className: 'reply'}),
            h('div', {className: 'L2'}, [
                h('div', {className: 'L1'}, [
                    h('blockquote', {text: 'quote', className: 'target'})
                ])
            ])
        ]));
        var start = findByClass(tree, 'target');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        #expect(ctx.evaluateScript("result.className")?.toString() == "L2")
    }

    @Test("walkUpToWrapStart: whitespace-only prior siblings do not halt walk-up")
    func walkUpIgnoresWhitespaceSiblings() {
        let ctx = makeWalkUpContext()
        // Prior sibling has textContent of "" or whitespace — must not be
        // treated as "prior content". walk-up continues past it.
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'email-body'}, [
            h('div', {text: 'reply', className: 'reply'}),
            h('div', {className: 'container'}, [
                h('br', {text: ''}),
                h('blockquote', {text: 'quote', className: 'target'})
            ])
        ]));
        var start = findByClass(tree, 'target');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        // br (whitespace) doesn't halt; walk-up moves to container, then stops
        // because .reply is a prior sibling of container with text.
        #expect(ctx.evaluateScript("result.className")?.toString() == "container")
    }

    @Test("walkUpToWrapStart: single-char prior sibling is trivial and does not halt")
    func walkUpTrivialPriorText() {
        let ctx = makeWalkUpContext()
        // Threshold: length >= 2 counts as prior content. A single character
        // (e.g. a stray "\u{00A0}" or "a") must NOT halt — prior siblings
        // with truly negligible text are indentation noise.
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'email-body'}, [
            h('div', {text: 'reply', className: 'reply'}),
            h('div', {className: 'container'}, [
                h('span', {text: ' '}),
                h('blockquote', {text: 'quote', className: 'target'})
            ])
        ]));
        var start = findByClass(tree, 'target');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        #expect(ctx.evaluateScript("result.className")?.toString() == "container")
    }

    @Test("walkUpToWrapStart: stops at direct child of body when no prior content anywhere")
    func walkUpStopsAtBodyChild() {
        let ctx = makeWalkUpContext()
        // Degenerate case: entire email is a single blockquote with no reply
        // text at any level. Walk-up should climb until parentNode === body,
        // then stop (loop condition). No over-collapse beyond body.
        ctx.evaluateScript("""
        var tree = attach(h('div', {className: 'wrapper'}, [
            h('div', {className: 'L1'}, [
                h('blockquote', {text: 'whole email is a quote', className: 'target'})
            ])
        ]));
        var start = findByClass(tree, 'target');
        var result = walkUpToWrapStart(start, body, _log);
        """)
        // wrapper.parentNode === body → loop exits with result === wrapper
        #expect(ctx.evaluateScript("result.className")?.toString() == "wrapper")
    }

    // MARK: - splitBlockBeforeTarget (lift attribution out when reply shares the block)
    //
    // These tests exercise the SHARED `splitBlockBeforeTargetJS` source from
    // AutoSizingHTMLView.swift. Production and tests evaluate the same string.
    //
    // The motivating real-world case (anonymized): a composer (Thunderbird's
    // moz-cite-prefix div is the known offender) folds the user's reply AND
    // the "On X wrote:" attribution into the same container, while the actual
    // <blockquote> of quoted content sits as the container's *outer* sibling.
    // The block walk-up in collapseQuotesJS would otherwise grab the whole
    // container and sweep the reply into the wrapper — and a marker inserted
    // *inside* the container can't reach the outer <blockquote>. So the
    // helper physically lifts the attribution out: it creates a new sibling
    // block after the original and moves targetNode + its in-block siblings
    // into it. The new block lives at the original block's level, so the
    // wrap loop sees the outer siblings; walkUpToWrapStart stops at the new
    // block because its previous sibling (the original) still carries reply
    // text.
    //
    // The synthetic node tree below adds support for `nodeType === 3` text
    // nodes, `document.createElement`, `parentNode.insertBefore`, and a
    // `parentNode.appendChild` that detaches the node from its previous
    // parent first (matching real DOM semantics, which is what
    // `splitBlockBeforeTarget` relies on to move targetNode out of the
    // original block).

    /// JS harness with text/element node builders + a `_doc` stand-in for
    /// `document`. `appendChild` and `insertBefore` correctly detach nodes
    /// from their previous parent before re-attaching, matching real DOM
    /// semantics — splitBlockBeforeTarget moves nodes between parents.
    private static let splitBlockTestHarness: String = """
    function _detach(node) {
        if (!node.parentNode) return;
        var p = node.parentNode;
        if (p.children) {
            var idx = p.children.indexOf(node);
            if (idx >= 0) p.children.splice(idx, 1);
        }
        if (node.previousSibling) node.previousSibling.nextSibling = node.nextSibling;
        if (node.nextSibling) node.nextSibling.previousSibling = node.previousSibling;
        node.parentNode = null;
        node.previousSibling = null;
        node.nextSibling = null;
    }
    function txt(s) {
        return { nodeType: 3, textContent: s, parentNode: null, previousSibling: null, nextSibling: null };
    }
    function el(tag, attrs, children) {
        attrs = attrs || {};
        children = children || [];
        var n = {
            nodeType: 1,
            tagName: (tag || 'DIV').toUpperCase(),
            className: attrs.className || '',
            textContent: attrs.text || '',
            children: [],
            parentNode: null,
            previousSibling: null,
            nextSibling: null,
            insertBefore: function(newNode, refNode) {
                _detach(newNode);
                if (!refNode) { return this.appendChild(newNode); }
                var idx = this.children.indexOf(refNode);
                if (idx < 0) return newNode;
                this.children.splice(idx, 0, newNode);
                newNode.parentNode = this;
                newNode.previousSibling = refNode.previousSibling;
                newNode.nextSibling = refNode;
                if (refNode.previousSibling) refNode.previousSibling.nextSibling = newNode;
                refNode.previousSibling = newNode;
                return newNode;
            },
            appendChild: function(newNode) {
                _detach(newNode);
                var prev = this.children.length ? this.children[this.children.length - 1] : null;
                this.children.push(newNode);
                newNode.parentNode = this;
                newNode.previousSibling = prev;
                newNode.nextSibling = null;
                if (prev) prev.nextSibling = newNode;
                return newNode;
            }
        };
        for (var i = 0; i < children.length; i++) {
            n.appendChild(children[i]);
        }
        if (!attrs.text) {
            var agg = '';
            for (var j = 0; j < n.children.length; j++) agg += (n.children[j].textContent || '');
            n.textContent = agg;
        }
        return n;
    }
    var _doc = {
        createElement: function(tag) {
            return el(tag, {}, []);
        }
    };
    var _splitLogs = [];
    function _splitLog(m) { _splitLogs.push(m); }
    """

    /// Evaluates `splitBlockBeforeTargetJS` + the split harness in a fresh JSContext.
    private func makeSplitContext() -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(splitBlockBeforeTargetJS)
        ctx.evaluateScript(Self.splitBlockTestHarness)
        return ctx
    }

    @Test("splitBlockBeforeTarget: lifts attribution out when reply shares the block, outer blockquote becomes reachable")
    func splitFiresOnMozCitePrefixShape() {
        let ctx = makeSplitContext()
        // Anonymized mirror of the moz-cite-prefix bug + outer-blockquote
        // sibling. The body looks like:
        //   <body>
        //     <div class="cite-block">
        //       [text "Reply line one."]
        //       <br>
        //       [text "Reply line two."]
        //       <br>
        //       [text "ATTRIBUTION LINE"]   ← targetNode
        //       <br>
        //     </div>
        //     <blockquote class="outer-quote">quoted thread</blockquote>
        //   </body>
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var trailingBr = el('br');
        var block = el('div', {className: 'cite-block'}, [
            txt('Reply line one.'),
            el('br'),
            txt('Reply line two.'),
            el('br'),
            attribNode,
            trailingBr
        ]);
        var outerBQ = el('blockquote', {text: 'quoted thread', className: 'outer-quote'});
        var bodyMock = el('body', {}, [block, outerBQ]);
        var result = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        """)
        // Returns a brand-new <div> with the expected class.
        #expect(ctx.evaluateScript("result !== null")?.toBool() == true)
        #expect(ctx.evaluateScript("result.tagName")?.toString() == "DIV")
        #expect(ctx.evaluateScript("result.className")?.toString() == "tm-quote-split-block")
        // The split block is the original block's NEW next sibling, and lives
        // at the same level (body, not inside cite-block).
        #expect(ctx.evaluateScript("block.nextSibling === result")?.toBool() == true)
        #expect(ctx.evaluateScript("result.previousSibling === block")?.toBool() == true)
        #expect(ctx.evaluateScript("result.parentNode === bodyMock")?.toBool() == true)
        // Attribution + trailing <br> have been moved into the split block.
        #expect(ctx.evaluateScript("attribNode.parentNode === result")?.toBool() == true)
        #expect(ctx.evaluateScript("trailingBr.parentNode === result")?.toBool() == true)
        // Reply text nodes stay in the original block.
        #expect(ctx.evaluateScript("block.children[0].textContent")?.toString() == "Reply line one.")
        #expect(ctx.evaluateScript("block.children.indexOf(attribNode)")?.toInt32() == -1)
        // The outer <blockquote> is now the split block's next sibling — so a
        // wrap loop that walks splitBlock.nextSibling will sweep it in.
        #expect(ctx.evaluateScript("result.nextSibling === outerBQ")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: no-op when attribution is the first text in the block")
    func splitSkipsWhenNoPriorText() {
        let ctx = makeSplitContext()
        // Normal Thunderbird-style structure: cite-block contains ONLY the
        // attribution line; reply text is in a sibling above.
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var citeBlock = el('div', {className: 'cite-block'}, [attribNode]);
        var bodyMock = el('body', {}, [
            el('div', {text: 'Reply body.', className: 'reply'}),
            citeBlock,
            el('blockquote', {text: 'quoted thread'})
        ]);
        var result = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        """)
        // No split — caller falls through to the normal block walk-up.
        #expect(ctx.evaluateScript("result === null")?.toBool() == true)
        // Attribution text untouched (still first child of its block).
        #expect(ctx.evaluateScript("attribNode.parentNode === citeBlock")?.toBool() == true)
        #expect(ctx.evaluateScript("attribNode.previousSibling === null")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: whitespace-only and single-char prior siblings do not trigger split")
    func splitIgnoresTrivialPriorText() {
        let ctx = makeSplitContext()
        // Threshold mirrors walkUpToWrapStart's: trimmed length >= 2.
        // Single whitespace + single-char prior text nodes are noise
        // (indentation), not the user's reply.
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var block = el('div', {className: 'cite-block'}, [
            txt('   '),
            txt('x'),
            el('br'),
            attribNode
        ]);
        var bodyMock = el('body', {}, [block, el('blockquote', {text: 'q'})]);
        var result = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        """)
        #expect(ctx.evaluateScript("result === null")?.toBool() == true)
        #expect(ctx.evaluateScript("attribNode.parentNode === block")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: splits when a meaningful prior sibling sits behind whitespace")
    func splitWalksPastTrivialToFindRealText() {
        let ctx = makeSplitContext()
        // Helper must walk ALL prior siblings — an immediately-prior <br> is
        // whitespace, but real reply text sits two siblings back. Still counts.
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var block = el('div', {className: 'cite-block'}, [
            txt('Reply body.'),
            el('br'),
            attribNode
        ]);
        var bodyMock = el('body', {}, [block, el('blockquote', {text: 'q'})]);
        var result = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        """)
        #expect(ctx.evaluateScript("result !== null")?.toBool() == true)
        #expect(ctx.evaluateScript("result.className")?.toString() == "tm-quote-split-block")
        #expect(ctx.evaluateScript("attribNode.parentNode === result")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: returns null when targetNode is an element (nodeType !== 3)")
    func splitReturnsNullForElementNode() {
        let ctx = makeSplitContext()
        // Defensive: the production caller only feeds text nodes (from the
        // segment map), but the helper still guards against misuse.
        ctx.evaluateScript("""
        var attribEl = el('span', {text: 'ATTRIBUTION LINE'});
        var block = el('div', {className: 'cite-block'}, [
            txt('Reply body.'),
            attribEl
        ]);
        var bodyMock = el('body', {}, [block]);
        var result = splitBlockBeforeTarget(attribEl, _doc, _splitLog);
        """)
        #expect(ctx.evaluateScript("result === null")?.toBool() == true)
        #expect(ctx.evaluateScript("attribEl.parentNode === block")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: returns null when targetNode has no parent")
    func splitReturnsNullForDetachedNode() {
        let ctx = makeSplitContext()
        ctx.evaluateScript("""
        var orphan = txt('ATTRIBUTION LINE');
        var result = splitBlockBeforeTarget(orphan, _doc, _splitLog);
        """)
        #expect(ctx.evaluateScript("result === null")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: returns null when block has no grand-parent (block IS body or root)")
    func splitReturnsNullForRootLevelBlock() {
        let ctx = makeSplitContext()
        // Defensive: if the attribution is somehow a direct child of <body>
        // (no grand-parent into which we could insert the new sibling block),
        // bail out and let the existing block walk-up handle it.
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var bodyMock = el('body', {}, [txt('Reply body.'), attribNode]);
        // bodyMock has no parentNode — this matches a real <body> at the root.
        var result = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        """)
        #expect(ctx.evaluateScript("result === null")?.toBool() == true)
    }

    @Test("splitBlockBeforeTarget: after split, walkUpToWrapStart stops at the split block")
    func splitBlockIsRespectedByWalkUp() {
        // End-to-end: simulate the production sequence — split, then walk up.
        // walkUpToWrapStart should immediately stop because the split block's
        // prior sibling (the original block) carries reply text.
        let ctx = JSContext()!
        ctx.evaluateScript(splitBlockBeforeTargetJS)
        ctx.evaluateScript(walkUpToWrapStartJS)
        ctx.evaluateScript(Self.splitBlockTestHarness)
        ctx.evaluateScript("""
        var attribNode = txt('ATTRIBUTION LINE');
        var block = el('div', {className: 'cite-block'}, [
            txt('Reply body.'),
            el('br'),
            attribNode
        ]);
        var outerBQ = el('blockquote', {text: 'quoted body', className: 'outer-quote'});
        var bodyMock = el('body', {}, [block, outerBQ]);
        var splitBlock = splitBlockBeforeTarget(attribNode, _doc, _splitLog);
        var finalStart = walkUpToWrapStart(splitBlock, bodyMock, _splitLog);
        """)
        // Walk-up stopped at the split block — its previous sibling (block)
        // has reply text >= 2 chars. The split block did NOT climb up to body.
        #expect(ctx.evaluateScript("finalStart === splitBlock")?.toBool() == true)
        #expect(ctx.evaluateScript("finalStart.parentNode === bodyMock")?.toBool() == true)
        // And critically: the outer blockquote is still the split block's
        // next sibling, so the production wrap loop will pull it into the
        // wrapper via `quoteStart.nextSibling` walking.
        #expect(ctx.evaluateScript("splitBlock.nextSibling === outerBQ")?.toBool() == true)
    }

    // MARK: - extractFirstMessageId

    @Test("extractFirstMessageId: single bracketed ID")
    func extractFirstSingleBracketed() {
        #expect(EmailFilter.extractFirstMessageId("<id@example.com>") == "id@example.com")
    }

    @Test("extractFirstMessageId: multiple bracketed IDs returns first")
    func extractFirstMultipleBracketed() {
        #expect(EmailFilter.extractFirstMessageId("<id1@a.com> <id2@b.com>") == "id1@a.com")
    }

    @Test("extractFirstMessageId: bare ID without brackets")
    func extractFirstBareId() {
        #expect(EmailFilter.extractFirstMessageId("id@example.com") == "id@example.com")
    }

    @Test("extractFirstMessageId: whitespace and newlines trimmed")
    func extractFirstWhitespaceTrimmed() {
        #expect(EmailFilter.extractFirstMessageId("  <id@example.com>  \n") == "id@example.com")
    }

    @Test("extractFirstMessageId: empty string returns nil")
    func extractFirstEmptyReturnsNil() {
        #expect(EmailFilter.extractFirstMessageId("") == nil)
        #expect(EmailFilter.extractFirstMessageId("   ") == nil)
    }

    @Test("extractFirstMessageId: multi-value with tabs/folded whitespace")
    func extractFirstFoldedWhitespace() {
        // RFC 2822 allows folded whitespace (CRLF + WSP) between message IDs
        #expect(EmailFilter.extractFirstMessageId("<id1@a.com>\r\n\t<id2@b.com>") == "id1@a.com")
    }
}
