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
        actionCapture: PromptCapture
    ) async {
        // user_action.md as read before the backend call, and the labels it shows: the patch deletes
        // only those whose text it removes (DS-CAPTURE).
        let currentUserActionMd = actionCapture.text
        BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: START original=\(originalAction) userTag=\(userManualTag)")
        BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: subject=\(subject.prefix(60)) from=\(from.prefix(40))")
        BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: blurb=\(summaryBlurb?.prefix(80) ?? "nil") todos=\(summaryTodos?.prefix(80) ?? "nil")")
        BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: actionMdLen=\(currentUserActionMd.count) disableLLM=\(disableLLMCalls)")

        // Skip if original action matches user's tag (no disagreement)
        guard originalAction != userManualTag else {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: SKIP original == user tag (\(userManualTag))")
            return
        }

        // Skip if no summary cached (can't generate meaningful patch)
        guard let blurb = summaryBlurb, !blurb.isEmpty else {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: SKIP no summary cached")
            return
        }

        // Skip if user_action.md is empty
        guard !currentUserActionMd.isEmpty else {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: SKIP user_action.md empty")
            return
        }

        // Skip if LLM calls are disabled
        guard !disableLLMCalls else {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: SKIP LLM disabled")
            return
        }

        // Effective thresholds (defaults, legacy-default migration and range clamp applied)
        let actionConfig = ActionCompactConfig.local()
        let compactThreshold = actionConfig.compactThreshold ?? PromptStore.defaultActionCompactThreshold
        let compactThresholdChars = actionConfig.compactThresholdChars ?? PromptStore.defaultActionCompactThresholdChars
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: action_compact_threshold=\(compactThreshold) action_compact_threshold_chars=\(compactThresholdChars)")
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

        BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: sending request to backend (prompt=system_prompt_action_refine)")

        do {
            let response = try await backend.sendCompletionsDirect(request)
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: backend responded, assistant=\(response.assistant?.prefix(200) ?? "nil")")

            guard let assistantText = response.assistant, !assistantText.isEmpty else {
                BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: FAIL LLM returned empty response")
                return
            }

            // Parse strict JSON: { "patch": "..." }
            guard let patchText = Self.parsePatchResponse(assistantText), !patchText.isEmpty else {
                BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: FAIL no patch in response. Raw: \(assistantText.prefix(300))")
                return
            }

            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: parsed patch:\n\(patchText)")

            // Apply the patch to current user_action.md
            guard let updated = ActionPatchApplier.applyActionPatch(content: currentUserActionMd, patchText: patchText) else {
                BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: FAIL patch application failed")
                return
            }

            guard !Bullets.same(updated, currentUserActionMd) else {
                BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: patch produced no change")
                return
            }

            // Persist the updated guidelines against the captured labels in a second hold of the prompt
            // store: refused with nothing written when the counter moved since the read (an edit,
            // a synced change, a reset or a restore) or demo mode started
            // or ended (ADR-IOS-038), and the patch is dropped.
            let beforeLen = currentUserActionMd.count
            let afterLen = updated.count
            let outcome = await PromptStore.shared.writeAfterRead(actionCapture, text: updated, "action-rule refine")
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: user_action.md \(outcome) (before=\(beforeLen) after=\(afterLen))")

        } catch {
            BackgroundSyncLogger.logDebug("[AIService] autoUpdatePrompt: ERROR \(error)")
        }
    }

    // MARK: - Manual Compact Action Rules

    /// What the person is told of a compaction's read or write. Dropped: the rules changed while it
    /// ran (an edit, a synced rule, a reset, sign-out or another account), so nothing was saved.
    nonisolated static func compactResult(_ outcome: PromptEditOutcome, opsCount: Int) -> CompactResult {
        switch outcome {
        case .saved: return .applied(opsCount: opsCount)
        case .unchanged: return .nothingToCompact
        case .unsaved: return .failed(message: "The rules could not be saved")
        case .dropped: return .skipped(reason: "Rules changed while compacting — try again")
        case .busy: return .skipped(reason: "Rules are busy — try again in a moment")
        }
    }

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
    /// is mergeable. Fire-and-return — returns a CompactResult describing what happened. The tap passes the
    /// `entered` demo-switch count it took before it made the task that calls this (DS-DEMO).
    func compactActionRulesNow(entered: Int? = nil) async -> CompactResult {
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[AIService] compactActionRules: START disableLLM=\(disableLLMCalls)")
        }

        // Skip if LLM calls are disabled
        guard !disableLLMCalls else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: SKIP LLM disabled")
            }
            return .skipped(reason: "AI is disabled")
        }

        // Current user_action.md, and the labels it shows, read in one brief hold of the prompt store
        //: the patch deletes only those whose text it removes (DS-CAPTURE).
        let actionCapture: PromptCapture
        switch await PromptStore.shared.readBeforeAI(.action, "compact action rules", entered: entered) {
        case .read(let capture): actionCapture = capture
        case .refused(let outcome): return Self.compactResult(outcome, opsCount: 0)
        }
        let currentUserActionMd = actionCapture.text

        // Skip if user_action.md is empty
        guard !currentUserActionMd.isEmpty else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: SKIP user_action.md empty")
            }
            return .skipped(reason: "No action rules to compact")
        }

        // Effective thresholds (same source as autoUpdateUserPromptOnTag)
        let actionConfig = ActionCompactConfig.local()
        let compactThreshold = actionConfig.compactThreshold ?? PromptStore.defaultActionCompactThreshold
        let compactThresholdChars = actionConfig.compactThresholdChars ?? PromptStore.defaultActionCompactThresholdChars

        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[AIService] compactActionRules: threshold=\(compactThreshold) thresholdChars=\(compactThresholdChars) mdLen=\(currentUserActionMd.count)")
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
            BackgroundSyncLogger.logDebug("[AIService] compactActionRules: sending compact-only request to backend")
        }

        do {
            // longTimeout: compacting a large user_action.md (20K+ chars observed)
            // legitimately runs for minutes — the default 120s resource cap killed
            // it with NSURLError -1001.
            let response = try await backend.sendCompletionsDirect(request, longTimeout: true)
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: backend responded, assistant=\(response.assistant?.prefix(200) ?? "nil")")
            }

            guard let assistantText = response.assistant, !assistantText.isEmpty else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[AIService] compactActionRules: FAIL empty response")
                }
                return .failed(message: "Empty response from server")
            }

            // Parse strict JSON: { "patch": "...", "reason": "<code>"? }
            guard let parsed = Self.parseCompactResponse(assistantText) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[AIService] compactActionRules: FAIL no patch in response. Raw: \(assistantText.prefix(300))")
                }
                return .failed(message: "Could not parse server response")
            }
            let patchText = parsed.patch

            // Empty patch: the backend reports WHY via the reason code so a
            // discarded merge (guard trip, non-applying ops) is distinguishable
            // from a genuinely clean rules file.
            guard !patchText.isEmpty else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[AIService] compactActionRules: empty patch, reason=\(parsed.reason ?? "none")")
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
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: parsed patch:\n\(patchText)")
            }

            // Apply the patch
            guard let updated = ActionPatchApplier.applyActionPatch(content: currentUserActionMd, patchText: patchText) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[AIService] compactActionRules: FAIL patch application failed")
                }
                return .failed(message: "Could not apply compaction patch")
            }

            guard !Bullets.same(updated, currentUserActionMd) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[AIService] compactActionRules: patch produced no change")
                }
                return .nothingToCompact
            }

            // Count applied operations (DEL lines in the patch indicate merged/removed rules)
            let opsCount = patchText.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) == "DEL" || $0.trimmingCharacters(in: .whitespaces) == "ADD" }
                .count

            // Persist in a second hold of the prompt store, mirroring autoUpdateUserPromptOnTag: the
            // caller never reports "Merged N rules" for a dropped write.
            let beforeLen = currentUserActionMd.count
            let afterLen = updated.count
            let outcome = await PromptStore.shared.writeAfterRead(actionCapture, text: updated, "compact action rules")
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: user_action.md \(outcome) (before=\(beforeLen) after=\(afterLen) ops=\(opsCount))")
            }
            return Self.compactResult(outcome, opsCount: opsCount)

        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[AIService] compactActionRules: ERROR \(error)")
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
            BackgroundSyncLogger.logDebug("[AIService] Failed to parse patch JSON: \(jsonString.prefix(200))")
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
                BackgroundSyncLogger.logDebug("[AIService] Failed to parse compact JSON: \(jsonString.prefix(200))")
            }
            return nil
        }

        return (parsed.patch.trimmingCharacters(in: .whitespacesAndNewlines), parsed.reason)
    }
}
