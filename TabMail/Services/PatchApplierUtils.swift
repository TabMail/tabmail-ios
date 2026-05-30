/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared utilities for ActionPatchApplier and KBPatchApplier.
/// Extracted from duplicated implementations in both appliers.
enum PatchApplierUtils {

    /// Normalize text to ensure proper markdown bullet and sentence ending.
    /// Matches TB's `normalizeContent()`.
    static func normalizeContent(_ text: String) -> String {
        // Remove existing bullet if present
        var normalized = text.hasPrefix("- ") ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text.trimmingCharacters(in: .whitespaces)

        // Add period if missing
        if !normalized.hasSuffix(".") {
            normalized += "."
        }

        return "- \(normalized)"
    }

    /// Check if content already exists in the given lines (case-insensitive).
    /// When `unicodeNormalize` is true, applies Unicode normalization (used by KB patch applier).
    static func isDuplicate(contentLines: [String], normalizedContent: String, unicodeNormalize: Bool = false) -> Bool {
        let normalizedText: String
        if unicodeNormalize {
            normalizedText = AIService.normalizeUnicode(normalizedContent).lowercased().trimmingCharacters(in: .whitespaces)
        } else {
            normalizedText = normalizedContent.lowercased().trimmingCharacters(in: .whitespaces)
        }
        return contentLines.contains { line in
            let lineText: String
            if unicodeNormalize {
                lineText = AIService.normalizeUnicode(line).lowercased().trimmingCharacters(in: .whitespaces)
            } else {
                lineText = line.lowercased().trimmingCharacters(in: .whitespaces)
            }
            return lineText == normalizedText
        }
    }

    /// Parsed patch operation (ADD or DEL with optional action type).
    struct PatchOperation {
        let operation: String // "ADD" or "DEL"
        let actionType: String? // nil for KB, "delete"/"archive"/"reply"/"none" for actions
        let content: String
    }

    /// Parse multiple ADD/DEL operations from patch text.
    /// When `hasActionType` is true, expects an action type line between the operation and content (action patches).
    /// When false, content follows directly after the operation line (KB patches).
    static func parseOperations(_ patchText: String, hasActionType: Bool) -> [PatchOperation] {
        var operations: [PatchOperation] = []
        let lines = patchText.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let operation = lines[i].trimmingCharacters(in: .whitespaces).uppercased()

            guard operation == "ADD" || operation == "DEL" else {
                i += 1
                continue
            }

            let actionType: String?
            let contentStartIndex: Int

            if hasActionType {
                guard i + 2 < lines.count else {
                    break
                }
                actionType = lines[i + 1].trimmingCharacters(in: .whitespaces).lowercased()
                contentStartIndex = i + 2
            } else {
                guard i + 1 < lines.count else {
                    break
                }
                actionType = nil
                contentStartIndex = i + 1
            }

            // Collect content lines until next operation or end
            var contentLines: [String] = []
            var j = contentStartIndex
            while j < lines.count {
                let nextLine = lines[j].trimmingCharacters(in: .whitespaces).uppercased()
                if nextLine == "ADD" || nextLine == "DEL" {
                    break
                }
                contentLines.append(lines[j])
                j += 1
            }

            guard !contentLines.isEmpty else {
                i = j
                continue
            }

            let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            operations.append(PatchOperation(operation: operation, actionType: actionType, content: content))
            i = j
        }

        return operations
    }
}
