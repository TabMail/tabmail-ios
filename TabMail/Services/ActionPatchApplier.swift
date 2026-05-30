/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Applies ADD/DEL patches to user_action.md content.
/// Port of TB addon's `patchApplier.js` — exact same parsing and application logic.
///
/// Patch format (from backend `system_prompt_action_refine`):
/// ```
/// ADD
/// archive
/// Company newsletters about conference announcements.
/// DEL
/// reply
/// Emails that are clearly informational.
/// ```
enum ActionPatchApplier {

    // MARK: - Public

    /// Apply an action rules patch with multiple ADD/DEL operations.
    /// Returns the updated content, or nil if parsing/application failed.
    static func applyActionPatch(content: String, patchText: String) -> String? {
        let operations = PatchApplierUtils.parseOperations(patchText, hasActionType: true)

        guard !operations.isEmpty else {
            print("[PatchApplier] No valid action operations found in patch")
            return nil
        }

        print("[PatchApplier] Processing \(operations.count) action operation(s)")

        var current = content
        for op in operations {
            print("[PatchApplier] Applying \(op.operation) for \(op.actionType ?? ""): \(String(op.content.prefix(50)))...")
            guard let updated = applySingleOperation(content: current, operation: op.operation, contentText: op.content, actionType: op.actionType ?? "") else {
                print("[PatchApplier] Failed to apply \(op.operation) operation")
                return nil
            }
            current = updated
        }

        return current
    }

    // MARK: - Application

    /// Apply a single ADD or DEL operation.
    private static func applySingleOperation(content: String, operation: String, contentText: String, actionType: String) -> String? {
        // Validate action type
        let validTypes = ["delete", "archive", "reply", "none"]
        guard validTypes.contains(actionType) else {
            print("[PatchApplier] Invalid action type: \(actionType)")
            return nil
        }

        guard !contentText.isEmpty else {
            print("[PatchApplier] Empty content text")
            return nil
        }

        let normalizedContent = PatchApplierUtils.normalizeContent(contentText)
        var contentLines = content.components(separatedBy: "\n")

        if operation == "ADD" {
            // Check for duplicates
            if PatchApplierUtils.isDuplicate(contentLines: contentLines, normalizedContent: normalizedContent) {
                print("[PatchApplier] Duplicate content detected, skipping: \(normalizedContent)")
                return content
            }

            // Find section header
            let sectionHeader = "# Emails to be marked as `\(actionType)` (DO NOT EDIT/DELETE THIS SECTION HEADER)"
            var sectionIndex = -1
            for i in 0..<contentLines.count {
                if contentLines[i].trimmingCharacters(in: .whitespaces) == sectionHeader {
                    sectionIndex = i
                    break
                }
            }

            guard sectionIndex >= 0 else {
                print("[PatchApplier] Section not found: \(sectionHeader)")
                return nil
            }

            // Find end of section (before next section header or end)
            var insertIndex = sectionIndex + 1
            for i in (sectionIndex + 1)..<contentLines.count {
                let line = contentLines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("# ") && line.contains("Emails to be marked as") {
                    break
                }
                if line.hasPrefix("- ") {
                    insertIndex = i + 1
                }
            }

            contentLines.insert(normalizedContent, at: insertIndex)

        } else if operation == "DEL" {
            // Find and remove the specific content (case-insensitive)
            let normalizedForComparison = normalizedContent.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)

            var contentRemoved = false
            for i in 0..<contentLines.count {
                guard contentLines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- ") else { continue }

                var lineForComparison = contentLines[i].trimmingCharacters(in: .whitespaces).lowercased()
                lineForComparison = lineForComparison.replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)

                if lineForComparison == normalizedForComparison {
                    contentLines.remove(at: i)
                    contentRemoved = true
                    print("[PatchApplier] Successfully removed content: \(contentLines.count) lines remaining")
                    break
                }
            }

            if !contentRemoved {
                print("[PatchApplier] Content not found for deletion: \(normalizedContent)")
                return nil
            }
        }

        return contentLines.joined(separator: "\n")
    }
}
