/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendError isRetriable")
struct BackendErrorRetriableTests {

    @Test("forbidden is not retriable")
    func forbiddenNotRetriable() {
        let error = BackendError.forbidden
        #expect(error.isRetriable == false)
    }

    @Test("unauthorized is not retriable")
    func unauthorizedNotRetriable() {
        let error = BackendError.unauthorized
        #expect(error.isRetriable == false)
    }

    @Test("accountGone is not retriable")
    func accountGoneNotRetriable() {
        let error = BackendError.accountGone
        #expect(error.isRetriable == false)
    }

    @Test("requestFailed 403 is not retriable")
    func status403NotRetriable() {
        let error = BackendError.requestFailed(statusCode: 403)
        #expect(error.isRetriable == false)
    }

    @Test("requestFailed 400 is not retriable")
    func status400NotRetriable() {
        let error = BackendError.requestFailed(statusCode: 400)
        #expect(error.isRetriable == false)
    }

    @Test("requestFailed 429 is retriable")
    func status429IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 429)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 408 is retriable")
    func status408IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 408)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 500 is retriable")
    func status500IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 500)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 502 is retriable")
    func status502IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 502)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 503 is retriable")
    func status503IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 503)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 0 (network failure) is retriable")
    func status0IsRetriable() {
        let error = BackendError.requestFailed(statusCode: 0)
        #expect(error.isRetriable == true)
    }

    @Test("requestFailed 404 is not retriable")
    func status404NotRetriable() {
        let error = BackendError.requestFailed(statusCode: 404)
        #expect(error.isRetriable == false)
    }

    @Test("requestFailed 422 is not retriable")
    func status422NotRetriable() {
        let error = BackendError.requestFailed(statusCode: 422)
        #expect(error.isRetriable == false)
    }
}
