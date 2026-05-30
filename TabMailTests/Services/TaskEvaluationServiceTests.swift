/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - TaskTimeoutError Tests

@Suite("TaskTimeoutError")
struct TaskTimeoutErrorTests {

    @Test("TaskTimeoutError conforms to Error")
    func conformsToError() {
        let error: Error = TaskTimeoutError()
        #expect(error is TaskTimeoutError)
    }

    @Test("TaskTimeoutError can be caught in do/catch")
    func catchable() {
        do {
            throw TaskTimeoutError()
        } catch is TaskTimeoutError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - TaskExecutionCache Tests

@Suite("TaskExecutionCache")
struct TaskExecutionCacheTests {

    @Test("getCachedResult returns nil for uncached task")
    func noCacheHit() async {
        let cache = TaskExecutionCache.shared
        let result = await cache.getCachedResult(taskHash: "t:uncached_\(UUID())", date: "2026-04-06")
        #expect(result == nil)
    }

    @Test("setCachedResult then getCachedResult returns value")
    func cacheRoundTrip() async {
        let cache = TaskExecutionCache.shared
        let hash = "t:test_roundtrip_\(UUID())"
        let date = "2026-04-06"

        await cache.setCachedResult(taskHash: hash, date: date, content: "Test result", sessionId: "session:1")

        let result = await cache.getCachedResult(taskHash: hash, date: date)
        #expect(result != nil)
        #expect(result?.content == "Test result")
        #expect(result?.sessionId == "session:1")
    }

    @Test("getCachedResult returns nil for different date")
    func differentDateMiss() async {
        let cache = TaskExecutionCache.shared
        let hash = "t:test_date_\(UUID())"

        await cache.setCachedResult(taskHash: hash, date: "2026-04-06", content: "Result", sessionId: "s1")

        let result = await cache.getCachedResult(taskHash: hash, date: "2026-04-07")
        #expect(result == nil)
    }

    @Test("gcOrphanedEntries keeps fresh orphans (under 90 day threshold)")
    func gcKeepsFreshOrphans() async {
        let cache = TaskExecutionCache.shared
        let activeHash = "t:gc_active_\(UUID())"
        let orphanHash = "t:gc_fresh_orphan_\(UUID())"

        await cache.setCachedResult(taskHash: activeHash, date: "2026-04-06", content: "Active", sessionId: "s1")
        await cache.setCachedResult(taskHash: orphanHash, date: "2026-04-06", content: "Fresh orphan", sessionId: "s2")

        // GC with only activeHash in the set — orphan is fresh so should be KEPT
        await cache.gcOrphanedEntries(activeTaskHashes: Set([activeHash]))

        // Active should still be there
        let activeResult = await cache.getCachedResult(taskHash: activeHash, date: "2026-04-06")
        #expect(activeResult != nil)

        // Fresh orphan should NOT be removed (ts is recent, within 90-day threshold)
        let orphanResult = await cache.getCachedResult(taskHash: orphanHash, date: "2026-04-06")
        #expect(orphanResult != nil)
    }

    @Test("gcOrphanedEntries removes old orphans via mergeIncoming with stale ts")
    func gcRemovesOldOrphans() async {
        let cache = TaskExecutionCache.shared
        let orphanHash = "t:gc_old_orphan_\(UUID())"
        let date = "2025-01-01"

        // Inject an old entry via mergeIncoming (simulating a stale entry from months ago)
        let oldEntry = TaskExecutionCache.CacheEntry(
            content: "Old result",
            sessionId: "s_old",
            ts: "2025-01-01T00:00:00Z"  // > 90 days ago
        )
        await cache.mergeIncoming(["\(orphanHash)_\(date)": oldEntry])

        // Verify it exists
        let before = await cache.getCachedResult(taskHash: orphanHash, date: date)
        #expect(before != nil)

        // GC with empty active set — this old orphan should be removed
        await cache.gcOrphanedEntries(activeTaskHashes: Set())

        let after = await cache.getCachedResult(taskHash: orphanHash, date: date)
        #expect(after == nil)
    }

    @Test("CacheEntry encodes and decodes correctly")
    func cacheEntryRoundTrip() throws {
        let entry = TaskExecutionCache.CacheEntry(
            content: "Task result text",
            sessionId: "task:t:abc123",
            ts: "2026-04-06T09:00:00Z"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TaskExecutionCache.CacheEntry.self, from: data)
        #expect(decoded.content == "Task result text")
        #expect(decoded.sessionId == "task:t:abc123")
        #expect(decoded.ts == "2026-04-06T09:00:00Z")
    }

    @Test("mergeIncoming adopts newer entries")
    func mergeIncomingNewer() async {
        let cache = TaskExecutionCache.shared
        let hash = "t:merge_newer_\(UUID())"
        let date = "2026-04-06"

        // Set local entry with an old timestamp
        await cache.setCachedResult(taskHash: hash, date: date, content: "Old local", sessionId: "s1")

        // Merge incoming with newer timestamp
        let incomingEntry = TaskExecutionCache.CacheEntry(
            content: "New remote",
            sessionId: "s2",
            ts: "2099-01-01T00:00:00Z"
        )
        await cache.mergeIncoming(["\(hash)_\(date)": incomingEntry])

        let result = await cache.getCachedResult(taskHash: hash, date: date)
        #expect(result?.content == "New remote")
        #expect(result?.sessionId == "s2")
    }

    @Test("mergeIncoming does not overwrite newer local entries")
    func mergeIncomingOlder() async {
        let cache = TaskExecutionCache.shared
        let hash = "t:merge_older_\(UUID())"
        let date = "2026-04-06"

        // Set local entry with a very new timestamp
        await cache.setCachedResult(taskHash: hash, date: date, content: "New local", sessionId: "s1")

        // Merge incoming with older timestamp
        let incomingEntry = TaskExecutionCache.CacheEntry(
            content: "Old remote",
            sessionId: "s2",
            ts: "2000-01-01T00:00:00Z"
        )
        await cache.mergeIncoming(["\(hash)_\(date)": incomingEntry])

        let result = await cache.getCachedResult(taskHash: hash, date: date)
        #expect(result?.content == "New local")
    }

    @Test("getAllCachedResults returns stored entries")
    func getAllReturnsEntries() async {
        let cache = TaskExecutionCache.shared
        let hash = "t:getall_\(UUID())"
        await cache.setCachedResult(taskHash: hash, date: "2026-04-06", content: "Entry", sessionId: "s1")

        let all = await cache.getAllCachedResults()
        #expect(all["\(hash)_2026-04-06"] != nil)
        #expect(all["\(hash)_2026-04-06"]?.content == "Entry")
    }
}
