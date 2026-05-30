/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - PushError

@Suite("PushError")
struct PushErrorTests {

    @Test("noAuthToken is an Error")
    func noAuthTokenConformsToError() {
        let error: Error = PushError.noAuthToken
        #expect(error is PushError)
    }

    @Test("requestFailed carries status code")
    func requestFailedCarriesStatusCode() {
        let error = PushError.requestFailed(statusCode: 403)
        if case .requestFailed(let code) = error {
            #expect(code == 403)
        } else {
            #expect(Bool(false), "Expected requestFailed case")
        }
    }

    @Test("requestFailed with 0 status code")
    func requestFailedZeroStatusCode() {
        let error = PushError.requestFailed(statusCode: 0)
        if case .requestFailed(let code) = error {
            #expect(code == 0)
        } else {
            #expect(Bool(false), "Expected requestFailed case")
        }
    }

    @Test("requestFailed with 500 status code")
    func requestFailed500() {
        let error = PushError.requestFailed(statusCode: 500)
        if case .requestFailed(let code) = error {
            #expect(code == 500)
        } else {
            #expect(Bool(false), "Expected requestFailed case")
        }
    }

    @Test("noAuthToken and requestFailed are distinct cases")
    func distinctCases() {
        let noAuth = PushError.noAuthToken
        let reqFailed = PushError.requestFailed(statusCode: 401)

        if case .noAuthToken = noAuth {
            // pass
        } else {
            #expect(Bool(false), "Expected noAuthToken")
        }

        if case .requestFailed = reqFailed {
            // pass
        } else {
            #expect(Bool(false), "Expected requestFailed")
        }
    }

    @Test("requestFailed preserves various HTTP status codes")
    func variousStatusCodes() {
        let codes = [200, 301, 400, 401, 403, 404, 429, 500, 502, 503]
        for code in codes {
            let error = PushError.requestFailed(statusCode: code)
            if case .requestFailed(let c) = error {
                #expect(c == code, "Expected status code \(code)")
            }
        }
    }

    @Test("PushError has non-empty localizedDescription")
    func localizedDescription() {
        let noAuth: Error = PushError.noAuthToken
        let reqFailed: Error = PushError.requestFailed(statusCode: 404)
        #expect(!noAuth.localizedDescription.isEmpty)
        #expect(!reqFailed.localizedDescription.isEmpty)
    }
}
