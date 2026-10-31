/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// `UserDefaults` that parks the first off-main writer, once, right after it read the reminder map: the
/// moment a detached rebuild holds an older copy of the map while a user toggle commits.
private final class ParkingDefaults: UserDefaults {
    private let state = Mutex((reads: 0, parked: false, timedOut: false))
    private let unblock = DispatchSemaphore(value: 0)

    var parked: Bool { state.withLock { $0.parked } }
    var timedOut: Bool { state.withLock { $0.timedOut } }
    func release() { unblock.signal() }

    /// A writer's one read of the map is its first off-main read of the key.
    override func data(forKey key: String) -> Data? {
        let snapshot = super.data(forKey: key)
        if key == "disabled_reminders_v2", !Thread.isMainThread {
            let park = state.withLock { s -> Bool in
                s.reads += 1
                return s.reads == 1
            }
            if park {
                state.withLock { $0.parked = true }
                if unblock.wait(timeout: .now() + 30) == .timedOut { state.withLock { $0.timedOut = true } }
            }
        }
        return snapshot
    }
}

private final class DefaultsBox: @unchecked Sendable {
    let value: ParkingDefaults
    init(_ value: ParkingDefaults) { self.value = value }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// Every writer of the reminder map replaces the whole map, and `ReminderBuilder`'s detached rebuild runs two of
/// them off the main thread, so an older writer must not save its copy over a newer writer's entry: an absent
/// entry means ENABLED, which would silently undo the user's disable (Device Sync spec section 8).
@MainActor
@Suite("Disabled reminders: a maintenance writer never replaces a newer choice", .serialized, .processGlobalState)
struct DisabledRemindersWriterRaceTests {

    private func isolatedDefaults(seed: [String: DisabledRemindersStore.DisabledEntry]) throws -> (ParkingDefaults, String) {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        let suite = "tabmail.tests.disabled-reminders-race." + UUID().uuidString
        let defaults = try #require(ParkingDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(seed), forKey: "disabled_reminders_v2")
        return (defaults, suite)
    }

    /// Runs `maintenance` off the main thread until it has read the map, then makes a user disable of
    /// `k:newer` from another thread, and finishes both. Returns the final map.
    private func raceWithUserDisable(
        _ defaults: ParkingDefaults, maintenance: @escaping @Sendable () -> Void
    ) async throws -> [String: DisabledRemindersStore.DisabledEntry] {
        try await race(defaults, parked: maintenance) {
            DisabledRemindersStore.setEnabled(hash: "k:newer", enabled: false, demo: false)
        }.real
    }

    /// Runs `parked` off the main thread until it has read the map, then runs `other` from another thread,
    /// and finishes both. With `enterDemo`, the demo starts while `other` waits for the lock and ends after
    /// both finished. Returns the final real map and the demo's.
    private func race(
        _ defaults: ParkingDefaults, enterDemo: Bool = false, parked: @escaping @Sendable () -> Void, other: @escaping @Sendable () -> Void
    ) async throws -> (real: [String: DisabledRemindersStore.DisabledEntry], demo: [String: DisabledRemindersStore.DisabledEntry]) {
        let box = DefaultsBox(defaults)
        let older = Task.detached { @Sendable [box] in
            DisabledRemindersStore.withTestDefaults(box.value, parked)
        }
        let end = ContinuousClock.now + .seconds(10)
        while !defaults.parked, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        guard defaults.parked else {
            defaults.release(); await older.value
            Issue.record("the maintenance writer never reached its read")
            return ([:], [:])
        }
        let userDone = Flag()
        let user = Task.detached { @Sendable [box] in
            DisabledRemindersStore.withTestDefaults(box.value, other)
            userDone.set()
        }
        // A store that lets the user's write through while the older writer holds its copy finishes it
        // here; one that serializes the writers finishes it after the older one is released.
        let wait = ContinuousClock.now + .seconds(1)
        while !userDone.isSet, ContinuousClock.now < wait { try await Task.sleep(for: .milliseconds(20)) }
        if enterDemo { DemoModeStore.shared.isActive = true }
        defaults.release()
        await older.value
        await user.value
        if enterDemo { DemoModeStore.shared.isActive = false }
        #expect(!defaults.timedOut)
        return DisabledRemindersStore.withTestDefaults(defaults) {
            (DisabledRemindersStore.getDisabledMap(demo: false), DisabledRemindersStore.getDisabledMap(demo: true))
        }
    }

