/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The assistant's inbox listing's debug cost line (`InboxReadTool.readListingWithCost`): with debug
/// logging off no meter is made, the listing gets nil and nothing is logged; with it on the tool logs
/// exactly one line, and that line holds the page, pages, rows, total and demo flag as integers, then
/// the meter's counts, and no account, folder, subject, sender or snippet text.
///
/// `.serialized, .processGlobalState`: these tests set the process-global
/// `DebugModeManager.loggingEnabledOverrideForTesting` and `AppLogStore.fileURLOverride`.
@Suite("Inbox read tool: the debug cost line is made only while debug logging is on and holds integers only", .serialized, .processGlobalState)
struct InboxReadToolCostLineTests {

    /// More than one page, so the listing runs its count and its page statements.
    private static let inboxRows = InboxReadTool.Config.pageSize + 10
    private static let accountId = "acc-costline"
    private static let subject = "Costline subject 4f1a"
    private static let sender = "costline.sender@example.com"
    private static let snippet = "Costline snippet 9c2d"
    /// Text in the database that the line must never hold.
    private static let names = [accountId, "INBOX", subject, sender, "recipient@example.com", snippet]
    /// The line's own fields, in order, then the meter's counts.
    private static let shapeKeys = ["page", "pages", "rows", "total", "demo"]
    private static let meterKeys: Set<String> = [
        "ms", "statements", "vmSteps", "fullScanSteps", "sorts", "pageHits", "pageMisses",
    ]
    private static let linePrefix = "[InboxReadTool] page="

    private func makeContext() throws -> (ToolContext, DatabaseQueue) {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: Self.accountId)
        try TestDatabase.insertFolder(db, accountId: Self.accountId)
        let now = Date()
        for index in 0..<Self.inboxRows {
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(1_000 + index)", subject: "\(Self.subject) \(index)",
                from: Self.sender, fromAddress: Self.sender,
                date: now.addingTimeInterval(-Double(index) * 60), snippet: "\(Self.snippet) \(index)",
                folderId: "\(Self.accountId):INBOX", accountId: Self.accountId)
        }
        return (ToolContext(db: db, translator: MockChatIdTranslator()), db)
    }

    /// The debug log's cost lines from the listing.
    private static func costLines() -> [String] {
        AppLogStore.read(channel: .debug).components(separatedBy: "\n").filter { $0.contains(linePrefix) }
    }

    /// Runs `body` with debug logging held at `loggingEnabled` and the log in a fresh file,
    /// restoring both after.
    private func withLogging(_ loggingEnabled: Bool, _ body: () async throws -> Void) async rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inboxcost_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = loggingEnabled }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        try await body()
    }

    @Test("With debug logging off the listing makes no meter, builds no line and the tool logs none")
    func noLineWithLoggingOff() async throws {
        let (ctx, db) = try makeContext()
        try await withLogging(false) {
            let read = try await db.read { try InboxReadTool.readListingWithCost($0, pageIndex: 1, demoActive: false) }
            #expect(read.costLine == nil, "a cost line was built with debug logging off: \(read.costLine ?? "")")
            #expect(read.listing.rows.count == InboxReadTool.Config.pageSize)
            #expect(read.listing.totalCount == Self.inboxRows)
            _ = try await InboxReadTool(context: ctx).execute(arguments: [:])
            #expect(Self.costLines().isEmpty, "a cost line was logged with debug logging off: \(Self.costLines())")
        }
    }

    @Test("With debug logging on the tool logs exactly one cost line per read")
    func oneLineWithLoggingOn() async throws {
        let (ctx, db) = try makeContext()
        try await withLogging(true) {
            let read = try await db.read { try InboxReadTool.readListingWithCost($0, pageIndex: 1, demoActive: false) }
            #expect(read.costLine != nil, "no cost line was built with debug logging on")
            #expect(Self.costLines().isEmpty, "the listing logged from inside the read: \(Self.costLines())")
            _ = try await InboxReadTool(context: ctx).execute(arguments: ["page_index": .int(2)])
            let logged = Self.costLines()
            #expect(logged.count == 1, "expected one cost line, got \(logged.count): \(logged)")
        }
    }

    @Test("The cost line holds the page, pages, rows, total and demo flag as integers, then counts only", arguments: [
        (1, false), (2, false), (1, true),
    ])
    func theLineHoldsIntegersOnly(page: Int, demoActive: Bool) async throws {
        let (_, db) = try makeContext()
        try await withLogging(true) {
            let read = try await db.read { try InboxReadTool.readListingWithCost($0, pageIndex: page, demoActive: demoActive) }
            guard let line = read.costLine else {
                Issue.record("no cost line was built with debug logging on")
                return
            }
            var tokens = line.split(separator: " ").map(String.init)
            #expect(tokens.first == "[InboxReadTool]", "the line does not start with its tag: \(line)")
            guard tokens.count > 1 + Self.shapeKeys.count else {
                Issue.record("the line is too short: \(line)")
                return
            }
            tokens.removeFirst()
            let listing = read.listing
            let expected = [listing.page + 1, listing.totalPages, listing.rows.count, listing.totalCount, demoActive ? 1 : 0]
            let shape = Array(tokens.prefix(Self.shapeKeys.count))
            let expectedShape = zip(Self.shapeKeys, expected).map { "\($0)=\($1)" }
            #expect(shape == expectedShape, "the line's own fields: \(line)")
            let countKeys = Set(tokens.dropFirst(Self.shapeKeys.count).map { token in String(token.prefix { $0 != "=" }) })
            #expect(countKeys == Self.meterKeys, "the line's counts: \(line)")
            for token in tokens {
                let parts = token.split(separator: "=", omittingEmptySubsequences: false)
                let isNumber = parts.count == 2 && Double(parts[1]) != nil
                #expect(isNumber, "a field is not key=number: \(token) in \(line)")
            }
            for name in Self.names {
                #expect(!line.contains(name), "the line holds \(name): \(line)")
            }
        }
    }
}
