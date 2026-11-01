/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateDownloadTool.swift – downloads a marketplace template and installs it locally

import Foundation

struct TemplateDownloadTool: AgentTool, Sendable {
    let name = "template_download"
    private let ctx: ToolContext
    private let fetch: @Sendable (String) async -> Fetched

    /// What the marketplace answered: the response body, or the error the tool reports.
    enum Fetched: Sendable {
        case body(Data)
        case failure(String)
    }

    /// `fetch` is the marketplace request; tests pass their own.
    init(context: ToolContext? = nil, fetch: (@Sendable (String) async -> Fetched)? = nil) {
        self.ctx = context ?? ToolContext()
        self.fetch = fetch ?? Self.fetchFromMarketplace
    }

    private static func fetchFromMarketplace(_ templateId: String) async -> Fetched {
        let baseURL = BackendConfig.templatesBaseURL
        guard let url = URL(string: "\(baseURL.absoluteString)/download/\(templateId)") else {
            return .failure("Failed to build marketplace URL.")
        }

        let token: String
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let t): token = t
        default: return .failure("Authentication not available. Please sign in first.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            return .failure("Failed to connect to template marketplace.")
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failure("Marketplace returned error: \(statusCode)")
        }
        return .body(data)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // The call awaits (a confirmation, a lookup) before it writes, so it carries the change counter it started
        // with (DS-DEMO): a demo switch, or any other change to the store, in between refuses its write.
        let started = ChangeCounter.device.current
        guard let templateId = await TemplateToolHelpers.resolveTemplateId(arguments, translator: ctx.translator) else {
            return ToolJSON.string(from: ["error": "Template ID is required."])
        }

        // Fetch template from marketplace
        let data: Data
        switch await fetch(templateId) {
        case .body(let body): data = body
        case .failure(let message): return ToolJSON.string(from: ["error": message])
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
            )],
            via: invocation.uiSink
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

        let saved = await MainActor.run {
            PromptStore.shared.addTemplate(newTemplate, since: started)
        }
        guard saved else { return ToolJSON.string(from: ["error": "Could not save the change; try again."]) }

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
