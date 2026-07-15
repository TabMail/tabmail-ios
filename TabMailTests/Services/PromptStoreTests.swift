/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - PromptParser.mergeSectionedField Tests

@Suite("PromptParser mergeSectionedField")
struct PromptParserMergeSectionedFieldTests {

    // Use realistic markdown with the actual section header format
    private func compositionMarkdown(
        writingStyle: String = "- Be concise",
        language: String = "- English",
        links: String = ""
    ) -> String {
        """
        # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        \(writingStyle)

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        \(language)

        # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)
        \(links)

        ====END USER INSTRUCTIONS====
        """
    }

    @Test("No changes returns local unchanged")
    func noChanges() {
        let md = compositionMarkdown()
        let result = PromptParser.mergeSectionedField(
            base: md, local: md, remote: md,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        #expect(result == md)
    }

    @Test("Remote adds bullet to one section")
    func remoteAddsBulletToOneSection() {
        let base = compositionMarkdown()
        let local = compositionMarkdown()
        let remote = compositionMarkdown(writingStyle: "- Be concise\n- Use active voice")
        let result = PromptParser.mergeSectionedField(
            base: base, local: local, remote: remote,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        #expect(result.contains("Be concise"))
        #expect(result.contains("Use active voice"))
        #expect(result.contains("English"))
    }

    @Test("Local changes preserved when remote adds to different section")
    func localAndRemoteDifferentSections() {
        let base = compositionMarkdown()
        let local = compositionMarkdown(writingStyle: "- Be concise\n- Be formal")
        let remote = compositionMarkdown(language: "- English\n- Spanish")
        let result = PromptParser.mergeSectionedField(
            base: base, local: local, remote: remote,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        #expect(result.contains("Be formal"))
        #expect(result.contains("Spanish"))
    }

    @Test("Remote removal applied across sections")
    func remoteRemoval() {
        let base = compositionMarkdown(writingStyle: "- Be concise\n- Be verbose")
        let local = compositionMarkdown(writingStyle: "- Be concise\n- Be verbose")
        let remote = compositionMarkdown(writingStyle: "- Be concise")
        let result = PromptParser.mergeSectionedField(
            base: base, local: local, remote: remote,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        #expect(result.contains("Be concise"))
        #expect(!result.contains("Be verbose"))
    }

    @Test("Both add to same section merges correctly")
    func bothAddToSameSection() {
        let base = compositionMarkdown(writingStyle: "- Be concise")
        let local = compositionMarkdown(writingStyle: "- Be concise\n- Use humor")
        let remote = compositionMarkdown(writingStyle: "- Be concise\n- Sign off as user")
        let result = PromptParser.mergeSectionedField(
            base: base, local: local, remote: remote,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        #expect(result.contains("Be concise"))
        #expect(result.contains("Use humor"))
        #expect(result.contains("Sign off as user"))
    }

    @Test("Action markdown with all four sections")
    func actionMarkdownMerge() {
        let base = """
        # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Spam
        # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Newsletters
        # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Urgent
        # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Uncategorized
        ====END USER INSTRUCTIONS====
        """
        let local = base
        let remote = """
        # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Spam
        - Phishing
        # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Newsletters
        # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Urgent
        # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Uncategorized
        ====END USER INSTRUCTIONS====
        """
        let result = PromptParser.mergeSectionedField(
            base: base, local: local, remote: remote,
            sectionHeaders: PromptParser.actionSectionHeaders
        )
        #expect(result.contains("Phishing"))
        #expect(result.contains("Newsletters"))
        #expect(result.contains("Urgent"))
    }
}

// MARK: - PromptParser.replaceSection Edge Cases

@Suite("PromptParser replaceSection edge cases")
struct PromptParserReplaceSectionEdgeCaseTests {

    @Test("Replaces section before end marker")
    func replacesBeforeEndMarker() {
        let markdown = """
        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English

        ====END USER INSTRUCTIONS====
        Some footer
        """
        let result = PromptParser.replaceSection(in: markdown, header: "Language", with: "- French")
        #expect(result.contains("- French"))
        #expect(!result.contains("- English"))
        #expect(result.contains("====END USER INSTRUCTIONS===="))
        #expect(result.contains("Some footer"))
    }

    @Test("Replaces empty section content")
    func replacesEmptySection() {
        let markdown = """
        # Links (DO NOT EDIT/DELETE THIS SECTION HEADER)

        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Content
        """
        let result = PromptParser.replaceSection(in: markdown, header: "Links", with: "- https://example.com")
        #expect(result.contains("- https://example.com"))
        #expect(result.contains("- Content"))
    }

    @Test("No matching header returns markdown unchanged")
    func noMatchingHeader() {
        let markdown = "# Something (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Content"
        let result = PromptParser.replaceSection(in: markdown, header: "NonExistent", with: "- New")
        #expect(result == markdown)
    }

    @Test("Multi-line replacement")
    func multiLineReplacement() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Old

        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Keep
        """
        let newContent = "- Line 1\n- Line 2\n- Line 3"
        let result = PromptParser.replaceSection(in: markdown, header: "Style", with: newContent)
        #expect(result.contains("- Line 1"))
        #expect(result.contains("- Line 2"))
        #expect(result.contains("- Line 3"))
        #expect(!result.contains("- Old"))
        #expect(result.contains("- Keep"))
    }
}

// MARK: - PromptParser.extractSection Edge Cases

@Suite("PromptParser extractSection edge cases")
struct PromptParserExtractSectionEdgeCaseTests {

    @Test("Extracts section with parentheses format header")
    func parenthesesFormat() {
        let markdown = """
        # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Be concise
        - Use active voice

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English
        """
        let result = PromptParser.extractSection(from: markdown, header: "General writing style")
        #expect(result.contains("Be concise"))
        #expect(result.contains("Use active voice"))
        #expect(!result.contains("English"))
    }

    @Test("Extracts content from last section before end marker")
    func lastSectionBeforeEndMarker() {
        let markdown = """
        # Links (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - https://example.com

        ====END USER INSTRUCTIONS====

        Now, acknowledge these instructions.
        """
        let result = PromptParser.extractSection(from: markdown, header: "Links")
        #expect(result == "- https://example.com")
    }

    @Test("Empty section returns empty string")
    func emptySection() {
        let markdown = """
        # Links (DO NOT EDIT/DELETE THIS SECTION HEADER)

        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Content
        """
        let result = PromptParser.extractSection(from: markdown, header: "Links")
        #expect(result.isEmpty)
    }

    @Test("Section with multiple blank lines trimmed")
    func multipleBlankLinesTrimmed() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)


        - Content here


        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        """
        let result = PromptParser.extractSection(from: markdown, header: "Style")
        #expect(result == "- Content here")
    }
}

// MARK: - PromptParser.extractBullets Edge Cases

@Suite("PromptParser extractBullets edge cases")
struct PromptParserExtractBulletsEdgeCaseTests {

    @Test("Extracts bullets with mixed indentation")
    func mixedIndentation() {
        let text = "- First\n  - Second\n    - Third"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["First", "Second", "Third"])
    }

    @Test("Preserves bullet content with special characters")
    func specialCharacters() {
        let text = "- Use `code` formatting\n- Emails from @example.com\n- Price: $10"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets.count == 3)
        #expect(bullets[0] == "Use `code` formatting")
        #expect(bullets[1] == "Emails from @example.com")
        #expect(bullets[2] == "Price: $10")
    }

    @Test("Handles text with only non-bullet lines")
    func onlyNonBulletLines() {
        let text = "Hello world\nNo bullets here\n* Star prefix"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets.isEmpty)
    }

    @Test("Single bullet")
    func singleBullet() {
        let bullets = PromptParser.extractBullets(from: "- Only one")
        #expect(bullets == ["Only one"])
    }
}

// MARK: - PromptParser.mergeBullets Edge Cases

@Suite("PromptParser mergeBullets edge cases")
struct PromptParserMergeBulletsEdgeCaseTests {

