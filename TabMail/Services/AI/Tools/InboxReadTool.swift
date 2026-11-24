/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3

/// Client-side `inbox_read` tool matching TB addon's `inbox_read.js`.
/// Queries GRDB for inbox messages and formats them for LLM consumption.
/// Registered in `ToolRegistry` at app startup.
struct InboxReadTool: AgentTool, Sendable {
    let name = "inbox_read"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    enum Config {
        /// TB uses pageSize=50 (inboxPageSizeDefault=100 clamped by inboxPageSizeMax=50)
        static let pageSize = 50
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let pageIndex: Int
        if let p = arguments["page_index"]?.wholeNumber {
            pageIndex = max(1, p)
        } else if case .string(let s) = arguments["page_index"], let p = Int(s) {
            pageIndex = max(1, p)
        } else {
            pageIndex = 1
        }

        // Query inbox: total + one page, in one read (`readListing`).
        // Demo boundary (ADR-IOS-038): demo lists ONLY demo rows; normal mode
        // never lists them (real rows are also isInInbox during coexistence).
        let demoActive = DemoModeStore.isDemoActive
        let started = CFAbsoluteTimeGetCurrent()
        let (listing, cost) = try await ctx.db.read { db in
            var cost = ReadCost()
            let listing = try Self.readListing(db, pageIndex: pageIndex, demoActive: demoActive, cost: &cost)
            return (listing, cost)
        }
        let readMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let totalCount = listing.totalCount
        let totalPages = listing.totalPages
        let safePage = listing.page
        let pageItems = listing.rows
        BackgroundSyncLogger.logDebug("[InboxReadTool] read page \(safePage + 1) of \(totalPages) (rows=\(pageItems.count) total=\(totalCount)) in \(readMs)ms statements=\(cost.statements) vmSteps=\(cost.vmSteps) fullscanSteps=\(cost.fullscanSteps)")

        // Format matching TB's formatMailList in helpers.js
        let translator = ctx.translator
        var blocks: [String] = []
        for msg in pageItems {
            let numericId = await translator.toNumericId(msg.id)
            BackgroundSyncLogger.logDebug("[AIChatDebug] InboxReadTool: registered id=\(numericId) → realId=\(msg.id.prefix(30)) subject=\(msg.subject.prefix(40))")
            var lines: [String] = []
            lines.append("unique_id: \(numericId)")
            lines.append("date: \(ToolFormatters.formatDate(msg.date))")
            lines.append("from: \(ToolFormatters.formatFrom(msg))")
            lines.append("subject: \(msg.subject.isEmpty ? "(No subject)" : msg.subject)")
            lines.append("has_attachments: \(msg.hasAttachments ? "yes" : "no")")
            lines.append("currently_tagged_for: \(msg.actionTag?.rawValue ?? "")")
            lines.append("replied: \(msg.isReplied ? "yes" : "no")")
            if let todos = msg.summaryTodos, !todos.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("todos: \(todos)")
            }
            if let blurb = msg.summaryBlurb, !blurb.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("two-line summary: \(blurb)")
            }
            blocks.append(lines.joined(separator: "\n\n"))
        }

        let body = blocks.joined(separator: "\n\n")
        let formatted = "====BEGIN EMAIL LIST====\n\(body)\n====END EMAIL LIST===="
        let footer = "\n----- Page \(safePage + 1) of \(totalPages) -----"

        // Build JSON result matching TB's return format
        let result = formatted + footer

        BackgroundSyncLogger.logDebug("[InboxReadTool] Returning page \(safePage + 1) of \(totalPages) (pageCount=\(pageItems.count) totalItems=\(totalCount))")

        var resultDict: [String: Any] = [
            "results": result,
            "page": safePage + 1,
            "totalPages": totalPages,
            "totalItems": totalCount,
        ]

        if safePage + 1 < totalPages {
            resultDict["comment"] = "There are more pages of results. To get the next page, call this tool again with page_index: \(safePage + 2)"
        }
        return ToolJSON.string(from: resultDict)
    }

    // MARK: - Listing read

    /// One page of the inbox listing, as the tool reports it.
    struct Listing: Sendable {
        let rows: [MessageHeader]
        /// Inbox rows in the account scope.
        let totalCount: Int
        /// The zero-based page returned: the requested page, clamped to the last.
        let page: Int

        var totalPages: Int { InboxReadTool.totalPages(for: totalCount) }
    }

    /// What the listing's statements made SQLite do, summed, for the debug timing line.
    struct ReadCost: Sendable {
        var statements = 0
        /// Virtual machine steps: grows with the index entries and rows a statement visits.
        var vmSteps = 0
        /// Rows stepped through by a full table scan (0 when every statement seeks an index).
        var fullscanSteps = 0
    }

    static func totalPages(for totalCount: Int) -> Int {
        max(1, (totalCount + Config.pageSize - 1) / Config.pageSize)
    }

    /// The requested 1-based page as a 0-based page, clamped to the listing's pages.
    static func clampedPage(_ pageIndex: Int, totalCount: Int) -> Int {
        min(max(pageIndex - 1, 0), totalPages(for: totalCount) - 1)
    }

    /// Reads one page of the inbox listing and its total.
    ///
    /// Same total and rows, in the same order, as counting the inbox rows in the account scope
    /// and paging them by `date` with LIMIT/OFFSET; but in normal mode neither the count nor the
    /// rows OFFSET skips read a table row per inbox message:
    /// - The inbox count comes from `messageHeader_isInInbox_date` alone.
    /// - When it is at most one page, the scoped page at offset 0 is the whole listing, whatever
    ///   the scope removes, so its rows are the total.
    /// - Otherwise the scope (`accountId` is not the demo account) is applied as "rowid is not one
    ///   of the demo account's rows", which the inbox index carries, so the count and the rows
    ///   OFFSET skips stay in the index. The demo rowids come from an `accountId` index alone, and
    ///   only when a demo account row exists: without it there is no demo message row (`accountId`
    ///   references `account`; `DemoSeed.wipe` deletes the account last), and the total is the
    ///   inbox count. The page's order adds `rowid DESC`, the index's own order among equal dates,
    ///   so the order is total.
    /// - Demo mode lists the demo account's few rows with the scoped count and page as they are.
    static func readListing(_ db: Database, pageIndex: Int, demoActive: Bool, cost: inout ReadCost) throws -> Listing {
        let pageSize = Config.pageSize
        let inbox = MessageHeader.filter(Column("isInInbox") == true)
        let inScope = inbox.filter(DemoToolGuard.accountScope(demoActive: demoActive))
        if !demoActive {
            let inboxCount = try fetchCount(db, inbox, cost: &cost)
            guard inboxCount > pageSize else {
                let rows = try fetchAll(db, inScope.order(Column("date").desc).limit(pageSize), cost: &cost)
                return Listing(rows: rows, totalCount: rows.count, page: 0)
            }
            let demoRowIDs = try DemoSeed.hasDemoData(db)
                ? fetchRowIDs(db, MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId), cost: &cost)
                : []
            let listed = demoRowIDs.isEmpty ? inbox : inbox.filter(!demoRowIDs.contains(Column.rowID))
            let totalCount = demoRowIDs.isEmpty ? inboxCount : try fetchCount(db, listed, cost: &cost)
            let page = clampedPage(pageIndex, totalCount: totalCount)
            let rows = try fetchAll(
                db,
                listed.order(Column("date").desc, Column.rowID.desc).limit(pageSize, offset: page * pageSize),
                cost: &cost)
            return Listing(rows: rows, totalCount: totalCount, page: page)
        }
        let totalCount = try fetchCount(db, inScope, cost: &cost)
        let page = clampedPage(pageIndex, totalCount: totalCount)
        let rows = try fetchAll(
            db, inScope.order(Column("date").desc).limit(pageSize, offset: page * pageSize), cost: &cost)
        return Listing(rows: rows, totalCount: totalCount, page: page)
    }

    private static func fetchRowIDs(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, cost: inout ReadCost
    ) throws -> [Int64] {
        let statement = try request.select(Column.rowID, as: Int64.self)
            .makePreparedRequest(db, forSingleResult: false).statement
        return try measured(statement, cost: &cost) { try Int64.fetchAll(statement) }
    }

    private static func fetchCount(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, cost: inout ReadCost
    ) throws -> Int {
        let statement = try request.select(SQL(sql: "COUNT(*)"), as: Int.self)
            .makePreparedRequest(db, forSingleResult: false).statement
        return try measured(statement, cost: &cost) { try Int.fetchOne(statement) ?? 0 }
    }

    private static func fetchAll(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, cost: inout ReadCost
    ) throws -> [MessageHeader] {
        let statement = try request.makePreparedRequest(db, forSingleResult: false).statement
        return try measured(statement, cost: &cost) { try MessageHeader.fetchAll(statement) }
    }

    /// Runs `fetch` on `statement` and adds what it made SQLite do to `cost`. The counters are
    /// reset first, as a cached statement keeps them from earlier runs.
    private static func measured<T>(_ statement: Statement, cost: inout ReadCost, _ fetch: () throws -> T) throws -> T {
        let handle = statement.sqliteStatement
        sqlite3_stmt_status(handle, SQLITE_STMTSTATUS_VM_STEP, 1)
        sqlite3_stmt_status(handle, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1)
        let value = try fetch()
        cost.statements += 1
        cost.vmSteps += Int(sqlite3_stmt_status(handle, SQLITE_STMTSTATUS_VM_STEP, 0))
        cost.fullscanSteps += Int(sqlite3_stmt_status(handle, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
        return value
    }
}
