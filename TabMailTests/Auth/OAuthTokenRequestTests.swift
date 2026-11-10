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

    // MARK: - The sign-in and refresh calls

    /// The four calls that reach a token endpoint during sign-in and renewal.
    enum Dispatch: String, CaseIterable, CustomTestStringConvertible {
        case googleCode, googleRefresh, microsoftCode, microsoftRefresh
        var testDescription: String { rawValue }
    }

    /// The requests the fake transport received, recorded from its handler thread.
    private final class SentRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FakeHTTP.Request] = []
        func append(_ request: FakeHTTP.Request) { lock.lock(); stored.append(request); lock.unlock() }
        var all: [FakeHTTP.Request] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Each call must send its own grant to its own provider's token endpoint:
    /// a refresh that went to the other provider, or a code sent as a refresh
    /// token, fails sign-in or renewal.
    @Test("Each sign-in and refresh call sends its own grant to its own provider", arguments: Dispatch.allCases)
    @MainActor
    func callSendsItsOwnGrant(dispatch: Dispatch) async throws {
        let value = Self.values[0]
        let verifier = value + "v"
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let sent = SentRequests()
        http.register(path: "token", method: "POST") { request in
            sent.append(request)
            return .json(raw: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#)
        }
        let service = OAuthService(tokenSession: http.session)

        let google = "https://oauth2.googleapis.com/token"
        let microsoft = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        let expected: (url: String, fields: [String: [String]])
        let tokens: OAuthTokens
        switch dispatch {
        case .googleCode:
            tokens = try await service.exchangeGoogleCode(value, codeVerifier: verifier)
            expected = (google, [
                "code": [value], "code_verifier": [verifier], "grant_type": ["authorization_code"],
                "client_id": [OAuthConfig.googleClientId],
                "redirect_uri": ["\(OAuthConfig.googleRedirectScheme):/oauthredirect"],
            ])
        case .googleRefresh:
            tokens = try await service.refreshGoogleToken(refreshToken: value)
            expected = (google, [
                "refresh_token": [value], "grant_type": ["refresh_token"], "client_id": [OAuthConfig.googleClientId],
            ])
        case .microsoftCode:
            tokens = try await service.exchangeMicrosoftCode(value, codeVerifier: verifier, scope: OAuthConfig.microsoftScopes)
            expected = (microsoft, [
                "code": [value], "code_verifier": [verifier], "scope": [OAuthConfig.microsoftScopes],
                "grant_type": ["authorization_code"], "client_id": [OAuthConfig.microsoftClientId],
                "redirect_uri": ["\(OAuthConfig.microsoftRedirectScheme)://auth"],
            ])
        case .microsoftRefresh:
            tokens = try await service.refreshMicrosoftToken(refreshToken: value)
            expected = (microsoft, [
                "refresh_token": [value], "scope": [OAuthConfig.microsoftScopes], "grant_type": ["refresh_token"],
                "client_id": [OAuthConfig.microsoftClientId],
            ])
        }

        #expect(tokens.accessToken == "access", "the call read the endpoint's answer")
        let requests = sent.all
        #expect(requests.count == 1, "requests: \(requests.map(\.url.absoluteString))")
        guard requests.count == 1 else { return }
        let request = requests[0]
        #expect(request.url.absoluteString == expected.url)
        #expect(request.method == "POST")
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        let fields = FormDecoding.fields(request.body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        #expect(fields == expected.fields)
    }
}
