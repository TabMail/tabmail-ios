/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Persistent cache for task execution results.
/// Port of TB's `taskExecutionCache.js` — UserDefaults-backed, synced via Device Sync.
///
/// Keyed by `{taskHash}_{YYYY-MM-DD}`. Stores content, sessionId, and timestamp.
/// Occurrence-based eviction: max 10 entries per taskHash.
///
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
actor TaskExecutionCache {

    static let shared = TaskExecutionCache()

    // MARK: - Types

    struct CacheEntry: Codable, Sendable {
        let content: String
        let sessionId: String
        let ts: String  // ISO8601 timestamp
    }

    // MARK: - Constants

    private let storageKey = "task_execution_cache"
    private let maxEntriesPerTask = 10
    private let gcAgeDays = 90

    // MARK: - In-Memory Mirror

    private var memoryCache: [String: CacheEntry]?

    // MARK: - Public API

    /// Get cached result for a task on a specific date.
    func getCachedResult(taskHash: String, date: String) -> CacheEntry? {
        let cache = loadCache()
        let key = cacheKey(taskHash: taskHash, date: date)
        return cache[key]
    }

    /// Store result, evict if >10 entries per task (occurrence-based).
    func setCachedResult(taskHash: String, date: String, content: String, sessionId: String) {
        var cache = loadCache()
        let key = cacheKey(taskHash: taskHash, date: date)

        cache[key] = CacheEntry(
            content: content,
            sessionId: sessionId,
            ts: Date().ISO8601Format()
        )

        evictExcessEntries(&cache, taskHash: taskHash)
        saveCache(cache)
        print("[TaskCache] Cached result for \(key)")
    }

    /// Get all entries (for Device Sync broadcast).
    func getAllCachedResults() -> [String: CacheEntry] {
        return loadCache()
    }

    /// CRDT merge from incoming Device Sync (newer timestamp wins, NO broadcast).
    func mergeIncoming(_ incoming: [String: CacheEntry]) {
        var cache = loadCache()
        var merged = 0

        for (key, inEntry) in incoming {
            guard !inEntry.ts.isEmpty else { continue }

            if let localEntry = cache[key] {
                if inEntry.ts > localEntry.ts {
                    cache[key] = inEntry
                    merged += 1
                }
            } else {
                cache[key] = inEntry
                merged += 1
            }
        }

        if merged > 0 {
            saveCache(cache)
        }

        print("[TaskCache] CRDT merge: \(merged) entries adopted from \(incoming.count) incoming (local total: \(cache.count))")
    }

    /// GC orphaned entries (tasks no longer in KB, 90-day threshold).
    func gcOrphanedEntries(activeTaskHashes: Set<String>) {
        var cache = loadCache()
        guard !cache.isEmpty else { return }

        let now = Date()
        let maxAge = Double(gcAgeDays * 86400)
        var removed = 0

        for (key, entry) in cache {
            // Extract taskHash from composite key "taskHash_YYYY-MM-DD"
            // taskHash format is "t:xxxx" (or legacy "c:xxxx"), so find the last underscore
            // that precedes a date pattern
            guard let taskHash = extractTaskHash(from: key) else {
                // Malformed key, remove it
                cache.removeValue(forKey: key)
                removed += 1
                continue
            }

            if activeTaskHashes.contains(taskHash) { continue }

            if let entryDate = Date.fromISO8601(entry.ts),
               now.timeIntervalSince(entryDate) > maxAge {
                cache.removeValue(forKey: key)
                removed += 1
            }
        }

        if removed > 0 {
            saveCache(cache)
            print("[TaskCache] GC removed \(removed) orphaned entries older than \(gcAgeDays) days")
        }
    }

    // MARK: - Private Helpers

    private func cacheKey(taskHash: String, date: String) -> String {
        return "\(taskHash)_\(date)"
    }

    /// Extract taskHash from composite key "taskHash_YYYY-MM-DD".
    /// The date portion is always the last 10 characters after the last underscore
    /// that matches a date pattern.
    private func extractTaskHash(from key: String) -> String? {
        // Date is always "YYYY-MM-DD" (10 chars) at the end after "_"
        // Key format: "t:xxxx_2026-03-27" or legacy "c:xxxx_2026-03-27"
        guard key.count > 11 else { return nil }
        let underscoreIndex = key.index(key.endIndex, offsetBy: -11)
        guard key[underscoreIndex] == "_" else { return nil }
        return String(key[key.startIndex..<underscoreIndex])
    }

    /// Evict oldest entries for a given taskHash if count exceeds maxEntriesPerTask.
    private func evictExcessEntries(_ cache: inout [String: CacheEntry], taskHash: String) {
        let prefix = "\(taskHash)_"
        let matchingKeys = cache.keys.filter { $0.hasPrefix(prefix) }

        guard matchingKeys.count > maxEntriesPerTask else { return }

        // Sort by timestamp ascending (oldest first)
        let sorted = matchingKeys.sorted { a, b in
            let tsA = cache[a]?.ts ?? ""
            let tsB = cache[b]?.ts ?? ""
            return tsA < tsB
        }

        let toRemove = sorted.count - maxEntriesPerTask
        for i in 0..<toRemove {
            cache.removeValue(forKey: sorted[i])
        }

        print("[TaskCache] Evicted \(toRemove) old entries for \(taskHash)")
    }

    // MARK: - Persistence

    private func loadCache() -> [String: CacheEntry] {
        if let cached = memoryCache {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            memoryCache = [:]
            return [:]
        }

        memoryCache = map
        return map
    }

    private func saveCache(_ cache: [String: CacheEntry]) {
        memoryCache = cache
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
