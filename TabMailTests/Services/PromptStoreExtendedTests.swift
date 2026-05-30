/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - PromptParser Static Method Extended Tests

@Suite("PromptParser extractSection extended")
struct PromptParserExtractSectionExtendedTests {

    @Test("extractSection returns empty for markdown with no matching header at all")
    func noHeaderAtAll() {
        let markdown = "Just some text\nWith no headers"
        let result = PromptParser.extractSection(from: markdown, header: "Nonexistent")
        #expect(result.isEmpty)
    }

    @Test("extractSection does not match header without DO NOT EDIT marker")
    func headerWithoutMarker() {
        let markdown = """
        # Language
        - English

        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Casual
        """
        // "Language" without the marker should not match
        let result = PromptParser.extractSection(from: markdown, header: "Language")
        #expect(result.isEmpty)
    }

    @Test("extractSection handles section with only whitespace lines")
    func sectionWithOnlyWhitespace() {
        let markdown = """
        # Links (DO NOT EDIT/DELETE THIS SECTION HEADER)


        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Content
        """
        let result = PromptParser.extractSection(from: markdown, header: "Links")
        #expect(result.isEmpty)
    }

    @Test("extractSection handles section at end of document without end marker")
    func sectionAtEndNoMarker() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Be clear
        - Be direct
        """
        let result = PromptParser.extractSection(from: markdown, header: "Style")
        #expect(result == "- Be clear\n- Be direct")
    }

    @Test("extractSection handles header with extra text before the marker")
    func headerWithExtraText() {
        let markdown = """
        # Writing style guidelines (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Professional tone
        """
        let result = PromptParser.extractSection(from: markdown, header: "Writing style guidelines")
        #expect(result == "- Professional tone")
    }

    @Test("extractSection handles content with mixed bullet and non-bullet lines")
    func mixedContent() {
        let markdown = """
        # Rules (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - First rule
        Some explanation
        - Second rule
        Another explanation

        ====END USER INSTRUCTIONS====
        """
        let result = PromptParser.extractSection(from: markdown, header: "Rules")
        #expect(result.contains("- First rule"))
        #expect(result.contains("Some explanation"))
        #expect(result.contains("- Second rule"))
    }
}

// MARK: - PromptParser replaceSection Extended

@Suite("PromptParser replaceSection extended")
struct PromptParserReplaceSectionExtendedTests {

    @Test("replaceSection with empty new content")
    func replaceWithEmptyContent() {
        let markdown = """
        # Style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Old content

