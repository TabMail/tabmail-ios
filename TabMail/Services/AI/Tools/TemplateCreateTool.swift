/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateCreateTool.swift – creates a new reply template with user confirmation

import Foundation

struct TemplateCreateTool: AgentTool, Sendable {
    let name = "template_create"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        let templateName = TemplateToolHelpers.stringArg(arguments, "name")
        guard !templateName.isEmpty else {
            return ToolJSON.string(from: ["error": "Template name is required."])
        }

        let instructions = TemplateToolHelpers.stringArrayArg(arguments, "instructions")
        let exampleReply = TemplateToolHelpers.stringArg(arguments, "example_reply")

        // Check for duplicate name
        var changes: [String] = []
        let hasDuplicate = await MainActor.run {
            PromptStore.shared.templates.contains { !$0.deleted && $0.name.lowercased() == templateName.lowercased() }
        }
        if hasDuplicate {
            changes.append("⚠️ A template named \"\(templateName)\" already exists")
        }

        // Show confirmation card
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .templateCreate,
            templates: [.init(
                templateId: "",
                name: templateName,
                instructionCount: instructions.count,
                exampleReplyPreview: TemplateToolHelpers.previewExampleReply(exampleReply),
                changes: changes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to create this template.",
            ] as [String: Any]))
        }

        // Create template in PromptStore (didSet triggers persistence + Device Sync)
        let templateId = UUID().uuidString
        let newTemplate = ReplyTemplate(
            id: templateId,
            name: templateName,
            enabled: true,
            instructions: instructions,
            exampleReply: exampleReply
        )

        await MainActor.run {
            PromptStore.shared.addTemplate(newTemplate)
        }

        // Register new template in ChatIdTranslator so LLM gets a numeric ID + pill rendering
        let numericId = await ctx.translator.toNumericId(templateId)
        await ctx.translator.cacheTemplateName(numericId: numericId, name: templateName)

        return ToolJSON.string(from: [
            "success": true,
            "message": "Template '\(templateName)' created successfully.",
            "template_id": numericId,
            "template_name": templateName,
        ] as [String: Any])
    }
}
