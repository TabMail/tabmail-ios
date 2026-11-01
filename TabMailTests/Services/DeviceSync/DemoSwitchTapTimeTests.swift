/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// An operation starts at the user's tap, not at the first turn of the task the tap makes (DS-DEMO). The marketplace
/// install and the action-rules compaction are the two taps whose task awaits a long step before it writes: each
/// takes its count in the tap, before the task, and a demo switch between the tap and the task's start refuses it.
/// The tests drive the production tap entry points (`beginMarketplaceInstall`, `ActionCompactionMonitor.start`).
/// The reminder snapshot gives a build the change counter and the mode as one pair.
@MainActor
@Suite("Operations that start at a tap, and the mode snapshot", .serialized, .processGlobalState)
struct DemoSwitchTapTimeTests {
    let store = PromptStore.shared

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        AIService.writeOptOutFlag(false)
        DemoModeStore.shared._resetForTests()
    }

    private func stored(_ key: String) -> Data? { UserDefaults.standard.data(forKey: key) }

    // MARK: - Marketplace install

    @Test("An install tapped before a switch that runs before its task starts is refused and saves nothing; one tapped after installs",
          arguments: [true, false])
    func installOvertakenBeforeItsTaskStartsIsRefused(entering: Bool) async throws {
        quiet()
        let saved = store.templates
        defer {
            DemoModeStore.shared._resetForTests()
            PromptStore.removeDemoOverlayKeys()
            store.applySyncedTemplates(saved)
        }
        store.applySyncedTemplates([ReplyTemplate(id: "tap-real", name: "Tap real")])
        if !entering { try await store.enterDemo() }
        let downloaded = TemplateMarketplaceClient.DownloadedTemplate(id: "tap-new", name: "Tap new", instructions: ["Be brief"], exampleReply: "Thanks", enabled: true)
        let realBefore = stored("user_templates")

        // The tap: the store takes the count, makes the task, and a switch that does not suspend runs before the task's turn.
        let pending = store.beginMarketplaceInstall(id: "tap-new", download: { _ in downloaded })
        if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        #expect(try await pending.value == .notSaved, "the install tapped before the switch is refused")
        #expect(stored("user_templates") == realBefore, "the real templates are unchanged")
        #expect(!store.templates.contains { $0.id == "tap-new" }, "nothing was installed in the mode now shown")

        // Control: the same tap, after the switch, installs in the mode now live.
        let again = try await store.beginMarketplaceInstall(id: "tap-new", download: { _ in downloaded }).value
        #expect(again == .installed("tap-new"))
        #expect(store.templates.contains { $0.id == "tap-new" && !$0.deleted })
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    // MARK: - Action rules compaction

    @Test("A compaction tapped before a switch that runs before its task starts is refused; one tapped after reaches its ordinary read",
          arguments: [true, false])
    func compactOvertakenBeforeItsTaskStartsIsRefused(entering: Bool) async throws {
        quiet()
        // An offline fixture: even a monitor that reached its model call could not send a request.
        DemoModeStore.shared.isTutorialPractice = true
        defer { DemoModeStore.shared._resetForTests(); PromptStore.removeDemoOverlayKeys() }
        if !entering { try await store.enterDemo() }
        let monitor = ActionCompactionMonitor()
        monitor.start()
        if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        try await settle(monitor)
        #expect(monitor.statusMessage?.contains("Rules changed") == true, "the stale tap was not refused: \(monitor.statusMessage ?? "nil")")

        // Control: with no switch between the tap and the task, the same monitor passes the read of the rules.
        monitor.start()
        try await settle(monitor)
        #expect(monitor.statusMessage != nil && monitor.statusMessage?.contains("Rules changed") == false, "control: \(monitor.statusMessage ?? "nil")")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    private func settle(_ monitor: ActionCompactionMonitor) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while monitor.isRunning, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!monitor.isRunning, "the compaction finished")
    }

    // MARK: - Mode snapshot

    private final class Flag: Sendable {
        let value = Mutex(false)
    }

    private final class Captured: Sendable {
        let value = Mutex<(counter: UUID, demoActive: Bool)?>(nil)
    }

    private static func blockTheMainActor(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    @Test("A snapshot taken while a switch is part-way through never pairs the old mode with the new counter or the reverse",
          arguments: [true, false])
    func snapshotIsConsistentAcrossAFlip(entering: Bool) async throws {
        quiet()
        defer { DemoModeStore.shared._resetForTests(); PromptStore.removeDemoOverlayKeys() }
        if !entering { try await store.enterDemo() }
        let flipping = Flag()
        let captured = Captured()
        let done = Flag()
        DispatchQueue.global().async {
            while !flipping.value.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
            captured.value.withLock { $0 = DisabledRemindersStore.modeSnapshot() }
            done.value.withLock { $0 = true }
        }
        var after: UUID?
        DisabledRemindersStore.switching(toDemo: entering) {
            DemoModeStore.shared.isActive = entering
            flipping.value.withLock { $0 = true }
            // The snapshot is asked for now, between the mode and the counter.
            Self.blockTheMainActor(seconds: 0.3)
            store.semaphore.renewCounterForSwitch()
            after = store.semaphore.counter
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await Self.wait(done), "the snapshot returned")
        let snapshot = try #require(captured.value.withLock { $0 })
        #expect(snapshot.demoActive == entering, "the snapshot has the mode after the flip")
        #expect(snapshot.counter == after, "the snapshot has the counter after the flip")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    private static func wait(_ flag: Flag) async -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if flag.value.withLock({ $0 }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
