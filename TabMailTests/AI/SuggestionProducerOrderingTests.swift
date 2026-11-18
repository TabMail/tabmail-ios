/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// ADR-IOS-114 decision 18, through the real producers: the AI Suggestion has one writer, and every
/// producer stores only over what it read as it started.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A reply job (the AI queue's, or the opened-email direct path's) that read an empty slot and
///     is still waiting for the backend never lands over an edit stored meanwhile: the header, the
///     AI cache, the change notifications and the request count all show only the edit. With no
///     edit, the same held job fills the slot (the control).
///  2. A result from another device carries the stored suggestion whole, change command included,
///     into the AI cache, and never replaces it.
///  3. A suggestion is stored on the header and in the AI cache together or not at all: a cache write
///     that fails leaves the header as it was and tells no view anything changed.
@Suite("The AI Suggestion's producers keep the one writer's order", .serialized, .processGlobalState)
struct SuggestionProducerOrderingTests {
    typealias Fixture = AITextMessageCallerTests.Fixture

    static let producedBody = "Thanks, I will send the budget today."
    static let producedText = "Sending the budget today"
    static let edit = ReplyResult(body: "Edited reply", textMessage: "Edited text", changeCommand: "make it shorter")
    /// How long a held response or a wait may take before the test gives up.
    static let bound: TimeInterval = 20

