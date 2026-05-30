/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendError Classification")
struct BackendErrorClassificationTests {

    @Test("isRetriable true for 429 rate limit")
    func retriable429() {
        let error = BackendError.requestFailed(statusCode: 429)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable true for 500 server error")
    func retriable500() {
        let error = BackendError.requestFailed(statusCode: 500)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable true for 502 bad gateway")
    func retriable502() {
        let error = BackendError.requestFailed(statusCode: 502)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable true for 503 service unavailable")
    func retriable503() {
        let error = BackendError.requestFailed(statusCode: 503)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable true for 408 timeout")
    func retriable408() {
        let error = BackendError.requestFailed(statusCode: 408)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable false for 401 unauthorized")
    func notRetriable401() {
        let error = BackendError.unauthorized
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable false for 403 forbidden")
    func notRetriable403() {
        let error = BackendError.forbidden
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable false for accountGone")
    func notRetriableAccountGone() {
        let error = BackendError.accountGone
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable false for 404 not found")
    func notRetriable404() {
        let error = BackendError.requestFailed(statusCode: 404)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable false for 400 bad request")
    func notRetriable400() {
        let error = BackendError.requestFailed(statusCode: 400)
        #expect(error.isRetriable == false)
    }
}

@Suite("BackendError Enum Cases")
struct BackendErrorCasesTests {

    @Test("unauthorized is an Error")
    func unauthorizedIsError() {
        let error: Error = BackendError.unauthorized
        #expect(error is BackendError)
    }

    @Test("forbidden is an Error")
    func forbiddenIsError() {
        let error: Error = BackendError.forbidden
        #expect(error is BackendError)
    }

    @Test("accountGone is an Error")
    func accountGoneIsError() {
        let error: Error = BackendError.accountGone
        #expect(error is BackendError)
    }

    @Test("requestFailed carries status code")
    func requestFailedStatusCode() {
        let error = BackendError.requestFailed(statusCode: 503)
        if case .requestFailed(let code) = error {
            #expect(code == 503)
        } else {
            #expect(Bool(false), "Expected requestFailed")
        }
    }

    @Test("isRetriable true for all 5xx codes")
    func retriableAll5xx() {
        for code in [500, 502, 503, 504] {
            let error = BackendError.requestFailed(statusCode: code)
            #expect(error.isRetriable == true, "Expected \(code) to be retriable")
        }
    }

    @Test("isRetriable false for client errors (4xx except 408/429)")
    func notRetriableClientErrors() {
        for code in [400, 401, 403, 404, 405, 409, 422] {
            let error = BackendError.requestFailed(statusCode: code)
            #expect(error.isRetriable == false, "Expected \(code) to NOT be retriable")
        }
    }
}
