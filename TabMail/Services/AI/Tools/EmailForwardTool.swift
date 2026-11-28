/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_forward` FSM tool matching TB addon's `email_forward.js`.
/// Opens a forward compose window for a specific email.
/// On iOS, this queues a `ComposeRequest` for the chat that asked (`ComposeOrigin`),
/// whose screen presents ComposeView in forward mode (ADR-IOS-053 Phase 2).
struct EmailForwardTool: AgentTool, Sendable {
    let name = "email_forward"
    private let ctx: ToolContext
    /// The compose edit a request runs (`EmailReplyTool.ComposeEdit`); tests answer it as the
    /// backend would.
    private let composeEdit: EmailReplyTool.ComposeEdit

    init(context: ToolContext? = nil, composeEdit: EmailReplyTool.ComposeEdit? = nil) {
        self.ctx = context ?? ToolContext()
        self.composeEdit = composeEdit ?? EmailReplyTool.chatComposeEdit
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// `invocation.composeOrigin`: the chat that asked, where the forward's compose card opens
    /// (ADR-IOS-053 Phase 2). Without one no screen can open it, so the tool fails fast.
    /// `invocation.fieldWordsKey`: the request was sent from the chat's reply field; a sent card
    /// completes that send in `ChatFieldWords` (ADR-IOS-117).
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

        // Demo boundary (ADR-IOS-038): a demo chat must never forward a real
        // email (and vice versa) — stale translator IDs can cross the line.
        guard DemoToolGuard.headerAccessible(header) else {
            BackgroundSyncLogger.logDebug("[EmailForwardTool] Blocked cross-boundary access to \(realId.prefix(30))")
            return ComposeOutcome.failed("Email not found for unique_id \(numericId)").describeForLLM
        }

        // Parse recipients (required for forward)
        let to = EmailComposeTool.parseStringArray(arguments["to"]) ?? EmailComposeTool.parseStringArray(arguments["recipients"]) ?? []
        let cc = EmailComposeTool.parseStringArray(arguments["cc"]) ?? []
        let bcc = EmailComposeTool.parseStringArray(arguments["bcc"]) ?? []

        // Parse compose instruction (TB's "request" field) — goes through runComposeEdit().
        // TB requires request for forward.
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

        if composeRequest == nil && explicitBody == nil {
            return ComposeOutcome.failed("request parameter is required and must contain the content request for the forward").describeForLLM
        }
        guard let origin = invocation.composeOrigin else {
            return ComposeOutcome.failed(ComposeOrigin.noScreenReason).describeForLLM
        }

        let recipientsFormatted = to.joined(separator: ", ")
        BackgroundSyncLogger.logDebug("[EmailForwardTool] Opening forward: numericId=\(numericId) subject=\(header.subject.prefix(40)) to=\(to) request=\(composeRequest != nil)")

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_forward" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Forward email with subject '...' to recipients: ... Content request: ..."
        var generatedSubject: String?
        var generatedBody: String? = explicitBody
        if let composeRequest {
            let wrappedRequest = "Forward email with subject \"\(header.subject)\" to recipients: \(recipientsFormatted). Content request: \(composeRequest)"
            // The related email's body for context, through the one identity-checked read: another
            // email seated at its address since it was read refuses the request.
            guard let relatedBodyText = try await ctx.db.read({ db in
                try ComposeEditContext.relatedBodyText(of: header, db: db)
            }) else {
                return ComposeOutcome.failed("the email changed since it was read; nothing was done").describeForLLM
            }
            do {
                // The forward is sent from the forwarded email's account, so the AI signs as it.
                let sender: Account? = try? await ctx.db.read { db in
                    try Account.fetchOne(db, key: header.accountId)
                }
                let result = try await EmailComposeTool.runComposeEdit(
                    to: to,
                    cc: cc,
                    subject: nil,
                    body: nil,
                    request: wrappedRequest,
                    mode: "edit_forward",
                    relatedHeader: header,
                    relatedBodyText: relatedBodyText,
                    sender: sender,
                    composeEdit: composeEdit
                )
                generatedSubject = result.subject
                generatedBody = result.body ?? generatedBody
                BackgroundSyncLogger.logDebug("[EmailForwardTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)")
            } catch {
                BackgroundSyncLogger.logDebug("[EmailForwardTool] performInlineEdit failed: \(error) — opening forward with original content")
            }
        }

        // Short-circuit duplicate retries — see EmailReplyTool for rationale.
        // Key on (accountId, stableId of source email, .forward mode) so
        // forwarding to different recipient sets the second time is still
        // blocked — the agent should be told "already forwarded" rather
        // than open a duplicate compose. If the user legitimately wants a
        // second forward, they wait out the TTL or phrase differently.
        let cacheKey = RecentlyCompletedComposeCache.Key(
            accountId: header.accountId,
            stableId: header.stableId,
            mode: .forward
        )
        if await MainActor.run(body: { ctx.router.recentlySentCompose.isRecentlySent(cacheKey) }) {
            BackgroundSyncLogger.logDebug("[EmailForwardTool] Skipping duplicate forward for \(header.accountId):\(header.stableId) — recently sent")
            return "This email was already forwarded moments ago. No further action needed."
        }

        // Suspend until the user sends, dismisses, or Stop cancels the task.
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome(fieldWordsKey: invocation.fieldWordsKey) { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .forward,
                replyTo: header,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: generatedSubject,
                body: generatedBody,
                origin: origin,
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
