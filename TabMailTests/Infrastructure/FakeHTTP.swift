/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// URLProtocol-based HTTP mock for provider tests.
///
/// Usage:
/// ```swift
/// let http = FakeHTTP.Scenario()
/// defer { http.close() }
/// http.register(
///     path: "/messages/m-1",
///     method: "GET",
///     response: .json(fixture: "Gmail/message-nested-eml.json")
/// )
/// let provider = GmailProvider(
///     userEmail: "user@example.com",
///     accessToken: { _ in "tok" },
///     session: http.session
/// )
/// // ... exercise provider; assertions check marker HTML / attachments.
/// ```
///
/// Matching is path-prefix + method. The longest matching prefix wins; for
/// equal-length matches, the first registration wins. Unmatched requests return
/// HTTP 599 with an explanatory body so test output pinpoints the missing fixture.
///
/// Fixtures live under `TabMailTests/Fixtures/` and are sourced from the cited
/// reference URLs in `Fixtures/README.md`. NEVER author fixtures from memory.
final class FakeHTTP: URLProtocol, @unchecked Sendable {

    private static let scopeHeader = "X-TabMail-Test-HTTP-Scope"

    // MARK: - Registration API

    /// Canned response for a matched request.
    struct CannedResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let transportErrorCode: URLError.Code?

        private init(
            statusCode: Int,
            headers: [String: String],
            body: Data,
            transportErrorCode: URLError.Code? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.transportErrorCode = transportErrorCode
        }

        /// Build a JSON response from a fixture file in `TabMailTests/Fixtures/`.
        /// Path is relative to the `Fixtures/` root, e.g. `"Gmail/message.json"`.
        static func json(fixture path: String, statusCode: Int = 200) -> CannedResponse {
            let url = Bundle(for: FakeHTTP.self).url(forResource: "Fixtures/" + path, withExtension: nil)
                ?? Bundle(for: FakeHTTP.self).resourceURL?.appendingPathComponent(path)
                ?? URL(fileURLWithPath: "/dev/null")
            let data = (try? Data(contentsOf: url)) ?? Data()
            return CannedResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }

