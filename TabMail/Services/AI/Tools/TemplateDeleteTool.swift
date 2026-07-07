/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateDeleteTool.swift – deletes a reply template with user confirmation

import Foundation

struct TemplateDeleteTool: AgentTool, Sendable {
    let name = "template_delete"
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
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        guard let template = await MainActor.run(body: { TemplateToolHelpers.lookupTemplate(templateId) }) else {
            return ToolJSON.string(from: ["error": "Template not found."])
        }

        // Show confirmation card
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .templateDelete,
            templates: [.init(
                templateId: templateId,
                name: template.name,
                instructionCount: template.instructions.count,
                exampleReplyPreview: TemplateToolHelpers.previewExampleReply(template.exampleReply)
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete this template.",
            ] as [String: Any]))
        }

        // Soft-delete template via PromptStore.deleteTemplate (CRDT tombstone for Device Sync)
        let templateName = template.name
        await MainActor.run {
            PromptStore.shared.deleteTemplate(id: templateId)
        }

        return ToolJSON.string(from: [
            "success": true,
            "message": "Template '\(templateName)' deleted.",
            "template_name": templateName,
        ] as [String: Any])
    }
}
