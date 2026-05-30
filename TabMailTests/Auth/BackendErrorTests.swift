/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendError")
struct BackendErrorTests {

    // MARK: - isRetriable classification

    @Test("unauthorized is not retriable")
    func unauthorizedNotRetriable() {
        #expect(BackendError.unauthorized.isRetriable == false)
    }

    @Test("accountGone is not retriable")
    func accountGoneNotRetriable() {
        #expect(BackendError.accountGone.isRetriable == false)
    }

    @Test("forbidden is not retriable (handled by 403 backoff)")
    func forbiddenNotRetriable() {
        #expect(BackendError.forbidden.isRetriable == false)
    }

    @Test("429 rate limit is retriable")
    func rateLimitRetriable() {
        #expect(BackendError.requestFailed(statusCode: 429).isRetriable == true)
    }

    @Test("500 server error is retriable")
    func serverErrorRetriable() {
        #expect(BackendError.requestFailed(statusCode: 500).isRetriable == true)
    }

    @Test("502 bad gateway is retriable")
    func badGatewayRetriable() {
        #expect(BackendError.requestFailed(statusCode: 502).isRetriable == true)
    }

    @Test("503 service unavailable is retriable")
    func serviceUnavailableRetriable() {
        #expect(BackendError.requestFailed(statusCode: 503).isRetriable == true)
    }

    @Test("408 timeout is retriable")
    func timeoutRetriable() {
        #expect(BackendError.requestFailed(statusCode: 408).isRetriable == true)
    }

    @Test("0 (network failure) is retriable")
    func networkFailureRetriable() {
        #expect(BackendError.requestFailed(statusCode: 0).isRetriable == true)
    }

    @Test("400 bad request is not retriable")
    func badRequestNotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 400).isRetriable == false)
    }

    @Test("401 via requestFailed is not retriable")
    func requestFailed401NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 401).isRetriable == false)
    }

    @Test("403 via requestFailed is not retriable")
    func requestFailed403NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 403).isRetriable == false)
    }

    @Test("404 not found is not retriable")
    func notFoundNotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 404).isRetriable == false)
    }

    @Test("422 unprocessable is not retriable")
    func unprocessableNotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 422).isRetriable == false)
    }

    // MARK: - errorDescription

    @Test("All error cases have descriptions")
    func errorDescriptions() {
        #expect(BackendError.unauthorized.errorDescription != nil)
        #expect(BackendError.accountGone.errorDescription != nil)
        #expect(BackendError.forbidden.errorDescription != nil)
        #expect(BackendError.requestFailed(statusCode: 500).errorDescription != nil)
    }

    @Test("requestFailed includes status code in description")
    func requestFailedDescription() {
        let desc = BackendError.requestFailed(statusCode: 500).errorDescription!
        #expect(desc.contains("500"))
    }
}
