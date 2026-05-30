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
        guard case .string(let raw) = arguments["statement"] else {
            print("[KBAddTool] Missing or empty 'statement'")
            return #"{"error": "missing statement"}"#
        }

        let statement = AIService.normalizeUnicode(raw).trimmingCharacters(in: .whitespaces)
        guard !statement.isEmpty else {
            print("[KBAddTool] Empty statement after normalization")
            return #"{"error": "missing statement"}"#
        }

        print("[KBAddTool] Starting with statement='\(statement.prefix(140))' len=\(statement.count)")

        // Load current KB
        let current = PromptStore.kbTextSnapshot()

        // Prefix with [Pinned] since kb_add is for explicit user requests (matching TB)
        let pinned = statement.hasPrefix("[Pinned]") ? statement : "[Pinned] \(statement)"
        let patchText = "ADD\n\(pinned)"

        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else {
            print("[KBAddTool] applyKBPatch returned nil")
            return #"{"error": "failed to update knowledge base"}"#
        }

        if updated == current {
            print("[KBAddTool] No-op (duplicate or unchanged)")
            return "No change (duplicate or unchanged)."
        }

        // Persist — Device Sync triggers automatically via PromptStore's rawKB didSet
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[KBAddTool] Persisted user_kb.md (\(updated.count) chars)")

        print("[KBAddTool] Success")
        return "Added to knowledge base."
    }
}
