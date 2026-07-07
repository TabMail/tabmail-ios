/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Result from `sendChatMessage` — carries both assistant text and optional thinking.
struct ChatResponse: Sendable {
    let text: String
    let thinking: String?
}

extension AIService {

    // MARK: - Agent Chat

    /// Send a chat message through the completions API, matching TB's agentConverse flow.
    /// Uses `system_prompt_agent` + `chat_converse` prompt templates.
    /// Server-side tools (search_web, date_to_day) auto-execute in the backend.
    ///
    /// - Parameters:
    ///   - userText: The user's message
    ///   - history: Current session turns for multi-turn context (not expired/archived history)
    ///   - onSSEEvent: Optional callback for server-side tool progress (UI activity bubbles)
    /// - Returns: A ChatResponse with assistant text and optional thinking, or nil if empty/error
    func sendChatMessage(
        userText: String,
        history: [ChatTurn],
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> ChatResponse? {
        // Per-user-turn pagination cache reset — matches TB resetPaginationSessions()
        // (memory_search.js:11-16). Each user message starts a fresh turn; within that
        // turn, repeated memory_search calls with identical args advance pages via the
        // in-memory cache.
        await MemorySearchCache.shared.reset()

        guard !disableLLMCalls else {
            print("[AIService] sendChatMessage: SKIP — LLM calls disabled")
            return nil
        }

        // Demo Mode budget. One sendChatMessage call = one count,
        // regardless of how many tool rounds the backend runs internally.
        // Refund on transient failures.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        if inDemo {
            let exhausted = await MainActor.run { DemoModeStore.shared.isCallBudgetExhausted }
            guard !exhausted else {
                throw DemoError.callBudgetExhausted
            }
            await MainActor.run { DemoModeStore.shared.consumeCall() }
        }
        var didRefund = false
        defer {
            if inDemo && !didRefund { /* successful path — keep counter */ }
        }

        // Build system message matching TB's _buildSystemMessage in init.js
        let userName = Self.chatUserName()
        let kbText = PromptStore.kbTextSnapshot()

        // Build reminders JSON from message summaries + KB entries (matching TB's reminderBuilder)
        let reminders = await ReminderBuilder.buildReminderList()
        let remindersJSON = reminders.isEmpty ? "" : await ReminderBuilder.formatRemindersJSON(reminders)
        print("[AIService] sendChatMessage: \(reminders.count) reminders (\(remindersJSON.count) chars)")

        let systemMessage = CompletionsMessage(
            role: "system",
            content: "system_prompt_agent",
            vars: [
                "user_name": .string(userName),
                "user_kb_content": .string(kbText),
                "user_reminders_json": .string(remindersJSON),
                "recent_chat_history": .string(""), // Empty — multi-turn context passed as conversation messages, not in system prompt
            ]
        )

        // Convert persisted history to CompletionsMessages
        let chatStore = ChatStore.shared
        let historyMessages = await chatStore.turnsToMessages(history)

        // Build new user message matching TB's chat_converse format
        let timeStamp = Self.formatTimestampForAgent(Date())
        let userMessage = CompletionsMessage(
            role: "user",
            content: "chat_converse",
            vars: [
                "user_message": .string(userText),
                "time_stamp": .string(timeStamp),
            ]
        )

        // Assemble full messages array: system + history + new user message
        var messages = [systemMessage]
        messages.append(contentsOf: historyMessages)
        messages.append(userMessage)

        print("[AIService] sendChatMessage: \(messages.count) messages (system + \(historyMessages.count) session turns + user)")
        print("[AIService]   userName=\(userName), kbLen=\(kbText.count), userText=\(userText.prefix(60))")

        // Send via completions — server-side tools (search_web, date_to_day) auto-execute in backend
        // Uses Direct variant: agent chat is user-initiated and should not wait behind background AI.
        let response: CompletionsResponse
        do {
            response = try await sendWithToolsDirect(
                messages: messages,
                onSSEEvent: onSSEEvent,
                invocation: invocation
            )
        } catch {
            // Demo refund on transient errors.
            if inDemo, DemoModeStore.shouldRefund(for: error) {
                await MainActor.run { DemoModeStore.shared.refundCall() }
                didRefund = true
            }
            throw error
        }

        if let error = response.error {
            print("[AIService] sendChatMessage error: \(error)")
            BackgroundSyncLogger.logChatError("Server error: \(error)", userMessage: userText)
            // Refund only when error string indicates transient failure (5xx, demo throttle).
            if inDemo {
                let dummy = NSError(domain: "AIChat", code: 0, userInfo: [NSLocalizedDescriptionKey: error])
                if DemoModeStore.shouldRefund(for: dummy) {
                    await MainActor.run { DemoModeStore.shared.refundCall() }
                    didRefund = true
                }
            }
            throw ChatError.serverError(error)
        }

        guard let text = response.assistant, !text.isEmpty else {
            print("[AIService] sendChatMessage: empty response")
            BackgroundSyncLogger.logChatError("Empty assistant response from server", userMessage: userText)
            return nil
        }

        // Match TB: normalizeUnicode + trim
        let cleaned = Self.normalizeUnicode(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            print("[AIService] sendChatMessage: empty response after normalization")
            BackgroundSyncLogger.logChatError("Response empty after normalizeUnicode+trim (raw len=\(text.count))", userMessage: userText)
            return nil
        }
        print("[AIChatDebug] sendChatMessage raw response (\(cleaned.count) chars):")
        print("[AIChatDebug]   \(cleaned.prefix(300))")
        return ChatResponse(text: cleaned, thinking: response.thinking)
    }

