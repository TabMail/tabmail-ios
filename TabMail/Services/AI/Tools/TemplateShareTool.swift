/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateShareTool.swift – shares a reply template to the public marketplace with user confirmation

import Foundation

struct TemplateShareTool: AgentTool, Sendable {
    let name = "template_share"
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

        // Template worker requires example_reply
        guard !template.exampleReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolJSON.string(from: ["error": "Template must have an example reply before sharing to the marketplace."])
        }

        let description = TemplateToolHelpers.stringArg(arguments, "description")
        let category = TemplateToolHelpers.stringArg(arguments, "category")
        let tags = TemplateToolHelpers.stringArrayArg(arguments, "tags")

        // Build changes for confirmation card
        var changes: [String] = []
        if !description.isEmpty { changes.append("description: \(description)") }
        if !category.isEmpty { changes.append("category: \(category)") }
        if !tags.isEmpty { changes.append("tags: \(tags.joined(separator: ", "))") }
        changes.append("By sharing, you agree to our Community Guidelines. Templates must be professional, respectful, and your own work. We reserve the right to reject or remove any template at any time.")

        // Show confirmation card
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .templateShare,
            templates: [.init(
                templateId: templateId,
                name: template.name,
                instructionCount: template.instructions.count,
                exampleReplyPreview: TemplateToolHelpers.previewExampleReply(template.exampleReply),
                changes: changes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to share this template.",
            ] as [String: Any]))
        }

        // POST to template worker /upload
        let baseURL = BackendConfig.templatesBaseURL
        guard let url = URL(string: "\(baseURL.absoluteString)/upload") else {
            return ToolJSON.string(from: ["error": "Template marketplace is not configured."])
        }

        let token: String
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let t): token = t
        default: return ToolJSON.string(from: ["error": "Authentication not available. Please sign in first."])
        }

        var body: [String: Any] = [
            "id": templateId,
            "name": template.name,
            "instructions": template.instructions,
            "example_reply": template.exampleReply,
        ]
        if !description.isEmpty { body["description"] = description }
        if !category.isEmpty { body["category"] = category }
        if !tags.isEmpty { body["tags"] = tags }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            return ToolJSON.string(from: ["error": "Failed to connect to template marketplace."])
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return ToolJSON.string(from: ["error": "Invalid marketplace response."])
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            var errorMsg = "Marketplace returned \(httpResponse.statusCode)"
            if let errData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let msg = errData["message"] as? String { errorMsg = msg }
                else if let err = errData["error"] as? String { errorMsg = err }
            }
            return ToolJSON.string(from: ["error": errorMsg])
        }

        let responseData = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = responseData["message"] as? String ?? "Template submitted for review. It will appear in the marketplace once approved."

        return ToolJSON.string(from: [
            "success": true,
            "message": message,
            "template_id": templateId,
            "status": responseData["status"] as? String ?? "pending_review",
        ] as [String: Any])
    }
}
