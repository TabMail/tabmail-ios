/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - PromptStateData encoding edge cases

@Suite("PromptStateData Encoding Edge Cases")
struct PromptStateDataEncodingTests {

    @Test("Encodes per-field timestamps with snake_case keys")
    func snakeCaseTimestampKeys() throws {
        let state = PromptStateData(
            compositionUpdatedAt: "2024-01-01T00:00:00Z",
            actionUpdatedAt: "2024-02-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("composition_updated_at"))
        #expect(json.contains("action_updated_at"))
        // Should NOT contain camelCase keys
        #expect(!json.contains("compositionUpdatedAt"))
    }

    @Test("Encodes kb_updated_at and templates_updated_at correctly")
    func kbAndTemplatesTimestampKeys() throws {
        let state = PromptStateData(
            kbUpdatedAt: "2024-03-01T00:00:00Z",
            templatesUpdatedAt: "2024-04-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("kb_updated_at"))
        #expect(json.contains("templates_updated_at"))
    }

    @Test("Encodes disabledReminders_updated_at correctly")
    func disabledRemindersTimestampKey() throws {
        let state = PromptStateData(
            disabledRemindersUpdatedAt: "2024-05-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("disabledReminders_updated_at"))
    }

    @Test("updatedAt key is preserved as-is (not snake_cased)")
    func updatedAtKey() throws {
        let state = PromptStateData(updatedAt: "2024-06-01T00:00:00Z")
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"updatedAt\""))
    }

    @Test("Empty composition string is preserved (not nil)")
    func emptyCompositionPreserved() throws {
        let state = PromptStateData(composition: "")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: data)
        #expect(decoded.composition == "")
    }
}

// MARK: - PromptStateData disabledReminders CRDT decoding

@Suite("PromptStateData DisabledReminders CRDT")
struct PromptStateDataDisabledRemindersCRDTTests {

    @Test("Decodes v2 CRDT map format with enabled=true entries")
    func v2MapWithEnabledEntries() throws {
        let json = """
        {
            "disabledReminders": {
                "hash1": {"enabled": false, "ts": "2024-01-01T00:00:00Z"},
                "hash2": {"enabled": true, "ts": "2024-02-01T00:00:00Z"}
            }
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?.count == 2)
        #expect(decoded.disabledReminders?["hash1"]?.enabled == false)
        #expect(decoded.disabledReminders?["hash2"]?.enabled == true)
        #expect(decoded.disabledReminders?["hash2"]?.ts == "2024-02-01T00:00:00Z")
    }

    @Test("Decodes empty v2 CRDT map")
    func emptyV2Map() throws {
        let json = #"{"disabledReminders": {}}"#
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?.isEmpty == true)
    }

    @Test("Legacy array with multiple hashes all get same timestamp")
    func legacyArrayMultipleHashes() throws {
        let json = """
        {
            "disabledReminders": ["a", "b", "c"],
            "disabledReminders_updated_at": "2024-06-15T12:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?.count == 3)
        for hash in ["a", "b", "c"] {
            #expect(decoded.disabledReminders?[hash]?.enabled == false)
            #expect(decoded.disabledReminders?[hash]?.ts == "2024-06-15T12:00:00Z")
        }
    }

    @Test("Legacy empty array produces empty map (not nil)")
    func legacyEmptyArray() throws {
        let json = #"{"disabledReminders": []}"#
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders?.isEmpty == true)
    }

    @Test("Null disabledReminders decodes as nil")
    func nullDisabledReminders() throws {
        let json = #"{"disabledReminders": null}"#
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: Data(json.utf8))
        #expect(decoded.disabledReminders == nil)
    }
}

// MARK: - PromptStateData with templates

@Suite("PromptStateData Templates Codable")
struct PromptStateDataTemplatesTests {

    @Test("Round-trip with multiple templates preserves all fields")
    func multipleTemplatesRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let t1 = ReplyTemplate(
            id: "t1", name: "Greeting", enabled: true,
            instructions: ["Be friendly", "Keep it short"],
            exampleReply: "Hello!",
            createdAt: fixedDate, updatedAt: fixedDate,
            deleted: false, deletedAt: nil
        )
        let t2 = ReplyTemplate(
            id: "t2", name: "Decline", enabled: false,
            instructions: ["Be polite"],
            exampleReply: "I'm sorry, I can't help with that.",
            createdAt: fixedDate, updatedAt: fixedDate,
            deleted: true, deletedAt: fixedDate
        )
        let state = PromptStateData(templates: [t1, t2])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PromptStateData.self, from: data)

        #expect(decoded.templates?.count == 2)
        #expect(decoded.templates?[0].name == "Greeting")
        #expect(decoded.templates?[0].instructions.count == 2)
        #expect(decoded.templates?[1].deleted == true)
        #expect(decoded.templates?[1].enabled == false)
    }

    @Test("Empty templates array round-trips correctly")
    func emptyTemplatesArray() throws {
        let state = PromptStateData(templates: [])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: data)
        #expect(decoded.templates?.isEmpty == true)
    }
}