    /// Resume an agent-chat turn that was cut off in transit (the caller caught a
    /// `ChatConnectionLostError` and kept its `resumeRequest`). Re-enters the tool
    /// loop from the preserved `conversation_state` carried in `request`, so every
    /// already-completed tool call and prior round's thinking is reused — nothing is
    /// re-executed and nothing the user typed is re-sent. This is the continuation
    /// counterpart to `sendChatMessage`; it is intentionally separate from the
    /// fork/resend pathways.
    ///
    /// Does NOT consume a Demo Mode budget call: the original `sendChatMessage`
    /// already accounted for this turn.
    func resumeChatMessage(
        request: CompletionsRequest,
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> ChatResponse? {
        guard !disableLLMCalls else {
            print("[AIService] resumeChatMessage: SKIP — LLM calls disabled")
            return nil
        }
        // Demo Mode budget: a resume re-runs the failed round, so it consumes one
        // call like a fresh turn. The original send refunded on connection-lost
        // (DemoModeStore.shouldRefund), so a resumed turn still nets exactly one
        // call. Refund here too if THIS resume attempt fails transiently.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        if inDemo {
            let exhausted = await MainActor.run { DemoModeStore.shared.isCallBudgetExhausted }
            guard !exhausted else { throw DemoError.callBudgetExhausted }
            await MainActor.run { DemoModeStore.shared.consumeCall() }
        }
        // Fresh per-turn pagination cache, matching sendChatMessage.
        await MemorySearchCache.shared.reset()

        print("[AIService] resumeChatMessage: resuming from saved conversation_state")
        // Refresh client_timestamp_ms: the saved request froze it at the failed
        // round's time, but a delayed retry should let the backend reason about
        // "now" (e.g. "what's on my calendar today"). Reconstructing via init
        // re-stamps the timestamp while preserving messages + conversation_state.
        // Matches TB, whose resume rebuilds the payload with a fresh Date.now().
        let refreshed = CompletionsRequest(
            messages: request.messages,
            client_timezone: request.client_timezone,
            disable_tools: request.disable_tools,
            web_search_enabled: request.web_search_enabled,
            conversation_state: request.conversation_state,
            byok: request.byok
        )
        let response: CompletionsResponse
        do {
            response = try await sendWithToolsDirect(request: refreshed, onSSEEvent: onSSEEvent, invocation: invocation)
        } catch {
            if inDemo, DemoModeStore.shouldRefund(for: error) {
                await MainActor.run { DemoModeStore.shared.refundCall() }
            }
            throw error
        }

        // Same post-processing as sendChatMessage (kept inline so the demo-budget
        // accounting there stays untouched).
        if let error = response.error {
            print("[AIService] resumeChatMessage error: \(error)")
            BackgroundSyncLogger.logChatError("Server error (resume): \(error)", userMessage: "(resumed)")
            throw ChatError.serverError(error)
        }
        guard let text = response.assistant, !text.isEmpty else {
            print("[AIService] resumeChatMessage: empty response")
            BackgroundSyncLogger.logChatError("Empty assistant response from server (resume)", userMessage: "(resumed)")
            return nil
        }
        let cleaned = Self.normalizeUnicode(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            print("[AIService] resumeChatMessage: empty response after normalization")
            return nil
        }
        return ChatResponse(text: cleaned, thinking: response.thinking)
    }

    /// Get the user's display name for chat system prompt.
    /// Uses the primary account's display name (matching TB's getUserName).
    /// Queries GRDB directly — safe from any isolation context.
    static func chatUserName() -> String {
        let name: String? = try? AppDatabase.dbPool.read { db in
            if let primary = try Account.filter(Column("isActive") == true && Column("isPrimary") == true).fetchOne(db) {
                return primary.displayName
            }
            return try Account.filter(Column("isActive") == true).fetchOne(db)?.displayName
        }
        return name ?? "User"
    }

    enum ChatError: Error, LocalizedError {
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .serverError(let msg): return msg
            }
        }
    }
}
