/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Blocking-contract tests for `EmailComposeTool` — mirrors the coverage that
/// `EmailReplyToolTests` / `EmailForwardToolTests` have for reply/forward.
///
/// email_compose was wired into the blocking-outcome pathway in commit
/// 1d5f663 (Agent compose tools: block on send/cancel, report outcome to
/// LLM) but only `EmailComposeToolParseTests` covers argument parsing —
/// the .sent / .cancelled / .failed round-trip through
/// `enqueueComposeAndAwaitOutcome` / `describeForLLM` was not covered.
///
/// Tests use the `request`-less code path (no `request` argument), which
/// avoids the backend-dependent `runComposeEdit` branch and calls directly
/// into the blocking helper. That exercises the contract we care about: the
/// tool must return the same outcome strings the LLM history would see for
/// email_reply / email_forward.
/// Per-test `AgentToolRouter` injected via `ToolContext` — same isolation
/// pattern as `EmailReplyToolTests`. See that file's suite header for the
/// cross-suite contention story this fixes.
@Suite("EmailCompose blocking contract")
@MainActor
struct EmailComposeToolOutcomeTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, AgentToolRouter) {
        let db = try TestDatabase.make()
        let router = AgentToolRouter()
        let ctx = ToolContext(db: db, translator: MockChatIdTranslator(), router: router)
        return (ctx, db, router)
    }

    /// See EmailReplyToolTests.waitForPendingCompose — same cooperative-poll
    /// pattern. Direct Task.yield() counts are unreliable because the tool's
    /// execute() does a prefix of work before suspending in the helper.
    private func waitForPendingCompose(
        on router: AgentToolRouter,
        timeout seconds: Double = 2.0
    ) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let req = router.takeCompose(for: ComposeTestOrigin.inboxHost) { return req }
            await Task.yield()
        }
        return router.takeCompose(for: ComposeTestOrigin.inboxHost)
    }

    /// THE SYSTEM PROPERTY: an agent's new email with a compose request is written by the model as a
    /// new email (`edit_new`), and its card opens with exactly the model's subject and body; a failed
    /// or malformed edit opens the card with the agent's own words, never part of an edit.
    /// Through the request path, the model answered by the compose edit the tool is given.
    @Test("A new email's compose request opens its card with the model's draft; a failed edit keeps the agent's words",
          arguments: [true, false])
    func composeRequestOpensTheModelsDraft(editSucceeds: Bool) async throws {
        let (_, db, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        let ctx = ToolContext(db: db, translator: MockChatIdTranslator(), router: router)
        let modes = Mutex<[String]>([])
        let body = "Hi Pat,\n\nAre you free on Friday?\n\nAlex"
        let tool = EmailComposeTool(context: ctx, composeEdit: { context, _, _, _ in
            modes.withLock { $0.append(context.mode) }
            guard editSucceeds else { throw InlineEditFailure(message: "The edit could not be read. Please try again.") }
            return try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
                response: "Done.", subject: "Friday", body: body, textMessage: "Free on Friday?", changeCommand: "")))
        })
        let task = Task { @MainActor in
            try await tool.execute(arguments: [
                "to": .array([.string("pat@example.com")]),
                "subject": .string("Agent subject"),
                "body": .string("Agent body"),
                "request": .string("ask Pat about Friday"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        let card = await waitForPendingCompose(on: router)
        card?.onOutcome(.cancelled)
        _ = try await task.value

        #expect(modes.withLock { $0 } == ["edit_new"], "the model is asked once, for a new email")
        let opened = try #require(card, "the card opens")
        #expect(opened.mode == .compose && opened.to == ["pat@example.com"])
        if editSucceeds {
            #expect(opened.subject == "Friday" && opened.body == body, "the card holds the model's draft")
        } else {
            #expect(opened.subject == "Agent subject" && opened.body == "Agent body", "the agent's own words, unchanged")
        }
    }

    @Test("Tool name is email_compose")
    func toolName() throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailComposeTool(context: ctx)
        #expect(tool.name == "email_compose")
    }

    @Test("User sending compose → tool resolves with 'sent successfully'")
    func blockingContractSent() async throws {
        let (ctx, _, router) = try makeContext()

        let tool = EmailComposeTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "to": .array([.string("a@b.com")]),
                "subject": .string("Hello"),
                "body": .string("Body text"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }

        // Request should carry .compose mode and the args we passed.
        #expect(req.mode == .compose)
        #expect(req.to == ["a@b.com"])
        #expect(req.subject == "Hello")

        req.onOutcome(.sent)
        let result = try await task.value
        #expect(result.contains("sent successfully"))
    }

    @Test("User dismissing compose → tool resolves with 'closed the compose window'")
    func blockingContractCancelled() async throws {
        let (ctx, _, router) = try makeContext()

        let tool = EmailComposeTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "to": .array([.string("a@b.com")]),
                "subject": .string("Bye"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }

        req.onOutcome(.cancelled)
        let result = try await task.value
        #expect(result.contains("closed the compose window"))
    }

    @Test("queueSend failure → tool resolves with 'Failed: ...'")
    func blockingContractFailed() async throws {
        let (ctx, _, router) = try makeContext()

        let tool = EmailComposeTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "to": .array([.string("a@b.com")]),
                "subject": .string("Fail"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }

        // ComposeView's queueSend catch path fires .failed; any later
        // .cancelled from .onDisappear must NOT overwrite (first-resolve wins).
        req.onOutcome(.failed("queueSend: disk full"))
        req.onOutcome(.cancelled)

        let result = try await task.value
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("queueSend"))
        #expect(result.contains("disk full"))
    }

    @Test("Empty recipients → uniform 'Failed: ' shape, never enqueues")
    func preWindowFailureEmptyRecipients() async throws {
        let (ctx, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)

        // email_compose requires at least one recipient. Rejected before the
        // helper — no suspension, no queue entry.
        let result = try await tool.execute(arguments: [
            "to": .array([]),
            "subject": .string("No recipients"),
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("recipients"))
        #expect(router.composeQueueDepth == 0)
    }

    @Test("Missing recipients arg → uniform 'Failed: ' shape, never enqueues")
    func preWindowFailureMissingRecipients() async throws {
        let (ctx, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)

        // No `to` at all — same pre-window rejection path.
        let result = try await tool.execute(arguments: [
            "subject": .string("x"),
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(router.composeQueueDepth == 0)
    }

    @Test("A compose asked with no chat screen fails fast and queues nothing")
    func noOriginFailsFast() async throws {
        let (ctx, _, router) = try makeContext()
        let result = try await ComposeTestOrigin.runWithoutOrigin(EmailComposeTool(context: ctx), arguments: [
            "to": .array([.string("a@example.com")]),
            "subject": .string("Hello"),
        ])
        #expect(result == ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM)
        #expect(router.composeQueueDepth == 0, "no card waits for a screen that can never take it")
    }

    @Test("The compose request carries the chat that asked")
    func requestCarriesItsOrigin() async throws {
        let (ctx, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "to": .array([.string("a@example.com")]),
                "subject": .string("Hello"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }
        #expect(req.origin == ComposeTestOrigin.inbox)
        req.onOutcome(.cancelled)
        _ = try await task.value
    }
}

/// ADR-IOS-053 Phase 2, at the content-generation boundary: a compose tool asked with no screen to
/// open its card on fails before it writes anything.
///
/// THE SYSTEM PROPERTY pinned here: `email_compose`, `email_reply` and `email_forward` invoked with
/// no compose origin (a non-interactive caller, or the compose editor's own chat) make no model call
/// for the email's words, queue no card, and return the no-screen failure the model reads, even
/// when asked to write the words (`request`). Each tool's model calls go to a fake backend through
/// the compose edit it is given (`composeEdit`, the production call on that backend), which counts them; the control shows the same arguments with an
/// origin make exactly one call, so a count of zero is the tool's own choice. The compose editor's
/// case runs its real inline-edit request with a fake tool call answered by the registered tool.
@Suite("Compose tools with no screen write nothing", .serialized, .processGlobalState)
@MainActor
struct ComposeToolGenerationBoundaryTests {
    enum Kind: String, CaseIterable, Sendable {
        case compose
        case reply
        case forward
    }

    /// The fake backend: answers every model call "Done" and records its body. For the compose
    /// editor's case, its first request (the editor's own instruction) is answered with a call to
    /// `email_compose` asking for words.
    final class Backend: @unchecked Sendable {
        /// What a tool asks the model to write.
        static let writeRequest = "Say that Friday works for everyone"
        /// What the user asks the compose editor's chat.
        static let editorInstruction = "Also send a note to Sam"

        let http = FakeHTTP.Scenario()
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
        }
        private let record = Record()

        init() {
            http.register(path: "/completions/chat", method: "POST") { [record] request in
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                record.bodies.withLock { $0.append(body) }
                let final: [String: Any]
                if body.contains(Backend.editorInstruction) && !body.contains("conversation_state") {
                    let arguments: [String: Any] = [
                        "to": ["sam@example.com"], "subject": "Friday",
                        "request": Backend.writeRequest,
                    ]
                    let argumentsText = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    final = [
                        "assistant": "",
                        "tool_calls": [["id": "tc-compose", "function": ["name": "email_compose", "arguments": argumentsText]]],
                        "conversation_state": ["harmony_messages": [], "current_round": 1],
                    ]
                } else {
                    final = ["assistant": "Done"]
                }
                let text = String(decoding: try! JSONSerialization.data(withJSONObject: final), as: UTF8.self)
                return .bytes(Data("event: final\ndata: \(text)\n\n".utf8), contentType: "text/event-stream")
            }
        }

        var service: AIService {
            AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        }

        /// The compose edit the tools here run: the production call (`performInlineEdit`, as
        /// `EmailReplyTool.chatComposeEdit` makes it) on this backend's service, so every model
        /// call a tool makes for its words is recorded here.
        var composeEdit: EmailReplyTool.ComposeEdit {
            let service = service
            return { context, subject, body, request in
                try await service.performInlineEdit(
                    currentSubject: subject, currentBody: body, context: context, instruction: request, chatHistory: [])
            }
        }

        var bodies: [String] { record.bodies.withLock { $0 } }

        /// The model calls that wrote an email's words for a tool: they carry the tool's request.
        var writeCalls: Int { bodies.filter { $0.contains(Backend.writeRequest) && !$0.contains("conversation_state") }.count }
    }

    /// Runs `body` with AI on (the AI choice made, not opted out: `AIService.isAIOff` reads both),
    /// then puts both values back. The opt-out alone leaves AI off while the choice is not made.
    /// It calls `AITestSetting`'s synchronous save and set rather than `AITestSetting.with`, whose
    /// nonisolated async body would take this main-actor closure across an isolation boundary.
    private static func withAIOn(_ body: () async throws -> Void) async throws {
        let restore = AITestSetting.save()
        defer { restore() }
        AITestSetting.set(aiOff: false)
        try await body()
    }

    /// The tool of `kind` on `backend`, its card going to `router`, and the arguments a model asking
    /// it to write the words sends.
    private static func tool(
        _ kind: Kind, backend: Backend, router: AgentToolRouter
    ) async throws -> (any AgentTool, [String: JSONValue]) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgG\(kind.rawValue)", subject: "Plans")
        await translator.seed(header.id, as: 30)
        let ctx = ToolContext(db: db, translator: translator, router: router)
        switch kind {
        case .compose:
            return (EmailComposeTool(context: ctx, composeEdit: backend.composeEdit), [
                "to": .array([.string("sam@example.com")]), "subject": .string("Friday"), "request": .string(Backend.writeRequest),
            ])
        case .reply:
            return (EmailReplyTool(context: ctx, composeEdit: backend.composeEdit), ["unique_id": .int(30), "request": .string(Backend.writeRequest)])
        case .forward:
            return (EmailForwardTool(context: ctx, composeEdit: backend.composeEdit), [
                "unique_id": .int(30), "to": .array([.string("sam@example.com")]), "request": .string(Backend.writeRequest),
            ])
        }
    }

    /// The invocation the compose editor's chat runs its inline edit with: its session's card sink
    /// and key, and no compose origin (its host is a compose window, which opens no agent card).
    private static func editorInvocation() -> ToolInvocation {
        let key = ActiveAgentTracker.composeSessionKey(draftId: "draft-boundary", epoch: "1")
        return ToolInvocation(uiSink: SessionUISink(session: ChatPillState.shared.session(for: key)), sessionKey: key)
    }

    @Test("A compose tool with no screen makes no model call for the words, queues no card, and fails plainly", arguments: Kind.allCases)
    func noOriginWritesNothing(kind: Kind) async throws {
        try await Self.withAIOn {
            let backend = Backend()
            defer { backend.http.close() }
            let router = AgentToolRouter()
            let (tool, arguments) = try await Self.tool(kind, backend: backend, router: router)
            let noScreen = ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM
            for invocation in [ToolInvocation.noninteractive, Self.editorInvocation()] {
                // Bounded: a tool that waits for a card is cancelled after five seconds and the wait
                // ends even if the tool ignores that, so a regression fails here instead of hanging the run.
                let run = Task { @MainActor in try await tool.execute(arguments: arguments, invocation: invocation) }
                guard let finished = await BoundedWait.result(of: run, within: .seconds(5)) else {
                    Issue.record("\(kind.rawValue): the tool did not return within five seconds")
                    continue
                }
                let result = try finished.get()
                #expect(result == noScreen, "\(kind.rawValue): the plain no-screen failure: \(result)")
            }
            let calls = backend.bodies.count
            #expect(calls == 0, "\(kind.rawValue): no model call writes words for a card no screen can open")
            #expect(router.composeQueueDepth == 0, "\(kind.rawValue): no card waits")
        }
    }

    @Test("Control: the same compose tool asked from a screen makes one model call for the words, then queues its card", arguments: Kind.allCases)
    func withOriginWritesOnce(kind: Kind) async throws {
        try await Self.withAIOn {
            let backend = Backend()
            defer { backend.http.close() }
            let router = AgentToolRouter()
            let (tool, arguments) = try await Self.tool(kind, backend: backend, router: router)
            let task = Task { @MainActor () -> String in
                try await tool.execute(arguments: arguments, invocation: ComposeTestOrigin.invocation)
            }
            let deadline = Date().addingTimeInterval(5)
            while router.composeQueueDepth == 0, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let request = router.takeCompose(for: ComposeTestOrigin.inboxHost) else {
                Issue.record("\(kind.rawValue): the card was never queued")
                task.cancel()
                _ = try? await task.value
                return
            }
            let writes = backend.writeCalls
            #expect(writes == 1, "\(kind.rawValue): one model call wrote the words: \(backend.bodies.count) calls")
            request.onOutcome(.cancelled)
            _ = try? await task.value
        }
    }

    @Test("The compose editor's chat: a compose tool the model calls there writes nothing and queues no card")
    func composeEditorToolCallWritesNothing() async throws {
        try await Self.withAIOn {
            let backend = Backend()
            defer { backend.http.close() }
            let router = AgentToolRouter()
            let registry = ToolRegistry.shared
            await registry.ensureDefaultToolsRegistered()
            let registered = await registry.tool(named: "email_compose")
            let (tool, _) = try await Self.tool(.compose, backend: backend, router: router)
            await registry.register(tool)

            let context = ComposeEditContext(
                recipients: ["alex@example.com"], toRecipients: ["alex@example.com"], ccRecipients: [], bccRecipients: [],
                toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
                senderName: "Me", senderEmail: "me@example.com", mode: "edit_new",
                compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "",
                relatedFrom: "", relatedTo: "", relatedCc: "", bodyText: "")
            // Bounded: a tool that waits for a card is cancelled after five seconds and the wait ends
            // even if the edit ignores that, so a regression fails here instead of hanging the run.
            let service = backend.service
            let invocation = Self.editorInvocation()
            let run = Task { @MainActor in
                try await service.performInlineEdit(
                    currentSubject: "Friday", currentBody: "", context: context,
                    instruction: Backend.editorInstruction, chatHistory: [], invocation: invocation)
            }
            let finished = await BoundedWait.result(of: run, within: .seconds(5))
            if let registered { await registry.register(registered) }
            guard let finished else {
                Issue.record("the editor's edit did not return within five seconds")
                return
            }
            _ = try finished.get()

            let bodies = backend.bodies
            #expect(bodies.count == 2, "the editor's request and the round with the tool's result, nothing else: \(bodies.count)")
            let writes = backend.writeCalls
            #expect(writes == 0, "the tool wrote no words")
            let answered = bodies.last?.contains(ComposeOrigin.noScreenReason) == true
            #expect(answered, "the model reads the tool's no-screen failure")
            #expect(router.composeQueueDepth == 0, "no card waits")
        }
    }
}
