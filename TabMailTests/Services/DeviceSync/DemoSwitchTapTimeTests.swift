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

    @Test("An install whose count was taken at the tap is refused when a switch ran before its task started; one taken after installs",
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

        // The tap: the count is taken, the task is made, and a switch that does not suspend runs before the task's turn.
        let tapped = store.changeSeen
        let pending = Task { try await store.installMarketplaceTemplate(id: "tap-new", since: tapped, download: { _ in downloaded }) }
        if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        #expect(try await pending.value == .notSaved, "the install made before the switch is refused")
        #expect(stored("user_templates") == realBefore, "the real templates are unchanged")
        #expect(!store.templates.contains { $0.id == "tap-new" }, "nothing was installed in the mode now shown")

        // Control: the same install, tapped after the switch, installs in the mode now live.
        let again = try await store.installMarketplaceTemplate(id: "tap-new", since: store.changeSeen, download: { _ in downloaded })
        #expect(again == .installed("tap-new"))
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    // MARK: - Action rules compaction

    @Test("A compaction whose count was taken at the tap is refused when a switch ran before its task started, and compacts nothing",
          arguments: [true, false])
    func compactOvertakenBeforeItsTaskStartsIsRefused(entering: Bool) async throws {
        quiet()
        defer { DemoModeStore.shared._resetForTests(); PromptStore.removeDemoOverlayKeys() }
        if !entering { try await store.enterDemo() }

        let entered = PromptStore.switchesSeen
        let pending = Task { await AIService.shared.compactActionRulesNow(entered: entered) }
        if entering { try await store.enterDemo() } else { try await store.leaveDemo() }
        let result = await pending.value
        guard case .skipped(let reason) = result else { Issue.record("the compaction made before the switch ran: \(result)"); return }
        #expect(reason.contains("changed"), "it reports that the rules changed: \(reason)")

        // Control: a count taken after the switch is accepted by the same read.
        let control = await store.readBeforeAI(.action, "tap control", entered: PromptStore.switchesSeen)
        guard case .read = control else { Issue.record("control: a count taken after the switch was refused"); return }
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    // MARK: - Source fence

    /// The two taps take their count before they make their task. The fence reads the source at run time.
    @Test("The marketplace install and the compaction button take their count before their task is made")
    func tapsSampleBeforeTheirTask() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        /// The count is taken before the first `Task {` that follows `anchor`.
        func sampledBeforeTheTask(_ path: String, anchor: String, sample: String) throws -> Bool {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            guard let start = source.range(of: anchor) else { return false }
            let rest = source[start.upperBound...]
            guard let sampled = rest.range(of: sample), let tasked = rest.range(of: "Task {") else { return false }
            return sampled.lowerBound < tasked.lowerBound
        }
        #expect(try sampledBeforeTheTask("TabMail/Views/Settings/MarketplaceTemplateDetailView.swift",
                                         anchor: "Button {", sample: "let started = store.changeSeen"))
        #expect(try sampledBeforeTheTask("TabMail/Views/Settings/ActionRulesView.swift",
                                         anchor: "func start()", sample: "let entered = PromptStore.switchesSeen"))
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
