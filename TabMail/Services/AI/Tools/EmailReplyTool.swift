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

        print("[EmailReplyTool] Opening reply: numericId=\(numericId) subject=\(header.subject.prefix(40)) request=\(composeRequest != nil) bodyLen=\(explicitBody?.count ?? 0)")

        // When a compose instruction is present, run it through performInlineEdit
        // with mode "edit_reply" — matching TB's runComposeEdit() flow.
        // TB wraps the request: "Reply to email with subject '...' with request: ..."
        var generatedSubject: String?
        var generatedBody: String? = explicitBody
        if let composeRequest {
            let wrappedRequest = "Reply to email with subject \"\(header.subject)\" with request: \(composeRequest)"
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
                    mode: "edit_reply",
                    relatedHeader: header,
                    relatedBodyText: relatedBodyText,
                    db: ctx.db
                )
                generatedSubject = result.subject
                generatedBody = result.body ?? generatedBody
                print("[EmailReplyTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)")
            } catch {
                print("[EmailReplyTool] performInlineEdit failed: \(error) — opening reply with cached/empty content")
            }
        }

        // Fall back to cached AI reply if no request and no explicit body
        if generatedBody == nil {
            generatedBody = header.cachedReply
        }

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
            print("[EmailReplyTool] Skipping duplicate reply for \(header.accountId):\(header.stableId) — recently sent")
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

    /// Apply an add/remove delta on top of `base`. Matching for removals is case-insensitive
    /// on the email address. A remove list containing "*" (literal) means "clear all — drop
    /// everything in `base`". Adds are appended after removes, de-duped case-insensitively
    /// against whatever's left.
    static func applyRecipientDelta(base: [String], adds: [String], removes: [String]) -> [String] {
        let clearAll = removes.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "*" })
        var result: [String]
        if clearAll {
            result = []
        } else {
            let removeSet = Set(removes.map { $0.lowercased() })
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
