/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the bug fixes around OAuth-failure routing in the
/// Gmail/Outlook consent gate (`AddAccountGmailOutlookView`).
///
/// History — these are the regression cases:
/// 1. Pre-fix, the catch block in `commitGmailOutlookAdd` only knew
///    about `CancellationError`; the actual cancel surfaces as
///    `NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1)`.
///    That fell into the generic catch, which cleared `PendingAccountAdd`
///    and dropped the user into `AddAccountGeneralView` — looked like
///    the gate had silently been bypassed.
/// 2. The view's spinner stayed on forever because `onConnect` was
///    sync and never signalled completion to reset `isProceeding`.
/// 3. Real failures (network, server) used to clear pending too. The
///    rule is now: **only No Thanks routes out of the gate; any
///    failure keeps the gate visible with the error inline**.
@Suite("ConnectErrorClassifier")
struct ConnectErrorClassifierTests {

    @Test("Swift task CancellationError → silent retry")
    func cancellationErrorIsSilent() {
        let outcome = ConnectErrorClassifier.classify(CancellationError())
        #expect(outcome == .silentRetry)
    }

    @Test("ASWebAuthenticationSession canceledLogin (code 1) → silent retry — regression for the silent-route bug")
    func asWebAuthCanceledLoginIsSilent() {
        let error = NSError(
            domain: ConnectErrorClassifier.asWebAuthSessionDomain,
            code: ConnectErrorClassifier.asWebAuthCanceledLoginCode
        )
        let outcome = ConnectErrorClassifier.classify(error)
        #expect(outcome == .silentRetry)
    }

    @Test("ASWebAuthenticationSession presentationContextNotProvided (code 2) → user-visible error")
    func asWebAuthOtherCodesAreError() {
        let error = NSError(
            domain: ConnectErrorClassifier.asWebAuthSessionDomain,
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "presentation context not provided"]
        )
        let outcome = ConnectErrorClassifier.classify(error)
        guard case .showError(let message) = outcome else {
            Issue.record("Expected .showError, got \(outcome)")
            return
        }
        #expect(message.contains("presentation context not provided"))
    }

    @Test("Network timeout → user-visible error with description")
    func networkErrorIsShown() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        let outcome = ConnectErrorClassifier.classify(error)
        guard case .showError(let message) = outcome else {
            Issue.record("Expected .showError, got \(outcome)")
            return
        }
        #expect(message.contains("timed out"))
        #expect(message.contains("try again"))
    }

    @Test("Generic Swift Error from server response → user-visible error")
    func genericErrorIsShown() {
        struct ServerError: Error, LocalizedError {
            var errorDescription: String? { "HTTP 500: internal server error" }
        }
        let outcome = ConnectErrorClassifier.classify(ServerError())
        guard case .showError(let message) = outcome else {
            Issue.record("Expected .showError, got \(outcome)")
            return
        }
        #expect(message.contains("HTTP 500"))
    }

    @Test("Different domain with code 1 → still user-visible error (not silent)")
    func unrelatedDomainCode1IsShown() {
        // Make sure we match the FULL (domain, code) tuple — code 1
        // alone in some random domain shouldn't be treated as a
        // cancel. Otherwise we'd silently swallow real errors that
        // happen to use code 1.
        let error = NSError(
            domain: "com.example.SomethingElse",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "real failure"]
        )
        let outcome = ConnectErrorClassifier.classify(error)
        guard case .showError = outcome else {
            Issue.record("Expected .showError, got \(outcome)")
            return
        }
    }

    @Test("ASWebAuth domain with non-1 code → still user-visible (not silent by domain alone)")
    func asWebAuthDomainOtherCodeIsShown() {
        let error = NSError(
            domain: ConnectErrorClassifier.asWebAuthSessionDomain,
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "weird auth failure"]
        )
        let outcome = ConnectErrorClassifier.classify(error)
        guard case .showError = outcome else {
            Issue.record("Expected .showError, got \(outcome)")
            return
        }
    }
}
