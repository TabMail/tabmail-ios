/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// URLProtocol-based HTTP mock for provider tests.
///
/// Usage:
/// ```swift
/// let session = FakeHTTP.makeSession()
/// FakeHTTP.register(
///     path: "/messages/m-1",
///     method: "GET",
///     response: .json(fixture: "Gmail/message-nested-eml.json")
/// )
/// let provider = GmailProvider(userEmail: "x@y", accessToken: { _ in "tok" }, session: session)
/// // ... exercise provider; assertions check marker HTML / attachments.
/// FakeHTTP.reset()  // in test tearDown.
/// ```
///
/// Matching is path-prefix + method. Registration order matters — the FIRST
/// matching entry wins. Unmatched requests return HTTP 599 with an explanatory
/// body so test output pinpoints the missing fixture.
///
/// Fixtures live under `TabMailTests/Fixtures/` and are sourced from the cited
/// reference URLs in `Fixtures/README.md`. NEVER author fixtures from memory.
final class FakeHTTP: URLProtocol, @unchecked Sendable {

    // MARK: - Registration API

    /// Canned response for a matched request.
    struct CannedResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

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
    }

    private struct Matcher: Sendable {
        let method: String
        let pathPrefix: String
        let response: CannedResponse
    }

    private struct State: Sendable {
        var matchers: [Matcher] = []
        /// Records every URL the fake served — test assertions can verify a
        /// fallback call was made (e.g. Exchange's second-round
        /// `microsoft.graph.itemattachment/item/attachments` call).
        var calls: [(method: String, url: String)] = []
    }

    private static let state = Mutex(State())

    /// Register a canned response. Matched on `httpMethod` + URL path-prefix.
    static func register(path: String, method: String = "GET", response: CannedResponse) {
        state.withLock { s in
            s.matchers.append(Matcher(method: method.uppercased(), pathPrefix: path, response: response))
        }
    }

    /// Record a call and return the response, if any matcher fits.
    ///
    /// Match rule: longest `pathPrefix` wins. A path-prefix OR substring-of-
    /// `absoluteString` match is accepted (so query strings in registrations,
    /// e.g. `"/messages/m-1?format=full"`, work too). Longest-prefix is
    /// important because a generic `/attachments` registration must not
    /// swallow more specific `/attachments/{id}?$expand=...` calls.
    fileprivate static func take(method: String, url: URL) -> CannedResponse? {
        state.withLock { s in
            s.calls.append((method: method.uppercased(), url: url.absoluteString))
            var best: (length: Int, response: CannedResponse)? = nil
            for m in s.matchers {
                guard m.method == method.uppercased() else { continue }
                let hit = url.path.hasPrefix(m.pathPrefix) || url.absoluteString.contains(m.pathPrefix)
                guard hit else { continue }
                if best == nil || m.pathPrefix.count > best!.length {
                    best = (m.pathPrefix.count, m.response)
                }
            }
            return best?.response
        }
    }

    /// Return all (method, url) pairs the fake has served so far.
    static func recordedCalls() -> [(method: String, url: String)] {
        state.withLock { $0.calls }
    }

    /// Clear all registrations and call log. Call in each test's teardown.
    static func reset() {
        state.withLock { s in
            s.matchers.removeAll()
            s.calls.removeAll()
        }
    }

    /// Build a `URLSession` that routes through this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHTTP.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return fail(code: 400, body: "no url") }
        let method = request.httpMethod ?? "GET"

        guard let canned = FakeHTTP.take(method: method, url: url) else {
            return fail(code: 599, body: "FakeHTTP: no matcher for \(method) \(url)")
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
