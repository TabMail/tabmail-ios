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
/// the account of the email open where the user asked (an email screen's chat), and from the
/// primary account in the inbox (the demo account in demo, either way); its compose card opens
/// with exactly the account the body was signed as.
///
/// Every test asks from a classic entry point with the chat view setting OFF: the inbox's own chat
/// (`ComposeOrigin.Screen.inbox`, no account bound) or an email screen's chat
/// (`ComposeOrigin.Screen.email`, bound to the open email's account, as `MessageDetailView` binds
/// it), and takes the card the way that screen's pill does (`AgentToolRouter.takeCompose(for:)`).
/// The card's account is the request's `fromAccountId`, which both screens look up as they open
/// the card (`AssistantComposeCardAccountWiringTests`).
///
/// The backend call is each tool's `composeEdit:` init, which receives the exact
/// `ComposeEditContext` the tool built; one test sends that context through a real `AIService`
/// request to read the name the backend receives.
///
/// `.processGlobalState`: the tools read the process-wide demo mode, which each test pins, the
/// chat view setting, which each test pins off, and the request test reads the App Group AI
/// opt-out flag, which it pins off and restores.
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

    /// The inbox's own chat: a turn there binds no account.
    private static let inbox = ComposeTestOrigin.invocation
    /// The chat key of the email screen the tests ask on.
    private static let screenKey = "sender-account-email-screen"
    /// The email screen's pill, which takes the cards its chat asked for.
    private static let emailHost = AgentToolRouter.ComposeHost(screen: .email, sessionKeys: [screenKey])

    /// A turn of the email screen's chat whose open email is in `openAccountId`: the account
    /// `MessageDetailView` binds (`composeFromAccountId`), carried by the turn's compose origin.
    private static func emailScreen(_ openAccountId: String) -> ToolInvocation {
        ToolInvocation(composeOrigin: ComposeOrigin(sessionKey: screenKey, screen: .email, fromAccountId: openAccountId))
    }

    /// A database with the home and work accounts and an Inbox for each. `primaryId` is the
    /// primary account (nil: none is), `inactive` the accounts that are not active,
    /// `calendarOnly` the accounts set up for calendar only, `oldestId` an account created
    /// before the others, and `withDemoRow` adds the demo account as the app seeds it (active and
    /// primary) with its own Inbox.
    ///
    /// Rows are inserted demo first, then home, then work, and created in that order unless
    /// `oldestId` says otherwise. A lookup without an order reads rows in insertion (and id)
    /// order, so a row a filter must skip comes BEFORE the expected one, and a lookup without
    /// that filter returns the wrong account.
    private func makeContext(
        primaryId: String?,
        inactive: Set<String> = [],
        calendarOnly: Set<String> = [],
        oldestId: String? = nil,
        withDemoRow: Bool = false
    ) throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        let db = try TestDatabase.make()
        let now = Date()
        if withDemoRow {
            var account = Account(emailAddress: Self.demo.email, displayName: Self.demo.name, provider: .imap)
            account.id = Self.demo.id
            account.isActive = true
            account.isPrimary = true
            account.createdAt = now.addingTimeInterval(-3 * 86_400)
            try db.write { try account.insert($0) }
            try TestDatabase.insertFolder(db, accountId: Self.demo.id)
        }
        for (index, seed) in [Self.home, Self.work].enumerated() {
            var account = Account(emailAddress: seed.email, displayName: seed.name, provider: .gmail)
            account.id = seed.id
            account.isPrimary = seed.id == primaryId
            account.isActive = !inactive.contains(seed.id)
            account.calendarOnly = calendarOnly.contains(seed.id)
            account.createdAt = seed.id == oldestId
                ? now.addingTimeInterval(-10 * 86_400)
                : now.addingTimeInterval(Double(index - 2) * 86_400)
            try db.write { try account.insert($0) }
            try TestDatabase.insertFolder(db, accountId: seed.id)
        }
        let translator = MockChatIdTranslator()
        let router = AgentToolRouter()
        return (ToolContext(db: db, translator: translator, router: router), db, translator, router)
    }

    /// Runs `body` with demo mode set to `active` and the chat view setting off (the classic
    /// screens), and puts both back after.
    private func withDemoMode(_ active: Bool, _ body: () async throws -> Void) async throws {
        let prior = DemoModeStore.shared.isActive
        let priorChatView = UserDefaults.standard.object(forKey: ChatViewConfig.enabledKey)
        DemoModeStore.shared.isActive = active
        UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
        defer {
            DemoModeStore.shared.isActive = prior
            UserDefaults.standard.set(priorChatView, forKey: ChatViewConfig.enabledKey)
        }
        #expect(!ChatViewConfig.isActive, "control: the chat view setting is off")
        try await body()
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

    /// The card `host`'s pill takes, polled for a bounded time.
    private func waitForPendingCompose(
        on router: AgentToolRouter, host: AgentToolRouter.ComposeHost, timeout seconds: Double = 5.0
    ) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let req = router.takeCompose(for: host) { return req }
            await Task.yield()
        }
        return router.takeCompose(for: host)
    }

    /// What the compose card was opened with: the account a new email is sent from (the screen
    /// opens the card from it) and the account of the email it replies to or forwards.
    private struct Card: Sendable {
        let fromAccountId: String?
        let replyToAccountId: String?
    }

    nonisolated private static func cannedEdit() -> InlineEditResult {
        InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil,
                         textMessage: nil, changeCommand: nil, raw: "")
    }

    /// Runs the tool `run` builds with the capturing edit call (`run` passes `composeEdit` to the
    /// tool's init), closes the compose card it opens on `host`, and returns every edit context
    /// the tool built and what the card was opened with. `edit` answers the edit call (default:
    /// a fixed result).
    private func captureEditAndRequest(
        router: AgentToolRouter,
        host: AgentToolRouter.ComposeHost = ComposeTestOrigin.inboxHost,
        edit: EmailReplyTool.ComposeEdit? = nil,
        run: @escaping @MainActor (_ composeEdit: @escaping EmailReplyTool.ComposeEdit) async throws -> String
    ) async throws -> (contexts: [ComposeEditContext], card: Card?) {
        var taken: Card?
        let box = ContextBox()
        let composeEdit: EmailReplyTool.ComposeEdit = { ctx, subject, body, request in
            await box.append(ctx)
            if let edit { return try await edit(ctx, subject, body, request) }
            return Self.cannedEdit()
        }
        let task = Task { @MainActor () -> String in try await run(composeEdit) }
        guard let req = await waitForPendingCompose(on: router, host: host) else {
            Issue.record("Tool did not open a compose card")
            task.cancel()
            _ = try? await task.value
            return (await box.contexts, nil)
        }
        taken = Card(fromAccountId: req.fromAccountId, replyToAccountId: req.replyTo?.accountId)
        req.onOutcome(.cancelled)
        _ = try await task.value
        return (await box.contexts, taken)
    }

    @Test("email_reply: a reply to the work account's email is signed as the work account, primary or not", arguments: [homeAccountId, workAccountId])
    func replySignsAsTheRepliedEmailsAccount(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, db, translator, router) = try makeContext(primaryId: primaryId)
            let header = try insertWorkEmail(db, messageId: "rep-work")
            await translator.seed(header.id, as: 21)

            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                    "unique_id": .int(21),
                    "request": .string("Say Friday works"),
                ], invocation: Self.inbox)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].mode == "edit_reply")
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.contexts[0].senderEmail == Self.work.email)
            // The card sends from the replied email's account, and takes no account of its own.
            #expect(captured.card?.replyToAccountId == Self.work.id)
            #expect(captured.card?.fromAccountId == nil)
        }
    }

    @Test("email_forward: a forward of the work account's email is signed as the work account, primary or not", arguments: [homeAccountId, workAccountId])
    func forwardSignsAsTheForwardedEmailsAccount(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, db, translator, router) = try makeContext(primaryId: primaryId)
            let header = try insertWorkEmail(db, messageId: "fwd-work")
            await translator.seed(header.id, as: 22)

            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await EmailForwardTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                    "unique_id": .int(22),
                    "to": .array([.string("pat@example.com")]),
                    "request": .string("Let them know Friday works"),
                ], invocation: Self.inbox)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].mode == "edit_forward")
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.contexts[0].senderEmail == Self.work.email)
            // The card sends from the forwarded email's account, and takes no account of its own.
            #expect(captured.card?.replyToAccountId == Self.work.id)
            #expect(captured.card?.fromAccountId == nil)
        }
    }

    /// A compose edit answer as the backend streams it at the JSON protocol: the final event
    /// whose `assistant` is the edit object (`AIService.parseInlineEditResponse`).
    nonisolated private static func streamedEditAnswer() -> Data {
        let edit: [String: Any] = [
            "response": "", "add_to": [], "remove_to": [], "add_cc": [], "remove_cc": [], "add_bcc": [], "remove_bcc": [],
            "subject": "Offsite", "body": "Friday works.", "text_message": "Friday works.", "change_command": "",
        ]
        let editText = (try? JSONSerialization.data(withJSONObject: edit)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let final = (try? JSONSerialization.data(withJSONObject: ["assistant": editText])) ?? Data()
        return Data(("event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n").utf8)
    }

    /// The name reaches the backend: each writing tool's edit goes through a real `AIService`
    /// request, whose `user_name` is the name the AI signs with. The work account is not the
    /// primary; the reply and forward are of its email, and every request is asked on its email's
    /// screen.
    @Test("email_reply, email_forward, email_compose: the backend request signs as the work account's name, not the primary's",
          arguments: ["email_reply", "email_forward", "email_compose"])
    func writingRequestCarriesTheSendingAccountsName(toolName: String) async throws {
        let restoreAISetting = AITestSetting.save()
        defer { restoreAISetting() }
        AITestSetting.set(aiOff: false)
        try await withDemoMode(false) {
            let backend = FakeHTTP.Scenario()
            backend.register(path: "/completions/chat", method: "POST") { _ in
                .bytes(Self.streamedEditAnswer(), contentType: "text/event-stream")
            }
            let service = AIService(backendClient: BackendClient(llmSession: backend.session))
            let (ctx, db, translator, router) = try makeContext(primaryId: Self.home.id)
            let header = try insertWorkEmail(db, messageId: "wire-\(toolName)")
            await translator.seed(header.id, as: 23)
            let arguments: [String: JSONValue] = toolName == "email_compose"
                ? ["to": .array([.string(Self.correspondent)]), "request": .string("Say Friday works")]
                : ["unique_id": .int(23), "to": .array([.string("pat@example.com")]), "request": .string("Say Friday works")]

            _ = try await captureEditAndRequest(router: router, host: Self.emailHost, edit: { context, subject, body, request in
                try await service.performInlineEdit(
                    currentSubject: subject, currentBody: body, context: context,
                    instruction: request, chatHistory: []
                )
            }) { composeEdit in
                let registry = ToolRegistry()
                await registry.register(EmailReplyTool(context: ctx, composeEdit: composeEdit))
                await registry.register(EmailForwardTool(context: ctx, composeEdit: composeEdit))
                await registry.register(EmailComposeTool(context: ctx, composeEdit: composeEdit))
                return await registry.execute(
                    name: toolName, arguments: arguments, invocation: Self.emailScreen(workAccountId)
                ).output
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

    /// Runs `email_compose` from the inbox's chat with a writing request (or `arguments`).
    private static func composeInTheInbox(
        _ ctx: ToolContext, composeEdit: @escaping EmailReplyTool.ComposeEdit, arguments: [String: JSONValue]? = nil
    ) async throws -> String {
        try await EmailComposeTool(context: ctx, composeEdit: composeEdit).execute(arguments: arguments ?? [
            "to": .array([.string(correspondent)]),
            "request": .string("Ask about moving the offsite to Friday"),
        ], invocation: inbox)
    }

    @Test("email_compose: the new email's card opens with the account the body is signed as", arguments: [homeAccountId, workAccountId])
    func newEmailOpensWithTheAccountItIsSignedAs(primaryId: String) async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: primaryId)
            let primary = primaryId == Self.home.id ? Self.home : Self.work

            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.card?.fromAccountId == primary.id)
            #expect(captured.contexts[0].senderName == primary.name)
            #expect(captured.contexts[0].senderEmail == primary.email)
        }
    }

    @Test("email_compose: with no writing request the card still opens with the sending account")
    func newEmailWithoutRequestCarriesTheSendingAccount() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.work.id)
            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit, arguments: [
                    "to": .array([.string(Self.correspondent)]),
                    "body": .string("See you Friday."),
                ])
            }
            #expect(captured.contexts.isEmpty)
            #expect(captured.card?.fromAccountId == Self.work.id)
        }
    }

    /// The account is read once: a primary account change while the AI is writing does not
    /// move the card away from the account the body was signed as.
    @Test("email_compose: a primary change during the edit keeps the card on the account the body is signed as")
    func newEmailKeepsItsAccountWhenThePrimaryChangesDuringTheEdit() async throws {
        try await withDemoMode(false) {
            let (ctx, db, _, router) = try makeContext(primaryId: Self.home.id)
            let captured = try await captureEditAndRequest(router: router, edit: { _, _, _, _ in
                try await db.write { db in
                    try db.execute(sql: "UPDATE account SET isPrimary = (id = ?)", arguments: [workAccountId])
                }
                return Self.cannedEdit()
            }) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.home.name)
            #expect(captured.card?.fromAccountId == Self.home.id)
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

            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == expected.name)
            #expect(captured.card?.fromAccountId == expected.id)
        }
    }

    /// With no active real primary account, the new email uses an active real account: never
    /// the demo row (which is primary), never an account that is not active, and never a
    /// primary account that is not active. Home (inactive) and the demo row come before work.
    @Test("email_compose: with no active real primary the new email uses the active real account", arguments: [nil, homeAccountId])
    func newEmailWithoutActivePrimaryUsesTheActiveRealAccount(primaryId: String?) async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: primaryId, inactive: [Self.home.id], withDemoRow: true)
            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.card?.fromAccountId == Self.work.id)
        }
    }

    /// A calendar-only account has no mail to send with, so a new email never goes from it,
    /// even when it is the primary account (removing the primary can make the oldest account
    /// primary, calendar-only or not): it goes from the mail account.
    @Test("email_compose: a calendar-only primary account is never the new email's account")
    func newEmailNeverUsesACalendarOnlyAccount() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id, calendarOnly: [Self.home.id])
            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.card?.fromAccountId == Self.work.id)
        }
    }

    /// With no primary account, the new email goes from the oldest account, as the inbox's
    /// compose does. Work is the oldest, though home comes first by insertion and by id.
    @Test("email_compose: with no primary account the new email is the oldest account's")
    func newEmailWithoutPrimaryUsesTheOldestAccount() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: nil, oldestId: Self.work.id)
            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.work.name)
            #expect(captured.card?.fromAccountId == Self.work.id)
        }
    }

    /// Demo boundary (ADR-IOS-038): in demo with no demo account, a new email is never signed as,
    /// or opened with, a real account.
    @Test("email_compose: in demo without the demo account the new email never takes a real account")
    func newEmailInDemoWithoutTheDemoAccountTakesNoRealAccount() async throws {
        try await withDemoMode(true) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id)
            let captured = try await captureEditAndRequest(router: router) { composeEdit in
                try await Self.composeInTheInbox(ctx, composeEdit: composeEdit)
            }
            let realNames: Set<String> = [Self.home.name, Self.work.name]
            let realEmails: Set<String> = [Self.home.email, Self.work.email]
            let realIds: Set<String> = [Self.home.id, Self.work.id]
            for context in captured.contexts {
                #expect(!realNames.contains(context.senderName))
                #expect(!realEmails.contains(context.senderEmail))
            }
            #expect(captured.card != nil, "control: the card opened")
            let cardAccountId = captured.card?.fromAccountId ?? ""
            #expect(!realIds.contains(cardAccountId))
        }
    }

    /// Runs `email_compose` the way a chat turn on an email's screen does: through a tool
    /// registry, with that screen's invocation. `arguments` default to a new email with a
    /// writing request.
    private static func composeThroughRegistry(
        _ ctx: ToolContext,
        composeEdit: @escaping EmailReplyTool.ComposeEdit,
        invocation: ToolInvocation,
        arguments: [String: JSONValue]? = nil
    ) async -> String {
        let registry = ToolRegistry()
        await registry.register(EmailComposeTool(context: ctx, composeEdit: composeEdit))
        let defaultArguments: [String: JSONValue] = [
            "to": .array([.string(correspondent)]),
            "request": .string("Ask about moving the offsite to Friday"),
        ]
        return await registry.execute(
            name: "email_compose", arguments: arguments ?? defaultArguments, invocation: invocation
        ).output
    }

    /// On an email's screen, a new email with the body already written (no writing request) also
    /// opens with the open email's account.
    @Test("email_compose: on an email's screen, a new email with a given body opens with the open email's account")
    func newEmailWithBodyOnAnEmailsScreenIsTheOpenEmailsAccount() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id)
            let captured = try await captureEditAndRequest(router: router, host: Self.emailHost) { composeEdit in
                await Self.composeThroughRegistry(
                    ctx, composeEdit: composeEdit, invocation: Self.emailScreen(workAccountId),
                    arguments: [
                        "to": .array([.string(Self.correspondent)]),
                        "body": .string("See you Friday."),
                    ])
            }
            #expect(captured.contexts.isEmpty)
            #expect(captured.card?.fromAccountId == Self.work.id)
        }
    }

    /// A reply or forward asked on another account's email screen is still sent from, and
    /// signed as, the replied or forwarded email's account: the open email's account is only for
    /// a new email. In demo, an email of the demo account is the demo account's, though a real
    /// primary coexists.
    @Test("email_reply and email_forward: asked on another account's screen, signed as the email's own account",
          arguments: ["email_reply", "email_forward"], [false, true])
    func replyAndForwardOnAnotherScreenSignAsTheEmailsAccount(toolName: String, demoActive: Bool) async throws {
        try await withDemoMode(demoActive) {
            let (ctx, db, translator, router) = try makeContext(primaryId: Self.home.id, withDemoRow: demoActive)
            let source = demoActive ? Self.demo : Self.work
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "screen-\(toolName)", subject: "Offsite",
                from: Self.correspondent, fromAddress: Self.correspondent, to: Self.workAlias,
                folderId: "\(source.id):INBOX", accountId: source.id
            )
            await translator.seed(header.id, as: 31)

            let captured = try await captureEditAndRequest(router: router, host: Self.emailHost) { composeEdit in
                let registry = ToolRegistry()
                await registry.register(EmailReplyTool(context: ctx, composeEdit: composeEdit))
                await registry.register(EmailForwardTool(context: ctx, composeEdit: composeEdit))
                return await registry.execute(
                    name: toolName,
                    arguments: [
                        "unique_id": .int(31),
                        "to": .array([.string("pat@example.com")]),
                        "request": .string("Say Friday works"),
                    ],
                    invocation: Self.emailScreen(homeAccountId)
                ).output
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == source.name)
            #expect(captured.contexts[0].senderEmail == source.email)
            #expect(captured.card?.replyToAccountId == source.id)
            #expect(captured.card?.fromAccountId == nil, "the screen's account is never a reply's or a forward's")
        }
    }

    /// Asked on an email's screen, a new email is sent from, and signed as, that email's
    /// account, whichever account is primary.
    @Test("email_compose: asked on an email's screen, the new email is the open email's account, not the primary's", arguments: [homeAccountId, workAccountId])
    func newEmailOnAnEmailsScreenIsTheOpenEmailsAccount(openId: String) async throws {
        try await withDemoMode(false) {
            let otherId = openId == Self.home.id ? Self.work.id : Self.home.id
            let (ctx, _, _, router) = try makeContext(primaryId: otherId)
            let open = openId == Self.home.id ? Self.home : Self.work

            let captured = try await captureEditAndRequest(router: router, host: Self.emailHost) { composeEdit in
                await Self.composeThroughRegistry(ctx, composeEdit: composeEdit, invocation: Self.emailScreen(openId))
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == open.name)
            #expect(captured.contexts[0].senderEmail == open.email)
            #expect(captured.card?.fromAccountId == open.id)
        }
    }

    /// Demo boundary (ADR-IOS-038) on an email's screen: in demo the new email is the demo
    /// account's even when the open email is a real account's; out of demo an email of the demo
    /// row never sends from it, and the new email is the real primary's.
    @Test("email_compose: on an email's screen the new email keeps the demo boundary", arguments: [true, false])
    func newEmailOnAnEmailsScreenKeepsTheDemoBoundary(demoActive: Bool) async throws {
        try await withDemoMode(demoActive) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id, withDemoRow: true)
            let openId = demoActive ? Self.work.id : Self.demo.id
            let expected = demoActive ? Self.demo : Self.home

            let captured = try await captureEditAndRequest(router: router, host: Self.emailHost) { composeEdit in
                await Self.composeThroughRegistry(ctx, composeEdit: composeEdit, invocation: Self.emailScreen(openId))
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == expected.name)
            #expect(captured.card?.fromAccountId == expected.id)
        }
    }

    /// An email whose account is no longer active does not send from that account: the new
    /// email is the primary's, as in the inbox.
    @Test("email_compose: on the screen of an email whose account is not active, the new email is the primary's")
    func newEmailOnAnInactiveAccountsEmailIsThePrimarys() async throws {
        try await withDemoMode(false) {
            let (ctx, _, _, router) = try makeContext(primaryId: Self.home.id, inactive: [Self.work.id])

            let captured = try await captureEditAndRequest(router: router, host: Self.emailHost) { composeEdit in
                await Self.composeThroughRegistry(ctx, composeEdit: composeEdit, invocation: Self.emailScreen(workAccountId))
            }
            #expect(captured.contexts.count == 1)
            guard captured.contexts.count == 1 else { return }
            #expect(captured.contexts[0].senderName == Self.home.name)
            #expect(captured.card?.fromAccountId == Self.home.id)
        }
    }
}

