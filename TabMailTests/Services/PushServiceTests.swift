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

#if DEBUG
/// The unit-test host never raises the notification permission alert: nothing
/// answers it, and it keeps the host scene inactive for the rest of the run.
@Suite("Push permission policy")
struct PushPermissionPolicyTests {
    @Test("injected XCTest environments skip the request; a plain launch requests")
    func injectedEnvironmentDecision() {
        #expect(PushPermissionPolicy.decision(environment: [:]) == .request)
        #expect(PushPermissionPolicy.decision(environment: [
            "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"
        ]) == .skippedUnitTestHost)
        #expect(PushPermissionPolicy.decision(environment: [
            "XCTestBundlePath": "/tmp/TabMailTests.xctest"
        ]) == .skippedUnitTestHost)
    }

    @Test("the app-hosted unit-test host skips the notification request")
    func unitTestHostSkipsRequest() {
        let environment = ProcessInfo.processInfo.environment
        let isXCTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        #expect(isXCTestHost, "this invariant must run in the ordinary XCTest app host")
        #expect(PushPermissionPolicy.hostDecision == .skippedUnitTestHost)
    }

    @Test("every path to the notification request goes through the policy guard")
    func requestIsGuarded() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "TabMailTests/Services/PushServiceTests.swift",
            with: "TabMail/Services/PushNotificationService.swift"), encoding: .utf8)
        let body = try #require(source.range(of: "func requestPermissionAndRegister() async {"))
        let request = try #require(source.range(of: "requestAuthorization(options:"))
        let guardLine = try #require(source.range(of: "guard PushPermissionPolicy.hostDecision == .request else"))
        #expect(body.upperBound < guardLine.lowerBound && guardLine.upperBound < request.lowerBound)
        #expect(source.components(separatedBy: "requestAuthorization(").count == 2,
                "one notification request site, behind the guard")
    }
}
#endif
