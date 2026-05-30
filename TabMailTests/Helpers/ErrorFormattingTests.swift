/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Error with a controlled localizedDescription for testing.
private struct FakeError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

@Suite("Error.userFacingDescription")
struct ErrorUserFacingDescriptionTests {

    // MARK: - Strips technical parenthesized domains

    @Test("Strips ASWebAuthenticationSession error domain")
    func stripsASWebAuth() {
        let error = FakeError(msg: "The operation couldn't be completed. (com.apple.AuthenticationServices.WebAuthenticationSession error 1.)")
        #expect(error.userFacingDescription == "The operation couldn't be completed.")
    }

    @Test("Strips NSURLErrorDomain")
    func stripsNSURLError() {
        let error = FakeError(msg: "The operation couldn't be completed. (NSURLErrorDomain error -1009.)")
        #expect(error.userFacingDescription == "The operation couldn't be completed.")
    }

    @Test("Strips kCFErrorDomainCFNetwork")
    func stripsCFNetwork() {
        let error = FakeError(msg: "The operation couldn't be completed. (kCFErrorDomainCFNetwork error 303.)")
        #expect(error.userFacingDescription == "The operation couldn't be completed.")
    }

    @Test("Strips Foundation._GenericObjCError domain")
    func stripsGenericObjCError() {
        let error = FakeError(msg: "The operation couldn't be completed. (Foundation._GenericObjCError error 0.)")
        #expect(error.userFacingDescription == "The operation couldn't be completed.")
    }

    // MARK: - Preserves user-friendly messages

    @Test("Preserves message without parentheses")
    func noParens() {
        let error = FakeError(msg: "Authentication failed. Please check your credentials.")
        #expect(error.userFacingDescription == "Authentication failed. Please check your credentials.")
    }

    @Test("Preserves parenthesized text without dots")
    func parensNoDots() {
        let error = FakeError(msg: "Something failed (please try again)")
        #expect(error.userFacingDescription == "Something failed (please try again)")
    }

    @Test("Preserves simple error messages")
    func simpleMessage() {
        let error = FakeError(msg: "Connection refused")
        #expect(error.userFacingDescription == "Connection refused")
    }

    // MARK: - Edge cases

    @Test("Falls back to full message when stripping leaves empty string")
    func emptyAfterStrip() {
        let error = FakeError(msg: "(com.apple.error.thing)")
        #expect(error.userFacingDescription == "(com.apple.error.thing)")
    }

    @Test("Handles multiple parenthesized groups with dots")
    func multipleParens() {
        let error = FakeError(msg: "Failed (foo.bar) then (baz.qux)")
        #expect(error.userFacingDescription == "Failed then")
    }

    @Test("Handles empty error message")
    func emptyMessage() {
        let error = FakeError(msg: "")
        #expect(error.userFacingDescription == "")
    }

    @Test("Preserves HTTP status codes in parens without dots")
    func httpStatusInParens() {
        let error = FakeError(msg: "Unauthorized (401)")
        #expect(error.userFacingDescription == "Unauthorized (401)")
    }

    @Test("Strips real NSError from ASWebAuthenticationSession cancel")
    func realASWebAuthCancel() {
        // This is the exact error the user reported
        let nsError = NSError(
            domain: "com.apple.AuthenticationServices.WebAuthenticationSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (com.apple.AuthenticationServices.WebAuthenticationSession error 1.)"]
        )
        let desc = nsError.userFacingDescription
        #expect(desc == "The operation couldn't be completed.")
    }

    @Test("Strips real URLError")
    func realURLError() {
        let error = URLError(.notConnectedToInternet)
        let desc = error.userFacingDescription
        // URLError localizedDescription varies by locale, but should not contain domain parens after stripping
        #expect(!desc.contains("NSURLErrorDomain"))
    }
}
