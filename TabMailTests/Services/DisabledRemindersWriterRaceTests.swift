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
    /// The key whose first off-main read parks (the real map unless a test aims at the demo's).
    var parkKey = "disabled_reminders_v2"

    var parked: Bool { state.withLock { $0.parked } }
    var timedOut: Bool { state.withLock { $0.timedOut } }
    func release() { unblock.signal() }

    /// A writer's one read of the map is its first off-main read of the key.
    override func data(forKey key: String) -> Data? {
        let snapshot = super.data(forKey: key)
        if key == parkKey, !Thread.isMainThread {
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

private final class ReadCapture: Sendable {
    private let value = Mutex<[String: DisabledRemindersStore.DisabledEntry]?>(nil)
    var map: [String: DisabledRemindersStore.DisabledEntry]? { value.withLock { $0 } }
    func set(_ map: [String: DisabledRemindersStore.DisabledEntry]) { value.withLock { $0 = map } }
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
            DisabledRemindersStore.setEnabled(hash: "k:newer", enabled: false)
        }
    }

    /// Runs `parked` off the main thread until it has read the map, then runs `other` from another thread,
    /// and finishes both. Returns the final map.
    private func race(
        _ defaults: ParkingDefaults, parked: @escaping @Sendable () -> Void, other: @escaping @Sendable () -> Void
    ) async throws -> [String: DisabledRemindersStore.DisabledEntry] {
        let box = DefaultsBox(defaults)
        let older = Task.detached { @Sendable [box] in
            DisabledRemindersStore.withTestDefaults(box.value, parked)
        }
        let end = ContinuousClock.now + .seconds(10)
        while !defaults.parked, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        guard defaults.parked else {
            defaults.release(); await older.value
            Issue.record("the maintenance writer never reached its read")
            return [:]
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
        defaults.release()
        await older.value
        await user.value
        #expect(!defaults.timedOut)
        return DisabledRemindersStore.withTestDefaults(defaults) { DisabledRemindersStore.getDisabledMap() }
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
            DisabledRemindersStore.setEnabled(hash: "k:newer", enabled: false)
        }, other: {
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:older"])
        })
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

    @Test("A read made while a writer is part-way through its change returns the writer's whole change")
    func readerSeesTheWholeChange() async throws {
        let (defaults, suite) = try isolatedDefaults(seed: ["k:seed": .init(enabled: false, ts: Date().ISO8601Format())])
        defer { defaults.removePersistentDomain(forName: suite) }
        let read = ReadCapture()
        let final = try await race(defaults, parked: {
            DisabledRemindersStore.setEnabled(hash: "k:choice", enabled: false)
        }, other: {
            read.set(DisabledRemindersStore.getDisabledMap())
        })
        #expect(read.map?["k:choice"]?.enabled == false, "the read returned the map from before the change it was ordered behind")
        #expect(read.map?["k:seed"]?.enabled == false)
        #expect(final["k:choice"]?.enabled == false, "control: the choice is stored")
    }

    // MARK: - DS-DEMO: a writer that started before a demo switch is refused after it

    fileprivate enum Writer: String, CaseIterable, CustomStringConvertible {
        case toggle, suppress, collect
        var description: String { rawValue }
        /// The entry this writer leaves in a map that holds `k:seed` and the stale `k:stale`.
        var hash: String { self == .toggle ? "k:toggled" : self == .suppress ? "k:suppressed" : "k:stale" }

        func run(since started: UUID) -> Bool {
            switch self {
            case .toggle: DisabledRemindersStore.setEnabled(hash: "k:toggled", enabled: false, since: started)
            case .suppress: DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["k:suppressed"], since: started)
            case .collect: DisabledRemindersStore.gcStaleEntries(freshHashes: [], since: started)
            }
        }
    }

    private static let realKey = "disabled_reminders_v2"

    /// The mode flips and the change counter moves in one transaction on the map lock, as a demo switch does.
    private func flip(toDemo entering: Bool) {
        DisabledRemindersStore.switching(toDemo: entering) {
            DemoModeStore.shared.isActive = entering
            ChangeCounter.device.renew()
        }
    }

    private func seededDefaults() throws -> (UserDefaults, String) {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        let suite = "tabmail.tests.disabled-reminders-switch." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let stale = Date().addingTimeInterval(-91 * 86400).ISO8601Format()
        let seed: [String: DisabledRemindersStore.DisabledEntry] = [
            "k:seed": .init(enabled: false, ts: Date().ISO8601Format()),
            "k:stale": .init(enabled: false, ts: stale),
        ]
        defaults.set(try JSONEncoder().encode(seed), forKey: Self.realKey)
        return (defaults, suite)
    }

    @Test("A writer that started before the demo was entered is refused after it and changes neither map; a fresh one saves", arguments: Writer.allCases)
    fileprivate func refusedAfterEntry(_ writer: Writer) throws {
        let (defaults, suite) = try seededDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        DisabledRemindersStore.withTestDefaults(defaults) {
            let realBefore = defaults.data(forKey: Self.realKey)
            let started = ChangeCounter.device.current
            flip(toDemo: true)
            #expect(!writer.run(since: started), "\(writer): the switch moved the counter, so the write is refused")
            #expect(defaults.data(forKey: Self.realKey) == realBefore, "\(writer): the real map is unchanged")
            #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) == nil, "\(writer): nothing reached the demo's map")
            // Control: a writer that started in the demo saves to the demo's map, and only there.
            #expect(writer.run(since: ChangeCounter.device.current), "\(writer): control saves")
            #expect(defaults.data(forKey: Self.realKey) == realBefore, "\(writer): the control left the real map alone")
            flip(toDemo: false)
        }
    }

    @Test("A writer that started in the demo is refused after it was left and changes neither map; a fresh one saves", arguments: Writer.allCases)
    fileprivate func refusedAfterExit(_ writer: Writer) throws {
        let (defaults, suite) = try seededDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        DisabledRemindersStore.withTestDefaults(defaults) {
            flip(toDemo: true)
            let realBefore = defaults.data(forKey: Self.realKey)
            let started = ChangeCounter.device.current
            flip(toDemo: false)
            #expect(!writer.run(since: started), "\(writer): the switch moved the counter, so the write is refused")
            #expect(defaults.data(forKey: Self.realKey) == realBefore, "\(writer): the real map is unchanged")
            #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) == nil, "\(writer): no demo map was left behind")
            // Control: a writer that started after the exit saves to the real map.
            #expect(writer.run(since: ChangeCounter.device.current), "\(writer): control saves")
            #expect(defaults.data(forKey: Self.realKey) != realBefore, "\(writer): the control changed the real map")
        }
    }

    @Test("Leaving the demo deletes the demo's map in the same transaction as the flip")
    func leavingDeletesTheDemoMap() throws {
        let (defaults, suite) = try seededDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        DisabledRemindersStore.withTestDefaults(defaults) {
            flip(toDemo: true)
            #expect(DisabledRemindersStore.setEnabled(hash: "k:demo", enabled: false))
            #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) != nil)
            flip(toDemo: false)
            #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) == nil, "the demo's map did not survive the exit")
            #expect(!DemoModeStore.isDemoActive)
        }
    }

    @Test("A demo writer holding the map when the demo is left lands first, so no demo map outlives the demo")
    func demoMapDoesNotOutliveTheDemo() async throws {
        let (defaults, suite) = try isolatedDefaults(seed: [:])
        defaults.parkKey = DisabledRemindersStore.demoStorageKeyV2
        defer { defaults.removePersistentDomain(forName: suite); DemoModeStore.shared._resetForTests() }
        DemoModeStore.shared._resetForTests()
        try await PromptStore.shared.enterDemo()
        let box = DefaultsBox(defaults)
        let started = ChangeCounter.device.current
        let writer = Task.detached { @Sendable [box] in
            DisabledRemindersStore.withTestDefaults(box.value) {
                _ = DisabledRemindersStore.setEnabled(hash: "k:demo", enabled: false, since: started)
            }
        }
        let end = ContinuousClock.now + .seconds(10)
        while !defaults.parked, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        guard defaults.parked else {
            defaults.release(); await writer.value
            Issue.record("the demo writer never reached its read")
            try await PromptStore.shared.leaveDemo()
            return
        }
        // The writer holds the map lock; the exit's flip waits for it, so the writer's own compare sees the old
        // counter and it commits to the demo's map before the flip removes that map.
        // The release comes from a task off the main actor: the exit's flip blocks the main thread on the lock.
        let releaser = Task.detached { @Sendable [box] in
            try? await Task.sleep(for: .milliseconds(300))
            box.value.release()
        }
        let leaving = DisabledRemindersStore.withTestDefaults(defaults) { Task { @MainActor in try await PromptStore.shared.leaveDemo() } }
        try await leaving.value
        await releaser.value
        await writer.value
        #expect(!defaults.timedOut)
        #expect(!DemoModeStore.isDemoActive)
        #expect(defaults.data(forKey: DisabledRemindersStore.demoStorageKeyV2) == nil, "a demo map outlived the demo")
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