        # Next (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Keep me
        """
        let result = PromptParser.replaceSection(in: markdown, header: "Style", with: "")
        #expect(PromptParser.extractSection(from: result, header: "Style").isEmpty)
        #expect(PromptParser.extractSection(from: result, header: "Next") == "- Keep me")
    }

    @Test("replaceSection preserves end-of-document structure")
    func replaceSectionPreservesEnd() {
        let markdown = "# Links (DO NOT EDIT/DELETE THIS SECTION HEADER)\n\n====END USER INSTRUCTIONS====\n\nNow, acknowledge these instructions."
        let result = PromptParser.replaceSection(in: markdown, header: "Links", with: "- https://test.com")
        #expect(result.contains("- https://test.com"))
        #expect(result.contains("====END USER INSTRUCTIONS===="))
        #expect(result.contains("Now, acknowledge these instructions."))
    }

    @Test("replaceSection handles multiple consecutive sections")
    func replaceMultipleConsecutive() {
        let markdown = "# Writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Style content\n# Useful links (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Links content\n# Language preferences (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Lang content\n====END USER INSTRUCTIONS===="
        let result = PromptParser.replaceSection(in: markdown, header: "Useful links", with: "- New links")
        #expect(PromptParser.extractSection(from: result, header: "Writing style") == "- Style content")
        #expect(PromptParser.extractSection(from: result, header: "Useful links") == "- New links")
        #expect(PromptParser.extractSection(from: result, header: "Language preferences") == "- Lang content")
    }
}

// MARK: - PromptParser mergeBullets Extended

@Suite("PromptParser mergeBullets extended")
struct PromptParserMergeBulletsExtendedTests {

    @Test("Local adds and remote removes different items")
    func localAddRemoteRemove() {
        let base = ["A", "B", "C"]
        let local = ["A", "B", "C", "D"] // local added D
        let remote = ["A", "C"]           // remote removed B
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result.contains("A"))
        #expect(!result.contains("B"))  // remote removed
        #expect(result.contains("C"))
        #expect(result.contains("D"))   // local added
    }

    @Test("Local removes and remote adds different items")
    func localRemoveRemoteAdd() {
        let base = ["A", "B"]
        let local = ["A"]           // local removed B
        let remote = ["A", "B", "C"] // remote added C
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(result.contains("A"))
        // B was not removed by remote, but local removed it — local ordering preserved
        #expect(!result.contains("B"))
        #expect(result.contains("C"))
    }

    @Test("Duplicates in base are handled")
    func duplicatesInBase() {
        let base = ["A", "A", "B"]
        let local = ["A", "A", "B"]
        let remote = ["A", "B"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        // Set-based, so duplicates collapse
        #expect(result.contains("A"))
        #expect(result.contains("B"))
    }

    @Test("All three lists identical returns local unchanged")
    func allIdentical() {
        let items = ["X", "Y", "Z"]
        let result = PromptParser.mergeBullets(base: items, local: items, remote: items)
        #expect(result == items)
    }

    @Test("Remote completely replaces all items")
    func remoteReplacesAll() {
        let base = ["A", "B", "C"]
        let local = ["A", "B", "C"]
        let remote = ["X", "Y"]
        let result = PromptParser.mergeBullets(base: base, local: local, remote: remote)
        #expect(!result.contains("A"))
        #expect(!result.contains("B"))
        #expect(!result.contains("C"))
        #expect(result.contains("X"))
        #expect(result.contains("Y"))
    }
}

// MARK: - PromptParser mergeFlatField Extended

@Suite("PromptParser mergeFlatField extended")
struct PromptParserMergeFlatFieldExtendedTests {

    @Test("All empty strings")
    func allEmpty() {
        let result = PromptParser.mergeFlatField(base: "", local: "", remote: "")
        #expect(result.isEmpty)
    }

    @Test("Base and local empty, remote has content")
    func onlyRemoteHasContent() {
        let result = PromptParser.mergeFlatField(base: "", local: "", remote: "- New item")
        #expect(result.contains("- New item"))
    }

    @Test("Non-bullet text in field is preserved when unchanged")
    func nonBulletText() {
        let text = "Just plain text without bullets"
        let result = PromptParser.mergeFlatField(base: text, local: text, remote: text)
        #expect(result == text) // no changes, returns local as-is
    }

    @Test("Mixed bullet and non-bullet: only bullets are merged")
    func mixedBulletNonBullet() {
        let base = "Header text\n- Bullet one"
        let local = "Header text\n- Bullet one"
        let remote = "Header text\n- Bullet one\n- Bullet two"
        let result = PromptParser.mergeFlatField(base: base, local: local, remote: remote)
        #expect(result.contains("Bullet one"))
        #expect(result.contains("Bullet two"))
    }
}

// MARK: - ReplyTemplate Codable Extended

@Suite("ReplyTemplate Codable extended")
struct ReplyTemplateCodableExtendedTests {

    @Test("Round-trip encode/decode preserves all fields")
    func fullRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let original = ReplyTemplate(
            id: "rt-1",
            name: "Test Template",
            enabled: true,
            instructions: ["Do this", "Do that"],
            exampleReply: "Hello, [Name]!",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            deleted: false,
            deletedAt: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ReplyTemplate.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.enabled == original.enabled)
        #expect(decoded.instructions == original.instructions)
        #expect(decoded.exampleReply == original.exampleReply)
        #expect(decoded.deleted == original.deleted)
        #expect(decoded.deletedAt == nil)
    }

    @Test("Decode with deleted=true and deletedAt preserves both")
    func decodeDeleted() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let deletedAt = Date(timeIntervalSince1970: 5000)
        let original = ReplyTemplate(
            id: "del-1", name: "Deleted",
            deleted: true, deletedAt: deletedAt
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ReplyTemplate.self, from: data)
        #expect(decoded.deleted == true)
        #expect(decoded.deletedAt != nil)
    }

    @Test("Array of templates round-trips correctly")
    func arrayRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let templates = [
            ReplyTemplate(id: "1", name: "First", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
            ReplyTemplate(id: "2", name: "Second", enabled: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
            ReplyTemplate(id: "3", name: "Third", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), deleted: true),
        ]
        let data = try encoder.encode(templates)
        let decoded = try decoder.decode([ReplyTemplate].self, from: data)
        #expect(decoded.count == 3)
        #expect(decoded[1].enabled == false)
        #expect(decoded[2].deleted == true)
    }

    @Test("Decoder handles missing optional fields with defaults")
    func decoderMissingOptionals() throws {
        let json = """
        {"id": "minimal", "name": "Minimal Template"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template = try decoder.decode(ReplyTemplate.self, from: Data(json.utf8))
        #expect(template.id == "minimal")
        #expect(template.name == "Minimal Template")
        #expect(template.enabled == true)
        #expect(template.instructions.isEmpty)
        #expect(template.exampleReply.isEmpty)
        #expect(template.deleted == false)
        #expect(template.deletedAt == nil)
    }
}

