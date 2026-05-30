/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateDownloadTool.swift – downloads a marketplace template and installs it locally

import Foundation

struct TemplateDownloadTool: AgentTool, Sendable {
    let name = "template_download"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        // Fetch template from marketplace
        let baseURL = BackendConfig.templatesBaseURL
        guard let url = URL(string: "\(baseURL.absoluteString)/download/\(templateId)") else {
            return ToolJSON.string(from: ["error": "Failed to build marketplace URL."])
        }

        let token: String
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let t): token = t
        default: return ToolJSON.string(from: ["error": "Authentication not available. Please sign in first."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            return ToolJSON.string(from: ["error": "Failed to connect to template marketplace."])
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ToolJSON.string(from: ["error": "Marketplace returned error: \(statusCode)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templateData = json["template"] as? [String: Any],
              let templateName = templateData["name"] as? String else {
            return ToolJSON.string(from: ["error": "Failed to parse marketplace response."])
        }

        let instructions = templateData["instructions"] as? [String] ?? []
        let exampleReply = (templateData["exampleReply"] as? String)
            ?? (templateData["example_reply"] as? String)
            ?? ""
        let enabled = templateData["enabled"] as? Bool ?? true

        // Show confirmation card
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .templateDownload,
            templates: [.init(
                templateId: templateId,
                name: templateName,
                instructionCount: instructions.count,
                exampleReplyPreview: TemplateToolHelpers.previewExampleReply(exampleReply)
            )]
        )

        guard confirmed else {
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to download this template.",
            ] as [String: Any]))
        }

        // Install locally — use the marketplace template's own ID
        let localId = (templateData["id"] as? String) ?? UUID().uuidString
        let newTemplate = ReplyTemplate(
            id: localId,
            name: templateName,
            enabled: enabled,
            instructions: instructions,
            exampleReply: exampleReply
        )

        await MainActor.run {
            PromptStore.shared.addTemplate(newTemplate)
        }

        // Register in translator for pill rendering
        let numericId = await ctx.translator.toNumericId(localId)
        await ctx.translator.cacheTemplateName(numericId: numericId, name: templateName)

        return ToolJSON.string(from: [
            "success": true,
            "message": "Template '\(templateName)' downloaded and installed.",
            "template_id": numericId,
            "template_name": templateName,
        ] as [String: Any])
    }
}
