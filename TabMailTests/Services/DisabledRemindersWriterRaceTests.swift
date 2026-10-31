/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// `UserDefaults` that parks the first off-main writer, once, right after it read the reminder map: the
/// moment a detached rebuild holds an older copy of the map while a user toggle commits.
private final class ParkingDefaults: UserDefaults, @unchecked Sendable {
    private let state = Mutex((reads: 0, parked: false, timedOut: false))
    private let unblock = DispatchSemaphore(value: 0)

    var parked: Bool { state.withLock { $0.parked } }
    var timedOut: Bool { state.withLock { $0.timedOut } }
    func release() { unblock.signal() }

    /// A writer's reads are the migration check, then the map: the second off-main read is the map.
    override func data(forKey key: String) -> Data? {
        let snapshot = super.data(forKey: key)
        if key == "disabled_reminders_v2", !Thread.isMainThread {
            let park = state.withLock { s -> Bool in
                s.reads += 1
                return s.reads == 2
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
        let box = DefaultsBox(defaults)
        let older = Task.detached { @Sendable [box] in
            DisabledRemindersStore.withTestDefaults(box.value, maintenance)
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
            DisabledRemindersStore.withTestDefaults(box.value) {
                DisabledRemindersStore.setEnabled(hash: "k:newer", enabled: false)
            }
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
}