// MARK: - PromptStateData full state round-trip

@Suite("PromptStateData Full State")
struct PromptStateDataFullStateTests {

    @Test("Full state with all fields round-trips through encode/decode")
    func fullStateRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 2000)
        let template = ReplyTemplate(
            id: "t1", name: "Test", enabled: true,
            instructions: ["Do things"],
            exampleReply: "OK",
            createdAt: fixedDate, updatedAt: fixedDate,
            deleted: false, deletedAt: nil
        )
        let entry = DisabledRemindersStore.DisabledEntry(enabled: false, ts: "2024-01-01T00:00:00Z")

        let original = PromptStateData(
            composition: "# Composition\n- Rule 1\n- Rule 2",
            action: "# Actions\n- Archive newsletters",
            kb: "I work at Acme Corp.\nMy boss is Jane.",
            templates: [template],
            disabledReminders: ["reminder_hash_1": entry],
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

        #expect(decoded.composition == original.composition)
        #expect(decoded.action == original.action)
        #expect(decoded.kb == original.kb)
        #expect(decoded.templates?.count == 1)
        #expect(decoded.disabledReminders?.count == 1)
        #expect(decoded.compositionUpdatedAt == "2024-01-01T01:00:00Z")
        #expect(decoded.actionUpdatedAt == "2024-01-01T02:00:00Z")
        #expect(decoded.kbUpdatedAt == "2024-01-01T03:00:00Z")
        #expect(decoded.templatesUpdatedAt == "2024-01-01T04:00:00Z")
        #expect(decoded.disabledRemindersUpdatedAt == "2024-01-01T05:00:00Z")
    }

    @Test("Multiline composition with newlines preserved")
    func multilineComposition() throws {
        let state = PromptStateData(composition: "Line 1\nLine 2\nLine 3\n\n# Section\n- Item")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PromptStateData.self, from: data)
        #expect(decoded.composition == "Line 1\nLine 2\nLine 3\n\n# Section\n- Item")
    }
}

// MARK: - AICacheSummary edge cases

@Suite("AICacheSummary Edge Cases")
struct AICacheSummaryEdgeCaseTests {

    @Test("Reminder fields all populated round-trip correctly")
    func reminderFieldsRoundTrip() throws {
        let summary = AICacheSummary(
            blurb: "Follow up needed",
            reminderDate: "2026-12-25",
            reminderTime: "09:00",
            reminderContent: "Check on holiday schedule"
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.reminderDate == "2026-12-25")
        #expect(decoded.reminderTime == "09:00")
        #expect(decoded.reminderContent == "Check on holiday schedule")
    }

    @Test("Todos with multiline content preserved")
    func multilineTodos() throws {
        let summary = AICacheSummary(blurb: "Test", todos: "- Task 1\n- Task 2\n- Task 3")
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.todos == "- Task 1\n- Task 2\n- Task 3")
    }

    @Test("Detailed field with long content preserved")
    func longDetailedContent() throws {
        let longContent = String(repeating: "This is a detailed analysis. ", count: 100)
        let summary = AICacheSummary(blurb: "Short", detailed: longContent)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.detailed == longContent)
    }
}

// MARK: - AICacheResult edge cases

@Suite("AICacheResult Edge Cases")
struct AICacheResultEdgeCaseTests {

    @Test("Reply-only result (no summary, no action)")
    func replyOnlyResult() throws {
        let result = AICacheResult(summary: nil, action: nil, reply: "Thank you for your message.")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.reply == "Thank you for your message.")
        #expect(decoded.summary == nil)
        #expect(decoded.action == nil)
    }

    @Test("Summary with all reminder fields but no action/reply")
    func summaryOnlyWithReminders() throws {
        let summary = AICacheSummary(
            blurb: "Action needed",
            reminderDate: "2026-03-20",
            reminderTime: "14:00",
            reminderContent: "Send report"
        )
        let result = AICacheResult(summary: summary, action: nil, reply: nil)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.summary?.reminderDate == "2026-03-20")
        #expect(decoded.action == nil)
        #expect(decoded.reply == nil)
    }

    @Test("Empty string action is preserved (not nil)")
    func emptyStringAction() throws {
        let result = AICacheResult(summary: nil, action: "", reply: nil)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.action == "")
    }

    @Test("Reply with HTML content preserved")
    func htmlReplyContent() throws {
        let htmlReply = "<p>Hello <strong>World</strong></p>"
        let result = AICacheResult(summary: nil, action: nil, reply: htmlReply)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.reply == htmlReply)
    }
}

