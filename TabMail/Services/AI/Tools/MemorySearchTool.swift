/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `memory_search` tool matching TB addon's `memory_search.js`.
/// v3: per-turn granularity. Each hit is a single chatHistory turn, ranked
/// independently by BM25 + vec. A session with three matching turns produces
/// three hits.
///
/// Backend: `MemoryIndex` hybrid FTS5 + sqlite-vec pipeline.
/// Registered in `ToolRegistry` at app startup.
struct MemorySearchTool: AgentTool, Sendable {
    let name = "memory_search"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let query) = arguments["query"], !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing query"}"#
        }

        let pageIndex: Int
        if case .int(let p) = arguments["page_index"] {
            pageIndex = max(1, p)
        } else if case .string(let s) = arguments["page_index"], let p = Int(s) {
            pageIndex = max(1, p)
        } else {
            pageIndex = 1
        }

        // Parse optional date filters (same helper as email_search uses).
        let fromDate = ToolFormatters.parseDate(arguments["from_date"])
        let toDate = ToolFormatters.parseDate(arguments["to_date"])
        let fromRaw: String? = {
            if case .string(let s) = arguments["from_date"] { return s }
            return nil
        }()
        let toRaw: String? = {
            if case .string(let s) = arguments["to_date"] { return s }
            return nil
        }()

        // TB parity — page size / prefetch / max.
        let pageSize = SearchConfig.memoryPageSizeDefault
        let prefetchPages = SearchConfig.memoryPrefetchPagesDefault
        let prefetchMax = SearchConfig.memoryPrefetchMaxResults
        let fetchLimit = min(pageSize * prefetchPages, prefetchMax)

        // Per-user-turn cache keyed on normalized args (matches TB memory_search.js:27-30).
        let cacheKey = MemorySearchCache.makeKey(query: query, fromDate: fromRaw, toDate: toRaw)
        print("[MemorySearchTool] ENTER q='\(query.prefix(60))' page=\(pageIndex) fromRaw=\(fromRaw ?? "nil") toRaw=\(toRaw ?? "nil") fromDate=\(fromDate.map { "\($0)" } ?? "nil") toDate=\(toDate.map { "\($0)" } ?? "nil") fetchLimit=\(fetchLimit)")
        var hits: [MemoryHit]
        if let cached = await MemorySearchCache.shared.get(cacheKey) {
            hits = cached
            print("[MemorySearchTool] CACHE HIT key=\(cacheKey.prefix(120)) hits=\(hits.count)")
        } else {
            let fromMs = fromDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            // Date-only "YYYY-MM-DD" → end-of-day inclusive. Without this,
            // `to_date=2026-04-30` would clip the range at midnight April 30
            // (= end of April 29) and silently drop everything actually on
            // April 30. Mirrors EmailSearchTool's handling.
            let toMs: Int64? = toDate.map { date in
                let ms = Int64(date.timeIntervalSince1970 * 1000)
                if let raw = toRaw, raw.count <= 10 {
                    return ms + 86_400_000 - 1
                }
                return ms
            }
            hits = await MemoryIndex.shared.search(
                query: query,
                fromMs: fromMs,
                toMs: toMs,
                limit: fetchLimit
            )
            print("[MemorySearchTool] CACHE MISS — MemoryIndex.search returned \(hits.count) hits")
            await MemorySearchCache.shared.set(cacheKey, hits)
        }

        if hits.isEmpty {
            print("[MemorySearchTool] EMPTY result q='\(query.prefix(60))' fromRaw=\(fromRaw ?? "nil") toRaw=\(toRaw ?? "nil") fromDate=\(fromDate.map { "\($0)" } ?? "nil") toDate=\(toDate.map { "\($0)" } ?? "nil")")
            return #"{"results": "No relevant memories found for this query.", "page": 1, "totalPages": 1, "pageCount": 0, "totalItems": 0}"#
        }

        // Paginate.
        let totalPages = max(1, (hits.count + pageSize - 1) / pageSize)
        let safePage = min(max(pageIndex - 1, 0), totalPages - 1)
        let start = safePage * pageSize
        let end = min(start + pageSize, hits.count)
        let slice = Array(hits[start..<end])

        // Format per-turn results. Role tag (USER / AGENT) + timestamp + snippet.
        //
        // IMPORTANT: explicit `String` annotations on both the outer binding AND the
        // closure return type. GRDB's `SQL` conforms to ExpressibleByStringInterpolation,
        // and Swift's inference for `"\(...)"` interpolation can resolve to `SQL` instead
        // of `String` in any file where GRDB is reachable through imports. Without these
        // annotations the closure ends up typed `(Int, MemoryHit) -> SQL`, `formatted`
        // becomes `SQL`, and `ToolJSON.bridgeValue`'s `String` case fails to match —
        // falling through to `"\(value)" as NSString`, which stringifies the SQL value
        // as `"SQL(elements: [GRDB.SQL.Element.expression(...)])"` in the tool output.
        // Caught by `logmain.log` on 2026-04-22. Sibling fix in `MemoryReadTool.swift`.
        let formatted: String = slice.enumerated().map { idx, hit -> String in
            let globalIdx = start + idx + 1
            let dateStr = ToolFormatters.formatDateMs(Double(hit.dateMs))
            let roleTag: String = hit.role == "user" ? "USER" : "AGENT"
            let snippetText: String = hit.snippet.isEmpty
                ? String(hit.content.prefix(SearchConfig.memorySnippetMaxLength))
                : hit.snippet
            return "\(globalIdx). [timestamp: \(hit.dateMs)] \(dateStr) (\(roleTag))\n\(snippetText)"
        }.joined(separator: "\n\n")

        let hint = "Use memory_read with a timestamp value to retrieve the full conversation context (±N turns from that timestamp)."
        print("[MemorySearchTool] Returning page \(safePage + 1) of \(totalPages) (totalItems=\(hits.count))")

        var resultDict: [String: Any] = [
            "results": formatted,
            "page": safePage + 1,
            "totalPages": totalPages,
            "totalItems": hits.count,
            "hint": hint,
        ]

        if safePage + 1 < totalPages {
            resultDict["comment"] = "There are more pages of results. To get the next page, call this tool again with page_index: \(safePage + 2)"
        }

        return ToolJSON.string(from: resultDict)
    }
}
