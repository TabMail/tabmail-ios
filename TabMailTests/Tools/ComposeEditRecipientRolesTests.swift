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
/// And a reply or forward edit request describes one email: its header and its body text come from
/// the same email, read together.
///
/// The backend call is replaced per task through `EmailComposeTool.inlineEditOverride`, which
/// receives the exact `ComposeEditContext` the tool built for `performInlineEdit`.
@Suite("Compose edit keeps recipient roles", .processGlobalState)
@MainActor
struct ComposeEditRecipientRolesTests {

    private actor ContextBox {
        var contexts: [ComposeEditContext] = []
        func append(_ ctx: ComposeEditContext) { contexts.append(ctx) }
    }

    /// The SQL of every statement run on a test database once attached (`log(_:)`), recorded from
    /// the database's own thread.
    private final class StatementLog: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func append(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
        /// How many SELECT statements so far name `table`, in any letter case. Schema lookups the
        /// database layer runs on its own are PRAGMAs and are not counted.
        func reads(of table: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return texts.filter {
                let sql = $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return sql.hasPrefix("select") && sql.contains(table.lowercased())
            }.count
        }
    }

    private func log(_ db: DatabaseQueue) -> StatementLog {
        let log = StatementLog()
        db.inDatabase { db in db.trace { log.append($0.description) } }
        return log
    }

    private static let primary = "sam@example.com"
    private static let copied = "pat@example.com"
    private static let blind = "lee@example.com"

