/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_compose` FSM tool matching TB addon's `email_compose.js`.
/// When a `request` (compose instruction) is present, calls `performInlineEdit()` with
/// mode `"edit_new"` to have the backend LLM generate subject + body — matching TB's
/// `runComposeEdit()` → `buildComposeEditChat()` → `system_prompt_compose_interactive` flow exactly.
/// Then opens ComposeView with the AI-generated content.
struct EmailComposeTool: AgentTool, Sendable {
    let name = "email_compose"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Parse recipients
        let to = Self.parseStringArray(arguments["to"]) ?? Self.parseStringArray(arguments["recipients"]) ?? []
        let cc = Self.parseStringArray(arguments["cc"]) ?? []
        let bcc = Self.parseStringArray(arguments["bcc"]) ?? []

        // Parse subject and body
        let subject: String?
        if case .string(let s) = arguments["subject"], !s.isEmpty {
            subject = s
        } else {
            subject = nil
        }

        let body: String?
        if case .string(let s) = arguments["body"], !s.isEmpty {
            body = s
        } else {
            body = nil
        }

        // Parse compose instruction (TB's "request" field).
        // When present, this triggers the full compose edit flow via performInlineEdit().
        let composeRequest: String?
        if case .string(let s) = arguments["request"], !s.isEmpty {
            composeRequest = s
        } else {
            composeRequest = nil
        }

        if to.isEmpty {
            return ComposeOutcome.failed("recipients parameter is required and must contain at least one recipient").describeForLLM
        }

        if DebugModeManager.isLoggingEnabled() { print("[EmailComposeTool] Opening compose: to=\(to) cc=\(cc) subject=\(subject ?? "(none)") bodyLen=\(body?.count ?? 0) requestLen=\(composeRequest?.count ?? 0)") }

        // When a compose instruction is present, run it through the backend LLM
        // to generate the actual email content — matching TB's runComposeEdit() flow.
        var generatedSubject = subject
        var generatedBody = body
        if let composeRequest {
            do {
                let result = try await Self.runComposeEdit(
                    recipients: to + cc,
                    subject: subject,
                    body: body,
                    request: composeRequest,
                    mode: "edit_new",
                    db: ctx.db
                )
                generatedSubject = result.subject ?? generatedSubject
                generatedBody = result.body ?? generatedBody
                if DebugModeManager.isLoggingEnabled() { print("[EmailComposeTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)") }
            } catch {
                print("[EmailComposeTool] performInlineEdit failed: \(error) — opening compose with original content")
            }
        }

        // Suspend until the user sends, dismisses, or Stop cancels the task.
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .compose,
                replyTo: nil,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: generatedSubject,
                body: generatedBody,
                onOutcome: onOutcome,
                outcomeState: state
            )
        }
        return outcome.describeForLLM
    }

    // MARK: - Compose Edit (TB Parity)

    /// Shared compose edit flow matching TB's `runComposeEdit()`.
    /// Resolves account/prompts, builds `ComposeEditContext`, and calls `performInlineEdit()`.
    /// Used by email_compose (mode "edit_new"), email_reply (mode "edit_reply"),
    /// and email_forward (mode "edit_forward") tools for full TB parity.
    static func runComposeEdit(
        recipients: [String],
        subject: String?,
        body: String?,
        request: String,
        mode: String,
        relatedHeader: MessageHeader? = nil,
        relatedBodyText: String? = nil,
        db: (any DatabaseReader & Sendable)? = nil
    ) async throws -> InlineEditResult {
        let dbReader = db ?? AppDatabase.rawPool
        // Get sender info from primary account (matching TB's user identity resolution)
        let account: Account? = try? await dbReader.read { db in
            if let primary = try Account.filter(Column("isActive") == true && Column("isPrimary") == true).fetchOne(db) {
                return primary
            }
            return try Account.filter(Column("isActive") == true).fetchOne(db)
        }

        // Get composition prompt and KB text (MainActor-isolated)
        let (kbText, compositionPrompt) = await MainActor.run {
            (PromptStore.shared.kbText(), PromptStore.shared.compositionMarkdown())
        }

        // Build related email metadata for reply/forward modes
        let relatedDate: String
        let relatedSubject: String
        let relatedFrom: String
        let relatedTo: String
        let relatedCc: String
        let bodyText: String

        if let header = relatedHeader {
            relatedDate = AIService.formatTimestampForAgent(header.date)
            relatedSubject = header.subject
            let fromFormatted = header.fromAddress.isEmpty ? header.from : "\(header.from) <\(header.fromAddress)>"
            relatedFrom = fromFormatted
            relatedTo = header.to
            relatedCc = ""  // iOS MessageHeader doesn't store CC
            bodyText = relatedBodyText ?? header.snippet
        } else {
            relatedDate = ""
            relatedSubject = ""
            relatedFrom = ""
            relatedTo = ""
            relatedCc = ""
            bodyText = ""
        }

        let context = ComposeEditContext(
            recipients: recipients,
            toRecipients: recipients,
            ccRecipients: [],
            bccRecipients: [],
            toDisplayNames: [:],
            ccDisplayNames: [:],
            bccDisplayNames: [:],
            senderName: account?.displayName ?? "",
            senderEmail: account?.emailAddress ?? "",
            mode: mode,
            compositionPrompt: compositionPrompt,
            kbText: kbText,
            relatedDate: relatedDate,
            relatedSubject: relatedSubject,
            relatedFrom: relatedFrom,
            relatedTo: relatedTo,
            relatedCc: relatedCc,
            bodyText: bodyText
        )

        if DebugModeManager.isLoggingEnabled() { print("[EmailComposeTool] runComposeEdit: mode=\(mode) recipients=\(recipients.count) request=\(request.prefix(80))") }

        return try await AIService.shared.performInlineEdit(
            currentSubject: subject ?? "",
            currentBody: body ?? "",
            context: context,
            instruction: request,
            chatHistory: []
        )
    }

    // MARK: - Helpers

    /// Parse a JSON value as a string array.
    /// Handles: array of strings, array of `{"email": "..."}` objects (tool schema format),
    /// or a single string. Extracts the `email` field from object items.
    static func parseStringArray(_ value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case .array(let arr):
            let strings = arr.compactMap { item -> String? in
                if case .string(let s) = item { return s }
                if case .dictionary(let dict) = item,
                   case .string(let email) = dict["email"], !email.isEmpty { return email }
                return nil
            }
            return strings.isEmpty ? nil : strings
        case .string(let s):
            return s.isEmpty ? nil : [s]
        default:
            return nil
        }
    }
}
