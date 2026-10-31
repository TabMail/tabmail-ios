/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import Synchronization
import Testing
@testable import TabMail

/// The invariants of the prompt store that the per-operation tests did not assert, each checked on persisted
/// state with a positive control: the counter an accepted restore renews (DS-COUNTER), the observation
/// dependency of the displayed bullets (DS-DISPLAYED), the demo never touching the real store (DS-DEMO), the
/// identities a received message must carry before it waits in line (DS-VALIDATE), and the section markers
/// a model's patch can never write.
@MainActor
@Suite("Prompt store invariants", .serialized, .processGlobalState)
struct PromptStoreInvariantTests {
    let store = PromptStore.shared
    private final class ObservationFlag: Sendable { let value = Mutex(false) }

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
    }

    private func read() async throws -> PromptCapture {
        guard case .read(let capture) = await store.readBeforeAI(.kb, "invariant read") else { throw DeviceSyncTestError("read refused") }
        return capture
    }

    /// Every real key the store writes: the bullets' state, the three rendered texts, the templates and the
    /// history. The demo's keys are not among them.
    private func realStorage() -> [String: Data?] {
        let defaults = UserDefaults.standard
        let keys = [UserDefaultsBulletStore.stateKey] + Array(UserDefaultsBulletStore.renderedKeys.values)
            + ["user_templates", "prompt_history"]
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8))
        })
    }

    /// Runs `body` with the demo overlay entered, and leaves the demo as it was found.
    private func inDemo(_ body: () async throws -> Void) async rethrows {
        DemoModeStore.shared._resetForTests()
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        defer {
            if DemoModeStore.isDemoActive { store.exitDemoOverlay() }
            DemoModeStore.shared._resetForTests()
            PromptStore.removeDemoOverlayKeys()
        }
        try await body()
    }

    @Test("A saved change invalidates a view that read the displayed bullets (DS-DISPLAYED)")
    func shownBulletChangesInvalidateTheView() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let changed = ObservationFlag()
        let control = ObservationFlag()
        let before = withObservationTracking { store.shown(.knowledgeBase).map(\.text) } onChange: { changed.value.withLock { $0 = true } }
        _ = withObservationTracking { store.rawKB } onChange: { control.value.withLock { $0 = true } }
        #expect(!before.contains(tag))
        #expect(await store.edit("invariant add") { try $0.addBullet(tag, to: .knowledgeBase) } == .saved)
        #expect(store.shown(.knowledgeBase).contains { $0.text == tag })
        #expect(control.value.withLock { $0 }, "positive control: the rendered text is observable")
        #expect(changed.value.withLock { $0 }, "the list read is invalidated by the saved change")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("An accepted restore of identical text still refuses an AI write read before it (DS-COUNTER)")
    func identicalRestoreInvalidatesOlderAI() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let capture = try await read()
        let oldCounter = store.semaphore.counter
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templates = String(decoding: try encoder.encode(store.templates), as: UTF8.self)
        let entry = PromptHistoryEntry(id: UUID().uuidString, timestamp: Date().ISO8601Format(), source: "local_edit", fields: ["kb"],
                                       composition: store.rawComposition, action: store.rawAction, kb: store.rawKB, templatesJSON: templates)
        #expect(await store.edit("invariant restore") { try $0.restoreFromHistory(entry); return .saved } == .saved)
        #expect(store.semaphore.counter != oldCounter, "every accepted restore moves the counter")
        #expect(await store.writeAfterRead(capture, text: capture.text + "\n- " + tag, "invariant late AI") == .dropped)
        #expect(!store.rawKB.contains(tag), "an older AI result does not land after the restore")
        // Positive control: an AI write read after the restore lands.
        let fresh = try await read()
        #expect(await store.writeAfterRead(fresh, text: fresh.text + "\n- " + tag, "invariant fresh AI") == .saved)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A demo gesture waiting on the semaphore when the demo ends writes nothing real (DS-DEMO)")
    func queuedDemoGestureStaysInDemo() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let realBefore = realStorage()
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let holder = await PromptStoreHolder(store)
        let pending = store.gesture("demo gesture") { try $0.addBullet(tag, to: .knowledgeBase) }
        try await Task.sleep(for: .milliseconds(100))
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        try await holder.end()
        #expect(await pending.value == .dropped)
        #expect(realStorage() == realBefore)
        #expect(!store.rawKB.contains(tag), "demo work never becomes real device data")
        // Positive control: the same gesture made outside the demo saves.
        #expect(await store.gesture("real gesture") { try $0.addBullet(tag, to: .knowledgeBase) }.value == .saved)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A demo gesture is a demo gesture even when the demo ends before its task first runs (DS-DEMO)")
    func gestureTargetIsFixedWhenMade() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let realBefore = realStorage()
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        // No await between the gesture and the end of the demo: the gesture's task has not run yet.
        let pending = store.gesture("demo gesture") { try $0.addBullet(tag, to: .knowledgeBase) }
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        #expect(await pending.value == .dropped)
        #expect(realStorage() == realBefore)
        #expect(!store.rawKB.contains(tag))
    }

    @Test("A real gesture waiting on the semaphore when the demo starts lands in the real store and never in the demo (DS-DEMO)")
    func queuedRealGestureStaysOutOfTheDemo() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        let pending = store.gesture("real gesture") { try $0.addBullet(tag, to: .knowledgeBase) }
        try await Task.sleep(for: .milliseconds(100))
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let overlay = store.rawKB
        try await holder.end()
        #expect(await pending.value == .saved, "its target was chosen when it was made")
        #expect(store.rawKB == overlay, "the demo shows no real text")
        #expect(UserDefaults.standard.string(forKey: "demo.user_prompts:user_kb.md") == overlay, "nothing reached the demo's key")
        #expect(UserDefaults.standard.string(forKey: "user_prompts:user_kb.md")?.contains(tag) == true, "the real text has it")
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        #expect(store.rawKB.contains(tag), "the real text is shown again on exit")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("An AI result read before the demo started lands in the real store when the demo has started (DS-DEMO, DS-AI)")
    func realAIResultSurvivesDemoEntry() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let capture = try await read()
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let overlay = store.rawKB
        #expect(await store.writeAfterRead(capture, text: capture.text + "\n- \(tag)\n", "real AI write") == .saved)
        #expect(store.rawKB == overlay, "the demo shows no real text")
        #expect(UserDefaults.standard.string(forKey: "user_prompts:user_kb.md")?.contains(tag) == true)
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        #expect(store.rawKB.contains(tag))
        // Control: a demo-captured result is dropped once the demo is over, and writes nothing real.
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let demoCapture = try await read()
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        let realBefore = realStorage()
        #expect(await store.writeAfterRead(demoCapture, text: demoCapture.text + "\n- \(tag) demo\n", "demo AI write") == .dropped)
        #expect(realStorage() == realBefore)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("Entering the demo seeds all three rendered texts, so the background snapshots read the overlay (DS-DEMO)")
    func demoEntrySeedsTheSnapshots() async {
        quiet()
        await inDemo {
            #expect(!store.rawKB.isEmpty)
            #expect(PromptStore.kbTextSnapshot() == store.rawKB)
            #expect(PromptStore.actionMarkdownSnapshot() == store.rawAction)
            #expect(UserDefaults.standard.string(forKey: "demo.user_prompts:user_composition.md") == store.rawComposition)
        }
    }

    @Test("No demo writer touches a real key or moves the counter, whichever way it writes (DS-DEMO)")
    func demoWritersNeverTouchTheRealStore() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let realBefore = realStorage()
        let counter = store.semaphore.counter
        var writers: [(String, () async throws -> Void)] = []
        for section in PromptSection.allCases {
            writers.append(("add \(section.key)", { _ = await store.edit("demo add") { try $0.addBullet(tag, to: section) } }))
            writers.append(("delete \(section.key)", {
                for shown in store.shown(section) {
                    _ = await store.edit("demo delete") { try $0.deleteShown(shown, from: section) }
                }
            }))
        }
        for field in BulletField.allCases {
            writers.append(("editText \(field.rawValue)", { _ = await store.edit("demo edit") { try $0.editText(field) { $0 + "\n- \(tag)" } } }))
            writers.append(("capture and commit \(field.rawValue)", {
                _ = await store.edit("demo commit") { access in
                    guard let capture = try access.readForEdit(field) else { return .unsaved }
                    return try access.commitEdit(capture, text: capture.text + "\n- \(tag)")
                }
            }))
            writers.append(("AI write \(field.rawValue)", {
                guard case .read(let capture) = await store.readBeforeAI(field, "demo AI read") else { return }
                _ = await store.writeAfterRead(capture, text: capture.text + "\n- \(tag)", "demo AI write")
            }))
            writers.append(("reset \(field.rawValue)", { _ = await store.edit("demo reset") { try $0.reset(field); return .saved } }))
        }
        writers.append(("restore", {
            let entry = PromptHistoryEntry(id: UUID().uuidString, timestamp: Date().ISO8601Format(), source: "local_edit", fields: ["kb"],
                                           composition: "", action: "", kb: "", templatesJSON: "[]")
            _ = await store.edit("demo restore") { try $0.restoreFromHistory(entry); return .saved }
        }))
        writers.append(("add template", { store.addTemplate() }))
        writers.append(("reset templates", { store.resetTemplates() }))
        writers.append(("receive", {
            await #expect(throws: PromptRefusal.changed) {
                try await store.withPromptStore("demo receive") { _ = try $0.receive(ForeignJSON.kb(tag)) }
            }
        }))
        writers.append(("send all", {
            await #expect(throws: PromptRefusal.changed) { try await store.withPromptStore("demo send") { try $0.sendAll() } }
        }))

        try await inDemo {
            // Positive control: a demo writer writes, to the overlay.
            _ = await store.edit("demo control") { try $0.addBullet(tag, to: .knowledgeBase) }
            #expect(store.rawKB.contains(tag))
            for (name, writer) in writers {
                try await writer()
                #expect(realStorage() == realBefore, "\(name) left the real store as it was")
                #expect(store.semaphore.counter == counter, "\(name) left the counter as it was")
            }
        }
        #expect(realStorage() == realBefore)
    }

    @Test("Two bullets whose texts differ only by Unicode normalization are two rows with two identities (DS-DISPLAYED)")
    func canonicallyEquivalentBulletsAreTwoRows() async {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        #expect(await store.edit("add composed") { try $0.addBullet("\(tag) caf\u{E9}", to: .knowledgeBase) } == .saved)
        #expect(await store.edit("add decomposed") { try $0.addBullet("\(tag) cafe\u{301}", to: .knowledgeBase) } == .saved)
        let rows = store.shown(.knowledgeBase).filter { $0.text.contains(tag) }
        #expect(rows.count == 2, "the store keeps both")
        #expect(Set(rows.map(\.id)).count == 2, "a list of them has two row identities")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A write interrupted between the labelled state and the rendered text is repaired when the store opens (DS-ATOMIC)")
    func interruptedWriteIsRepairedAtOpen() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let defaults = UserDefaults.standard
        let key = "user_prompts:user_kb.md"
        let stale = try #require(defaults.string(forKey: key))
        #expect(await store.edit("interrupted add") { try $0.addBullet(tag, to: .knowledgeBase) } == .saved)
        let current = try #require(defaults.string(forKey: key))
        #expect(current.contains(tag))
        // The interruption: the labelled state holds the new bullet, the rendered text is the old one.
        defaults.set(stale, forKey: key)
        let catalog = try #require(Bundle.main.url(forResource: "device-sync-default-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? DefaultCatalog.decode($0) })
        PromptStore.syncRenderedKeys(UserDefaultsBulletStore(defaults: defaults), defaults: defaults, catalog: catalog)
        #expect(defaults.string(forKey: key) == current, "the rendered text is the labelled state's again")
        // Control: a store that is already consistent is left as it is.
        PromptStore.syncRenderedKeys(UserDefaultsBulletStore(defaults: defaults), defaults: defaults, catalog: catalog)
        #expect(defaults.string(forKey: key) == current)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A rendered text that differs from the labelled state only in canonically equivalent bytes is replaced by its exact bytes (DS-ATOMIC)")
    func repairReplacesByteDifferentCanonicallyEqualText() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let defaults = UserDefaults.standard
        let key = "user_prompts:user_kb.md"
        #expect(await store.edit("composed add") { try $0.addBullet("\(tag) caf\u{E9}", to: .knowledgeBase) } == .saved)
        let current = try #require(defaults.string(forKey: key))
        let decomposed = current.decomposedStringWithCanonicalMapping
        #expect(decomposed == current, "canonically equal")
        #expect(Array(decomposed.utf8) != Array(current.utf8), "but not the same bytes")
        defaults.set(decomposed, forKey: key)
        let catalog = try #require(Bundle.main.url(forResource: "device-sync-default-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? DefaultCatalog.decode($0) })
        PromptStore.syncRenderedKeys(UserDefaultsBulletStore(defaults: defaults), defaults: defaults, catalog: catalog)
        #expect(Array(try #require(defaults.string(forKey: key)).utf8) == Array(current.utf8), "the state's exact bytes are rendered again")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A message without a string sender, field and snapshot id is dropped before it waits in line (DS-VALIDATE)")
    func malformedIdentityCannotDisplaceValidReceive() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        DeviceSyncService.shared.handleMessage(ForeignBulletMessage.kb(tag))
        let invalid = #"{"type":"bullet_state","v":1,"field":"kb","sender":7,"snap":"bad","part":1,"parts":1,"bullets":[],"seen":{}}"#
        for _ in 0..<BulletSyncConfig.maxWaitingReceives { DeviceSyncService.shared.handleMessage(invalid) }
        try await holder.end()
        try await Task.sleep(for: .seconds(1))
        #expect(store.rawKB.contains(tag), "the valid snapshot survives the invalid ones")
        // Positive control: a valid message received afterwards applies.
        let control = tag + " control"
        DeviceSyncService.shared.handleMessage(ForeignBulletMessage.kb(control))
        try await Task.sleep(for: .seconds(1))
        #expect(store.rawKB.contains(control))
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A model's patch holding a section marker is refused, so no rule leaves another section")
    func actionPatchMarkerCannotDeleteOtherSections() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        #expect(await store.edit("invariant seed") { try $0.addBullet(tag, to: .archiveRules) } == .saved)
        let content = store.rawAction
        #expect(ActionPatchApplier.applyActionPatch(content: content, patchText: "ADD\ndelete\n" + Bullets.instructionsEnd) == nil)
        #expect(ActionPatchApplier.applyActionPatch(content: content, patchText: "ADD\ndelete\nrule " + Bullets.headerMark) == nil)
        #expect(store.bullets(.archiveRules).contains(tag), "an ADD cannot remove a rule from another section")
        // Positive control: an ordinary patch applies.
        #expect(ActionPatchApplier.applyActionPatch(content: content, patchText: "ADD\ndelete\n" + tag + " ordinary") != nil)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A real AI result queued behind a holder while the demo starts and ends lands in the real store (DS-DEMO, DS-AI)")
    func queuedRealAIResultSurvivesDemoStartAndEnd() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let capture = try await read()
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let holder = await PromptStoreHolder(store)
        let pending = Task { await store.writeAfterRead(capture, text: capture.text + "\n- \(tag)\n", "queued real AI write") }
        try await Task.sleep(for: .milliseconds(100))
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        try await holder.end()
        #expect(await pending.value == .saved, "its target is the capture's, not the mode when it runs")
        #expect(UserDefaults.standard.string(forKey: "user_prompts:user_kb.md")?.contains(tag) == true)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A knowledge-base tool call made before the demo starts writes the real store even if the demo starts first (DS-DEMO)")
    func toolTargetIsFixedWhenCalled() async throws {
        quiet()
        DemoModeStore.shared._resetForTests()
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        let call = Task { try await KBAddTool().execute(arguments: ["statement": .string("\(tag) tool fact")]) }
        try await Task.sleep(for: .milliseconds(100))
        DemoModeStore.shared.isActive = true
        store.enterDemoOverlay()
        let overlay = store.rawKB
        try await holder.end()
        _ = try await call.value
        #expect(store.rawKB == overlay, "the demo shows no real text")
        #expect(UserDefaults.standard.string(forKey: "demo.user_prompts:user_kb.md") == overlay, "nothing reached the demo's key")
        #expect(UserDefaults.standard.string(forKey: "user_prompts:user_kb.md")?.contains("\(tag) tool fact") == true, "the real text has it")
        store.exitDemoOverlay()
        DemoModeStore.shared._resetForTests()
        PromptStore.removeDemoOverlayKeys()
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }
}

/// A `bullet_state` message as the JSON object the engine receives.
private enum ForeignJSON {
    @MainActor
    static func kb(_ text: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(ForeignBulletMessage.kb(text).utf8))
        return object as? [String: Any] ?? [:]
    }
}
