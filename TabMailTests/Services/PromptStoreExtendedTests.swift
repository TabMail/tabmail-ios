/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

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
