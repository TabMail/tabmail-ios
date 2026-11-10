/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - CalendarEventDeleteTool

@Suite("CalendarEventDeleteTool Argument Validation")
struct CalendarEventDeleteToolTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        return ToolContext(db: db, translator: translator)
    }

    @Test("Tool name is calendar_event_delete")
    func toolName() throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        #expect(tool.name == "calendar_event_delete")
    }

    @Test("Missing event_id returns error")
    func missingEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty string event_id returns error")
    func emptyEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }

    @Test("Whitespace-only event_id returns error")
    func whitespaceEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("   ")])
        #expect(result.contains("missing event_id"))
    }

    @Test("Non-string event_id returns error")
    func nonStringEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .int(42)])
        #expect(result.contains("missing event_id"))
    }

    @Test("Boolean event_id returns error")
    func booleanEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .bool(true)])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - CalendarEventEditTool

@Suite("CalendarEventEditTool Argument Validation")
struct CalendarEventEditToolTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        return ToolContext(db: db, translator: translator)
    }

    @Test("Tool name is calendar_event_edit")
    func toolName() throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        #expect(tool.name == "calendar_event_edit")
    }

    @Test("Missing event_id returns error")
    func missingEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty string event_id returns error")
    func emptyEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }

    @Test("Whitespace-only event_id returns error")
    func whitespaceEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("   ")])
        #expect(result.contains("missing event_id"))
    }

    @Test("Non-string event_id returns error")
    func nonStringEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .int(42)])
        #expect(result.contains("missing event_id"))
    }

    @Test("An unrecognized timezone is refused before the card, naming the zone")
    func unrecognizedTimeZoneIsRefused() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [
            "event_id": .string("evt-1"), "start_iso": .string("2099-07-15T10:00:00"), "timezone": .string("Not/AZone"),
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], "\(result)")
        let error = try #require(json["error"] as? String, "\(result)")
        #expect(json["ok"] as? Bool == false)
        #expect(error.contains("This event uses the time zone \"Not/AZone\", which TabMail does not recognize"), "\(error)")
        #expect(error.contains("The event was NOT changed"), "\(error)")
    }

    @Test("Boolean event_id returns error")
    func booleanEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .bool(true)])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - CalendarEventCreateTool

@Suite("CalendarEventCreateTool time zone")
struct CalendarEventCreateToolTimeZoneTests {

    @Test("An unrecognized timezone is refused before the card, naming the zone")
    func unrecognizedTimeZoneIsRefused() async throws {
        let tool = CalendarEventCreateTool(context: ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator()))
        let result = try await tool.execute(arguments: [
            "title": .string("Planning"), "start_iso": .string("2099-07-15T10:00:00"),
            "end_iso": .string("2099-07-15T11:00:00"), "timezone": .string("Not/AZone"),
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], "\(result)")
        let error = try #require(json["error"] as? String, "\(result)")
        #expect(json["ok"] as? Bool == false)
        #expect(error.contains("This event uses the time zone \"Not/AZone\", which TabMail does not recognize"), "\(error)")
        #expect(error.contains("The event was NOT created"), "\(error)")
    }
}
