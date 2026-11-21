/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_reply` FSM tool matching TB addon's `email_reply.js`.
/// Opens a reply compose window for a specific email.
/// On iOS, this sets `AgentToolRouter.pendingCompose` which the UI observes
/// and presents ComposeView with `replyTo:`.
struct EmailReplyTool: AgentTool, Sendable {
    let name = "email_reply"
    private let ctx: ToolContext
    /// The compose edit a request runs: the draft's subject and body with the request, in the
    /// context the card would send (`ComposeEditContext.make`), as Thunderbird's `runComposeEdit`.
    /// Tests answer it as the backend would (precedent: `ToolContext`'s injected database).
    typealias ComposeEdit = @Sendable (
        _ context: ComposeEditContext, _ subject: String, _ body: String, _ request: String
    ) async throws -> InlineEditResult
    private let composeEdit: ComposeEdit
    /// The one write this tool makes: an edit of the AI Suggestion stored over the one it edited
    /// (`ComposeView.writeCachedReplyToDB`, the one writer), bound to the email the field showed.
    /// Its context stays read-only; tests store into their own database.
    typealias StoreSuggestionEdit = @Sendable (
        _ edit: ReplyResult, _ shown: ReplyResult, _ email: MessageHeader
    ) async -> AIWriteOutcome
    private let storeSuggestionEdit: StoreSuggestionEdit

    init(context: ToolContext? = nil, composeEdit: ComposeEdit? = nil, storeSuggestionEdit: StoreSuggestionEdit? = nil) {
        self.ctx = context ?? ToolContext()
        self.storeSuggestionEdit = storeSuggestionEdit ?? { edit, shown, email in
            await ComposeView.writeCachedReplyToDB(edit, replacing: shown, replyTo: email, db: AppDatabase.dbPool)
        }
        self.composeEdit = composeEdit ?? Self.chatComposeEdit
    }

    /// The production compose edit of every agent compose tool (reply, new email, forward): the
    /// chat's one AI service, the one the card's edits and Recompute use.
    static let chatComposeEdit: ComposeEdit = { context, subject, body, request in
        if let override = EmailComposeTool.inlineEditOverride {
            return try await override(context, request)
        }
        let aiService = await MainActor.run { ChatPillState.shared.aiService }
        return try await aiService.performInlineEdit(
            currentSubject: subject, currentBody: body, context: context, instruction: request, chatHistory: [])
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// The registry's entry (`AgentTool`), with the one choice of what a field edit of the AI
    /// Suggestion does (`ChatSuggestionConfig.fieldEditRewritesInPlace`).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        try await run(arguments: arguments, invocation: invocation,
                      rewritesInPlace: ChatSuggestionConfig.fieldEditRewritesInPlace)
    }

    /// `invocation.fieldReply`: the request was sent from the chat's reply field. A reply to the
    /// email that field showed, any copy of it in the same account, carries it, so its compose goes
    /// to the people chosen then; a reply to another account's copy, or another email, keeps its
    /// own recipients (ADR-IOS-114 decision 11). The field's AI Suggestion belongs to the row it
    /// showed alone, and only while that row is still the same email.
    ///
    /// A request from the field while its AI Suggestion showed (`ChatFieldReply.suggestion`) is a
    /// compose edit of that suggestion, as Thunderbird's inline editor edits the draft it shows
    /// (`runComposeEdit` with the draft as `body`). `rewritesInPlace` is the one choice of what
    /// follows (`ChatSuggestionConfig.fieldEditRewritesInPlace`): the edit and its text version
    /// replace the suggestion, so the ghost shows them and the card stays closed; or the compose
    /// card opens with the edited email. Internal so tests can take either choice.
    func run(
        arguments: [String: JSONValue], invocation: ToolInvocation, rewritesInPlace: Bool
    ) async throws -> String {
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

        // Parse delta-shaped overrides: per-field add/remove lists applied on top of reply-all
        // defaults. See email_reply-v1.5.16.json. Absent key = no delta (empty).
        let addTo = EmailComposeTool.parseStringArray(arguments["add_recipients"]) ?? []
        let removeTo = EmailComposeTool.parseStringArray(arguments["remove_recipients"]) ?? []
        let addCc = EmailComposeTool.parseStringArray(arguments["add_cc"]) ?? []
        let removeCc = EmailComposeTool.parseStringArray(arguments["remove_cc"]) ?? []
        let addBcc = EmailComposeTool.parseStringArray(arguments["add_bcc"]) ?? []
        let removeBcc = EmailComposeTool.parseStringArray(arguments["remove_bcc"]) ?? []

        let accounts: [Account] = (try? await ctx.db.read { db in try Account.fetchAll(db) }) ?? []

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

        BackgroundSyncLogger.logDebug("[EmailReplyTool] Opening reply: numericId=\(numericId) subject=\(header.subject.prefix(40)) request=\(composeRequest != nil) bodyLen=\(explicitBody?.count ?? 0)")

        // The row the field showed is bound to the email it showed, checked before anything is
        // decided or read: a UIDVALIDITY reset can seat another email at its address, and the
        // request is then refused, never turned into a reply to that other email.
        let fieldRow = invocation.fieldReply.flatMap { $0.email.id == header.id ? $0.email : nil }
        if let fieldRow, try await !ctx.db.read({ db in try AIWriteTarget.stillHolds(fieldRow, db: db) }) {
            return ComposeOutcome.failed(
                "the email changed since the request was sent; nothing was done, and the AI Suggestion is unchanged").describeForLLM
        }

        // The field's request, as it was when sent. Its audience (who was chosen in Reply to)
        // applies to a reply to the email it showed in that same account, any copy of it; never
        // across accounts. Its AI Suggestion belongs to the row it showed alone.
        let fieldReply = invocation.fieldReply.flatMap { $0.audienceApplies(to: header) ? $0 : nil }
        let shownSuggestion = composeRequest == nil || fieldRow == nil ? nil : fieldReply?.suggestion
        let account = accounts.first { $0.id == header.accountId }

        // THE draft of this reply, derived once and used for both the model's context and the card:
        // a plain reply to only the people chosen in the field (this call's recipient changes are
        // not applied, as the card never applied them), else the AI Suggestion's own envelope
        // (`ChatReplyCompose.suggestionEnvelope`, the ghost's card's builder) with this call's
        // recipient changes applied by the card's own operation. Its kind follows the final
        // audience (`ChatReplyCompose.with`).
        let suggestionEnvelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: accounts)
        let start: ChatReplyCompose
        if shownSuggestion == nil, let only = fieldReply?.onlyTo {
            start = ChatReplyCompose.onlyTo(only, replying: header)
        } else {
            start = suggestionEnvelope.with(
                recipients: suggestionEnvelope.recipients.applying(
                    to: Self.delta(adds: addTo, removes: removeTo), cc: Self.delta(adds: addCc, removes: removeCc),
                    bcc: Self.delta(adds: addBcc, removes: removeBcc)),
                subject: suggestionEnvelope.subject)
        }

        // An edit of the shown suggestion: the draft is that envelope and the suggestion's body.
        if let shownSuggestion, let composeRequest {
            guard let bodyText = try await relatedBody(of: header, boundTo: fieldRow) else {
                return ComposeOutcome.failed(
                    "the email changed since the request was sent; the AI Suggestion is unchanged").describeForLLM
            }
            let context = await Self.editContext(
                recipients: start.recipients, account: account, related: header, relatedBodyText: bodyText)
            let result: InlineEditResult
            do {
                result = try await composeEdit(context, start.subject, shownSuggestion.body, composeRequest)
            } catch {
                BackgroundSyncLogger.logDebug("[EmailReplyTool] suggestion edit failed: \(error)")
                return ComposeOutcome.failed("the AI Suggestion could not be changed; it is unchanged").describeForLLM
            }
            return await Self.finishSuggestionEdit(
                result, shown: shownSuggestion, start: start,
                suggestionEnvelope: suggestionEnvelope, email: header, rewritesInPlace: rewritesInPlace,
                store: storeSuggestionEdit,
                openCard: { envelope, body in
                    await openReplyCard(
                        header: header, envelope: envelope, body: body, fieldReply: fieldReply,
                        draftId: Draft.separateReplyKey(replyTo: "\(header.accountId):\(header.stableId)"))
                })
        }

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_reply" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Reply to email with subject '...' with request: ..."
        var envelope = start
        var generatedBody: String? = explicitBody
        if let composeRequest {
            guard let bodyText = try await relatedBody(of: header, boundTo: fieldRow) else {
                return ComposeOutcome.failed("the email changed since the request was sent; nothing was done").describeForLLM
            }
            let wrappedRequest = "Reply to email with subject \"\(header.subject)\" with request: \(composeRequest)"
            let context = await Self.editContext(
                recipients: start.recipients, account: account, related: header, relatedBodyText: bodyText)
            do {
                let result = try await composeEdit(context, "", "", wrappedRequest)
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
            fieldReply: fieldReply, draftId: nil)
    }

    /// The email's body for a compose edit's context (`ComposeEditContext.relatedBodyText`, the one
    /// identity-checked read), checked against the row the field showed (`boundTo`) when there is
    /// one, else the row this call read; nil when that row is no longer that email. Read only
    /// where a model edit runs.
    private func relatedBody(of header: MessageHeader, boundTo shown: MessageHeader?) async throws -> String?? {
        try await ctx.db.read { db in try ComposeEditContext.relatedBodyText(of: shown ?? header, db: db) }
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
    /// the task.
    private func openReplyCard(
        header: MessageHeader, envelope: ChatReplyCompose, body: String?, suggestion: ReplyResult? = nil,
        fieldReply: ChatFieldReply?, draftId: String?
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
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .reply,
                replyTo: header,
                to: envelope.to,
                cc: envelope.cc,
                bcc: envelope.bcc,
                subject: envelope.subject,
                body: body,
                suggestion: suggestion,
                // A Reply All when the recipients hold the whole Reply All audience, so the send
                // records reply-all on the original (#915).
                isReplyAll: envelope.isReplyAll,
                fieldReply: fieldReply,
                draftId: draftId,
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

    /// The end of a compose edit of the AI Suggestion the field showed (`shown`), from the draft
    /// `start` (the suggestion's envelope with this call's recipient changes). A subject the edit
    /// writes replaces the start's; with none (the model's subject was blank) the draft keeps the
    /// start's subject, an empty one included. The edit's recipient
    /// changes apply by the card's own operation (`Recipients.applying`). In place, only when the
    /// edited draft is still the suggestion's envelope (`ChatReplyCompose.holds`): the edit, its
    /// text version and change command replace the suggestion through the one writer, over the
    /// suggestion edited (a newer one stored meanwhile wins), and the ghost shows them; no card
    /// opens. Otherwise (not in place, or a draft the suggestion cannot hold: another subject,
    /// sender or audience) the compose card opens with exactly the edited draft and the
    /// suggestion is unchanged. The outcome says which happened, so the agent tells the user what
    /// they see.
    static func finishSuggestionEdit(
        _ result: InlineEditResult, shown: ReplyResult, start: ChatReplyCompose,
        suggestionEnvelope: ChatReplyCompose, email: MessageHeader, rewritesInPlace: Bool,
        store: StoreSuggestionEdit, openCard: (ChatReplyCompose, String) async -> String
    ) async -> String {
        guard let body = result.body, let textMessage = result.textMessage else {
            return ComposeOutcome.failed(
                "the AI Suggestion could not be changed (\(result.response ?? "no edit")); it is unchanged").describeForLLM
        }
        let subject = result.subject ?? start.subject
        let recipients = start.recipients.applying(to: result.toDelta, cc: result.ccDelta, bcc: result.bccDelta)
        let staysTheSuggestion = suggestionEnvelope.holds(
            recipients: recipients, subject: subject, accountId: email.accountId, of: email)
        guard rewritesInPlace, staysTheSuggestion else {
            let why = staysTheSuggestion ? ""
                : "the edited email has another subject or other recipients, which the AI Suggestion cannot hold; "
            let outcome = await openCard(suggestionEnvelope.with(recipients: recipients, subject: subject), body)
            return "Opened the reply card with the edited email (\(why)the AI Suggestion is unchanged). Outcome: \(outcome)"
        }
        let edit = ReplyResult(body: body, textMessage: textMessage, changeCommand: result.changeCommand)
        guard await store(edit, shown, email) == .written else {
            return ComposeOutcome.failed(
                "the AI Suggestion could not be stored (it changed meanwhile, or the save failed); this edit was not kept").describeForLLM
        }
        return "Changed the AI Suggestion in place (no card opened); it now reads: \(textMessage). "
            + "Nothing was sent: the user taps the suggestion to review and send it."
    }
}
