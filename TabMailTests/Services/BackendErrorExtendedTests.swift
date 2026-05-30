/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendError Extended")
struct BackendErrorExtendedTests {

    // MARK: - 403 Backoff Behavior

    @Test("forbidden errorDescription mentions 403")
    func forbiddenDescription() {
        let desc = BackendError.forbidden.errorDescription!
        #expect(desc.contains("403"))
    }

    @Test("accountGone errorDescription is descriptive")
    func accountGoneDescription() {
        let desc = BackendError.accountGone.errorDescription!
        #expect(!desc.isEmpty)
    }

    @Test("unauthorized errorDescription mentions 401")
    func unauthorizedDescription() {
        let desc = BackendError.unauthorized.errorDescription!
        #expect(desc.contains("401"))
    }

    // MARK: - isRetriable boundary cases

    @Test("499 is not retriable (unknown 4xx)")
    func status499NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 499).isRetriable == false)
    }

    @Test("504 gateway timeout is retriable (5xx)")
    func status504Retriable() {
        #expect(BackendError.requestFailed(statusCode: 504).isRetriable == true)
    }

    @Test("599 is retriable (5xx)")
    func status599Retriable() {
        #expect(BackendError.requestFailed(statusCode: 599).isRetriable == true)
    }

    @Test("600 is not retriable (outside 5xx range)")
    func status600NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 600).isRetriable == false)
    }

    @Test("200 is not retriable (success codes shouldn't be errors)")
    func status200NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 200).isRetriable == false)
    }

    @Test("requestFailed description includes status code")
    func requestFailedDescriptionIncludesCode() {
        let errors: [Int] = [400, 404, 429, 500, 502, 503]
        for code in errors {
            let desc = BackendError.requestFailed(statusCode: code).errorDescription!
            #expect(desc.contains("\(code)"))
        }
    }

    // MARK: - Error conformance

    @Test("BackendError conforms to LocalizedError")
    func conformsToLocalizedError() {
        let error: any LocalizedError = BackendError.unauthorized
        #expect(error.errorDescription != nil)
    }

    @Test("BackendError conforms to Error")
    func conformsToError() {
        let error: any Error = BackendError.requestFailed(statusCode: 500)
        #expect(error.localizedDescription.contains("500"))
    }
}
