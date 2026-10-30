/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// Invariant tests at the prompt store's boundaries (§12.3): every operation that awaits is interrupted by
// a lease expiry, a reset, and a newer local edit, and the newer edit is kept, nothing older lands on a
// newer state, and an uninterrupted control succeeds. They run on the test host's real prompt store.

@MainActor
@Suite("Prompt store boundaries", .serialized, .processGlobalState)
struct PromptStoreBoundaryTests {
    private let store = PromptStore.shared

    private func read(_ field: BulletField) async throws -> PromptCapture {
        guard case .read(let capture) = await store.readBeforeAI(field, "boundary read") else {
            throw DeviceSyncTestError("no read of \(field.rawValue)")
        }
        return capture
    }

    // MARK: - DS-AI: a write that read before a change is dropped, whatever the change was

    @Test("An AI write is dropped after a newer local edit, which is kept; a fresh read writes (DS-AI)")
    func aiWriteAfterLocalEdit() async throws {
        let tag = PromptStoreTestCleanup.tag()
        let capture = try await read(.kb)
        let local = await store.edit("local edit") { try $0.addBullet("\(tag) local", to: .knowledgeBase) }
        #expect(local == .saved)
        let dropped = await store.writeAfterRead(capture, text: capture.text + "\n- \(tag) ai", "boundary write")
        #expect(dropped == .dropped)
        #expect(store.rawKB.contains("\(tag) local"))
        #expect(!store.rawKB.contains("\(tag) ai"))

        let fresh = try await read(.kb)
        let saved = await store.writeAfterRead(fresh, text: fresh.text + "\n- \(tag) ai", "boundary write")
        #expect(saved == .saved, "the uninterrupted control writes")
        #expect(store.rawKB.contains("\(tag) ai"))
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("An AI write is dropped after a reset, which is kept (DS-AI, DS-RESET)")
    func aiWriteAfterReset() async throws {
        let tag = PromptStoreTestCleanup.tag()
        let added = await store.edit("add") { try $0.addBullet("\(tag) rule", to: .deleteRules) }
        #expect(added == .saved)
        let capture = try await read(.action)
        let reset = await store.edit("reset") { try $0.reset(.action); return .saved }
        #expect(reset == .saved)
        let afterReset = store.rawAction
        let dropped = await store.writeAfterRead(capture, text: capture.text + "\n- \(tag) ai", "boundary write")
        #expect(dropped == .dropped)
        #expect(store.rawAction == afterReset, "nothing older lands on the reset")
        #expect(!store.rawAction.contains(tag))
        let fresh = try await read(.action)
        #expect(await store.writeAfterRead(fresh, text: fresh.text, "boundary write") != .dropped, "the uninterrupted control isn't dropped")
    }

    @Test("An AI write is dropped after a restore, which is kept (DS-AI, DS-RESTORE)")
    func aiWriteAfterRestore() async throws {
        let tag = PromptStoreTestCleanup.tag()
        let capture = try await read(.kb)
        let entry = PromptHistoryEntry(id: UUID().uuidString, timestamp: Date().ISO8601Format(), source: "local_edit",
                                       fields: ["kb"], composition: store.rawComposition, action: store.rawAction,
                                       kb: capture.text + "\n- \(tag) restored", templatesJSON: "[]")
        let restored = await store.edit("restore") { try $0.restoreFromHistory(entry); return .saved }
        #expect(restored == .saved)
        #expect(store.rawKB.contains("\(tag) restored"))
        let dropped = await store.writeAfterRead(capture, text: capture.text + "\n- \(tag) ai", "boundary write")
        #expect(dropped == .dropped, "a restore moves the counter (DS-COUNTER)")
        #expect(store.rawKB.contains("\(tag) restored"))
        #expect(!store.rawKB.contains("\(tag) ai"))
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("Nothing but a saved change moves the counter: an unchanged edit and a refused one leave it")
    func counterMovesOnlyOnSavedChanges() async throws {
        let before = store.semaphore.counter
        let unchanged = await store.edit("no change") { try $0.editText(.kb) { _ in nil } }
        #expect(unchanged == .unchanged)
        #expect(store.semaphore.counter == before)
        let tag = PromptStoreTestCleanup.tag()
        let saved = await store.edit("add") { try $0.addBullet("\(tag) counter", to: .knowledgeBase) }
        #expect(saved == .saved)
        #expect(store.semaphore.counter != before)
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    // MARK: - DS-LEASE: an expired holder saves nothing, wherever it was

    /// One operation of each kind that writes, and the same one's read of the stored state.
    private func operations(tag: String, capture: PromptCapture, shown: ShownBullet) -> [(name: String, run: (PromptAccess) throws -> Void)] {
        [
            ("add", { _ = try $0.addBullet("\(tag) lease add", to: .knowledgeBase) }),
            ("editText", { _ = try $0.editText(.kb) { $0 + "\n- \(tag) lease edit\n" } }),
            ("commitEdit", { _ = try $0.commitEdit(capture, text: capture.text + "\n- \(tag) lease commit\n") }),
            ("commitAIEdit", { _ = try $0.commitAIEdit(capture, text: capture.text + "\n- \(tag) lease ai\n") }),
            ("deleteShown", { _ = try $0.deleteShown(shown, from: .knowledgeBase) }),
            ("reset", { try $0.reset(.kb) }),
            ("receive", { _ = try $0.receive(Self.object(ForeignBulletMessage.kb("\(tag) lease receive"))) }),
            ("sendAll", { try $0.sendAll() }),
            ("recordHistory", { try $0.recordHistory(source: "local_edit", fields: ["kb"]) }),
            ("saveHistory", { try $0.saveHistory([]) }),
            ("readForEdit", { _ = try $0.readForEdit(.kb) }),
        ]
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test("A hold past its lease saves and reads nothing, on every operation (DS-LEASE, I4)")
    func expiredHolderWritesNothing() async throws {
        let defaults = UserDefaults.standard
        let tag = PromptStoreTestCleanup.tag()
        let seeded = await store.edit("seed") { try $0.addBullet("\(tag) seed", to: .knowledgeBase) }
        #expect(seeded == .saved)
        let capture = try await read(.kb)
        let shown = try #require(store.shown(.knowledgeBase).first { $0.text.contains(tag) })
        // The seed's own debounced history entry (2 s) lands first, so the baselines below are settled.
        try await Task.sleep(for: .milliseconds(2500))
        let config = store.semaphore.config
        store.semaphore.config = PromptSemaphore.Config(leaseSeconds: 0.05, retries: config.retries, retryBaseDelayMs: config.retryBaseDelayMs, retryJitterMs: config.retryJitterMs)
        defer { store.semaphore.config = config }
        let ops = operations(tag: tag, capture: capture, shown: shown)
        for (name, run) in ops {
            let storedBefore = defaults.data(forKey: UserDefaultsBulletStore.stateKey)
            let rawBefore = [store.rawComposition, store.rawAction, store.rawKB]
            let historyBefore = defaults.data(forKey: "prompt_history")
            do {
                try await store.withPromptStore("lease \(name)") { access in
                    try await Task.sleep(for: .milliseconds(200))
                    try run(access)
                }
                Issue.record("\(name): an expired hold wasn't refused")
            } catch PromptRefusal.changed {
                // refused
            }
            #expect(defaults.data(forKey: UserDefaultsBulletStore.stateKey) == storedBefore, "\(name): the stored state changed")
            #expect([store.rawComposition, store.rawAction, store.rawKB] == rawBefore, "\(name): the rendered text changed")
            #expect(defaults.data(forKey: "prompt_history") == historyBefore, "\(name): the history changed")
        }
        store.semaphore.config = config
        // The uninterrupted control: the same operations in a live hold are not refused.
        for (name, run) in ops where !["reset", "deleteShown", "commitAIEdit", "commitEdit"].contains(name) {
            do {
                try await store.withPromptStore("control \(name)") { try run($0) }
            } catch {
                Issue.record("\(name): the uninterrupted control failed: \(error)")
            }
        }
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("Disconnect and a nested call never wait: the second is refused at once (I4, DS-NESTED)")
    func neverAnInfiniteBlock() async throws {
        let holder = await PromptStoreHolder(store)
        let config = store.semaphore.config
        store.semaphore.config = PromptSemaphore.Config(leaseSeconds: config.leaseSeconds, retries: 1, retryBaseDelayMs: 10, retryJitterMs: 0)
        defer { store.semaphore.config = config }
        let started = ContinuousClock.now
        let outcome = await store.edit("busy") { _ in .saved }
        #expect(outcome == .busy)
        #expect(ContinuousClock.now - started < .seconds(2))
        // Disconnecting while the store is held returns at once and holds nothing.
        DeviceSyncService.shared.disconnect()
        try await holder.end()
        store.semaphore.config = config
        #expect(await store.edit("free") { _ in .unchanged } == .unchanged)
    }
}
