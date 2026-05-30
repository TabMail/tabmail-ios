/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// TemplateSearchTool.swift – search local templates AND the public marketplace (non-FSM, read-only)

import Foundation

struct TemplateSearchTool: AgentTool, Sendable {
    let name = "template_search"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let query = TemplateToolHelpers.stringArg(arguments, "query")
        let category = TemplateToolHelpers.stringArg(arguments, "category")
        let sort = TemplateToolHelpers.stringArg(arguments, "sort")
        let translator = ctx.translator

        var allResults: [[String: Any]] = []

        // --- 1. Search local templates ---
        let localTemplates = await MainActor.run { () -> [ReplyTemplate] in
            PromptStore.shared.templates.filter { !$0.deleted }
        }

        // Word-based OR matching: split query into words, score by hits across fields
        let queryWords = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }

        var scored: [(template: ReplyTemplate, score: Int)] = []
        for t in localTemplates {
            if queryWords.isEmpty {
                scored.append((t, 0))
                continue
            }

            let nameLower = t.name.lowercased()
            let instrText = t.instructions.joined(separator: " ").lowercased()
            let exampleLower = t.exampleReply.lowercased()

            var hits = 0
            for word in queryWords {
                if nameLower.contains(word) { hits += 2 }       // name weighted higher
                if instrText.contains(word) { hits += 1 }
                if exampleLower.contains(word) { hits += 1 }
            }

            if hits > 0 {
                scored.append((t, hits))
            }
        }

        // Sort by score descending (best matches first)
        scored.sort { $0.score > $1.score }

        var localCount = 0
        for (t, _) in scored {
            let numericId = await translator.toNumericId(t.id)
            await translator.cacheTemplateName(numericId: numericId, name: t.name)
            localCount += 1
            allResults.append([
                "template_id": numericId,
                "name": t.name,
                "source": "local",
                "enabled": t.enabled,
                "instructions_count": t.instructions.count,
            ] as [String: Any])
        }

        // Collect local IDs for dedup against marketplace
        let localIds = Set(scored.map { $0.template.id })

        // --- 2. Search marketplace ---
        var marketplaceCount = 0
        var marketplaceTotal = 0
        var marketplaceHasMore = false

        do {
            let token: String
            switch await TabMailTokenCoordinator.shared.validToken() {
            case .success(let t): token = t
            default: token = ""
            }

            if !token.isEmpty {
                var params: [URLQueryItem] = [URLQueryItem(name: "limit", value: "10")]
                if !query.isEmpty { params.append(URLQueryItem(name: "search", value: query)) }
                if !category.isEmpty { params.append(URLQueryItem(name: "category", value: category)) }
                if !sort.isEmpty { params.append(URLQueryItem(name: "sort", value: sort)) }

                let baseURL = BackendConfig.templatesBaseURL
                var components = URLComponents(string: "\(baseURL.absoluteString)/list")
                components?.queryItems = params

                if let url = components?.url {
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                    let (data, response) = try await sharedEphemeralSession.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let templates = json["templates"] as? [[String: Any]] {

                        for t in templates {
                            let realId = t["id"] as? String ?? ""
                            // Skip marketplace templates already present locally
                            if localIds.contains(realId) { continue }
                            let numericId = await translator.toNumericId(realId)
                            let templateName = t["name"] as? String ?? "(Untitled)"
                            await translator.cacheTemplateName(numericId: numericId, name: templateName)

                            var result: [String: Any] = [
                                "template_id": numericId,
                                "name": templateName,
                                "source": "marketplace",
                                "download_count": t["download_count"] as? Int ?? 0,
                            ]
                            if let desc = t["description"] as? String, !desc.isEmpty {
                                result["description"] = desc
                            }
                            if let instructions = t["instructions"] as? [String] {
                                result["instructions_count"] = instructions.count
                            }
                            if let cat = t["category"] as? String, !cat.isEmpty {
                                result["category"] = cat
                            }
                            allResults.append(result)
                        }

                        marketplaceCount = templates.count
                        let pagination = json["pagination"] as? [String: Any]
                        marketplaceTotal = pagination?["total"] as? Int ?? templates.count
                        marketplaceHasMore = pagination?["has_more"] as? Bool ?? false
                    }
                }
            }
        } catch {
            // Marketplace failure is non-fatal — local results still returned
        }

        // --- 3. Return combined ---
        if allResults.isEmpty {
            return ToolJSON.string(from: ["ok": true, "result": "No templates found matching your search."])
        }

        return ToolJSON.string(from: [
            "ok": true,
            "templates": allResults,
            "local_count": localCount,
            "marketplace_count": marketplaceCount,
            "marketplace_total": marketplaceTotal,
            "marketplace_has_more": marketplaceHasMore,
        ] as [String: Any])
    }
}
