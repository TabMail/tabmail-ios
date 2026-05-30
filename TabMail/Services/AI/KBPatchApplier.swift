/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Applies ADD/DEL patch operations to knowledge base text.
/// Port of TB's `patchApplier.js` (KB mode only — no action rules).
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum KBPatchApplier {

    // MARK: - Public API

    /// Apply a KB patch (ADD/DEL operations) to existing content.
    /// Returns updated content, or nil if a DEL target was not found.
    /// Matches TB's `applyKBPatch()` in `patchApplier.js`.
    static func applyKBPatch(content: String, patchText: String) -> String? {
        let operations = PatchApplierUtils.parseOperations(patchText, hasActionType: false)

        if operations.isEmpty {
            print("[KBPatchApplier] No valid KB operations found in patch")
            return nil
        }

        print("[KBPatchApplier] Processing \(operations.count) KB operation(s)")

        var currentContent = content
        for op in operations {
            print("[KBPatchApplier] Applying KB \(op.operation): \(op.content.prefix(50))...")
            guard let result = applySingleKBOperation(content: currentContent, operation: op.operation, contentText: op.content) else {
                print("[KBPatchApplier] Failed to apply KB \(op.operation) operation")
                return nil
            }
            currentContent = result
        }

        return currentContent
    }

    // MARK: - Single Operation

    /// Apply a single KB operation (ADD or DEL).
    /// Matches TB's `applySingleOperation()` with actionType=null.
    private static func applySingleKBOperation(content: String, operation: String, contentText: String) -> String? {
        guard !contentText.isEmpty else {
            print("[KBPatchApplier] Empty content text")
            return nil
        }

        let normalizedContent = PatchApplierUtils.normalizeContent(contentText)
        var contentLines = content.components(separatedBy: "\n")

        if operation == "ADD" {
            // Check for duplicates (with Unicode normalization)
            if PatchApplierUtils.isDuplicate(contentLines: contentLines, normalizedContent: normalizedContent, unicodeNormalize: true) {
                print("[KBPatchApplier] Duplicate content detected, skipping: \(normalizedContent)")
                return content
            }

            // KB operation: append to end
            contentLines.append(normalizedContent)

        } else if operation == "DEL" {
            // Find and remove the specific content (case-insensitive with Unicode normalization)
            // Normalize by removing trailing periods from both sides for comparison
            let normalizedContentForComparison = AIService.normalizeUnicode(normalizedContent)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)

            print("[KBPatchApplier] DEL: looking for '\(normalizedContentForComparison.prefix(80))'")

            var contentRemoved = false
            for i in 0..<contentLines.count {
                var lineForComparison = AIService.normalizeUnicode(contentLines[i])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                // Strip trailing period for consistent comparison
                lineForComparison = lineForComparison.replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)

                if contentLines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    if lineForComparison == normalizedContentForComparison {
                        let removedLine = contentLines[i]
                        contentLines.remove(at: i)
                        contentRemoved = true
                        print("[KBPatchApplier] Successfully removed content: \(removedLine)")
                        break
                    }
                }
            }

            if !contentRemoved {
                print("[KBPatchApplier] Content not found for deletion: \(normalizedContent)")
                return nil
            }
        }

        return contentLines.joined(separator: "\n")
    }
}