    @Test("All empty arrays")
    func allEmpty() {
        let result = PromptParser.mergeBullets(base: [], local: [], remote: [])
        #expect(result.isEmpty)
    }

    @Test("Local empty, remote has items")
    func localEmptyRemoteHasItems() {
        let result = PromptParser.mergeBullets(base: [], local: [], remote: ["A", "B"])
        #expect(result == ["A", "B"])
    }

    @Test("Remote removes all items")
    func remoteRemovesAll() {
        let result = PromptParser.mergeBullets(base: ["A", "B"], local: ["A", "B"], remote: [])
        #expect(result.isEmpty)
    }

    @Test("Local removes item that remote also removes")
    func bothRemoveSameItem() {
        let base = ["A", "B", "C"]
        let local = ["A", "C"]
        let remote = ["A", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "C"])
    }

    @Test("Remote adds item already in local (no duplicate)")
    func remoteAddsExistingLocal() {
        let base = ["A"]
        let local = ["A", "B"]
        let remote = ["A", "B"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result == ["A", "B"])
    }

    @Test("Remote replaces item (remove old + add new)")
    func remoteReplacesItem() {
        let base = ["A", "B", "C"]
        let local = ["A", "B", "C"]
        let remote = ["A", "D", "C"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result.contains("A"))
        #expect(result.contains("C"))
        #expect(result.contains("D"))
        #expect(!result.contains("B"))
    }
}

