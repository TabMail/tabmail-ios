/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit tests for the provider-agnostic `EmlMarker` builder. IMAP, Gmail, and
/// Exchange all feed this helper — tests here guard the HTML shape that
/// `EmlAttachmentPreview` and `EmailFilter.parseEmlSectionMetadata` consume.
///
/// All content is synthetic.
@Suite("EmlMarker.build — unified marker emission")
struct EmlMarkerBuildTests {

    private func makeEnvelope(
        subject: String? = "Synthetic Subject",
        from: String? = "sender@example.com",
        date: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        to: [String] = ["recipient@example.com"],
        cc: [String] = []
    ) -> EmlMarker.Envelope {
        EmlMarker.Envelope(subject: subject, from: from, date: date, to: to, cc: cc)
    }

    @Test("Marker contains class and filename/partSection attrs")
    func basicMarker() {
        let html = EmlMarker.build(
            filename: "sample.eml",
            partSection: "2",
            envelope: makeEnvelope(),
            bodyHtml: "<p>Body</p>"
        )
        #expect(html.contains("class=\"tm-eml-section\""))
        #expect(html.contains("data-filename=\"sample.eml\""))
        #expect(html.contains("data-part-section=\"2\""))
    }

    @Test("Envelope fields become data-* attributes")
    func envelopeAttributes() {
        let html = EmlMarker.build(
            filename: "x.eml",
            partSection: "abc",
            envelope: makeEnvelope(
                subject: "Hi there",
                from: "a@b.c",
                to: ["to1@example.com", "to2@example.com"],
                cc: ["cc@example.com"]
            ),
            bodyHtml: "<p>x</p>"
        )
        #expect(html.contains("data-subject=\"Hi there\""))
        #expect(html.contains("data-from=\"a@b.c\""))
        #expect(html.contains("data-to=\"to1@example.com, to2@example.com\""))
        #expect(html.contains("data-cc=\"cc@example.com\""))
    }

    @Test("Date attribute uses ISO-8601 format")
    func dateIsoFormat() {
        let html = EmlMarker.build(
            filename: "x.eml",
            partSection: "1",
            envelope: makeEnvelope(date: Date(timeIntervalSince1970: 1_700_000_000)),
            bodyHtml: ""
        )
        // 1700000000 → 2023-11-14T22:13:20Z
        #expect(html.range(of: "data-date=\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"", options: .regularExpression) != nil)
    }

    @Test("Missing envelope fields omit their data-* attributes")
    func missingFieldsOmitted() {
        let html = EmlMarker.build(
            filename: "x.eml",
            partSection: "1",
            envelope: EmlMarker.Envelope(subject: nil, from: nil, date: nil, to: [], cc: []),
            bodyHtml: "<p>x</p>"
        )
        #expect(!html.contains("data-subject="))
        #expect(!html.contains("data-from="))
        #expect(!html.contains("data-date="))
        #expect(!html.contains("data-to="))
        #expect(!html.contains("data-cc="))
        // Required attrs are still there
        #expect(html.contains("data-filename=\"x.eml\""))
        #expect(html.contains("data-part-section=\"1\""))
    }

    @Test("Filename with special HTML chars is escaped")
    func filenameEscaped() {
        let html = EmlMarker.build(
            filename: "a&b<c>\"d.eml",
            partSection: "1",
            envelope: makeEnvelope(),
            bodyHtml: ""
        )
        #expect(html.contains("data-filename=\"a&amp;b&lt;c&gt;&quot;d.eml\""))
    }

    @Test("Body passes through extractBodyContent — wrapped in .tm-email-body")
    func bodyWrapping() {
        let html = EmlMarker.build(
            filename: "x.eml",
            partSection: "1",
            envelope: makeEnvelope(),
            bodyHtml: "<html><head><style>.x{color:red}</style></head><body><p>Content</p></body></html>"
        )
        #expect(html.contains("<div class=\"tm-email-body\">"))
        #expect(html.contains("<p>Content</p>"))
        #expect(!html.contains("<style"))
        #expect(!html.contains("<head"))
    }

    @Test("Headers block emitted inside .tm-eml-headers wrapper")
    func headersWrapper() {
        let html = EmlMarker.build(
            filename: "x.eml",
            partSection: "1",
            envelope: makeEnvelope(subject: "S"),
            bodyHtml: ""
        )
        #expect(html.contains("<div class=\"tm-eml-headers\">"))
        #expect(html.contains("<b>Subject:</b> S"))
    }

