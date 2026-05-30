/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateReadTool.swift – read full details of a local or marketplace template (non-FSM, read-only)

import Foundation

struct TemplateReadTool: AgentTool, Sendable {
    let name = "template_read"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        // Try local first
        if let template = await MainActor.run(body: { TemplateToolHelpers.lookupTemplate(templateId) }) {
            return ToolJSON.string(from: [
                "ok": true,
                "source": "local",
                "template_id": templateId,
                "name": template.name,
                "enabled": template.enabled,
                "instructions": template.instructions,
                "example_reply": template.exampleReply,
            ] as [String: Any])
        }

        // Not found locally — try marketplace
        let token: String
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let t): token = t
        default: return ToolJSON.string(from: ["error": "Template not found locally and authentication not available for marketplace."])
        }

        let baseURL = BackendConfig.templatesBaseURL
        guard let url = URL(string: "\(baseURL.absoluteString)/template/\(templateId)") else {
            return ToolJSON.string(from: ["error": "Template not found."])
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            return ToolJSON.string(from: ["error": "Failed to connect to template marketplace."])
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["template"] as? [String: Any],
              let name = t["name"] as? String else {
            return ToolJSON.string(from: ["error": "Template not found."])
        }

        return ToolJSON.string(from: [
            "ok": true,
            "source": "marketplace",
            "template_id": templateId,
            "name": name,
            "instructions": t["instructions"] as? [String] ?? [],
            "example_reply": t["example_reply"] as? String ?? "",
            "download_count": t["download_count"] as? Int ?? 0,
            "category": t["category"] as? String ?? "",
            "created_at": t["created_at"] as? String ?? "",
            "updated_at": t["updated_at"] as? String ?? "",
        ] as [String: Any])
    }
}
