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
