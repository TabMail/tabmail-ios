/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// End-to-end URLProtocol-mocked tests for `AuthedHTTP` — verifies the actual
/// HTTP path through `performHTTPRequest` / `performHTTPRequestWithRetry`:
///   - 401 → refresh() → retry (exactly once) succeeds
///   - 401 after refresh surfaces as networkError (no infinite retry)
///   - `X-Client-Timezone` header is attached to every request
///   - Rate-limit retry (Gmail 403 / Graph 429) exponential backoff invokes refresh=0
///   - `requestAllowing404` returns status 404 instead of throwing
///
/// Uses URLProtocol injection via a custom URLSession passed to AuthedHTTP.
/// `.serialized` is required — tests share `MockURLProtocol.currentRecorder` static
/// state, so Swift Testing's default parallel execution would race them.
@Suite("Shared/HTTP AuthedHTTP — network-mocked contract", .serialized)
struct AuthedHTTPNetworkTests {

    // MARK: - URLProtocol mock infrastructure

    /// Test-scoped request handler. One per test — set before firing requests,
    /// MockURLProtocol pulls requests from it. Handler returns (status, body, headers?)
    /// and captures request metadata (headers, bearer) for assertions.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _responses: [(Int, Data)] = []
        private var _index: Int = 0

        init(responses: [(Int, Data)]) { self._responses = responses }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var requestCount: Int { lock.withLock { _requests.count } }

        func record(_ req: URLRequest) -> (Int, Data) {
            lock.withLock {
                _requests.append(req)
                let r = _responses[min(_index, _responses.count - 1)]
                _index += 1
                return r
            }
        }
    }

    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var currentRecorder: Recorder?
        // NSLock is Sendable, so a `let` constant doesn't need `nonisolated(unsafe)`.
        static let recorderLock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.recorderLock.lock()
            let recorder = Self.currentRecorder
            Self.recorderLock.unlock()

            guard let recorder else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let (status, body) = recorder.record(request)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static func makeSession(recorder: Recorder) -> URLSession {
        MockURLProtocol.recorderLock.lock()
        MockURLProtocol.currentRecorder = recorder
        MockURLProtocol.recorderLock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        return URLSession(configuration: cfg)
    }

    /// Minimal mutable-token auth source.
    final class TokenSource: AuthSource, @unchecked Sendable {
        let accountId: String = "test"
        private let lock = NSLock()
        private var _token: String
        private var _refreshCount = 0
        private var _nextRefreshToken: String

        init(initial: String, nextRefresh: String) {
            self._token = initial
            self._nextRefreshToken = nextRefresh
        }
        var refreshCount: Int { lock.withLock { _refreshCount } }
        func current() async -> String? { lock.withLock { _token } }
        func refresh() async throws -> String {
            lock.withLock { _refreshCount += 1; _token = _nextRefreshToken }
            return _nextRefreshToken
        }
    }

    // MARK: - Tests

    @Test("401 then 200 → refresh called once, second request uses new token, data returned")
    func refreshRetryHappyPath() async throws {
        let recorder = Recorder(responses: [
            (401, Data("unauth".utf8)),
            (200, Data(#"{"ok":true}"#.utf8)),
        ])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "old", nextRefresh: "new")
        let http = AuthedHTTP(auth: auth, retry: .graph, logLabel: nil, session: session)

        let data = try await http.get("https://example.test/v1/me")

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(auth.refreshCount == 1)
        #expect(recorder.requestCount == 2)
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old")
        #expect(recorder.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("401 after refresh surfaces as networkError — no further retries")
    func refreshRetryExhausted() async {
        let recorder = Recorder(responses: [
            (401, Data()),
            (401, Data()),
        ])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "old", nextRefresh: "new")
        let http = AuthedHTTP(auth: auth, retry: .graph, logLabel: nil, session: session)

        do {
            _ = try await http.get("https://example.test/v1/me")
            Issue.record("Expected networkError throw")
        } catch let HTTPError.networkError(statusCode: s) {
            #expect(s == 401)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
        #expect(auth.refreshCount == 1)
        #expect(recorder.requestCount == 2)
    }

    @Test("Every request carries the X-Client-Timezone header")
    func timezoneHeader() async throws {
        let recorder = Recorder(responses: [(200, Data("{}".utf8))])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "t", nextRefresh: "t")
        let http = AuthedHTTP(auth: auth, retry: .graph, logLabel: nil, session: session)

        _ = try await http.get("https://example.test/v1/me")
        let tz = recorder.requests.first?.value(forHTTPHeaderField: "X-Client-Timezone")
        #expect(tz != nil)
        #expect(tz == TimeZone.current.identifier)
    }

    @Test("Gmail policy retries on 403 (rateLimitExceeded); refresh not invoked")
    func rateLimitRetryNotAuth() async throws {
        let recorder = Recorder(responses: [
            (403, Data("rate".utf8)),
            (200, Data("{}".utf8)),
        ])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "t", nextRefresh: "t")
        // Short initialDelay so the test runs fast — still exercises the retry code path.
        let policy = HTTPRetryPolicy(retryableStatusCodes: [429, 403], maxAttempts: 2, initialDelay: 0.01)
        let http = AuthedHTTP(auth: auth, retry: policy, logLabel: nil, session: session)

        let data = try await http.get("https://example.test/v1/me")
        #expect(String(data: data, encoding: .utf8) == "{}")
        #expect(auth.refreshCount == 0)   // 403 is rate-limit, not auth
        #expect(recorder.requestCount == 2)
    }

    @Test("requestAllowing404 returns statusCode=404 instead of throwing")
    func allowing404ReturnsResult() async throws {
        let recorder = Recorder(responses: [(404, Data("expired".utf8))])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "t", nextRefresh: "t")
        let http = AuthedHTTP(auth: auth, retry: .gmail, logLabel: nil, session: session)

        let result = try await http.requestAllowing404(url: "https://example.test/history")
        #expect(result.statusCode == 404)
        #expect(result.data == nil)           // 404 = non-2xx, data becomes nil per performHTTPRequest contract
    }

    @Test("POST body + Content-Type header attached")
    func postBodyAndContentType() async throws {
        let recorder = Recorder(responses: [(200, Data("{}".utf8))])
        let session = Self.makeSession(recorder: recorder)
        let auth = TokenSource(initial: "t", nextRefresh: "t")
        let http = AuthedHTTP(auth: auth, retry: .graph, logLabel: nil, session: session)

        let payload = Data(#"{"a":1}"#.utf8)
        _ = try await http.post("https://example.test/v1/send", body: payload)
        let req = recorder.requests.first
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // URLRequest.httpBody is stripped by URLProtocol in some configurations —
        // check httpBodyStream as a fallback.
        let seenBody: Data? = req?.httpBody ?? req?.httpBodyStream.flatMap { stream in
            stream.open()
            defer { stream.close() }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }
        #expect(seenBody == payload)
    }
}
