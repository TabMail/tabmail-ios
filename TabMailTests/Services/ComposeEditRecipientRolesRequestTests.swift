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
                // The compose edit JSON the backend answers this build with (2.0.0).
                let assistant = ComposeEditJSON.make(
                    response: "Wrote it.", subject: "Offsite", body: "Friday works.",
                    textMessage: "Friday works.", changeCommand: "")
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
        try await AITestSetting.with(aiOff: false, body)
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

    /// The names the assistant gave reach the backend: the tool's context goes through its
    /// init's `composeEdit:` seam into a real `AIService` request, and `original_to`/`original_cc` carry
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
            let recipientsJSON = try #require(vars["recipients_json"] as? String)
            let recipients = try #require(
                try JSONSerialization.jsonObject(with: Data(recipientsJSON.utf8)) as? [[String: Any]]
            )
            #expect(recipients.compactMap { $0["email"] as? String } == [Self.primary])
            #expect(recipients.count == 1)
            #expect(vars["original_to"] as? String == "Sam Lee <\(Self.primary)>")
            #expect(vars["original_cc"] as? String == "Pat Kim <\(Self.copied)>")
        }
    }

    /// An agent compose tool built with no `composeEdit:`, as the tool registry builds it.
    enum DefaultTool: String, CaseIterable, Sendable {
        case compose, forward, reply

        /// The compose edit mode the tool asks for.
        var mode: String {
            switch self {
            case .compose: "edit_new"
            case .forward: "edit_forward"
            case .reply: "edit_reply"
            }
        }
    }

    /// A tool's default edit is the chat's: it goes to the chat's AI service
    /// (`ChatPillState.shared.aiService`), and the draft the backend writes is what the compose
    /// card opens with.
    @Test("A compose tool's default edit goes to the chat's AI service and its draft reaches the card",
          arguments: DefaultTool.allCases)
    func defaultEditReachesChatService(_ tool: DefaultTool) async throws {
        try await withAIEnabled {
            let backend = Backend()
            let service = AIService(backendClient: BackendClient(llmSession: backend.http.session))
            let cardBody = try await Self.runDefaultTool(tool, service: service)

            let messages = backend.messages
            #expect(messages.count == 1, "the edit reached the chat's AI service")
            guard messages.count == 1 else { return }
            let mode = messages[0]["mode"] as? String
            #expect(mode == tool.mode)
            // The body `Backend` answers every request with.
            #expect(cardBody == "Friday works.", "the card opens with the backend's draft")
        }
    }

    /// Runs `tool`, built with no `composeEdit:`, on an email from Sam while the chat's AI service
    /// is `service`, closes the compose card it opens, and returns the card's body. The chat's
    /// service is put back after.
    @MainActor
    private static func runDefaultTool(_ tool: DefaultTool, service: AIService) async throws -> String? {
        ChatPillState.shared.aiService = service
        defer { ChatPillState.shared.aiService = .shared }
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        let ctx = ToolContext(db: db, translator: translator, router: router)
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "default-edit", subject: "Offsite",
            from: Self.primary, fromAddress: Self.primary,
            to: "test@example.com"
        )
        await translator.seed(header.id, as: 21)
        let request = JSONValue.string("Say Friday works")
        let task = Task { @MainActor () -> String in
            switch tool {
            case .compose:
                return try await EmailComposeTool(context: ctx).execute(arguments: [
                    "to": .array([.string(Self.copied)]), "request": request,
                ], invocation: ComposeTestOrigin.invocation)
            case .forward:
                return try await EmailForwardTool(context: ctx).execute(arguments: [
                    "unique_id": .int(21), "to": .array([.string(Self.copied)]), "request": request,
                ], invocation: ComposeTestOrigin.invocation)
            case .reply:
                return try await EmailReplyTool(context: ctx).execute(arguments: [
                    "unique_id": .int(21), "request": request,
                ], invocation: ComposeTestOrigin.invocation)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        var taken = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        while taken == nil, Date() < deadline {
            await Task.yield()
            taken = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        }
        guard let req = taken else {
            Issue.record("Tool did not open a compose card")
            task.cancel()
            _ = try? await task.value
            return nil
        }
        let body = req.body
        req.onOutcome(.cancelled)
        _ = try await task.value
        return body
    }

    /// Runs a named email_compose call whose edit request goes to `service`, then closes
    /// the compose card it opens.
    @MainActor
    private static func runNamedCompose(service: AIService) async throws {
        let router = AgentToolRouter()
        let ctx = ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator(), router: router)
        let tool = EmailComposeTool(context: ctx, composeEdit: { context, subject, body, instruction in
            try await service.performInlineEdit(
                currentSubject: subject, currentBody: body, context: context,
                instruction: instruction, chatHistory: []
            )
        })
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "recipients": .array([.dictionary(["name": .string("Sam Lee"), "email": .string(Self.primary)])]),
                "cc": .array([.dictionary(["name": .string("Pat Kim"), "email": .string(Self.copied)])]),
                "request": .string("Ask about moving the offsite to Friday"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        let deadline = Date().addingTimeInterval(5)
        var taken = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        while taken == nil, Date() < deadline {
            await Task.yield()
            taken = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        }
        guard let req = taken else {
            Issue.record("Tool did not open a compose card")
            task.cancel()
            _ = try? await task.value
            return
        }
        req.onOutcome(.cancelled)
        _ = try await task.value
    }
}
