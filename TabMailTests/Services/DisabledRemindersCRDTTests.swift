/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Each test runs against its own isolated `UserDefaults(suiteName:)`, wired into
// `DisabledRemindersStore` via `withTestDefaults` (`@TaskLocal`). Tests therefore
// never write the shared `.standard` domain and need no `.serialized`.
//
// Why this matters (regression): these tests used to seed/mutate `.standard`
// directly. A `UserDefaults(suiteName:)` instance's search list falls through to
// the application (`.standard`) domain for any key its own suite domain lacks, so
// while this suite ran in parallel with `FirstLaunchOverdueTests`, that suite's
// isolated reads of `disabled_reminders_v2` picked up THIS suite's `.standard`
// writes — passing in isolation but flaky in the full suite. Keeping every writer
// on an isolated suite domain is the fix.
@Suite("DisabledRemindersStore CRDT")
struct DisabledRemindersCRDTTests {

    /// Create a fresh, isolated `UserDefaults` for a single test, wire it into
    /// `DisabledRemindersStore` via `@TaskLocal`, run the body, and tear down.
    private static func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let suiteName = "tabmail.tests.disabled-reminders-crdt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try DisabledRemindersStore.withTestDefaults(defaults) {
            try body(defaults)
        }
    }

    private static func seedMap(_ map: [String: DisabledRemindersStore.DisabledEntry], into defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: "disabled_reminders_v2")
        }
    }

    private static func isoDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return date.ISO8601Format()
    }

    // MARK: - mergeIncoming

    @Test("Incoming entry newer than local replaces local")
    func incomingNewerWins() {
        Self.withIsolatedDefaults { defaults in
            let localTs = "2024-01-01T00:00:00Z"
            let incomingTs = "2024-06-01T00:00:00Z"
            Self.seedMap(["h1": .init(enabled: false, ts: localTs)], into: defaults)

            DisabledRemindersStore.mergeIncoming(["h1": .init(enabled: true, ts: incomingTs)])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.enabled == true)
            #expect(map["h1"]?.ts == incomingTs)
        }
    }

    @Test("Incoming entry older than local preserves local")
    func localNewerPreserved() {
        Self.withIsolatedDefaults { defaults in
            let localTs = "2024-06-01T00:00:00Z"
            let incomingTs = "2024-01-01T00:00:00Z"
            Self.seedMap(["h1": .init(enabled: false, ts: localTs)], into: defaults)

            DisabledRemindersStore.mergeIncoming(["h1": .init(enabled: true, ts: incomingTs)])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.enabled == false)
            #expect(map["h1"]?.ts == localTs)
        }
    }

    @Test("New hash from incoming is added")
    func newHashAdded() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["h1": .init(enabled: false, ts: "2024-01-01T00:00:00Z")], into: defaults)

            DisabledRemindersStore.mergeIncoming(["h2": .init(enabled: false, ts: "2024-03-01T00:00:00Z")])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.count == 2)
            #expect(map["h1"] != nil)
            #expect(map["h2"] != nil)
        }
    }

    @Test("Empty incoming map causes no changes")
    func emptyIncomingNoOp() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["h1": .init(enabled: false, ts: "2024-01-01T00:00:00Z")], into: defaults)

            DisabledRemindersStore.mergeIncoming([:])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.count == 1)
            #expect(map["h1"]?.ts == "2024-01-01T00:00:00Z")
        }
    }

    @Test("Mixed newer and older entries merge correctly")
    func mixedPartialMerge() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap([
                "h1": .init(enabled: false, ts: "2024-03-01T00:00:00Z"),
                "h2": .init(enabled: true, ts: "2024-06-01T00:00:00Z"),
                "h3": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
            ], into: defaults)

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
    }

    @Test("Merge into empty local map adopts all incoming")
    func mergeIntoEmpty() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.mergeIncoming([
                "a": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
                "b": .init(enabled: true, ts: "2024-02-01T00:00:00Z"),
            ])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.count == 2)
            #expect(map["a"]?.enabled == false)
            #expect(map["b"]?.enabled == true)
        }
    }

    // MARK: - gcStaleEntries

    @Test("Entry not in freshHashes and older than 90 days is removed")
    func staleOrphanRemoved() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["old": .init(enabled: false, ts: Self.isoDate(daysAgo: 100))], into: defaults)

            DisabledRemindersStore.gcStaleEntries(freshHashes: [])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["old"] == nil)
        }
    }

    @Test("Entry not in freshHashes but younger than 90 days is kept")
    func recentOrphanKept() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["recent": .init(enabled: false, ts: Self.isoDate(daysAgo: 30))], into: defaults)

            DisabledRemindersStore.gcStaleEntries(freshHashes: [])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["recent"] != nil)
        }
    }

    @Test("Entry in freshHashes is kept even if old")
    func freshOldEntryKept() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["pinned": .init(enabled: false, ts: Self.isoDate(daysAgo: 200))], into: defaults)

            DisabledRemindersStore.gcStaleEntries(freshHashes: ["pinned"])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["pinned"] != nil)
        }
    }

    @Test("Empty map does not crash")
    func emptyMapNoOp() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.gcStaleEntries(freshHashes: ["anything"])
            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.isEmpty)
        }
    }

    @Test("Mixed stale and fresh entries — correct partial GC")
    func mixedGC() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap([
                "stale1": .init(enabled: false, ts: Self.isoDate(daysAgo: 100)),
                "stale2": .init(enabled: true, ts: Self.isoDate(daysAgo: 120)),
                "recent": .init(enabled: false, ts: Self.isoDate(daysAgo: 10)),
                "oldButFresh": .init(enabled: false, ts: Self.isoDate(daysAgo: 200)),
            ], into: defaults)

            DisabledRemindersStore.gcStaleEntries(freshHashes: ["oldButFresh"])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["stale1"] == nil)
            #expect(map["stale2"] == nil)
            #expect(map["recent"] != nil)
            #expect(map["oldButFresh"] != nil)
            #expect(map.count == 2)
        }
    }

    // INVARIANT (ADR-IOS-079): GC only collects hash namespaces this device can
    // re-derive. An absent entry means ENABLED, so collecting one asserts the user
    // never disabled it — sound only for a prefix this device can still put into
    // `freshHashes`. Scheduled tasks are not parsed here, so a `t:` hash can never
    // be fresh; its disable state arrives only from a peer over a relay that keeps
    // no copy, and dropping it loses the user's choice for good.
    //
    // Stated as the system property, not the mechanism: a `t:` entry that is absent
    // from `freshHashes` AND older than the GC age still survives the pass, and is
    // still reported as disabled. Two-sided on purpose — the same pass must keep
    // collecting genuinely stale `m:`/`k:` entries, so a guard that simply switched
    // GC off could not pass this test.
    @Test("Task-hash disable state survives GC while stale message/KB entries are still collected")
    func nonDerivableTaskHashesSurviveGC() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap([
                "t:1abc": .init(enabled: false, ts: Self.isoDate(daysAgo: 400)),
                "t:2def": .init(enabled: true, ts: Self.isoDate(daysAgo: 400)),
                "m:stale@example.com": .init(enabled: false, ts: Self.isoDate(daysAgo: 400)),
                "k:9zz": .init(enabled: false, ts: Self.isoDate(daysAgo: 400)),
            ], into: defaults)

            // The freshness set this platform can actually build: message and KB
            // hashes only, and none of the seeded ones are still live.
            DisabledRemindersStore.gcStaleEntries(freshHashes: ["m:other@example.com", "k:1aa"])

            let map = DisabledRemindersStore.getDisabledMap()

            // The user's intention survives — and survives as DISABLED, since an
            // entry that came back enabled would read downstream as "never disabled".
            #expect(map["t:1abc"]?.enabled == false)
            #expect(DisabledRemindersStore.getDisabledHashes().contains("t:1abc"))
            // The re-enable tombstone is the same durable intention, kept whole.
            #expect(map["t:2def"]?.enabled == true)

            // Non-vacuity: GC still ran and still collected what it can re-derive.
            #expect(map["m:stale@example.com"] == nil)
            #expect(map["k:9zz"] == nil)
            #expect(map.count == 2)
        }
    }

    // MARK: - getDisabledHashes

    @Test("Returns only hashes where enabled is false")
    func onlyDisabledReturned() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap([
                "dis1": .init(enabled: false, ts: "2024-01-01T00:00:00Z"),
                "en1": .init(enabled: true, ts: "2024-01-01T00:00:00Z"),
                "dis2": .init(enabled: false, ts: "2024-02-01T00:00:00Z"),
            ], into: defaults)

            let hashes = DisabledRemindersStore.getDisabledHashes()
            #expect(hashes == Set(["dis1", "dis2"]))
        }
    }

    @Test("Empty map returns empty set")
    func emptyMapEmptySet() {
        Self.withIsolatedDefaults { _ in
            let hashes = DisabledRemindersStore.getDisabledHashes()
            #expect(hashes.isEmpty)
        }
    }

    @Test("All enabled entries returns empty set")
    func allEnabledEmpty() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap([
                "a": .init(enabled: true, ts: "2024-01-01T00:00:00Z"),
                "b": .init(enabled: true, ts: "2024-02-01T00:00:00Z"),
            ], into: defaults)

            let hashes = DisabledRemindersStore.getDisabledHashes()
            #expect(hashes.isEmpty)
        }
    }

    // MARK: - setEnabled

    @Test("Setting disabled creates entry with enabled=false")
    func setDisabled() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.setEnabled(hash: "test1", enabled: false)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["test1"]?.enabled == false)
            #expect(map["test1"]?.ts != nil)
        }
    }

    @Test("Setting enabled creates tombstone entry with enabled=true")
    func setEnabledTombstone() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.setEnabled(hash: "test2", enabled: true)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["test2"]?.enabled == true)
        }
    }

    @Test("Overwrites existing entry with new timestamp")
    func overwritesExisting() {
        Self.withIsolatedDefaults { defaults in
            let key = "overwrite_\(UUID().uuidString.prefix(8))"
            let oldTs = "2020-01-01T00:00:00Z"
            Self.seedMap([key: .init(enabled: false, ts: oldTs)], into: defaults)

            DisabledRemindersStore.setEnabled(hash: key, enabled: true)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map[key]?.enabled == true)
            #expect(map[key]?.ts != oldTs)
        }
    }

    @Test("Sets timestamp close to current time")
    func timestampIsCurrent() {
        Self.withIsolatedDefaults { _ in
            let before = Date()
            DisabledRemindersStore.setEnabled(hash: "ts_test", enabled: false)
            let after = Date()

            let map = DisabledRemindersStore.getDisabledMap()
            let entryDate = Date.fromISO8601(map["ts_test"]!.ts)!
            #expect(entryDate >= before.addingTimeInterval(-1))
            #expect(entryDate <= after.addingTimeInterval(1))
        }
    }
}
