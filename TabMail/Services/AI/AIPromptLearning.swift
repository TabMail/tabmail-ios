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

        // Read compaction threshold from UserDefaults; fall back to default if unset
        // (integer(forKey:) returns 0 when unset, which would be an invalid threshold)
        let compactThreshold = UserDefaults.standard.object(forKey: PromptStore.actionCompactThresholdKey) as? Int
            ?? PromptStore.defaultActionCompactThreshold
        let compactThresholdChars = UserDefaults.standard.object(forKey: PromptStore.actionCompactThresholdCharsKey) as? Int
            ?? PromptStore.defaultActionCompactThresholdChars
        if DebugModeManager.isLoggingEnabled() {
            print("[AIService] autoUpdatePrompt: action_compact_threshold=\(compactThreshold) action_compact_threshold_chars=\(compactThresholdChars)")
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
            "action_compact_threshold": .int(compactThreshold),
            "action_compact_threshold_chars": .int(compactThresholdChars),
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

            // Persist updated guidelines — must happen on MainActor since PromptStore is @MainActor.
            // Demo guard (ADR-IOS-038): a refine dispatched before demo entry can
            // complete during demo — saving would write into the demo overlay
            // (discarded on exit). Drop instead.
            let beforeLen = currentUserActionMd.count
            let afterLen = updated.count
            await MainActor.run {
                guard !DemoModeStore.shared.isActive else {
                    print("[AIService] autoUpdatePrompt: dropped — demo mode became active mid-flight")
                    return
                }
                PromptStore.shared.rawAction = updated
                print("[AIService] autoUpdatePrompt: SUCCESS user_action.md updated (before=\(beforeLen) after=\(afterLen))")
            }

        } catch {
            print("[AIService] autoUpdatePrompt: ERROR \(error)")
        }
    }

    // MARK: - Manual Compact Action Rules

    /// Result type for compactActionRulesNow.
    enum CompactResult {
        case applied(opsCount: Int)
        case nothingToCompact
        case skipped(reason: String)
        case failed(message: String)
    }

    /// Manually trigger a compact-only action-rules refinement.
    /// Sends `action_compact_only: true` so the backend runs compaction only,
    /// bypassing thresholds, and returns patch ops or an empty patch when nothing
    /// is mergeable. Fire-and-return — returns a CompactResult describing what happened.
    func compactActionRulesNow() async -> CompactResult {
        if DebugModeManager.isLoggingEnabled() {
            print("[AIService] compactActionRules: START disableLLM=\(disableLLMCalls)")
        }

        // Skip if LLM calls are disabled
        guard !disableLLMCalls else {
            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] compactActionRules: SKIP LLM disabled")
            }
            return .skipped(reason: "AI is disabled")
        }

        // Read current snapshot (nonisolated, safe from actor)
        let currentUserActionMd = PromptStore.actionMarkdownSnapshot()

        // Skip if user_action.md is empty
        guard !currentUserActionMd.isEmpty else {
            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] compactActionRules: SKIP user_action.md empty")
            }
            return .skipped(reason: "No action rules to compact")
        }

        // Read both thresholds from UserDefaults (same nil-object pattern as autoUpdateUserPromptOnTag)
        let compactThreshold = UserDefaults.standard.object(forKey: PromptStore.actionCompactThresholdKey) as? Int
            ?? PromptStore.defaultActionCompactThreshold
        let compactThresholdChars = UserDefaults.standard.object(forKey: PromptStore.actionCompactThresholdCharsKey) as? Int
            ?? PromptStore.defaultActionCompactThresholdChars

        if DebugModeManager.isLoggingEnabled() {
            print("[AIService] compactActionRules: threshold=\(compactThreshold) thresholdChars=\(compactThresholdChars) mdLen=\(currentUserActionMd.count)")
        }

        // Build compact-only request: action_compact_only=true, email-metadata as empty strings
        let vars: [String: JSONValue] = [
            "current_user_action_md": .string(currentUserActionMd),
            "action_compact_threshold": .int(compactThreshold),
            "action_compact_threshold_chars": .int(compactThresholdChars),
            "action_compact_only": .bool(true),
            // Email-metadata fields expected by the template — empty for compact-only path
            "subject": .string(""),
            "from_sender": .string(""),
            "summary_blurb": .string(""),
            "todos": .string(""),
            "original_agent_action": .string(""),
            "original_user_action_prompt": .string(""),
            "user_manual_tag": .string(""),
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

        if DebugModeManager.isLoggingEnabled() {
            print("[AIService] compactActionRules: sending compact-only request to backend")
        }

        do {
            // longTimeout: compacting a large user_action.md (20K+ chars observed)
            // legitimately runs for minutes — the default 120s resource cap killed
            // it with NSURLError -1001.
            let response = try await backend.sendCompletionsDirect(request, longTimeout: true)
            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] compactActionRules: backend responded, assistant=\(response.assistant?.prefix(200) ?? "nil")")
            }

            guard let assistantText = response.assistant, !assistantText.isEmpty else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: FAIL empty response")
                }
                return .failed(message: "Empty response from server")
            }

            // Parse strict JSON: { "patch": "...", "reason": "<code>"? }
            guard let parsed = Self.parseCompactResponse(assistantText) else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: FAIL no patch in response. Raw: \(assistantText.prefix(300))")
                }
                return .failed(message: "Could not parse server response")
            }
            let patchText = parsed.patch

            // Empty patch: the backend reports WHY via the reason code so a
            // discarded merge (guard trip, non-applying ops) is distinguishable
            // from a genuinely clean rules file.
            guard !patchText.isEmpty else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: empty patch, reason=\(parsed.reason ?? "none")")
                }
                switch parsed.reason {
                case "guard_char_retention", "guard_pure_delete":
                    return .skipped(reason: "Merge discarded by safety check — try again")
                case "no_ops_applied", "no_ops_parsed":
                    return .skipped(reason: "Merge didn't match current rules — try again")
                case "parse_failed", "llm_error":
                    return .failed(message: "Model response unusable — try again")
                default:
                    return .nothingToCompact
                }
            }

            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] compactActionRules: parsed patch:\n\(patchText)")
            }

            // Drift guard: re-read snapshot; if changed since we started, abort.
            let latestActionMd = PromptStore.actionMarkdownSnapshot()
            guard latestActionMd == currentUserActionMd else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: SKIP prompt changed concurrently (was \(currentUserActionMd.count) now \(latestActionMd.count))")
                }
                return .skipped(reason: "Rules changed while compacting — try again")
            }

            // Apply the patch
            guard let updated = ActionPatchApplier.applyActionPatch(content: currentUserActionMd, patchText: patchText) else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: FAIL patch application failed")
                }
                return .failed(message: "Could not apply compaction patch")
            }

            guard updated != currentUserActionMd else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: patch produced no change")
                }
                return .nothingToCompact
            }

            // Count applied operations (DEL lines in the patch indicate merged/removed rules)
            let opsCount = patchText.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) == "DEL" || $0.trimmingCharacters(in: .whitespaces) == "ADD" }
                .count

            // Persist on MainActor; demo guard mirrors autoUpdateUserPromptOnTag.
            // The closure returns whether the persist actually happened so the
            // caller never reports "Merged N rules" for a demo-dropped write.
            let beforeLen = currentUserActionMd.count
            let afterLen = updated.count
            let persisted = await MainActor.run { () -> Bool in
                guard !DemoModeStore.shared.isActive else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[AIService] compactActionRules: dropped — demo mode became active mid-flight")
                    }
                    return false
                }
                PromptStore.shared.rawAction = updated
                if DebugModeManager.isLoggingEnabled() {
                    print("[AIService] compactActionRules: SUCCESS user_action.md updated (before=\(beforeLen) after=\(afterLen) ops=\(opsCount))")
                }
                return true
            }

            guard persisted else {
                return .skipped(reason: "Demo mode active")
            }
            return .applied(opsCount: opsCount)

        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] compactActionRules: ERROR \(error)")
            }
            return .failed(message: error.localizedDescription)
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

    /// Parse a compact-only response: { "patch": "...", "reason": "<code>"? }.
    /// The backend attaches a machine-readable reason to empty-patch exits so
    /// discarded merges are distinguishable from a genuinely clean file
    /// (guard trip / non-applying ops / model failure). Extra keys are ignored
    /// by older parsers, so this stays backward/forward compatible.
    static func parseCompactResponse(_ text: String) -> (patch: String, reason: String?)? {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences (same handling as parsePatchResponse)
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonString = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct CompactResponse: Decodable {
            let patch: String
            let reason: String?
        }

        guard let parsed = try? JSONDecoder().decode(CompactResponse.self, from: data) else {
            if DebugModeManager.isLoggingEnabled() {
                print("[AIService] Failed to parse compact JSON: \(jsonString.prefix(200))")
            }
            return nil
        }

        return (parsed.patch.trimmingCharacters(in: .whitespacesAndNewlines), parsed.reason)
    }
}
