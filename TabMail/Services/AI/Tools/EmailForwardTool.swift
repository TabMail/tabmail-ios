/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_forward` FSM tool matching TB addon's `email_forward.js`.
/// Opens a forward compose window for a specific email.
/// On iOS, this sets `AgentToolRouter.pendingCompose` which the UI observes
/// and presents ComposeView in forward mode.
struct EmailForwardTool: AgentTool, Sendable {
    let name = "email_forward"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Parse unique_id (numeric ID from ChatIdTranslator)
        let numericId: Int
        if case .int(let n) = arguments["unique_id"] {
            numericId = n
        } else if case .string(let s) = arguments["unique_id"], let n = Int(s) {
            numericId = n
        } else if case .double(let d) = arguments["unique_id"] {
            numericId = Int(d)
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

        let recipientsFormatted = to.joined(separator: ", ")
        print("[EmailForwardTool] Opening forward: numericId=\(numericId) subject=\(header.subject.prefix(40)) to=\(to) request=\(composeRequest != nil)")

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_forward" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Forward email with subject '...' to recipients: ... Content request: ..."
        var generatedSubject: String?
        var generatedBody: String? = explicitBody
        if let composeRequest {
            let wrappedRequest = "Forward email with subject \"\(header.subject)\" to recipients: \(recipientsFormatted). Content request: \(composeRequest)"
            do {
                // Get related email body text for context
                let relatedBodyText: String? = try? await ctx.db.read { db in
                    guard let messageBody = try MessageBody.fetchOne(db, key: header.id),
                          let html = messageBody.htmlContent, !html.isEmpty else { return nil }
                    return EmailFilter.htmlToPlainText(html)
                }
                let result = try await EmailComposeTool.runComposeEdit(
                    recipients: to + cc,
                    subject: nil,
                    body: nil,
                    request: wrappedRequest,
                    mode: "edit_forward",
                    relatedHeader: header,
                    relatedBodyText: relatedBodyText
                )
                generatedSubject = result.subject
                generatedBody = result.body ?? generatedBody
                print("[EmailForwardTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)")
            } catch {
                print("[EmailForwardTool] performInlineEdit failed: \(error) — opening forward with original content")
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
            print("[EmailForwardTool] Skipping duplicate forward for \(header.accountId):\(header.stableId) — recently sent")
            return "This email was already forwarded moments ago. No further action needed."
        }

        // Suspend until the user sends, dismisses, or Stop cancels the task.
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .forward,
                replyTo: header,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: generatedSubject,
                body: generatedBody,
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
