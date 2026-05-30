/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Manages post-chat KB refinement, matching TB's `knowledgebase.js`.
/// When a chat session ends (idle > 30s), session turns are sent to the backend
/// with `system_prompt_kb_refine` to extract useful facts into the KB.
///
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
actor KBRefinementService {
    static let shared = KBRefinementService()

    private let backendClient = BackendClient()

    /// Minimum exchanges (user+assistant pairs) before triggering refinement.
    /// Matches TB's `KB_PERIODIC.minPendingExchanges`.
    private static let minExchanges = 3

    /// Whether a refinement is currently in progress (serialized execution).
    private var isRunning = false

    // MARK: - Public API

    /// Refine the KB with turns from a completed chat session.
    /// Matches TB's `kbUpdate(conversationHistory)`.
    /// Fire-and-forget safe — logs errors internally.
    func refineKB(sessionTurns: [ChatTurn]) async {
        // Respect privacy opt-out (matches AIService.disableLLMCalls check)
        guard !AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey) else {
            print("[KBRefine] Skipped — AI calls disabled (privacy opt-out)")
            return
        }

        // Filter to meaningful messages (user + assistant only, skip structural turns)
        let meaningful = sessionTurns.filter { turn in
            (turn.role == "user" || turn.role == "assistant") && turn.type == "normal"
        }

        // Count exchanges (user+assistant pairs)
        let exchangeCount = meaningful.filter { $0.role == "user" }.count
        guard exchangeCount >= Self.minExchanges else {
            print("[KBRefine] Only \(exchangeCount) exchanges (min \(Self.minExchanges)), skipping")
            return
        }

        // Serialize: skip if already running
        guard !isRunning else {
            print("[KBRefine] Already running, skipping")
            return
        }
        isRunning = true
        defer { isRunning = false }

        print("[KBRefine] Starting KB refinement (\(meaningful.count) messages, \(exchangeCount) exchanges)")

        // Build chat history text from session turns (matches TB's format)
        let chatHistory = buildChatHistory(from: meaningful)

        // Get current KB text
        let currentKB = PromptStore.kbTextSnapshot()

        // Build system message matching TB's system_prompt_kb_refine format
        let currentTime = AIService.formatTimestampForAgent(Date())
        let systemMessage = CompletionsMessage(
            role: "system",
            content: "system_prompt_kb_refine",
            vars: [
                "current_user_kb_md": .string(currentKB),
                "chat_history": .string(chatHistory),
                "current_time": .string(currentTime),
                "reminder_retention_days": .int(14),
                "max_bullets": .int(200),
            ]
        )

        let request = CompletionsRequest(
            messages: [systemMessage],
            client_timezone: TimeZone.current.identifier,
            disable_tools: true
        )

        // Send to backend (BackendClient.sendCompletions has its own 120s timeout)
        let startTime = Date()
        do {
            let response = try await backendClient.sendCompletionsDirect(request)

            let duration = Date().timeIntervalSince(startTime)
            print("[KBRefine] Backend responded in \(String(format: "%.1f", duration))s")

            if let error = response.error, !error.isEmpty {
                print("[KBRefine] Backend error: \(error)")
                return
            }

            guard let refinedKB = response.refined_kb else {
                print("[KBRefine] No refined_kb in response")
                return
            }

            // 3-way merge: treat refinement as a "remote" change.
            // base = KB snapshot before backend call (currentKB)
            // local = current KB (may have changed via sync/tools during the flight)
            // remote = refined KB from backend
            let currentKBNow = PromptStore.kbTextSnapshot()
            let mergedKB = PromptParser.mergeFlatField(base: currentKB, local: currentKBNow, remote: refinedKB)

            if mergedKB == currentKBNow {
                print("[KBRefine] KB unchanged after 3-way merge")
                return
            }

            print("[KBRefine] KB updated via 3-way merge (\(currentKBNow.count) → \(mergedKB.count) chars)")

            // Persist merged KB — this triggers Device Sync broadcast + UI reactivity via PromptStore.rawKB didSet.
            // PromptStore.rawKB didSet also triggers reminder re-parse via .onChange(of: rawKB) in DynamicIslandChat,
            // which calls ReminderBuilder.getRandomReminders() (parses KB reminders on demand).
            await MainActor.run {
                PromptStore.shared.rawKB = mergedKB
            }

            print("[KBRefine] KB refinement complete (changed=true)")
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            print("[KBRefine] Failed after \(String(format: "%.1f", duration))s: \(error)")
        }
    }

    // MARK: - Private

    /// Build [USER]/[AGENT] chat history text from session turns.
    /// Matches TB's format in `_kbUpdateImpl`.
    private func buildChatHistory(from turns: [ChatTurn]) -> String {
        var parts: [String] = []

        for turn in turns {
            switch turn.role {
            case "user":
                if let userMessage = turn.userMessage, !userMessage.isEmpty {
                    parts.append("[USER]: \(userMessage)")
                }
            case "assistant":
                if !turn.content.isEmpty {
                    parts.append("[AGENT]: \(turn.content)")
                }
            default:
                break
            }
        }

        return parts.joined(separator: "\n\n")
    }
}
