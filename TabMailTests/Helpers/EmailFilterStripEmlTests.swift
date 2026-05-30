/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailFilter.stripEmbeddedEmlSections")
struct EmailFilterStripEmlTests {

    @Test("Returns input unchanged when no marker present")
    func noMarker() {
        let html = "<p>Hello world</p><div>Some content</div>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result == html)
    }

    @Test("Removes a single tm-eml-section block")
    func singleSection() {
        let html = """
        <p>Main body content</p>
        <div class="tm-eml-section" data-filename="nested.eml"><p>Nested email</p></div>
        <p>After</p>
        """
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("Main body content"))
        #expect(result.contains("After"))
        #expect(!result.contains("Nested email"))
        #expect(!result.contains("tm-eml-section"))
        #expect(!result.contains("nested.eml"))
    }

    @Test("Surrounding whitespace is preserved")
    func preservesSurroundingWhitespace() {
        let html = "<p>Before</p>\n<div class=\"tm-eml-section\">X</div>\n<p>After</p>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("<p>Before</p>"))
        #expect(result.contains("<p>After</p>"))
        #expect(!result.contains("tm-eml-section"))
    }

    @Test("Nested divs inside section — entire section removed")
    func nestedDivs() {
        let html = """
        <p>Before</p>
        <div class="tm-eml-section" data-filename="x.eml">
            <div class="tm-eml-headers">
                <div>Subject: Test</div>
                <div>From: A</div>
            </div>
            <div class="tm-email-body">
                <div>Hello</div>
                <div><div>Deeply nested</div></div>
            </div>
        </div>
        <p>After</p>
        """
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
        #expect(!result.contains("Subject: Test"))
        #expect(!result.contains("Hello"))
        #expect(!result.contains("Deeply nested"))
        #expect(!result.contains("tm-eml-section"))
    }

    @Test("Multiple sections — all removed, non-section content kept")
    func multipleSections() {
        let html = """
        <p>Main</p>
        <div class="tm-eml-section" data-filename="a.eml"><p>A body</p></div>
        <p>Middle</p>
        <div class="tm-eml-section" data-filename="b.eml"><p>B body</p></div>
        <p>End</p>
        """
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("Main"))
        #expect(result.contains("Middle"))
        #expect(result.contains("End"))
        #expect(!result.contains("A body"))
        #expect(!result.contains("B body"))
    }

    @Test("Section with additional classes still matched")
    func additionalClasses() {
        let html = "<p>X</p><div class=\"foo tm-eml-section bar\" data-filename=\"x.eml\">hidden</div><p>Y</p>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("X"))
        #expect(result.contains("Y"))
        #expect(!result.contains("hidden"))
    }

    @Test("Case-insensitive tag name")
    func caseInsensitiveTag() {
        let html = "<p>X</p><DIV class=\"tm-eml-section\">hidden</DIV><p>Y</p>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("X"))
        #expect(result.contains("Y"))
        #expect(!result.contains("hidden"))
    }

    @Test("Single-quoted class attribute")
    func singleQuotedClass() {
        let html = "<p>X</p><div class='tm-eml-section'>hidden</div><p>Y</p>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("X"))
        #expect(result.contains("Y"))
        #expect(!result.contains("hidden"))
    }

    @Test("Div with tm-eml-section not as whole-token class is NOT removed")
    func partialClassMatch() {
        // "tm-eml-sections" (plural) should not match the "tm-eml-section" token
        let html = "<p>A</p><div class=\"tm-eml-sections\">kept</div><p>B</p>"
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("kept"))
    }

    @Test("htmlToPlainText still sees content inside tm-eml-section (FTS invariant)")
    func ftsStillFindsContent() {
        let html = """
        <p>Main message</p>
        <div class="tm-eml-section" data-filename="g.eml">
            <div class="tm-email-body">surplus transferred to next quarter</div>
        </div>
        """
        // FTS must still be able to find .eml content via htmlToPlainText (no strip).
        let fts = EmailFilter.htmlToPlainText(html)
        #expect(fts.contains("Main message"))
        #expect(fts.contains("surplus transferred"))
        // But after stripping, it's gone.
        let stripped = EmailFilter.stripEmbeddedEmlSections(html)
        let strippedPlain = EmailFilter.htmlToPlainText(stripped)
        #expect(strippedPlain.contains("Main message"))
        #expect(!strippedPlain.contains("surplus transferred"))
    }

    @Test("Empty input")
    func emptyInput() {
        #expect(EmailFilter.stripEmbeddedEmlSections("") == "")
    }

    @Test("Malformed HTML — unclosed div — does not crash")
    func malformedUnclosed() {
        let html = "<p>A</p><div class=\"tm-eml-section\"><p>No close"
        // Should not crash. The section consumes to end of input; content before is preserved.
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("A"))
        #expect(!result.contains("No close"))
    }

    @Test("Section adjacent to non-section div")
    func adjacentNormalDiv() {
        let html = """
        <div>Normal div before</div>
        <div class="tm-eml-section">hidden</div>
        <div>Normal div after</div>
        """
        let result = EmailFilter.stripEmbeddedEmlSections(html)
        #expect(result.contains("Normal div before"))
        #expect(result.contains("Normal div after"))
        #expect(!result.contains("hidden"))
    }
}
