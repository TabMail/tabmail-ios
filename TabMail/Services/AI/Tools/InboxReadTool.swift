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

    private enum Config {
        /// TB uses pageSize=50 (inboxPageSizeDefault=100 clamped by inboxPageSizeMax=50)
        static let pageSize = 50
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let pageIndex: Int
        if case .int(let p) = arguments["page_index"] {
            pageIndex = max(1, p)
        } else if case .string(let s) = arguments["page_index"], let p = Int(s) {
            pageIndex = max(1, p)
        } else {
            pageIndex = 1
        }

        // Query inbox: count + single page via LIMIT/OFFSET (bounded memory).
        // Demo boundary (ADR-IOS-038): demo lists ONLY demo rows; normal mode
        // never lists them (real rows are also isInInbox during coexistence).
        let demoActive = DemoModeStore.isDemoActive
        let totalCount = try await ctx.db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(DemoToolGuard.accountScope(demoActive: demoActive))
                .fetchCount(db)
        }
        let totalPages = max(1, (totalCount + Config.pageSize - 1) / Config.pageSize)
        let safePage = min(max(pageIndex - 1, 0), totalPages - 1)
        let offset = safePage * Config.pageSize

        let pageItems: [MessageHeader] = try await ctx.db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(DemoToolGuard.accountScope(demoActive: demoActive))
                .order(Column("date").desc)
                .limit(Config.pageSize, offset: offset)
                .fetchAll(db)
        }

        // Format matching TB's formatMailList in helpers.js
        let translator = ctx.translator
        var blocks: [String] = []
        for msg in pageItems {
            let numericId = await translator.toNumericId(msg.id)
            print("[AIChatDebug] InboxReadTool: registered id=\(numericId) → realId=\(msg.id.prefix(30)) subject=\(msg.subject.prefix(40))")
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

        print("[InboxReadTool] Returning page \(safePage + 1) of \(totalPages) (pageCount=\(pageItems.count) totalItems=\(totalCount))")

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

}
