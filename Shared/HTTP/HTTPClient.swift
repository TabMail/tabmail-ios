/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Module config for the shared HTTP layer. Lives here (Shared/) because this
/// file is compiled into BOTH the main app and the NSE and therefore cannot
/// reference the main-target-only `SyncConfig`.
enum HTTPConfig {
    /// Hard ceiling on total transfer time for `sharedEphemeralSession`,
    /// regardless of bytes received. `URLSessionConfiguration.ephemeral`
    /// defaults this to **7 days** — a stalled REST/OAuth/sync call whose
    /// connection trickles partial bytes keeps resetting the 60s per-request
    /// timer (`timeoutIntervalForRequest`) and would otherwise hang for that
    /// long. That is the "hang on boot after long disuse" class: on first
    /// foreground the app refreshes deeply-expired tokens / runs a large sync,
    /// and a slow-trickle endpoint stalls with no effective ceiling. 300s is
    /// generous for large attachment downloads on slow links while bounding any
    /// stall to 5 minutes. The LLM stream uses a SEPARATE session
    /// (`BackendClient.llmSession`, `SyncConfig.llmResourceTimeoutSeconds`) and
    /// is unaffected.
    static let sharedResourceTimeoutSeconds: TimeInterval = 300
    /// The longest `Retry-After` a retry waits for inside one request. A server
    /// asking for longer gets no retry: the request fails with its status, and
    /// the caller's own retry (the next sync pass, the queue's next drain) comes
    /// later. Keeps one call from holding its caller for minutes, and keeps the
    /// notification service extension inside its time budget.
    static let maxHonouredRetryAfterSeconds: TimeInterval = 10
}

/// Shared ephemeral URLSession for all HTTP providers (Gmail, Exchange, backend calls).
/// Ephemeral = no persistent connection cache, no cookies, no credential storage.
/// When TCP connections die during iOS suspension, the session creates fresh sockets
/// on the next request — no manual reset needed. Single instance avoids
/// "Cannot allocate memory" from per-request session creation.
let sharedEphemeralSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = HTTPConfig.sharedResourceTimeoutSeconds
    return URLSession(configuration: config)
}()

/// Result of an HTTP request — success returns data, failure returns nil data + status code.
struct HTTPRequestResult: Sendable {
    let data: Data?
    let statusCode: Int
    /// Raw response body captured on a non-2xx response, even though `data`
    /// stays nil for failures. Populated so a caller that opts into
    /// `AuthedHTTP.requestPreservingBadRequestBody` can structurally parse a
    /// provider's error payload (e.g. Gmail's invalid-label 400, Graph's
    /// `ErrorInvalidIdMalformed` 400) instead of guessing from status code
    /// alone. `nil` on success (use `data` there) or when the body is empty.
    /// Carries the body **whole** — never truncated. The 500-character cap a
    /// few lines below applies only to the human-readable log line, never to
    /// what a classifier receives.
    /// Defaulted so every pre-existing `HTTPRequestResult(...)` call site
    /// (production and test) keeps compiling unchanged. `var` (not `let`) is
    /// required for a defaulted stored property to appear as an overridable
    /// parameter in the synthesized memberwise initializer at all — a
    /// defaulted `let` is baked in as a fixed constant and cannot be
    /// customized per instance.
    var errorBody: Data? = nil
    /// The response's `Retry-After`, in seconds, when it gives a non-negative
    /// number of seconds (the form Microsoft Graph sends on 429 and 503). `nil`
    /// when the header is absent or is an HTTP date.
    var retryAfter: TimeInterval? = nil
}

/// `Retry-After` as delta-seconds (RFC 9110, section 10.2.3), or nil.
func retryAfterSeconds(_ response: URLResponse) -> TimeInterval? {
    guard let raw = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
          let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
    return TimeInterval(seconds)
}

