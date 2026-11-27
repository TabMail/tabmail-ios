/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// The test accounts' ids, at file scope so a `@Test` argument list can name them.
private let homeAccountId = "acc-home"
private let workAccountId = "acc-work"

/// Invariant: when the assistant writes an email, the AI signs the body as the account the email
/// is sent from. A reply or forward is sent from the email's own account, so the body is signed
/// with that account's name even when it is not the primary account. A new email is sent from
/// the primary account (the demo account in demo), and its compose card opens with exactly the
/// account the body was signed as.
///
/// The backend call is replaced per task through `EmailComposeTool.inlineEditOverride`, which
/// receives the exact `ComposeEditContext` the tool built for `performInlineEdit`; one test sends
/// that context through a real `AIService` request to read the name the backend receives.
///
/// `.processGlobalState`: the tools read the process-wide demo mode, which each test pins, and
/// the request test reads the App Group AI opt-out flag, which it pins off and restores.
@Suite("Compose edit signs as the sending account", .serialized, .processGlobalState)
@MainActor
struct ComposeEditSenderAccountTests {

    private actor ContextBox {
        var contexts: [ComposeEditContext] = []
        func append(_ ctx: ComposeEditContext) { contexts.append(ctx) }
    }

    private static let home = (id: homeAccountId, email: "home@example.com", name: "Home Name")
    private static let work = (id: workAccountId, email: "work@example.com", name: "Work Name")
    private static let demo = (id: DemoSeed.demoAccountId, email: "demo@example.com", name: "Demo Name")
    private static let correspondent = "sam@example.com"
    /// The address the work account's email was sent to: a team alias, not the account's own
    /// address, so the account the email arrived in is known only from the email's account.
    private static let workAlias = "team@example.com"

