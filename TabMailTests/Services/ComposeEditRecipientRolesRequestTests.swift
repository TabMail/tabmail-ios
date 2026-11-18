/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Invariant: the compose edit request the backend receives keeps every recipient's role.
/// A Cc recipient reaches the backend only as `original_cc`, never in `original_to` or in
/// `recipients_json` (the prompt's RECIPIENT LIST), and Bcc only as `original_bcc`.
///
/// `ComposeEditRecipientRolesTests` pins the tools up to the `ComposeEditContext`; this suite
/// reads the request at `POST /completions/chat`, so a change to the context-to-variable
/// mapping inside `AIService.performInlineEdit` fails here.
///
/// `.processGlobalState`: `AIService` reads the App Group opt-out flag, which
/// `DictationOptOutFlagTests` writes; the test pins it off and restores it.
@Suite(.serialized, .processGlobalState)
struct ComposeEditRecipientRolesRequestTests {

    private static let primary = "sam@example.com"
    private static let copied = "pat@example.com"
    private static let blind = "lee@example.com"

    /// Answers `/completions/chat` with a final assistant edit and reads back every request.
    private final class Backend: Sendable {
        let http = FakeHTTP.Scenario()

        init() {
            http.register(path: "/completions/chat", method: "POST") { _ in
                let assistant = "Subject: Offsite\nBody: Friday works."
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
        }

        /// The first message of every request received, in order.
        var messages: [[String: Any]] {
            http.recordedCalls().map { call in
                let json = call.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                return (json["messages"] as? [[String: Any]])?.first ?? [:]
            }
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

    @Test("performInlineEdit sends To Sam, Cc Pat, Bcc Lee to the backend in their own roles")
    func requestKeepsRecipientRoles() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))
            let context = ComposeEditContext(
                recipients: [Self.primary],
                toRecipients: [Self.primary],
                ccRecipients: [Self.copied],
                bccRecipients: [Self.blind],
                toDisplayNames: [:],
                ccDisplayNames: [:],
                bccDisplayNames: [:],
                senderName: "Test User",
                senderEmail: "test@example.com",
                mode: "edit_new",
                compositionPrompt: "",
                kbText: "",
                relatedDate: "",
                relatedSubject: "",
                relatedFrom: "",
                relatedTo: "",
                relatedCc: "",
                bodyText: ""
            )

            _ = try await service.performInlineEdit(
                currentSubject: "",
                currentBody: "",
                context: context,
                instruction: "Ask about moving the offsite to Friday",
                chatHistory: []
            )

            let messages = backend.messages
            #expect(messages.count == 1)
            guard messages.count == 1 else { return }
            let vars = messages[0]
            #expect(vars["mode"] as? String == "edit_new")

            let recipientsJSON = try #require(vars["recipients_json"] as? String)
            let recipients = try #require(
                try JSONSerialization.jsonObject(with: Data(recipientsJSON.utf8)) as? [[String: Any]]
            )
            #expect(recipients.compactMap { $0["email"] as? String } == [Self.primary])
            #expect(recipients.count == 1)

            let originalTo = vars["original_to"] as? String
            #expect(originalTo == "<\(Self.primary)>")
            #expect(vars["original_cc"] as? String == "<\(Self.copied)>")
            #expect(vars["original_bcc"] as? String == "<\(Self.blind)>")

            #expect(originalTo?.contains(Self.copied) == false)
            #expect(!recipientsJSON.contains(Self.copied))
        }
    }

    /// The names the assistant gave reach the backend: the tool's context goes through the
    /// override seam into a real `AIService` request, and `original_to`/`original_cc` carry
    /// each recipient as `Name <address>`.
    @Test("email_compose: tool recipient names reach the backend's original_to and original_cc")
    func toolNamesReachBackend() async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))
            try await Self.runNamedCompose(service: service)

            let messages = backend.messages
            #expect(messages.count == 1)
            guard messages.count == 1 else { return }
            let vars = messages[0]
            #expect(vars["original_to"] as? String == "Sam Lee <\(Self.primary)>")
            #expect(vars["original_cc"] as? String == "Pat Kim <\(Self.copied)>")
        }
    }

    /// Runs a named email_compose call whose edit request goes to `service`, then closes
    /// the compose card it opens.
    @MainActor
    private static func runNamedCompose(service: AIService) async throws {
        let router = AgentToolRouter()
        let ctx = ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator(), router: router)
        let tool = EmailComposeTool(context: ctx)
        let override: @Sendable (ComposeEditContext, String) async throws -> InlineEditResult = { context, instruction in
            try await service.performInlineEdit(
                currentSubject: "", currentBody: "", context: context,
                instruction: instruction, chatHistory: []
            )
        }
        try await EmailComposeTool.$inlineEditOverride.withValue(override) {
            let task = Task { @MainActor () -> String in
                try await tool.execute(arguments: [
                    "recipients": .array([.dictionary(["name": .string("Sam Lee"), "email": .string(Self.primary)])]),
                    "cc": .array([.dictionary(["name": .string("Pat Kim"), "email": .string(Self.copied)])]),
                    "request": .string("Ask about moving the offsite to Friday"),
                ])
            }
            let deadline = Date().addingTimeInterval(5)
            while router.pendingCompose == nil, Date() < deadline { await Task.yield() }
            guard let req = router.pendingCompose else {
                Issue.record("Tool did not open a compose card")
                task.cancel()
                _ = try? await task.value
                return
            }
            req.onOutcome(.cancelled)
            _ = try await task.value
        }
    }
}