/// The chat gives its compose tools the account of the email it is about: each turn of a pill
/// carries a compose origin (`ComposeOrigin`), built in one place from the account its host binds
/// (`composeFromAccountId`: the email screen's highlighted email's account, else its own email's;
/// nil in the inbox and in the compose editor, whose pill opens no card). `email_compose` reads
/// that account and puts the account it signs the body as on the request it queues.
@Suite("Assistant chat binds the open email's account to its turns")
struct AssistantChatOpenEmailAccountWiringTests {

    /// The argument list of each call that starts with `start` in `code`, up to and including its
    /// closing parenthesis.
    private static func argumentLists(of start: String, in code: String) -> [String] {
        var lists: [String] = []
        var searchFrom = code.startIndex
        while let open = code.range(of: start, range: searchFrom..<code.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" { depth -= 1 }
                index = code.index(after: index)
            }
            lists.append(String(code[open.upperBound..<index]))
            searchFrom = index
        }
        return lists
    }

    /// Every app-target source by file name, comments and string contents masked and whitespace
    /// collapsed.
    private static func appCode() throws -> [(name: String, code: String)] {
        try DiagnosticPrintGateTests.appTargetSources().map { file in
            ((file.relativePath as NSString).lastPathComponent,
             DiagnosticPrintGateTests.codeOnly(file.source).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
    }

    /// The code of the one app-target file called `name`.
    private static func code(of name: String, in code: [(name: String, code: String)]) -> String {
        let matches = code.filter { $0.name == name }
        #expect(matches.count == 1, "\(name): \(matches.count) files")
        return matches.count == 1 ? matches[0].code : ""
    }

    @Test("Every compose origin carries the host's bound account, and the new email's request the account it is signed as")
    func everyComposeOriginCarriesTheBoundAccount() throws {
        let code = try Self.appCode()
        var constructions: [String: [String]] = [:]
        for (name, text) in code {
            let lists = Self.argumentLists(of: "ComposeOrigin(", in: text)
            if !lists.isEmpty { constructions[name, default: []] += lists }
        }
        #expect(Set(constructions.keys) == ["DynamicIslandChatButton.swift", "EmailComposeTool.swift"],
                "compose origin builders: \(constructions.keys.sorted())")
        // The pill's one builder: the host's account, read as the turn starts.
        let pill = constructions["DynamicIslandChatButton.swift"] ?? []
        #expect(pill.count == 1)
        for arguments in pill {
            #expect(arguments.hasSuffix("fromAccountId: composeFromAccountId)"))
        }
        // The new email's request: the turn's chat and screen, with the account the tool signed the
        // body as, which it read from the turn's bound account first.
        let tool = constructions["EmailComposeTool.swift"] ?? []
        #expect(tool.count == 1)
        for arguments in tool {
            #expect(arguments == "sessionKey: origin.sessionKey, screen: origin.screen, fromAccountId: account?.id)")
        }
        let toolCode = Self.code(of: "EmailComposeTool.swift", in: code)
        #expect(toolCode.contains("let account = await Self.sendingAccount(openEmailAccountId: origin.fromAccountId, db: ctx.db)"))
        #expect(toolCode.contains("sender: account,"), "the body is signed as that account")
        // The compose editor's pill and a host that presents no card build no origin.
        let island = Self.code(of: "DynamicIslandChatButton.swift", in: code)
        #expect(island.contains("guard onAgentCompose != nil, composeContext == nil else { return nil }"))
    }

    /// The account comes from the screen: the email screen builds its chat pill with the email
    /// the chat is about (the highlighted one in a conversation, else the screen's email) and
    /// binds that email's account; the inbox's and the compose editor's pills are given neither.
    /// `message` is the chat's first initializer argument, so a construction passes it exactly
    /// when its arguments start with it. The chat view's hosts are pinned by `ChatReplyFieldTests`.
    @Test("The email screen's chat is given its email and binds that email's account; the inbox's and the compose editor's neither")
    func theEmailScreensChatBindsItsEmailsAccount() throws {
        var constructions: [String: [String]] = [:]
        for (name, text) in try Self.appCode() {
            let lists = Self.argumentLists(of: "DynamicIslandChat(", in: text)
            guard !lists.isEmpty else { continue }
            constructions[name, default: []] += lists.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        #expect(Set(constructions.keys) == ["MessageDetailView.swift", "InboxView.swift", "ComposeView.swift",
                                            "ChatThreadView.swift", "ChatNewThreadView.swift", "KeyboardFocusTestScene.swift"],
                "chat pill hosts: \(constructions.keys.sorted())")
        let detail = constructions["MessageDetailView.swift"] ?? []
        #expect(detail.count == 1)
        for arguments in detail {
            #expect(arguments.hasPrefix("message: chatContextMessage ?? message,"))
            #expect(arguments.contains("composeFromAccountId: (chatContextMessage ?? message).accountId,"))
        }
        for host in ["InboxView.swift", "ComposeView.swift", "KeyboardFocusTestScene.swift"] {
            for arguments in constructions[host] ?? [] {
                #expect(!arguments.hasPrefix("message:"), "\(host) gives its chat an email")
                #expect(!arguments.contains("composeFromAccountId:"), "\(host) binds an account")
            }
        }
    }

    /// The chat's turns carry that origin: a fresh turn, a resumed turn and the chat view's field
    /// compose each pass an invocation with the turn's origin to the completion call, which would
    /// otherwise run the compose tools with no screen (`invocation` defaults to `.noninteractive`,
    /// and a compose tool with no origin fails fast). The compose editor's inline edit passes the
    /// session's card channel only: its pill opens no compose card.
    @Test("Every chat completion call passes an invocation with the turn's compose origin")
    func everyChatCompletionCallPassesTheTurnsOrigin() throws {
        let sources = try Self.appCode()
        let code = Self.code(of: "DynamicIslandChatButton.swift", in: sources)
        #expect(!code.isEmpty)

        // The local invocation bindings: the field compose's and the fresh turn's.
        let bindings = code.components(separatedBy: "let invocation =").dropFirst()
        #expect(bindings.count == 2, "expected two local invocation bindings, found \(bindings.count)")
        for binding in bindings {
            let arguments = Self.argumentLists(of: "ToolInvocation(", in: String(binding)).first ?? ""
            #expect(binding.hasPrefix(" ToolInvocation("))
            #expect(arguments.contains("composeOrigin: origin"), "an invocation without the turn's origin: \(arguments.prefix(120))")
        }

        for call in ["ChatPillState.shared.aiService.sendChatMessage(", "ChatPillState.shared.aiService.resumeChatMessage(",
                     "TutorialChatScript.response("] {
            let lists = Self.argumentLists(of: call, in: code)
            #expect(lists.count == 1, "expected one \(call) call, found \(lists.count)")
            for arguments in lists {
                #expect(arguments.contains("invocation: invocation")
                        || arguments.contains("invocation: ToolInvocation( uiSink: SessionUISink(session: session), sessionKey: sessionKey, composeOrigin: origin)"),
                        "\(call) does not pass the turn's invocation")
            }
        }
        let edits = Self.argumentLists(of: "ChatPillState.shared.aiService.performInlineEdit(", in: code)
        #expect(edits.count == 1)
        for arguments in edits {
            #expect(arguments.contains("invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey)"))
        }
    }
}