// MARK: - AI cache probe result filtering

@Suite("AI Cache Probe Result Filtering")
struct AICacheProbeFilteringTests {

    /// Simulates the probe handler's filtering logic: given a header with some AI data
    /// and a field filter, build AICacheResult and check the guard.
    /// This mirrors the logic in RootView.swift's aiCacheProbeHandler.
    private func buildFilteredResult(
        summaryBlurb: String?,
        actionTag: String?,
        cachedReply: String?,
        wantSummary: Bool,
        wantAction: Bool,
        wantReply: Bool
    ) -> AICacheResult? {
        let hasSummary = wantSummary && summaryBlurb != nil
        let hasAction = wantAction && actionTag != nil
        let hasReply = wantReply && cachedReply != nil && !cachedReply!.isEmpty

        var result = AICacheResult()
        if hasSummary {
            result.summary = AICacheSummary(blurb: summaryBlurb ?? "")
        }
        if hasAction {
            result.action = actionTag
        }
        if hasReply {
            result.reply = cachedReply
        }

        // Guard: only include if at least one requested field is populated
        if result.summary != nil || result.action != nil || result.reply != nil {
            return result
        }
        return nil
    }

    @Test("Header with summary but action requested returns nil (the fix)")
    func headerWithSummaryButActionRequested() {
        // Header has summary but probe asks for action (which is nil)
        // Before the fix, this returned an empty AICacheResult. Now returns nil.
        let result = buildFilteredResult(
            summaryBlurb: "Some summary",
            actionTag: nil,
            cachedReply: nil,
            wantSummary: false,
            wantAction: true,
            wantReply: false
        )
        #expect(result == nil)
    }

    @Test("Header with summary and action, action requested returns action")
    func headerWithBothActionRequested() {
        let result = buildFilteredResult(
            summaryBlurb: "Some summary",
            actionTag: "archive",
            cachedReply: nil,
            wantSummary: false,
            wantAction: true,
            wantReply: false
        )
        #expect(result != nil)
        #expect(result?.action == "archive")
        #expect(result?.summary == nil) // Not requested
    }

    @Test("Header with all fields, all requested returns all")
    func allFieldsAllRequested() {
        let result = buildFilteredResult(
            summaryBlurb: "Summary",
            actionTag: "reply",
            cachedReply: "Hello",
            wantSummary: true,
            wantAction: true,
            wantReply: true
        )
        #expect(result != nil)
        #expect(result?.summary?.blurb == "Summary")
        #expect(result?.action == "reply")
        #expect(result?.reply == "Hello")
    }

    @Test("Header with reply only, summary requested returns nil")
    func replyOnlySummaryRequested() {
        let result = buildFilteredResult(
            summaryBlurb: nil,
            actionTag: nil,
            cachedReply: "Some reply",
            wantSummary: true,
            wantAction: false,
            wantReply: false
        )
        #expect(result == nil)
    }

    @Test("Header with empty reply, reply requested returns nil")
    func emptyReplyRequestedReturnsNil() {
        let result = buildFilteredResult(
            summaryBlurb: nil,
            actionTag: nil,
            cachedReply: "",
            wantSummary: false,
            wantAction: false,
            wantReply: true
        )
        #expect(result == nil)
    }

    @Test("No fields requested returns nil regardless of data")
    func noFieldsRequestedReturnsNil() {
        let result = buildFilteredResult(
            summaryBlurb: "Has data",
            actionTag: "delete",
            cachedReply: "Reply",
            wantSummary: false,
            wantAction: false,
            wantReply: false
        )
        #expect(result == nil)
    }
}

// MARK: - SyncField timestamp key mapping

@Suite("SyncField Timestamp Key Mapping")
struct SyncFieldTimestampKeyTests {

    @Test("Each SyncField has a unique rawValue")
    func uniqueRawValues() {
        let rawValues = SyncField.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("promptFields is a strict subset of allCases")
    func promptFieldsSubset() {
        let allSet = Set(SyncField.allCases)
        for field in SyncField.promptFields {
            #expect(allSet.contains(field))
        }
    }

    @Test("promptFields count is allCases minus 2")
    func promptFieldsCountRelation() {
        #expect(SyncField.promptFields.count == SyncField.allCases.count - 2)
    }

    @Test("disabledReminders and taskCache are the non-prompt fields")
    func nonPromptFields() {
        let nonPrompt = Set(SyncField.allCases).subtracting(SyncField.promptFields)
        #expect(nonPrompt.count == 2)
        #expect(nonPrompt.contains(.disabledReminders))
        #expect(nonPrompt.contains(.taskCache))
    }
}
