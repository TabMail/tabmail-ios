/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Every token request carries its code, verifier or refresh token to the
/// token endpoint exactly as given, whatever characters it holds: the endpoint
/// reads the body as a form, where `+` is a space and `&`/`=` split fields.
@Suite("OAuth token requests")
struct OAuthTokenRequestTests {
    static let values = ["4/0Ab+cd&e=f", "a b+c=d", "/x%2B%26y", "caf\u{e9}~-._"]

    private static func body(_ request: URLRequest) -> [String: [String]] {
        FormDecoding.fields(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    private static func isFormPost(_ request: URLRequest, to url: String) -> Bool {
        request.url?.absoluteString == url && request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
    }

    @Test("A Google code exchange sends the code and verifier as given", arguments: values)
    func googleCodeExchange(value: String) {
        let request = OAuthService.googleCodeExchangeRequest(code: value, codeVerifier: value + "v")
        let fields = Self.body(request)

        #expect(Self.isFormPost(request, to: "https://oauth2.googleapis.com/token"))
        #expect(fields["code"] == [value])
        #expect(fields["code_verifier"] == [value + "v"])
        #expect(fields["grant_type"] == ["authorization_code"])
        #expect(fields["client_id"] == [OAuthConfig.googleClientId])
        #expect(fields["redirect_uri"] == ["\(OAuthConfig.googleRedirectScheme):/oauthredirect"])
        #expect(Set(fields.keys) == ["client_id", "code", "code_verifier", "grant_type", "redirect_uri"])
    }

    @Test("A Google refresh sends the refresh token as given", arguments: values)
    func googleRefresh(value: String) {
        let request = OAuthService.googleRefreshRequest(refreshToken: value)
        let fields = Self.body(request)

        #expect(Self.isFormPost(request, to: "https://oauth2.googleapis.com/token"))
        #expect(fields["refresh_token"] == [value])
        #expect(fields["grant_type"] == ["refresh_token"])
        #expect(fields["client_id"] == [OAuthConfig.googleClientId])
        #expect(Set(fields.keys) == ["client_id", "refresh_token", "grant_type"])
    }

    @Test("A Microsoft code exchange sends the code, verifier and scope as given", arguments: values)
    func microsoftCodeExchange(value: String) {
        let request = OAuthService.microsoftCodeExchangeRequest(
            code: value, codeVerifier: value + "v", scope: OAuthConfig.microsoftScopes)
        let fields = Self.body(request)

        #expect(Self.isFormPost(request, to: "https://login.microsoftonline.com/common/oauth2/v2.0/token"))
        #expect(fields["code"] == [value])
        #expect(fields["code_verifier"] == [value + "v"])
        #expect(fields["scope"] == [OAuthConfig.microsoftScopes])
        #expect(fields["grant_type"] == ["authorization_code"])
        #expect(fields["client_id"] == [OAuthConfig.microsoftClientId])
        #expect(fields["redirect_uri"] == ["\(OAuthConfig.microsoftRedirectScheme)://auth"])
        #expect(Set(fields.keys) == ["client_id", "code", "code_verifier", "grant_type", "redirect_uri", "scope"])
    }

    @Test("A Microsoft refresh sends the refresh token and scope as given", arguments: values)
    func microsoftRefresh(value: String) {
        let request = OAuthService.microsoftRefreshRequest(refreshToken: value)
        let fields = Self.body(request)

        #expect(Self.isFormPost(request, to: "https://login.microsoftonline.com/common/oauth2/v2.0/token"))
        #expect(fields["refresh_token"] == [value])
        #expect(fields["scope"] == [OAuthConfig.microsoftScopes])
        #expect(fields["grant_type"] == ["refresh_token"])
        #expect(fields["client_id"] == [OAuthConfig.microsoftClientId])
        #expect(Set(fields.keys) == ["client_id", "refresh_token", "grant_type", "scope"])
    }
}
