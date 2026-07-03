/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Minimal state store for disabled reminders.
/// Port of TB's `reminderStateStore.js`. UserDefaults-backed, synced via Device Sync.
///
/// **v2 CRDT format**: Stores `{hash: {enabled: Bool, ts: ISO8601}}` map instead of `[String]` array.
/// Per-hash timestamps enable convergent merge (newer ts wins per hash).
/// `enabled: false` = disabled, `enabled: true` = re-enabled (tombstone), absent = enabled (default).
///
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum DisabledRemindersStore {

    private static let storageKeyV1 = "disabled_reminders"
    private static let storageKeyV2 = "disabled_reminders_v2"

    /// Demo-scoped map key (ADR-IOS-038). Deleted on demo exit by
    /// `DemoModeService`. Public so the service can remove it.
    static let demoStorageKeyV2 = "demo.disabled_reminders_v2"

    /// Active map key: demo mode operates entirely on its own (initially
    /// empty) map so demo dismiss/snooze never touches — or broadcasts —
    /// the real user's disabled-reminder state.
    private static var activeKeyV2: String {
        DemoModeStore.isDemoActive ? demoStorageKeyV2 : storageKeyV2
    }

    /// GC age threshold — entries not in fresh set and older than this are removed.
    private static let gcAgeDays = 90

    // MARK: - Test-Only Defaults Injection

    /// `UserDefaults` is documented thread-safe; the wrapper just makes it `Sendable`
    /// for storage in a `@TaskLocal`.
    private final class DefaultsRef: @unchecked Sendable {
        let value: UserDefaults
        init(_ value: UserDefaults) { self.value = value }
    }

    /// Per-task override of the backing `UserDefaults`. `@TaskLocal` (rather than a
    /// process-global slot) is critical: Swift Testing runs suites in parallel, and
    /// a global override leaks the test's isolated defaults into unrelated parallel
    /// suites that touch this store. TaskLocal scopes the override to the test's
    /// own Task tree (including child Tasks spawned for Device Sync broadcasts),
    /// so parallel suites without an override naturally fall back to `.standard`.
    @TaskLocal private static var taskLocalTestDefaults: DefaultsRef?

    /// Test-only hook. Runs `body` with the store's backing `UserDefaults`
    /// overridden to `defaults`. Production never calls this.
    static func withTestDefaults<T>(_ defaults: UserDefaults?, _ body: () throws -> T) rethrows -> T {
        try $taskLocalTestDefaults.withValue(defaults.map(DefaultsRef.init), operation: body)
    }

    /// Current backing `UserDefaults`. Returns the per-task test override if set,
    /// otherwise `UserDefaults.standard`.
    static var defaults: UserDefaults {
        taskLocalTestDefaults?.value ?? .standard
    }

    // MARK: - CRDT Entry

    struct DisabledEntry: Codable, Sendable {
        let enabled: Bool
        let ts: String // ISO8601
    }

    // MARK: - Hashing

    /// Generate a stable hash for a reminder.
    /// - Message reminders: `m:{rfc2822MessageId}` (cross-platform, bracket-stripped)
    ///   Fallback: `m:{uniqueId}` (platform-specific, won't dedup cross-platform)
    /// - KB reminders: `k:{djb2hash}` (content-based, already cross-platform)
    /// - Fallback: `o:{first32chars}`
    /// Matches TB's `hashReminder()`.
    static func hashReminder(source: String, content: String, uniqueId: String?, rfc822MessageId: String? = nil) -> String {
        if source == "message" {
            // Prefer shared cross-platform hash using RFC 2822 Message-ID
            if let rfc822 = rfc822MessageId, !rfc822.isEmpty {
                let cleaned = rfc822.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                return "m:\(cleaned)"
            }
            // Fallback: platform-specific (won't dedup cross-platform)
            if let uid = uniqueId {
                return "m:\(uid)"
            }
        } else if source == "kb" {
            let hash = djb2Hash(content)
            return "k:\(String(hash, radix: 36))"
        }
        // Fallback
        return "o:\(String(content.prefix(32)))"
    }

    /// DJB2 hash matching TB's implementation:
    /// `hash = ((hash << 5) - hash) + charCode; hash = hash & hash`
    /// Uses UTF-16 code units to match JS `String.charCodeAt()` behavior
    /// (surrogate pairs for non-BMP characters produce two hash iterations).
    static func djb2Hash(_ str: String) -> Int32 {
        var hash: Int32 = 0
        for codeUnit in str.utf16 {
            let charCode = Int32(codeUnit)
            hash = ((hash << 5) &- hash) &+ charCode
        }
        return hash
    }

    // MARK: - Read/Write (v2 CRDT Map)

    /// Migrate v1 array to v2 map on first access.
    private static func migrateIfNeeded() {
        // Never migrate into (or based on) the demo map.
        guard !DemoModeStore.isDemoActive else { return }
        let d = defaults
        guard d.data(forKey: storageKeyV2) == nil else { return }

        let oldHashes = d.stringArray(forKey: storageKeyV1) ?? []
        if !oldHashes.isEmpty {
            let now = Date().ISO8601Format()
            var map: [String: DisabledEntry] = [:]
            for hash in oldHashes {
                map[hash] = DisabledEntry(enabled: false, ts: now)
            }
            saveDisabledMap(map, key: storageKeyV2)
            print("[DisabledRemindersStore] Migrated \(oldHashes.count) entries from v1 to v2 CRDT format")
        }
    }

    /// Get the full CRDT map.
    static func getDisabledMap() -> [String: DisabledEntry] {
        getDisabledMap(key: activeKeyV2)
    }

    /// Keyed load — read-modify-write callers capture `activeKeyV2` ONCE and
    /// pass it to both load and save, so a demo entry/exit flipping the mode
    /// between the read and the write can't route a real map into the demo
    /// key (or vice versa).
    private static func getDisabledMap(key: String) -> [String: DisabledEntry] {
        migrateIfNeeded()
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: DisabledEntry].self, from: data) else {
            return [:]
        }
        return map
    }

    /// Save the CRDT map (see getDisabledMap(key:) for the key contract).
    private static func saveDisabledMap(_ map: [String: DisabledEntry], key: String) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    /// Get set of disabled hashes (entries where enabled == false).
    /// Matches TB's `getDisabledHashes()`.
    static func getDisabledHashes() -> Set<String> {
        let map = getDisabledMap()
        return Set(map.filter { !$0.value.enabled }.map(\.key))
    }

    /// Set enabled/disabled for a hash (idempotent).
    /// Writes a CRDT entry with current timestamp.
    /// Matches TB's `setEnabled()`.
    /// Broadcasts change to Device Sync peers (local user action).
    static func setEnabled(hash: String, enabled: Bool) {
        let key = activeKeyV2  // captured once — see getDisabledMap(key:)
        var map = getDisabledMap(key: key)
        map[hash] = DisabledEntry(enabled: enabled, ts: Date().ISO8601Format())
        saveDisabledMap(map, key: key)
        print("[DisabledRemindersStore] Set \(hash) enabled=\(enabled) (disabled count: \(map.filter { !$0.value.enabled }.count))")

        // Broadcast to Device Sync peers. Demo dismiss/snooze stays local to
        // the demo map — broadcasting would also stamp the real
        // device_sync_ts:disabledReminders bookkeeping.
        if !DemoModeStore.isDemoActive {
            Task { @MainActor in
                DeviceSyncService.shared.debouncedBroadcast(fields: [.disabledReminders])
            }
        }

        // Notify local observers (chat pill regenerates reminders)
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
    }

    /// CRDT merge: per-hash, newer timestamp wins.
    /// Does NOT trigger a broadcast (used for incoming Device Sync).
    static func mergeIncoming(_ incomingMap: [String: DisabledEntry]) {
        let key = activeKeyV2  // captured once — see getDisabledMap(key:)
        var localMap = getDisabledMap(key: key)
        var merged = 0

        for (hash, inEntry) in incomingMap {
            if let localEntry = localMap[hash] {
                if inEntry.ts > localEntry.ts {
                    localMap[hash] = inEntry
                    merged += 1
                }
            } else {
                localMap[hash] = inEntry
                merged += 1
            }
        }

        if merged > 0 {
            saveDisabledMap(localMap, key: key)
        }
        print("[DisabledRemindersStore] CRDT merge: \(merged) entries adopted from \(incomingMap.count) incoming (local total: \(localMap.count))")
    }

    /// Bulk-disable hashes with epoch-zero timestamps. Used by first-launch overdue
    /// suppression so that any Device Sync state (real timestamps) always wins in CRDT merge.
    /// Does NOT broadcast to Device Sync or post notifications — caller handles that.
    static func bulkDisableWithEpochZero(hashes: [String]) {
        guard !hashes.isEmpty else { return }
        let key = activeKeyV2  // captured once — see getDisabledMap(key:)
        var map = getDisabledMap(key: key)
        let epochZero = "1970-01-01T00:00:00Z"
        for hash in hashes {
            // Only write if no existing entry — preserve any prior state from sync/user action
            if map[hash] == nil {
                map[hash] = DisabledEntry(enabled: false, ts: epochZero)
            }
        }
        saveDisabledMap(map, key: key)
        print("[DisabledRemindersStore] Bulk-disabled \(hashes.count) hashes with epoch-zero timestamps")
    }

    /// Time-based GC: remove entries NOT in fresh set AND older than gcAgeDays.
    /// Replaces the old aggressive `syncState()` which immediately removed orphans.
    static func gcStaleEntries(freshHashes: Set<String>) {
        let key = activeKeyV2  // captured once — see getDisabledMap(key:)
        var map = getDisabledMap(key: key)
        guard !map.isEmpty else { return }

        let now = Date()
        var removed = 0

        for (hash, entry) in map {
            if !freshHashes.contains(hash) {
                if let entryDate = Date.fromISO8601(entry.ts),
                   now.timeIntervalSince(entryDate) > Double(gcAgeDays * 86400) {
                    map.removeValue(forKey: hash)
                    removed += 1
                }
            }
        }

        if removed > 0 {
            saveDisabledMap(map, key: key)
            print("[DisabledRemindersStore] GC removed \(removed) entries older than \(gcAgeDays) days")
        }
    }
}
