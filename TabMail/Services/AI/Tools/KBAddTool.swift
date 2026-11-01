/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `kb_add` tool matching TB addon's `kb_add.js`.
/// Appends a single knowledge statement to user_kb.md via KBPatchApplier.
/// Entries are auto-pinned ([Pinned] prefix) since kb_add is only for explicit user requests.
/// Registered in `ToolRegistry` at app startup.
struct KBAddTool: AgentTool, Sendable {
    let name = "kb_add"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // The call belongs to the mode it started in (DS-DEMO): the demo-switch count is taken before anything
        // awaits and the prompt store compares it when the call's turn comes.
        let entered = PromptStore.switchesSeen
        guard case .string(let raw) = arguments["statement"] else {
            BackgroundSyncLogger.logDebug("[KBAddTool] Missing or empty 'statement'")
            return #"{"error": "missing statement"}"#
        }

        let statement = AIService.normalizeUnicode(raw).trimmingCharacters(in: .whitespaces)
        guard !statement.isEmpty else {
            BackgroundSyncLogger.logDebug("[KBAddTool] Empty statement after normalization")
            return #"{"error": "missing statement"}"#
        }

        BackgroundSyncLogger.logDebug("[KBAddTool] Starting with statement='\(statement.prefix(140))' len=\(statement.count)")

        // Prefix with [Pinned] since kb_add is for explicit user requests (matching TB)
        let pinned = statement.hasPrefix("[Pinned]") ? statement : "[Pinned] \(statement)"
        let patchText = "ADD\n\(pinned)"

        // One read-change-save of the KB through the prompt store (DS-CAPTURE); the commit sends it
        // (Device Sync).
        let edit = await { @MainActor () async -> KBToolEdit in
            var patched = false
            let outcome = await PromptStore.shared.edit("kb_add tool", entered: entered) { hold in
                try hold.editText(.kb) { current in
                    guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else { return nil }
                    patched = true
                    return updated
                }
            }
            return KBToolEdit(patched: patched, outcome: outcome)
        }()

        // Refused before the patch ran: the model is told why.
        if let refusal = KBToolEdit.refusal(edit.outcome) { return refusal }

        guard edit.patched else {
            BackgroundSyncLogger.logDebug("[KBAddTool] applyKBPatch returned nil")
            return #"{"error": "failed to update knowledge base"}"#
        }

        switch edit.outcome {
        case .saved:
            BackgroundSyncLogger.logDebug("[KBAddTool] Persisted user_kb.md")
        case .unchanged:
            BackgroundSyncLogger.logDebug("[KBAddTool] No-op (duplicate or unchanged)")
            return "No change (duplicate or unchanged)."
        case .unsaved, .dropped, .busy:
            BackgroundSyncLogger.logDebug("[KBAddTool] Not saved (\(edit.outcome))")
            return #"{"error": "failed to update knowledge base"}"#
        }

        BackgroundSyncLogger.logDebug("[KBAddTool] Success")
        return "Added to knowledge base."
    }
}
