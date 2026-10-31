/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A brief operation belongs to the mode it started in (DS-DEMO): a gesture or a short tool that is made while a
/// demo switch already waits in line ahead of it runs after that switch, and is refused. Nothing is saved on
/// either side, and it reports that it could not save. The controls are the same calls with no switch, and the
/// same calls queued behind an ordinary edit, which still save: waiting in line is not a refusal.
@MainActor
@Suite("Brief operations across a queued demo switch", .serialized, .processGlobalState)
struct DemoSwitchQueuedWriterTests {
    let store = PromptStore.shared

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        DemoModeStore.shared._resetForTests()
    }

    private func realStorage() -> Data? {
        UserDefaults.standard.data(forKey: UserDefaultsBulletStore.stateKey)
    }

    // MARK: - Gestures

    @Test("A gesture made while a switch waits ahead of it is refused and saves on neither side", arguments: [true, false])
    func gestureBehindAQueuedSwitchIsRefused(entering: Bool) async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        if !entering { try await store.enterDemo() }
        let holder = await PromptStoreHolder(store)
        let switching = Task { @MainActor in
            if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(DemoModeStore.isDemoActive == !entering, "the switch has not run yet")
        let realBefore = realStorage()
        let pending = store.gesture("queued behind a switch") { try $0.addBullet(tag, to: .knowledgeBase) }
        try await Task.sleep(for: .milliseconds(100))
        try await holder.end()
        try await switching.value
        #expect(await pending.value == .dropped, "work begun before the switch is refused")
        #expect(!store.rawKB.contains(tag), "the mode now live received none of it")
        #expect(realStorage() == realBefore, "no real state changed")
        #expect(UserDefaults.standard.string(forKey: "demo.user_prompts:user_kb.md")?.contains(tag) != true, "the demo received none of it")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        // Control: the same gesture, made after the switch, saves.
        #expect(await store.gesture("fresh") { try $0.addBullet(tag, to: .knowledgeBase) }.value == .saved)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A gesture queued behind another edit still saves: only a switch refuses it")
    func gestureBehindAnotherEditSaves() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        let first = store.gesture("first") { try $0.addBullet(tag + " first", to: .knowledgeBase) }
        let second = store.gesture("second") { try $0.addBullet(tag + " second", to: .knowledgeBase) }
        try await Task.sleep(for: .milliseconds(100))
        try await holder.end()
        #expect(await first.value == .saved)
        #expect(await second.value == .saved, "the first edit moved the change counter, which a brief operation does not carry")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    // MARK: - Short tools

    /// Blocks the calling (main) thread, which `Task.sleep` would not.
    private static func blockTheMainActor(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    nonisolated private static func run(_ tool: String, tag: String, statement: String) async throws -> String {
        switch tool {
        case "kb_add": return try await KBAddTool().execute(arguments: ["statement": .string(tag + " new")])
        case "kb_del": return try await KBDelTool().execute(arguments: ["statement": .string(statement)])
        case "reminder_add": return try await ReminderAddTool().execute(arguments: ["text": .string(tag + " new")])
        default: return try await ReminderDelTool().execute(arguments: ["text": .string(tag)])
        }
    }

    @Test("A KB or reminder tool made while a switch waits ahead of it is refused and changes neither store",
          arguments: ["kb_add", "kb_del", "reminder_add", "reminder_del"], [true, false])
    func toolBehindAQueuedSwitchIsRefused(tool: String, entering: Bool) async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let statement = tool.hasPrefix("reminder") ? "[Reminder] \(tag)" : "[Pinned] \(tag)"
        #expect(await store.edit("real seed") { try $0.addBullet(statement, to: .knowledgeBase) } == .saved)
        if !entering {
            try await store.enterDemo()
            #expect(await store.edit("demo seed") { try $0.addBullet(statement, to: .knowledgeBase) } == .saved)
        }
        let holder = await PromptStoreHolder(store)
        let switching = Task { @MainActor in
            if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(DemoModeStore.isDemoActive == !entering, "the switch has not run yet")
        let realBefore = realStorage()
        let pending = Task { try await Self.run(tool, tag: tag, statement: statement) }
        try await Task.sleep(for: .milliseconds(100))
        try await holder.end()
        try await switching.value
        let result = try await pending.value
        #expect(result.lowercased().contains("could not save"), "the model is told nothing was saved: \(result)")
        #expect(realStorage() == realBefore, "the old call changed real state")
        let demoKB = UserDefaults.standard.string(forKey: "demo.user_prompts:user_kb.md") ?? ""
        #expect(!demoKB.contains(tag + " new"), "the old call added to the demo")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A KB or reminder tool whose first hop to the main actor is overtaken by a switch is refused",
          arguments: ["kb_add", "kb_del", "reminder_add", "reminder_del"], [true, false])
    func toolOvertakenBeforeItsFirstHopIsRefused(tool: String, entering: Bool) async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let statement = tool.hasPrefix("reminder") ? "[Reminder] \(tag)" : "[Pinned] \(tag)"
        #expect(await store.edit("real seed") { try $0.addBullet(statement, to: .knowledgeBase) } == .saved)
        if !entering {
            try await store.enterDemo()
            #expect(await store.edit("demo seed") { try $0.addBullet(statement, to: .knowledgeBase) } == .saved)
        }
        let realBefore = realStorage()
        let pending = Task.detached { try await Self.run(tool, tag: tag, statement: statement) }
        // The test holds the main actor while the tool runs up to its first hop onto it, then switches without
        // suspending, so the switch is over before the tool's turn on the main actor.
        Self.blockTheMainActor(seconds: 0.3)
        if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        let result = try await pending.value
        #expect(result.lowercased().contains("could not save"), "the model is told nothing was saved: \(result)")
        #expect(realStorage() == realBefore, "the old call changed real state")
        let demoKB = UserDefaults.standard.string(forKey: "demo.user_prompts:user_kb.md") ?? ""
        #expect(!demoKB.contains(tag + " new"), "the old call added to the demo")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A KB tool queued behind an ordinary edit still saves")
    func toolBehindAnotherEditSaves() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        let edit = store.gesture("ahead") { try $0.addBullet(tag + " ahead", to: .knowledgeBase) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = Task { try await KBAddTool().execute(arguments: ["statement": .string(tag + " tool")]) }
        try await Task.sleep(for: .milliseconds(100))
        try await holder.end()
        #expect(await edit.value == .saved)
        #expect(try await pending.value == "Added to knowledge base.")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    // MARK: - First-launch suppression

    @Test("An obsolete first-launch build marks nothing done, whether its list is empty or not", arguments: [true, false])
    func obsoleteSuppressionMarksNothing(empty: Bool) async throws {
        quiet()
        let suite = "tabmail.tests.suppression." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date(), forKey: "firstLaunchDate")
        let overdue = empty ? [] : [Reminder.suppressionProbe(hash: "k:probe")]
        let started = ChangeCounter.device.current
        try await store.enterDemo()
        #expect(!ReminderBuilder.testAutoDisableOverdue(overdue, since: started, defaults: defaults))
        #expect(!defaults.bool(forKey: "didAutoDisableOverdueReminders"), "a refused build must leave the mark unset")
        // Control: the same call, begun after the switch, completes.
        _ = ReminderBuilder.testAutoDisableOverdue(overdue, since: ChangeCounter.device.current, defaults: defaults)
        #expect(defaults.bool(forKey: "didAutoDisableOverdueReminders"), "an uninterrupted build marks the work done")
        try await store.leaveDemo()
    }

    // MARK: - The reminder cache

    @Test("A reminder build that was running when the demo ended cannot supply the next read in the real mode")
    func oldDemoBuildDoesNotWarmTheRealCache() async throws {
        quiet()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switch-reminder-cache-" + UUID().uuidString)
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
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        let tag = "cache-" + UUID().uuidString
        try await pool.write { db in
            var account = Account(emailAddress: "demo@example.com", displayName: "Demo", provider: .gmail)
            account.id = DemoSeed.demoAccountId
            try account.save(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
            try folder.save(db)
            var header = MessageHeader(messageId: tag, subject: "Reminder", from: "Sender", fromAddress: "sender@example.com", to: "demo@example.com", date: Date(), snippet: "", folderId: folder.id, accountId: account.id, folderPath: "INBOX", isInInbox: true)
            header.reminderContent = tag
            header.rfc822MessageId = "<" + tag + "@example.com>"
            try header.insert(db)
        }
        try await store.enterDemo()
        ReminderBuilder.invalidateCache()
        // The build reads the database first; holding the pool's only reader keeps it part-way through, after it
        // took the counter and the mode, while the demo is left.
        let gate = DatabaseReaderGate(pool)
        guard await gate.waitUntilHeld() else { Issue.record("the reader was never taken"); try await store.leaveDemo(); return }
        let pending = Task { await ReminderBuilder.buildReminderList(includeDisabled: true) }
        try await Task.sleep(for: .seconds(1))
        try await store.leaveDemo()
        await gate.release()
        let old = await pending.value
        #expect(old.contains { $0.content == tag }, "control: the build that was running reached the demo's reminder")
        let fresh = await ReminderBuilder.buildReminderList(includeDisabled: true)
        #expect(!fresh.contains { $0.content == tag }, "a fresh read in the real mode reused the finished demo build")
        ReminderBuilder.invalidateCache()
    }
}

private extension Reminder {
    /// An enabled reminder overdue at the first launch.
    static func suppressionProbe(hash: String) -> Reminder {
        let day = Calendar.current.date(byAdding: .day, value: -10, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let due = String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
        return Reminder(type: "reminder", content: "probe", dueDate: due, dueTime: nil, source: "kb", hash: hash, enabled: true,
                        action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
                        instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil)
    }
}