/// Every classic screen that presents an assistant compose card opens it with the account the
/// body was signed as: a new email from the request's account (`fromAccountId`), looked up in the
/// app's accounts after `canOpen` checked it is there, and a reply or forward with no account of
/// the screen's own, so the card sends from the replied or forwarded email's account
/// (`ComposeView` prefers a passed account over `replyTo`'s). Every screen opens the card through
/// one presenter (`AgentToolRouter.ComposeRequest.composeView(account:)`).
@Suite("Assistant compose card account wiring")
struct AssistantComposeCardAccountWiringTests {

    /// The one app-target source whose path ends in `suffix`, comments and string contents masked
    /// and whitespace collapsed.
    private static func code(_ suffix: String) throws -> String {
        let files = try DiagnosticPrintGateTests.appTargetSources().filter { $0.relativePath.hasSuffix(suffix) }
        #expect(files.count == 1, "\(suffix): \(files.count) files")
        guard files.count == 1 else { return "" }
        return DiagnosticPrintGateTests.codeOnly(files[0].source).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of `body` between the first `start` and the next `end` after it.
    private static func section(of body: String, from start: String, to end: String) throws -> String {
        let open = try #require(body.range(of: start))
        let close = try #require(body.range(of: end, range: open.upperBound..<body.endIndex))
        return String(body[open.upperBound..<close.lowerBound])
    }

    @Test("A new email's card opens with the request's account; a reply's and a forward's with the email's own")
    func cardsOpenWithTheSignedAccount() throws {
        let presenter = try Self.section(
            of: try Self.code("Views/Chat/ChatReplyField.swift"),
            from: "func composeView(account: Account?, openedOn: ComposeScreen? = nil, onOutcome: @escaping @MainActor (ComposeOutcome) -> Void) -> ComposeView {",
            to: "struct ChatReadyReply")
        let compose = try Self.section(of: presenter, from: "case .compose:", to: "case .reply:")
        let reply = try Self.section(of: presenter, from: "case .reply:", to: "case .forward:")
        let forward = try Self.section(of: presenter, from: "case .forward:", to: "} } }")

        #expect(compose.contains("account: account,"))
        #expect(compose.components(separatedBy: "account:").count - 1 == 1, "a new email: one account argument")
        for parentCase in [reply, forward] {
            #expect(parentCase.contains("replyTo: replyTo,"))
            #expect(parentCase.components(separatedBy: "account:").count - 1 == 0, "a reply or forward: no account argument")
        }

        // The inbox and the email screen open the card from the request's account, after `canOpen`.
        let inbox = try Self.code("Views/Inbox/InboxView.swift")
        #expect(inbox.components(separatedBy: ".composeView(account:").count - 1 == 1)
        #expect(inbox.contains("req.composeView(account: navigationStore.accounts.first { $0.id == req.fromAccountId }, onOutcome: req.onOutcome)"))
        #expect(inbox.contains("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } agentCompose = req"))
        let detail = try Self.code("Views/Message/MessageDetailView.swift")
        #expect(detail.components(separatedBy: ".composeView(account:").count - 1 == 1)
        #expect(detail.contains("req.composeView(account: fromAccount(of: req), onOutcome: req.onOutcome)"))
        let detailActions = try Self.code("Views/Message/MessageDetailView+Actions.swift")
        #expect(detailActions.contains("func fromAccount(of req: AgentToolRouter.ComposeRequest) -> Account? { navigationStore.accounts.first { $0.id == req.fromAccountId } }"))
        #expect(detailActions.contains("guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return } agentCompose = req"))
    }
}
