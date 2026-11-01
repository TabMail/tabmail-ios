/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A reminder build awaits between its start and its writes (DS-DEMO). It takes the change counter and the mode as
/// one snapshot, and the three writes it makes (the migrated hash, the first-launch suppression with its done mark,
/// and the garbage collection) each carry that counter. A demo switch in between, in either direction, refuses all
/// three: both reminder maps are byte-identical afterwards and the done mark is unset. The control is the same
/// build with no switch, which makes each of the three writes in the mode it started in.
@MainActor
@Suite("Reminder build across a demo switch", .serialized, .processGlobalState)
struct ReminderBuilderSwitchTests {
    private static let realKey = "disabled_reminders_v2"
    private static let demoKey = DisabledRemindersStore.demoStorageKeyV2
    private static let doneKey = "didAutoDisableOverdueReminders"

    private struct Rows {
        let migrating: MessageHeader
        let overdue: MessageHeader

        func hash(_ header: MessageHeader) -> String {
            DisabledRemindersStore.hashReminder(source: "message", content: header.reminderContent ?? "", uniqueId: header.id, rfc822MessageId: header.rfc822MessageId)
        }
    }

    nonisolated private static func yesterday() -> String {
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }

    /// Two inbox reminders in the account: one whose old platform hash is disabled (it migrates), one overdue.
    nonisolated private static func seed(_ pool: DatabasePool, accountId: String, tag: String, demo: Bool) async throws -> Rows {
        try await pool.write { db in
            var account = Account(emailAddress: (demo ? "demo-" : "real-") + tag + "@example.com", displayName: "Account", provider: .gmail)
            account.id = accountId
            try account.save(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
            try folder.save(db)
            func header(_ name: String, due: String?) throws -> MessageHeader {
                let messageId = name + "-" + tag
                var header = MessageHeader(messageId: messageId, subject: "Reminder", from: "Sender", fromAddress: "sender@example.com", to: "me@example.com", date: Date(), snippet: "", folderId: folder.id, accountId: account.id, folderPath: "INBOX", isInInbox: true)
                header.reminderContent = messageId
                header.reminderDate = due
                header.rfc822MessageId = "<" + messageId + "@example.com>"
                try header.save(db)
                return header
            }
            return Rows(migrating: try header("migrating", due: nil), overdue: try header("overdue", due: yesterday()))
        }
    }

    /// Both maps get the old hash of each mode's migrating reminder (disabled) and a stale entry a collection removes.
    private static func seedMaps(_ defaults: UserDefaults, oldHashes: [String], stale: String) throws {
        var map: [String: DisabledRemindersStore.DisabledEntry] = [:]
        let fresh = Date().ISO8601Format()
        for hash in oldHashes { map[hash] = .init(enabled: false, ts: fresh) }
        map[stale] = .init(enabled: false, ts: Date().addingTimeInterval(-200 * 86400).ISO8601Format())
        let data = try JSONEncoder().encode(map)
        defaults.set(data, forKey: realKey)
        defaults.set(data, forKey: demoKey)
    }

    private static func decoded(_ defaults: UserDefaults, _ key: String) -> [String: DisabledRemindersStore.DisabledEntry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: DisabledRemindersStore.DisabledEntry].self, from: $0) } ?? [:]
    }

    @Test("A build whose demo was entered or left while it ran makes none of its three writes; an uninterrupted one makes all three",
          arguments: [true, false])
    func buildWritesRefusedAcrossASwitch(entering: Bool) async throws {
        let store = PromptStore.shared
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        DemoModeStore.shared._resetForTests()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("builder-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 1
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let app = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { old -> AppDatabase? in
            let saved = old
            old = app
            return saved
        }
        let standard = UserDefaults.standard
        let firstLaunch = standard.object(forKey: "firstLaunchDate")
        let done = standard.object(forKey: Self.doneKey)
        let suite = "builder-switch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let firstLaunch { standard.set(firstLaunch, forKey: "firstLaunchDate") } else { standard.removeObject(forKey: "firstLaunchDate") }
            if let done { standard.set(done, forKey: Self.doneKey) } else { standard.removeObject(forKey: Self.doneKey) }
            DemoModeStore.shared._resetForTests()
            PromptStore.removeDemoOverlayKeys()
            ReminderBuilder.invalidateCache()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let tag = UUID().uuidString.lowercased().prefix(8).description
        let real = try await Self.seed(pool, accountId: "builder-real-" + tag, tag: tag, demo: false)
        let demo = try await Self.seed(pool, accountId: DemoSeed.demoAccountId, tag: tag, demo: true)
        let stale = "stale-" + tag
        let oldHashes = ["m:" + real.migrating.id, "m:" + demo.migrating.id]

        func switchDemo(_ entering: Bool) async throws {
            try await DisabledRemindersStore.withTestDefaults(defaults) {
                Task { @MainActor in if entering { try await store.enterDemo() } else { try await store.leaveDemo() } }
            }.value
        }

        func prepare() throws {
            try Self.seedMaps(defaults, oldHashes: oldHashes, stale: stale)
            standard.set(Date(), forKey: "firstLaunchDate")
            standard.set(false, forKey: Self.doneKey)
            ReminderBuilder.invalidateCache()
        }

        // Control: the build begins in its mode and no switch comes. Each of the three writes lands in that mode's map.
        if !entering { try await switchDemo(true) }
        try prepare()
        let rows = entering ? real : demo
        let liveKey = entering ? Self.realKey : Self.demoKey
        let otherKey = entering ? Self.demoKey : Self.realKey
        let otherBefore = defaults.data(forKey: otherKey)
        _ = await DisabledRemindersStore.withTestDefaults(defaults) {
            Task { await ReminderBuilder.buildReminderList(includeDisabled: true) }
        }.value
        let live = Self.decoded(defaults, liveKey)
        #expect(live[rows.hash(rows.migrating)]?.enabled == false, "control: the migrated hash was written")
        #expect(live[rows.hash(rows.overdue)]?.enabled == false, "control: the overdue reminder was suppressed")
        #expect(live[stale] == nil, "control: the stale entry was collected")
        #expect(standard.bool(forKey: Self.doneKey), "control: the suppression is marked done")
        #expect(defaults.data(forKey: otherKey) == otherBefore, "control: the other mode's map is untouched")
        if !entering { try await switchDemo(false) }

        // The build starts in its mode, is held at its first database read, and the demo is entered or left.
        if !entering { try await switchDemo(true) }
        try prepare()
        let gate = DatabaseReaderGate(pool)
        guard await gate.waitUntilHeld() else { Issue.record("the reader was never taken"); return }
        let pending = DisabledRemindersStore.withTestDefaults(defaults) {
            Task { await ReminderBuilder.buildReminderList(includeDisabled: true) }
        }
        try await Task.sleep(for: .seconds(1))
        try await switchDemo(entering)
        #expect(DemoModeStore.isDemoActive == entering, "the switch happened")
        // Leaving deletes the demo's map; both maps are put back so a write into either is visible.
        try Self.seedMaps(defaults, oldHashes: oldHashes, stale: stale)
        let realBefore = defaults.data(forKey: Self.realKey)
        let demoBefore = defaults.data(forKey: Self.demoKey)
        await gate.release()
        let list = await pending.value

        #expect(defaults.data(forKey: Self.realKey) == realBefore, "the build wrote the real map: \(Self.decoded(defaults, Self.realKey).keys.sorted())")
        #expect(defaults.data(forKey: Self.demoKey) == demoBefore, "the build wrote the demo's map: \(Self.decoded(defaults, Self.demoKey).keys.sorted())")
        #expect(!standard.bool(forKey: Self.doneKey), "the refused suppression is not marked done")
        #expect(!list.isEmpty, "the build itself finished")
        if DemoModeStore.isDemoActive { try await switchDemo(false) }
    }
}
