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
/// touched the singleton's compose slot / `composeQueue` /
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

    /// Wait for the helper to queue the request, and take it as the inbox chat's pill does
    /// (`ComposeTestOrigin`). The tool's `execute()` does translator + db awaits before reaching
    /// the helper, so a fixed number of `Task.yield()` calls is unreliable. Polls cooperatively
    /// until the request is taken or we exceed the timeout (failure surfaces as the nil-guard in
    /// each test).
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
            try await tool.execute(arguments: ["unique_id": .int(1)], invocation: ComposeTestOrigin.invocation)
        }
        // Let execute() reach the helper's suspension (translator + db awaits
        // complete first, then the helper queues the request).
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }

        req.onOutcome(.sent)
        let result = try await task.value
        #expect(result.contains("sent successfully"))
    }

    /// #915: the tool fills the reply-all recipient set, so the send must
    /// record reply-all (103) on the Outlook original, like the Reply All button.
    @Test("The AI reply request is flagged reply-all")
    func requestIsReplyAll() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgRA", subject: "Hello")
        await translator.seed(header.id, as: 1)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(1)], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }
        #expect(req.mode == .reply)
        #expect(req.isReplyAll)
        req.onOutcome(.cancelled)
        _ = try await task.value
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
            try await tool.execute(arguments: ["unique_id": .int(2)], invocation: ComposeTestOrigin.invocation)
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

    @Test("queueSend failure → tool resolves with 'Failed: queueSend: ...'")
    func blockingContractFailed() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR3", subject: "Fail")
        await translator.seed(header.id, as: 3)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(3)], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
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
            try await tool.execute(arguments: ["unique_id": .int(10)], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
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
            try await tool.execute(arguments: ["unique_id": .int(11)], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            firstTask.cancel(); _ = try? await firstTask.value; return
        }
        req.onOutcome(.sent)
        _ = try await firstTask.value

        // Clear the queue as the compose window's teardown would.
        router.resetComposeQueueForTesting()

        // Round 2 HTTP fails → chat turn retries → tool fires again with the
        // same unique_id. Cache should short-circuit.
        let retryResult = try await tool.execute(arguments: ["unique_id": .int(11)], invocation: ComposeTestOrigin.invocation)
        #expect(retryResult.contains("already sent"))
        #expect(router.composeQueueDepth == 0)
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
            try await tool.execute(arguments: ["unique_id": .int(12)], invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
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

    // MARK: - Where the card opens (ADR-IOS-053 Phase 2)

    @Test("A reply asked with no chat screen fails fast and queues nothing")
    func noOriginFailsFast() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR20", subject: "Hi")
        await translator.seed(header.id, as: 20)

        let result = try await ComposeTestOrigin.runWithoutOrigin(EmailReplyTool(context: ctx), arguments: ["unique_id": .int(20)])
        #expect(result == ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM)
        #expect(router.composeQueueDepth == 0, "no card waits for a screen that can never take it")
    }

    @Test("The reply request carries the chat that asked, and only that chat takes it")
    func requestCarriesItsOrigin() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msgR21", subject: "Hi")
        await translator.seed(header.id, as: 21)
        let asked = ComposeOrigin(sessionKey: "thread:acc1:t-21", screen: .chat)
        let invocation = ToolInvocation(composeOrigin: asked)

        let tool = EmailReplyTool(context: ctx)
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: ["unique_id": .int(21)], invocation: invocation)
        }
        let deadline = Date().addingTimeInterval(2.0)
        while router.composeQueueDepth == 0 && Date() < deadline {
            await Task.yield()
        }
        #expect(router.firstQueuedRequestForTesting?.origin == asked, "the request names the chat that asked")
        let inbox = router.takeCompose(for: ComposeTestOrigin.inboxHost)
        #expect(inbox == nil, "the inbox never takes the chat's request")
        let email = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .email, sessionKeys: [asked.sessionKey]))
        #expect(email == nil, "nor the email screen of the same thread")
        let req = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: ["thread:acc1:newer", asked.sessionKey]))
        #expect(req?.origin == asked, "the chat that asked takes it, by any key of its thread")
        req?.onOutcome(.cancelled)
        if req == nil { task.cancel() }
        _ = try? await task.value
    }

    // MARK: - An email only the user's own addresses are on

    /// One recipient change the reply tool is asked for on an own-only email, and the card it opens.
    struct OwnOnlyChange: Sendable, CustomTestStringConvertible {
        let name: String
        let arguments: [String: JSONValue]
        let to: [String]
        let cc: [String]
        let bcc: [String]
        /// The To entries that name no sendable address, as written.
        var toNamed: [String] = []
        var testDescription: String { name }
    }

    nonisolated static let ownOnlyChanges: [OwnOnlyChange] = [
        OwnOnlyChange(name: "someone else added to To", arguments: ["add_recipients": .array([.string("bob@example.com")])],
                      to: ["bob@example.com"], cc: [], bcc: []),
        OwnOnlyChange(name: "someone else added to Cc", arguments: ["add_cc": .array([.string("bob@example.com")])],
                      to: [], cc: ["bob@example.com"], bcc: []),
        OwnOnlyChange(name: "someone else added to Bcc", arguments: ["add_bcc": .array([.string("bob@example.com")])],
                      to: [], cc: [], bcc: ["bob@example.com"]),
        // A name with no address is someone else too: the user names them on the card, which then
        // holds them alone.
        OwnOnlyChange(name: "someone else added by name only", arguments: ["add_recipients": .array([.string("Bob Smith")])],
                      to: [], cc: [], bcc: [], toNamed: ["Bob Smith"]),
        OwnOnlyChange(name: "someone else added by name only, beside one of the user's own addresses",
                      arguments: ["add_recipients": .array([.string("A@example.com"), .string("Bob Smith")])],
                      to: ["a@example.com"], cc: [], bcc: [], toNamed: ["Bob Smith"]),
        OwnOnlyChange(name: "To cleared and someone else added by name only",
                      arguments: ["remove_recipients": .array([.string("*")]), "add_recipients": .array([.string("Bob Smith")])],
                      to: [], cc: [], bcc: [], toNamed: ["Bob Smith"]),
        // Controls: with nobody else added, the user's own addresses are the reply's audience.
        OwnOnlyChange(name: "no change", arguments: [:],
                      to: ["a@example.com", "b@example.com"], cc: ["c@example.com"], bcc: []),
        OwnOnlyChange(name: "one of the user's own addresses added",
                      arguments: ["add_recipients": .array([.string("A@example.com")])],
                      to: ["a@example.com", "b@example.com"], cc: ["c@example.com"], bcc: []),
    ]

    /// The user forwards an email from their account A to their account B, copying their account C,
    /// and, on the copy B received, asks for a reply. Its Reply All holds nobody, so the reply goes to
    /// A, then B, with C in Cc (`ChatThread.replyAllAudience`). Once the change adds someone else, the
    /// card opens to them alone: the person added is never shown the user's other addresses. B's
    /// account address is stored with capitals, as an account can be, and is still one of the user's.
    @Test("An own-only email's reply card keeps the user's addresses only while nobody else is added",
          arguments: ownOnlyChanges)
    func ownOnlyFallbackWithAChange(_ change: OwnOnlyChange) async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "B@Example.com")
        try TestDatabase.insertAccount(db, id: "acc3", email: "c@example.com")
        try TestDatabase.insertFolder(db, accountId: "acc2")
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msgOwn", subject: "Notes", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", folderId: "acc2:INBOX", accountId: "acc2")
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cc = 'c@example.com' WHERE id = ?", arguments: [header.id])
        }
        await translator.seed(header.id, as: 30)

        let tool = EmailReplyTool(context: ctx)
        let arguments = change.arguments.merging(["unique_id": .int(30)]) { $1 }
        let task = Task { @MainActor () -> String in
            try await tool.execute(arguments: arguments, invocation: ComposeTestOrigin.invocation)
        }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Helper did not queue a request the asking chat could take")
            task.cancel()
            _ = try? await task.value
            return
        }
        let to = RecipientEntry(req.to).addresses.map { $0.lowercased() }
        let cc = RecipientEntry(req.cc).addresses.map { $0.lowercased() }
        let bcc = RecipientEntry(req.bcc).addresses.map { $0.lowercased() }
        let toNamed = RecipientEntry(req.to).leftovers
        #expect(to == change.to && cc == change.cc && bcc == change.bcc, "To \(to), Cc \(cc), Bcc \(bcc)")
        #expect(toNamed == change.toNamed, "To entries with no address: \(toNamed)")
        #expect(req.isReplyAll, "a Reply All, as before the own-only audience")
        req.onOutcome(.cancelled)
        _ = try await task.value
    }
}
