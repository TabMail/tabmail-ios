/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ReplyTemplate")
struct ReplyTemplateTests {

    @Test("Default init creates valid template")
    func defaultInit() {
        let template = ReplyTemplate()
        #expect(template.name == "New Template")
        #expect(template.enabled == true)
        #expect(template.instructions.isEmpty)
        #expect(template.exampleReply.isEmpty)
        #expect(template.deleted == false)
        #expect(template.deletedAt == nil)
        #expect(!template.id.isEmpty)
    }

    @Test("Custom init sets all fields")
    func customInit() {
        let now = Date()
        let template = ReplyTemplate(
            id: "t1", name: "Professional",
            enabled: true, instructions: ["Be formal", "Use signature"],
            exampleReply: "Dear X,\n\nThank you...",
            createdAt: now, updatedAt: now,
            deleted: false, deletedAt: nil
        )
        #expect(template.name == "Professional")
        #expect(template.instructions.count == 2)
        #expect(template.exampleReply.contains("Dear"))
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let now = Date()
        let template = ReplyTemplate(
            id: "t1", name: "Casual",
            enabled: false, instructions: ["Be friendly"],
            exampleReply: "Hey!",
            createdAt: now, updatedAt: now,
            deleted: true, deletedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(template)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplyTemplate.self, from: data)

        #expect(decoded.id == "t1")
        #expect(decoded.name == "Casual")
        #expect(decoded.enabled == false)
        #expect(decoded.deleted == true)
        #expect(decoded.deletedAt != nil)
    }

    @Test("Decoder handles missing optional fields")
    func decoderMissingOptionals() throws {
        let json = """
        {"id": "t2", "name": "Minimal"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template = try decoder.decode(ReplyTemplate.self, from: Data(json.utf8))
        #expect(template.id == "t2")
        #expect(template.name == "Minimal")
        #expect(template.enabled == true) // default
        #expect(template.instructions.isEmpty) // default
        #expect(template.deleted == false) // default
    }

    @Test("Soft-delete tombstone pattern")
    func softDeleteTombstone() {
        var template = ReplyTemplate(id: "t1", name: "ToDelete")
        template.deleted = true
        template.deletedAt = Date()
        #expect(template.deleted == true)
        #expect(template.deletedAt != nil)
    }
}

@Suite("PromptHistoryEntry")
struct PromptHistoryEntryTests {

    @Test("sourceLabel maps correctly")
    func sourceLabels() {
        let edit = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: ["composition"],
            composition: "comp", action: "act", kb: "kb", templatesJSON: "[]"
        )
        #expect(edit.sourceLabel == "Edit")

        let reset = PromptHistoryEntry(
            id: "2", timestamp: "2024-03-15T10:00:00Z",
            source: "reset", fields: ["composition"],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(reset.sourceLabel == "Reset")

        let sync = PromptHistoryEntry(
            id: "3", timestamp: "2024-03-15T10:00:00Z",
            source: "sync_receive", fields: ["kb"],
            composition: "", action: "", kb: "new kb", templatesJSON: "[]"
        )
        #expect(sync.sourceLabel == "Sync")
    }

    @Test("date parses ISO8601 timestamp")
    func dateParses() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "[]"
        )
        #expect(entry.date != .distantPast)
    }

    @Test("decodedTemplates parses JSON")
    func decodedTemplates() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templates = [ReplyTemplate(id: "t1", name: "Test")]
        let json = String(data: try! encoder.encode(templates), encoding: .utf8)!

        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: ["templates"],
            composition: "", action: "", kb: "", templatesJSON: json
        )
        #expect(entry.decodedTemplates.count == 1)
        #expect(entry.decodedTemplates.first?.name == "Test")
    }

    @Test("decodedTemplates with invalid JSON returns empty")
    func decodedTemplatesInvalid() {
        let entry = PromptHistoryEntry(
            id: "1", timestamp: "2024-03-15T10:00:00Z",
            source: "local_edit", fields: [],
            composition: "", action: "", kb: "", templatesJSON: "not json"
        )
        #expect(entry.decodedTemplates.isEmpty)
    }
}
