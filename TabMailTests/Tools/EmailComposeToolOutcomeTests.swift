/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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
            if let req = router.pendingCompose { return req }
            await Task.yield()
        }
        return router.pendingCompose
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
            ])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
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
            ])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
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
            ])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
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
        #expect(router.pendingCompose == nil)
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
        #expect(router.pendingCompose == nil)
    }
}
