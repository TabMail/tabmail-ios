/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ReminderAddTool

@Suite("ReminderAddTool Argument Validation")
struct ReminderAddToolTests {

    @Test("Tool name is reminder_add")
    func toolName() {
        let tool = ReminderAddTool()
        #expect(tool.name == "reminder_add")
    }

    @Test("Missing text returns error")
    func missingText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (int) returns error")
    func intText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .int(42)])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (bool) returns error")
    func boolText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .bool(true)])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (array) returns error")
    func arrayText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .array([.string("a")])])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (dictionary) returns error")
    func dictText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .dictionary(["k": .string("v")])])
        #expect(result.contains("missing text"))
    }

    @Test("Empty string text returns error")
    func emptyText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .string("")])
        #expect(result.contains("missing text"))
    }

    @Test("Whitespace-only text returns error after normalization")
    func whitespaceText() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: ["text": .string("   ")])
        #expect(result.contains("missing text"))
    }

    // MARK: - due_date validation

    @Test("Invalid due_date format returns error")
    func invalidDueDateFormat() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string("2025-03-15"),
        ])
        #expect(result.contains("invalid due_date format"))
        #expect(result.contains("YYYY/MM/DD"))
    }

    @Test("due_date with extra characters returns error")
    func dueDateExtraChars() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string("2025/03/15 extra"),
        ])
        #expect(result.contains("invalid due_date format"))
    }

    @Test("due_date with wrong separator returns error")
    func dueDateWrongSeparator() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string("2025.03.15"),
        ])
        #expect(result.contains("invalid due_date format"))
    }

    @Test("due_date with incomplete format returns error")
    func dueDateIncomplete() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string("2025/03"),
        ])
        #expect(result.contains("invalid due_date format"))
    }

    // MARK: - due_time validation

    @Test("Invalid due_time format returns error")
    func invalidDueTimeFormat() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string("9:30"),
        ])
        #expect(result.contains("invalid due_time format"))
        #expect(result.contains("HH:MM"))
    }

    @Test("due_time with seconds returns error")
    func dueTimeWithSeconds() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string("09:30:00"),
        ])
        #expect(result.contains("invalid due_time format"))
    }

    @Test("due_time with AM/PM returns error")
    func dueTimeWithAMPM() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string("09:30 AM"),
        ])
        #expect(result.contains("invalid due_time format"))
    }

    @Test("due_time with wrong separator returns error")
    func dueTimeWrongSeparator() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string("09.30"),
        ])
        #expect(result.contains("invalid due_time format"))
    }

    // MARK: - Optional params are truly optional

    @Test("Empty due_date is treated as absent (no error)")
    func emptyDueDateNoError() async throws {
        let tool = ReminderAddTool()
        // With valid text and empty due_date, should NOT return due_date error
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string(""),
        ])
        #expect(!result.contains("invalid due_date format"))
    }

    @Test("Whitespace-only due_date is treated as absent (no error)")
    func whitespaceDueDateNoError() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_date": .string("   "),
        ])
        #expect(!result.contains("invalid due_date format"))
    }

    @Test("Empty due_time is treated as absent (no error)")
    func emptyDueTimeNoError() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string(""),
        ])
        #expect(!result.contains("invalid due_time format"))
    }

    @Test("Whitespace-only due_time is treated as absent (no error)")
    func whitespaceDueTimeNoError() async throws {
        let tool = ReminderAddTool()
        let result = try await tool.execute(arguments: [
            "text": .string("Buy groceries"),
            "due_time": .string("   "),
        ])
        #expect(!result.contains("invalid due_time format"))
    }
}

// MARK: - ReminderDelTool

@Suite("ReminderDelTool Argument Validation")
struct ReminderDelToolTests {

    @Test("Tool name is reminder_del")
    func toolName() {
        let tool = ReminderDelTool()
        #expect(tool.name == "reminder_del")
    }

    @Test("Missing text returns error")
    func missingText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (int) returns error")
    func intText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .int(42)])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (bool) returns error")
    func boolText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .bool(false)])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (array) returns error")
    func arrayText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .array([])])
        #expect(result.contains("missing text"))
    }

    @Test("Non-string text (dictionary) returns error")
    func dictText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .dictionary([:])])
        #expect(result.contains("missing text"))
    }

    @Test("Empty string text returns error")
    func emptyText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .string("")])
        #expect(result.contains("missing text"))
    }

    @Test("Whitespace-only text returns error after normalization")
    func whitespaceText() async throws {
        let tool = ReminderDelTool()
        let result = try await tool.execute(arguments: ["text": .string("   ")])
        #expect(result.contains("missing text"))
    }
}