    @Test("Marker output is consumable by parseEmlSectionMetadata")
    func roundTripThroughParser() {
        let html = EmlMarker.build(
            filename: "nested.eml",
            partSection: "42",
            envelope: makeEnvelope(
                subject: "Test",
                from: "\"Alice\" <alice@example.com>",
                to: ["bob@example.com"],
                cc: ["carol@example.com"]
            ),
            bodyHtml: "<p>body</p>"
        )
        let md = EmailFilter.parseEmlSectionMetadata(html: html, filename: "nested.eml")
        #expect(md != nil)
        #expect(md?.subject == "Test")
        #expect(md?.from == "\"Alice\" <alice@example.com>")
        #expect(md?.toList == "bob@example.com")
        #expect(md?.ccList == "carol@example.com")
        #expect(md?.partSection == "42")
    }

    @Test("Output is consumable by stripEmbeddedEmlSections")
    func stripRemovesOutput() {
        let html = "<p>Main</p>" + EmlMarker.build(
            filename: "x.eml",
            partSection: "1",
            envelope: makeEnvelope(),
            bodyHtml: "<p>Hidden from quotes</p>"
        )
        let stripped = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(stripped.contains("Main"))
        #expect(!stripped.contains("Hidden from quotes"))
        #expect(!stripped.contains("tm-eml-section"))
    }

    @Test("extractBodyContent on fragment wraps in .tm-email-body")
    func extractFragmentWrap() {
        let out = EmlMarker.extractBodyContent(from: "<p>Just a fragment</p>")
        #expect(out == "<div class=\"tm-email-body\"><p>Just a fragment</p></div>")
    }

    @Test("extractBodyContent strips <style> even in fragments")
    func extractStripsStyle() {
        let out = EmlMarker.extractBodyContent(from: "<p>A</p><style>.z{}</style><p>B</p>")
        #expect(!out.contains("<style"))
        #expect(out.contains("<p>A</p>"))
        #expect(out.contains("<p>B</p>"))
    }

    @Test("escapeHtml handles &, <, >, \"")
    func escapeHtml() {
        #expect(EmlMarker.escapeHtml("a & b") == "a &amp; b")
        #expect(EmlMarker.escapeHtml("a < b > c") == "a &lt; b &gt; c")
        #expect(EmlMarker.escapeHtml("say \"hi\"") == "say &quot;hi&quot;")
    }

    @Test("embeddedHeadersPlainText format")
    func plainTextHeaders() {
        let text = EmlMarker.embeddedHeadersPlainText(
            envelope: makeEnvelope(subject: "S", from: "F", to: ["T"], cc: ["C"]),
            filename: "z.eml"
        )
        #expect(text.contains("--- z.eml ---"))
        #expect(text.contains("Subject: S"))
        #expect(text.contains("From: F"))
        #expect(text.contains("To: T"))
        #expect(text.contains("CC: C"))
    }
}

/// `EmlMarker.extractBodyContent` builds a slice from two bounds searched in
/// **opposite directions**: `<body\b[^>]*>` forward (so the FIRST open wins)
/// and `</body>` with `.backwards` (so the LAST close wins). They used to be
/// searched independently, so the trap condition is directional and exact —
/// it fires iff **every** `</body>` precedes the **first** `<body…>`, which
/// produced a **reversed** `Range`, and `String` subscripting TRAPS on one: an
/// uncatchable precondition failure, not a throwable error.
///
/// That directionality is why `<body>A</body><body>B` is safe and
/// `</body><body>B` is not, and why a fix that merely special-cased a leading
/// `</body>` would look correct. The table below therefore carries both.
///
/// Its input is the concatenated `textContent` of nested `message/rfc822`
/// parts — raw sender bytes reached from background sync and the
/// notification-service extension with no user gesture, so the trap was a
/// relaunch-crash loop on a retryable fetch.
///
/// These tests pin the **invariant**, not the one crafted string that exposed
/// it: *for any input the extraction either slices correctly-ordered bounds or
/// takes the no-pair branch — it never traps, and it never drops content.*
/// The table varies the bound pair on every axis independently (ordering,
/// presence, multiplicity, case, attributes) because a fixture that only feeds
/// `</body><body>x` pins the example and the next spelling walks past it.
///
/// All HTML here is synthetic.
@Suite("EmlMarker.extractBodyContent — bound-pair invariant")
struct EmlMarkerBoundPairTests {

    /// One row of the adversarial shape table.
    struct Shape: CustomStringConvertible, Sendable {
        let name: String
        let html: String
        /// Substrings that MUST survive into the output on whichever branch runs.
        /// Their presence is what proves the crossed shapes fell through to the
        /// no-pair branch rather than silently returning an empty/clamped slice.
        let mustRetain: [String]
        /// Substrings that must NOT survive (the `<style>` strip runs on both
        /// branches).
        var mustNotContain: [String] = []
        var description: String { name }
    }