// MARK: - PromptHistoryEntry Extended

@Suite("PromptHistoryEntry extended")
struct PromptHistoryEntryExtendedTests {

    @Test("sourceLabel returns Edit for local_edit")
    func sourceLabelEdit() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.sourceLabel == "Edit")
    }

    @Test("sourceLabel returns Reset for reset")
    func sourceLabelReset() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "reset", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.sourceLabel == "Reset")
    }

    @Test("sourceLabel returns Sync for sync_receive")
    func sourceLabelSync() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "sync_receive", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.sourceLabel == "Sync")
    }

    @Test("date parses valid ISO8601 timestamp")
    func dateParseValid() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-06-15T12:30:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.date != .distantPast)
    }

    @Test("decodedTemplates handles malformed JSON gracefully")
    func decodedTemplatesMalformedJSON() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "",
            templatesJSON: "{ not valid json }"
        )
        #expect(entry.decodedTemplates.isEmpty)
    }

    @Test("decodedTemplates handles valid single template JSON")
    func decodedTemplatesSingleTemplate() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let template = ReplyTemplate(id: "t1", name: "Solo",
                                     createdAt: Date(timeIntervalSince1970: 0),
                                     updatedAt: Date(timeIntervalSince1970: 0))
        let json = String(data: try! encoder.encode([template]), encoding: .utf8)!

        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "local_edit", fields: ["templates"],
            composition: "", action: "", kb: "",
            templatesJSON: json
        )
        #expect(entry.decodedTemplates.count == 1)
        #expect(entry.decodedTemplates[0].name == "Solo")
    }

    @Test("Codable round-trip with special characters in fields")
    func codableSpecialChars() throws {
        let entry = PromptHistoryEntry(
            id: "special-chars",
            timestamp: "2024-01-01T00:00:00Z",
            source: "local_edit",
            fields: ["composition"],
            composition: "# Title\n- Bullet with \"quotes\" and 'apostrophes'",
            action: "Delete emails from <script>alert(1)</script>",
            kb: "User's name: O'Brien",
            templatesJSON: "[]"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PromptHistoryEntry.self, from: data)
        #expect(decoded.composition.contains("\"quotes\""))
        #expect(decoded.action.contains("<script>"))
        #expect(decoded.kb.contains("O'Brien"))
    }

    @Test("empty fields array round-trips")
    func emptyFieldsRoundTrip() throws {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-01-01T00:00:00Z",
            source: "reset", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PromptHistoryEntry.self, from: data)
        #expect(decoded.fields.isEmpty)
    }
}

// MARK: - PromptParser.extractBullets Extended

@Suite("PromptParser extractBullets extended")
struct PromptParserExtractBulletsExtendedTests {

    @Test("Empty string returns empty array")
    func emptyString() {
        let bullets = PromptParser.extractBullets(from: "")
        #expect(bullets.isEmpty)
    }

    @Test("Bullets with leading and trailing whitespace are trimmed before matching")
    func bulletsWithWhitespace() {
        let text = "   - Trimmed bullet   "
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["Trimmed bullet"])
    }

    @Test("Bullet with dash but no space is not extracted")
    func dashNoSpace() {
        let text = "-NoSpace"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets.isEmpty)
    }

    @Test("Multiple consecutive blank lines between bullets")
    func blankLinesBetweenBullets() {
        let text = "- First\n\n\n\n- Second"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets == ["First", "Second"])
    }

    @Test("Bullets with markdown formatting preserved")
    func markdownFormatting() {
        let text = "- **Bold** text\n- *Italic* text\n- `Code` text"
        let bullets = PromptParser.extractBullets(from: text)
        #expect(bullets.count == 3)
        #expect(bullets[0] == "**Bold** text")
        #expect(bullets[1] == "*Italic* text")
        #expect(bullets[2] == "`Code` text")
    }
}

