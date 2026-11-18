/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Invariant: when the assistant's compose, forward or reply tool asks the AI to write the
/// body, the edit request keeps every recipient's role. A Cc recipient arrives as Cc, never
/// as To, so the AI does not write the body as if the copied person were a primary addressee.
///
/// The backend call is replaced per task through `EmailComposeTool.inlineEditOverride`, which
/// receives the exact `ComposeEditContext` the tool built for `performInlineEdit`.
@Suite("Compose edit keeps recipient roles")
@MainActor
struct ComposeEditRecipientRolesTests {

    private actor ContextBox {
        var contexts: [ComposeEditContext] = []
        func append(_ ctx: ComposeEditContext) { contexts.append(ctx) }
    }

    private static let primary = "sam@example.com"
    private static let copied = "pat@example.com"
    private static let blind = "lee@example.com"

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        let ctx = ToolContext(db: db, translator: translator, router: router)
        return (ctx, db, translator, router)
    }

    private func waitForPendingCompose(on router: AgentToolRouter, timeout seconds: Double = 5.0) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let req = router.pendingCompose { return req }
            await Task.yield()
        }
        return router.pendingCompose
    }

    /// Runs `tool` with the backend edit call captured, closes the compose card it opens, and
    /// returns every edit context the tool built.
    private func captureEditContexts(
        router: AgentToolRouter,
        run: @escaping @MainActor () async throws -> String
    ) async throws -> [ComposeEditContext] {
        let box = ContextBox()
        let override: @Sendable (ComposeEditContext, String) async throws -> InlineEditResult = { ctx, _ in
            await box.append(ctx)
            return InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil, raw: "")
        }
        try await EmailComposeTool.$inlineEditOverride.withValue(override) {
            let task = Task { @MainActor () -> String in try await run() }
            guard let req = await waitForPendingCompose(on: router) else {
                Issue.record("Tool did not open a compose card")
                task.cancel()
                _ = try? await task.value
                return
            }
            req.onOutcome(.cancelled)
            _ = try await task.value
        }
        return await box.contexts
    }

    private func expectRolesKept(_ contexts: [ComposeEditContext], expectTo: String) {
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        let ctx = contexts[0]
        #expect(ctx.toRecipients.contains(expectTo))
        #expect(ctx.ccRecipients == [Self.copied])
        #expect(!ctx.toRecipients.contains(Self.copied))
        #expect(!ctx.recipients.contains(Self.copied))
    }

    /// A Bcc recipient never reaches the edit request as To or Cc.
    private func expectBccNotToOrCc(_ contexts: [ComposeEditContext]) {
        guard contexts.count == 1 else { return }
        #expect(!contexts[0].toRecipients.contains(Self.blind))
        #expect(!contexts[0].ccRecipients.contains(Self.blind))
    }

    @Test("email_compose: To Sam, Cc Pat, Bcc Lee reaches the edit request as To Sam, Cc Pat")
    func composeKeepsCcAsCc() async throws {
        let (ctx, _, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)
        let contexts = try await captureEditContexts(router: router) {
            try await tool.execute(arguments: [
                "to": .array([.string(Self.primary)]),
                "cc": .array([.string(Self.copied)]),
                "bcc": .array([.string(Self.blind)]),
                "request": .string("Ask about moving the offsite to Friday"),
            ])
        }
        expectRolesKept(contexts, expectTo: Self.primary)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].mode == "edit_new")
        expectBccNotToOrCc(contexts)
    }

    @Test("email_forward: To Sam, Cc Pat, Bcc Lee reaches the edit request as To Sam, Cc Pat")
    func forwardKeepsCcAsCc() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "fwd1", subject: "Offsite")
        await translator.seed(header.id, as: 11)

        let tool = EmailForwardTool(context: ctx)
        let contexts = try await captureEditContexts(router: router) {
            try await tool.execute(arguments: [
                "unique_id": .int(11),
                "to": .array([.string(Self.primary)]),
                "cc": .array([.string(Self.copied)]),
                "bcc": .array([.string(Self.blind)]),
                "request": .string("Let them know Friday works"),
            ])
        }
        expectRolesKept(contexts, expectTo: Self.primary)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].mode == "edit_forward")
        expectBccNotToOrCc(contexts)
    }

    private static let alsoCopied = "lee@example.com"
    private static let newlyCopied = "kim@example.com"

    /// Replies with a content request to a message from Sam that copied Pat and Lee, and
    /// returns the edit contexts the reply tool built.
    private func replyEditContexts(extraArguments: [String: JSONValue]) async throws -> [ComposeEditContext] {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "rep1", subject: "Offsite",
            from: Self.primary, fromAddress: Self.primary,
            to: "test@example.com"
        )
        header.cc = "\(Self.copied), \(Self.alsoCopied)"
        let updated = header
        try await db.write { db in try updated.update(db) }
        await translator.seed(header.id, as: 12)

        let tool = EmailReplyTool(context: ctx)
        var arguments: [String: JSONValue] = [
            "unique_id": .int(12),
            "request": .string("Say Friday works"),
        ]
        arguments.merge(extraArguments) { _, new in new }
        let finalArguments = arguments
        return try await captureEditContexts(router: router) {
            try await tool.execute(arguments: finalArguments)
        }
    }

    @Test("email_reply: an added Cc reaches the edit request as Cc, not To")
    func replyKeepsAddedCcAsCc() async throws {
        let contexts = try await replyEditContexts(extraArguments: [
            "add_cc": .array([.string(Self.newlyCopied)]),
        ])
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].recipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.copied, Self.alsoCopied, Self.newlyCopied])
        #expect(contexts[0].mode == "edit_reply")
    }

    @Test("email_reply: the original message's Cc reaches the edit request as Cc, not To")
    func replyKeepsRetainedCcAsCc() async throws {
        let contexts = try await replyEditContexts(extraArguments: [:])
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].recipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.copied, Self.alsoCopied])
    }

    @Test("email_reply: a removed Cc is absent from the edit request")
    func replyDropsRemovedCc() async throws {
        let contexts = try await replyEditContexts(extraArguments: [
            "remove_cc": .array([.string(Self.copied)]),
        ])
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].recipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.alsoCopied])
    }

    @Test("email_reply: a replaced Cc reaches the edit request as the new Cc only")
    func replyKeepsReplacedCcAsCc() async throws {
        let contexts = try await replyEditContexts(extraArguments: [
            "remove_cc": .array([.string(Self.copied)]),
            "add_cc": .array([.string(Self.newlyCopied)]),
        ])
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].recipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.alsoCopied, Self.newlyCopied])
    }
}
