/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension AIService {

    // MARK: - Auto-Update User Prompt on Manual Tag (port of TB autoUpdateUserPrompt.js)

    /// When user manually overrides an AI-assigned tag, send the disagreement to the backend
    /// for automatic refinement of user_action.md. Fire-and-forget — errors are logged, not thrown.
    /// Actor isolation provides natural serialization (matches TB's semaphore-of-1 pattern).
    func autoUpdateUserPromptOnTag(
        subject: String,
        from: String,
        summaryBlurb: String?,
        summaryTodos: String?,
        originalAction: String,
        userManualTag: String,
        currentUserActionMd: String
    ) async {
        print("[AIService] autoUpdatePrompt: START original=\(originalAction) userTag=\(userManualTag)")
        print("[AIService] autoUpdatePrompt: subject=\(subject.prefix(60)) from=\(from.prefix(40))")
        print("[AIService] autoUpdatePrompt: blurb=\(summaryBlurb?.prefix(80) ?? "nil") todos=\(summaryTodos?.prefix(80) ?? "nil")")
        print("[AIService] autoUpdatePrompt: actionMdLen=\(currentUserActionMd.count) disableLLM=\(disableLLMCalls)")

        // Skip if original action matches user's tag (no disagreement)
        guard originalAction != userManualTag else {
            print("[AIService] autoUpdatePrompt: SKIP original == user tag (\(userManualTag))")
            return
        }

        // Skip if no summary cached (can't generate meaningful patch)
        guard let blurb = summaryBlurb, !blurb.isEmpty else {
            print("[AIService] autoUpdatePrompt: SKIP no summary cached")
            return
        }

        // Skip if user_action.md is empty
        guard !currentUserActionMd.isEmpty else {
            print("[AIService] autoUpdatePrompt: SKIP user_action.md empty")
            return
        }

        // Skip if LLM calls are disabled
        guard !disableLLMCalls else {
            print("[AIService] autoUpdatePrompt: SKIP LLM disabled")
            return
        }

        // Build the system message matching TB's format for system_prompt_action_refine
        let vars: [String: JSONValue] = [
            "subject": .string(subject),
            "from_sender": .string(from),
            "summary_blurb": .string(blurb),
            "todos": .string(summaryTodos ?? ""),
            "original_agent_action": .string(originalAction),
            "original_user_action_prompt": .string(""),  // TB stores write-once per message; iOS not yet tracked
            "user_manual_tag": .string(userManualTag),
            "current_user_action_md": .string(currentUserActionMd),
        ]

        let message = CompletionsMessage(
            role: "system",
            content: "system_prompt_action_refine",
            vars: vars
        )

        let request = CompletionsRequest(
            messages: [message],
            client_timezone: nil,
            disable_tools: true
        )

        print("[AIService] autoUpdatePrompt: sending request to backend (prompt=system_prompt_action_refine)")

        do {
            let response = try await backend.sendCompletionsDirect(request)
            print("[AIService] autoUpdatePrompt: backend responded, assistant=\(response.assistant?.prefix(200) ?? "nil")")

            guard let assistantText = response.assistant, !assistantText.isEmpty else {
                print("[AIService] autoUpdatePrompt: FAIL LLM returned empty response")
                return
            }

            // Parse strict JSON: { "patch": "..." }
            guard let patchText = Self.parsePatchResponse(assistantText), !patchText.isEmpty else {
                print("[AIService] autoUpdatePrompt: FAIL no patch in response. Raw: \(assistantText.prefix(300))")
                return
            }

            print("[AIService] autoUpdatePrompt: parsed patch:\n\(patchText)")

            // Re-read current prompt — another tag correction may have mutated it during the await.
            // If it changed, skip this patch to avoid overwriting a concurrent update.
            let latestActionMd = PromptStore.actionMarkdownSnapshot()
            guard latestActionMd == currentUserActionMd else {
                print("[AIService] autoUpdatePrompt: SKIP prompt changed concurrently (was \(currentUserActionMd.count) now \(latestActionMd.count))")
                return
            }

            // Apply the patch to current user_action.md
            guard let updated = ActionPatchApplier.applyActionPatch(content: currentUserActionMd, patchText: patchText) else {
                print("[AIService] autoUpdatePrompt: FAIL patch application failed")
                return
            }

            guard updated != currentUserActionMd else {
                print("[AIService] autoUpdatePrompt: patch produced no change")
                return
            }

            // Persist updated guidelines — must happen on MainActor since PromptStore is @MainActor
            let beforeLen = currentUserActionMd.count
            let afterLen = updated.count
            await MainActor.run {
                PromptStore.shared.rawAction = updated
                print("[AIService] autoUpdatePrompt: SUCCESS user_action.md updated (before=\(beforeLen) after=\(afterLen))")
            }

        } catch {
            print("[AIService] autoUpdatePrompt: ERROR \(error)")
        }
    }

    /// Parse the backend response for a patch JSON: { "patch": "..." }
    static func parsePatchResponse(_ text: String) -> String? {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonString = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct PatchResponse: Decodable {
            let patch: String
        }

        guard let parsed = try? JSONDecoder().decode(PatchResponse.self, from: data) else {
            print("[AIService] Failed to parse patch JSON: \(jsonString.prefix(200))")
            return nil
        }

        return parsed.patch.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
