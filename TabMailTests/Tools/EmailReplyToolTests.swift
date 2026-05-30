/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Blocking-contract tests for `EmailReplyTool` — covers the helper-returned
/// outcome strings (`.sent` / `.cancelled`) and the uniform pre-window
/// failure shape.
///
/// Each test owns a fresh `AgentToolRouter` injected via `ToolContext` — no
/// `.shared` access from the test body. This eliminates the cross-suite
/// contention that made these tests flaky when they ran in parallel with
/// `EmailComposeToolOutcomeTests` and `AgentToolRouterTests` (all of which
/// touched the singleton's `pendingCompose` / `composeQueue` /
/// `recentlySentCompose`). With per-test routers the contention is
/// structurally impossible, not just policy-protected.
@Suite("EmailReplyTool blocking contract")
@MainActor
struct EmailReplyToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        let ctx = ToolContext(db: db, translator: translator, router: router)
        return (ctx, db, translator, router)
    }

    /// Wait for the helper to populate `pendingCompose` on the MainActor.
    /// The tool's `execute()` does translator + db awaits before reaching
    /// the helper, so a fixed number of `Task.yield()` calls is unreliable.
    /// Polls cooperatively until the request appears or we exceed the
    /// timeout (failure surfaces as the nil-guard in each test).
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

    @Test("Tool name is email_reply")
    func toolName() throws {
        let (ctx, _, _, _) = try makeContext()
        let tool = EmailReplyTool(context: ctx)
        #expect(tool.name == "email_reply")
    }

    @Test("User sending compose → tool resolves with 'sent successfully'")
    func blockingContractSent() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR1", subject: "Hello")
        await translator.seed(header.id, as: 1)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(1)])
        }
        // Let execute() reach the helper's suspension (translator + db awaits
        // complete first, then the helper sets pendingCompose).
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
            task.cancel()
            _ = try? await task.value
            return
        }

        req.onOutcome(.sent)
        let result = try await task.value
        #expect(result.contains("sent successfully"))
    }

    @Test("User dismissing compose → tool resolves with 'closed the compose window'")
    func blockingContractCancelled() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR2", subject: "Bye")
        await translator.seed(header.id, as: 2)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(2)])
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

    @Test("queueSend failure → tool resolves with 'Failed: queueSend: ...'")
    func blockingContractFailed() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR3", subject: "Fail")
        await translator.seed(header.id, as: 3)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(3)])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
            task.cancel()
            _ = try? await task.value
            return
        }

        // Simulate ComposeView's queueSend catch path firing .failed, then
        // the user eventually dismissing (which fires .onDisappear →
        // .cancelled, but tryResolve keeps the .failed outcome).
        req.onOutcome(.failed("queueSend: disk full"))
        req.onOutcome(.cancelled)

        let result = try await task.value
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("queueSend"))
        #expect(result.contains("disk full"))
    }

    @Test("Bad unique_id → uniform 'Failed: ' shape, never enqueues")
    func preWindowFailureUsesUniformShape() async throws {
        let (ctx, _, _, router) = try makeContext()
        let tool = EmailReplyTool(context: ctx)

        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
        #expect(router.composeQueueDepth == 0)
        #expect(router.pendingCompose == nil)
    }

    @Test("Unknown numeric ID → 'Failed: Email not found for unique_id N'")
    func unknownNumericId() async throws {
        let (ctx, _, _, router) = try makeContext()
        let tool = EmailReplyTool(context: ctx)

        let result = try await tool.execute(arguments: ["unique_id": .int(404)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("Email not found for unique_id 404"))
        #expect(router.composeQueueDepth == 0)
    }

    @Test("ID in translator but message missing from DB → 'Failed: ... no longer exists'")
    func idInTranslatorButMissingFromDb() async throws {
        let (ctx, _, translator, router) = try makeContext()
        await translator.seed("missing_msg_id", as: 99)
        let tool = EmailReplyTool(context: ctx)

        let result = try await tool.execute(arguments: ["unique_id": .int(99)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("no longer exists"))
        #expect(router.composeQueueDepth == 0)
    }

    // MARK: - Retry dedup (Round 2 failure → fresh chat turn re-emits tool_call)

    @Test(".sent marks the dedup cache keyed on accountId + stableId + .reply")
    func sentMarksDedupCache() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR10", subject: "Hi", rfc822MessageId: "rfc-10")
        await translator.seed(header.id, as: 10)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(10)])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
            task.cancel(); _ = try? await task.value; return
        }
        req.onOutcome(.sent)
        _ = try await task.value

        // Cache should now mark (acc1, header.stableId, .reply) as recent.
        let key = RecentlyCompletedComposeCache.Key(
            accountId: header.accountId, stableId: header.stableId, mode: .reply
        )
        #expect(router.recentlySentCompose.isRecentlySent(key) == true)
    }

    @Test("Retry after .sent short-circuits without opening compose")
    func retryAfterSentShortCircuits() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR11", subject: "Hi", rfc822MessageId: "rfc-11")
        await translator.seed(header.id, as: 11)

        // First round: user sends.
        let tool = EmailReplyTool(context: ctx)
        let firstTask = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(11)])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
            firstTask.cancel(); _ = try? await firstTask.value; return
        }
        req.onOutcome(.sent)
        _ = try await firstTask.value

        // Clear pendingCompose as the view normally would on teardown.
        router.pendingCompose = nil
        router.resetComposeQueueForTesting()

        // Round 2 HTTP fails → chat turn retries → tool fires again with the
        // same unique_id. Cache should short-circuit.
        let retryResult = try await tool.execute(arguments: ["unique_id": .int(11)])
        #expect(retryResult.contains("already sent"))
        #expect(router.composeQueueDepth == 0)
        #expect(router.pendingCompose == nil)
    }

    @Test(".cancelled does NOT mark the dedup cache (user must be able to retry)")
    func cancelledDoesNotMarkCache() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR12", subject: "Hi", rfc822MessageId: "rfc-12")
        await translator.seed(header.id, as: 12)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(12)])
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not populate pendingCompose")
            task.cancel(); _ = try? await task.value; return
        }
        req.onOutcome(.cancelled)
        _ = try await task.value

        // Cache must NOT contain the key — user dismissing the window is not
        // "sent", and a retry should be allowed to re-open compose.
        let key = RecentlyCompletedComposeCache.Key(
            accountId: header.accountId, stableId: header.stableId, mode: .reply
        )
        #expect(router.recentlySentCompose.isRecentlySent(key) == false)
    }
}
