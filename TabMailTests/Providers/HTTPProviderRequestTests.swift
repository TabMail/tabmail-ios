/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - URLProtocol Mock

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func mockResponse(url: String, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// MARK: - Tests

@Suite("performHTTPRequest", .serialized)
struct HTTPProviderRequestTests {

    @Test("Returns data for 200 response")
    func success200() async throws {
        let session = mockSession()
        MockURLProtocol.handler = { request in
            let response = mockResponse(url: request.url!.absoluteString, statusCode: 200)
            return (response, Data("ok".utf8))
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok123", session: session
        )
        #expect(result.data != nil)
        #expect(result.statusCode == 200)
        #expect(String(data: result.data!, encoding: .utf8) == "ok")
    }

    @Test("Returns nil data for 4xx response")
    func error4xx() async throws {
        let session = mockSession()
        MockURLProtocol.handler = { request in
            let response = mockResponse(url: request.url!.absoluteString, statusCode: 401)
            return (response, Data("unauthorized".utf8))
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok123", session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 401)
    }

    @Test("Returns nil data for 5xx response")
    func error5xx() async throws {
        let session = mockSession()
        MockURLProtocol.handler = { request in
            let response = mockResponse(url: request.url!.absoluteString, statusCode: 500)
            return (response, Data("server error".utf8))
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok123", session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 500)
    }

    @Test("Sets Authorization Bearer header")
    func authHeader() async throws {
        let session = mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data())
        }

        _ = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "my-secret-token", session: session
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret-token")
    }

    @Test("Sets Content-Type for JSON body")
    func jsonBody() async throws {
        let session = mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data())
        }

        let body = Data("{\"key\":\"value\"}".utf8)
        _ = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "POST", body: body,
            token: "tok", session: session
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(capturedRequest?.httpMethod == "POST")
        // Note: httpBody is consumed by URLSession during sending and not preserved
        // on the URLRequest received by URLProtocol. Content-Type header confirms body was set.
    }

    @Test("No Content-Type when body is nil")
    func noBodyNoContentType() async throws {
        let session = mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data())
        }

        _ = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test("Extra headers are set")
    func extraHeaders() async throws {
        let session = mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data())
        }

        _ = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", extraHeaders: ["Prefer": "outlook.timezone=\"UTC\""],
            session: session
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Prefer") == "outlook.timezone=\"UTC\"")
    }

    @Test("Invalid URL throws HTTPError.invalidURL")
    func invalidURL() async {
        do {
            _ = try await performHTTPRequest(
                url: "", method: "GET", body: nil,
                token: "tok"
            )
            #expect(Bool(false), "Should have thrown")
        } catch {
            if case HTTPError.invalidURL = error {
                // expected
            } else {
                #expect(Bool(false), "Wrong error type: \(error)")
            }
        }
    }

    @Test("All 2xx status codes return data")
    func success2xxRange() async throws {
        let session = mockSession()
        for code in [200, 201, 204, 299] {
            MockURLProtocol.handler = { request in
                let response = mockResponse(url: request.url!.absoluteString, statusCode: code)
                return (response, Data("ok".utf8))
            }

            let result = try await performHTTPRequest(
                url: "https://api.test.com/data", method: "GET", body: nil,
                token: "tok", session: session
            )
            #expect(result.data != nil, "Expected data for status \(code)")
            #expect(result.statusCode == code)
        }
    }

    @Test("HTTPRequestResult stores fields correctly")
    func resultFields() {
        let data = Data("test".utf8)
        let result = HTTPRequestResult(data: data, statusCode: 201)
        #expect(result.data == data)
        #expect(result.statusCode == 201)

        let nilResult = HTTPRequestResult(data: nil, statusCode: 404)
        #expect(nilResult.data == nil)
        #expect(nilResult.statusCode == 404)
    }

    // MARK: - T4.H1 — a non-2xx body must survive to the caller
    //
    // Before T4.H1 the failure body was read off the wire and dropped on the
    // floor, so every downstream classifier had to guess from the status code
    // alone. These pin the INVARIANT ("the bytes the server sent with a
    // failure reach the caller, whole"), not the mechanism.

    @Test("A non-2xx response preserves the raw error body while data stays nil")
    func nonSuccessPreservesErrorBody() async throws {
        let session = mockSession()
        let serverBody = Data(#"{"error":{"code":400,"message":"Invalid label: Label_9"}}"#.utf8)
        MockURLProtocol.handler = { request in
            return (mockResponse(url: request.url!.absoluteString, statusCode: 400), serverBody)
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/messages/modify", method: "POST", body: nil,
            token: "tok", session: session
        )
        // `data` semantics are unchanged — failures still surface nil there.
        #expect(result.data == nil)
        #expect(result.statusCode == 400)
        #expect(result.errorBody == serverBody)
    }

    @Test("A 5xx response also preserves its error body")
    func serverErrorPreservesErrorBody() async throws {
        let session = mockSession()
        let serverBody = Data("upstream unavailable".utf8)
        MockURLProtocol.handler = { request in
            return (mockResponse(url: request.url!.absoluteString, statusCode: 503), serverBody)
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 503)
        #expect(result.errorBody == serverBody)
    }

    @Test("An empty non-2xx body leaves errorBody nil rather than empty Data")
    func emptyErrorBodyStaysNil() async throws {
        let session = mockSession()
        MockURLProtocol.handler = { request in
            return (mockResponse(url: request.url!.absoluteString, statusCode: 400), Data())
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session
        )
        #expect(result.statusCode == 400)
        // nil, not Data() — "no payload to classify" must be distinguishable
        // from "a payload that happens to be zero bytes".
        #expect(result.errorBody == nil)
    }

    @Test("A 2xx response leaves errorBody nil — success payloads belong in data")
    func successLeavesErrorBodyNil() async throws {
        let session = mockSession()
        MockURLProtocol.handler = { request in
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data("ok".utf8))
        }

        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session
        )
        #expect(result.data != nil)
        #expect(result.errorBody == nil)
    }

    @Test("errorBody carries the whole body — the 500-character cap is the log line's, not the data's")
    func errorBodyIsNeverTruncated() async throws {
        let session = mockSession()
        // Deliberately far past the 500-character prefix `performHTTPRequest`
        // applies to its human-readable log line, so a body-side cap would show up.
        let filler = String(repeating: "x", count: 4096)
        let serverBody = Data(#"{"error":{"message":"\#(filler)"}}"#.utf8)
        MockURLProtocol.handler = { request in
            return (mockResponse(url: request.url!.absoluteString, statusCode: 400), serverBody)
        }

        // `logLabel` non-nil so the capped log path actually runs alongside the capture.
        let result = try await performHTTPRequest(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session, logLabel: "T4.H1"
        )
        #expect(result.errorBody?.count == serverBody.count)
        #expect(result.errorBody == serverBody)
    }

    @Test("HTTPRequestResult.errorBody defaults to nil so pre-existing call sites are unchanged")
    func errorBodyDefaultsToNil() {
        // The two-argument memberwise init must still exist — every production and
        // test construction predating T4.H1 relies on it.
        let result = HTTPRequestResult(data: nil, statusCode: 500)
        #expect(result.errorBody == nil)

        let withBody = HTTPRequestResult(data: nil, statusCode: 400, errorBody: Data("payload".utf8))
        #expect(withBody.errorBody == Data("payload".utf8))
    }
}

