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
    /// The field's Device Sync timestamp (`DeviceSyncService.TimestampKey.disabledReminders`).
    private static let fieldTimestampKey = "device_sync_ts:disabledReminders"

    /// Demo-scoped map key (ADR-IOS-038). Deleted on demo exit by
    /// `DemoModeService`. Public so the service can remove it.
    static let demoStorageKeyV2 = "demo.disabled_reminders_v2"

    /// Active map key: demo mode operates entirely on its own (initially
    /// empty) map so demo dismiss/snooze never touches — or broadcasts —
    /// the real user's disabled-reminder state. Follows the live mode (DS-DEMO): a transaction reads it under
    /// the map lock, where the mode cannot change (`switching`).
    private static var currentKey: String {
        DemoModeStore.isDemoActive ? demoStorageKeyV2 : storageKeyV2
    }

    /// GC age threshold — entries not in fresh set and older than this are removed.
    private static let gcAgeDays = 90

    /// Hash namespace this device can no longer derive — see `gcStaleEntries`.
    /// Scheduled tasks are not parsed or executed here (ADR-IOS-079), so no `t:`
    /// hash can ever be produced locally.
    private static let nonDerivableHashPrefix = "t:"

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

    // MARK: - Map transaction lock

    /// Every writer replaces the WHOLE map (read, change, encode, save), and the
    /// writers run on different threads: the user toggles on the MainActor, a
    /// Device Sync receive merges on the MainActor, and `ReminderBuilder`'s detached
    /// rebuild runs `bulkDisableWithEpochZero` and `gcStaleEntries` off it. Without a
    /// single line through the map, an older writer saves its captured copy over a
    /// newer writer's entry, and an absent entry means ENABLED, so the user's disable
    /// is lost for good. Each writer therefore holds this lock for its WHOLE
    /// transaction and decides from the map it reads under the lock. No transaction
    /// calls another, so the lock is not recursive.
    private static let mapLock = NSLock()

    private static func transaction<T>(_ body: () -> T) -> T {
        mapLock.lock()
        defer { mapLock.unlock() }
        return body()
    }

    /// DS-DEMO: whether the change counter moved since a multi-step writer read it (the existing DS-AI
    /// compare). Checked inside the transaction, where the mode and the counter change together only in
    /// `switching`, so a write that started before a demo switch never lands after it. Nil is a brief
    /// writer, which reads and writes with no await between.
    private static func moved(since started: UUID?) -> Bool {
        guard let started else { return false }
        return ChangeCounter.device.current != started
    }

    /// DS-DEMO: the demo is entered or left. `flip` sets the mode and moves the change counter; both happen
    /// under the map lock, so no transaction sees the new mode with the old counter. Leaving also deletes
    /// the demo's map, after the flip.
    static func switching(toDemo entering: Bool, _ flip: () -> Void) {
        transaction {
            flip()
            if !entering { defaults.removeObject(forKey: demoStorageKeyV2) }
        }
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

    /// Get the full CRDT map in the live mode: the real choices, or the demo's own.
    static func getDisabledMap() -> [String: DisabledEntry] {
        getDisabledMap(key: currentKey)
    }

    /// Deletes the demo's map when no demo is running (the launch wipe of a force-quit demo's leftovers,
    /// and the start of a demo). A demo's exit deletes it in `switching`.
    static func removeDemoMap() {
        transaction { defaults.removeObject(forKey: demoStorageKeyV2) }
    }

    /// Keyed load: the caller passes the key it is working on, read in the same transaction as the save.
    ///
    /// A device with only the v1 list (no v2 map yet) reads it as the real map: every hash disabled, each
    /// at the field's Device Sync timestamp (epoch zero when it has none), as TB's `readStoredField` does.
    /// The next change to the real map stores it as v2. Nothing migrates, so no transaction decides by
    /// the mode whether to; the choice is the key.
    private static func getDisabledMap(key: String) -> [String: DisabledEntry] {
        guard let data = defaults.data(forKey: key) else {
            return key == storageKeyV2 ? legacyMap() : [:]
        }
        guard let map = try? JSONDecoder().decode([String: DisabledEntry].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func legacyMap() -> [String: DisabledEntry] {
        let ts = defaults.string(forKey: fieldTimestampKey) ?? Bullets.epochZero
        var map: [String: DisabledEntry] = [:]
        for hash in defaults.stringArray(forKey: storageKeyV1) ?? [] {
            map[hash] = DisabledEntry(enabled: false, ts: ts)
        }
        return map
    }

    /// Save the CRDT map.
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
    /// A writer that awaited between its start and this write passes the change counter it started with
    /// (`since`, DS-DEMO): false when that moved, and nothing was written.
    @discardableResult
    static func setEnabled(hash: String, enabled: Bool, since started: UUID? = nil) -> Bool {
        let written: (map: [String: DisabledEntry], demo: Bool)? = transaction {
            guard !moved(since: started) else { return nil }
            let key = currentKey
            var map = getDisabledMap(key: key)
            map[hash] = DisabledEntry(enabled: enabled, ts: Date().ISO8601Format())
            saveDisabledMap(map, key: key)
            return (map, key == demoStorageKeyV2)
        }
        guard let (map, demo) = written else {
            BackgroundSyncLogger.logDebug("[DisabledRemindersStore] A change for \(hash) was refused: the demo was entered or left since it started")
            return false
        }
        BackgroundSyncLogger.logDebug("[DisabledRemindersStore] Set \(hash) enabled=\(enabled) (disabled count: \(map.filter { !$0.value.enabled }.count))")

        // Broadcast to Device Sync peers. Demo dismiss/snooze stays local to
        // the demo map — broadcasting would also stamp the real
        // device_sync_ts:disabledReminders bookkeeping.
        if !demo {
            Task { @MainActor in
                DeviceSyncService.shared.debouncedBroadcast(fields: [.disabledReminders])
            }
        }

        // Notify local observers (chat pill regenerates reminders)
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        return true
    }

    /// CRDT merge: per-hash, newer timestamp wins.
    /// Does NOT trigger a broadcast (used for incoming Device Sync).
    static func mergeIncoming(_ incomingMap: [String: DisabledEntry]) {
        let (merged, total) = transaction { () -> (Int, Int) in
            let key = currentKey
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
            return (merged, localMap.count)
        }
        BackgroundSyncLogger.logDebug("[DisabledRemindersStore] CRDT merge: \(merged) entries adopted from \(incomingMap.count) incoming (local total: \(total))")
    }

    /// Bulk-disable hashes with epoch-zero timestamps. Used by first-launch overdue
    /// suppression so that any Device Sync state (real timestamps) always wins in CRDT merge.
    /// Does NOT broadcast to Device Sync or post notifications — caller handles that.
    /// False when `since` moved (see `setEnabled`): nothing was written.
    @discardableResult
    static func bulkDisableWithEpochZero(hashes: [String], since started: UUID? = nil) -> Bool {
        guard !hashes.isEmpty else { return true }
        let epochZero = "1970-01-01T00:00:00Z"
        let written = transaction { () -> Bool in
            guard !moved(since: started) else { return false }
            let key = currentKey
            var map = getDisabledMap(key: key)
            for hash in hashes {
                // Only write if no existing entry — preserve any prior state from sync/user action
                if map[hash] == nil {
                    map[hash] = DisabledEntry(enabled: false, ts: epochZero)
                }
            }
            saveDisabledMap(map, key: key)
            return true
        }
        guard written else { return false }
        BackgroundSyncLogger.logDebug("[DisabledRemindersStore] Bulk-disabled \(hashes.count) hashes with epoch-zero timestamps")
        return true
    }

    /// Time-based GC: remove entries NOT in fresh set AND older than gcAgeDays.
    /// Replaces the old aggressive `syncState()` which immediately removed orphans.
    ///
    /// **Invariant: GC only collects hash namespaces this device can re-derive.**
    /// An absent entry means ENABLED, so deleting one asserts "the user never disabled
    /// this". That inference is sound only for a prefix this device can still PRODUCE
    /// into `freshHashes`; for any other prefix, "not fresh" means "not computable
    /// here", never "no longer exists".
    ///
    /// `t:` (scheduled-task) hashes are exactly that case. Tasks are not parsed on this
    /// platform, so a `t:` hash can never enter `freshHashes` and every such entry would
    /// otherwise age out. That state only ever arrives from a peer, and the transport
    /// keeps no copy — if this device holds the surviving one, collecting it discards
    /// the user's disable permanently and the task defaults back to enabled elsewhere.
    /// Deleting this guard reintroduces that loss.
    ///
    /// The guard is deliberately unconditional: `t:` entries are retained forever here.
    /// They are tiny, and the platform that does derive them still collects them on its
    /// own side, so nothing is gained by trying to decide when one is "really" stale.
    /// False when `since` moved (see `setEnabled`): nothing was collected.
    @discardableResult
    static func gcStaleEntries(freshHashes: Set<String>, since started: UUID? = nil) -> Bool {
        let now = Date()
        let result = transaction { () -> Int? in
            guard !moved(since: started) else { return nil }
            let key = currentKey
            var map = getDisabledMap(key: key)
            guard !map.isEmpty else { return 0 }
            var removed = 0

            for (hash, entry) in map {
                guard !hash.hasPrefix(nonDerivableHashPrefix) else { continue }
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
            }
            return removed
        }
        guard let removed = result else { return false }
        if removed > 0 {
            BackgroundSyncLogger.logDebug("[DisabledRemindersStore] GC removed \(removed) entries older than \(gcAgeDays) days")
        }
        return true
    }
}
