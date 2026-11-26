/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What the chat view's closed field writes from the user's own message (ADR-IOS-114 decision 10,
/// amended 2026-11-26): a reply to someone else's email, a follow-up to the user's own email, or a
/// new email. The backend's compose-text prompt reads it as `mode`.
enum ComposeTextMode: String, Sendable, CaseIterable {
    /// The email the field shows is from someone else: the email written replies to it.
    case reply = "text_reply"
    /// The email the field shows is the user's own: the email written follows it up to the same
    /// people, and never answers it.
    case followup = "text_followup"
    /// A new email's chat, with no email: a new email.
    case new = "text_new"

    /// The mode for a field on `email`: a follow-up when the user wrote it (`PromptVariables.isSentByUser`,
    /// the one rule the chat shows an email as the user's own by), else a reply.
    static func thread(sentByUser: Bool) -> ComposeTextMode {
        sentByUser ? .followup : .reply
    }

    /// The modes that carry an email as their context.
    var hasEmail: Bool { self != .new }
}

extension AIService {
    /// The chat view's closed field's request (ADR-IOS-114 decision 10, amended 2026-11-26): the
    /// email that says `userText`, the user's own message exactly as sent, in the user's style. One
    /// system message, `system_prompt_compose_text`, with no tools: the email says only what the
    /// words say. The draft it is written for is `context` (its recipients by role, the sending
    /// account, and for a reply or follow-up the email shown with its body) with `subject`. The
    /// answer is the compose edit JSON, read as every compose edit's (`runComposeEditRequest`);
    /// its `change_command` is the one-line alternative offered next, under the AI Suggestion
    /// (`ChatAlternativeLink`).
    ///
    /// The words are never wrapped in an instruction, and no AI Suggestion, edit history or
    /// request goes with them.
    func performComposeText(
        _ mode: ComposeTextMode, userText: String, subject: String, context: ComposeEditContext,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> InlineEditResult {
        guard !disableLLMCalls else {
            BackgroundSyncLogger.logDebug("[AIService] performComposeText: SKIP — LLM calls disabled")
            return Self.inlineEditWithAIOff
        }
        let request = CompletionsRequest(
            messages: [Self.composeTextMessage(mode, userText: userText, subject: subject, context: context)],
            client_timezone: TimeZone.current.identifier,
            disable_tools: true)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[AIService] performComposeText: mode=\(mode.rawValue) wordsLen=\(userText.count) subjectLen=\(subject.count)")
        }
        return try await runComposeEditRequest(request, label: "performComposeText", invocation: invocation)
    }

    /// The compose-text request's one system message. Internal so tests read its variables.
    static func composeTextMessage(
        _ mode: ComposeTextMode, userText: String, subject: String, context: ComposeEditContext
    ) -> CompletionsMessage {
        var vars: [String: JSONValue] = [
            "mode": .string(mode.rawValue),
            "user_text": .string(userText),
            "user_name": .string(context.senderName),
            "user_composition_prompt": .string(context.compositionPrompt),
            "user_kb_content": .string(context.kbText),
            "current_time": .string(formatTimestampForAgent(Date())),
            "current_subject": .string(subject),
            "original_to": .string(recipientBlock(context.toRecipients, names: context.toDisplayNames)),
            "original_cc": .string(recipientBlock(context.ccRecipients, names: context.ccDisplayNames)),
            "original_bcc": .string(recipientBlock(context.bccRecipients, names: context.bccDisplayNames)),
        ]
        if mode.hasEmail {
            let split = EmailFilter.splitMessageAndQuotes(context.bodyText)
            vars["message"] = .string(split.message)
            vars["quotes_section"] = .string(split.quotes)
            vars["related_date"] = .string(context.relatedDate)
            vars["related_subject"] = .string(context.relatedSubject)
            vars["related_from"] = .string(context.relatedFrom)
            vars["related_to"] = .string(context.relatedTo)
            vars["related_cc"] = .string(context.relatedCc)
        }
        return CompletionsMessage(role: "system", content: "system_prompt_compose_text", vars: vars)
    }
}
