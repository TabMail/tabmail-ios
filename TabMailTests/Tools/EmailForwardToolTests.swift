/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailForwardTool")
struct EmailForwardToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db, translator)
    }

    @Test("Tool name is email_forward")
    func toolName() throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        #expect(tool.name == "email_forward")
    }

    @Test("Missing unique_id returns error")
    func missingUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Non-numeric string unique_id returns error")
    func nonNumericStringUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("abc")])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Boolean unique_id returns error")
    func boolUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .bool(true)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Unknown numeric ID returns not found for given unique_id")
    func unknownNumericId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(999)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("Email not found for unique_id 999"))
    }

    @Test("ID in translator but message not in DB returns email not found")
    func idInTranslatorButNotInDb() async throws {
        let (ctx, _, translator) = try makeContext()
        await translator.seed("nonexistent_msg", as: 50)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(50),
            "request": .string("Forward this please")
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("no longer exists"))
    }

    @Test("Missing both request and body returns error")
    func missingRequestAndBody() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg1", subject: "Fwd Test")
        await translator.seed(header.id, as: 10)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(10),
            "to": .array([.string("bob@test.com")])
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("request parameter is required"))
    }

    @Test("unique_id as string '42' parsed correctly")
    func uniqueIdAsString() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        // String "42" should parse to numeric 42, then fail at translator lookup (not at parse)
        let result = try await tool.execute(arguments: ["unique_id": .string("42")])
        #expect(!result.contains("missing or invalid unique_id"))
        #expect(result.contains("Email not found for unique_id 42"))
    }

    @Test("unique_id as double 42.0 parsed correctly")
    func uniqueIdAsDouble() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        // Double 42.0 should parse to numeric 42, then fail at translator lookup (not at parse)
        let result = try await tool.execute(arguments: ["unique_id": .double(42.0)])
        #expect(!result.contains("missing or invalid unique_id"))
        #expect(result.contains("Email not found for unique_id 42"))
    }

    @Test("Empty string request with no body returns error")
    func emptyRequestNoBody() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg2", subject: "Empty Req")
        await translator.seed(header.id, as: 20)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(20),
            "request": .string("")
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("request parameter is required"))
    }
}

/// Where the forward's compose card opens (ADR-IOS-053 Phase 2). Each test owns a fresh
/// `AgentToolRouter` injected through `ToolContext`, like `EmailReplyToolTests`.
@Suite("EmailForwardTool card origin")
@MainActor
struct EmailForwardToolOriginTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        return (ToolContext(db: db, translator: translator, router: router), db, translator, router)
    }

    @Test("A forward asked with no chat screen fails fast and queues nothing")
    func noOriginFailsFast() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgF20", subject: "Agenda")
        await translator.seed(header.id, as: 20)

        let result = try await ComposeTestOrigin.runWithoutOrigin(EmailForwardTool(context: ctx), arguments: [
            "unique_id": .int(20),
            "to": .array([.string("sam@example.com")]),
            "body": .string("For you")
        ])
        #expect(result == ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM)
        #expect(router.composeQueueDepth == 0, "no card waits for a screen that can never take it")
    }

    @Test("The forward request carries the screen that asked, and only that screen takes it")
    func requestCarriesItsOrigin() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgF21", subject: "Agenda")
        await translator.seed(header.id, as: 21)
        let asked = ComposeOrigin(sessionKey: ChatThreadKey.key(for: header), screen: .email)
        let invocation = ToolInvocation(composeOrigin: asked)

        let tool = EmailForwardTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: [
                "unique_id": .int(21),
                "to": .array([.string("sam@example.com")]),
                "body": .string("For you")
            ], invocation: invocation)
        }
        let deadline = Date().addingTimeInterval(2.0)
        while router.composeQueueDepth == 0 && Date() < deadline {
            await Task.yield()
        }
        #expect(router.firstQueuedRequestForTesting?.origin == asked, "the request names the screen that asked")
        #expect(router.firstQueuedRequestForTesting?.to == ["sam@example.com"])
        let inbox = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        #expect(inbox == nil, "the inbox never takes the email screen's request")
        let chat = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey]))
        #expect(chat == nil, "nor the chat of the same thread")
        let req = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .email, sessionKeys: [asked.sessionKey]))
        #expect(req?.origin == asked, "the email screen that asked takes it")
        req?.onOutcome(.cancelled)
        if req == nil { task.cancel() }
        _ = try? await task.value
    }
}