    /// A database with the home and work accounts and an Inbox for each. `primaryId` is the
    /// primary account (nil: none is), `inactive` the accounts that are not active, and
    /// `withDemoRow` adds the demo account as the app seeds it (active and primary).
    ///
    /// Rows are inserted demo first, then home, then work. The account lookups have no order,
    /// so they read rows in this order: a row a filter must skip comes BEFORE the expected one,
    /// and a lookup without that filter returns the wrong account.
    private func makeContext(
        primaryId: String?,
        inactive: Set<String> = [],
        withDemoRow: Bool = false
    ) throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        if withDemoRow {
            var account = Account(emailAddress: Self.demo.email, displayName: Self.demo.name, provider: .imap)
            account.id = Self.demo.id
            account.isActive = true
            account.isPrimary = true
            try db.write { try account.insert($0) }
        }
        for seed in [Self.home, Self.work] {
            var account = Account(emailAddress: seed.email, displayName: seed.name, provider: .gmail)
            account.id = seed.id
            account.isPrimary = seed.id == primaryId
            account.isActive = !inactive.contains(seed.id)
            try db.write { try account.insert($0) }
            try TestDatabase.insertFolder(db, accountId: seed.id)
        }
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        return (ToolContext(db: db, translator: translator, router: router), db, translator, router)
    }

    /// Runs `body` with demo mode set to `active`, and puts the previous mode back after.
    private func withDemoMode(_ active: Bool, _ body: () async throws -> Void) async throws {
        let prior = DemoModeStore.shared.isActive
        DemoModeStore.shared.isActive = active
        do {
            try await body()
        } catch {
            DemoModeStore.shared.isActive = prior
            throw error
        }
        DemoModeStore.shared.isActive = prior
    }

    /// An email from Sam to the work account's team alias, in the work account's Inbox.
    private func insertWorkEmail(_ db: DatabaseQueue, messageId: String) throws -> MessageHeader {
        try TestDatabase.insertMessageHeader(
            db, messageId: messageId, subject: "Offsite",
            from: Self.correspondent, fromAddress: Self.correspondent,
            to: Self.workAlias,
            folderId: "\(Self.work.id):INBOX", accountId: Self.work.id
        )
    }

    private func waitForPendingCompose(on router: AgentToolRouter, timeout seconds: Double = 5.0) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let req = router.pendingCompose { return req }
            await Task.yield()
        }
        return router.pendingCompose
    }

    /// What the compose card was opened with: the request's account (a new email) and the
    /// account of the email it replies to or forwards.
    private struct Card: Sendable {
        let account: Account?
        let replyToAccountId: String?
    }

    nonisolated private static func cannedEdit() -> InlineEditResult {
        InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil, raw: "")
    }

    /// Runs `tool` with the backend edit call captured, closes the compose card it opens, and
    /// returns every edit context the tool built and what the card was opened with. `edit`
    /// answers the edit call (default: a fixed result).
    private func captureEditAndRequest(
        router: AgentToolRouter,
        edit: (@Sendable (ComposeEditContext, String) async throws -> InlineEditResult)? = nil,
        run: @escaping @MainActor () async throws -> String
    ) async throws -> (contexts: [ComposeEditContext], card: Card?) {
        var enqueued: Card?
        let box = ContextBox()
        let override: @Sendable (ComposeEditContext, String) async throws -> InlineEditResult = { ctx, instruction in
            await box.append(ctx)
            if let edit { return try await edit(ctx, instruction) }
            return Self.cannedEdit()
        }
        try await EmailComposeTool.$inlineEditOverride.withValue(override) {
            let task = Task { @MainActor () -> String in try await run() }
            guard let req = await waitForPendingCompose(on: router) else {
                Issue.record("Tool did not open a compose card")
                task.cancel()
                _ = try? await task.value
                return
            }
            enqueued = Card(account: req.account, replyToAccountId: req.replyTo?.accountId)
            req.onOutcome(.cancelled)
            _ = try await task.value
        }
        return (await box.contexts, enqueued)
    }

    @Test("email_reply: a reply to the work account's email is signed as the work account, primary or not", arguments: [homeAccountId, workAccountId])
    func replySignsAsTheRepliedEmailsAccount(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, db, translator, router) = try makeContext(primaryId: primaryId)
            let header = try insertWorkEmail(db, messageId: "rep-work")
            await translator.seed(header.id, as: 21)

            let tool = EmailReplyTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "unique_id": .int(21),
                    "request": .string("Say Friday works"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].mode == "edit_reply")
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.contexts[0].senderEmail == Self.work.email)
            // The card sends from the replied email's account.
            #expect(captured.card?.replyToAccountId == Self.work.id)
        }
    }

    @Test("email_forward: a forward of the work account's email is signed as the work account, primary or not", arguments: [homeAccountId, workAccountId])
    func forwardSignsAsTheForwardedEmailsAccount(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, db, translator, router) = try makeContext(primaryId: primaryId)
            let header = try insertWorkEmail(db, messageId: "fwd-work")
            await translator.seed(header.id, as: 22)

            let tool = EmailForwardTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "unique_id": .int(22),
                    "to": .array([.string("pat@example.com")]),
                    "request": .string("Let them know Friday works"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].mode == "edit_forward")
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.contexts[0].senderEmail == Self.work.email)
            // The card sends from the forwarded email's account.
            #expect(captured.card?.replyToAccountId == Self.work.id)
        }
    }

    /// The name reaches the backend: the reply tool's edit goes through a real `AIService`
    /// request, whose `user_name` is the name the AI signs with.
    @Test("email_reply: the backend request signs as the work account's name, not the primary's")
    func replyRequestCarriesTheRepliedAccountsName() async throws {
        let restoreAISetting = AITestSetting.save()
        defer { restoreAISetting() }
        AITestSetting.set(aiOff: false)
        try await withDemoMode(false) {
            let backend = FakeHTTP.Scenario()
            backend.register(path: "/completions/chat", method: "POST") { _ in
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": "Subject: Offsite\nBody: Friday works."])) ?? Data()
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
            let service = AIService(backendClient: BackendClient(llmSession: backend.session))
            let (ctx, db, translator, router) = try makeContext(primaryId: Self.home.id)
            let header = try insertWorkEmail(db, messageId: "rep-wire")
            await translator.seed(header.id, as: 23)

            let tool = EmailReplyTool(context: ctx)
            _ = try await captureEditAndRequest(router: router, edit: { context, instruction in
                try await service.performInlineEdit(
                    currentSubject: "", currentBody: "", context: context,
                    instruction: instruction, chatHistory: []
                )
            }) {
                try await tool.execute(arguments: [
                    "unique_id": .int(23),
                    "request": .string("Say Friday works"),
                ])
            }

            let calls = backend.recordedCalls()
            #expect(calls.count == 1)
            guard calls.count == 1 else { return }
            let json = calls[0].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let vars = (json["messages"] as? [[String: Any]])?.first ?? [:]
            let userName = vars["user_name"] as? String
            #expect(userName == Self.work.name)
        }
    }

    @Test("email_compose: the new email's card opens with the account the body is signed as", arguments: [homeAccountId, workAccountId])
    func newEmailOpensWithTheAccountItIsSignedAs(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: primaryId)
            let primary = primaryId == Self.home.id ? Self.home : Self.work

            let tool = EmailComposeTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "request": .string("Ask about moving the offsite to Friday"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            let account = captured.card?.account
            #expect(account?.id == primary.id)
            #expect(captured.contexts[0].senderName == primary.name)
            #expect(captured.contexts[0].senderEmail == primary.email)
            #expect(captured.contexts[0].senderName == account?.displayName)
            #expect(captured.contexts[0].senderEmail == account?.emailAddress)
        }
    }

    @Test("email_compose: with no writing request the card still opens with the sending account")
    func newEmailWithoutRequestCarriesTheSendingAccount() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.work.id)
            let tool = EmailComposeTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "body": .string("See you Friday."),
                ])
            }
            #expect(captured.contexts.isEmpty)
            #expect(captured.card?.account?.id == Self.work.id)
        }
    }

    /// The account is read once: a primary account change while the AI is writing does not
    /// move the card away from the account the body was signed as.
    @Test("email_compose: a primary change during the edit keeps the card on the account the body is signed as")
    func newEmailKeepsItsAccountWhenThePrimaryChangesDuringTheEdit() async throws {
        try await withDemoMode(false) {
            let (ctx, db, _, router) = try makeContext(primaryId: Self.home.id)
            let tool = EmailComposeTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router, edit: { _, _ in
                try await db.write { db in
                    try db.execute(sql: "UPDATE account SET isPrimary = (id = ?)", arguments: [workAccountId])
                }
                return Self.cannedEdit()
            }) {
                try await tool.execute(arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "request": .string("Ask about moving the offsite to Friday"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.home.name)
            #expect(captured.card?.account?.id == Self.home.id)
        }
    }

    /// Demo boundary (ADR-IOS-038): the demo account and a real primary are both primary while
    /// they coexist. In demo the new email is signed as, and opens with, the demo account; out
    /// of demo, the real primary.
    @Test("email_compose: in demo the new email is the demo account's, out of demo the real primary's", arguments: [true, false])
    func newEmailFollowsTheDemoBoundary(demoActive: Bool) async throws {
        try await withDemoMode(demoActive) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id, withDemoRow: true)
            let expected = demoActive ? Self.demo : Self.home

            let tool = EmailComposeTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "request": .string("Ask about moving the offsite to Friday"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == expected.name)
            #expect(captured.card?.account?.id == expected.id)
        }
    }

    /// With no active real primary account, the new email uses an active real account: never
    /// the demo row (which is primary), never an account that is not active, and never a
    /// primary account that is not active. Home (inactive) and the demo row come before work.
    @Test("email_compose: with no active real primary the new email uses the active real account", arguments: [nil, homeAccountId])
    func newEmailWithoutActivePrimaryUsesTheActiveRealAccount(primaryId: String?) async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: primaryId, inactive: [Self.home.id], withDemoRow: true)
            let tool = EmailComposeTool(context: ctx)
            let captured = try await captureEditAndRequest(router: router) {
                try await tool.execute(arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "request": .string("Ask about moving the offsite to Friday"),
                ])
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.card?.account?.id == Self.work.id)
        }
    }
}