        /// Build a JSON response from a raw string literal (synthetic, for tests
        /// that don't warrant a full fixture file).
        static func json(raw: String, statusCode: Int = 200) -> CannedResponse {
            CannedResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                body: Data(raw.utf8)
            )
        }

        /// Build a response with arbitrary binary body (e.g. a file attachment).
        static func bytes(_ data: Data, contentType: String = "application/octet-stream", statusCode: Int = 200) -> CannedResponse {
            CannedResponse(
                statusCode: statusCode,
                headers: ["Content-Type": contentType],
                body: data
            )
        }

        /// Build a response with given status code only (for testing error paths).
        static func status(_ code: Int) -> CannedResponse {
            CannedResponse(statusCode: code, headers: [:], body: Data())
        }

        /// Fail the request at the URL-loading boundary without fabricating an
        /// HTTP response. This pins provider behavior for real transport errors.
        static func transportError(_ code: URLError.Code) -> CannedResponse {
            CannedResponse(
                statusCode: 0,
                headers: [:],
                body: Data(),
                transportErrorCode: code
            )
        }
    }

    /// Immutable request snapshot passed to a stateful test response handler.
    /// The handler remains synchronous because `URLProtocol.startLoading()` is
    /// synchronous; mutable provider models should protect their state with
    /// `Mutex`, just like the fake's own registry.
    struct Request: Sendable {
        let method: String
        let url: URL
        let body: Data?
    }

    fileprivate enum RegisteredResponse: Sendable {
        case canned(CannedResponse)
        case dynamic(@Sendable (Request) -> CannedResponse)

        func response(for request: Request) -> CannedResponse {
            switch self {
            case .canned(let response): response
            case .dynamic(let handler): handler(request)
            }
        }
    }

    private struct Matcher: Sendable {
        let method: String
        let pathPrefix: String
        let response: RegisteredResponse
    }

    private struct State: Sendable {
        var matchers: [Matcher] = []
        /// Records every request the fake served — test assertions can verify a
        /// fallback call was made (e.g. Exchange's second-round
        /// `microsoft.graph.itemattachment/item/attachments` call) or inspect an
        /// exact provider payload at the HTTP boundary.
        var calls: [(method: String, url: String, body: Data?)] = []
    }

    fileprivate final class StateBox: Sendable {
        private let state = Mutex(State())

        func register(path: String, method: String, response: RegisteredResponse) {
            state.withLock { value in
                value.matchers.append(Matcher(
                    method: method.uppercased(),
                    pathPrefix: path,
                    response: response
                ))
            }
        }

        func take(method: String, url: URL, body: Data?) -> CannedResponse? {
            let registered: RegisteredResponse? = state.withLock { value in
                value.calls.append((method: method.uppercased(), url: url.absoluteString, body: body))
                var best: (length: Int, response: RegisteredResponse)?
                for matcher in value.matchers {
                    guard matcher.method == method.uppercased() else { continue }
                    let hit = url.path.hasPrefix(matcher.pathPrefix)
                        || url.absoluteString.contains(matcher.pathPrefix)
                    guard hit else { continue }
                    if best == nil || matcher.pathPrefix.count > best!.length {
                        best = (matcher.pathPrefix.count, matcher.response)
                    }
                }
                return best?.response
            }
            return registered?.response(for: Request(
                method: method.uppercased(),
                url: url,
                body: body
            ))
        }

        func recordedCalls() -> [(method: String, url: String, body: Data?)] {
            state.withLock { $0.calls }
        }

        func reset() {
            state.withLock { value in
                value.matchers.removeAll()
                value.calls.removeAll()
            }
        }
    }

    private static let registry = Mutex<[String: StateBox]>([:])

    /// Per-test HTTP namespace. Its registrations, request log, and reset/close
    /// lifecycle cannot affect another scenario, even when both URLSessions
    /// request the same method and URL concurrently.
    final class Scenario: @unchecked Sendable {
        fileprivate let id: String
        fileprivate let box: StateBox
        private let isClosed = Mutex(false)

        let session: URLSession

        init() {
            let id = UUID().uuidString
            self.id = id
            self.box = StateBox()
            self.session = FakeHTTP.makeSession(scopeID: id)
            FakeHTTP.registry.withLock { $0[id] = box }
        }

        fileprivate init(id: String) {
            self.id = id
            self.box = StateBox()
            self.session = FakeHTTP.makeSession(scopeID: id)
            FakeHTTP.registry.withLock { $0[id] = box }
        }

        func register(path: String, method: String = "GET", response: CannedResponse) {
            box.register(path: path, method: method, response: .canned(response))
        }

        /// Register a synchronous stateful response. The handler runs outside
        /// FakeHTTP's registry lock, so it may safely own an independent Mutex
        /// model and derive each response from prior requests.
        func register(
            path: String,
            method: String = "GET",
            handler: @escaping @Sendable (Request) -> CannedResponse
        ) {
            box.register(path: path, method: method, response: .dynamic(handler))
        }

        func recordedCalls() -> [(method: String, url: String, body: Data?)] {
            box.recordedCalls()
        }

        func reset() {
            box.reset()
        }

        /// Invalidates this scenario's session and unregisters only this
        /// scenario. Safe to call more than once and from `defer`.
        func close() {
            let shouldClose = isClosed.withLock { closed in
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }

            session.invalidateAndCancel()
            box.reset()
            FakeHTTP.registry.withLock { values in
                guard values[id] === box else { return }
                _ = values.removeValue(forKey: id)
            }
        }

        deinit {
            close()
        }
    }

    /// Transitional namespace for the still-serialized Exchange mock suite.
    /// New and migrated tests must use `Scenario` instead of these static APIs.
    private static let legacyScenario = Scenario(id: "legacy")

    /// Register a canned response. Matched on `httpMethod` + URL path-prefix.
    static func register(path: String, method: String = "GET", response: CannedResponse) {
        legacyScenario.register(path: path, method: method, response: response)
    }

    /// Record a call and return the response, if any matcher fits.
    ///
    /// Match rule: longest `pathPrefix` wins. A path-prefix OR substring-of-
    /// `absoluteString` match is accepted (so query strings in registrations,
    /// e.g. `"/messages/m-1?format=full"`, work too). Longest-prefix is
    /// important because a generic `/attachments` registration must not
    /// swallow more specific `/attachments/{id}?$expand=...` calls.
    fileprivate static func take(
        request: URLRequest,
        method: String,
        url: URL,
        body: Data?
    ) -> CannedResponse? {
        let box: StateBox?
        if let scopeID = request.value(forHTTPHeaderField: scopeHeader) {
            box = registry.withLock { $0[scopeID] }
        } else {
            box = legacyScenario.box
        }
        return box?.take(method: method, url: url, body: body)
    }

    /// Return every request the fake has served so far.
    static func recordedCalls() -> [(method: String, url: String, body: Data?)] {
        legacyScenario.recordedCalls()
    }

    /// Clear all registrations and call log. Call in each test's teardown.
    static func reset() {
        legacyScenario.reset()
    }

    /// Build a `URLSession` that routes through this protocol.
    static func makeSession() -> URLSession {
        makeSession(scopeID: legacyScenario.id)
    }

    private static func makeSession(scopeID: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHTTP.self] + (config.protocolClasses ?? [])
        config.httpAdditionalHeaders = [scopeHeader: scopeID]
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return fail(code: 400, body: "no url") }
        let method = request.httpMethod ?? "GET"

        guard let canned = FakeHTTP.take(
            request: request,
            method: method,
            url: url,
            body: Self.bodyData(from: request)
        ) else {
            return fail(code: 599, body: "FakeHTTP: no matcher for \(method) \(url)")
        }

        if let transportErrorCode = canned.transportErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(transportErrorCode))
            return
        }

        let http = HTTPURLResponse(
            url: url,
            statusCode: canned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: canned.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func fail(code: Int, body: String) {
        let url = request.url ?? URL(string: "about:blank")!
        let http = HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
