/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Retry policy for `AuthedHTTP`. Rate-limit codes differ per provider.
struct HTTPRetryPolicy: Sendable {
    let retryableStatusCodes: Set<Int>
    let maxAttempts: Int
    let initialDelay: TimeInterval

    /// Gmail: 429 + 403 (per-user rateLimitExceeded is 403).
    static let gmail = HTTPRetryPolicy(retryableStatusCodes: [429, 403], maxAttempts: 3, initialDelay: 1.0)
    /// Graph / other REST APIs: 429 only.
    static let graph = HTTPRetryPolicy(retryableStatusCodes: [429], maxAttempts: 3, initialDelay: 1.0)
}

/// Single 401-retry path used by every shared REST API layer.
/// Both main app providers and NSE clients construct one of these per call site.
/// On 401 → `auth.refresh()` → retry once. On rate-limit → exponential backoff.
struct AuthedHTTP: Sendable {
    let auth: any AuthSource
    let retry: HTTPRetryPolicy
    let logLabel: String?
    /// Optional URLSession override — used by tests to inject a URLProtocol-backed
    /// session. Production call sites omit this and get the shared ephemeral session.
    let session: URLSession?

    init(auth: any AuthSource, retry: HTTPRetryPolicy, logLabel: String? = nil, session: URLSession? = nil) {
        self.auth = auth
        self.retry = retry
        self.logLabel = logLabel
        self.session = session
    }

    func get(_ url: String, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await request(url: url, method: "GET", body: nil, extraHeaders: extraHeaders)
    }

    func post(_ url: String, body: Data, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await request(url: url, method: "POST", body: body, extraHeaders: extraHeaders)
    }

    func patch(_ url: String, body: Data, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await request(url: url, method: "PATCH", body: body, extraHeaders: extraHeaders)
    }

    func put(_ url: String, body: Data, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await request(url: url, method: "PUT", body: body, extraHeaders: extraHeaders)
    }

    func delete(_ url: String, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await request(url: url, method: "DELETE", body: nil, extraHeaders: extraHeaders)
    }

    /// Raw request — exposes 404 status via `HTTPAuthedResult` instead of throwing,
    /// so callers like Gmail `fetchHistory` can distinguish "history expired" (404)
    /// from "real error".
    func requestAllowing404(url: String, method: String = "GET", body: Data? = nil) async throws -> HTTPAuthedResult {
        var token = try await currentOrRefresh()
        var result = try await performHTTPRequestWithRetry(
            url: url, method: method, body: body, token: token,
            retryableStatusCodes: retry.retryableStatusCodes,
            maxAttempts: retry.maxAttempts, initialDelay: retry.initialDelay,
            session: session,
            logLabel: logLabel
        )
        if result.statusCode == 401 {
            token = try await auth.refresh()
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                session: session, logLabel: logLabel
            )
        }
        return HTTPAuthedResult(data: result.data, statusCode: result.statusCode)
    }

    /// Like `post`/`get`/`patch`, but on a final (post-401-retry) `400`
    /// failure throws `HTTPError.networkErrorWithBody` carrying the raw
    /// response bytes instead of the bodyless `.networkError`. Every other
    /// failure status still throws the ordinary `.networkError` — this is a
    /// narrow opt-in for the handful of action-path call sites (Gmail label
    /// modify/lookup, Graph move) that must structurally classify a `400`
    /// error payload rather than guess from the status code alone (Law 4:
    /// only a provably authoritative signal may be treated as stale).
    func requestPreservingBadRequestBody(
        url: String,
        method: String,
        body: Data?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        var token = try await currentOrRefresh()
        var result = try await performHTTPRequestWithRetry(
            url: url, method: method, body: body, token: token,
            extraHeaders: extraHeaders,
            retryableStatusCodes: retry.retryableStatusCodes,
            maxAttempts: retry.maxAttempts, initialDelay: retry.initialDelay,
            session: session,
            logLabel: logLabel
        )

        if result.statusCode == 401 {
            token = try await auth.refresh()
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                extraHeaders: extraHeaders, session: session, logLabel: logLabel
            )
        }

        if let data = result.data {
            return data
        }
        if result.statusCode == 400, let errorBody = result.errorBody {
            throw HTTPError.networkErrorWithBody(statusCode: 400, body: errorBody)
        }
        throw HTTPError.networkError(statusCode: result.statusCode)
    }

    // MARK: - Internal

    private func request(url: String, method: String, body: Data?, extraHeaders: [String: String]) async throws -> Data {
        var token = try await currentOrRefresh()
        var result = try await performHTTPRequestWithRetry(
            url: url, method: method, body: body, token: token,
            extraHeaders: extraHeaders,
            retryableStatusCodes: retry.retryableStatusCodes,
            maxAttempts: retry.maxAttempts, initialDelay: retry.initialDelay,
            session: session,
            logLabel: logLabel
        )

        if result.statusCode == 401 {
            token = try await auth.refresh()
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                extraHeaders: extraHeaders, session: session, logLabel: logLabel
            )
        }

        if let data = result.data {
            return data
        }
        throw HTTPError.networkError(statusCode: result.statusCode)
    }

    private func currentOrRefresh() async throws -> String {
        if let t = await auth.current() { return t }
        return try await auth.refresh()
    }
}

/// Result type that preserves status code for callers that need to branch on 404 / 410.
struct HTTPAuthedResult: Sendable {
    let data: Data?
    let statusCode: Int
}
