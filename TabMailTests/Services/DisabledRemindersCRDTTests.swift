/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// All tests share UserDefaults state — must run serially to avoid cross-test interference.
@Suite("DisabledRemindersStore CRDT", .serialized)
struct DisabledRemindersCRDTTests {

    private static func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: "disabled_reminders_v2")
        UserDefaults.standard.removeObject(forKey: "disabled_reminders")
        UserDefaults.standard.synchronize()
    }

    private static func seedMap(_ map: [String: DisabledRemindersStore.DisabledEntry]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "disabled_reminders_v2")
            UserDefaults.standard.synchronize()
        }
    }

    private static func isoDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return date.ISO8601Format()
    }

    // MARK: - mergeIncoming

    @Test("Incoming entry newer than local replaces local")
    func incomingNewerWins() {
        Self.cleanDefaults()
        let localTs = "2024-01-01T00:00:00Z"
        let incomingTs = "2024-06-01T00:00:00Z"
        Self.seedMap(["h1": .init(enabled: false, ts: localTs)])

        DisabledRemindersStore.mergeIncoming(["h1": .init(enabled: true, ts: incomingTs)])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["h1"]?.enabled == true)
        #expect(map["h1"]?.ts == incomingTs)
    }

    @Test("Incoming entry older than local preserves local")
    func localNewerPreserved() {
        Self.cleanDefaults()
        let localTs = "2024-06-01T00:00:00Z"
        let incomingTs = "2024-01-01T00:00:00Z"
        Self.seedMap(["h1": .init(enabled: false, ts: localTs)])

        DisabledRemindersStore.mergeIncoming(["h1": .init(enabled: true, ts: incomingTs)])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["h1"]?.enabled == false)
        #expect(map["h1"]?.ts == localTs)
    }

    @Test("New hash from incoming is added")
    func newHashAdded() {
        Self.cleanDefaults()
        Self.seedMap(["h1": .init(enabled: false, ts: "2024-01-01T00:00:00Z")])

        DisabledRemindersStore.mergeIncoming(["h2": .init(enabled: false, ts: "2024-03-01T00:00:00Z")])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map.count == 2)
        #expect(map["h1"] != nil)
        #expect(map["h2"] != nil)
    }

    @Test("Empty incoming map causes no changes")
    func emptyIncomingNoOp() {
        Self.cleanDefaults()
        Self.seedMap(["h1": .init(enabled: false, ts: "2024-01-01T00:00:00Z")])

        DisabledRemindersStore.mergeIncoming([:])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map.count == 1)
        #expect(map["h1"]?.ts == "2024-01-01T00:00:00Z")
    }

    @Test("Mixed newer and older entries merge correctly")
    func mixedPartialMerge() {
        Self.cleanDefaults()
        Self.seedMap([
            "h1": .init(enabled: false, ts: "2024-03-01T00:00:00Z"),
            "h2": .init(enabled: true, ts: "2024-06-01T00:00:00Z"),
            "h3": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
        ])

        DisabledRemindersStore.mergeIncoming([
            "h1": .init(enabled: true, ts: "2024-09-01T00:00:00Z"),   // newer → adopt
            "h2": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),  // older → keep local
            "h4": .init(enabled: false, ts: "2024-05-01T00:00:00Z"),  // new → add
        ])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["h1"]?.enabled == true)
        #expect(map["h1"]?.ts == "2024-09-01T00:00:00Z")
        #expect(map["h2"]?.enabled == true)
        #expect(map["h2"]?.ts == "2024-06-01T00:00:00Z")
        #expect(map["h3"]?.enabled == false)
        #expect(map["h4"]?.enabled == false)
        #expect(map.count == 4)
    }

    @Test("Merge into empty local map adopts all incoming")
    func mergeIntoEmpty() {
        Self.cleanDefaults()

        DisabledRemindersStore.mergeIncoming([
            "a": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
            "b": .init(enabled: true, ts: "2024-02-01T00:00:00Z"),
        ])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map.count == 2)
        #expect(map["a"]?.enabled == false)
        #expect(map["b"]?.enabled == true)
    }

    // MARK: - gcStaleEntries

    @Test("Entry not in freshHashes and older than 90 days is removed")
    func staleOrphanRemoved() {
        Self.cleanDefaults()
        Self.seedMap(["old": .init(enabled: false, ts: Self.isoDate(daysAgo: 100))])

        DisabledRemindersStore.gcStaleEntries(freshHashes: [])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["old"] == nil)
    }

    @Test("Entry not in freshHashes but younger than 90 days is kept")
    func recentOrphanKept() {
        Self.cleanDefaults()
        Self.seedMap(["recent": .init(enabled: false, ts: Self.isoDate(daysAgo: 30))])

        DisabledRemindersStore.gcStaleEntries(freshHashes: [])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["recent"] != nil)
    }

    @Test("Entry in freshHashes is kept even if old")
    func freshOldEntryKept() {
        Self.cleanDefaults()
        Self.seedMap(["pinned": .init(enabled: false, ts: Self.isoDate(daysAgo: 200))])

        DisabledRemindersStore.gcStaleEntries(freshHashes: ["pinned"])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["pinned"] != nil)
    }

    @Test("Empty map does not crash")
    func emptyMapNoOp() {
        Self.cleanDefaults()
        DisabledRemindersStore.gcStaleEntries(freshHashes: ["anything"])
        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map.isEmpty)
    }

    @Test("Mixed stale and fresh entries — correct partial GC")
    func mixedGC() {
        Self.cleanDefaults()
        Self.seedMap([
            "stale1": .init(enabled: false, ts: Self.isoDate(daysAgo: 100)),
            "stale2": .init(enabled: true, ts: Self.isoDate(daysAgo: 120)),
            "recent": .init(enabled: false, ts: Self.isoDate(daysAgo: 10)),
            "oldButFresh": .init(enabled: false, ts: Self.isoDate(daysAgo: 200)),
        ])

        DisabledRemindersStore.gcStaleEntries(freshHashes: ["oldButFresh"])

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["stale1"] == nil)
        #expect(map["stale2"] == nil)
        #expect(map["recent"] != nil)
        #expect(map["oldButFresh"] != nil)
        #expect(map.count == 2)
    }

    // MARK: - getDisabledHashes

    @Test("Returns only hashes where enabled is false")
    func onlyDisabledReturned() {
        Self.cleanDefaults()
        Self.seedMap([
            "dis1": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
            "en1": .init(enabled: true, ts: "2024-01-01T00:00:00Z"),
            "dis2": .init(enabled: false, ts: "2024-02-01T00:00:00Z"),
        ])

        let hashes = DisabledRemindersStore.getDisabledHashes()
        #expect(hashes == Set(["dis1", "dis2"]))
    }

    @Test("Empty map returns empty set")
    func emptyMapEmptySet() {
        Self.cleanDefaults()
        let hashes = DisabledRemindersStore.getDisabledHashes()
        #expect(hashes.isEmpty)
    }

    @Test("All enabled entries returns empty set")
    func allEnabledEmpty() {
        Self.cleanDefaults()
        Self.seedMap([
            "a": .init(enabled: true, ts: "2024-01-01T00:00:00Z"),
            "b": .init(enabled: true, ts: "2024-02-01T00:00:00Z"),
        ])

        let hashes = DisabledRemindersStore.getDisabledHashes()
        #expect(hashes.isEmpty)
    }

    // MARK: - setEnabled

    @Test("Setting disabled creates entry with enabled=false")
    func setDisabled() {
        Self.cleanDefaults(); defer { Self.cleanDefaults() }
        DisabledRemindersStore.setEnabled(hash: "test1", enabled: false)

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["test1"]?.enabled == false)
        #expect(map["test1"]?.ts != nil)
    }

    @Test("Setting enabled creates tombstone entry with enabled=true")
    func setEnabledTombstone() {
        Self.cleanDefaults(); defer { Self.cleanDefaults() }
        DisabledRemindersStore.setEnabled(hash: "test2", enabled: true)

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map["test2"]?.enabled == true)
    }

    @Test("Overwrites existing entry with new timestamp")
    func overwritesExisting() {
        Self.cleanDefaults(); defer { Self.cleanDefaults() }
        let key = "overwrite_\(UUID().uuidString.prefix(8))"
        let oldTs = "2020-01-01T00:00:00Z"
        Self.seedMap([key: .init(enabled: false, ts: oldTs)])

        DisabledRemindersStore.setEnabled(hash: key, enabled: true)

        let map = DisabledRemindersStore.getDisabledMap()
        #expect(map[key]?.enabled == true)
        #expect(map[key]?.ts != oldTs)
    }

    @Test("Sets timestamp close to current time")
    func timestampIsCurrent() {
        Self.cleanDefaults(); defer { Self.cleanDefaults() }
        let before = Date()
        DisabledRemindersStore.setEnabled(hash: "ts_test", enabled: false)
        let after = Date()

        let map = DisabledRemindersStore.getDisabledMap()
        let entryDate = Date.fromISO8601(map["ts_test"]!.ts)!
        #expect(entryDate >= before.addingTimeInterval(-1))
        #expect(entryDate <= after.addingTimeInterval(1))
    }
}
