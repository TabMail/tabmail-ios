/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Each test runs against its own `UserDefaults(suiteName:)` instance, so the
// suite no longer needs `.serialized` — tests can execute in parallel without
// stepping on shared global state.
@Suite("First Launch Overdue Suppression")
struct FirstLaunchOverdueTests {

    // MARK: - Helpers

    /// Create a fresh, isolated `UserDefaults` for a single test, wire it into
    /// `DisabledRemindersStore` via `@TaskLocal`, run the body, and tear down.
    /// The `@TaskLocal` scoping means parallel suites that touch this store
    /// see their own state (or `.standard`), not ours.
    private static func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let suiteName = "tabmail.tests.first-launch-overdue.\(UUID().uuidString)"
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

    private static func dateStr(daysFromNow days: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: days, to: Date())!
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func makeReminder(
        hash: String,
        dueDate: String?,
        enabled: Bool = true,
        source: String = "message"
    ) -> Reminder {
        Reminder(
            type: "reminder",
            content: "Test reminder \(hash)",
            dueDate: dueDate,
            dueTime: nil,
            source: source,
            hash: hash,
            enabled: enabled,
            action: "reply",
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil,
            rawLine: nil
        )
    }

    // MARK: - bulkDisableWithEpochZero

    @Test("bulkDisableWithEpochZero writes entries with epoch-zero timestamp")
    func bulkDisableWritesEpochZero() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1", "h2"])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.count == 2)
            #expect(map["h1"]?.enabled == false)
            #expect(map["h1"]?.ts == "1970-01-01T00:00:00Z")
            #expect(map["h2"]?.enabled == false)
            #expect(map["h2"]?.ts == "1970-01-01T00:00:00Z")
        }
    }

    @Test("bulkDisableWithEpochZero skips hashes that already have entries")
    func bulkDisableSkipsExisting() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["h1": .init(enabled: true, ts: "2026-01-01T00:00:00Z")], into: defaults)

            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1", "h2"])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.enabled == true)
            #expect(map["h1"]?.ts == "2026-01-01T00:00:00Z")
            #expect(map["h2"]?.enabled == false)
            #expect(map["h2"]?.ts == "1970-01-01T00:00:00Z")
        }
    }

    @Test("bulkDisableWithEpochZero with empty array is a no-op")
    func bulkDisableEmptyNoOp() {
        Self.withIsolatedDefaults { defaults in
            Self.seedMap(["existing": .init(enabled: false, ts: "2026-01-01T00:00:00Z")], into: defaults)

            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: [])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.count == 1)
            #expect(map["existing"] != nil)
        }
    }

    // MARK: - Device Sync overrides epoch-zero entries

    @Test("Device Sync mergeIncoming overrides epoch-zero entries")
    func deviceSyncOverridesEpochZero() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1", "h2"])
            let mapBefore = DisabledRemindersStore.getDisabledMap()
            #expect(mapBefore["h1"]?.enabled == false)
            #expect(mapBefore["h2"]?.enabled == false)

            DisabledRemindersStore.mergeIncoming([
                "h1": .init(enabled: true, ts: "2026-03-01T00:00:00Z"),
            ])

            let mapAfter = DisabledRemindersStore.getDisabledMap()
            #expect(mapAfter["h1"]?.enabled == true)
            #expect(mapAfter["h1"]?.ts == "2026-03-01T00:00:00Z")
            #expect(mapAfter["h2"]?.enabled == false)
            #expect(mapAfter["h2"]?.ts == "1970-01-01T00:00:00Z")
        }
    }

    @Test("Any real timestamp from sync wins over epoch-zero")
    func anyRealTimestampWins() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1"])

            DisabledRemindersStore.mergeIncoming([
                "h1": .init(enabled: false, ts: "2020-01-01T00:00:00Z"),
            ])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.ts == "2020-01-01T00:00:00Z")
        }
    }

    // MARK: - GC interaction with epoch-zero entries

    @Test("GC removes epoch-zero entries NOT in freshHashes")
    func gcRemovesOrphanedEpochZero() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1"])

            DisabledRemindersStore.gcStaleEntries(freshHashes: [])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"] == nil)
        }
    }

    @Test("GC preserves epoch-zero entries IN freshHashes")
    func gcPreservesActiveEpochZero() {
        Self.withIsolatedDefaults { _ in
            DisabledRemindersStore.bulkDisableWithEpochZero(hashes: ["h1"])

            DisabledRemindersStore.gcStaleEntries(freshHashes: ["h1"])

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.enabled == false)
            #expect(map["h1"]?.ts == "1970-01-01T00:00:00Z")
        }
    }

    // MARK: - autoDisableOverdueOnFirstLaunch guard conditions

    @Test("Auto-disable does not run without firstLaunchDate")
    func noFirstLaunchDateSkips() {
        Self.withIsolatedDefaults { defaults in
            let reminders = [
                Self.makeReminder(hash: "h1", dueDate: Self.dateStr(daysFromNow: -10)),
            ]
            let result = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(result == false)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.isEmpty)
        }
    }

    @Test("Auto-disable does not run twice")
    func doesNotRunTwice() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "h1", dueDate: Self.dateStr(daysFromNow: -10)),
            ]

            let first = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(first == true)

            // Clear the map to prove the second invocation does not re-run.
            Self.seedMap([:], into: defaults)

            let second = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(second == false)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map.isEmpty)
        }
    }

    @Test("Auto-disable only disables reminders with due dates before firstLaunchDate")
    func onlyDisablesOverdue() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "overdue1", dueDate: Self.dateStr(daysFromNow: -30)),
                Self.makeReminder(hash: "overdue2", dueDate: Self.dateStr(daysFromNow: -1)),
                Self.makeReminder(hash: "today", dueDate: Self.dateStr(daysFromNow: 0)),
                Self.makeReminder(hash: "future", dueDate: Self.dateStr(daysFromNow: 7)),
                Self.makeReminder(hash: "noduedate", dueDate: nil),
            ]

            let result = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(result == true)

            let disabled = DisabledRemindersStore.getDisabledHashes()
            #expect(disabled.contains("overdue1"))
            #expect(disabled.contains("overdue2"))
            #expect(!disabled.contains("today"))
            #expect(!disabled.contains("future"))
            #expect(!disabled.contains("noduedate"))
        }
    }

    @Test("Auto-disable skips already-disabled reminders")
    func skipsAlreadyDisabled() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "h1", dueDate: Self.dateStr(daysFromNow: -10), enabled: false),
            ]

            let result = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(result == false)
        }
    }

    @Test("Auto-disable with no overdue reminders returns false")
    func noOverdueReturnsFalse() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "future1", dueDate: Self.dateStr(daysFromNow: 7)),
                Self.makeReminder(hash: "future2", dueDate: Self.dateStr(daysFromNow: 30)),
            ]

            let result = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(result == false)

            #expect(defaults.bool(forKey: "didAutoDisableOverdueReminders") == true)
        }
    }

    @Test("Auto-disable uses epoch-zero timestamps, not current time")
    func usesEpochZeroTimestamps() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "h1", dueDate: Self.dateStr(daysFromNow: -5)),
            ]

            _ = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)

            let map = DisabledRemindersStore.getDisabledMap()
            #expect(map["h1"]?.ts == "1970-01-01T00:00:00Z")
        }
    }

    // MARK: - End-to-end: auto-disable then sync override

    @Test("Full flow: auto-disable on first launch, then Device Sync re-enables")
    func fullFlowAutoDisableThenSync() {
        Self.withIsolatedDefaults { defaults in
            defaults.set(Date(), forKey: "firstLaunchDate")

            let reminders = [
                Self.makeReminder(hash: "h1", dueDate: Self.dateStr(daysFromNow: -10)),
                Self.makeReminder(hash: "h2", dueDate: Self.dateStr(daysFromNow: -5)),
                Self.makeReminder(hash: "h3", dueDate: Self.dateStr(daysFromNow: 3)),
            ]

            let result = ReminderBuilder.testAutoDisableOverdue(reminders, defaults: defaults)
            #expect(result == true)

            var disabled = DisabledRemindersStore.getDisabledHashes()
            #expect(disabled.contains("h1"))
            #expect(disabled.contains("h2"))
            #expect(!disabled.contains("h3"))

            DisabledRemindersStore.mergeIncoming([
                "h1": .init(enabled: true, ts: "2026-04-01T00:00:00Z"),
            ])

            disabled = DisabledRemindersStore.getDisabledHashes()
            #expect(!disabled.contains("h1"))
            #expect(disabled.contains("h2"))
        }
    }
}
