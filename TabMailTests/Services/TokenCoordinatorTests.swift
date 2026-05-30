/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - TabMailTokenCoordinator.RefreshResult

@Suite("TabMailTokenCoordinator.RefreshResult")
struct RefreshResultTests {

    @Test("success carries access token string")
    func successCarriesToken() {
        let result = TabMailTokenCoordinator.RefreshResult.success("test_token_abc")
        if case .success(let token) = result {
            #expect(token == "test_token_abc")
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }

    @Test("success with empty token")
    func successEmptyToken() {
        let result = TabMailTokenCoordinator.RefreshResult.success("")
        if case .success(let token) = result {
            #expect(token == "")
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }

    @Test("permanentFailure is a distinct case")
    func permanentFailure() {
        let result = TabMailTokenCoordinator.RefreshResult.permanentFailure
        if case .permanentFailure = result {
            // pass
        } else {
            #expect(Bool(false), "Expected permanentFailure case")
        }
    }

    @Test("transientFailure is a distinct case")
    func transientFailure() {
        let result = TabMailTokenCoordinator.RefreshResult.transientFailure
        if case .transientFailure = result {
            // pass
        } else {
            #expect(Bool(false), "Expected transientFailure case")
        }
    }

    @Test("noSession is a distinct case")
    func noSession() {
        let result = TabMailTokenCoordinator.RefreshResult.noSession
        if case .noSession = result {
            // pass
        } else {
            #expect(Bool(false), "Expected noSession case")
        }
    }

    @Test("All four cases are distinguishable")
    func allCasesDistinguishable() {
        let cases: [TabMailTokenCoordinator.RefreshResult] = [
            .success("tok"),
            .permanentFailure,
            .transientFailure,
            .noSession,
        ]

        // Each case should match only itself
        for (i, result) in cases.enumerated() {
            switch result {
            case .success:
                #expect(i == 0)
            case .permanentFailure:
                #expect(i == 1)
            case .transientFailure:
                #expect(i == 2)
            case .noSession:
                #expect(i == 3)
            }
        }
    }

    @Test("RefreshResult conforms to Sendable")
    func sendableConformance() {
        // This test verifies at compile time that RefreshResult is Sendable.
        // If it weren't, this would fail to compile in strict concurrency mode.
        let result: any Sendable = TabMailTokenCoordinator.RefreshResult.success("token")
        _ = result
    }

    @Test("success preserves long token strings")
    func longToken() {
        let longToken = String(repeating: "a", count: 2048)
        let result = TabMailTokenCoordinator.RefreshResult.success(longToken)
        if case .success(let token) = result {
            #expect(token.count == 2048)
            #expect(token == longToken)
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }
}
