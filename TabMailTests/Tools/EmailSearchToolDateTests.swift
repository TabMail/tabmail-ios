/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// email_search's date bounds: a full timestamp bounds to the millisecond, in
/// any offset and with fractional seconds; a date alone bounds by its day.
@Suite("EmailSearchTool dates", .serialized, .processGlobalState)
struct EmailSearchToolDateTests {

    private static let folderId = "emaildates:INBOX"

    /// Noon UTC three days ago plus 250 ms: the bound the timestamps below name.
    private func bound() -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: Date().addingTimeInterval(-3 * 86_400))
        return Int64(day.timeIntervalSince1970 + 12 * 3_600) * 1000 + 250
    }

    private func timestamp(_ ms: Int64, offsetHours: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)!
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func record(_ id: String, subject: String, dateMs: Int64) -> FTSHeaderRecord {
        FTSHeaderRecord(contentKey: ContentKey(rawValue: id),
            headerId: id, messageId: "m-\(id.suffix(8))",
            subject: subject, from: "a@example.com", to: "b@example.com",
            dateMs: dateMs,
            folderId: Self.folderId
        )
    }

    /// Indexes three matching messages an hour apart around the bound (and
    /// filler that doesn't match), runs `body`, then removes them all.
    private func withMessages(_ body: (EmailSearchTool, String, [Int64]) async throws -> Void) async throws {
        let marker = "emaildates\(UUID().uuidString.prefix(8).lowercased())"
        let b = bound()
        let dates = [b - 3_600_000, b, b + 3_600_000]
        var records = dates.enumerated().map { record("emaildates:INBOX:match-\(marker)-\($0.offset)", subject: "\(marker) report", dateMs: $0.element) }
        records += (0..<20).map { record("emaildates:INBOX:filler-\(marker)-\($0)", subject: "filler subject \($0)", dateMs: b) }
        let keys = records.map(\.contentKey)
        defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: keys) } }
        _ = try await SearchIndex.shared.indexHeaders(records)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try AppDatabase(dbPool: pool) // the schema the tool reads headers from
        let tool = EmailSearchTool(context: ToolContext(db: pool, translator: MockChatIdTranslator()))
        try await body(tool, marker, dates)
    }

    private func totalItems(_ result: String) throws -> Int {
        let data = try #require(result.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["totalItems"] as? Int)
    }

    @Test("A full timestamp bounds the search to the millisecond", arguments: [0, 2, -5])
    func fullTimestampBounds(offsetHours: Int) async throws {
        try await withMessages { tool, marker, dates in
            let at = timestamp(dates[1], offsetHours: offsetHours)
            let from = try await tool.execute(arguments: ["query": .string(marker), "from_date": .string(at)])
            #expect(try totalItems(from) == 2, "from \(at): the bound's message and the later one")
            let to = try await tool.execute(arguments: ["query": .string(marker), "to_date": .string(at)])
            #expect(try totalItems(to) == 2, "to \(at): the earlier message and the bound's")
            let just = timestamp(dates[1] + 1, offsetHours: offsetHours)
            let after = try await tool.execute(arguments: ["query": .string(marker), "from_date": .string(just)])
            #expect(try totalItems(after) == 1, "from \(just): only the later message")
        }
    }

    @Test("A date alone bounds the search by its day")
    func dateOnlyBounds() async throws {
        try await withMessages { tool, marker, dates in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(dates[1]) / 1000))
            let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            let dayStart = try #require(Date.fromISO8601FullDate(day))
            let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
            let endMs = startMs + 86_400_000 - 1
            let from = try await tool.execute(arguments: ["query": .string(marker), "from_date": .string(day)])
            #expect(try totalItems(from) == dates.filter { $0 >= startMs }.count)
            let to = try await tool.execute(arguments: ["query": .string(marker), "to_date": .string(day)])
            #expect(try totalItems(to) == dates.filter { $0 <= endMs }.count)
        }
    }
}
