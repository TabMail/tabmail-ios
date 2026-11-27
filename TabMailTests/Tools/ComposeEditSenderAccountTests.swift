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
/// with that account's name and address even when it is not the primary account. A new email's
/// compose card opens with exactly the account the body was signed as.
///
/// The backend call is replaced per task through `EmailComposeTool.inlineEditOverride`, which
/// receives the exact `ComposeEditContext` the tool built for `performInlineEdit`.
@Suite("Compose edit signs as the sending account")
@MainActor
struct ComposeEditSenderAccountTests {

    private actor ContextBox {
        var contexts: [ComposeEditContext] = []
        func append(_ ctx: ComposeEditContext) { contexts.append(ctx) }
    }

    private static let home = (id: homeAccountId, email: "home@example.com", name: "Home Name")
    private static let work = (id: workAccountId, email: "work@example.com", name: "Work Name")
    private static let correspondent = "sam@example.com"

    /// A database with two active accounts, `primaryId` the primary one, and an Inbox for each.
    private func makeContext(primaryId: String) throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        for seed in [Self.home, Self.work] {
            var account = Account(emailAddress: seed.email, displayName: seed.name, provider: .gmail)
            account.id = seed.id
            account.isPrimary = seed.id == primaryId
            try db.write { try account.insert($0) }
            try TestDatabase.insertFolder(db, accountId: seed.id)
        }
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        return (ToolContext(db: db, translator: translator, router: router), db, translator, router)
    }

    /// An email from Sam to the work account, in the work account's Inbox.
    private func insertWorkEmail(_ db: DatabaseQueue, messageId: String) throws -> MessageHeader {
        try TestDatabase.insertMessageHeader(
            db, messageId: messageId, subject: "Offsite",
            from: Self.correspondent, fromAddress: Self.correspondent,
            to: Self.work.email,
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

    /// Runs `tool` with the backend edit call captured, closes the compose card it opens, and
    /// returns every edit context the tool built and what the card was opened with.
    private func captureEditAndRequest(
        router: AgentToolRouter,
        run: @escaping @MainActor () async throws -> String
    ) async throws -> (contexts: [ComposeEditContext], card: Card?) {
        var enqueued: Card?
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
            enqueued = Card(account: req.account, replyToAccountId: req.replyTo?.accountId)
            req.onOutcome(.cancelled)
            _ = try await task.value
        }
        return (await box.contexts, enqueued)
    }

    @Test("email_reply: a reply to the work account's email is signed as the work account, not the primary")
    func replySignsAsTheRepliedEmailsAccount() async throws {
        let (ctx, db, translator, router) = try makeContext(primaryId: Self.home.id)
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

    @Test("email_forward: a forward of the work account's email is signed as the work account, not the primary")
    func forwardSignsAsTheForwardedEmailsAccount() async throws {
        let (ctx, db, translator, router) = try makeContext(primaryId: Self.home.id)
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

    @Test("email_compose: the new email's card opens with the account the body is signed as", arguments: [homeAccountId, workAccountId])
    func newEmailOpensWithTheAccountItIsSignedAs(primaryId: String) async throws {
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

    @Test("email_compose: with no writing request the card still opens with the sending account")
    func newEmailWithoutRequestCarriesTheSendingAccount() async throws {
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

/// Every view that presents an assistant compose request opens a new email's card with the
/// request's account, the one the body was signed as, never an account of its own choosing
/// (both views observe the request, and either can present it).
@Suite("Assistant compose card account wiring")
struct AssistantComposeCardAccountWiringTests {

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        let raw = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The `.compose` case of `composeViewForAgentRequest` in `text`.
    private static func composeCase(in text: String) throws -> Substring {
        let function = try #require(text.range(of: "func composeViewForAgentRequest(_ req: AgentToolRouter.ComposeRequest)"))
        let open = try #require(text[function.upperBound...].range(of: "case .compose:"))
        let close = try #require(text[open.upperBound...].range(of: "case .reply:"))
        return text[open.upperBound..<close.lowerBound]
    }

    @Test("A new email's card opens with the request's account", arguments: [
        "TabMail/Views/Inbox/InboxView.swift",
        "TabMail/Views/Message/MessageDetailView+Actions.swift",
    ])
    func newEmailCardOpensWithTheRequestsAccount(path: String) throws {
        let compose = String(try Self.composeCase(in: Self.source(path)))
        #expect(compose.contains("account: req.account,"), "\(path)")
        let accountArguments = compose.components(separatedBy: "account:").count - 1
        #expect(accountArguments == 1, "\(path): one account argument")
    }
}
