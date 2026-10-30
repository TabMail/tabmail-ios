/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

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

    @Test("Decoder defaults enabled to true when missing")
    func decoderDefaultEnabled() throws {
        // enabled is Bool?, decodeIfPresent returns nil for null → defaults to true
        // Actually this will throw because Bool can't decode null — test with missing key
        let json2 = #"{"id": "x", "name": "Y"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template = try decoder.decode(ReplyTemplate.self, from: Data(json2.utf8))
        #expect(template.enabled == true)
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
