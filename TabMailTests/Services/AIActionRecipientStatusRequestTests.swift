/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The action request carries the receiving account's cc status (TB parity:
/// `actionGenerator.js`). These tests read the request the backend actually
/// receives at `POST /completions/chat`, so a call path that drops the status
/// fails here even though `PromptVariables.actionVariables` still builds it.
///
/// `.processGlobalState`: `AIService` reads the App Group opt-out flag, which
/// `DictationOptOutFlagTests` writes; each test pins it off and restores it.
@Suite(.serialized, .processGlobalState)
struct AIActionRecipientStatusRequestTests {

    /// Answers `/completions/chat` (the summary prompt gets a plain blurb, the
    /// action prompt a valid action) and reads back every request it received.
    private final class Backend: Sendable {
        let http = FakeHTTP.Scenario()

        init() {
            http.register(path: "/completions/chat", method: "POST") { request in
                let assistant = Self.firstMessage(request.body)["content"] as? String == "system_prompt_action"
                    ? #"{"action":"archive"}"#
                    : "A short summary."
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
        }

        private static func firstMessage(_ body: Data?) -> [String: Any] {
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return (json["messages"] as? [[String: Any]])?.first ?? [:]
        }

        /// The first message of every request received, in order.
        var messages: [[String: Any]] {
            http.recordedCalls().map { Self.firstMessage($0.body) }
        }

        func messages(for prompt: String) -> [[String: Any]] {
            messages.filter { $0["content"] as? String == prompt }
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

    private func classify(_ service: AIService, recipientStatus: String) async throws -> ActionTag? {
        try await service.classifyAction(
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com",
            bodyText: "Notes from the planning call.", htmlContent: nil,
            summary: SummaryResult(blurb: "Planning notes.", todos: nil,
                                   reminderDate: nil, reminderTime: nil, reminderContent: nil),
            userName: "Recipient", actionPrompt: "",
            recipientStatus: recipientStatus
        )
    }

    private func process(_ service: AIService, recipientStatus: String) async throws -> (summary: SummaryResult, action: ActionTag?, reply: String?)? {
        // `rfc822MessageId: nil` skips the Device Sync probe, so both prompts run.
        try await service.process(
            messageId: "msg-1", rfc822MessageId: nil, accountEmail: "recipient@example.com",
            subject: "Quarterly planning", from: "Sender", fromAddress: "sender@company.com",
            date: Date(), bodyText: "Notes from the planning call.", htmlContent: nil,
            hasExistingAction: false, userName: "Recipient", kbText: "", actionPrompt: "",
            recipientStatus: recipientStatus
        )
    }

    @Test("classifyAction sends recipient_status \"cc\" in the action request")
    func classifySendsCc() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))

            let tag = try await classify(service, recipientStatus: "cc")

            #expect(tag == .archive)
            let actions = backend.messages(for: "system_prompt_action")
            try #require(actions.count == 1)
            #expect(actions[0]["recipient_status"] as? String == "cc")
            #expect(actions[0]["subject"] as? String == "Quarterly planning")
            #expect(backend.messages.count == 1)
        }
    }

    @Test("classifyAction omits recipient_status for a direct or unknown recipient")
    func classifyOmitsWhenEmpty() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))

            let tag = try await classify(service, recipientStatus: "")

            #expect(tag == .archive)
            let actions = backend.messages(for: "system_prompt_action")
            try #require(actions.count == 1)
            #expect(actions[0]["recipient_status"] == nil)
            #expect(actions[0]["subject"] as? String == "Quarterly planning")
        }
    }

    @Test("classifyAction sends no request when AI is opted out")
    func classifyOptOutSendsNothing() async throws {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(true)
        let backend = Backend()
        let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))

        let tag = try await classify(service, recipientStatus: "cc")

        #expect(tag == nil)
        #expect(backend.messages.isEmpty)
    }

    @Test("process sends recipient_status \"cc\" with both the summary and the action request")
    func processSendsCcOnBothPrompts() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))

            let result = try await process(service, recipientStatus: "cc")

            #expect(result?.action == .archive)
            let summaries = backend.messages(for: "system_prompt_summary")
            let actions = backend.messages(for: "system_prompt_action")
            try #require(summaries.count == 1)
            try #require(actions.count == 1)
            #expect(summaries[0]["recipient_status"] as? String == "cc")
            #expect(actions[0]["recipient_status"] as? String == "cc")
            #expect(backend.messages.count == 2)
        }
    }

    @Test("process omits recipient_status from both requests for a direct or unknown recipient")
    func processOmitsWhenEmpty() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))

            let result = try await process(service, recipientStatus: "")

            #expect(result?.action == .archive)
            let summaries = backend.messages(for: "system_prompt_summary")
            let actions = backend.messages(for: "system_prompt_action")
            try #require(summaries.count == 1)
            try #require(actions.count == 1)
            #expect(summaries[0]["recipient_status"] == nil)
            #expect(actions[0]["recipient_status"] == nil)
        }
    }
}
