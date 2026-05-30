/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ChangeSettingTool Argument Validation")
struct ChangeSettingToolTests {

    @Test("Tool name is change_setting")
    func toolName() {
        let tool = ChangeSettingTool()
        #expect(tool.name == "change_setting")
    }

    // MARK: - Missing / invalid 'setting' key

    @Test("Missing setting key returns error")
    func missingSetting() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: ["value": .bool(true)])
        #expect(result.contains("missing"))
    }

    @Test("Non-string setting key returns error")
    func nonStringSetting() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: ["setting": .int(42), "value": .bool(true)])
        #expect(result.contains("missing"))
    }

    @Test("Unknown setting key returns error")
    func unknownSetting() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: ["setting": .string("nonexistent.key"), "value": .bool(true)])
        #expect(result.contains("Unknown setting"))
    }

    // MARK: - Boolean settings: type validation

    @Test("Boolean setting coerces string 'true' to boolean")
    func boolSettingStringTrue() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("privacy.web_search_enabled"),
            "value": .string("true"),
        ])
        #expect(result.contains("ok"))
    }

    @Test("Boolean setting coerces string 'false' to boolean")
    func boolSettingStringFalse() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("privacy.web_search_enabled"),
            "value": .string("false"),
        ])
        #expect(result.contains("ok"))
    }

    @Test("Boolean setting with non-boolean string returns error")
    func boolSettingInvalidString() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("privacy.web_search_enabled"),
            "value": .string("yes"),
        ])
        #expect(result.contains("boolean"))
    }

    @Test("Boolean setting with int value returns error")
    func boolSettingIntValue() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("privacy.web_search_enabled"),
            "value": .int(1),
        ])
        #expect(result.contains("boolean"))
    }

    @Test("Boolean setting with double value returns error")
    func boolSettingDoubleValue() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.proactive_enabled"),
            "value": .double(1.0),
        ])
        #expect(result.contains("boolean"))
    }

    // MARK: - Number settings: type validation

    @Test("Number setting with boolean value returns error")
    func numberSettingBoolValue() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .bool(true),
        ])
        #expect(result.contains("integer"))
    }

    @Test("Number setting with non-numeric string returns error")
    func numberSettingNonNumericString() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .string("abc"),
        ])
        #expect(result.contains("integer"))
    }

    // MARK: - Number settings: range validation

    @Test("Window days below minimum returns error")
    func windowDaysBelowMin() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .int(0),
        ])
        #expect(result.contains("between"))
    }

    @Test("Window days above maximum returns error")
    func windowDaysAboveMax() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .int(999),
        ])
        #expect(result.contains("between"))
    }

    @Test("Advance minutes below minimum returns error")
    func advanceMinutesBelowMin() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.due_reminder_advance_minutes"),
            "value": .int(1),
        ])
        #expect(result.contains("between"))
    }

    @Test("Advance minutes above maximum returns error")
    func advanceMinutesAboveMax() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.due_reminder_advance_minutes"),
            "value": .int(999),
        ])
        #expect(result.contains("between"))
    }

    // MARK: - Number settings: alternative input types accepted

    @Test("Number setting accepts double value (truncated to int)")
    func numberSettingDoubleAccepted() async throws {
        let tool = ChangeSettingTool()
        // 15.9 should be accepted and truncated to 15 (within 1-30 range)
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .double(15.9),
        ])
        // Should succeed (persists to UserDefaults in test context)
        #expect(result.contains("ok"))
    }

    @Test("Number setting accepts string-encoded integer")
    func numberSettingStringIntAccepted() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .string("10"),
        ])
        #expect(result.contains("ok"))
    }

    // MARK: - All settings exist and are callable

    @Test("privacy.web_search_enabled is a valid setting")
    func webSearchIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("privacy.web_search_enabled"),
            "value": .bool(true),
        ])
        #expect(result.contains("ok"))
        #expect(!result.contains("Unknown"))
    }

    @Test("notifications.proactive_enabled is a valid setting")
    func proactiveIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.proactive_enabled"),
            "value": .bool(false),
        ])
        #expect(result.contains("ok"))
    }

    @Test("notifications.new_reminder_window_days is a valid setting")
    func windowDaysIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .int(7),
        ])
        #expect(result.contains("ok"))
    }

    @Test("notifications.due_reminder_advance_minutes is a valid setting")
    func advanceMinutesIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.due_reminder_advance_minutes"),
            "value": .int(30),
        ])
        #expect(result.contains("ok"))
    }

    @Test("task.enabled is a valid setting")
    func taskEnabledIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("task.enabled"),
            "value": .bool(true),
        ])
        #expect(result.contains("ok"))
    }

    @Test("task.advance_minutes is a valid setting")
    func taskAdvanceMinutesIsValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("task.advance_minutes"),
            "value": .int(5),
        ])
        #expect(result.contains("ok"))
    }

    @Test("task.advance_minutes out of range returns error")
    func taskAdvanceMinutesOutOfRange() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("task.advance_minutes"),
            "value": .int(999),
        ])
        #expect(result.contains("between"))
    }

    @Test("grace_minutes is NOT a valid iOS setting")
    func graceMinutesNotValid() async throws {
        let tool = ChangeSettingTool()
        let result = try await tool.execute(arguments: [
            "setting": .string("notifications.grace_minutes"),
            "value": .int(5),
        ])
        #expect(result.contains("Unknown setting"))
    }
}
