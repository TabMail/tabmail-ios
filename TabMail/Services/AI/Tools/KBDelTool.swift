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
            print("[KBDelTool] Missing or empty 'statement'")
            return #"{"error": "missing statement"}"#
        }

        let statement = AIService.normalizeUnicode(raw).trimmingCharacters(in: .whitespaces)
        guard !statement.isEmpty else {
            print("[KBDelTool] Empty statement after normalization")
            return #"{"error": "missing statement"}"#
        }

        print("[KBDelTool] Starting with statement='\(statement.prefix(140))' len=\(statement.count)")

        // Load current KB
        let current = PromptStore.kbTextSnapshot()
        if current.isEmpty {
            print("[KBDelTool] Knowledge base is empty")
            return #"{"error": "knowledge base is empty"}"#
        }

        let patchText = "DEL\n\(statement)"

        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else {
            print("[KBDelTool] applyKBPatch returned nil")
            return #"{"error": "failed to delete from knowledge base (statement not found)"}"#
        }

        if updated == current {
            print("[KBDelTool] No-op (statement not found)")
            return #"{"error": "statement not found in knowledge base"}"#
        }

        // Persist — Device Sync triggers automatically via PromptStore's rawKB didSet
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[KBDelTool] Persisted user_kb.md (\(updated.count) chars)")

        print("[KBDelTool] Success")
        return "Removed from knowledge base."
    }
}