    static let shapes: [Shape] = [
        // --- close precedes open: the reversed-Range family ---
        Shape(name: "close before open",
              html: "</body><body>x",
              mustRetain: ["</body>", "<body>", "x"]),
        Shape(name: "close before open, uppercase tags",
              html: "</BODY><BODY>x",
              mustRetain: ["</BODY>", "<BODY>", "x"]),
        Shape(name: "close before open, mixed case",
              html: "</Body><BoDy>x",
              mustRetain: ["</Body>", "<BoDy>", "x"]),
        Shape(name: "close before open, attributes on the open tag",
              html: "</body><body class=\"c\" id=\"i\">x",
              mustRetain: ["class=\"c\"", "id=\"i\"", "x"]),
        Shape(name: "close before open, inside a full document",
              html: "<html></body><body>x</html>",
              mustRetain: ["x", "<html>"]),
        Shape(name: "close before open, with a style block to strip",
              html: "<style>.z{}</style></body><body>x",
              mustRetain: ["x"],
              mustNotContain: ["<style", ".z{}"]),
        Shape(name: "close before open, open tag is the final token",
              html: "</body>x<body>",
              mustRetain: ["x", "</body>"]),

        // --- one bound only: must take the no-pair branch, not half a slice ---
        Shape(name: "close only",
              html: "</body>plain",
              mustRetain: ["plain", "</body>"]),
        Shape(name: "open only",
              html: "<body>plain",
              mustRetain: ["plain"]),
        Shape(name: "neither bound (fragment)",
              html: "<p>fragment</p>",
              mustRetain: ["<p>fragment</p>"]),
        Shape(name: "empty input",
              html: "",
              mustRetain: []),

        // --- multiplicity: an ordered pair still exists, and must still be used ---
        Shape(name: "multiple opens",
              html: "<body><body>a</body></html>",
              mustRetain: ["a"]),
        Shape(name: "multiple closes",
              html: "<body>a</body>b</body>",
              mustRetain: ["a"]),
        Shape(name: "close, open, close",
              html: "</body><body>a</body>",
              mustRetain: ["a"]),
        // The directional negative control. A `</body>` AFTER the first `<body>`
        // does not cross even though a later `<body>` has no close of its own —
        // forward-first-open vs backwards-last-close still orders correctly. A
        // fix that special-cased "input begins with `</body>`" would pass the
        // crossed rows above and break nothing here, which is why this row and
        // `directionalNegativeControlUnchanged` below both exist.
        Shape(name: "open, close, open (does NOT cross)",
              html: "<body>A</body><body>B",
              mustRetain: ["A"]),
    ]

    @Test("Any bound-pair shape returns a wrapped result and never traps", arguments: shapes)
    func boundPairNeverTraps(shape: Shape) {
        let out = EmlMarker.extractBodyContent(from: shape.html)
        // Reaching this line IS the first half of the invariant: a reversed
        // Range is a `fatalError`, so a regression kills the test host outright
        // rather than recording a failure here.
        #expect(out.hasPrefix("<div class=\"tm-email-body\">"), "\(shape.name): missing wrapper prefix")
        #expect(out.hasSuffix("</div>"), "\(shape.name): missing wrapper suffix")
        for needle in shape.mustRetain {
            #expect(out.contains(needle), "\(shape.name): dropped \(needle.debugDescription)")
        }
        for needle in shape.mustNotContain {
            #expect(!out.contains(needle), "\(shape.name): retained \(needle.debugDescription)")
        }
    }

    // MARK: - Benign controls (literal expectations — a derived one could bless the bug)

    @Test("Benign full document is byte-identical to the pre-fix output")
    func benignFullDocumentUnchanged() {
        let out = EmlMarker.extractBodyContent(from: "<html><body>hello</body></html>")
        #expect(out == "<div class=\"tm-email-body\">hello</div>")
    }

    @Test("Benign document with head styles and body attributes keeps only the body inner")
    func benignWithHeadStylesUnchanged() {
        let out = EmlMarker.extractBodyContent(
            from: "<html><head><style>.a{}</style></head><body class=\"c\"><p>Hi</p></body></html>"
        )
        #expect(out == "<div class=\"tm-email-body\"><p>Hi</p></div>")
    }

    @Test("The LAST close still wins inside the bounded region")
    func lastCloseStillWins() {
        // `.backwards` is preserved by the fix — only its search window moved.
        let out = EmlMarker.extractBodyContent(from: "<html><body>a</body>b</body></html>")
        #expect(out == "<div class=\"tm-email-body\">a</body>b</div>")
    }

    @Test("A close AFTER the first open does not cross — byte-identical to pre-fix")
    func directionalNegativeControlUnchanged() {
        // The boundary case for the trap CONDITION. An unclosed trailing `<body>`
        // is not a crossing: the forward search takes the first open (index 0),
        // the backwards search takes the last close (index 7), and 6 < 7. Pinned
        // with a literal so a fix that clamps or widens the window is caught.
        let out = EmlMarker.extractBodyContent(from: "<body>A</body><body>B")
        #expect(out == "<div class=\"tm-email-body\">A</div>")
    }
}