// MARK: - PromptParser.mergeFlatField Edge Cases

@Suite("PromptParser mergeFlatField edge cases")
struct PromptParserMergeFlatFieldEdgeCaseTests {

    @Test("Remote removes bullet from flat field")
    func remoteRemovesBullet() {
        let base = "- A\n- B\n- C"
        let local = "- A\n- B\n- C"
        let remote = "- A\n- C"
        let result = PromptParser.mergeFlatField(base: base, local: local, remote: remote)
        #expect(result.contains("- A"))
        #expect(result.contains("- C"))
        #expect(!result.contains("- B"))
    }

    @Test("Both add different bullets to flat field")
    func bothAddDifferent() {
        let base = "- A"
        let local = "- A\n- B"
        let remote = "- A\n- C"
        let result = PromptParser.mergeFlatField(base: base, local: local, remote: remote)
        #expect(result.contains("- A"))
        #expect(result.contains("- B"))
        #expect(result.contains("- C"))
    }

    @Test("No changes returns exact local string")
    func noChangesReturnsExactLocal() {
        let text = "- A\n- B"
        let result = PromptParser.mergeFlatField(base: text, local: text, remote: text)
        // When no changes, should return local as-is (exact identity)
        #expect(result == text)
    }

    @Test("Empty base with local and remote content")
    func emptyBaseWithContent() {
        let base = ""
        let local = "- A"
        let remote = "- B"
        let result = PromptParser.mergeFlatField(base: base, local: local, remote: remote)
        #expect(result.contains("- A"))
        #expect(result.contains("- B"))
    }
}

// MARK: - PromptHistoryEntry Edge Cases

@Suite("PromptHistoryEntry edge cases")
struct PromptHistoryEntryEdgeCaseTests {

    @Test("Invalid timestamp returns distantPast")
    func invalidTimestamp() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "not-a-date",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.date == .distantPast)
    }

    @Test("Unknown source returns raw source string")
    func unknownSource() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "unknown_source", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.sourceLabel == "unknown_source")
    }

    @Test("Empty templatesJSON returns empty array")
    func emptyTemplatesJSON() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: ""
        )
        #expect(entry.decodedTemplates.isEmpty)
    }

    @Test("Multiple templates decoded correctly")
    func multipleTemplates() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templates = [
            ReplyTemplate(id: "t1", name: "First"),
            ReplyTemplate(id: "t2", name: "Second"),
            ReplyTemplate(id: "t3", name: "Third"),
        ]
        let json = String(data: try! encoder.encode(templates), encoding: .utf8)!
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: ["templates"],
            composition: "", action: "", kb: "", templatesJSON: json
        )
        #expect(entry.decodedTemplates.count == 3)
        #expect(entry.decodedTemplates[0].name == "First")
        #expect(entry.decodedTemplates[2].name == "Third")
    }

    @Test("Hashable conformance works")
    func hashable() {
        let entry1 = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: ["composition"],
            composition: "comp", action: "act", kb: "kb", templatesJSON: "[]"
        )
        let entry2 = PromptHistoryEntry(
            id: "2", timestamp: "2024-03-15T11:00:00Z",
            source: "reset", fields: ["action"],
            composition: "comp", action: "act", kb: "kb", templatesJSON: "[]"
        )
        var set: Set<PromptHistoryEntry> = [entry1, entry2]
        #expect(set.count == 2)
        set.insert(entry1)
        #expect(set.count == 2)
    }

    @Test("Identifiable id matches")
    func identifiable() {
        let entry = PromptHistoryEntry(
            id: "unique-id-123", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.id == "unique-id-123")
    }

    @Test("Fields array preserved")
    func fieldsPreserved() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "sync_receive", fields: ["composition", "action", "kb"],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.fields.count == 3)
        #expect(entry.fields.contains("composition"))
        #expect(entry.fields.contains("action"))
        #expect(entry.fields.contains("kb"))
    }
}