// MARK: - Retry Mock (separate from performHTTPRequest mock to avoid static handler conflicts)

private final class RetryMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func retryMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RetryMockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - performHTTPRequestWithRetry Tests

@Suite("performHTTPRequestWithRetry", .serialized)
struct HTTPProviderRetryTests {

    @Test("Returns data on first success (no retry needed)")
    func successNoRetry() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            return (mockResponse(url: request.url!.absoluteString, statusCode: 200), Data("ok".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", session: session
        )
        #expect(result.data != nil)
        #expect(result.statusCode == 200)
        #expect(callCount == 1)
    }

    @Test("Retries on 429 and succeeds")
    func retryOn429() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            let code = callCount == 1 ? 429 : 200
            return (mockResponse(url: request.url!.absoluteString, statusCode: code), Data("ok".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", retryableStatusCodes: [429], maxAttempts: 3,
            initialDelay: 0.01, session: session
        )
        #expect(result.data != nil)
        #expect(callCount == 2)
    }

    @Test("Retries on custom status codes (429 and 403)")
    func retryOnCustomCodes() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            let code = callCount == 1 ? 403 : 200
            return (mockResponse(url: request.url!.absoluteString, statusCode: code), Data("ok".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", retryableStatusCodes: [429, 403], maxAttempts: 3,
            initialDelay: 0.01, session: session
        )
        #expect(result.data != nil)
        #expect(callCount == 2)
    }

    @Test("Gives up after max attempts and returns last result")
    func exhaustsRetries() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            return (mockResponse(url: request.url!.absoluteString, statusCode: 429), Data("rate limited".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", retryableStatusCodes: [429], maxAttempts: 3,
            initialDelay: 0.01, session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 429)
        #expect(callCount == 4) // 1 initial + 3 retries
    }

    @Test("Does not retry on non-retryable status codes")
    func noRetryOnOtherCodes() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            return (mockResponse(url: request.url!.absoluteString, statusCode: 401), Data("unauth".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", retryableStatusCodes: [429], maxAttempts: 3,
            initialDelay: 0.01, session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 401)
        #expect(callCount == 1)
    }

    @Test("Stops retrying when status changes to non-retryable")
    func stopsOnNonRetryable() async throws {
        let session = retryMockSession()
        var callCount = 0
        RetryMockURLProtocol.handler = { request in
            callCount += 1
            // First 429, then 500 (not retryable)
            let code = callCount == 1 ? 429 : 500
            return (mockResponse(url: request.url!.absoluteString, statusCode: code), Data("err".utf8))
        }

        let result = try await performHTTPRequestWithRetry(
            url: "https://api.test.com/data", method: "GET", body: nil,
            token: "tok", retryableStatusCodes: [429], maxAttempts: 3,
            initialDelay: 0.01, session: session
        )
        #expect(result.data == nil)
        #expect(result.statusCode == 500)
        #expect(callCount == 2)
    }
}
