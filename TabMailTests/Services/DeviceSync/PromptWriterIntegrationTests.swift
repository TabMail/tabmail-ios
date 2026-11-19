/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The writers that change the prompt store from outside it: the AI refinements and the chat tools. Each
/// runs for real against a mock backend, and the tests read what it persisted, so a writer whose save is
/// removed or replaced by its unchanged input fails here (DS-AI, DS-CAPTURE).
@MainActor
@Suite("Prompt store writers", .serialized, .processGlobalState)
struct PromptWriterIntegrationTests {
    let store = PromptStore.shared

    /// Answers `/completions/chat` with one `final` event holding `payload`.
    private final class Backend: Sendable {
        let http = FakeHTTP.Scenario()

        init(_ payload: [String: Any]) {
            let final = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            http.register(path: "/completions/chat", method: "POST") { _ in
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
        }

        var client: BackendClient { BackendClient(llmSession: http.session) }
    }

    private func quiet() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
    }

    private func withAIEnabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let restore = AITestSetting.save()
        defer { restore() }
        AITestSetting.set(aiOff: false)
        return try await body()
    }

    private func patch(_ text: String) -> [String: Any] {
        ["assistant": #"{"patch":"\#(text.replacingOccurrences(of: "\n", with: "\\n"))"}"#]
    }

    private func capture(_ field: BulletField) async throws -> PromptCapture {
        guard case .read(let capture) = await store.readBeforeAI(field, "writer test read") else { throw DeviceSyncTestError("read refused") }
        return capture
    }

    private func persisted(_ field: BulletField) -> String {
        UserDefaults.standard.string(forKey: UserDefaultsBulletStore.renderedKeys[field] ?? "") ?? ""
    }

    private func refine(_ service: AIService, _ capture: PromptCapture) async {
        await service.autoUpdateUserPromptOnTag(subject: "Quarterly planning", from: "Sender", summaryBlurb: "Planning notes.",
                                                summaryTodos: nil, originalAction: "archive", userManualTag: "delete",
                                                actionCapture: capture)
    }

    @Test("A tag-override refinement persists its rule; one read before another edit is dropped (DS-AI)")
    func tagOverrideRefinementPersists() async throws {
        quiet()
        try await withAIEnabled {
            let tag = PromptStoreTestCleanup.tag()
            let backend = Backend(patch("ADD\ndelete\n\(tag) newsletters"))
            let service = AIService(backendClient: backend.client)
            let stale = try await capture(.action)

            // Another edit lands after the read: the late write is dropped and nothing of it is stored.
            let other = PromptStoreTestCleanup.tag()
            #expect(await store.edit("writer test edit") { try $0.addBullet(other, to: .archiveRules) } == .saved)
            await refine(service, stale)
            #expect(!persisted(.action).contains(tag), "a refinement read before another edit does not land")
            #expect(persisted(.action).contains(other))

            // Positive control: read after that edit, the same refinement lands, in the stored text.
            await refine(service, try await capture(.action))
            #expect(persisted(.action).contains(tag), "the refinement is persisted")
            #expect(store.bullets(.deleteRules).contains { $0.contains(tag) })
            #expect(persisted(.action).contains(other), "the other edit survives")
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
            await PromptStoreTestCleanup.remove(tag: other, from: store)
        }
    }

    @Test("A manual compaction persists its patch and reports it (DS-AI)")
    func manualCompactionPersists() async {
        quiet()
        await withAIEnabled {
            let tag = PromptStoreTestCleanup.tag()
            let backend = Backend(patch("ADD\ndelete\n\(tag) merged"))
            let service = AIService(backendClient: backend.client)
            let result = await service.compactActionRulesNow()
            guard case .applied(let ops) = result else {
                Issue.record("not applied: \(result)")
                return
            }
            #expect(ops == 1)
            #expect(persisted(.action).contains(tag))
            #expect(store.bullets(.deleteRules).contains { $0.contains(tag) })
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }

    @Test("A manual compaction refused after its check is skipped as with AI off at the start, and the rules stay as they were")
    func refusedCompactionIsSkipped() async {
        quiet()
        await withAIEnabled {
            let tag = PromptStoreTestCleanup.tag()
            #expect(await store.edit("writer test edit") { try $0.addBullet(tag, to: .archiveRules) } == .saved)
            let backend = Backend(patch("ADD\ndelete\n\(tag) merged"))
            // The entry check reads the setting on; the backend client finds it off when it would send.
            let off = AIService(backendClient: BackendClient(llmSession: backend.http.session, isAIOff: { true }))
            let before = persisted(.action)
            #expect(before.contains(tag))

            let result = await off.compactActionRulesNow()
            guard case .skipped(let reason) = result else {
                Issue.record("not skipped: \(result)")
                await PromptStoreTestCleanup.remove(tag: tag, from: store)
                return
            }
            #expect(reason == "AI is disabled")
            #expect(persisted(.action) == before, "the rules are unchanged")
            #expect(backend.http.recordedCalls().isEmpty)

            // Control: with the client finding AI on, the same compaction is sent and applied.
            let on = AIService(backendClient: BackendClient(llmSession: backend.http.session, isAIOff: { false }))
            if case .applied = await on.compactActionRulesNow() {} else { Issue.record("control not applied") }
            #expect(backend.http.recordedCalls().count == 1)
            #expect(persisted(.action).contains("\(tag) merged"))
            await PromptStoreTestCleanup.remove(tag: "\(tag) merged", from: store)
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }

    @Test("A knowledge base refinement persists the refined text it was given (DS-REFINE)")
    func knowledgeBaseRefinementPersists() async {
        quiet()
        await withAIEnabled {
            let tag = PromptStoreTestCleanup.tag()
            let backend = Backend(["refined_kb": store.rawKB + "\n- \(tag) refined fact\n"])
            let service = KBRefinementService(backendClient: backend.client)
            func turn(_ role: String) -> ChatTurn {
                ChatTurn(id: ChatTurn.generateId(), timestamp: Date().timeIntervalSince1970 * 1000, role: role,
                         content: "text", userMessage: role == "user" ? "text" : nil, type: "normal", chars: 4,
                         renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
            }
            await service.refineKB(sessionTurns: [turn("user"), turn("assistant"), turn("user"), turn("assistant"), turn("user"), turn("assistant")])
            #expect(persisted(.kb).contains("\(tag) refined fact"))
            #expect(store.shown(.knowledgeBase).contains { $0.text.contains(tag) })
            await PromptStoreTestCleanup.remove(tag: tag, from: store)
        }
    }

    @Test("kb_add and kb_del persist their statement and its removal")
    func knowledgeBaseToolsPersist() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let added = try await KBAddTool().execute(arguments: ["statement": .string("\(tag) kb fact")])
        #expect(added == "Added to knowledge base.", "\(added)")
        #expect(persisted(.kb).contains("\(tag) kb fact"))
        #expect(store.shown(.knowledgeBase).contains { $0.text.contains(tag) })

        let removed = try await KBDelTool().execute(arguments: ["statement": .string("[Pinned] \(tag) kb fact")])
        #expect(!removed.contains("error"), "\(removed)")
        #expect(!persisted(.kb).contains(tag))
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("reminder_add and reminder_del persist the reminder and its removal")
    func reminderToolsPersist() async throws {
        quiet()
        let tag = PromptStoreTestCleanup.tag()
        let added = try await ReminderAddTool().execute(arguments: ["text": .string("\(tag) call back"), "due_date": .string("2099/01/02")])
        #expect(added.contains("ok"), "\(added)")
        #expect(persisted(.kb).contains("\(tag) call back"))
        #expect(store.shown(.knowledgeBase).contains { $0.text.contains("\(tag) call back") })

        let removed = try await ReminderDelTool().execute(arguments: ["text": .string("\(tag) call back")])
        #expect(removed.contains("ok"), "\(removed)")
        #expect(!persisted(.kb).contains(tag))
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }
}
