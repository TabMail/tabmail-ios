/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Tracks which reminders have already triggered notifications, preventing duplicates.
/// Port of TB's `reached_out_ids` in `reminderStateStore.js`.
/// UserDefaults-backed. Keyed by reminder hash (e.g., "m:rfc822Id" or "k:djb2Hash").
/// Each reminder notifies at most once. Entries have a 48h TTL to survive sync
/// fluctuations (messages moving, reprocessing, re-syncs) without premature eviction.
///
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum ReachedOutStore {

    private static let storageKey = "proactive.reached_out_ids"

    /// 48h TTL — entries survive sync fluctuations but don't accumulate forever.
    private static let ttlSeconds: TimeInterval = 48 * 3600

    struct Entry: Codable, Sendable {
        let notifiedAt: Date
    }

    // MARK: - Read/Write

    static func getAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveAll(_ map: [String: Entry]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Check / Record

    /// Check if a reminder has already been notified (within TTL).
    static func hasNotified(hash: String) -> Bool {
        guard let entry = getAll()[hash] else { return false }
        // Expired entries don't count
        return Date().timeIntervalSince(entry.notifiedAt) < ttlSeconds
    }

    /// Bulk check: returns the set of hashes that have been notified (within TTL).
    /// Avoids N full JSON decodes when checking multiple hashes.
    static func notifiedHashes(from hashes: [String]) -> Set<String> {
        let map = getAll()
        let now = Date()
        var result = Set<String>()
        for hash in hashes {
            if let entry = map[hash], now.timeIntervalSince(entry.notifiedAt) < ttlSeconds {
                result.insert(hash)
            }
        }
        return result
    }

    /// Record that a notification was delivered for this reminder.
    static func markNotified(hash: String) {
        var map = getAll()
        map[hash] = Entry(notifiedAt: Date())
        saveAll(map)
    }

    /// Refresh TTL for all hashes that are still in the active reminder list.
    /// This prevents entries from expiring while the reminder is still alive —
    /// the TTL only matters for reminders that have genuinely disappeared.
    static func refreshActive(hashes: Set<String>) {
        var map = getAll()
        let now = Date()
        var refreshed = 0
        for hash in hashes {
            if map[hash] != nil {
                map[hash] = Entry(notifiedAt: now)
                refreshed += 1
            }
        }
        if refreshed > 0 {
            saveAll(map)
            print("[ReachedOutStore] Refreshed TTL for \(refreshed) active entries")
        }
    }

    // MARK: - Pruning

    /// Remove entries older than TTL. Called periodically to keep storage clean.
    static func prune() {
        var map = getAll()
        let before = map.count
        let cutoff = Date().addingTimeInterval(-ttlSeconds)
        map = map.filter { _, entry in
            entry.notifiedAt > cutoff
        }
        let removed = before - map.count
        if removed > 0 {
            saveAll(map)
            print("[ReachedOutStore] Pruned \(removed) expired entries")
        }
    }
}