    /// Every test here starts in real (non-demo) mode, which the tool's demo boundary reads.
    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator, AgentToolRouter) {
        DemoModeStore.shared.isActive = false
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
        try await captureEditAndRequest(router: router, run: run).contexts
    }

    /// The edit contexts the tool built and the To/Cc/Bcc of the compose request it enqueued.
    private func captureEditAndRequest(
        router: AgentToolRouter,
        run: @escaping @MainActor () async throws -> String
    ) async throws -> (contexts: [ComposeEditContext], to: [String], cc: [String], bcc: [String]) {
        var enqueued: (to: [String], cc: [String], bcc: [String]) = ([], [], [])
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
            enqueued = (req.to, req.cc, req.bcc)
            req.onOutcome(.cancelled)
            _ = try await task.value
        }
        return (await box.contexts, enqueued.to, enqueued.cc, enqueued.bcc)
    }

    private static let named: [String: String] = [
        "sam@example.com": "Sam Lee",
        "pat@example.com": "Pat Kim",
        "lee@example.com": "Lee Park",
        "kim@example.com": "Kim Cho",
    ]

    private static func namedObject(_ address: String) -> JSONValue {
        .dictionary(["name": .string(named[address] ?? ""), "email": .string(address)])
    }

    /// The display names the compose card shows for one enqueued field, filled the way
    /// ComposeView fills a prefilled field.
    private static func cardNames(_ texts: [String]) -> [String: String] {
        ComposeDraftGuards.fieldState(RecipientEntry(texts)).displayNames
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

    @Test("email_compose: recipient display names reach the edit request with bare addresses")
    func composeKeepsDisplayNames() async throws {
        let (ctx, _, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)
        let contexts = try await captureEditContexts(router: router) {
            try await tool.execute(arguments: [
                "recipients": .array([.dictionary(["name": .string("Sam Lee"), "email": .string(Self.primary)])]),
                "cc": .array([.dictionary(["name": .string("Pat Kim"), "email": .string(Self.copied)])]),
                "request": .string("Ask about moving the offsite to Friday"),
            ])
        }
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].recipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.copied])
        #expect(contexts[0].toDisplayNames == [Self.primary: "Sam Lee"])
        #expect(contexts[0].ccDisplayNames == [Self.copied: "Pat Kim"])
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

    @Test("email_compose: named To, Cc and Bcc reach the compose card with their names")
    func composeRequestKeepsNames() async throws {
        let (ctx, _, _, router) = try makeContext()
        let tool = EmailComposeTool(context: ctx)
        let captured = try await captureEditAndRequest(router: router) {
            try await tool.execute(arguments: [
                "recipients": .array([Self.namedObject(Self.primary)]),
                "cc": .array([Self.namedObject(Self.copied)]),
                "bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Ask about moving the offsite to Friday"),
            ])
        }
        #expect(Self.cardNames(captured.to) == [Self.primary: "Sam Lee"])
        #expect(Self.cardNames(captured.cc) == [Self.copied: "Pat Kim"])
        #expect(Self.cardNames(captured.bcc) == [Self.blind: "Lee Park"])
    }

    @Test("email_forward: named To, Cc and Bcc keep their names in the edit request and on the card")
    func forwardKeepsNames() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "fwd2", subject: "Offsite")
        await translator.seed(header.id, as: 13)

        let tool = EmailForwardTool(context: ctx)
        let captured = try await captureEditAndRequest(router: router) {
            try await tool.execute(arguments: [
                "unique_id": .int(13),
                "to": .array([Self.namedObject(Self.primary)]),
                "cc": .array([Self.namedObject(Self.copied)]),
                "bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Let them know Friday works"),
            ])
        }
        let contexts = captured.contexts
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].mode == "edit_forward")
        #expect(contexts[0].toRecipients == [Self.primary])
        #expect(contexts[0].ccRecipients == [Self.copied])
        #expect(contexts[0].toDisplayNames == [Self.primary: "Sam Lee"])
        #expect(contexts[0].ccDisplayNames == [Self.copied: "Pat Kim"])
        #expect(Self.cardNames(captured.to) == [Self.primary: "Sam Lee"])
        #expect(Self.cardNames(captured.cc) == [Self.copied: "Pat Kim"])
        #expect(Self.cardNames(captured.bcc) == [Self.blind: "Lee Park"])
    }

    @Test("email_reply: named additions keep their names in the edit request and on the card")
    func replyKeepsAddedNames() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "rep2", subject: "Offsite",
            from: Self.primary, fromAddress: Self.primary,
            to: "test@example.com"
        )
        await translator.seed(header.id, as: 14)

        let tool = EmailReplyTool(context: ctx)
        let captured = try await captureEditAndRequest(router: router) {
            try await tool.execute(arguments: [
                "unique_id": .int(14),
                "add_recipients": .array([Self.namedObject(Self.newlyCopied)]),
                "add_cc": .array([Self.namedObject(Self.copied)]),
                "add_bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Say Friday works"),
            ])
        }
        let contexts = captured.contexts
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].mode == "edit_reply")
        #expect(contexts[0].toRecipients.contains(Self.newlyCopied))
        #expect(contexts[0].ccRecipients == [Self.copied])
        #expect(contexts[0].toDisplayNames[Self.newlyCopied] == "Kim Cho")
        #expect(contexts[0].ccDisplayNames == [Self.copied: "Pat Kim"])
        #expect(Self.cardNames(captured.to)[Self.newlyCopied] == "Kim Cho")
        #expect(Self.cardNames(captured.cc) == [Self.copied: "Pat Kim"])
        #expect(Self.cardNames(captured.bcc) == [Self.blind: "Lee Park"])
    }

    @Test("email_reply: adding the original sender by name keeps one To recipient")
    func replyAddingSenderByNameKeepsOneTo() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "rep3", subject: "Offsite",
            from: Self.primary, fromAddress: Self.primary,
            to: "test@example.com"
        )
        await translator.seed(header.id, as: 15)

        let tool = EmailReplyTool(context: ctx)
        let captured = try await captureEditAndRequest(router: router) {
            try await tool.execute(arguments: [
                "unique_id": .int(15),
                "add_recipients": .array([Self.namedObject(Self.primary)]),
                "request": .string("Say Friday works"),
            ])
        }
        #expect(captured.contexts.count == 1)
        guard captured.contexts.count == 1 else { return }
        #expect(captured.contexts[0].toRecipients == [Self.primary])
        #expect(ComposeDraftGuards.fieldState(RecipientEntry(captured.to)).tokens == [Self.primary])
    }

    // MARK: - The email a reply or forward edit request describes (#991)

    /// Runs the reply (or forward) tool with a content request on the email seeded as `numericId`.
    private func sourceEmailContexts(
        isForward: Bool, ctx: ToolContext, router: AgentToolRouter, numericId: Int
    ) async throws -> [ComposeEditContext] {
        var arguments: [String: JSONValue] = ["unique_id": .int(numericId), "request": .string("Say Friday works")]
        if isForward { arguments["to"] = .array([.string(Self.primary)]) }
        let finalArguments = arguments
        return try await captureEditContexts(router: router) {
            if isForward { return try await EmailForwardTool(context: ctx).execute(arguments: finalArguments) }
            return try await EmailReplyTool(context: ctx).execute(arguments: finalArguments)
        }
    }

    @Test("email_reply and email_forward: the edit request carries the email's own body with its own header")
    func replyAndForwardDescribeOneEmail() async throws {
        for isForward in [false, true] {
            let (ctx, db, translator, router) = try makeContext()
            try TestDatabase.insertAccount(db)
            try TestDatabase.insertFolder(db)
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "src1", subject: "Offsite", snippet: "Offsite snippet")
            try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Offsite body</p>")
            await translator.seed(header.id, as: 21)
            let statements = log(db)

            let contexts = try await sourceEmailContexts(isForward: isForward, ctx: ctx, router: router, numericId: 21)
            #expect(contexts.count == 1)
            guard contexts.count == 1 else { continue }
            #expect(contexts[0].relatedSubject == "Offsite")
            #expect(contexts[0].bodyText.contains("Offsite body"))
            #expect(!contexts[0].bodyText.contains("Offsite snippet"))
            // The body the request carries is the one read with the header; no other body read follows.
            let bodyReads = statements.reads(of: "messageBody")
            #expect(bodyReads == 1, "forward \(isForward): \(bodyReads) body reads")
        }
    }

    @Test("email_reply and email_forward: without a request the AI is not asked and no body is read")
    func replyAndForwardWithoutARequestAskNothing() async throws {
        for isForward in [false, true] {
            let (ctx, db, translator, router) = try makeContext()
            try TestDatabase.insertAccount(db)
            try TestDatabase.insertFolder(db)
            let header = try TestDatabase.insertMessageHeader(db, messageId: "src8", subject: "Offsite")
            try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Offsite body</p>")
            await translator.seed(header.id, as: 28)
            let statements = log(db)

            var arguments: [String: JSONValue] = ["unique_id": .int(28)]
            if isForward {
                // A forward needs a request or a body; without a request it opens with the body given.
                arguments["to"] = .array([.string(Self.primary)])
                arguments["body"] = .string("See below.")
            }
            let finalArguments = arguments
            let contexts = try await captureEditContexts(router: router) {
                if isForward { return try await EmailForwardTool(context: ctx).execute(arguments: finalArguments) }
                return try await EmailReplyTool(context: ctx).execute(arguments: finalArguments)
            }
            #expect(contexts.isEmpty, "forward \(isForward): the AI was asked without a request")
            let bodyReads = statements.reads(of: "messageBody")
            #expect(bodyReads == 0, "forward \(isForward): the body was read without a request")
        }
    }

    @Test("email_reply and email_forward: an email that is gone fails the tool without asking the AI or opening compose")
    func replyAndForwardOfAGoneEmailFail() async throws {
        for isForward in [false, true] {
            let (ctx, db, translator, router) = try makeContext()
            try TestDatabase.insertAccount(db)
            try TestDatabase.insertFolder(db)
            await translator.seed("acc1:INBOX:gone", as: 29)

            let box = ContextBox()
            let override: @Sendable (ComposeEditContext, String) async throws -> InlineEditResult = { edit, _ in
                await box.append(edit)
                return InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil, raw: "")
            }
            var arguments: [String: JSONValue] = ["unique_id": .int(29), "request": .string("Say Friday works")]
            if isForward { arguments["to"] = .array([.string(Self.primary)]) }
            let finalArguments = arguments
            let answer = try await EmailComposeTool.$inlineEditOverride.withValue(override) {
                if isForward { return try await EmailForwardTool(context: ctx).execute(arguments: finalArguments) }
                return try await EmailReplyTool(context: ctx).execute(arguments: finalArguments)
            }
            #expect(answer.contains("no longer exists"), "forward \(isForward): \(answer)")
            let asked = await box.contexts
            #expect(asked.isEmpty, "forward \(isForward): the AI was asked about an email that is gone")
            let noCard = router.pendingCompose == nil
            #expect(noCard, "forward \(isForward): a compose card opened for an email that is gone")
        }
    }

    @Test("email_reply and email_forward: with no stored body the edit request carries the email's own snippet")
    func replyAndForwardWithoutABodyUseTheSnippet() async throws {
        for isForward in [false, true] {
            let (ctx, db, translator, router) = try makeContext()
            try TestDatabase.insertAccount(db)
            try TestDatabase.insertFolder(db)
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "src2", subject: "Offsite", snippet: "Offsite snippet")
            await translator.seed(header.id, as: 22)

            let contexts = try await sourceEmailContexts(isForward: isForward, ctx: ctx, router: router, numericId: 22)
            #expect(contexts.count == 1)
            guard contexts.count == 1 else { continue }
            #expect(contexts[0].relatedSubject == "Offsite")
            #expect(contexts[0].bodyText == "Offsite snippet")
        }
    }

    @Test("relatedEmail reads the header and, only for a request, its body, in one read")
    func relatedEmailReadsTheHeaderAndBodyTogether() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "src3", subject: "Offsite")
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Offsite body</p>")

        let withBody = try db.read { db in
            try EmailComposeTool.relatedEmail(realId: header.id, withBodyText: true, db: db)
        }
        #expect(withBody?.header.id == header.id)
        #expect(withBody?.bodyText?.contains("Offsite body") == true)

        let statements = log(db)
        let headerOnly = try db.read { db in
            try EmailComposeTool.relatedEmail(realId: header.id, withBodyText: false, db: db)
        }
        #expect(headerOnly?.header.id == header.id)
        #expect(headerOnly?.bodyText == nil)
        let bodyReads = statements.reads(of: "messageBody")
        #expect(bodyReads == 0, "the body was read for a header-only request")

        let missing = try db.read { db in
            try EmailComposeTool.relatedEmail(realId: "absent", withBodyText: true, db: db)
        }
        let isMissing = missing == nil
        #expect(isMissing)
    }

    @Test("relatedEmail: a failed body read returns the email without its body")
    func relatedEmailSurvivesAFailedBodyRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "src4", subject: "Offsite")
        try db.write { db in try db.execute(sql: "DROP TABLE messageBody") }

        let read = try db.read { db in
            try EmailComposeTool.relatedEmail(realId: header.id, withBodyText: true, db: db)
        }
        #expect(read?.header.id == header.id)
        #expect(read?.bodyText == nil)
    }

    @Test("email_reply and email_forward: a failed body read still sends the edit request, with the email's own snippet")
    func replyAndForwardSurviveAFailedBodyRead() async throws {
        for isForward in [false, true] {
            let (ctx, db, translator, router) = try makeContext()
            try TestDatabase.insertAccount(db)
            try TestDatabase.insertFolder(db)
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "src5", subject: "Offsite", snippet: "Offsite snippet")
            try await db.write { db in try db.execute(sql: "DROP TABLE messageBody") }
            await translator.seed(header.id, as: 25)

            let contexts = try await sourceEmailContexts(isForward: isForward, ctx: ctx, router: router, numericId: 25)
            #expect(contexts.count == 1)
            guard contexts.count == 1 else { continue }
            #expect(contexts[0].relatedSubject == "Offsite")
            #expect(contexts[0].bodyText == "Offsite snippet")
        }
    }

    @Test("relatedEmail does not read the body of an email the current mode may not touch, in either mode")
    func relatedEmailSkipsTheBodyAcrossTheDemoBoundary() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertAccount(db, id: DemoSeed.demoAccountId, email: "demo@example.com")
        try TestDatabase.insertFolder(db, accountId: DemoSeed.demoAccountId)
        let demo = try TestDatabase.insertMessageHeader(
            db, messageId: "src6", subject: "Demo",
            folderId: "\(DemoSeed.demoAccountId):INBOX", accountId: DemoSeed.demoAccountId)
        try TestDatabase.insertMessageBody(db, headerId: demo.id, htmlContent: "<p>Demo body</p>")
        let real = try TestDatabase.insertMessageHeader(db, messageId: "src7", subject: "Real")
        try TestDatabase.insertMessageBody(db, headerId: real.id, htmlContent: "<p>Real body</p>")
        let statements = log(db)
        defer { DemoModeStore.shared.isActive = false }

        for demoActive in [false, true] {
            DemoModeStore.shared.isActive = demoActive
            let (forbidden, allowed, allowedBody) = demoActive ? (real, demo, "Demo body") : (demo, real, "Real body")

            let before = statements.reads(of: "messageBody")
            let refused = try db.read { db in
                try EmailComposeTool.relatedEmail(realId: forbidden.id, withBodyText: true, db: db)
            }
            #expect(refused?.header.id == forbidden.id, "demo \(demoActive): the caller refuses the header itself")
            #expect(refused?.bodyText == nil, "demo \(demoActive)")
            let forbiddenReads = statements.reads(of: "messageBody") - before
            #expect(forbiddenReads == 0, "demo \(demoActive): the body of an email the mode may not touch was read")

            // Control: an email of the current mode, read the same way, has its body, read once.
            let allowedBefore = statements.reads(of: "messageBody")
            let kept = try db.read { db in
                try EmailComposeTool.relatedEmail(realId: allowed.id, withBodyText: true, db: db)
            }
            #expect(kept?.bodyText?.contains(allowedBody) == true, "demo \(demoActive)")
            let allowedReads = statements.reads(of: "messageBody") - allowedBefore
            #expect(allowedReads == 1, "demo \(demoActive): \(allowedReads) body reads")
        }
    }

    @Test("email_reply and email_forward read the email's body only in the same read as its header")
    func replyAndForwardReadTheBodyWithTheHeader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["EmailReplyTool.swift", "EmailForwardTool.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("TabMail/Services/AI/Tools/\(file)"), encoding: .utf8)
            #expect(source.contains(
                "try EmailComposeTool.relatedEmail(realId: realId, withBodyText: composeRequest != nil, db: db)"), "\(file)")
            let lowered = source.lowercased()
            #expect(!lowered.contains("messagebody"), "\(file)")
            #expect(!lowered.contains("messageheader.fetch"), "\(file)")
            #expect(!lowered.contains("messageheader.filter"), "\(file)")
        }
        // The edit flow they hand the email to reads neither the header nor the body again.
        let compose = try String(
            contentsOf: root.appendingPathComponent("TabMail/Services/AI/Tools/EmailComposeTool.swift"), encoding: .utf8)
        let start = try #require(compose.range(of: "static func runComposeEdit("))
        let end = try #require(compose.range(of: "static func displayNames(", range: start.upperBound..<compose.endIndex))
        let edit = compose[start.lowerBound..<end.lowerBound].lowercased()
        #expect(edit.contains("relatedbodytext ?? header.snippet"))
        #expect(!edit.contains("messagebody"))
        #expect(!edit.contains("messageheader.fetch"))
        #expect(!edit.contains("messageheader.filter"))
    }
}
