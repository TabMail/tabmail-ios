/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateEditTool.swift – edits an existing reply template with user confirmation

import Foundation

struct TemplateEditTool: AgentTool, Sendable {
    let name = "template_edit"
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
        // Resolve numeric ID to real template UUID
        let numericTemplateId = TemplateToolHelpers.intArg(arguments, "template_id")
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        // Look up existing template (for confirmation card display only)
        guard let template = await MainActor.run(body: { TemplateToolHelpers.lookupTemplate(templateId) }) else {
            return ToolJSON.string(from: ["error": "Template not found."])
        }

        // Determine what changed
        let newName = TemplateToolHelpers.stringArgOpt(arguments, "name")
        let newInstructions: [String]? = {
            guard case .array = arguments["instructions"] else { return nil }
            return TemplateToolHelpers.stringArrayArg(arguments, "instructions")
        }()
        let newExampleReply = TemplateToolHelpers.stringArgOpt(arguments, "example_reply")

        // Must have at least one change
        guard newName != nil || newInstructions != nil || newExampleReply != nil else {
            return ToolJSON.string(from: ["error": "No changes provided. Specify at least one field to update (name, instructions, or example_reply)."])
        }

        // Build changes descriptions for confirmation card (from arguments, like CalendarEventEditTool)
        var changes: [String] = []
        if let n = newName, n != template.name {
            changes.append("name: \(template.name) → \(n)")
        }
        if let ins = newInstructions {
            changes.append("instructions: \(template.instructions.count) → \(ins.count) rules")
        }
        if let ex = newExampleReply, ex != template.exampleReply {
            changes.append("example reply: updated")
        }

        let displayName = newName ?? template.name

        // Show confirmation card
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .templateEdit,
            templates: [.init(
                templateId: templateId,
                name: displayName,
                instructionCount: newInstructions?.count ?? template.instructions.count,
                exampleReplyPreview: TemplateToolHelpers.previewExampleReply(newExampleReply ?? template.exampleReply),
                changes: changes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to edit this template.",
            ] as [String: Any]))
        }

        // Re-fetch template from store to avoid overwriting Device Sync changes
        // that arrived during the confirmation dialog (same pattern as CalendarEventEditTool
        // which builds from arguments, not from a pre-confirmation snapshot).
        let updated = await MainActor.run { () -> Bool in
            guard let current = PromptStore.shared.templates.first(where: { $0.id == templateId && !$0.deleted }) else { return false }
            var t = current
            if let n = newName { t.name = n }
            if let ins = newInstructions { t.instructions = ins }
            if let ex = newExampleReply { t.exampleReply = ex }
            PromptStore.shared.updateTemplate(t)
            return true
        }

        guard updated else {
            return ToolJSON.string(from: ["error": "Template was deleted by another device during confirmation."])
        }

        // Update template name cache so pills show the new name
        if let numericId = numericTemplateId {
            await ctx.translator.cacheTemplateName(numericId: numericId, name: displayName)
        }

        return ToolJSON.string(from: [
            "success": true,
            "message": "Template '\(displayName)' updated successfully.",
            "template_id": templateId,
            "template_name": displayName,
        ] as [String: Any])
    }
}
