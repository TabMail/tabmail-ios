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
    /// The compose edit a request runs (`EmailReplyTool.ComposeEdit`); tests answer it as the
    /// backend would.
    private let composeEdit: EmailReplyTool.ComposeEdit

    init(context: ToolContext? = nil, composeEdit: EmailReplyTool.ComposeEdit? = nil) {
        self.ctx = context ?? ToolContext()
        self.composeEdit = composeEdit ?? EmailReplyTool.chatComposeEdit
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

        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[EmailComposeTool] Opening compose: to=\(to) cc=\(cc) subject=\(subject ?? "(none)") bodyLen=\(body?.count ?? 0) requestLen=\(composeRequest?.count ?? 0)") }

        // When a compose instruction is present, run it through the backend LLM
        // to generate the actual email content — matching TB's runComposeEdit() flow.
        var generatedSubject = subject
        var generatedBody = body
        if let composeRequest {
            do {
                let result = try await Self.runComposeEdit(
                    to: to,
                    cc: cc,
                    subject: subject,
                    body: body,
                    request: composeRequest,
                    mode: "edit_new",
                    db: ctx.db,
                    composeEdit: composeEdit
                )
                generatedSubject = result.subject ?? generatedSubject
                generatedBody = result.body ?? generatedBody
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[EmailComposeTool] AI generated: subject=\(generatedSubject?.prefix(60) ?? "nil") bodyLen=\(generatedBody?.count ?? 0)") }
            } catch {
                BackgroundSyncLogger.logDebug("[EmailComposeTool] performInlineEdit failed: \(error) — opening compose with original content")
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
    /// Used by the email_compose (mode "edit_new") and email_forward (mode "edit_forward") tools
    /// for full TB parity. email_reply (mode "edit_reply") builds the same context with
    /// `ComposeEditContext.make`, as the compose card does.
    static func runComposeEdit(
        to: [String],
        cc: [String],
        subject: String?,
        body: String?,
        request: String,
        mode: String,
        relatedHeader: MessageHeader? = nil,
        relatedBodyText: String? = nil,
        db: (any DatabaseReader & Sendable)? = nil,
        composeEdit: EmailReplyTool.ComposeEdit
    ) async throws -> InlineEditResult {
        let dbReader = db ?? AppDatabase.rawPool
        // Get sender info from primary account (matching TB's user identity
        // resolution). Demo boundary (ADR-IOS-038): in demo, compose MUST use
        // the demo account — during debug-menu coexistence the real primary is
        // ALSO isPrimary, so an unscoped lookup could pick (and send via) the
        // real account. Normal mode excludes the demo row symmetrically.
        let demoActive = DemoModeStore.isDemoActive
        let account: Account? = try? await dbReader.read { db in
            if demoActive {
                return try Account
                    .filter(Column("id") == DemoSeed.demoAccountId && Column("isActive") == true)
                    .fetchOne(db)
            }
            if let primary = try Account
                .filter(Column("isActive") == true && Column("isPrimary") == true)
                .filter(Column("id") != DemoSeed.demoAccountId)
                .fetchOne(db) {
                return primary
            }
            return try Account
                .filter(Column("isActive") == true)
                .filter(Column("id") != DemoSeed.demoAccountId)
                .fetchOne(db)
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

        // Each recipient keeps its role: `recipients` (recipients_json) is the To list, as in
        // TB's buildComposeEditChat, and Cc goes to ccRecipients (original_cc), so the AI
        // does not address a copied recipient as a primary one.
        // Recipients may be mailbox text (`Name <email>`); give the AI the addresses and
        // their names separately, as ComposeView's own edit context does.
        let toEntry = RecipientEntry(to)
        let ccEntry = RecipientEntry(cc)
        let context = ComposeEditContext(
            recipients: toEntry.addresses,
            toRecipients: toEntry.addresses,
            ccRecipients: ccEntry.addresses,
            bccRecipients: [],
            toDisplayNames: Self.displayNames(toEntry),
            ccDisplayNames: Self.displayNames(ccEntry),
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

        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[EmailComposeTool] runComposeEdit: mode=\(mode) to=\(to.count) cc=\(cc.count) request=\(request.prefix(80))") }

        return try await composeEdit(context, subject ?? "", body ?? "", request)
    }

    // MARK: - Helpers

    /// Display names by address, for the entry's recipients that carry one.
    static func displayNames(_ entry: RecipientEntry) -> [String: String] {
        var names: [String: String] = [:]
        for recipient in entry.recipients {
            if let name = recipient.name, !name.isEmpty { names[recipient.address] = name }
        }
        return names
    }

    /// Parse a JSON value as a string array.
    /// Handles: array of strings, array of `{"name": "...", "email": "..."}` objects (tool
    /// schema format), or a single string. An object item becomes `Name <email>` when it
    /// carries a name, else the bare `email`.
    static func parseStringArray(_ value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case .array(let arr):
            let strings = arr.compactMap { item -> String? in
                if case .string(let s) = item { return s }
                if case .dictionary(let dict) = item,
                   case .string(let email) = dict["email"], !email.isEmpty {
                    // Keep the display name the model gave, as TB's compose draft does
                    // (`name <email>`), rendered as a mailbox `RecipientEntry` reads back.
                    var name: String?
                    if case .string(let n) = dict["name"] {
                        let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
                        name = trimmed.isEmpty ? nil : trimmed
                    }
                    return RecipientEntry.text(name: name, address: email)
                }
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
