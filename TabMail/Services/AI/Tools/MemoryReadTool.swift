/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `memory_read` tool matching TB addon's `memory_read.js`.
/// v3: returns a contiguous window of turns centered on the turn closest to
/// the requested timestamp, bounded to the matched turn's session. Matches
/// TB's per-turn context-window behavior.
///
/// See ADR-IOS-034.
struct MemoryReadTool: AgentTool, Sendable {
    let name = "memory_read"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Parse required timestamp (epoch ms).
        let timestampMs: Double
        if case .int(let t) = arguments["timestamp"] {
            timestampMs = Double(t)
        } else if case .string(let s) = arguments["timestamp"], let t = Double(s) {
            timestampMs = t
        } else {
            return #"{"error": "Invalid or missing timestamp. Use a timestamp value from memory_search results."}"#
        }

        // Parse optional tolerance_minutes.
        let defaultTolMinutes = SearchConfig.memoryReadDefaultToleranceMs / 60_000
        let toleranceMinutes: Int
        if case .int(let t) = arguments["tolerance_minutes"] {
            toleranceMinutes = max(1, t)
        } else if case .string(let s) = arguments["tolerance_minutes"], let t = Int(s) {
            toleranceMinutes = max(1, t)
        } else {
            toleranceMinutes = defaultTolMinutes
        }

        // Parse optional max_turns.
        let maxTurns: Int
        if case .int(let t) = arguments["max_turns"] {
            maxTurns = max(1, t)
        } else if case .string(let s) = arguments["max_turns"], let t = Int(s) {
            maxTurns = max(1, t)
        } else {
            maxTurns = SearchConfig.memoryReadMaxTurns
        }

        let toleranceMs = Int64(toleranceMinutes) * 60 * 1000
        let target = Int64(timestampMs)
        print("[MemoryReadTool] ENTER timestampMs=\(target) toleranceMin=\(toleranceMinutes) maxTurns=\(maxTurns)")

        let hits = await MemoryIndex.shared.readByTimestamp(
            timestampMs: target,
            toleranceMs: toleranceMs,
            maxTurns: maxTurns
        )

        // TB-parity: empty window returns the literal string, NOT JSON (memory_read.js:63).
        if hits.isEmpty {
            print("[MemoryReadTool] EMPTY window — returning TB-parity literal")
            return "No conversation found around this timestamp."
        }

        // Format per-turn with role + date header. Explicit `String` annotations
        // on outer binding AND closure return — same GRDB SQL-interpolation guard
        // as MemorySearchTool (see PROJECT_MEMORY.md pitfall note).
        let formatted: String = hits.map { hit -> String in
            let dateStr = ToolFormatters.formatDateMs(Double(hit.dateMs))
            let roleTag: String = hit.role == "user" ? "USER" : "AGENT"
            let body: String = hit.content.isEmpty ? "(empty)" : hit.content
            return "--- \(dateStr) (\(roleTag)) ---\n\(body)"
        }.joined(separator: "\n\n")

        print("[MemoryReadTool] Returning \(hits.count) turns in context window")

        // TB-parity: success returns raw string, NOT JSON (memory_read.js:109).
        return formatted
    }
}
