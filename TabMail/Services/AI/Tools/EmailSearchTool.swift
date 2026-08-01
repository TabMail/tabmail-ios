/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_search` tool matching TB addon's `email_search.js`.
/// Uses FTS5 hybrid search via SearchIndex and formats results for LLM.
/// Registered in `ToolRegistry` at app startup.
struct EmailSearchTool: AgentTool, Sendable {
    let name = "email_search"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    private enum Config {
        /// TB uses pageSize=20 (searchPageSizeDefault=20 clamped by searchPageSizeMax=500)
        static let pageSize = 20
        static let maxResults = 50
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let query) = arguments["query"],
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing or empty query"}"#
        }

        let pageIndex: Int
        if case .int(let p) = arguments["page_index"] {
            pageIndex = max(1, p)
        } else if case .string(let s) = arguments["page_index"], let p = Int(s) {
            pageIndex = max(1, p)
        } else {
            pageIndex = 1
        }

        // Parse optional date filters
        let fromDate = ToolFormatters.parseDate(arguments["from_date"])
        let toDate = ToolFormatters.parseDate(arguments["to_date"])

        let fromStr = fromDate.map { ToolFormatters.formatDate($0) } ?? "-"
        let toStr = toDate.map { ToolFormatters.formatDate($0) } ?? "-"
        print("[EmailSearchTool] email_search: query='\(String(query.prefix(80)))' from_date='\(fromStr)' to_date='\(toStr)' page_index=\(pageIndex)")

        // Convert date filters to epoch ms for search layer.
        // When to_date is a date-only string (YYYY-MM-DD), extend to end-of-day
        // so messages on that day are included (23:59:59.999).
        let fromDateMs = fromDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let toDateMs: Int64? = toDate.map { date in
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            if case .string(let str) = arguments["to_date"], str.count <= 10 {
                return ms + 86_400_000 - 1 // date-only → end of day
            }
            return ms
        }

        // FTS search via SearchIndex (hybrid: keyword + vector, with date filtering in SQL)
        let searchStart = CFAbsoluteTimeGetCurrent()
        var hits = try await SearchIndex.shared.search(
            query: query, fromDateMs: fromDateMs, toDateMs: toDateMs, limit: Config.maxResults)
        let searchMs = Int((CFAbsoluteTimeGetCurrent() - searchStart) * 1000)
        print("[EmailSearchTool] email_search: FTS returned \(hits.count) items in \(searchMs)ms")

        // Handle sort option
        let sort: String
        if case .string(let s) = arguments["sort"] {
            sort = s
        } else {
            sort = "date_desc"
        }

        switch sort {
        case "date_asc":
            hits.sort { $0.dateMs < $1.dateMs }
        case "date_desc":
            hits.sort { $0.dateMs > $1.dateMs }
        default:
            break // "relevance" — keep FTS rank ordering
        }

        let total = hits.count
        print("[EmailSearchTool] email_search: \(total) items total (sort=\(sort))")

        // Log top results for debugging
        for (i, hit) in hits.prefix(10).enumerated() {
            let date = Date(timeIntervalSince1970: Double(hit.dateMs) / 1000)
            print("[EmailSearchTool]   [\(i)] rank=\(String(format: "%.4f", hit.rank)) headerId=\(hit.contentKey.rawValue.prefix(40)) date=\(ToolFormatters.formatDate(date)) snippet=\(hit.snippet.prefix(60))")
        }

        if total == 0 {
            let resultDict: [String: Any] = [
                "results": "No emails found with the query. Use a different query.",
                "page": 1,
                "totalPages": 1,
                "pageCount": 0,
                "totalItems": 0,
            ]
            return ToolJSON.string(from: resultDict)
        }

        // Paginate
        let totalPages = max(1, (total + Config.pageSize - 1) / Config.pageSize)
        let safePage = min(max(pageIndex - 1, 0), totalPages - 1)
        let start = safePage * Config.pageSize
        let end = min(start + Config.pageSize, total)
        let slice = Array(hits[start..<end])

        // Resolve headers from GRDB and format matching TB's formatMailList
        let translator = ctx.translator
        var blocks: [String] = []

        for hit in slice {
            // 🚨 STAGE E1 — DAY-ONE BREAKAGE, already known to the plan. `hit.contentKey`
            // addresses an FTS row; both uses below treat it as a `messageHeader.id`
            // (primary-key fetch, and the agent-facing numeric-id translation that later
            // round-trips back into `MessageHeader.fetchOne`). Byte-identical today; at
            // E1 every UID-addressed account's agent search resolves no header and the
            // numeric ids it hands the model point at nothing.
            let ftsKeyAsHeaderId = hit.contentKey.rawValue
            // Fetch header for full metadata
            let header: MessageHeader? = try await ctx.db.read { db in
                try MessageHeader.fetchOne(db, key: ftsKeyAsHeaderId)
            }

            let numericId = await translator.toNumericId(ftsKeyAsHeaderId)
            var lines: [String] = []
            lines.append("unique_id: \(numericId)")

            if let header {
                lines.append("date: \(ToolFormatters.formatDate(header.date))")
                lines.append("from: \(ToolFormatters.formatFrom(header))")
                lines.append("subject: \(header.subject.isEmpty ? "(No subject)" : header.subject)")
                lines.append("has_attachments: \(header.hasAttachments ? "yes" : "no")")
                lines.append("currently_tagged_for: \(header.actionTag?.rawValue ?? "")")
                lines.append("replied: \(header.isReplied ? "yes" : "no")")
                // TB formatMailList: search results use FTS snippet, not blurb/todos
                if !hit.snippet.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("search snippet: \(hit.snippet)")
                }
            } else {
                // Fallback to FTS data when header missing
                let date = Date(timeIntervalSince1970: Double(hit.dateMs) / 1000)
                lines.append("date: \(ToolFormatters.formatDate(date))")
                lines.append("search snippet: \(hit.snippet)")
            }

            blocks.append(lines.joined(separator: "\n\n"))
            print("[EmailSearchTool] registered id=\(numericId) → headerId=...\(ftsKeyAsHeaderId.suffix(30))")
        }

        let body = blocks.joined(separator: "\n\n")
        let formatted = "====BEGIN EMAIL LIST====\n\(body)\n====END EMAIL LIST===="

        var resultDict: [String: Any] = [
            "results": formatted,
            "page": safePage + 1,
            "totalPages": totalPages,
            "totalItems": total,
        ]

        if safePage + 1 < totalPages {
            resultDict["comment"] = "There are more pages of results. To get the next page, call this tool again with page_index: \(safePage + 2)"
        }

        print("[EmailSearchTool] Returning page \(safePage + 1) of \(totalPages) (pageCount=\(slice.count) totalItems=\(total))")

        return ToolJSON.string(from: resultDict)
    }

}
