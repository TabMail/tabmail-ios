/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - SyncField

@Suite("SyncField Enum")
struct SyncFieldTests {

    @Test("CaseIterable returns all 6 cases")
    func allCases() {
        #expect(SyncField.allCases.count == 6)
    }

    @Test("All expected cases exist")
    func expectedCases() {
        let cases = Set(SyncField.allCases)
        #expect(cases.contains(.composition))
        #expect(cases.contains(.action))
        #expect(cases.contains(.kb))
        #expect(cases.contains(.templates))
        #expect(cases.contains(.disabledReminders))
        #expect(cases.contains(.taskCache))
    }

    @Test("rawValue matches expected strings")
    func rawValues() {
        #expect(SyncField.composition.rawValue == "composition")
        #expect(SyncField.action.rawValue == "action")
        #expect(SyncField.kb.rawValue == "kb")
        #expect(SyncField.templates.rawValue == "templates")
        #expect(SyncField.disabledReminders.rawValue == "disabledReminders")
        #expect(SyncField.taskCache.rawValue == "taskCache")
    }

    @Test("init(rawValue:) round-trips all cases")
    func rawValueRoundTrip() {
        for field in SyncField.allCases {
            let reconstructed = SyncField(rawValue: field.rawValue)
            #expect(reconstructed == field)
        }
    }

    @Test("init(rawValue:) returns nil for unknown value")
    func unknownRawValue() {
        #expect(SyncField(rawValue: "nonexistent") == nil)
    }

    @Test("promptFields excludes disabledReminders and taskCache")
    func promptFields() {
        let promptFields = SyncField.promptFields
        #expect(promptFields.count == 4)
        #expect(promptFields.contains(.composition))
        #expect(promptFields.contains(.action))
        #expect(promptFields.contains(.kb))
        #expect(promptFields.contains(.templates))
        #expect(!promptFields.contains(.disabledReminders))
        #expect(!promptFields.contains(.taskCache))
    }

    @Test("displayName returns non-empty strings for all cases")
    func displayNames() {
        for field in SyncField.allCases {
            #expect(!field.displayName.isEmpty)
        }
    }

    @Test("icon returns non-empty strings for all cases")
    func icons() {
        for field in SyncField.allCases {
            #expect(!field.icon.isEmpty)
        }
    }
}

// MARK: - PromptStateData

@Suite("PromptStateData Codable")
struct PromptStateDataTests {

    @Test("Round-trip with all fields populated")
    func fullRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let template = ReplyTemplate(
            id: "t1", name: "Greeting", enabled: true,
            instructions: ["Be friendly"],
            exampleReply: "Hello!",
            createdAt: fixedDate, updatedAt: fixedDate,
            deleted: false, deletedAt: nil
        )
        let entry = DisabledRemindersStore.DisabledEntry(enabled: false, ts: "2024-01-01T00:00:00Z")

        let original = PromptStateData(
            composition: "Compose rules",
            action: "Action rules",
            kb: "Knowledge base",
            templates: [template],
            disabledReminders: ["hash1": entry],
            updatedAt: "2024-01-01T00:00:00Z",
            compositionUpdatedAt: "2024-01-01T01:00:00Z",
            actionUpdatedAt: "2024-01-01T02:00:00Z",
            kbUpdatedAt: "2024-01-01T03:00:00Z",
            templatesUpdatedAt: "2024-01-01T04:00:00Z",
            disabledRemindersUpdatedAt: "2024-01-01T05:00:00Z"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PromptStateData.self, from: data)