// MARK: - ReplyTemplate Edge Cases

@Suite("ReplyTemplate edge cases")
struct ReplyTemplateEdgeCaseTests {

    @Test("Hashable conformance for set operations")
    func hashable() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let t1 = ReplyTemplate(id: "t1", name: "A", createdAt: fixedDate, updatedAt: fixedDate)
        let t2 = ReplyTemplate(id: "t2", name: "B", createdAt: fixedDate, updatedAt: fixedDate)
        let t3 = ReplyTemplate(id: "t1", name: "A", createdAt: fixedDate, updatedAt: fixedDate)
        var set: Set<ReplyTemplate> = [t1, t2, t3]
        #expect(set.count == 2)
        set.insert(t1)
        #expect(set.count == 2)
    }

    @Test("Sendable conformance allows cross-isolation")
    func sendable() async {
        let template = ReplyTemplate(id: "t1", name: "Test")
        let result: ReplyTemplate = await Task.detached {
            return template
        }.value
        #expect(result.id == "t1")
    }

    @Test("Decoder with all fields present")
    func decoderAllFields() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = ReplyTemplate(
            id: "full", name: "Complete",
            enabled: false, instructions: ["A", "B"],
            exampleReply: "Hello",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            deleted: true,
            deletedAt: Date(timeIntervalSince1970: 3000)
        )
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplyTemplate.self, from: data)
        #expect(decoded.id == "full")
        #expect(decoded.name == "Complete")
        #expect(decoded.enabled == false)
        #expect(decoded.instructions == ["A", "B"])
        #expect(decoded.exampleReply == "Hello")
        #expect(decoded.deleted == true)
        #expect(decoded.deletedAt != nil)
    }

    @Test("Equatable via Hashable")
    func equatable() {
        let t1 = ReplyTemplate(
            id: "t1", name: "A", enabled: true,
            instructions: ["X"], exampleReply: "Y",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let t2 = ReplyTemplate(
            id: "t1", name: "A", enabled: true,
            instructions: ["X"], exampleReply: "Y",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(t1 == t2)
    }

    @Test("Templates with different IDs are not equal")
    func differentIds() {
        let t1 = ReplyTemplate(id: "t1", name: "Same")
        let t2 = ReplyTemplate(id: "t2", name: "Same")
        #expect(t1 != t2)
    }

    @Test("Decoder defaults enabled to true when null or missing")
    func decoderDefaultEnabled() throws {
        let nullJSON = #"{"id": "null", "name": "Null", "enabled": null}"#
        let missingJSON = #"{"id": "missing", "name": "Missing"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nullTemplate = try decoder.decode(ReplyTemplate.self, from: Data(nullJSON.utf8))
        let missingTemplate = try decoder.decode(ReplyTemplate.self, from: Data(missingJSON.utf8))
        #expect(nullTemplate.enabled == true)
        #expect(missingTemplate.enabled == true)
    }

    @Test("Decoder defaults deleted to false when missing")
    func decoderDefaultDeleted() throws {
        let json = #"{"id": "x", "name": "Y"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template = try decoder.decode(ReplyTemplate.self, from: Data(json.utf8))
        #expect(template.deleted == false)
        #expect(template.deletedAt == nil)
    }

    @Test("Decoder defaults instructions to empty when missing")
    func decoderDefaultInstructions() throws {
        let json = #"{"id": "x", "name": "Y"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template = try decoder.decode(ReplyTemplate.self, from: Data(json.utf8))
        #expect(template.instructions.isEmpty)
        #expect(template.exampleReply.isEmpty)
    }

    @Test("Empty instructions and example reply")
    func emptyInstructionsAndReply() {
        let template = ReplyTemplate(
            id: "t1", name: "Empty",
            instructions: [], exampleReply: ""
        )
        #expect(template.instructions.isEmpty)
        #expect(template.exampleReply.isEmpty)
    }

    @Test("Large instructions array")
    func largeInstructions() throws {
        let instructions = (0..<100).map { "Instruction \($0)" }
        let template = ReplyTemplate(
            id: "t1", name: "Many",
            instructions: instructions
        )
        #expect(template.instructions.count == 100)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(template)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplyTemplate.self, from: data)
        #expect(decoded.instructions.count == 100)
    }
}

// MARK: - PromptParser Section Headers Constants

@Suite("PromptParser section header constants")
struct PromptParserSectionHeaderConstantsTests {

    @Test("Composition section headers has 3 entries")
    func compositionHeaders() {
        #expect(PromptParser.compositionSectionHeaders.count == 3)
        #expect(PromptParser.compositionSectionHeaders.contains("General writing style"))
        #expect(PromptParser.compositionSectionHeaders.contains("Language"))
        #expect(PromptParser.compositionSectionHeaders.contains("Useful links to personal website and other resources"))
    }

    @Test("Action section headers has 4 entries")
    func actionHeaders() {
        #expect(PromptParser.actionSectionHeaders.count == 4)
        #expect(PromptParser.actionSectionHeaders.contains("Emails to be marked as `delete`"))
        #expect(PromptParser.actionSectionHeaders.contains("Emails to be marked as `archive`"))
        #expect(PromptParser.actionSectionHeaders.contains("Emails to be marked as `reply`"))
        #expect(PromptParser.actionSectionHeaders.contains("Emails to be marked as `none`"))
    }
}

// MARK: - PromptParser round-trip tests

@Suite("PromptParser round-trip (extract then replace)")
struct PromptParserRoundTripTests {

    @Test("Extract then replace preserves structure")
    func extractThenReplace() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Be concise
        - Use active voice

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English

        ====END USER INSTRUCTIONS====
        """
        let extracted = PromptParser.extractSection(from: markdown, header: "Style")
        let replaced = PromptParser.replaceSection(in: markdown, header: "Style", with: extracted)
        // After extracting and putting back, language section should be preserved
        let langContent = PromptParser.extractSection(from: replaced, header: "Language")
        #expect(langContent == "- English")
    }

    @Test("Replace then extract yields the new content")
    func replaceThenExtract() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Old content

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English

        ====END USER INSTRUCTIONS====
        """
        let newContent = "- New content\n- Another line"
        let replaced = PromptParser.replaceSection(in: markdown, header: "Style", with: newContent)
        let extracted = PromptParser.extractSection(from: replaced, header: "Style")
        #expect(extracted == newContent)
    }

    @Test("Replace does not affect other sections")
    func replaceDoesNotAffectOthers() {
        let markdown = """
        # Delete (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Spam

        # Archive (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Newsletters

        # Reply (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Urgent

        ====END USER INSTRUCTIONS====
        """
        let replaced = PromptParser.replaceSection(in: markdown, header: "Archive", with: "- Important docs")
        #expect(PromptParser.extractSection(from: replaced, header: "Delete") == "- Spam")
        #expect(PromptParser.extractSection(from: replaced, header: "Archive") == "- Important docs")
        #expect(PromptParser.extractSection(from: replaced, header: "Reply") == "- Urgent")
    }
}

