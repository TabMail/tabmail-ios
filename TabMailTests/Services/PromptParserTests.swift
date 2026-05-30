/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PromptParser extractSection")
struct PromptParserExtractSectionTests {

    @Test("Extracts section content between headers")
    func extractsBetweenHeaders() {
        let markdown = """
        # General writing style <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - Be concise
        - Use active voice

        # Language <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - English
        """
        let result = PromptParser.extractSection(from: markdown, header: "General writing style")
        #expect(result.contains("Be concise"))
        #expect(result.contains("Use active voice"))
        #expect(!result.contains("English"))
    }

    @Test("Extracts last section before end marker")
    func extractsBeforeEndMarker() {
        let markdown = """
        # Language <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - English
        - Spanish
        ====END USER INSTRUCTIONS====
        """
        let result = PromptParser.extractSection(from: markdown, header: "Language")
        #expect(result.contains("English"))
        #expect(result.contains("Spanish"))
    }

    @Test("Returns empty for missing section")
    func missingSection() {
        let markdown = """
        # Something <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - Content here
        """
        let result = PromptParser.extractSection(from: markdown, header: "NonExistent")
        #expect(result.isEmpty)
    }

    @Test("Trims leading and trailing blank lines")
    func trimsBlankLines() {
        let markdown = """
        # Test <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->

        - Content

        # Next <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        """
        let result = PromptParser.extractSection(from: markdown, header: "Test")
        #expect(result == "- Content")
    }
}

@Suite("PromptParser extractBullets")
struct PromptParserExtractBulletsTests {

    @Test("Extracts bullet items")
    func extractsBullets() {
        let text = """
        - First item
        - Second item
        - Third item
        """
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["First item", "Second item", "Third item"])
    }

    @Test("Ignores non-bullet lines")
    func ignoresNonBullets() {
        let text = """
        Some text
        - A bullet
        More text
        * Not a bullet (wrong prefix)
        """
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["A bullet"])
    }

    @Test("Handles whitespace around bullets")
    func handlesWhitespace() {
        let text = "  - Indented item  "
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["Indented item"])
    }

    @Test("Empty text returns empty array")
    func emptyText() {
        let bullets = PromptParser.extractBullets(from: "")
        #expect(bullets.isEmpty)
    }
}

@Suite("PromptParser mergeBullets")
struct PromptParserMergeBulletsTests {

    @Test("No changes returns local as-is")
    func noChanges() {
        let base = ["A", "B", "C"]
        let local = ["A", "B", "C"]
        let remote = ["A", "B", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Remote addition appended to local")
    func remoteAddition() {
        let base = ["A", "B"]
        let local = ["A", "B"]
        let remote = ["A", "B", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Remote removal applied to local")
    func remoteRemoval() {
        let base = ["A", "B", "C"]
        let local = ["A", "B", "C"]
        let remote = ["A", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "C"])
    }

    @Test("Local addition preserved")
    func localAddition() {
        let base = ["A", "B"]
        let local = ["A", "B", "D"]
        let remote = ["A", "B"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "B", "D"])
    }

    @Test("Both add different items")
    func bothAddDifferent() {
        let base = ["A"]
        let local = ["A", "B"]
        let remote = ["A", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result.contains("A"))
        #expect(result.contains("B"))
        #expect(result.contains("C"))
        #expect(result.count == 3)
    }

    @Test("Remote removes and adds")
    func remoteRemoveAndAdd() {
        let base = ["A", "B"]
        let local = ["A", "B"]
        let remote = ["A", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "C"])
    }

    @Test("Local ordering preserved")
    func localOrderingPreserved() {
        let base = ["A", "B", "C"]
        let local = ["C", "B", "A"]
        let remote = ["A", "B", "C", "D"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        // Local ordering preserved: C, B, A — then D appended
        #expect(result == ["C", "B", "A", "D"])
    }

    @Test("Duplicate remote additions not duplicated")
    func noDuplicateRemoteAdditions() {
        let base = ["A"]
        let local = ["A", "B"]
        let remote = ["A", "B"]  // B also added by remote but already in local
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "B"])
    }

    @Test("Empty base treats all remote as additions")
    func emptyBase() {
        let base: [String] = []
        let local = ["A"]
        let remote = ["B"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result.contains("A"))
        #expect(result.contains("B"))
    }
}

@Suite("PromptParser mergeFlatField")
struct PromptParserMergeFlatFieldTests {

    @Test("No changes returns local")
    func noChanges() {
        let text = "- A\n- B"
        let result = PromptParser.mergeFlatField(base: text, local: text, remote: text)
        #expect(result == text)
    }

    @Test("Remote adds bullet")
    func remoteAddsBullet() {
        let base = "- A\n- B"
        let local = "- A\n- B"
        let remote = "- A\n- B\n- C"
        let result = PromptParser.mergeFlatField(base: base, local: local, remote: remote)
        #expect(result.contains("- A"))
        #expect(result.contains("- B"))
        #expect(result.contains("- C"))
    }
}

@Suite("PromptParser replaceSection")
struct PromptParserReplaceSectionTests {

    @Test("Replaces section content")
    func replacesContent() {
        let markdown = """
        # Test <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - Old content

        # Next <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - Kept
        """
        let result = PromptParser.replaceSection(in: markdown, header: "Test", with: "- New content")
        #expect(result.contains("- New content"))
        #expect(!result.contains("- Old content"))
        #expect(result.contains("- Kept"))
    }

    @Test("Preserves section header")
    func preservesHeader() {
        let markdown = """
        # Test <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->
        - Old
        """
        let result = PromptParser.replaceSection(in: markdown, header: "Test", with: "- New")
        #expect(result.contains("# Test <!-- DO NOT EDIT/DELETE THIS SECTION HEADER -->"))
    }
}