        #expect(decoded.composition == "Compose rules")
        #expect(decoded.action == "Action rules")
        #expect(decoded.kb == "Knowledge base")
        #expect(decoded.templates?.count == 1)
        #expect(decoded.templates?.first?.name == "Greeting")
        #expect(decoded.disabledReminders?["hash1"]?.enabled == false)
        #expect(decoded.disabledReminders?["hash1"]?.ts == "2024-01-01T00:00:00Z")
        #expect(decoded.updatedAt == "2024-01-01T00:00:00Z")
        #expect(decoded.compositionUpdatedAt == "2024-01-01T01:00:00Z")
        #expect(decoded.actionUpdatedAt == "2024-01-01T02:00:00Z")
        #expect(decoded.kbUpdatedAt == "2024-01-01T03:00:00Z")
        #expect(decoded.templatesUpdatedAt == "2024-01-01T04:00:00Z")
        #expect(decoded.disabledRemindersUpdatedAt == "2024-01-01T05:00:00Z")
    }

    @Test("Round-trip with all fields nil")
    func emptyRoundTrip() throws {
        let original = PromptStateData()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: data)

        #expect(decoded.composition == nil)
        #expect(decoded.action == nil)
        #expect(decoded.kb == nil)
        #expect(decoded.templates == nil)
        #expect(decoded.disabledReminders == nil)
        #expect(decoded.updatedAt == nil)
        #expect(decoded.compositionUpdatedAt == nil)
        #expect(decoded.actionUpdatedAt == nil)
        #expect(decoded.kbUpdatedAt == nil)
        #expect(decoded.templatesUpdatedAt == nil)
        #expect(decoded.disabledRemindersUpdatedAt == nil)
    }

    @Test("Decodes with missing optional fields from JSON")
    func decodesMissingFields() throws {
        let json = """
        {"composition": "test"}
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.composition == "test")
        #expect(decoded.action == nil)
        #expect(decoded.kb == nil)
        #expect(decoded.templates == nil)
        #expect(decoded.disabledReminders == nil)
    }

    @Test("CodingKeys map snake_case timestamp fields")
    func codingKeysMapping() throws {
        let json = """
        {
            "composition": "rules",
            "composition_updated_at": "2024-01-01T00:00:00Z",
            "action_updated_at": "2024-02-01T00:00:00Z",
            "kb_updated_at": "2024-03-01T00:00:00Z",
            "templates_updated_at": "2024-04-01T00:00:00Z",
            "disabledReminders_updated_at": "2024-05-01T00:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.compositionUpdatedAt == "2024-01-01T00:00:00Z")
        #expect(decoded.actionUpdatedAt == "2024-02-01T00:00:00Z")
        #expect(decoded.kbUpdatedAt == "2024-03-01T00:00:00Z")
        #expect(decoded.templatesUpdatedAt == "2024-04-01T00:00:00Z")
        #expect(decoded.disabledRemindersUpdatedAt == "2024-05-01T00:00:00Z")
    }

    @Test("Legacy disabledReminders array is converted to CRDT map")
    func legacyArrayConversion() throws {
        let json = """
        {
            "disabledReminders": ["hash_a", "hash_b"],
            "disabledReminders_updated_at": "2024-06-01T00:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?.count == 2)
        #expect(decoded.disabledReminders?["hash_a"]?.enabled == false)
        #expect(decoded.disabledReminders?["hash_a"]?.ts == "2024-06-01T00:00:00Z")
        #expect(decoded.disabledReminders?["hash_b"]?.enabled == false)
        #expect(decoded.disabledReminders?["hash_b"]?.ts == "2024-06-01T00:00:00Z")
    }

    @Test("Legacy disabledReminders array uses updatedAt fallback when field timestamp missing")
    func legacyArrayFallbackTimestamp() throws {
        let json = """
        {
            "disabledReminders": ["hash_x"],
            "updatedAt": "2024-07-01T00:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?["hash_x"]?.ts == "2024-07-01T00:00:00Z")
    }

    @Test("Legacy disabledReminders array uses epoch zero when no timestamps available")
    func legacyArrayEpochZeroFallback() throws {
        let json = """
        {
            "disabledReminders": ["hash_y"]
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?["hash_y"]?.ts == "1970-01-01T00:00:00.000Z")
    }
}

// MARK: - AICacheSummary

@Suite("AICacheSummary Codable")
struct AICacheSummaryTests {

    @Test("Round-trip with all fields")
    func fullRoundTrip() throws {
        let original = AICacheSummary(
            blurb: "Quick summary",
            todos: "- Task 1\n- Task 2",
            detailed: "Detailed analysis here",
            reminderDate: "2024-03-15",
            reminderTime: "10:00",
            reminderContent: "Follow up on budget"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)

        #expect(decoded.blurb == "Quick summary")
        #expect(decoded.todos == "- Task 1\n- Task 2")
        #expect(decoded.detailed == "Detailed analysis here")
        #expect(decoded.reminderDate == "2024-03-15")
        #expect(decoded.reminderTime == "10:00")
        #expect(decoded.reminderContent == "Follow up on budget")
    }

    @Test("Round-trip with only required blurb field")
    func minimalRoundTrip() throws {
        let original = AICacheSummary(blurb: "Short blurb")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)

        #expect(decoded.blurb == "Short blurb")
        #expect(decoded.todos == nil)
        #expect(decoded.detailed == nil)
        #expect(decoded.reminderDate == nil)
        #expect(decoded.reminderTime == nil)
        #expect(decoded.reminderContent == nil)
    }

    @Test("Decodes from JSON with missing optional fields")
    func decodesPartialJSON() throws {
        let json = """
        {"blurb": "A summary", "todos": "Do stuff"}
        """
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: Data(json.utf8))
        #expect(decoded.blurb == "A summary")
        #expect(decoded.todos == "Do stuff")
        #expect(decoded.detailed == nil)
        #expect(decoded.reminderDate == nil)
    }
}

// MARK: - AICacheResult

@Suite("AICacheResult Codable")
struct AICacheResultTests {

    @Test("Round-trip with all fields")
    func fullRoundTrip() throws {
        let summary = AICacheSummary(
            blurb: "Summary blurb",
            todos: "Todos",
            detailed: nil,
            reminderDate: "2024-01-15",
            reminderTime: "14:30",
            reminderContent: "Call back"
        )
        let original = AICacheResult(
            summary: summary,
            action: "reply",
            reply: "Thanks for reaching out!"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)

        #expect(decoded.summary?.blurb == "Summary blurb")
        #expect(decoded.summary?.todos == "Todos")
        #expect(decoded.summary?.reminderDate == "2024-01-15")
        #expect(decoded.summary?.reminderContent == "Call back")
        #expect(decoded.action == "reply")
        #expect(decoded.reply == "Thanks for reaching out!")
    }

    @Test("Round-trip with all fields nil")
    func emptyRoundTrip() throws {
        let original = AICacheResult(summary: nil, action: nil, reply: nil)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)

        #expect(decoded.summary == nil)
        #expect(decoded.action == nil)
        #expect(decoded.reply == nil)
    }

    @Test("Decodes from JSON with only action field")
    func partialJSON() throws {
        let json = """
        {"action": "archive"}
        """
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: Data(json.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.action == "archive")
        #expect(decoded.reply == nil)
    }

    @Test("Decodes from empty JSON object")
    func emptyJSON() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: Data(json.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.action == nil)
        #expect(decoded.reply == nil)
    }

    @Test("Nested summary decodes correctly from JSON")
    func nestedSummaryFromJSON() throws {
        let json = """
        {
            "summary": {
                "blurb": "Test blurb",
                "reminderDate": "2024-12-25",
                "reminderTime": "09:00",
                "reminderContent": "Christmas follow-up"
            },
            "action": "none"
        }
        """
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: Data(json.utf8))
        #expect(decoded.summary?.blurb == "Test blurb")
        #expect(decoded.summary?.reminderDate == "2024-12-25")
        #expect(decoded.summary?.reminderTime == "09:00")
        #expect(decoded.summary?.reminderContent == "Christmas follow-up")
        #expect(decoded.action == "none")
        #expect(decoded.reply == nil)
    }
}