    /// A lock a closure can capture (a `Mutex` cannot be copied into one).
    final class Box<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ initial: Value) { value = Mutex(initial) }
    }

    /// A backend whose reply (compose) answer is held until `release()`; every other prompt is
    /// answered at once as `AITextMessageCallerTests.Backend` answers it.
    final class HeldBackend: Sendable {
        let http = FakeHTTP.Scenario()
        private let gate = DispatchSemaphore(value: 0)
        private let released = Mutex(false)
        private let answered = Box(false)

        init() {
            http.register(path: "/completions/chat", method: "POST") { [gate, answered] request in
                let prompt = AITextMessageCallerTests.Backend.prompt(request.body)
                let object: [String: Any]
                switch prompt {
                case "system_prompt_summary":
                    object = ["summary": AITextMessageCallerTests.blurb, "todos": [],
                              "reminder": ["due_date": NSNull(), "due_time": NSNull(), "content": NSNull()],
                              "text_message": AITextMessageCallerTests.summaryText]
                case "system_prompt_action":
                    object = ["action": "reply"]
                default:
                    object = ["subject": "Re: Plans", "body": SuggestionProducerOrderingTests.producedBody,
                              "text_message": SuggestionProducerOrderingTests.producedText]
                }
                let assistant = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                let stream = Data(("event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n").utf8)
                guard prompt != "system_prompt_summary", prompt != "system_prompt_action" else {
                    return .bytes(stream, contentType: "text/event-stream")
                }
                return .parked {
                    _ = gate.wait(timeout: .now() + SuggestionProducerOrderingTests.bound)
                    answered.value.withLock { $0 = true }
                    return .bytes(stream, contentType: "text/event-stream")
                }
            }
        }

        var service: AIService { AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }) }
        var prompts: [String] { http.recordedCalls().compactMap { AITextMessageCallerTests.Backend.prompt($0.body) } }
        var replyRequests: Int { prompts.filter { $0 == "system_prompt_compose" }.count }
        var wasAnswered: Bool { answered.value.withLock { $0 } }

        func release() {
            let first = released.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { gate.signal() }
        }

        func close() {
            release()
            http.close()
        }
    }

    /// Counts `.messageDataDidChange` posts for one row.
    final class ChangeCounter: @unchecked Sendable {
        private let count = Box(0)
        private var token: NSObjectProtocol?

        init(_ id: MessageHeader.ID) {
            token = NotificationCenter.default.addObserver(forName: .messageDataDidChange, object: nil, queue: nil) { [count] note in
                guard note.object as? MessageHeader.ID == id else { return }
                count.value.withLock { $0 += 1 }
            }
        }

        var value: Int { count.value.withLock { $0 } }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    private func withAIEnabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(false)
        return try await body()
    }

    /// Polls `condition` until it holds or `bound` passes; the caller asserts afterwards.
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Self.bound)
        while try !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - 1. Producers held across an edit

    @Test("The queue's reply job, held after reading an empty slot, never lands over an edit stored meanwhile",
          arguments: [true, false])
    func queueJobHeldAcrossEdit(editLands: Bool) async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = HeldBackend()
            let changes = ChangeCounter(fixture.header.id)
            defer { changes.stop(); backend.close(); fixture.close() }
            #expect(fixture.header.suggestion == nil, "control: the job reads an empty slot")

            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)
            let header = fixture.header, account = fixture.account, target = fixture.target, service = backend.service
            let job = Task {
                await queue.executeJobForTesting(
                    ActiveAIQueue.AIJob(headerId: header.id, accountId: "acc1", jobType: .reply),
                    message: header, plainText: "Can you send the budget?", account: account,
                    target: target, aiService: service)
            }
            try await waitUntil { backend.replyRequests == 1 }
            #expect(backend.replyRequests == 1, "control: the job is waiting for its reply")

            if editLands {
                #expect(await ComposeView.writeCachedReplyToDB(Self.edit, replacing: nil, replyTo: fixture.header, db: fixture.pool) == .written,
                        "control: the edit is stored while the job waits")
            }
            backend.release()
            _ = await job.value

            let expected = editLands ? Self.edit : ReplyResult(body: Self.producedBody, textMessage: Self.producedText)
            #expect(try fixture.row()?.suggestion == expected)
            #expect(try fixture.cache()?.suggestion == expected)
            #expect(changes.value == 1, "one change: the edit's, or the job's own fill")
            #expect(backend.replyRequests == 1, "the reply was asked for once")
        }
    }

    @Test("The opened-email direct path, held after reading an empty slot, never lands over an edit stored meanwhile",
          arguments: [true, false])
    func directPathHeldAcrossEdit(editLands: Bool) async throws {
        try await withAIEnabled {
            // Summarized: opening the email asks only for its reply.
            let fixture = try Fixture(summarized: true)
            let backend = HeldBackend()
            defer { backend.close(); fixture.close() }

            await AccountManager.shared.processMessage(
                fixture.header, body: try fixture.body, account: fixture.account,
                target: fixture.target, aiService: backend.service)
            try await waitUntil { backend.replyRequests == 1 }
            #expect(backend.replyRequests == 1, "control: the direct path is waiting for its reply")

            if editLands {
                #expect(await ComposeView.writeCachedReplyToDB(Self.edit, replacing: nil, replyTo: fixture.header, db: fixture.pool) == .written,
                        "control: the edit is stored while the direct path waits")
            }
            backend.release()
            let expected = editLands ? Self.edit : ReplyResult(body: Self.producedBody, textMessage: Self.producedText)
            // The direct path runs detached: wait for its answer, then for its write (or its drop).
            try await waitUntil { backend.wasAnswered }
            if editLands {
                try await Task.sleep(for: .milliseconds(500))
            } else {
                try await waitUntil { try fixture.row()?.suggestion == expected }
            }

            #expect(try fixture.row()?.suggestion == expected)
            #expect(try fixture.cache()?.suggestion == expected)
            #expect(backend.replyRequests == 1, "the reply was asked for once")
        }
    }

    // MARK: - 2. A result from another device carries the stored suggestion whole

    @Test("The queue's peer carry keeps the stored suggestion and puts it in the AI cache with its change command")
    func queuePeerCarriesTheCommand() async throws {
        try await withAIEnabled {
            // A unique UID: the search index is shared by the whole test process.
            let fixture = try Fixture(messageId: UUID().uuidString)
            let backend = AITextMessageCallerTests.Backend()
            let key = ContentKey(rawValue: fixture.header.id)
            defer {
                backend.close(); fixture.close()
                Task { try? await SearchIndex.shared.removeMessages(contentKeys: [key]) }
            }
            // The row holds an edited suggestion (with a command) and no summary; nothing is cached yet.
            var local = fixture.header
            let seededOK = local.replaceSuggestion(with: Self.edit, ifStill: nil)
            #expect(seededOK, "control: the edit is seeded")
            let seeded = local
            try await fixture.pool.write { try seeded.update($0) }
            #expect(try fixture.cache() == nil, "control: the cache entry comes from the peer carry")
            let h = fixture.header
            try await SearchIndex.shared.removeMessages(contentKeys: [key])
            _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
                contentKey: key, headerId: h.id, messageId: h.messageId, subject: h.subject,
                from: "\(h.from) <\(h.fromAddress)>", to: h.to,
                dateMs: Int64(h.date.timeIntervalSince1970 * 1000))])
            try await SearchIndex.shared.updateBody(contentKey: key, body: "Can you send the budget?")

            await ActiveAIQueue().executeWholeJobForTesting(
                ActiveAIQueue.AIJob(headerId: h.id, accountId: "acc1", jobType: .reply, windowExempt: true),
                aiService: backend.peerService)

            let row = try #require(try fixture.row())
            #expect(row.summaryBlurb == AITextMessageCallerTests.peerBlurb, "control: the peer's summary was carried")
            #expect(row.suggestion == Self.edit, "the peer's reply never replaces the stored suggestion")
            #expect(try fixture.cache()?.suggestion == Self.edit, "the cache gets the whole suggestion, command included")
            #expect(!backend.prompts.contains("system_prompt_compose"), "the stored suggestion is not asked for again")
        }
    }

    @Test("The direct path's peer carry keeps the stored suggestion and puts it in the AI cache with its change command")
    func directPeerCarriesTheCommand() async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = AITextMessageCallerTests.Backend()
            defer { backend.close(); fixture.close() }
            var local = fixture.header
            let seededOK = local.replaceSuggestion(with: Self.edit, ifStill: nil)
            #expect(seededOK, "control: the edit is seeded")
            let seeded = local
            try await fixture.pool.write { try seeded.update($0) }

            await AccountManager.shared.processMessage(
                seeded, body: try fixture.body, account: fixture.account,
                target: fixture.target, aiService: backend.peerService)
            try await waitUntil { try fixture.cache()?.summaryBlurb == AITextMessageCallerTests.peerBlurb }

            let row = try #require(try fixture.row())
            #expect(row.summaryBlurb == AITextMessageCallerTests.peerBlurb, "control: the peer's summary was carried")
            #expect(row.suggestion == Self.edit, "the peer's reply never replaces the stored suggestion")
            #expect(try fixture.cache()?.suggestion == Self.edit, "the cache gets the whole suggestion, command included")
        }
    }

    // MARK: - 3. Header and cache together or not at all

    @Test("A suggestion whose cache write fails leaves the header as it was and posts no change", arguments: [true, false])
    func cacheFailureRollsBackTheHeader(cacheFails: Bool) async throws {
        let fixture = try Fixture()
        let changes = ChangeCounter(fixture.header.id)
        defer { changes.stop(); fixture.close() }
        if cacheFails {
            try await fixture.pool.write { db in
                try db.execute(sql: """
                    CREATE TEMP TRIGGER refuseCacheInsert BEFORE INSERT ON messageAICache
                    BEGIN SELECT RAISE(ABORT, 'cache write refused'); END;
                    CREATE TEMP TRIGGER refuseCacheUpdate BEFORE UPDATE ON messageAICache
                    BEGIN SELECT RAISE(ABORT, 'cache write refused'); END;
                    """)
            }
        }

        let outcome = await ComposeView.writeCachedReplyToDB(Self.edit, replacing: nil, replyTo: fixture.header, db: fixture.pool)
        // The change is posted on the main actor after the write; let it arrive.
        try await Task.sleep(for: .milliseconds(200))

        if cacheFails {
            #expect(outcome == .dropped, "a failed write is never reported as stored")
            #expect(try fixture.row()?.suggestion == nil, "the header write is rolled back with the cache write")
            #expect(try fixture.cache() == nil)
            #expect(changes.value == 0, "no view is told the row changed")
        } else {
            #expect(outcome == .written, "control")
            #expect(try fixture.row()?.suggestion == Self.edit)
            #expect(try fixture.cache()?.suggestion == Self.edit)
            #expect(changes.value == 1)
        }
    }
}