    @Test("A first-launch suppression cannot replace a later user disable")
    func suppressionDoesNotReplaceNewerDisable() async throws {
        let (defaults, suite) = try isolatedDefaults(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())])
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = try await raceWithUserDisable(defaults) {
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:older"])
        }
        #expect(result["k:older"]?.enabled == false, "the suppression committed")
        #expect(result["k:seed"]?.enabled == false, "the baseline entry remains")
        #expect(result["k:newer"]?.enabled == false, "the user's later disable remains")
    }

    @Test("A garbage collection cannot replace a later user disable")
    func garbageCollectionDoesNotReplaceNewerDisable() async throws {
        let stale = Date().addingTimeInterval(-91 * 86400).ISO8601Format()
        let (defaults, suite) = try isolatedDefaults(seed: ["k:seed": .init(enabled: false, ts: stale)])
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = try await raceWithUserDisable(defaults) {
            DisabledRemindersStore.gcStaleEntries(freshHashes: [])
        }
        #expect(result["k:seed"] == nil, "the collection committed its removal")
        #expect(result["k:newer"]?.enabled == false, "the user's later disable remains")
    }

    @Test("A user disable that read the map cannot replace a maintenance write that committed meanwhile")
    func userDisableDoesNotReplaceMaintenanceWrite() async throws {
        let (defaults, suite) = try isolatedDefaults(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())])
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = try await race(defaults, parked: {
            DisabledRemindersStore.setEnabled(hash: "k:newer", enabled: false, demo: false)
        }, other: {
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:older"], demo: false)
        }).real
        #expect(result["k:newer"]?.enabled == false, "the user's disable committed")
        #expect(result["k:older"]?.enabled == false, "the maintenance write remains")
        #expect(result["k:seed"]?.enabled == false, "the baseline entry remains")
    }

    @Test("A received merge cannot replace a later user disable")
    func mergeDoesNotReplaceNewerDisable() async throws {
        let (defaults, suite) = try isolatedDefaults(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())])
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = try await raceWithUserDisable(defaults) {
            DisabledRemindersStore.mergeIncoming(["k:peer": .init(enabled: false, ts: Date().ISO8601Format())])
        }
        #expect(result["k:peer"]?.enabled == false, "the merge committed")
        #expect(result["k:newer"]?.enabled == false, "the user's later disable remains")
    }

    // MARK: - The writer's target is the one it took before it waited

    /// Each writer takes its target as its caller states it (`demo: false`), before it waits for the map lock; a demo
    /// that starts while it waits must not move its write to the demo's map or its saved entries out of the real one.
    private func writesTheRealMapWhenTheDemoStartsWhileItWaits(
        seed: [String: DisabledRemindersStore.DisabledEntry], hash: String, writer: @escaping @Sendable () -> Void
    ) async throws {
        let (defaults, suite) = try isolatedDefaults(seed: seed)
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoModeStore.shared
        demo._resetForTests()
        defer { demo._resetForTests() }
        let result = try await race(defaults, enterDemo: true, parked: {
            DisabledRemindersStore.setEnabled(hash: "k:first", enabled: false, demo: false)
        }, other: writer)
        #expect(result.real["k:first"]?.enabled == false, "the writer that held the lock committed")
        #expect(result.real["k:seed"]?.enabled == false, "the earlier entries remain")
        #expect(result.real[hash]?.enabled == false, "the writer's entry is in the real map")
        #expect(result.demo.isEmpty, "the demo's map stays empty: nothing moved there")
    }

    @Test("A first-launch suppression that waits for the lock writes the real map though the demo starts meanwhile")
    func suppressionKeepsItsTarget() async throws {
        try await writesTheRealMapWhenTheDemoStartsWhileItWaits(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())], hash: "k:suppressed") {
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:suppressed"], demo: false)
        }
    }

    @Test("A received merge that waits for the lock writes the real map though the demo starts meanwhile")
    func mergeKeepsItsTarget() async throws {
        try await writesTheRealMapWhenTheDemoStartsWhileItWaits(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())], hash: "k:peer") {
            DisabledRemindersStore.mergeIncoming(["k:peer": .init(enabled: false, ts: Date().ISO8601Format())], demo: false)
        }
    }

    @Test("A garbage collection that waits for the lock collects the real map though the demo starts meanwhile")
    func collectionKeepsItsTarget() async throws {
        let stale = Date().addingTimeInterval(-91 * 86400).ISO8601Format()
        let (defaults, suite) = try isolatedDefaults(seed: ["k:stale": .init(enabled: false, ts: stale)])
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoModeStore.shared
        demo._resetForTests()
        defer { demo._resetForTests() }
        let result = try await race(defaults, enterDemo: true, parked: {
            DisabledRemindersStore.setEnabled(hash: "k:first", enabled: false, demo: false)
        }, other: {
            DisabledRemindersStore.gcStaleEntries(freshHashes: [], demo: false)
        })
        #expect(result.real["k:stale"] == nil, "the collection removed the stale entry from the real map")
        #expect(result.real["k:first"]?.enabled == false)
        #expect(result.demo.isEmpty)
    }

    @Test("A user toggle that waits for the lock writes the real map though the demo starts meanwhile")
    func toggleKeepsItsTarget() async throws {
        try await writesTheRealMapWhenTheDemoStartsWhileItWaits(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())], hash: "k:toggled") {
            DisabledRemindersStore.setEnabled(hash: "k:toggled", enabled: false, demo: false)
        }
    }

    @Test("A demo-targeted change after the demo ended is refused and writes nothing, for every writer")
    func demoWritesAreRefusedAfterTheDemoEnded() throws {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        let suite = "DemoEndedWrites." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoModeStore.shared
        demo._resetForTests()
        defer { demo._resetForTests() }
        DisabledRemindersStore.withTestDefaults(defaults) {
            // Control: while the demo runs a demo-targeted change lands in the demo's map.
            demo.isActive = true
            #expect(DisabledRemindersStore.setEnabled(hash: "k:during", enabled: false, demo: true))
            DisabledRemindersStore.mergeIncoming(["k:merged": .init(enabled: false, ts: Date().ISO8601Format())], demo: true)
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:bulk"], demo: true)
            #expect(DisabledRemindersStore.getDisabledMap(demo: true).keys.sorted() == ["k:bulk", "k:during", "k:merged"])
            demo.isActive = false
            DisabledRemindersStore.removeDemoMap()

            // After the demo: nothing is written to the demo's map, and the real map is untouched.
            #expect(!DisabledRemindersStore.setEnabled(hash: "k:after", enabled: false, demo: true))
            DisabledRemindersStore.mergeIncoming(["k:merged": .init(enabled: false, ts: Date().ISO8601Format())], demo: true)
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:bulk"], demo: true)
            DisabledRemindersStore.gcStaleEntries(freshHashes: [], demo: true)
            #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) == nil, "no demo map was left behind")
            #expect(DisabledRemindersStore.getDisabledMap(demo: false).isEmpty)
        }
    }

    @Test("In the demo the reminder map is the demo's own; the real map is untouched and reads back after")
    func demoMapIsSeparate() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        let suite = "DemoReminderMap." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoModeStore.shared
        demo._resetForTests()
        defer { demo._resetForTests() }
        DisabledRemindersStore.withTestDefaults(defaults) {
            DisabledRemindersStore.setEnabled(hash: "k:real", enabled: false)
            demo.isActive = true
            #expect(DisabledRemindersStore.getDisabledMap()["k:real"] == nil, "the demo does not show the real choices")
            DisabledRemindersStore.setEnabled(hash: "k:demo", enabled: false)
            #expect(DisabledRemindersStore.getDisabledMap()["k:demo"]?.enabled == false, "the demo shows its own choice")
            demo.isActive = false
            #expect(DisabledRemindersStore.getDisabledMap()["k:demo"] == nil, "the demo's choice does not outlive it")
            #expect(DisabledRemindersStore.getDisabledMap()["k:real"]?.enabled == false, "the real choice reads back")
        }
    }

    @Test("The v1 list is the real map only: the demo does not read it, a demo change does not store it, and it reads again after")
    func v1ListIsNotTheDemosMap() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        let suite = "DemoReminderV1." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoModeStore.shared
        demo._resetForTests()
        defer { demo._resetForTests() }
        defaults.set(["k:legacy"], forKey: "disabled_reminders")
        DisabledRemindersStore.withTestDefaults(defaults) {
            #expect(DisabledRemindersStore.getDisabledMap()["k:legacy"]?.enabled == false, "control: the real map reads the v1 list")
            demo.isActive = true
            #expect(DisabledRemindersStore.getDisabledMap()["k:legacy"] == nil, "the demo does not read the v1 list")
            DisabledRemindersStore.setEnabled(hash: "k:demo", enabled: false)
            #expect(defaults.data(forKey: "disabled_reminders_v2") == nil, "a demo change stores no real map")
            demo.isActive = false
            #expect(DisabledRemindersStore.getDisabledMap()["k:legacy"]?.enabled == false, "the v1 list reads again after the demo")
            #expect(DisabledRemindersStore.getDisabledMap()["k:demo"] == nil)
        }
    }
}