// MARK: - PromptHistoryEntry Codable

@Suite("PromptHistoryEntry Codable")
struct PromptHistoryEntryCodableTests {

    @Test("Round-trip encode/decode preserves all fields")
    func roundTrip() throws {
        let entry = PromptHistoryEntry(
            id: "hist-1",
            timestamp: "2024-06-01T12:00:00Z",
            source: "local_edit",
            fields: ["composition", "kb"],
            composition: "# Comp\n- Rule 1",
            action: "# Action\n- Delete spam",
            kb: "- KB fact",
            templatesJSON: "[]"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PromptHistoryEntry.self, from: data)
        #expect(decoded.id == "hist-1")
        #expect(decoded.timestamp == "2024-06-01T12:00:00Z")
        #expect(decoded.source == "local_edit")
        #expect(decoded.fields == ["composition", "kb"])
        #expect(decoded.composition == "# Comp\n- Rule 1")
        #expect(decoded.action == "# Action\n- Delete spam")
        #expect(decoded.kb == "- KB fact")
        #expect(decoded.templatesJSON == "[]")
    }

    @Test("Array of entries round-trips")
    func arrayRoundTrip() throws {
        let entries = [
            PromptHistoryEntry(
                id: "1", timestamp: "2024-01-01T00:00:00Z",
                source: "reset", fields: ["composition"],
                composition: "A", action: "B", kb: "C", templatesJSON: "[]"
            ),
            PromptHistoryEntry(
                id: "2", timestamp: "2024-02-01T00:00:00Z",
                source: "sync_receive", fields: ["action", "templates"],
                composition: "D", action: "E", kb: "F", templatesJSON: "[{\"id\":\"t1\",\"name\":\"T\"}]"
            ),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([PromptHistoryEntry].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].id == "1")
        #expect(decoded[1].source == "sync_receive")
    }
}

