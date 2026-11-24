/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

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
        let (listing, costLine): (Listing, String?) = try await ctx.db.read { db in
            let meter = ReadCostMeter.start(db)
            let listing = try Self.readListing(db, pageIndex: pageIndex, demoActive: demoActive, meter: meter)
            return (listing, meter?.line("InboxReadTool", [
                "page": listing.page + 1, "pages": listing.totalPages, "rows": listing.rows.count,
                "total": listing.totalCount, "demo": demoActive ? 1 : 0,
            ]))
        }
        if let costLine { ReadCostMeter.log([costLine]) }
        let totalCount = listing.totalCount
        let totalPages = listing.totalPages
        let safePage = listing.page
        let pageItems = listing.rows

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
    ///
    /// Every statement is prepared through `meter` (`ReadCostMeter.statement`) for the debug cost
    /// line; nil counts nothing.
    static func readListing(_ db: Database, pageIndex: Int, demoActive: Bool, meter: ReadCostMeter?) throws -> Listing {
        let pageSize = Config.pageSize
        let inbox = MessageHeader.filter(Column("isInInbox") == true)
        let inScope = inbox.filter(DemoToolGuard.accountScope(demoActive: demoActive))
        if !demoActive {
            let inboxCount = try fetchCount(db, inbox, meter: meter)
            guard inboxCount > pageSize else {
                let rows = try fetchAll(db, inScope.order(Column("date").desc).limit(pageSize), meter: meter)
                return Listing(rows: rows, totalCount: rows.count, page: 0)
            }
            let demoRowIDs = try DemoSeed.hasDemoData(db)
                ? fetchRowIDs(db, MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId), meter: meter)
                : []
            let listed = demoRowIDs.isEmpty ? inbox : inbox.filter(!demoRowIDs.contains(Column.rowID))
            let totalCount = demoRowIDs.isEmpty ? inboxCount : try fetchCount(db, listed, meter: meter)
            let page = clampedPage(pageIndex, totalCount: totalCount)
            let rows = try fetchAll(
                db,
                listed.order(Column("date").desc, Column.rowID.desc).limit(pageSize, offset: page * pageSize),
                meter: meter)
            return Listing(rows: rows, totalCount: totalCount, page: page)
        }
        let totalCount = try fetchCount(db, inScope, meter: meter)
        let page = clampedPage(pageIndex, totalCount: totalCount)
        let rows = try fetchAll(
            db, inScope.order(Column("date").desc).limit(pageSize, offset: page * pageSize), meter: meter)
        return Listing(rows: rows, totalCount: totalCount, page: page)
    }

    private static func fetchRowIDs(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, meter: ReadCostMeter?
    ) throws -> [Int64] {
        try Int64.fetchAll(statement(db, request.select(Column.rowID, as: Int64.self), meter: meter))
    }

    private static func fetchCount(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, meter: ReadCostMeter?
    ) throws -> Int {
        try Int.fetchOne(statement(db, request.select(SQL(sql: "COUNT(*)"), as: Int.self), meter: meter)) ?? 0
    }

    private static func fetchAll(
        _ db: Database, _ request: QueryInterfaceRequest<MessageHeader>, meter: ReadCostMeter?
    ) throws -> [MessageHeader] {
        try MessageHeader.fetchAll(statement(db, request, meter: meter))
    }

    /// `request`'s SQL and arguments in a statement prepared through `meter`.
    private static func statement<T>(
        _ db: Database, _ request: QueryInterfaceRequest<T>, meter: ReadCostMeter?
    ) throws -> Statement {
        let prepared = try request.makePreparedRequest(db, forSingleResult: false).statement
        let statement = try ReadCostMeter.statement(db, sql: prepared.sql, meter: meter)
        try statement.setArguments(prepared.arguments)
        return statement
    }
}
