/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Main app's SummaryResult — wraps the shared AIResponseParser.SummaryResult.
/// Conforms to Sendable for async processing in the main app.
struct SummaryResult: Sendable {
    let blurb: String?
    let todos: String?
    let reminderDate: String?
    let reminderTime: String?
    let reminderContent: String?

    init(blurb: String?, todos: String?, reminderDate: String?, reminderTime: String?, reminderContent: String?) {
        self.blurb = blurb; self.todos = todos
        self.reminderDate = reminderDate; self.reminderTime = reminderTime; self.reminderContent = reminderContent
    }

    init(from shared: AIResponseParser.SummaryResult) {
        self.blurb = shared.blurb; self.todos = shared.todos
        self.reminderDate = shared.reminderDate; self.reminderTime = shared.reminderTime; self.reminderContent = shared.reminderContent
    }
}

extension AIService {

    // MARK: - Summary Generation

    func generateSummary(
        subject: String,
        from: String,
        fromAddress: String,
        date: Date,
        bodyText: String,
        htmlContent: String?,
        userName: String,
        kbText: String
    ) async throws -> SummaryResult {
        guard !disableLLMCalls else {
            return SummaryResult(blurb: nil, todos: nil, reminderDate: nil, reminderTime: nil, reminderContent: nil)
        }

        // Shared prompt variable assembly (single source of truth — also used by NSE).
        let metadata = MessageMetadata(
            providerMessageId: "", threadId: nil, rfc822MessageId: nil,
            inReplyTo: nil, references: [],
            from: EmailAddress(name: from, email: fromAddress),
            to: [], cc: [], bcc: [], replyTo: nil,
            subject: subject, date: date, snippet: "",
            isRead: false, isFlagged: false, hasAttachments: false,
            providerLabels: [],
            folderPath: nil
        )
        let body = RenderedBody(
            htmlContent: htmlContent, textContent: bodyText,
            attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
        )
        let account = AccountContext(userName: userName, kbText: kbText, actionPrompt: "")
        let rawVars = PromptVariables.summaryVariables(metadata: metadata, body: body, account: account)
        let vars: [String: JSONValue] = rawVars.mapValues { JSONValue.fromAny($0) }

        let message = CompletionsMessage(
            role: "system",
            content: "system_prompt_summary",
            vars: vars
        )

        let timezone = TimeZone.current.identifier
        let request = CompletionsRequest(
            messages: [message],
            client_timezone: timezone,
            disable_tools: false  // TB sends disableTools: false for summary (tools enabled)
        )

        if DebugModeManager.isLoggingEnabled() { print("[AIService] Summary payload: subject=\(subject.prefix(60)), from=\(from.prefix(40)), date=\(rawVars["email_date"] ?? "?"), body.len=\(bodyText.count), noReply=\(rawVars["is_noreply_address"] ?? "?"), unsub=\(rawVars["has_unsubscribe_link"] ?? "?")") }

        // Single attempt — failed messages stay unprocessed and get re-queued
        // on the next sync cycle (natural retry via queue loop).
        let llmT0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Summary LLM START (body.len=\(bodyText.count))")
        let response = try await backend.sendCompletions(request)
        let llmElapsed = Int((CFAbsoluteTimeGetCurrent() - llmT0) * 1000)
        BackgroundSyncLogger.logAIProcessing("Summary LLM END in \(llmElapsed)ms")

        guard let rawText = response.assistant else {
            print("[AIService] Summary: no assistant text in response")
            return SummaryResult(blurb: nil, todos: nil, reminderDate: nil, reminderTime: nil, reminderContent: nil)
        }

        // Match TB: normalizeUnicode(json.assistant.trim()) before parsing
        let text = Self.normalizeUnicode(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        return parseSummaryResponse(text)
    }

    // MARK: - Response Parsing

    /// Delegates to shared AIResponseParser — single source of truth for both main app and NSE.
    func parseSummaryResponse(_ text: String) -> SummaryResult {
        SummaryResult(from: AIResponseParser.parseSummaryResponse(text))
    }
}
