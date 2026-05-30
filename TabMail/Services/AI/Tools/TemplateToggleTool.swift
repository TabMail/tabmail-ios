/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateToggleTool.swift – enable or disable a reply template (non-FSM, no confirmation)

import Foundation

struct TemplateToggleTool: AgentTool, Sendable {
    let name = "template_toggle"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        guard case .bool(let enabled) = arguments["enabled"] else {
            return ToolJSON.string(from: ["error": "The 'enabled' parameter (true or false) is required."])
        }

        guard let template = await MainActor.run(body: { TemplateToolHelpers.lookupTemplate(templateId) }) else {
            return ToolJSON.string(from: ["error": "Template not found."])
        }

        if template.enabled == enabled {
            return ToolJSON.string(from: [
                "ok": true,
                "result": "Template \"\(template.name)\" is already \(enabled ? "enabled" : "disabled").",
                "template_id": templateId,
                "template_name": template.name,
                "enabled": enabled,
            ] as [String: Any])
        }

        await MainActor.run {
            var updated = template
            updated.enabled = enabled
            PromptStore.shared.updateTemplate(updated)
        }

        let verb = enabled ? "enabled" : "disabled"
        return ToolJSON.string(from: [
            "ok": true,
            "result": "Template \"\(template.name)\" \(verb).",
            "template_id": templateId,
            "template_name": template.name,
            "enabled": enabled,
        ] as [String: Any])
    }
}
