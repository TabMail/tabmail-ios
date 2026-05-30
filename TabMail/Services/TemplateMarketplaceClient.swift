/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// API client for the template marketplace worker (templates-dev.tabmail.ai).
/// Follows the same auth pattern as DeviceSyncService — reads Supabase JWT from Keychain directly.
actor TemplateMarketplaceClient {
    static let shared = TemplateMarketplaceClient()

    private var baseURL: URL { BackendConfig.templatesBaseURL }
    private let session = sharedEphemeralSession

    // MARK: - Response Types

    struct MarketplaceTemplate: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String?
        let instructions: [String]
        let example_reply: String
        let download_count: Int
        let is_featured: Bool
        let is_official: Bool
        let status: String
        let category: String?
        let tags: [String]?
        let created_at: String
        let updated_at: String
    }

    struct ListResponse: Codable, Sendable {
        let templates: [MarketplaceTemplate]
        let pagination: Pagination
    }

    struct Pagination: Codable, Sendable {
        let limit: Int
        let offset: Int
        let total: Int
        let has_more: Bool
    }

    struct DownloadResponse: Codable, Sendable {
        let template: DownloadedTemplate
    }

    struct DownloadedTemplate: Codable, Sendable {
        let id: String
        let name: String
        let instructions: [String]
        let exampleReply: String
        let enabled: Bool
    }

    struct MyTemplate: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String?
        let instructions: [String]
        let example_reply: String
        let download_count: Int
        let is_featured: Bool
        let is_official: Bool
        let status: String
        let category: String?
        let tags: [String]?
        let created_at: String
        let updated_at: String
        let rejection_reason: String?
        let reviewed_at: String?
    }

    struct MyTemplatesResponse: Codable, Sendable {
        let templates: [MyTemplate]
        let limits: TemplateLimits
    }

    struct TemplateLimits: Codable, Sendable {
        let max_templates: Int
        let current_count: Int
        let remaining: Int
    }

    struct UploadRequest: Encodable, Sendable {
        let id: String
        let name: String
        let description: String?
        let instructions: [String]
        let example_reply: String
    }

    struct UploadResponse: Codable, Sendable {
        let success: Bool
        let message: String
        let template_id: String
        let status: String
    }

    enum MarketplaceError: Error, LocalizedError {
        case unauthorized
        case requestFailed(statusCode: Int)
        case noAuthToken
        case validationError(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Not authenticated"
            case .requestFailed(let code): return "Request failed (\(code))"
            case .noAuthToken: return "Please sign in to browse templates"
            case .validationError(let msg): return msg
            }
        }
    }

    enum SortOrder: String, CaseIterable, Sendable {
        case popular
        case recent
        case name
    }

    // MARK: - API Methods

    func listTemplates(
        sort: SortOrder = .popular,
        search: String? = nil,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> ListResponse {
        var components = URLComponents(url: baseURL.appending(path: "/list"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let search, !search.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "search", value: search))
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try await applyAuth(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(ListResponse.self, from: data)
    }

    func downloadTemplate(id: String) async throws -> DownloadedTemplate {
        var request = URLRequest(url: baseURL.appending(path: "/download/\(id)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(DownloadResponse.self, from: data).template
    }

    func uploadTemplate(_ template: ReplyTemplate, description: String? = nil) async throws -> UploadResponse {
        var request = URLRequest(url: baseURL.appending(path: "/upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)

        let body = UploadRequest(
            id: template.id,
            name: template.name,
            description: description,
            instructions: template.instructions,
            example_reply: template.exampleReply
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 400 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                throw MarketplaceError.validationError(message)
            }
        }
        try checkResponse(response)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    func myTemplates() async throws -> MyTemplatesResponse {
        var request = URLRequest(url: baseURL.appending(path: "/my-templates"))
        request.httpMethod = "GET"
        try await applyAuth(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(MyTemplatesResponse.self, from: data)
    }

    func unshareTemplate(id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/unshare/\(id)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)

        let (_, response) = try await session.data(for: request)
        try checkResponse(response)
    }

    // MARK: - Private

    private func applyAuth(_ request: inout URLRequest) async throws {
        guard let token = await currentAuthToken() else {
            throw MarketplaceError.noAuthToken
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(BackendClient.clientVersion, forHTTPHeaderField: "X-Client-Version")
    }

    /// Fresh auth token, refreshing via shared coordinator if expired.
    private func currentAuthToken() async -> String? {
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let token):
            return token
        case .permanentFailure, .transientFailure, .noSession:
            return nil
        }
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.requestFailed(statusCode: 0)
        }
        if http.statusCode == 401 { throw MarketplaceError.unauthorized }
        guard 200..<300 ~= http.statusCode else {
            throw MarketplaceError.requestFailed(statusCode: http.statusCode)
        }
    }
}
