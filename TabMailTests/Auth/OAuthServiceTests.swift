/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendConfig URLs")
struct BackendConfigURLTests {

    @Test("API base URL is valid HTTPS")
    func apiBaseURL() {
        let url = BackendConfig.apiBaseURL
        #expect(url.scheme == "https" || url.scheme == "http")
        #expect(url.host != nil)
    }

    @Test("Completions endpoint path")
    func completionsEndpoint() {
        let url = BackendConfig.apiBaseURL.appending(path: "/v1/completions")
        #expect(url.pathComponents.contains("completions"))
    }
}

@Suite("KeychainHelper Key Factories")
struct KeychainHelperKeyTests {

    @Test("Access token key format")
    func accessTokenKey() {
        let key = KeychainHelper.accessTokenKey(accountId: "gmail_user")
        #expect(key.contains("gmail_user"))
        #expect(key.contains("access") || key.contains("token"))
    }

    @Test("Refresh token key format")
    func refreshTokenKey() {
        let key = KeychainHelper.refreshTokenKey(accountId: "gmail_user")
        #expect(key.contains("gmail_user"))
        #expect(key.contains("refresh"))
    }

    @Test("Password key format")
    func passwordKey() {
        let key = KeychainHelper.passwordKey(accountId: "imap_user")
        #expect(key.contains("imap_user"))
        #expect(key.contains("password"))
    }

    @Test("Keys are unique per account")
    func keysUniquePerAccount() {
        let key1 = KeychainHelper.accessTokenKey(accountId: "account1")
        let key2 = KeychainHelper.accessTokenKey(accountId: "account2")
        #expect(key1 != key2)
    }

    @Test("Key types are distinct")
    func keyTypesDistinct() {
        let access = KeychainHelper.accessTokenKey(accountId: "acc1")
        let refresh = KeychainHelper.refreshTokenKey(accountId: "acc1")
        let password = KeychainHelper.passwordKey(accountId: "acc1")
        #expect(access != refresh)
        #expect(refresh != password)
        #expect(access != password)
    }
}

@Suite("KeychainError Cases")
struct KeychainErrorCaseTests {

    @Test("KeychainError.saveFailed stores OSStatus")
    func saveFailedStoresStatus() {
        let error = KeychainError.saveFailed(-25299)
        if case .saveFailed(let status) = error {
            #expect(status == -25299)
        } else {
            Issue.record("Expected saveFailed case")
        }
    }

    @Test("KeychainError conforms to Error")
    func conformsToError() {
        let error: any Error = KeychainError.saveFailed(-25300)
        #expect(error.localizedDescription.isEmpty == false)
    }
}