/// Execute an HTTP request with Bearer token authentication.
/// Shared by every REST provider (Gmail, Exchange, Google Calendar, Exchange Calendar, BackendClient).
/// Handles URL construction, headers, Content-Type for JSON body, and optional error logging.
/// With a `gate`, the request holds one of its slots while it is on the wire.
func performHTTPRequest(
    url urlString: String,
    method: String,
    body: Data?,
    token: String,
    extraHeaders: [String: String] = [:],
    session: URLSession? = nil,
    logLabel: String? = nil,
    gate: HTTPConcurrencyGate? = nil
) async throws -> HTTPRequestResult {
    let session = session ?? sharedEphemeralSession
    guard let url = URL(string: urlString) else {
        throw HTTPError.invalidURL(urlString)
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // Timezone header — every shared API call carries this so prompts receive
    // `client_timezone` variable automatically.
    req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Client-Timezone")
    for (key, value) in extraHeaders {
        req.setValue(value, forHTTPHeaderField: key)
    }
    if let body {
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = if let gate {
        try await gate.withSlot { try await session.data(for: req) }
    } else {
        try await session.data(for: req)
    }
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    if 200..<300 ~= statusCode {
        return HTTPRequestResult(data: data, statusCode: statusCode)
    }

    if let logLabel, let errorBodyText = String(data: data, encoding: .utf8) {
        // Debug-gated with `#if DEBUG` rather than `DebugModeManager` because
        // `Shared/` also compiles into the NSE, where that type does not exist.
        #if DEBUG
        print("[\(logLabel)] HTTP \(statusCode) \(method) \(url): \(errorBodyText.prefix(500))")
        #endif
    }

    return HTTPRequestResult(
        data: nil, statusCode: statusCode, errorBody: data.isEmpty ? nil : data,
        retryAfter: retryAfterSeconds(response))
}

/// Execute an HTTP request with automatic retry on rate-limiting status codes,
/// up to `maxAttempts` retries. Each retry waits for the response's `Retry-After`
/// when it has one, as Graph asks ("Wait the number of seconds specified in the
/// Retry-After header"), and otherwise backs off exponentially (initialDelay, 2×,
/// 4×, ...). A `Retry-After` above `HTTPConfig.maxHonouredRetryAfterSeconds` ends
/// the retries and returns that response. Gmail retries `[429, 403]` (per-user
/// rateLimitExceeded is 403); Graph retries `[429, 503]`.
func performHTTPRequestWithRetry(
    url urlString: String,
    method: String,
    body: Data?,
    token: String,
    extraHeaders: [String: String] = [:],
    retryableStatusCodes: Set<Int> = [429],
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 1.0,
    session: URLSession? = nil,
    logLabel: String? = nil,
    gate: HTTPConcurrencyGate? = nil
) async throws -> HTTPRequestResult {
    var result = try await performHTTPRequest(
        url: urlString, method: method, body: body, token: token,
        extraHeaders: extraHeaders, session: session, logLabel: logLabel, gate: gate
    )

    if result.data != nil || !retryableStatusCodes.contains(result.statusCode) {
        return result
    }

    for attempt in 0..<maxAttempts {
        let delay: TimeInterval
        if let retryAfter = result.retryAfter {
            guard retryAfter <= HTTPConfig.maxHonouredRetryAfterSeconds else {
                if let logLabel {
                    #if DEBUG
                    print("[\(logLabel)] HTTP \(result.statusCode) asks to retry after \(retryAfter)s, longer than \(HTTPConfig.maxHonouredRetryAfterSeconds)s: not retrying now")
                    #endif
                }
                return result
            }
            delay = retryAfter
        } else {
            delay = initialDelay * Double(1 << attempt)
        }
        if let logLabel {
            #if DEBUG
            print("[\(logLabel)] Rate limited (\(result.statusCode)), retrying in \(delay)s (attempt \(attempt + 1)/\(maxAttempts))")
            #endif
        }
        try await Task.sleep(for: .seconds(delay))
        result = try await performHTTPRequest(
            url: urlString, method: method, body: body, token: token,
            extraHeaders: extraHeaders, session: session, logLabel: logLabel, gate: gate
        )
        if result.data != nil { return result }
        if !retryableStatusCodes.contains(result.statusCode) { break }
    }

    return result
}

enum HTTPError: Error, Sendable {
    case invalidURL(String)
    case networkError(statusCode: Int)
    /// Same failure shape as `.networkError`, but additionally carries the raw
    /// response body. Only `AuthedHTTP.requestPreservingBadRequestBody` (an
    /// explicit opt-in used by a handful of action-path call sites) produces
    /// this case, and only for a `400` response — every other failure status,
    /// and every ordinary `request()` call site, still throws the bodyless
    /// `.networkError` unchanged. Exists so a caller can structurally parse a
    /// provider-specific error payload (e.g. Gmail's invalid-label 400,
    /// Graph's `ErrorInvalidIdMalformed` 400) instead of guessing from the
    /// status code alone.
    case networkErrorWithBody(statusCode: Int, body: Data)
}
