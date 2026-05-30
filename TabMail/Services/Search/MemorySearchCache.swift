/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Per-user-turn pagination cache for `MemorySearchTool`.
/// Mirrors TB `memory_search.js:9-41` `searchSessions` map.
///
/// Reset at the start of each user message (top of
/// `AIService.sendChatMessage` / `AIChat.swift:23`) so paginated calls within
/// one turn reuse the cached hit list, but a new turn starts fresh.
actor MemorySearchCache {
    static let shared = MemorySearchCache()

    private var sessions: [String: [MemoryHit]] = [:]

    /// Look up cached hits for a normalized-args JSON key.
    func get(_ key: String) -> [MemoryHit]? {
        sessions[key]
    }

    /// Store hits for a normalized-args JSON key.
    func set(_ key: String, _ hits: [MemoryHit]) {
        sessions[key] = hits
    }

    /// Reset all caches. Called from `AIService.sendChatMessage` top.
    func reset() {
        sessions.removeAll()
    }

    /// Build the cache key the way TB does in `memory_search.js:27-30`:
    /// JSON-encoded normalized args (query / from_date / to_date).
    static func makeKey(query: String, fromDate: String?, toDate: String?) -> String {
        // Sort-order-stable JSON via explicit key layout (matches TB's JSON.stringify
        // on a three-key object).
        let q = escape(query.trimmingCharacters(in: .whitespaces))
        let f = escape(fromDate ?? "")
        let t = escape(toDate ?? "")
        return "{\"query\":\"\(q)\",\"from_date\":\"\(f)\",\"to_date\":\"\(t)\"}"
    }

    /// JSON string escape — backslashes and double quotes. Enough for the three
    /// string fields we encode; tool args are user-entered text, not untrusted JSON.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Test hooks

extension MemorySearchCache {
    /// Returns the number of cached keys. Used by tests to assert reset cleared state.
    func _testKeyCount() -> Int { sessions.count }
}
