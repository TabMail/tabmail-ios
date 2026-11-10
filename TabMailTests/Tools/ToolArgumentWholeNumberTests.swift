/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Whole-number tool arguments
//
// Integer tool arguments arrive as JSON numbers. A number `Int` cannot hold decodes as
// `.double` (`JSONValue.init(from:)` tries `Int` first), and so does any fraction. Every tool
// reads an integer argument through `JSONValue.wholeNumber`, and refuses a value that is not a
// whole number rather than truncating or rounding it.

@Suite("Tool argument validation: whole numbers")
struct ToolArgumentWholeNumberTests {

    /// Values no integer argument may accept: outside `Int` either way, and a fraction.
    static let unusableNumbers: [Double] = [1e300, -1e300, 2.5]

    private func makeContext() throws -> ToolContext {
        ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator())
    }

    // MARK: - The accessor

    @Test("an integer is returned as is", arguments: [0, 1, -7, Int.max, Int.min])
    func integerIsReturned(n: Int) {
        #expect(JSONValue.int(n).wholeNumber == n)
    }

    @Test("a double holding a whole number is returned as that number",
          arguments: [(14.0, 14), (0.0, 0), (-3.0, -3), (4_503_599_627_370_496.0, 4_503_599_627_370_496)])
    func wholeDoubleIsReturned(pair: (Double, Int)) {
        #expect(JSONValue.double(pair.0).wholeNumber == pair.1)
    }

    @Test("a double that is not a whole number Int can hold is not a whole number",
          arguments: [3.5, -0.25, 1e300, -1e300, 1e19, -1e19, Double(Int.max), Double.infinity, -Double.infinity, Double.nan])
    func otherDoubleIsRejected(d: Double) {
        #expect(JSONValue.double(d).wholeNumber == nil)
    }

    @Test("a value that is not a number is not a whole number",
          arguments: [JSONValue.string("5"), .bool(true), .null, .array([.int(1)]), .dictionary(["n": .int(1)])])
    func nonNumberIsRejected(value: JSONValue) {
        #expect(value.wholeNumber == nil)
    }

    // MARK: - Every tool that reads an integer argument

    @Test("message tools refuse a unique_id that is not a whole number", arguments: unusableNumbers)
    func messageToolsRefuseUniqueId(d: Double) async throws {
        let ctx = try makeContext()
        let args: [String: JSONValue] = ["unique_id": .double(d)]
        #expect(try await EmailReadTool(context: ctx).execute(arguments: args).contains("invalid or missing unique_id"))
        #expect(try await EmailOpenTool(context: ctx).execute(arguments: args).contains("invalid or missing unique_id"))
        #expect(try await EmailReplyTool(context: ctx).execute(arguments: args).contains("missing or invalid unique_id"))
        #expect(try await EmailForwardTool(context: ctx).execute(arguments: args).contains("missing or invalid unique_id"))
        #expect(try await AttachmentReadPdfTool(context: ctx).execute(arguments: args).contains("invalid or missing unique_id"))
    }

    @Test("delete keeps only the ids that are whole numbers", arguments: unusableNumbers)
    func deleteKeepsWholeIds(d: Double) {
        #expect(EmailDeleteTool.parseUniqueIds(["unique_ids": .array([.int(4), .double(d), .double(9.0), .string("6")])]) == [4, 9, 6])
        #expect(EmailDeleteTool.parseUniqueIds(["unique_id": .double(d)]).isEmpty)
        #expect(EmailDeleteTool.parseUniqueIds(["unique_id": .double(9.0)]) == [9])
    }

    @Test("a number setting refuses a value that is not a whole number", arguments: unusableNumbers)
    func settingRefusesValue(d: Double) async throws {
        let result = try await ChangeSettingTool().execute(arguments: [
            "setting": .string("notifications.new_reminder_window_days"),
            "value": .double(d),
        ])
        #expect(result.contains("requires an integer value"))
    }

    @Test("a template id that is not a whole number is no id", arguments: unusableNumbers)
    func templateIdRejected(d: Double) {
        #expect(TemplateToolHelpers.intArg(["template_id": .double(d)], "template_id") == nil)
        #expect(TemplateToolHelpers.intArg(["template_id": .double(12.0)], "template_id") == 12)
        #expect(TemplateToolHelpers.intArg(["template_id": .string("12")], "template_id") == 12)
    }

    @Test("contact search refuses a limit that is not a whole number", arguments: unusableNumbers)
    func contactSearchRefusesLimit(d: Double) async throws {
        let result = try await ContactSearchTool().execute(arguments: ["query": .string("Alex"), "limit": .double(d)])
        #expect(result.contains("limit must be a whole number"))
    }

    @Test("calendar search refuses a page_index that is not a whole number", arguments: unusableNumbers)
    func calendarSearchRefusesPageIndex(d: Double) async throws {
        let result = try await CalendarSearchTool().execute(arguments: ["query": .string("standup"), "page_index": .double(d)])
        #expect(result.contains("page_index must be a whole number"))
    }

    @Test("calendar search answers the largest page_index with the beyond-the-last-page reply")
    func calendarSearchLargestPage() {
        let reply = CalendarSearchTool().paginateAndFormat(events: [], calendarNames: [:], pageIndex: Int.max)
        #expect(reply.contains("beyond the last page"))
    }

    // MARK: - Recurrence interval and count

    private func recurrence(_ key: String, _ value: JSONValue) -> [String: JSONValue] {
        ["recurrence": .dictionary(["freq": .string("weekly"), key: value])]
    }

    /// Present but not a whole number of 1 or more.
    static let unusableRecurrenceNumbers: [JSONValue] = [
        .double(1e300), .double(-1e300), .double(2.5), .int(0), .int(-2), .string("5"), .bool(true),
    ]

    @Test("the event builder refuses an interval that is not a whole number of 1 or more", arguments: unusableRecurrenceNumbers)
    func builderRefusesInterval(value: JSONValue) {
        #expect(throws: CalendarProviderError.self) {
            try CalendarToolHelpers.buildGCalEventInput(recurrence("interval", value), isAllDay: false)
        }
    }

    @Test("the event builder refuses a count that is not a whole number of 1 or more", arguments: unusableRecurrenceNumbers)
    func builderRefusesCount(value: JSONValue) {
        #expect(throws: CalendarProviderError.self) {
            try CalendarToolHelpers.buildGCalEventInput(recurrence("count", value), isAllDay: false)
        }
    }

    @Test("the event builder writes a whole double count and interval as integers")
    func builderAcceptsWholeDoubles() throws {
        let args: [String: JSONValue] = ["recurrence": .dictionary([
            "freq": .string("weekly"), "interval": .double(2.0), "count": .double(14.0),
        ])]
        let rule = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false).recurrence?.first
        #expect(rule == "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=14")
    }

    @Test("the event builder treats a null count or interval as absent")
    func builderNullIsAbsent() throws {
        let args: [String: JSONValue] = ["recurrence": .dictionary([
            "freq": .string("daily"), "interval": .null, "count": .null,
        ])]
        let rule = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false).recurrence?.first
        #expect(rule == "RRULE:FREQ=DAILY")
    }

    @Test("calendar create and edit refuse a bad recurrence before the confirmation card",
          arguments: [JSONValue.double(1e300), .double(2.5), .int(0)])
    func createAndEditRefuse(count: JSONValue) async throws {
        let ctx = try makeContext()
        let rec = recurrence("count", count)

        var createArgs = rec
        createArgs["title"] = .string("Standup")
        let created = try await CalendarEventCreateTool(context: ctx).execute(arguments: createArgs)
        #expect(created.contains("recurrence.count must be a whole number of 1 or more"))
        #expect(created.contains("NOT created"))

        var editArgs = rec
        editArgs["event_id"] = .string("evt-1")
        let edited = try await CalendarEventEditTool(context: ctx).execute(arguments: editArgs)
        #expect(edited.contains("recurrence.count must be a whole number of 1 or more"))
        #expect(edited.contains("NOT changed"))
    }

    @Test("the confirmation text shows a whole double count and interval")
    func summaryShowsWholeDoubles() throws {
        let args: [String: JSONValue] = ["recurrence": .dictionary([
            "freq": .string("weekly"), "interval": .double(2.0), "count": .double(14.0),
        ])]
        #expect(try CalendarToolHelpers.recurrenceSummary(args) == "every 2 weekly (14 times)")
    }

    // MARK: - No other path from a JSON number to Int

    /// Every integer argument goes through `JSONValue.wholeNumber`. A new `.double` binding in a
    /// tool is a new conversion that skips it. `AttachmentReadPdfTool.parsePage` is the one
    /// exception: it bounds its page number to `Int32` before converting.
    @Test("tools read numbers only through JSONValue.wholeNumber")
    func noOtherDoubleConversion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tools
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        // Recursive: the agent tools and their helpers live under Services/AI, and the calendar
        // queue that replays tool arguments lives under Services/Account.
        let dirs = ["TabMail/Services/AI", "TabMail/Services/Account"]
        let binding = try Regex(#"case\s+(let\s+)?\.double\((let\s+)?\w+\)"#)
        var found: [String: Int] = [:]
        var scanned = 0
        for dir in dirs {
            let url = root.appendingPathComponent(dir)
            let files = (FileManager.default.subpaths(atPath: url.path) ?? []).filter { $0.hasSuffix(".swift") }
            #expect(!files.isEmpty, "no sources found under \(dir)")
            for file in files {
                let source = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                scanned += 1
                let count = source.matches(of: binding).count
                if count > 0 { found["\(dir)/\(file)"] = count }
            }
        }
        #expect(scanned > 20, "scanned only \(scanned) files; the source root moved")
        #expect(found == ["TabMail/Services/AI/Tools/AttachmentReadPdfTool.swift": 1],
                "a tool reads a JSON number outside JSONValue.wholeNumber: \(found)")
    }
}
