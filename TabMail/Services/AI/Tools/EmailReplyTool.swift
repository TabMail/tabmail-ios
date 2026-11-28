/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_reply` FSM tool matching TB addon's `email_reply.js`.
/// Opens a reply compose window for a specific email.
/// On iOS, this queues a `ComposeRequest` for the chat that asked (`ComposeOrigin`),
/// whose screen presents ComposeView with `replyTo:` (ADR-IOS-053 Phase 2).
struct EmailReplyTool: AgentTool, Sendable {
    static let registeredName = "email_reply"
    let name = Self.registeredName
    private let ctx: ToolContext
    /// The compose edit a request runs: the draft's subject and body with the request, in the
    /// context the card would send (`ComposeEditContext.make`), as Thunderbird's `runComposeEdit`.
    /// Tests answer it as the backend would (precedent: `ToolContext`'s injected database).
    typealias ComposeEdit = @Sendable (
        _ context: ComposeEditContext, _ subject: String, _ body: String, _ request: String
    ) async throws -> InlineEditResult
    private let composeEdit: ComposeEdit

    init(context: ToolContext? = nil, composeEdit: ComposeEdit? = nil) {
        self.ctx = context ?? ToolContext()
        self.composeEdit = composeEdit ?? Self.chatComposeEdit
    }

    /// The production compose edit of every agent compose tool (reply, new email, forward): the
    /// chat's one AI service, the one the card's edits and Recompute use.
    static let chatComposeEdit: ComposeEdit = { context, subject, body, request in
        let aiService = await MainActor.run { ChatPillState.shared.aiService }
        return try await aiService.performInlineEdit(
            currentSubject: subject, currentBody: body, context: context, instruction: request, chatHistory: [])
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// `invocation.composeOrigin`: the chat that asked, where the reply's compose card opens
    /// (ADR-IOS-053 Phase 2). Without one no screen can open it, so the tool fails fast. The chat
    /// view's closed field never comes here: its Send is the user's own message, written by
    /// `ChatFieldCompose` (ADR-IOS-114 decision 10, amended 2026-11-26).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // Parse unique_id (numeric ID from ChatIdTranslator)
        let numericId: Int
        if let n = arguments["unique_id"]?.wholeNumber {
            numericId = n
        } else if case .string(let s) = arguments["unique_id"], let n = Int(s) {
            numericId = n
        } else {
            return ComposeOutcome.failed("missing or invalid unique_id").describeForLLM
        }

        // Resolve to real MessageHeader
        let translator = ctx.translator
        guard let realId = await translator.toRealId(numericId) else {
            return ComposeOutcome.failed("Email not found for unique_id \(numericId)").describeForLLM
        }

        guard let header: MessageHeader = try await ctx.db.read({ db in
            try MessageHeader.fetchOne(db, key: realId)
        }) else {
            return ComposeOutcome.failed("Email with id \(realId) no longer exists").describeForLLM
        }

        // Demo boundary (ADR-IOS-038): a demo chat must never reply to a real
        // email (and vice versa) — stale translator IDs can cross the line.
        guard DemoToolGuard.headerAccessible(header) else {
            BackgroundSyncLogger.logDebug("[EmailReplyTool] Blocked cross-boundary access to \(realId.prefix(30))")
            return ComposeOutcome.failed("Email not found for unique_id \(numericId)").describeForLLM
        }

        BackgroundSyncLogger.logDebug("[EmailReplyTool] Opening reply: numericId=\(numericId) subject=\(header.subject.prefix(40))")
        return try await reply(to: header, arguments: arguments, invocation: invocation)
    }

    /// The reply to `header` the agent asks for.
    private func reply(to header: MessageHeader, arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // Parse delta-shaped overrides: per-field add/remove lists applied on top of reply-all
        // defaults. See email_reply-v1.5.16.json. Absent key = no delta (empty).
        let addTo = EmailComposeTool.parseStringArray(arguments["add_recipients"]) ?? []
        let removeTo = EmailComposeTool.parseStringArray(arguments["remove_recipients"]) ?? []
        let addCc = EmailComposeTool.parseStringArray(arguments["add_cc"]) ?? []
        let removeCc = EmailComposeTool.parseStringArray(arguments["remove_cc"]) ?? []
        let addBcc = EmailComposeTool.parseStringArray(arguments["add_bcc"]) ?? []
        let removeBcc = EmailComposeTool.parseStringArray(arguments["remove_bcc"]) ?? []

        let accounts: [Account] = (try? await ctx.db.read { db in try Account.fetchAll(db) }) ?? []

        guard let origin = invocation.composeOrigin else {
            return ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM
        }

        // Parse optional request (compose instruction) and body separately.
        // TB's "request" goes through runComposeEdit() to generate the actual reply content.
        let composeRequest: String?
        if case .string(let s) = arguments["request"], !s.isEmpty {
            composeRequest = s
        } else {
            composeRequest = nil
        }

        let explicitBody: String?
        if case .string(let s) = arguments["body"], !s.isEmpty {
            explicitBody = s
        } else {
            explicitBody = nil
        }

        BackgroundSyncLogger.logDebug("[EmailReplyTool] Reply request: request=\(composeRequest != nil) bodyLen=\(explicitBody?.count ?? 0)")

        let account = accounts.first { $0.id == header.accountId }

        // THE draft of this reply, derived once and used for both the model's context and the card:
        // the AI Suggestion's own envelope (`ChatReplyCompose.suggestionEnvelope`, the ghost's card's
        // builder) with this call's recipient changes applied by the one step the field's Send
        // shares (`ChatReplyCompose.applying`, which also leaves an own-only email's addresses out
        // once someone else is added). Its kind follows the final audience (`ChatReplyCompose.with`).
        let suggestionEnvelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: accounts)
        let start = suggestionEnvelope.applying(
            to: Self.delta(adds: addTo, removes: removeTo), cc: Self.delta(adds: addCc, removes: removeCc),
            bcc: Self.delta(adds: addBcc, removes: removeBcc), subject: suggestionEnvelope.subject, accounts: accounts)

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_reply" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Reply to email with subject '...' with request: ..."
        var envelope = start
        var generatedBody: String? = explicitBody
        if let composeRequest {
            let request = "Reply to email with subject \"\(header.subject)\" with request: \(composeRequest)"
            // The email's body, read with the check that the row is still that email
            // (`ComposeEditContext.relatedBodyText`): a UIDVALIDITY reset can seat another email at
            // its address, and its body is never sent as this email's context.
            guard let bodyText = try await ctx.db.read({ db in
                try ComposeEditContext.relatedBodyText(of: header, onBodyReadFailure: .readsAsMissing, db: db)
            }) else {
                return ComposeOutcome.failed("the email changed since the request was sent; nothing was done").describeForLLM
            }
            let context = await Self.editContext(
                recipients: start.recipients, account: account, related: header, relatedBodyText: bodyText)
            do {
                let result = try await composeEdit(context, "", "", request)
                // A subject the edit writes replaces the start's; with none the start's stays.
                if let subject = result.subject { envelope = start.with(subject: subject) }
                generatedBody = result.body ?? generatedBody
                BackgroundSyncLogger.logDebug("[EmailReplyTool] AI generated: subject=\(result.subject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)")
            } catch {
                BackgroundSyncLogger.logDebug("[EmailReplyTool] performInlineEdit failed: \(error) — opening reply with the AI Suggestion or empty content")
            }
        }

        // With no request and no explicit body, the card opens on the stored AI Suggestion: the
        // whole value (body, text message, change command), so the card's own edit replaces
        // exactly the value stored (`MessageHeader.replaceSuggestion(with:ifStill:)`).
        let storedSuggestion = generatedBody == nil ? header.suggestion : nil
        return await openReplyCard(
            header: header, envelope: envelope, body: generatedBody, suggestion: storedSuggestion,
            origin: origin, invocation: invocation)
    }

    /// The compose edit's context for a reply draft with `recipients`, sent from `account`.
    private static func editContext(
        recipients: ComposeDraftGuards.Recipients, account: Account?, related: MessageHeader, relatedBodyText: String?
    ) async -> ComposeEditContext {
        let (kbText, compositionPrompt) = await MainActor.run {
            (PromptStore.shared.kbText(), PromptStore.shared.compositionMarkdown())
        }
        return ComposeEditContext.make(
            recipients: recipients, account: account, mode: "edit_reply", related: related,
            relatedBodyText: relatedBodyText, compositionPrompt: compositionPrompt, kbText: kbText)
    }

    /// This call's add/remove lists for one field, as the card applies an edit's
    /// (`Recipients.applying`): adds read as recipient text, removals as addresses, `"*"` clears.
    static func delta(adds: [String], removes removeTexts: [String]) -> RecipientDelta? {
        let removeEntry = RecipientEntry(removeTexts)
        let removes = removeEntry.leftovers.contains("*") ? ["*"] : removeEntry.addresses.map { $0.lowercased() }
        let delta = RecipientDelta(adds: RecipientEntry(adds), removes: removes)
        return delta.isEmpty ? nil : delta
    }

    /// Opens the reply's compose card and waits until the user sends, dismisses, or Stop cancels
    /// the task. `origin`: the chat that asked, where the card opens. A retried turn re-emits its
    /// tool call, so a reply sent moments ago opens nothing (`recentlySentCompose`).
    private func openReplyCard(
        header: MessageHeader, envelope: ChatReplyCompose, body: String?, suggestion: ReplyResult?,
        origin: ComposeOrigin, invocation: ToolInvocation
    ) async -> String {
        // Short-circuit duplicate retries: if we just sent a reply to this
        // same email within the TTL, don't re-prompt the user. Round 2 HTTP
        // failures trigger a chat-turn retry that re-emits this tool_call;
        // without this, the user sees a fresh compose window for a message
        // that's already queued in the outbox.
        let cacheKey = RecentlyCompletedComposeCache.Key(
            accountId: header.accountId,
            stableId: header.stableId,
            mode: .reply
        )
        if await MainActor.run(body: { ctx.router.recentlySentCompose.isRecentlySent(cacheKey) }) {
            BackgroundSyncLogger.logDebug("[EmailReplyTool] Skipping duplicate reply for \(header.accountId):\(header.stableId) — recently sent")
            return "Reply to this email was already sent moments ago. No further action needed."
        }

        // Suspend until the user sends, dismisses, or Stop cancels the task.
        // The helper threads onOutcome + outcomeState into ComposeRequest so
        // the MainActor-isolated ComposeView callback resumes this tool's
        // continuation.
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome(fieldWordsKey: invocation.fieldWordsKey) { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .reply,
                replyTo: header,
                to: envelope.to,
                cc: envelope.cc,
                bcc: envelope.bcc,
                subject: envelope.subject,
                body: body,
                origin: origin,
                suggestion: suggestion,
                // A Reply All when the recipients hold the whole Reply All audience, so the send
                // records reply-all on the original (#915).
                isReplyAll: envelope.isReplyAll,
                onOutcome: onOutcome,
                outcomeState: state
            )
        }
        if case .sent = outcome {
            await MainActor.run {
                ctx.router.recentlySentCompose.markSent(cacheKey)
            }
        }
        return outcome.describeForLLM
    }
}