// MARK: - mergeSectionedField with real-world default markdown

@Suite("PromptParser with real default markdown format")
struct PromptParserRealWorldTests {

    // Mimics the actual default composition markdown format
    private let defaultComposition = """
        # User provided composition instructions
        - Below are the user-defined instructions for composing emails.
        - Strictly follow these instructions in future responses.

        ====BEGIN USER INSTRUCTIONS====


        # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - ALWAYS sign off as the user using the **First Name Only**.
        - I want to sound friendly and professional, but not too formal.
        - ALWAYS start with a greeting.
        - I generally use Cheers or Best, depending on the context.

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - I write in English Only.

        # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)


        ====END USER INSTRUCTIONS====

        Now, acknowledge these user instructions and do not deviate from them.
        """

    @Test("Extract writing style from default composition")
    func extractWritingStyleFromDefault() {
        let result = PromptParser.extractSection(from: defaultComposition, header: "General writing style")
        #expect(result.contains("ALWAYS sign off"))
        #expect(result.contains("friendly and professional"))
        #expect(result.contains("ALWAYS start with a greeting"))
        #expect(result.contains("Cheers or Best"))
    }

    @Test("Extract language from default composition")
    func extractLanguageFromDefault() {
        let result = PromptParser.extractSection(from: defaultComposition, header: "Language")
        #expect(result.contains("English Only"))
    }

    @Test("Extract useful links from default composition (empty)")
    func extractLinksFromDefault() {
        let result = PromptParser.extractSection(from: defaultComposition, header: "Useful links to personal website and other resources")
        #expect(result.isEmpty)
    }

    @Test("Replace writing style in default composition preserves other sections")
    func replaceWritingStyleInDefault() {
        let replaced = PromptParser.replaceSection(
            in: defaultComposition,
            header: "General writing style",
            with: "- Be extremely formal\n- Never use contractions"
        )
        let lang = PromptParser.extractSection(from: replaced, header: "Language")
        #expect(lang.contains("English Only"))
        let style = PromptParser.extractSection(from: replaced, header: "General writing style")
        #expect(style.contains("Be extremely formal"))
        #expect(!style.contains("friendly and professional"))
    }

    @Test("mergeSectionedField with default composition as base")
    func mergeWithDefaultAsBase() {
        let remote = PromptParser.replaceSection(
            in: defaultComposition,
            header: "Language",
            with: "- I write in English and Spanish."
        )
        let result = PromptParser.mergeSectionedField(
            base: defaultComposition,
            local: defaultComposition,
            remote: remote,
            sectionHeaders: PromptParser.compositionSectionHeaders
        )
        let lang = PromptParser.extractSection(from: result, header: "Language")
        #expect(lang.contains("English and Spanish"))
    }
}
