/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Parks the model's response until the test releases it.
private final class ResponseGate: @unchecked Sendable {
    private let flags = Mutex((started: false, timedOut: false))
    private let unblock = DispatchSemaphore(value: 0)
    var started: Bool { flags.withLock { $0.started } }
    var timedOut: Bool { flags.withLock { $0.timedOut } }

    func park() {
        flags.withLock { $0.started = true }
        if unblock.wait(timeout: .now() + 30) == .timedOut { flags.withLock { $0.timedOut = true } }
    }

    func release() { unblock.signal() }
}

/// A writer whose model call another edit interrupts (DS-AI, DS-COUNTER): the response arrives after the
/// user's newer edit and must not replace it. Each runs the real writer against a mock backend that parks
/// the response, with an uninterrupted control that persists the same response.
@MainActor
@Suite("Prompt store writers interrupted by an edit", .serialized, .processGlobalState)
struct PromptWriterInterruptionTests {
    let store = PromptStore.shared

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        AIService.writeOptOutFlag(false)
    }

    private func backend(_ payload: [String: Any], gate: ResponseGate) throws -> (BackendClient, FakeHTTP.Scenario) {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let body = Data(("event: final\ndata: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST") { _ in
            .parked { gate.park(); return .bytes(body, contentType: "text/event-stream") }
        }
        return (BackendClient(llmSession: http.session), http)
    }

    private func untilStarted(_ gate: ResponseGate) async throws -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while !gate.started, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        return gate.started
    }

    private func persisted(_ field: BulletField) -> String {
        UserDefaults.standard.string(forKey: UserDefaultsBulletStore.renderedKeys[field] ?? "") ?? ""
    }

    private func turns() -> [ChatTurn] {
        ["user", "assistant", "user", "assistant", "user", "assistant"].map { role in
            ChatTurn(id: ChatTurn.generateId(), timestamp: Date().timeIntervalSince1970 * 1000, role: role, content: "text",
                     userMessage: role == "user" ? "text" : nil, type: "normal", chars: 4, renderedContent: nil, sessionId: nil,
                     remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        }
    }

    @Test("A knowledge base refinement answered after a newer edit keeps the edit; uninterrupted, it persists")
    func refinementInterruptedByNewerEdit() async throws {
        quiet()
        for interrupt in [false, true] {
            let tag = PromptStoreTestCleanup.tag()
            let gate = ResponseGate()
            let (client, http) = try backend(["refined_kb": store.rawKB + "\n- \(tag) old AI result"], gate: gate)
            defer { http.close() }
            let service = KBRefinementService(backendClient: client)
            let pending = Task { await service.refineKB(sessionTurns: turns()) }
            guard try await untilStarted(gate) else {
                gate.release(); await pending.value
                Issue.record("the request did not reach the parked backend")
                return
            }
            if interrupt { #expect(await store.edit("newer KB edit") { try $0.addBullet("\(tag) newer user edit", to: .knowledgeBase) } == .saved) }
            gate.release(); await pending.value
            #expect(!gate.timedOut)
            #expect(persisted(.kb).contains("\(tag) old AI result") == !interrupt)
            if interrupt { #expect(persisted(.kb).contains("\(tag) newer user edit"), "the newer edit is durable") }
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }

    @Test("A compaction answered after a newer edit keeps the edit and does not report applying; uninterrupted, it persists")
    func compactionInterruptedByNewerEdit() async throws {
        quiet()
        for interrupt in [false, true] {
            let tag = PromptStoreTestCleanup.tag()
            let gate = ResponseGate()
            let assistant = String(decoding: try JSONSerialization.data(withJSONObject: ["patch": "ADD\ndelete\n\(tag) old AI result"]), as: UTF8.self)
            let (client, http) = try backend(["assistant": assistant], gate: gate)
            defer { http.close() }
            let service = AIService(backendClient: client)
            let pending = Task { await service.compactActionRulesNow() }
            guard try await untilStarted(gate) else {
                gate.release(); _ = await pending.value
                Issue.record("the request did not reach the parked backend")
                return
            }
            if interrupt { #expect(await store.edit("newer rule edit") { try $0.addBullet("\(tag) newer user edit", to: .archiveRules) } == .saved) }
            gate.release()
            let result = await pending.value
            #expect(!gate.timedOut)
            #expect(persisted(.action).contains("\(tag) old AI result") == !interrupt)
            if interrupt {
                #expect(persisted(.action).contains("\(tag) newer user edit"), "the newer edit is durable")
                if case .applied = result { Issue.record("a stale compaction reported that it applied") }
            } else if case .applied = result {
            } else {
                Issue.record("the uninterrupted control did not apply: \(result)")
            }
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }
}

/// The queue's action-refine dispatch, run as the drain runs it with a mock backend: the snapshot's input reaches the
/// request, the returned patch changes the stored rules, and a result answered after a newer edit is dropped.
@MainActor
@Suite("Queued action refine", .serialized, .processGlobalState)
struct QueuedActionRefineTests {
    let store = PromptStore.shared

    private func persisted() -> String {
        UserDefaults.standard.string(forKey: UserDefaultsBulletStore.renderedKeys[.action] ?? "") ?? ""
    }

    private func snapshot(_ tag: String) -> ActionRefineSnapshot {
        ActionRefineSnapshot(messageStableId: "msg-\(tag)", accountId: "acc-\(tag)", subject: "\(tag) subject", from: "sender@example.com",
                             summaryBlurb: "Planning notes.", summaryTodos: nil, originalAction: "archive", userManualTag: "delete")
    }

    @Test("A dispatched refine sends the snapshot's input and persists its patch; one answered after a newer edit is dropped")
    func dispatchPersistsOrDrops() async throws {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        AIService.writeOptOutFlag(false)
        for interrupt in [false, true] {
            let tag = PromptStoreTestCleanup.tag()
            let gate = ResponseGate()
            let assistant = String(decoding: try JSONSerialization.data(withJSONObject: ["patch": "ADD\ndelete\n\(tag) old AI result"]), as: UTF8.self)
            let data = try JSONSerialization.data(withJSONObject: ["assistant": assistant])
            let body = Data(("event: final\ndata: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
            let http = FakeHTTP.Scenario()
            http.register(path: "/completions/chat", method: "POST") { _ in
                .parked { gate.park(); return .bytes(body, contentType: "text/event-stream") }
            }
            defer { http.close() }
            let service = AIService(backendClient: BackendClient(llmSession: http.session))
            let pending = Task { await BackfillAIQueue.shared.dispatchActionRefine(snapshot(tag), ai: service) }
            let end = ContinuousClock.now + .seconds(10)
            while !gate.started, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
            guard gate.started else {
                gate.release(); await pending.value
                Issue.record("the dispatch did not reach the parked backend")
                return
            }
            if interrupt { #expect(await store.edit("newer rule edit") { try $0.addBullet("\(tag) newer user edit", to: .archiveRules) } == .saved) }
            gate.release(); await pending.value
            #expect(!gate.timedOut)
            let sent = http.recordedCalls().compactMap(\.body).map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.contains { $0.contains("\(tag) subject") }, "the snapshot's subject reached the request")
            #expect(persisted().contains("\(tag) old AI result") == !interrupt)
            if interrupt { #expect(persisted().contains("\(tag) newer user edit"), "the newer edit is durable") }
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }
}

/// The Settings editor's Add and Delete, called as its controls call them, read back from the store: a hosted
/// SwiftUI control publishes no element a test can tap, so only the control's one-line closure is not run.
@MainActor
@Suite("Settings bullet editor actions", .serialized, .processGlobalState)
struct BulletListEditorActionsTests {
    let store = PromptStore.shared

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
    }

    private func persisted(_ field: BulletField) -> String {
        UserDefaults.standard.string(forKey: UserDefaultsBulletStore.renderedKeys[field] ?? "") ?? ""
    }

    private func added(_ text: String, to section: PromptSection) async -> PromptEditOutcome? {
        guard case .adding(let task) = BulletListEditorActions.add(text, to: section, in: store) else { return nil }
        return await task.value
    }

    @Test("Add persists the trimmed line; Delete removes exactly the row shown and keeps an unrelated bullet")
    func addThenDelete() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let other = PromptStoreTestCleanup.tag()
        #expect(await added("  \(tag) first  ", to: .archiveRules) == .saved)
        #expect(await added(other, to: .archiveRules) == .saved)
        #expect(persisted(.action).contains("\(tag) first"), "Add is durable")
        #expect(persisted(.action).contains(other))

        let shown = try #require(store.shown(.archiveRules).first { $0.text == "\(tag) first" })
        #expect(await BulletListEditorActions.delete(shown, from: .archiveRules, in: store).value == .saved)
        #expect(!persisted(.action).contains("\(tag) first"), "Delete is durable")
        #expect(!store.shown(.archiveRules).contains { $0.text == "\(tag) first" })
        #expect(persisted(.action).contains(other), "an unrelated bullet is kept")
        await PromptStoreTestCleanup.remove(tag: other, from: store)
    }

    @Test("Add adds nothing for a blank line and refuses a line holding a section marker")
    func addRefusals() async {
        quiet()
        let before = persisted(.action)
        if case .nothing = BulletListEditorActions.add("   ", to: .archiveRules, in: store) {} else { Issue.record("a blank line was not ignored") }
        let marker = "DO NOT EDIT/DELETE THIS SECTION HEADER"
        if case .refused(let text) = BulletListEditorActions.add(marker, to: .archiveRules, in: store) {
            #expect(text == PromptStore.sectionMarkerRefusal)
        } else {
            Issue.record("a marker line was not refused")
        }
        #expect(persisted(.action) == before, "neither changed the stored text")
    }

    private func reminder(_ content: String) -> Reminder {
        Reminder(type: "reminder", content: content, dueDate: nil, dueTime: nil, source: "kb", hash: "k:" + content, enabled: true,
                 action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil, instruction: nil, scheduleDays: nil,
                 scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil)
    }

    @Test("Deleting a KB reminder removes the labels its bullet was shown with and keeps a bullet added since")
    func reminderDeletionUsesTheShownLabels() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let line = "Reminder: \(tag) pay rent"
        #expect(await store.edit("add reminder") { try $0.addBullet(line, to: .knowledgeBase) } == .saved)
        let shownKB = store.shown(.knowledgeBase)
        let found = try #require(KBReminderDeletion.shown(for: reminder("\(tag) pay rent"), in: shownKB))
        #expect(found.text == line)
        #expect(KBReminderDeletion.shown(for: reminder("\(tag) other"), in: shownKB) == nil, "a reminder with no bullet is not matched")
        // An unrelated bullet and a later bullet with the same words in other case.
        #expect(await store.edit("add unrelated") { try $0.addBullet("\(tag) unrelated", to: .knowledgeBase) } == .saved)
        #expect(await KBReminderDeletion.delete(found, in: store).value == .saved)
        #expect(!store.rawKB.contains(line), "the reminder bullet is gone from the stored text")
        #expect(store.rawKB.contains("\(tag) unrelated"), "an unrelated bullet is kept")
        #expect(await KBReminderDeletion.delete(found, in: store).value == .unchanged, "deleting it again changes nothing")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("Delete of a row that is already gone changes nothing")
    func deleteOfAGoneRow() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        #expect(await added(tag, to: .deleteRules) == .saved)
        let shown = try #require(store.shown(.deleteRules).first { $0.text == tag })
        #expect(await BulletListEditorActions.delete(shown, from: .deleteRules, in: store).value == .saved)
        #expect(await BulletListEditorActions.delete(shown, from: .deleteRules, in: store).value == .unchanged)
    }
}

/// A mock model that answers every completion with `patch` as its patch.
private func mockModel(patch: String) throws -> (AIService, FakeHTTP.Scenario) {
    let assistant = String(decoding: try JSONSerialization.data(withJSONObject: ["patch": patch]), as: UTF8.self)
    let data = try JSONSerialization.data(withJSONObject: ["assistant": assistant])
    let body = Data(("event: final\ndata: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
    let http = FakeHTTP.Scenario()
    http.register(path: "/completions/chat", method: "POST") { _ in .bytes(body, contentType: "text/event-stream") }
    return (AIService(backendClient: BackendClient(llmSession: http.session)), http)
}

/// The action-rule writers decide "the patch changed nothing" on bytes (`Bullets.same`), as the store does: a patch
/// that replaces a rule with a canonically equivalent but byte-different one is a change and is saved. The queue's
/// dispatch runs the refine for the snapshot it holds.
@MainActor
@Suite("Action rule writers compare bytes", .serialized, .processGlobalState)
struct ActionRuleExactByteTests {
    let store = PromptStore.shared

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        AIService.writeOptOutFlag(false)
    }

    private func persisted() -> String {
        UserDefaults.standard.string(forKey: UserDefaultsBulletStore.renderedKeys[.action] ?? "") ?? ""
    }

    /// Byte containment: `String.contains` would call canonically equivalent text equal.
    private func hasBytes(_ haystack: String, _ needle: String) -> Bool {
        Array(haystack.utf8).firstRange(of: Array(needle.utf8)) != nil
    }

    private func snapshot(_ tag: String) -> ActionRefineSnapshot {
        ActionRefineSnapshot(messageStableId: "msg-\(tag)", accountId: "acc-\(tag)", subject: "\(tag) subject", from: "sender@example.com",
                             summaryBlurb: "Planning notes.", summaryTodos: nil, originalAction: "archive", userManualTag: "delete")
    }

    /// Seeds a rule in its precomposed form and returns it with the decomposed form of the same text.
    private func seedRule(_ tag: String) async -> (composed: String, decomposed: String) {
        let composed = "\(tag) Caf\u{E9} news."
        let decomposed = "\(tag) Cafe\u{301} news."
        #expect(await store.edit("seed rule") { try $0.addBullet(composed, to: .deleteRules) } == .saved)
        return (composed, decomposed)
    }

    @Test("A refine patch that only re-spells a rule in canonically equivalent bytes is saved")
    func refineSavesByteDifferentRule() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let rule = await seedRule(tag)
        let (ai, http) = try mockModel(patch: "DEL\ndelete\n\(rule.decomposed)\nADD\ndelete\n\(rule.decomposed)")
        defer { http.close() }
        await BackfillAIQueue.shared.dispatchActionRefine(snapshot(tag), ai: ai)
        #expect(hasBytes(persisted(), rule.decomposed), "the re-spelled rule was saved")
        #expect(!hasBytes(persisted(), rule.composed), "the old spelling is gone")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A compaction patch that only re-spells a rule in canonically equivalent bytes is saved")
    func compactionSavesByteDifferentRule() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let rule = await seedRule(tag)
        let (ai, http) = try mockModel(patch: "DEL\ndelete\n\(rule.decomposed)\nADD\ndelete\n\(rule.decomposed)")
        defer { http.close() }
        let result = await ai.compactActionRulesNow()
        if case .applied = result {} else { Issue.record("the compaction did not apply: \(result)") }
        #expect(hasBytes(persisted(), rule.decomposed), "the re-spelled rule was saved")
        #expect(!hasBytes(persisted(), rule.composed), "the old spelling is gone")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("The queue's dispatch of an action-refine row runs the refine and persists its patch; an undecodable row throws")
    func dispatchRunsTheRefine() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let (ai, http) = try mockModel(patch: "ADD\ndelete\n\(tag) queued rule")
        defer { http.close() }
        let row = try PendingAIRefinement.make(snapshot(tag), now: Int64(Date().timeIntervalSince1970 * 1000))
        try await BackfillAIQueue.shared.dispatch(row, jobType: .actionRefine, ai: ai)
        #expect(persisted().contains("\(tag) queued rule"), "the refine ran and its patch was saved")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)

        let broken = PendingAIRefinement(dedupKey: "broken-\(tag)", jobType: .actionRefine, payloadJSON: "{", createdAt: 0)
        await #expect(throws: (any Error).self) { try await BackfillAIQueue.shared.dispatch(broken, jobType: .actionRefine, ai: ai) }
    }
}
