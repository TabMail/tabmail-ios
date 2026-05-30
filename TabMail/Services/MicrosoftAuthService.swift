/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation

// MARK: - Microsoft OAuth

extension OAuthService {

    /// Identity-only Microsoft OAuth — `User.Read openid profile email`
    /// only, no Mail/Calendar. First step of the split sign-in flow.
    func authenticateMicrosoftIdentityOnly() async throws -> OAuthTokens {
        try await runMicrosoftAuth(
            scope: "User.Read openid profile email",
            loginHint: nil
        )
    }

    /// Full-scope Microsoft OAuth (Mail + Calendar + identity). Pass
    /// `loginHint` to pre-fill the account chooser when re-authing
    /// after `authenticateMicrosoftIdentityOnly`.
    func authenticateMicrosoft(loginHint: String? = nil) async throws -> OAuthTokens {
        try await runMicrosoftAuth(
            scope: OAuthConfig.microsoftScopes,
            loginHint: loginHint
        )
    }

    private func runMicrosoftAuth(scope: String, loginHint: String?) async throws -> OAuthTokens {
        let clientId = OAuthConfig.microsoftClientId
        let redirectScheme = OAuthConfig.microsoftRedirectScheme
        print("[OAuth] Microsoft clientId: \(clientId)")
        print("[OAuth] Microsoft redirectScheme: \(redirectScheme)")
        guard !clientId.isEmpty else {
            throw OAuthError.notConfigured("Microsoft OAuth client ID not set")
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let redirectUri = "\(redirectScheme)://auth"

        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query"),
            // `select_account` shows the picker. When `loginHint` is
            // set Microsoft auto-selects the matching account so the
            // user only sees the new-scope consent step.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let loginHint, !loginHint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = queryItems

        let authURL = components.url!
        print("[OAuth] Microsoft authURL: \(authURL)")

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callback: .customScheme(redirectScheme)) { url, error in
                print("[OAuth] Microsoft callback — url: \(String(describing: url)), error: \(String(describing: error))")
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OAuthError.cancelled) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.currentSession = session
            let started = session.start()
            print("[OAuth] Microsoft session.start() returned: \(started)")
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.noAuthCode
        }

        return try await exchangeMicrosoftCode(code, codeVerifier: codeVerifier, scope: scope)
    }

    private func exchangeMicrosoftCode(_ code: String, codeVerifier: String, scope: String) async throws -> OAuthTokens {
        let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let redirectUri = "\(OAuthConfig.microsoftRedirectScheme)://auth"
        let params = [
            "client_id": OAuthConfig.microsoftClientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri,
            "scope": scope,
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let response = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)

        guard let accessToken = response.access_token else {
            throw OAuthError.tokenExchangeFailed(response.error ?? "unknown")
        }

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: response.refresh_token,
            expiresAt: response.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            idToken: response.id_token
        )
    }

    func refreshMicrosoftToken(refreshToken: String) async throws -> OAuthTokens {
        let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": OAuthConfig.microsoftClientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": OAuthConfig.microsoftScopes,
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let response = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)

        guard let accessToken = response.access_token else {
            throw OAuthError.tokenExchangeFailed(response.error ?? "unknown")
        }

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: response.refresh_token ?? refreshToken,
            expiresAt: response.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            idToken: response.id_token
        )
    }

    // MARK: - Microsoft User Info

    func fetchMicrosoftUserInfo(accessToken: String) async throws -> (email: String, name: String) {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let info = try JSONDecoder().decode(MicrosoftUserInfo.self, from: data)
        let email = info.mail ?? info.userPrincipalName ?? ""
        return (email, info.displayName ?? email)
    }

    // MARK: - Microsoft Metadata-Scope Consent (web-hosted)
    //
    // Mirror of `authenticateGoogleMetadataScope` for Outlook. The iOS app
    // calls the worker's `/push-consent/outlook/init` with its Supabase JWT
    // + claimed email + iOS callback scheme; worker mints an opaque session
    // and returns a startUrl. iOS opens that URL in ASWebAuthenticationSession,
    // the user consents on Microsoft's page, Microsoft redirects to the
    // worker's `/callback` which exchanges code → tokens and stores them
    // server-side. iOS only sees the final redirect back to its custom
    // scheme carrying `?status=ok|error&reason=...`. Tokens never transit iOS.
    //
    // Throws `OAuthError.cancelled` on explicit decline (caller invokes
    // `disableNSEGlobally`); `OAuthError.consentFailed(reason)` on transient
    // or non-cancel errors so the foreground banner can re-prompt later.

    func authenticateMicrosoftMetadataScope(loginHint: String, pushClient: PushClient) async throws {
        let redirectScheme = OAuthConfig.microsoftRedirectScheme
        guard !redirectScheme.isEmpty else {
            throw OAuthError.notConfigured("MICROSOFT_REDIRECT_SCHEME not set")
        }
        // Distinct path on the existing scheme — same scheme is already
        // registered for the primary mail-account flow, so reusing avoids
        // a second URL type registration.
        let iosRedirect = "\(redirectScheme)://outlook-metadata-consent"

        let startURL: URL
        do {
            startURL = try await pushClient.initOutlookConsentWeb(
                userEmail: loginHint,
                iosRedirect: iosRedirect
            )
        } catch {
            print("[MetadataConsent-Outlook] /init failed: \(error)")
            throw error
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: startURL, callback: .customScheme(redirectScheme)) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OAuthError.cancelled) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.currentSession = session
            _ = session.start()
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status = items.first(where: { $0.name == "status" })?.value
        let reason = items.first(where: { $0.name == "reason" })?.value

        if status == "ok" {
            return
        }
        // Microsoft's consent decline surfaces as `reason=access_denied` via the
        // worker's callback (it forwards Microsoft's `?error=access_denied`).
        if reason == "access_denied" {
            throw OAuthError.cancelled
        }
        print("[MetadataConsent-Outlook] consent failed: reason=\(reason ?? "unknown")")
        throw OAuthError.consentFailed(reason ?? "unknown")
    }
}

// MARK: - Response Models

private struct MicrosoftTokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
    let error: String?
}

private struct MicrosoftUserInfo: Decodable {
    let mail: String?
    let userPrincipalName: String?
    let displayName: String?
}
