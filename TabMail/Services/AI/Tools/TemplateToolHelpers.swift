/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateToolHelpers.swift – shared utilities for template tools

import Foundation

enum TemplateToolHelpers {
    static func stringArg(_ args: [String: JSONValue], _ key: String) -> String {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return ""
    }

    static func stringArgOpt(_ args: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func stringArrayArg(_ args: [String: JSONValue], _ key: String) -> [String] {
        guard case .array(let arr) = args[key] else { return [] }
        return arr.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            return nil
        }
    }

    static func intArg(_ args: [String: JSONValue], _ key: String) -> Int? {
        switch args[key] {
        case .int(let n): return n
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// Resolve a numeric template ID to a real template UUID via the translator.
    /// The LLM sends numeric IDs; we need the real UUID to look up in PromptStore.
    @MainActor
    static func resolveTemplateId(_ args: [String: JSONValue], key: String = "template_id", translator: any ChatIdTranslating) async -> String? {
        guard let numericId = intArg(args, key) else { return nil }
        return await translator.toRealId(numericId)
    }

    /// Look up a template by UUID in PromptStore.
    @MainActor
    static func lookupTemplate(_ templateId: String) -> ReplyTemplate? {
        let store = PromptStore.shared
        return store.templates.first { $0.id == templateId && !$0.deleted }
    }

    /// Truncate example reply for preview in confirmation cards.
    static func previewExampleReply(_ text: String, maxLength: Int = 100) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }
}