/// Every view that presents an assistant compose request opens the card with the account the
/// body was signed as: a new email with the request's account, and a reply or forward with no
/// account of the view's own, so the card sends from the replied or forwarded email's account
/// (`ComposeView` prefers a passed account over `replyTo`'s). Both views observe the request,
/// and either can present it.
@Suite("Assistant compose card account wiring")
struct AssistantComposeCardAccountWiringTests {

    /// Every app-target `composeViewForAgentRequest` body, with comments and string contents
    /// masked (a commented-out argument must not satisfy the fence) and whitespace collapsed.
    private static func hostBodies() throws -> [String] {
        try DiagnosticPrintGateTests.appTargetSources().flatMap { file -> [String] in
            DiagnosticPrintGateTests.codeOnly(file.source)
                .components(separatedBy: "func composeViewForAgentRequest(_ req: AgentToolRouter.ComposeRequest)")
                .dropFirst()
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
    }

    /// The text of `body` between the first `start` and the next `end` after it.
    private static func section(of body: String, from start: String, to end: String) throws -> String {
        let open = try #require(body.range(of: start))
        let close = try #require(body.range(of: end, range: open.upperBound..<body.endIndex))
        return String(body[open.upperBound..<close.lowerBound])
    }

    @Test("A new email's card opens with the request's account; a reply's and a forward's with the email's own")
    func cardsOpenWithTheSignedAccount() throws {
        let bodies = try Self.hostBodies()
        #expect(bodies.count == 2, "expected the inbox and message-detail hosts, found \(bodies.count)")
        for body in bodies {
            let compose = try Self.section(of: body, from: "case .compose:", to: "case .reply:")
            let reply = try Self.section(of: body, from: "case .reply:", to: "case .forward:")
            let forward = try Self.section(of: body, from: "case .forward:", to: "}")

            #expect(compose.contains("account: req.account,"))
            let composeAccountArguments = compose.components(separatedBy: "account:").count - 1
            #expect(composeAccountArguments == 1, "a new email: one account argument")

            for parentCase in [reply, forward] {
                #expect(parentCase.contains("replyTo: req.replyTo,"))
                let accountArguments = parentCase.components(separatedBy: "account:").count - 1
                #expect(accountArguments == 0, "a reply or forward: no account argument")
            }
        }
    }
}