// MARK: - PromptParser compositionSectionHeaders / actionSectionHeaders integration

@Suite("PromptParser section headers integration")
struct PromptParserSectionHeadersIntegrationTests {

    @Test("All composition headers are extractable from default composition markdown")
    func compositionHeadersExtractable() {
        // Build a markdown with all composition headers
        let markdown = """
        # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Rule 1

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English

        # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - https://example.com

        ====END USER INSTRUCTIONS====
        """
        for header in PromptParser.compositionSectionHeaders {
            let result = PromptParser.extractSection(from: markdown, header: header)
            #expect(!result.isEmpty, "Header '\(header)' should be extractable")
        }
    }

    @Test("All action headers are extractable from default action markdown")
    func actionHeadersExtractable() {
        let markdown = """
        # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Spam

        # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Newsletters

        # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Urgent

        # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - Unknown

        ====END USER INSTRUCTIONS====
        """
        for header in PromptParser.actionSectionHeaders {
            let result = PromptParser.extractSection(from: markdown, header: header)
            #expect(!result.isEmpty, "Header '\(header)' should be extractable")
        }
    }

    @Test("Replacing all sections in sequence preserves document structure")
    func replaceAllSections() {
        let markdown = "# Writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Style1\n\n# Useful links (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Links1\n\n# Language preferences (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Lang1\n\n====END USER INSTRUCTIONS===="
        var result = markdown
        result = PromptParser.replaceSection(in: result, header: "Writing style", with: "- Style2")
        result = PromptParser.replaceSection(in: result, header: "Useful links", with: "- Links2")
        result = PromptParser.replaceSection(in: result, header: "Language preferences", with: "- Lang2")

        #expect(PromptParser.extractSection(from: result, header: "Writing style") == "- Style2")
        #expect(PromptParser.extractSection(from: result, header: "Useful links") == "- Links2")
        #expect(PromptParser.extractSection(from: result, header: "Language preferences") == "- Lang2")
        #expect(result.contains("====END USER INSTRUCTIONS===="))
    }
}

// MARK: - ReplyTemplate Edge Cases Extended

@Suite("ReplyTemplate defaults extended")
struct ReplyTemplateDefaultsExtendedTests {

    @Test("Default init creates valid template")
    func defaultInit() {
        let template = ReplyTemplate()
        #expect(!template.id.isEmpty)
        #expect(template.name == "New Template")
        #expect(template.enabled == true)
        #expect(template.instructions.isEmpty)
        #expect(template.exampleReply.isEmpty)
        #expect(template.deleted == false)
        #expect(template.deletedAt == nil)
    }

    @Test("Two default inits have different IDs")
    func uniqueIds() {
        let t1 = ReplyTemplate()
        let t2 = ReplyTemplate()
        #expect(t1.id != t2.id)
    }

    @Test("Template with empty name is valid")
    func emptyName() {
        let t = ReplyTemplate(name: "")
        #expect(t.name.isEmpty)
    }

    @Test("Template equality checks all fields")
    func equalityAllFields() {
        let date = Date(timeIntervalSince1970: 1000)
        let t1 = ReplyTemplate(id: "same", name: "A", enabled: true, instructions: ["x"],
                                exampleReply: "y", createdAt: date, updatedAt: date)
        var t2 = t1
        t2.name = "B"  // Mutate via var copy
        #expect(t1 != t2) // Different name
    }
}

// MARK: - PromptParser mergeSectionedField Extended

@Suite("PromptParser mergeSectionedField extended")
struct PromptParserMergeSectionedFieldExtendedTests {

    @Test("Merge with unknown section headers does nothing")
    func mergeUnknownHeaders() {
        let markdown = "# Known (DO NOT EDIT/DELETE THIS SECTION HEADER)\n- Content\n====END USER INSTRUCTIONS===="
        let result = PromptParser.mergeSectionedField(
            base: markdown, local: markdown, remote: markdown,
            sectionHeaders: ["Unknown"]
        )
        #expect(result == markdown)
    }

    @Test("Merge with empty sectionHeaders array returns local unchanged")
    func mergeEmptyHeaders() {
        let markdown = "Some content"
        let result = PromptParser.mergeSectionedField(
            base: markdown, local: markdown, remote: "Different",
            sectionHeaders: []
        )
        #expect(result == markdown)
    }
}
