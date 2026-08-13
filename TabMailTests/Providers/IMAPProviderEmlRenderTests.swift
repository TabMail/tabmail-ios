/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

@Suite("IMAPFetchMapping.renderBodyWithEmbeddedHeaders — embedded .eml rendering")
struct EmlRenderTests {

    // MARK: - Helpers

    /// Build a SwiftMail.Message with specific body parts.
    private func makeMessage(parts: [MessagePart]) -> SwiftMail.Message {
        let header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Test")
        return Message(header: header, parts: parts)
    }

    private func makeTextPlainPart(section: String, text: String) -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: "text/plain; charset=utf-8",
            data: text.data(using: .utf8)
        )
    }

    private func makeTextHtmlPart(section: String, html: String) -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: "text/html; charset=utf-8",
            data: html.data(using: .utf8)
        )
    }

    private func makeRfc822Part(section: String, filename: String?, subject: String? = nil) -> MessagePart {
        let embeddedInfo = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            subject: subject ?? "Embedded Subject",
            from: "sender@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(timeIntervalSince1970: 1710000000)
        )
        return MessagePart(
            sectionString: section,
            contentType: "message/rfc822",
            filename: filename,
            embeddedMessageInfo: embeddedInfo
        )
    }

    // MARK: - Basic rendering

    @Test("Plain text message without .eml renders normally")
    func plainTextNoEml() {
        let parts = [makeTextPlainPart(section: "1", text: "Hello world")]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/plain")
        #expect(result == "Hello world")
    }

    @Test("HTML message without .eml renders normally")
    func htmlNoEml() {
        let parts = [makeTextHtmlPart(section: "1", html: "<p>Hello</p>")]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result == "<p>Hello</p>")
    }

    @Test("Returns nil when no matching parts exist")
    func noMatchingParts() {
        let parts = [makeTextPlainPart(section: "1", text: "Hello")]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result == nil)
    }

    // MARK: - Embedded .eml with top-level HTML

    @Test("Message with top-level HTML and embedded .eml HTML renders both")
    func topLevelHtmlAndEml() {
        // multipart/mixed: text/html at 1, message/rfc822 at 2, text/html at 2.1
        let parts = [
            makeTextHtmlPart(section: "1", html: "<p>Main body</p>"),
            makeRfc822Part(section: "2", filename: "test.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>Embedded body</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        // Main body should be included (before any .eml-section wrapper)
        #expect(result!.contains("<p>Main body</p>"))
        // Embedded body should be included
        #expect(result!.contains("<p>Embedded body</p>"))
        // Embedded headers should be present
        #expect(result!.contains("<b>test.eml</b>"))
        // Main body comes first
        let mainRange = result!.range(of: "Main body")!
        let embeddedRange = result!.range(of: "Embedded body")!
        #expect(mainRange.lowerBound < embeddedRange.lowerBound)
        // Embedded content is wrapped in a .tm-eml-section marker
        #expect(result!.contains("class=\"tm-eml-section\""))
        #expect(result!.contains("data-filename=\"test.eml\""))
        #expect(result!.contains("data-part-section=\"2\""))
        // Main body is OUTSIDE the .tm-eml-section wrapper
        let mainPos = result!.range(of: "Main body")!.lowerBound
        let sectionPos = result!.range(of: "tm-eml-section")!.lowerBound
        #expect(mainPos < sectionPos)
    }

    // MARK: - The main bug: text/plain main body + HTML .eml

    @Test("Text-only main body with HTML .eml includes main text as HTML")
    func textOnlyMainWithHtmlEml() {
        // multipart/mixed: text/plain at 1, message/rfc822 at 2, text/html at 2.1.2
        let parts = [
            makeTextPlainPart(section: "1", text: "Hi Alex, this is the main body."),
            makeRfc822Part(section: "2", filename: "nested.eml"),
            makeTextHtmlPart(section: "2.1.2", html: "<p>Embedded HTML content</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        // Main body text should be present (converted to HTML via plainTextToHTML)
        #expect(result!.contains("Hi Alex, this is the main body."))
        // Embedded HTML body should be present
        #expect(result!.contains("Embedded HTML content"))
        // Embedded headers should be present
        #expect(result!.contains("<b>nested.eml</b>"))
        // The main body text should come BEFORE the embedded section wrapper
        let mainRange = result!.range(of: "Hi Alex")!
        let sectionRange = result!.range(of: "tm-eml-section")!
        #expect(mainRange.lowerBound < sectionRange.lowerBound)
        // Should be wrapped in plainTextToHTML container (main body promoted)
        #expect(result!.contains("white-space:pre-wrap"))
        // Embedded content wrapped in .tm-eml-section
        #expect(result!.contains("data-filename=\"nested.eml\""))
    }

    @Test("Text-only main body with text-only .eml does not double-prepend")
    func textOnlyMainWithTextOnlyEml() {
        // Both main and .eml are text/plain — no HTML parts at all
        let parts = [
            makeTextPlainPart(section: "1", text: "Main message."),
            makeRfc822Part(section: "2", filename: "note.eml"),
            makeTextPlainPart(section: "2.1", text: "Embedded text."),
        ]
        let message = makeMessage(parts: parts)
        // text/html should be nil since no HTML parts exist
        let htmlResult = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(htmlResult == nil)
        // text/plain should have both
        let textResult = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/plain")
        #expect(textResult != nil)
        #expect(textResult!.contains("Main message."))
        #expect(textResult!.contains("Embedded text."))
    }

    @Test("No main body — only .eml HTML renders without extra prefix")
    func noMainBodyOnlyEmlHtml() {
        // Only the embedded .eml has content (main message is empty forwarding wrapper)
        let parts = [
            makeRfc822Part(section: "1", filename: "forwarded.eml"),
            makeTextHtmlPart(section: "1.1", html: "<p>Forwarded content</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        #expect(result!.contains("Forwarded content"))
        #expect(result!.contains("<b>forwarded.eml</b>"))
        // Should NOT contain pre-wrap div (no top-level text was prepended)
        #expect(!result!.contains("white-space:pre-wrap"))
    }

    // MARK: - Multiple embedded .eml parts

    @Test("Multiple .eml attachments with text-only main body")
    func multipleEmlsWithTextMain() {
        let parts = [
            makeTextPlainPart(section: "1", text: "See attached."),
            makeRfc822Part(section: "2", filename: "first.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>First email</p>"),
            makeRfc822Part(section: "3", filename: "second.eml"),
            makeTextHtmlPart(section: "3.1", html: "<p>Second email</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        // Main text included
        #expect(result!.contains("See attached."))
        // Both .eml contents included
        #expect(result!.contains("First email"))
        #expect(result!.contains("Second email"))
        // Both headers included
        #expect(result!.contains("<b>first.eml</b>"))
        #expect(result!.contains("<b>second.eml</b>"))
        // Both wrapped in separate .tm-eml-section blocks with distinct filenames
        #expect(result!.contains("data-filename=\"first.eml\""))
        #expect(result!.contains("data-filename=\"second.eml\""))
        // Exactly two sections
        let sectionCount = result!.components(separatedBy: "class=\"tm-eml-section\"").count - 1
        #expect(sectionCount == 2)
    }

    // MARK: - Edge case: main HTML exists alongside .eml

    // MARK: - Reachability of the bound-pair invariant

    /// The unit invariant lives in `EmlMarkerBoundPairTests`; this proves the
    /// crafted bytes actually REACH it. A nested `message/rfc822` `text/html`
    /// part's `textContent` is concatenated verbatim into `nestedBodyHtml` and
    /// handed to `EmlMarker.build` → `extractBodyContent`, so a sender-supplied
    /// `</body>` before the first `<body…>` used to reverse the slice's bounds
    /// and trap here — on the background-sync and NSE paths, with no user
    /// gesture. Entirely in-process: no network, no server fake.
    @Test("Nested .eml body whose </body> precedes its <body> renders without trapping")
    func nestedEmlCrossedBodyTagsRender() {
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body"),
            makeRfc822Part(section: "2", filename: "crafted.eml"),
            makeTextHtmlPart(section: "2.1", html: "</body><body>x"),
        ]
        let message = makeMessage(parts: parts)
        // Returning at all is the assertion: a reversed Range is a `fatalError`,
        // which Swift Testing cannot catch — a regression kills the host.
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        #expect(result!.contains("data-filename=\"crafted.eml\""))
        // The sender's payload survives into the marker (no-pair branch), so the
        // fix cannot be mistaken for "drop the section on crossed tags".
        #expect(result!.contains("x"))
        #expect(result!.contains("tm-email-body"))
    }

    /// The guarded string is **derived**, not any one part's bytes:
    /// `renderBodyWithEmbeddedHeaders` concatenates the `textContent` of every
    /// nested body under one `message/rfc822` part before handing the result to
    /// `EmlMarker.build`. Neither part below crosses on its own — the crossing
    /// only exists in the concatenation — so a parser that sanitized each part
    /// individually would not have prevented this.
    @Test("Crossed body tags formed only by CONCATENATION of two nested parts")
    func nestedEmlCrossedByConcatenation() {
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body"),
            makeRfc822Part(section: "2", filename: "split.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>alpha</p></body>"),
            makeTextHtmlPart(section: "2.2", html: "<body><p>beta</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        #expect(result!.contains("data-filename=\"split.eml\""))
        // Both halves of the concatenation survive — nothing was dropped.
        #expect(result!.contains("alpha"))
        #expect(result!.contains("beta"))
    }

    // MARK: - extractBodyContent

    @Test("extractBodyContent: extracts body from full HTML document")
    func extractBodyFromFullDocument() {
        let html = """
        <html><head><style>.foo { color: red; }</style></head>
        <body lang="EN-CA"><p>Hello</p></body></html>
        """
        let result = IMAPProvider.extractBodyContent(from: html)
        #expect(result.contains("tm-email-body"))
        #expect(result.contains("<p>Hello</p>"))
        // Style block stripped
        #expect(!result.contains("<style"))
        #expect(!result.contains(".foo"))
        // Head stripped
        #expect(!result.contains("<head"))
        #expect(!result.contains("<html"))
    }

    @Test("extractBodyContent: strips inline <style> blocks outside head")
    func extractStripsAllStyleBlocks() {
        let html = """
        <html><body>
        <style>.MsoNormal { font-size: 11pt; }</style>
        <p>Content</p>
        <style>@page { size: 612pt 792pt; }</style>
        </body></html>
        """
        let result = IMAPProvider.extractBodyContent(from: html)
        #expect(result.contains("<p>Content</p>"))
        #expect(!result.contains("<style"))
        #expect(!result.contains("MsoNormal"))
        #expect(!result.contains("@page"))
    }

    @Test("extractBodyContent: fragment without body tag still wrapped")
    func extractFragment() {
        let html = "<p>Just a fragment</p>"
        let result = IMAPProvider.extractBodyContent(from: html)
        #expect(result == "<div class=\"tm-email-body\"><p>Just a fragment</p></div>")
    }

    @Test("extractBodyContent: fragment with style block strips style")
    func extractFragmentWithStyle() {
        let html = """
        <p>Hello</p><style>.foo { font-size: 9pt; }</style><p>World</p>
        """
        let result = IMAPProvider.extractBodyContent(from: html)
        #expect(result.contains("<p>Hello</p>"))
        #expect(result.contains("<p>World</p>"))
        #expect(!result.contains("<style"))
        #expect(!result.contains(".foo"))
    }

    @Test("Embedded .eml with Outlook full HTML document is stripped to body and wrapped")
    func outlookHtmlFullyStripped() {
        let outlookHtml = """
        <html xmlns:v="urn:schemas-microsoft-com:vml"
              xmlns:o="urn:schemas-microsoft-com:office:office"><head>
        <meta http-equiv="Content-Type" content="text/html; charset=us-ascii">
        <style><!--
        p.MsoNormal { margin: 0cm; font-size: 11.0pt; font-family: Calibri, sans-serif; }
        .MsoChpDefault { font-size: 10.0pt; }
        @page WordSection1 { size: 612.0pt 792.0pt; margin: 72.0pt; }
        div.WordSection1 { page: WordSection1; }
        --></style>
        </head><body lang="EN-CA">
        <div class="WordSection1">
        <p class="MsoNormal"><span style="font-size:11.0pt;">Main content</span></p>
        </div></body></html>
        """
        let parts = [
            makeRfc822Part(section: "1", filename: "outlook.eml"),
            makeTextHtmlPart(section: "1.1", html: outlookHtml),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        // Must include actual content
        #expect(result!.contains("Main content"))
        // Must wrap in tm-email-body so our CSS can target it
        #expect(result!.contains("tm-email-body"))
        // All style/page/font CSS must be stripped — these leak globally and break layout
        #expect(!result!.contains("<style"))
        #expect(!result!.contains("@page"))
        #expect(!result!.contains("MsoChpDefault"))
        #expect(!result!.contains("font-size: 10.0pt"))
        // The document-level tags must be gone
        #expect(!result!.contains("<html"))
        #expect(!result!.contains("<head"))
        #expect(!result!.contains("<!DOCTYPE"))
        // But the WordSection1 div (inline styles already gone — it was a pure class)
        // can remain; our CSS neutralizes it.
    }

    @Test("Marker carries envelope metadata as data-* attributes")
    func markerCarriesEnvelopeMetadata() {
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body"),
            makeRfc822Part(section: "2", filename: "nested.eml", subject: "RE: Quarterly Plan"),
            makeTextHtmlPart(section: "2.1", html: "<p>Embedded</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        #expect(result.contains("data-filename=\"nested.eml\""))
        #expect(result.contains("data-part-section=\"2\""))
        #expect(result.contains("data-subject=\"RE: Quarterly Plan\""))
        #expect(result.contains("data-from=\"sender@example.com\""))
        #expect(result.contains("data-to=\"recipient@example.com\""))
        // Date is ISO-8601 format
        #expect(result.range(of: "data-date=\"[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression) != nil)
    }

    @Test("parseEmlSectionMetadata extracts envelope from marker")
    func parseEmlSectionMetadataHappyPath() {
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body"),
            makeRfc822Part(section: "2", filename: "nested.eml", subject: "RE: Quarterly Plan"),
            makeTextHtmlPart(section: "2.1", html: "<p>Embedded</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let md = EmailFilter.parseEmlSectionMetadata(html: result, filename: "nested.eml")
        #expect(md != nil)
        #expect(md?.subject == "RE: Quarterly Plan")
        #expect(md?.from == "sender@example.com")
        #expect(md?.toList == "recipient@example.com")
        #expect(md?.partSection == "2")
        #expect(md?.date != nil)
    }

    @Test("parseEmlSectionMetadata returns nil for non-matching filename")
    func parseEmlSectionMetadataMiss() {
        let parts = [
            makeRfc822Part(section: "2", filename: "a.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>A</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let md = EmailFilter.parseEmlSectionMetadata(html: result, filename: "b.eml")
        #expect(md == nil)
    }

    @Test("parseEmlSectionMetadata selects correct marker among multiple")
    func parseEmlSectionMetadataMultiple() {
        let parts = [
            makeRfc822Part(section: "2", filename: "first.eml", subject: "First"),
            makeTextHtmlPart(section: "2.1", html: "<p>A</p>"),
            makeRfc822Part(section: "3", filename: "second.eml", subject: "Second"),
            makeTextHtmlPart(section: "3.1", html: "<p>B</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let first = EmailFilter.parseEmlSectionMetadata(html: result, filename: "first.eml")
        let second = EmailFilter.parseEmlSectionMetadata(html: result, filename: "second.eml")
        #expect(first?.subject == "First")
        #expect(second?.subject == "Second")
        #expect(first?.partSection == "2")
        #expect(second?.partSection == "3")
    }

    @Test("parseEmlSectionMetadata decodes HTML entities in attribute values")
    func parseEmlSectionMetadataHTMLEntities() {
        // Subject with characters that get HTML-escaped ("&", "<", ">", '"')
        let parts = [
            makeRfc822Part(section: "2", filename: "q.eml", subject: "A&B <x>"),
            makeTextHtmlPart(section: "2.1", html: "<p>X</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let md = EmailFilter.parseEmlSectionMetadata(html: result, filename: "q.eml")
        #expect(md?.subject == "A&B <x>")
    }

    @Test("FTS invariant — htmlToPlainText still finds content inside .tm-eml-section")
    func ftsStillFindsEmbedded() {
        // The unified-blob architecture requires that FTS (htmlToPlainText)
        // continues to index content that's visually hidden via CSS class.
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body visible"),
            makeRfc822Part(section: "2", filename: "nested.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>surplus transferred to next quarter</p>"),
        ]
        let message = makeMessage(parts: parts)
        let html = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let plainForFTS = EmailFilter.htmlToPlainText(html)
        #expect(plainForFTS.contains("Main body visible"))
        #expect(plainForFTS.contains("surplus transferred"))
    }

    @Test("Strip invariant — stripEmbeddedEmlSections removes .eml content but keeps main body")
    func stripInvariant() {
        let parts = [
            makeTextPlainPart(section: "1", text: "Main body visible"),
            makeRfc822Part(section: "2", filename: "nested.eml", subject: "RE: Quarterly Plan"),
            makeTextHtmlPart(section: "2.1", html: "<p>surplus transferred</p>"),
        ]
        let message = makeMessage(parts: parts)
        let html = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")!
        let stripped = EmailFilter.stripEmbeddedEmlSections(html)
        // Main body survives the strip
        #expect(stripped.contains("Main body visible"))
        // .eml content is gone
        #expect(!stripped.contains("surplus transferred"))
        #expect(!stripped.contains("RE: Quarterly Plan"))
        #expect(!stripped.contains("tm-eml-section"))
    }

    @Test("Top-level HTML exists — no text/plain prepend occurs")
    func topLevelHtmlExists() {
        // Main has HTML — no need to prepend text/plain
        let parts = [
            makeTextPlainPart(section: "1.1", text: "Plain version"),
            makeTextHtmlPart(section: "1.2", html: "<p>HTML version</p>"),
            makeRfc822Part(section: "2", filename: "attached.eml"),
            makeTextHtmlPart(section: "2.1", html: "<p>Attachment HTML</p>"),
        ]
        let message = makeMessage(parts: parts)
        let result = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        #expect(result != nil)
        // HTML version used, NOT plain version converted
        #expect(result!.contains("<p>HTML version</p>"))
        #expect(!result!.contains("white-space:pre-wrap"))
        // Attachment included
        #expect(result!.contains("Attachment HTML"))
    }
}
