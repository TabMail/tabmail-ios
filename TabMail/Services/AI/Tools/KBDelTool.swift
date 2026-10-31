/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `kb_del` tool matching TB addon's `kb_del.js`.
/// Removes a single knowledge statement from user_kb.md via KBPatchApplier.
/// Registered in `ToolRegistry` at app startup.
struct KBDelTool: AgentTool, Sendable {
    let name = "kb_del"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let raw) = arguments["statement"] else {
            BackgroundSyncLogger.logDebug("[KBDelTool] Missing or empty 'statement'")
            return #"{"error": "missing statement"}"#
        }

        let statement = AIService.normalizeUnicode(raw).trimmingCharacters(in: .whitespaces)
        guard !statement.isEmpty else {
            BackgroundSyncLogger.logDebug("[KBDelTool] Empty statement after normalization")
            return #"{"error": "missing statement"}"#
        }

        BackgroundSyncLogger.logDebug("[KBDelTool] Starting with statement='\(statement.prefix(140))' len=\(statement.count)")

        let patchText = "DEL\n\(statement)"

        // One read-change-save of the KB through the prompt store (DS-CAPTURE); the commit sends it
        // (Device Sync).
        let edit = await { @MainActor () async -> (empty: Bool, edit: KBToolEdit) in
            var empty = false
            var patched = false
            let outcome = await PromptStore.shared.edit("kb_del tool") { hold in
                try hold.editText(.kb) { current in
                    guard !current.isEmpty else {
                        empty = true
                        return nil
                    }
                    guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else { return nil }
                    patched = true
                    return updated
                }
            }
            return (empty, KBToolEdit(patched: patched, outcome: outcome))
        }()

        // Refused before the patch ran: the model is told why.
        if let refusal = KBToolEdit.refusal(edit.edit.outcome) { return refusal }

        if edit.empty {
            BackgroundSyncLogger.logDebug("[KBDelTool] Knowledge base is empty")
            return #"{"error": "knowledge base is empty"}"#
        }

        guard edit.edit.patched else {
            BackgroundSyncLogger.logDebug("[KBDelTool] applyKBPatch returned nil")
            return #"{"error": "failed to delete from knowledge base (statement not found)"}"#
        }

        switch edit.edit.outcome {
        case .saved:
            BackgroundSyncLogger.logDebug("[KBDelTool] Persisted user_kb.md")
        case .unchanged:
            BackgroundSyncLogger.logDebug("[KBDelTool] No-op (statement not found)")
            return #"{"error": "statement not found in knowledge base"}"#
        case .unsaved, .dropped, .busy:
            BackgroundSyncLogger.logDebug("[KBDelTool] Not saved (\(edit.edit.outcome))")
            return #"{"error": "failed to delete from knowledge base"}"#
        }

        BackgroundSyncLogger.logDebug("[KBDelTool] Success")
        return "Removed from knowledge base."
    }
}
