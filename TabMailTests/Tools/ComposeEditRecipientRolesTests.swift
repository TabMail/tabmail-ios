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
/// And a reply or forward edit request describes one email: its body text is read with the check that
/// the row is still the email its header was read from (`ComposeEditContext.relatedBodyText`).
///
/// Each tool gets the backend call through its init's `composeEdit:` seam, which receives the
/// exact `ComposeEditContext` the tool built for `performInlineEdit`.
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
            if let req = router.takeCompose(for: ComposeTestOrigin.inboxHost) { return req }
            await Task.yield()
        }
        return router.takeCompose(for: ComposeTestOrigin.inboxHost)
    }

    /// Runs the tool `run` builds with the capturing edit call, closes the compose card it opens,
    /// and returns every edit context the tool built.
    private func captureEditContexts(
        router: AgentToolRouter,
        run: @escaping @MainActor (_ composeEdit: @escaping EmailReplyTool.ComposeEdit) async throws -> String
    ) async throws -> [ComposeEditContext] {
        try await captureEditAndRequest(router: router, run: run).contexts
    }

    /// The edit contexts the tool built and the To/Cc/Bcc of the compose request it enqueued.
    /// `run` passes `composeEdit` to the tool's init, the tool's one edit call.
    private func captureEditAndRequest(
        router: AgentToolRouter,
        run: @escaping @MainActor (_ composeEdit: @escaping EmailReplyTool.ComposeEdit) async throws -> String
    ) async throws -> (contexts: [ComposeEditContext], to: [String], cc: [String], bcc: [String]) {
        let box = ContextBox()
        let composeEdit: EmailReplyTool.ComposeEdit = { ctx, _, _, _ in
            await box.append(ctx)
            return InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil, textMessage: nil, changeCommand: nil, raw: "")
        }
        let task = Task { @MainActor () -> String in try await run(composeEdit) }
        guard let req = await waitForPendingCompose(on: router) else {
            Issue.record("Tool did not open a compose card")
            task.cancel()
            _ = try? await task.value
            return (await box.contexts, [], [], [])
        }
        req.onOutcome(.cancelled)
        _ = try await task.value
        return (await box.contexts, req.to, req.cc, req.bcc)
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
        let contexts = try await captureEditContexts(router: router) { composeEdit in
            try await EmailComposeTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "to": .array([.string(Self.primary)]),
                "cc": .array([.string(Self.copied)]),
                "bcc": .array([.string(Self.blind)]),
                "request": .string("Ask about moving the offsite to Friday"),
            ], invocation: ComposeTestOrigin.invocation)
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
        let contexts = try await captureEditContexts(router: router) { composeEdit in
            try await EmailComposeTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "recipients": .array([.dictionary(["name": .string("Sam Lee"), "email": .string(Self.primary)])]),
                "cc": .array([.dictionary(["name": .string("Pat Kim"), "email": .string(Self.copied)])]),
                "request": .string("Ask about moving the offsite to Friday"),
            ], invocation: ComposeTestOrigin.invocation)
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

        let contexts = try await captureEditContexts(router: router) { composeEdit in
            try await EmailForwardTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "unique_id": .int(11),
                "to": .array([.string(Self.primary)]),
                "cc": .array([.string(Self.copied)]),
                "bcc": .array([.string(Self.blind)]),
                "request": .string("Let them know Friday works"),
            ], invocation: ComposeTestOrigin.invocation)
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

        var arguments: [String: JSONValue] = [
            "unique_id": .int(12),
            "request": .string("Say Friday works"),
        ]
        arguments.merge(extraArguments) { _, new in new }
        let finalArguments = arguments
        return try await captureEditContexts(router: router) { composeEdit in
            try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(
                arguments: finalArguments, invocation: ComposeTestOrigin.invocation)
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
        let captured = try await captureEditAndRequest(router: router) { composeEdit in
            try await EmailComposeTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "recipients": .array([Self.namedObject(Self.primary)]),
                "cc": .array([Self.namedObject(Self.copied)]),
                "bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Ask about moving the offsite to Friday"),
            ], invocation: ComposeTestOrigin.invocation)
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

        let captured = try await captureEditAndRequest(router: router) { composeEdit in
            try await EmailForwardTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "unique_id": .int(13),
                "to": .array([Self.namedObject(Self.primary)]),
                "cc": .array([Self.namedObject(Self.copied)]),
                "bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Let them know Friday works"),
            ], invocation: ComposeTestOrigin.invocation)
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

        let captured = try await captureEditAndRequest(router: router) { composeEdit in
            try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "unique_id": .int(14),
                "add_recipients": .array([Self.namedObject(Self.newlyCopied)]),
                "add_cc": .array([Self.namedObject(Self.copied)]),
                "add_bcc": .array([Self.namedObject(Self.blind)]),
                "request": .string("Say Friday works"),
            ], invocation: ComposeTestOrigin.invocation)
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

    /// The field keeps an added address as it was written, and its name under that address: the
    /// name is read back under the address in the same case, so a mixed-case address keeps it.
    @Test("email_reply: a named addition written in mixed case keeps its name in the edit request and on the card")
    func replyKeepsMixedCaseAddedNames() async throws {
        let (ctx, db, translator, router) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "rep4", subject: "Offsite",
            from: Self.primary, fromAddress: Self.primary,
            to: "test@example.com"
        )
        await translator.seed(header.id, as: 16)

        let mixedCase = "Kim@example.com"
        let captured = try await captureEditAndRequest(router: router) { composeEdit in
            try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "unique_id": .int(16),
                "add_cc": .array([.dictionary(["name": .string("Kim Cho"), "email": .string(mixedCase)])]),
                "request": .string("Say Friday works"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        let contexts = captured.contexts
        #expect(contexts.count == 1)
        guard contexts.count == 1 else { return }
        #expect(contexts[0].ccRecipients == [mixedCase], "control: the Cc holds the address as it was written")
        #expect(contexts[0].ccDisplayNames[mixedCase] == "Kim Cho")
        let cardCc = Self.cardNames(captured.cc)
        #expect(cardCc[mixedCase] == "Kim Cho")
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

        let captured = try await captureEditAndRequest(router: router) { composeEdit in
            try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(arguments: [
                "unique_id": .int(15),
                "add_recipients": .array([Self.namedObject(Self.primary)]),
                "request": .string("Say Friday works"),
            ], invocation: ComposeTestOrigin.invocation)
        }
        #expect(captured.contexts.count == 1)
        guard captured.contexts.count == 1 else { return }
        #expect(captured.contexts[0].toRecipients == [Self.primary])
        #expect(ComposeDraftGuards.fieldState(RecipientEntry(captured.to)).tokens == [Self.primary])
    }

    // MARK: - The email a reply or forward edit request describes (#991)
    //
    // Main's #1620 tests, re-pinned on the chat view's seams: the tools' `composeEdit:` init and the
    // one checked body read, `ComposeEditContext.relatedBodyText`, which reads the body in the same
    // snapshot as the check that the row is still the email the tool read (main reads both through
    // `EmailComposeTool.relatedEmail`, which the chat view does not have).

    /// Runs the reply (or forward) tool, with `composeEdit` as its backend call, from the inbox chat.
    private static func runSourceTool(
        isForward: Bool, ctx: ToolContext, composeEdit: @escaping EmailReplyTool.ComposeEdit,
        arguments: [String: JSONValue]
    ) async throws -> String {
        if isForward {
            return try await EmailForwardTool(context: ctx, composeEdit: composeEdit).execute(
                arguments: arguments, invocation: ComposeTestOrigin.invocation)
        }
        return try await EmailReplyTool(context: ctx, composeEdit: composeEdit).execute(
            arguments: arguments, invocation: ComposeTestOrigin.invocation)
    }

    /// Runs the reply (or forward) tool with a content request on the email seeded as `numericId`.
    private func sourceEmailContexts(
        isForward: Bool, ctx: ToolContext, router: AgentToolRouter, numericId: Int
    ) async throws -> [ComposeEditContext] {
        var arguments: [String: JSONValue] = ["unique_id": .int(numericId), "request": .string("Say Friday works")]
        if isForward { arguments["to"] = .array([.string(Self.primary)]) }
        let finalArguments = arguments
        return try await captureEditContexts(router: router) { composeEdit in
            try await Self.runSourceTool(isForward: isForward, ctx: ctx, composeEdit: composeEdit, arguments: finalArguments)
        }
    }

    /// The tool's answer when it opens no compose card, and the edit contexts it built meanwhile.
    private func runWithoutCard(
        isForward: Bool, ctx: ToolContext, arguments: [String: JSONValue]
    ) async throws -> (answer: String, asked: [ComposeEditContext]) {
        let box = ContextBox()
        let composeEdit: EmailReplyTool.ComposeEdit = { edit, _, _, _ in
            await box.append(edit)
            return InlineEditResult(response: nil, subject: "Subject", body: "Body", toDelta: nil, ccDelta: nil, bccDelta: nil, textMessage: nil, changeCommand: nil, raw: "")
        }
        let answer = try await Self.runSourceTool(isForward: isForward, ctx: ctx, composeEdit: composeEdit, arguments: arguments)
        return (answer, await box.contexts)
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
            // The body the request carries is the one read with the identity check; no other body read follows.
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
            let contexts = try await captureEditContexts(router: router) { composeEdit in
                try await Self.runSourceTool(isForward: isForward, ctx: ctx, composeEdit: composeEdit, arguments: finalArguments)
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

            var arguments: [String: JSONValue] = ["unique_id": .int(29), "request": .string("Say Friday works")]
            if isForward { arguments["to"] = .array([.string(Self.primary)]) }
            let (answer, asked) = try await runWithoutCard(isForward: isForward, ctx: ctx, arguments: arguments)
            #expect(answer.contains("no longer exists"), "forward \(isForward): \(answer)")
            #expect(asked.isEmpty, "forward \(isForward): the AI was asked about an email that is gone")
            let noCard = router.takeCompose(for: ComposeTestOrigin.inboxHost) == nil
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

    @Test("relatedBodyText reads the body of the email the row still holds, and refuses a row that is gone")
    func relatedBodyTextReadsTheBodyOfTheHeldEmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "src3", subject: "Offsite")
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Offsite body</p>")
        let bare = try TestDatabase.insertMessageHeader(db, messageId: "src3b", subject: "No body")

        let withBody = try db.read { db in try ComposeEditContext.relatedBodyText(of: header, db: db) }
        let bodyText = withBody.flatMap { $0 }
        #expect(bodyText?.contains("Offsite body") == true)

        let withoutBody = try db.read { db in try ComposeEditContext.relatedBodyText(of: bare, db: db) }
        let heldWithNoBody = withoutBody.map { $0 == nil } ?? false
        #expect(heldWithNoBody, "a held email with no stored body gives no body text, not a refusal")

        // The row is gone: the read refuses, and reads no body.
        try db.write { db in _ = try MessageHeader.deleteOne(db, key: header.id) }
        let statements = log(db)
        let gone = try db.read { db in try ComposeEditContext.relatedBodyText(of: header, db: db) }
        let refused = gone == nil
        #expect(refused, "a row that no longer holds the email refuses")
        let bodyReads = statements.reads(of: "messageBody")
        #expect(bodyReads == 0, "the body of a row that no longer holds the email was read")
    }

    @Test("relatedBodyText: a failed body read gives the held email no body text")
    func relatedBodyTextSurvivesAFailedBodyRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "src4", subject: "Offsite")
        try db.write { db in try db.execute(sql: "DROP TABLE messageBody") }

        let read = try db.read { db in try ComposeEditContext.relatedBodyText(of: header, db: db) }
        let heldWithNoBody = read.map { $0 == nil } ?? false
        #expect(heldWithNoBody, "a failed body read is read as no body, not a refusal or an error")
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

    @Test("email_reply and email_forward do not read the body of an email the current mode may not touch, in either mode")
    func replyAndForwardSkipTheBodyAcrossTheDemoBoundary() async throws {
        defer { DemoModeStore.shared.isActive = false }
        for demoActive in [false, true] {
            for isForward in [false, true] {
                let (ctx, db, translator, router) = try makeContext()
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
                let (forbidden, allowed, allowedBody) = demoActive ? (real, demo, "Demo body") : (demo, real, "Real body")
                await translator.seed(forbidden.id, as: 26)
                await translator.seed(allowed.id, as: 27)
                DemoModeStore.shared.isActive = demoActive
                let statements = log(db)
                let label = "demo \(demoActive), forward \(isForward)"

                var arguments: [String: JSONValue] = ["unique_id": .int(26), "request": .string("Say Friday works")]
                if isForward { arguments["to"] = .array([.string(Self.primary)]) }
                let (answer, asked) = try await runWithoutCard(isForward: isForward, ctx: ctx, arguments: arguments)
                #expect(answer.contains("not found"), "\(label): \(answer)")
                #expect(asked.isEmpty, "\(label): the AI was asked about an email the mode may not touch")
                let forbiddenReads = statements.reads(of: "messageBody")
                #expect(forbiddenReads == 0, "\(label): the body of an email the mode may not touch was read")
                let noCard = router.takeCompose(for: ComposeTestOrigin.inboxHost) == nil
                #expect(noCard, "\(label): a compose card opened across the boundary")

                // Control: an email of the current mode, asked the same way, has its body, read once.
                let contexts = try await sourceEmailContexts(isForward: isForward, ctx: ctx, router: router, numericId: 27)
                #expect(contexts.count == 1, "\(label)")
                guard contexts.count == 1 else { continue }
                #expect(contexts[0].bodyText.contains(allowedBody), "\(label)")
                let allowedReads = statements.reads(of: "messageBody") - forbiddenReads
                #expect(allowedReads == 1, "\(label): \(allowedReads) body reads")
            }
        }
    }

    @Test("email_reply and email_forward read the email's body only through the checked read of the header they read")
    func replyAndForwardReadTheBodyWithTheHeader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        for file in ["EmailReplyTool.swift", "EmailForwardTool.swift"] {
            let text = try source("TabMail/Services/AI/Tools/\(file)")
            let lowered = text.lowercased()
            #expect(count("try MessageHeader.fetchOne(db, key: realId)", in: text) == 1, "\(file): one header read")
            #expect(count("try ComposeEditContext.relatedBodyText(of: header, db: db)", in: text) == 1,
                    "\(file): the body only through the checked read of that header")
            #expect(!lowered.contains("messagebody"), "\(file)")
            #expect(count("messageheader.fetch", in: lowered) == 1, "\(file)")
            #expect(!lowered.contains("messageheader.filter"), "\(file)")
        }
        // The checked read: the identity check and the body read share one database snapshot, the
        // check first.
        let inline = try source("TabMail/Services/AI/AIInlineEdit.swift")
        let start = try #require(inline.range(of: "static func relatedBodyText(of header: MessageHeader, db: Database)"))
        let check = try #require(inline.range(of: "guard try AIWriteTarget.stillHolds(header, db: db) else { return nil }", range: start.upperBound..<inline.endIndex))
        let body = try #require(inline.range(of: "MessageBody.fetchOne(db, key: header.id)", range: start.upperBound..<inline.endIndex))
        #expect(check.upperBound <= body.lowerBound, "the identity check runs before the body read")
        // The edit flows they hand the email to read neither the header nor the body again.
        let compose = try source("TabMail/Services/AI/Tools/EmailComposeTool.swift")
        let editStart = try #require(compose.range(of: "static func runComposeEdit("))
        let editEnd = try #require(compose.range(of: "static func displayNames(", range: editStart.upperBound..<compose.endIndex))
        let edit = compose[editStart.lowerBound..<editEnd.lowerBound].lowercased()
        #expect(edit.contains("relatedbodytext ?? header.snippet"))
        #expect(!edit.contains("messagebody"))
        #expect(!edit.contains("messageheader.fetch"))
        #expect(!edit.contains("messageheader.filter"))
        let makeStart = try #require(inline.range(of: "static func make("))
        let makeEnd = try #require(inline.range(of: "static func relatedBodyText(", range: makeStart.upperBound..<inline.endIndex))
        let make = inline[makeStart.lowerBound..<makeEnd.lowerBound]
        #expect(make.contains("bodyText: related.map { relatedBodyText ?? $0.snippet } ?? \"\")"))
        #expect(!make.lowercased().contains("messagebody.fetch"))
    }
}
