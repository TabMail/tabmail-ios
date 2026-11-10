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
    /// Microsoft Graph: 429 (throttled) and 503 ("temporarily unavailable … You
    /// can repeat the request after a delay, the length of which can be specified
    /// in a Retry-After header", Graph errors page), each after its `Retry-After`.
    static let graph = HTTPRetryPolicy(retryableStatusCodes: [429, 503], maxAttempts: 3, initialDelay: 1.0)
}

/// Single 401-retry path used by every shared REST API layer.
/// Both main app providers and NSE clients construct one of these per call site.
/// On 401 → `auth.refresh()` → retry once. On rate-limit → `Retry-After`, else
/// exponential backoff. With a `gate`, every request it sends (the first, each
/// retry, the one after a refresh) holds one of the gate's slots while on the wire.
struct AuthedHTTP: Sendable {
    /// A test's URLSession for every shared HTTP request made in its scope:
    /// `AuthedHTTP` and `performHTTPRequest` alike, including those of providers
    /// built by code the test does not construct. Nil in production.
    @TaskLocal static var sessionOverride: URLSession?
    let auth: any AuthSource
    let retry: HTTPRetryPolicy
    let logLabel: String?
    /// Optional URLSession override — used by tests to inject a URLProtocol-backed
    /// session. Production call sites omit this and get the shared ephemeral session.
    let session: URLSession?
    /// Called once with the final HTTP-status failure of `get`/`post`/`patch`/
    /// `put`/`delete` (after any 401 refresh and rate-limit retries), before the
    /// error is thrown: the method, the status and the provider's error body. Lets
    /// a provider log the error it names; it is never handed the request body or
    /// the token. Not called for a transport error, a cancellation, a failed
    /// refresh, `requestAllowing404` or `requestPreservingBadRequestBody`.
    let onFailure: (@Sendable (_ method: String, _ statusCode: Int, _ errorBody: Data?) -> Void)?
    /// The provider's concurrency limit (Outlook: one per mailbox), or nil for none.
    let gate: HTTPConcurrencyGate?

    init(
        auth: any AuthSource, retry: HTTPRetryPolicy, logLabel: String? = nil, session: URLSession? = nil,
        onFailure: (@Sendable (_ method: String, _ statusCode: Int, _ errorBody: Data?) -> Void)? = nil,
        gate: HTTPConcurrencyGate? = nil
    ) {
        self.auth = auth
        self.retry = retry
        self.logLabel = logLabel
        self.session = session ?? Self.sessionOverride
        self.onFailure = onFailure
        self.gate = gate
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
            logLabel: logLabel,
            gate: gate
        )
        if result.statusCode == 401 {
            token = try await auth.refresh(rejecting: token)
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                session: session, logLabel: logLabel, gate: gate
            )
        }
        return HTTPAuthedResult(data: result.data, statusCode: result.statusCode)
    }

    /// Like `post`/`get`/`patch`, but on a final (post-401-retry) `400`
    /// failure throws `HTTPError.networkErrorWithBody` carrying the raw
    /// response bytes instead of the bodyless `.networkError`. Every other
    /// failure status still throws the ordinary `.networkError` — this is a
    /// narrow opt-in for the action-path call sites that must structurally
    /// classify a `400` error payload rather than guess from the status code
    /// alone (Law 4: only a provably authoritative signal may be treated as
    /// stale).
    ///
    /// ⚠ THE CONSUMER LIST IS ONE CALL SITE, and this comment has now been wrong
    /// TWICE — corrected 2026-08-05 by round-5 Angle 3. It first named *"Gmail
    /// label modify/lookup, Graph move"*; the Graph half was an intention, never a
    /// call site. The correction then still named two Gmail consumers — the private
    /// wrapper *"and the Gmail label-lookup site"* — and the second of those has no
    /// call sites either. At HEAD there is exactly ONE caller of this function,
    /// `GmailProvider.requestPreservingBadRequestBody` (its private wrapper), and
    /// that wrapper in turn has exactly TWO callers, `GmailProvider.modifyMessage`
    /// and `GmailProvider.trashOrUntrashMessage` (#420).
    /// No Gmail label-lookup path reaches here: the `/labels` catalog calls go
    /// through the ordinary `request(...)`. Nothing else calls it;
    /// `ExchangeProvider.patchMessage` and `ExchangeProvider.moveMessage` both
    /// still call the body-dropping `request`, so every Graph mutation's `400`
    /// reaches the queue bodyless and unclassifiable, and retries as a counted
    /// failure. The queue has no `400` classifier of its own.
    ///
    /// **The comment was corrected rather than the consumer added, deliberately.**
    /// The gap is registered as `KNOWN_ISSUES.md` `IOS-GRAPH-004` and it fails
    /// SAFE — an unclassifiable Graph `400` retries as a counted failure, bounded
    /// by the fifth exit, instead of being recorded as done. Wiring Graph through here is only half a fix: without the
    /// accompanying **narrow** body-parse that accepts a parsed
    /// `ErrorInvalidIdMalformed` and nothing else, it re-creates `v1.6.38`'s
    /// bare-status-code discard, which retired the intention on every `400`.
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
            logLabel: logLabel,
            gate: gate
        )

        if result.statusCode == 401 {
            token = try await auth.refresh(rejecting: token)
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                extraHeaders: extraHeaders, session: session, logLabel: logLabel, gate: gate
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
            logLabel: logLabel,
            gate: gate
        )

        if result.statusCode == 401 {
            token = try await auth.refresh(rejecting: token)
            result = try await performHTTPRequest(
                url: url, method: method, body: body, token: token,
                extraHeaders: extraHeaders, session: session, logLabel: logLabel, gate: gate
            )
        }

        if let data = result.data {
            return data
        }
        onFailure?(method, result.statusCode, result.errorBody)
        throw HTTPError.networkError(statusCode: result.statusCode)
    }

    private func currentOrRefresh() async throws -> String {
        try Task.checkCancellation()
        if let t = await auth.current() { return t }
        return try await auth.refresh()
    }
}

/// Result type that preserves status code for callers that need to branch on 404 / 410.
struct HTTPAuthedResult: Sendable {
    let data: Data?
    let statusCode: Int
}
