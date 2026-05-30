/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension AIService {

    // MARK: - Action Classification

    func classifyAction(
        subject: String,
        from: String,
        fromAddress: String,
        bodyText: String,
        htmlContent: String?,
        summary: SummaryResult,
        userName: String,
        actionPrompt: String
    ) async throws -> ActionTag? {
        guard !disableLLMCalls else { return nil }

        // Shared prompt variable assembly (single source of truth — also used by NSE).
        let metadata = MessageMetadata(
            providerMessageId: "", threadId: nil, rfc822MessageId: nil,
            inReplyTo: nil, references: [],
            from: EmailAddress(name: from, email: fromAddress),
            to: [], cc: [], bcc: [], replyTo: nil,
            subject: subject, date: Date(), snippet: "",
            isRead: false, isFlagged: false, hasAttachments: false,
            providerLabels: [],
            folderPath: nil
        )
        let body = RenderedBody(
            htmlContent: htmlContent, textContent: bodyText,
            attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
        )
        let account = AccountContext(userName: userName, kbText: "", actionPrompt: actionPrompt)
        let summaryCtx = SummaryContext(blurb: summary.blurb, todos: summary.todos)
        let rawVars = PromptVariables.actionVariables(
            metadata: metadata, body: body, summary: summaryCtx, account: account
        )
        let vars: [String: JSONValue] = rawVars.mapValues { JSONValue.fromAny($0) }
        let isNoReply = EmailFilter.isNoReply(fromAddress)
        let hasUnsubscribe = EmailFilter.hasUnsubscribeLink(htmlContent)

        let message = CompletionsMessage(
            role: "system",
            content: "system_prompt_action",
            vars: vars
        )

        let request = CompletionsRequest(
            messages: [message],
            client_timezone: nil,
            disable_tools: true
        )

        if DebugModeManager.isLoggingEnabled() { print("[AIService] Action payload: subject=\(subject.prefix(60)), from=\(from.prefix(40)), body.len=\(bodyText.count), noReply=\(isNoReply), unsub=\(hasUnsubscribe), todo=\((summary.todos ?? "N/A").prefix(60)), summary=\((summary.blurb ?? "N/A").prefix(60))") }

        // Single attempt — natural retry via queue loop on next sync cycle.
        let llmT0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Action LLM START")
        let response = try await backend.sendCompletions(request)
        let llmElapsed = Int((CFAbsoluteTimeGetCurrent() - llmT0) * 1000)
        BackgroundSyncLogger.logAIProcessing("Action LLM END in \(llmElapsed)ms")
        guard let text = response.assistant, let tag = Self.parseActionResponse(text) else {
            if DebugModeManager.isLoggingEnabled() { print("[AIService] Action: no valid action from LLM response. Raw: \(response.assistant?.prefix(200) ?? "nil")") }
            return nil
        }
        return tag
    }

    // MARK: - Response Parsing

    /// Delegates to shared AIResponseParser — single source of truth for both main app and NSE.
    static func parseActionResponse(_ text: String) -> ActionTag? {
        guard let raw = AIResponseParser.parseActionTag(from: text) else {
            if DebugModeManager.isLoggingEnabled() { print("[AIService] No action field found in response: \(text.prefix(200))") }
            return nil
        }
        return ActionTag(rawValue: raw)
    }
}
