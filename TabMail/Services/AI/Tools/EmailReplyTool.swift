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
        self.composeEdit = composeEdit ?? { context, subject, body, request in
            try await AIService.shared.performInlineEdit(
                currentSubject: subject, currentBody: body, context: context, instruction: request, chatHistory: [])
        }
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

        // Compute reply-all defaults from the replied header. Sender + original To + original Cc,
        // with the user's own account addresses filtered out.
        let accounts: [Account] = (try? await ctx.db.read { db in try Account.fetchAll(db) }) ?? []
        let replyAll = buildReplyAllRecipients(for: header, allAccounts: accounts)

        let to = Self.applyRecipientDelta(base: replyAll.to, adds: addTo, removes: removeTo)
        let cc = Self.applyRecipientDelta(base: replyAll.cc, adds: addCc, removes: removeCc)
        let bcc = Self.applyRecipientDelta(base: [], adds: addBcc, removes: removeBcc)

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

        // The field's request, as it was when sent. Its audience (who was chosen in Reply to)
        // applies to a reply to the email it showed in that same account, any copy of it; never
        // across accounts. Its AI Suggestion belongs to the row it showed alone.
        let fieldReply = invocation.fieldReply.flatMap { $0.audienceApplies(to: header) ? $0 : nil }
        let shownSuggestion = composeRequest == nil ? nil
            : fieldReply.flatMap { $0.email.id == header.id ? $0.suggestion : nil }

        // The email's body for the edit's context, read in one snapshot with the check that the
        // row the field showed is still that email (a UIDVALIDITY reset can seat another at its
        // address): an edit of the suggestion is never asked against another email.
        let shownEmail = shownSuggestion == nil ? nil : fieldReply?.email
        let related = try await ctx.db.read { db -> (stillShown: Bool, bodyText: String?) in
            if let shownEmail {
                guard let target = try AIWriteTarget.capture(message: shownEmail, db: db),
                      try target.resolveCurrentHeader(db: db) != nil else { return (false, nil) }
            }
            return (true, try ComposeEditContext.relatedBodyText(of: header, db: db))
        }
        if shownSuggestion != nil, !related.stillShown {
            return ComposeOutcome.failed(
                "the email changed since the request was sent; the AI Suggestion is unchanged").describeForLLM
        }
        let account = accounts.first { $0.id == header.accountId }
        let (kbText, compositionPrompt) = await MainActor.run {
            (PromptStore.shared.kbText(), PromptStore.shared.compositionMarkdown())
        }

        // An edit of the shown suggestion: the draft is the suggestion's own envelope, built as the
        // ghost's card builds it, with this call's recipient changes applied, and its body.
        if let shownSuggestion, let composeRequest {
            let suggestionEnvelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: accounts)
            // `to`, `cc` and `bcc` are the same builder's Reply All audience with this call's changes.
            let start = ChatReplyCompose(isReplyAll: true, to: to, cc: cc, bcc: bcc, subject: suggestionEnvelope.subject)
            let context = ComposeEditContext.make(
                recipients: start.recipients, account: account, mode: "edit_reply", related: header,
                relatedBodyText: related.bodyText, compositionPrompt: compositionPrompt, kbText: kbText)
            let result: InlineEditResult
            do {
                result = try await composeEdit(context, start.subject ?? "", shownSuggestion.body, composeRequest)
            } catch {
                BackgroundSyncLogger.logDebug("[EmailReplyTool] suggestion edit failed: \(error)")
                return ComposeOutcome.failed("the AI Suggestion could not be changed; it is unchanged").describeForLLM
            }
            return await Self.finishSuggestionEdit(
                result, shown: shownSuggestion, start: start, suggestionEnvelope: suggestionEnvelope,
                email: header, rewritesInPlace: rewritesInPlace, store: storeSuggestionEdit,
                openCard: { envelope, body in
                    await openReplyCard(
                        header: header, to: envelope.to, cc: envelope.cc, bcc: envelope.bcc,
                        subject: envelope.subject, body: body, fieldReply: fieldReply)
                })
        }

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_reply" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Reply to email with subject '...' with request: ..."
        var generatedSubject: String?
        var generatedBody: String? = explicitBody
        if let composeRequest {
            let wrappedRequest = "Reply to email with subject \"\(header.subject)\" with request: \(composeRequest)"
            let context = ComposeEditContext.make(
                recipients: ChatReplyCompose(isReplyAll: true, to: to, cc: cc, bcc: bcc).recipients,
                account: account, mode: "edit_reply", related: header, relatedBodyText: related.bodyText,
                compositionPrompt: compositionPrompt, kbText: kbText)
            do {
                let result = try await composeEdit(context, "", "", wrappedRequest)
                generatedSubject = result.subject
                generatedBody = result.body ?? generatedBody
                BackgroundSyncLogger.logDebug("[EmailReplyTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)")
            } catch {
                BackgroundSyncLogger.logDebug("[EmailReplyTool] performInlineEdit failed: \(error) — opening reply with cached/empty content")
            }
        }

        // Fall back to cached AI reply if no request and no explicit body
        if generatedBody == nil {
            generatedBody = header.cachedReply
        }

        return await openReplyCard(
            header: header, to: to, cc: cc, bcc: bcc, subject: generatedSubject, body: generatedBody,
            fieldReply: fieldReply)
    }

    /// Opens the reply's compose card and waits until the user sends, dismisses, or Stop cancels
    /// the task.
    private func openReplyCard(
        header: MessageHeader, to: [String], cc: [String], bcc: [String], subject: String?, body: String?,
        fieldReply: ChatFieldReply?
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
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                // Recipients start from the reply-all set, so the send
                // records reply-all on the original (#915).
                isReplyAll: true,
                fieldReply: fieldReply,
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
    /// `start` (the suggestion's envelope with this call's recipient changes). The edit's recipient
    /// changes apply by the card's own operation (`Recipients.applying`). In place, only when the
    /// edited draft is still the suggestion's envelope (`ChatReplyCompose.holds`): the edit, its
    /// text version and change command replace the suggestion through the one writer, over the
    /// suggestion edited (a newer one stored meanwhile wins), and the ghost shows them; no card
    /// opens. Otherwise (not in place, or a draft the suggestion cannot hold: another subject,
    /// sender or audience) the compose card opens with exactly the edited draft and the
    /// suggestion is unchanged. The outcome says which happened, so the agent tells the user what
    /// they see.
    static func finishSuggestionEdit(
        _ result: InlineEditResult, shown: ReplyResult, start: ChatReplyCompose, suggestionEnvelope: ChatReplyCompose,
        email: MessageHeader, rewritesInPlace: Bool, store: StoreSuggestionEdit,
        openCard: (ChatReplyCompose, String) async -> String
    ) async -> String {
        guard let body = result.body, let textMessage = result.textMessage else {
            return ComposeOutcome.failed(
                "the AI Suggestion could not be changed (\(result.response ?? "no edit")); it is unchanged").describeForLLM
        }
        let recipients = start.recipients.applying(to: result.toDelta, cc: result.ccDelta, bcc: result.bccDelta)
        let subject = result.subject ?? start.subject ?? ThreadUtils.replySubject(for: email.subject)
        let staysTheSuggestion = suggestionEnvelope.holds(
            recipients: recipients, subject: subject, accountId: email.accountId, of: email)
        guard rewritesInPlace, staysTheSuggestion else {
            let why = staysTheSuggestion ? ""
                : "the edited email has another subject or other recipients, which the AI Suggestion cannot hold; "
            let outcome = await openCard(start.with(recipients: recipients, subject: subject), body)
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

    /// Apply an add/remove delta on top of `base`. Matching for removals is case-insensitive
    /// on the email address. A remove list containing "*" (literal) means "clear all — drop
    /// everything in `base`". Adds are appended after removes, de-duped case-insensitively
    /// against whatever's left.
    static func applyRecipientDelta(base: [String], adds: [String], removes: [String]) -> [String] {
        // Read the removals as recipient text first (ADR-IOS-092), so
        // `"Bob" <bob@example.com>` or a list in one string removes each address.
        let removeEntry = RecipientEntry(removes)
        var result: [String]
        if removeEntry.leftovers.contains("*") {
            result = []
        } else {
            let removeSet = Set(removeEntry.addresses.map { $0.lowercased() })
            result = base.filter { !removeSet.contains($0.lowercased()) }
        }
        var seen = Set(result.map { $0.lowercased() })
        for email in adds {
            let trimmed = email.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "*" else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}
