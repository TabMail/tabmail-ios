/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum OAuthConfig {
    /// Loaded from Secrets.xcconfig → Info.plist at runtime
    static var googleClientId: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String ?? ""
    }
    static var googleRedirectScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_SCHEME") as? String ?? ""
    }
    static var microsoftClientId: String {
        Bundle.main.object(forInfoDictionaryKey: "MICROSOFT_CLIENT_ID") as? String ?? ""
    }
    static var microsoftRedirectScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "MICROSOFT_REDIRECT_SCHEME") as? String ?? ""
    }
    static let microsoftScopes = "Mail.ReadWrite Mail.Send Calendars.ReadWrite offline_access User.Read openid profile email"
    // Metadata-scope OAuth for Outlook runs web-hosted (mirror of Gmail) —
    // the worker owns the Entra app registration and its client
    // credentials, and exchanges code → tokens server-side.
    // iOS only opens the worker-provided startUrl in ASWebAuthenticationSession
    // and parses the final `?status=ok|error` redirect. No iOS-side Microsoft
    // client ID needed.
}

struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let idToken: String?
}

@MainActor
final class OAuthService: NSObject {

    var currentSession: ASWebAuthenticationSession?

    // MARK: - Google OAuth

    /// Identity-only Google OAuth — `openid email profile` scopes only,
    /// no Gmail/Calendar. Used as the first step of the split sign-in
    /// flow: the user gets a small "TabMail wants to know who you are"
    /// dialog, completes the TabMail account creation, then sees the
    /// `AddAccountGmailOutlookView` consent gate. The full mail scopes
    /// are only requested (via the regular `authenticateGoogle`) if
    /// the user taps **Connect** on that gate.
    func authenticateGoogleIdentityOnly() async throws -> OAuthTokens {
        try await runGoogleAuth(
            scope: "openid email profile",
            loginHint: nil,
            includeGrantedScopes: false,
            accessTypeOffline: false
        )
    }

    /// Full-scope Google OAuth (Gmail + Calendar + identity). Optional
    /// `loginHint` pre-fills the account chooser. We deliberately do
    /// NOT pass `include_granted_scopes=true` here — Google's
    /// incremental-auth path appears to interact badly with rapid
    /// back-to-back OAuth sessions on the same custom URL scheme,
    /// surfacing as a spurious `ASWebAuthenticationSessionError.canceledLogin`
    /// in `ASWebAuthenticationSession`'s callback. Re-asking for the
    /// identity scopes (`openid email profile`) along with the mail
    /// scopes is cheap — Google de-dupes them server-side — and the
    /// resulting consent screen is the same single dialog either way.
    func authenticateGoogle(loginHint: String? = nil) async throws -> OAuthTokens {
        try await runGoogleAuth(
            scope: "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/calendar openid email profile",
            loginHint: loginHint,
            includeGrantedScopes: false,
            accessTypeOffline: true
        )
    }

    private func runGoogleAuth(
        scope: String,
        loginHint: String?,
        includeGrantedScopes: Bool,
        accessTypeOffline: Bool
    ) async throws -> OAuthTokens {
        let clientId = OAuthConfig.googleClientId
        let redirectScheme = OAuthConfig.googleRedirectScheme
        print("[OAuth] clientId: \(clientId)")
        print("[OAuth] redirectScheme: \(redirectScheme)")
        guard !clientId.isEmpty else {
            throw OAuthError.notConfigured("Google OAuth client ID not set")
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: "\(redirectScheme):/oauthredirect"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if accessTypeOffline {
            queryItems.append(URLQueryItem(name: "access_type", value: "offline"))
        }
        if includeGrantedScopes {
            queryItems.append(URLQueryItem(name: "include_granted_scopes", value: "true"))
        }
        if let loginHint, !loginHint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = queryItems

        let authURL = components.url!
        print("[OAuth] authURL: \(authURL)")

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callback: .customScheme(redirectScheme)) { url, error in
                if let error {
                    let nsError = error as NSError
                    print("[OAuth] callback ERROR — domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo), description=\(nsError.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let url {
                    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let hasCode = queryItems.contains(where: { $0.name == "code" })
                    let hasError = queryItems.first(where: { $0.name == "error" })?.value
                    print("[OAuth] callback received — hasCode=\(hasCode), googleError=\(hasError ?? "nil")")
                    continuation.resume(returning: url)
                } else {
                    print("[OAuth] callback received — url: nil, error: nil (treating as cancel)")
                    continuation.resume(throwing: OAuthError.cancelled)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.currentSession = session
            let started = session.start()
            print("[OAuth] session.start() returned: \(started) (scope=\(scope))")
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.noAuthCode
        }

        return try await exchangeGoogleCode(code, codeVerifier: codeVerifier)
    }

    private func exchangeGoogleCode(_ code: String, codeVerifier: String) async throws -> OAuthTokens {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": OAuthConfig.googleClientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": "\(OAuthConfig.googleRedirectScheme):/oauthredirect",
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)

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

    func refreshGoogleToken(refreshToken: String) async throws -> OAuthTokens {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": OAuthConfig.googleClientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)

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

    // MARK: - Google Metadata-Scope OAuth (for server-side push classifier)

    /// Run a separate OAuth flow requesting ONLY
    /// `https://www.googleapis.com/auth/gmail.metadata` — no body access, no
    /// write — so the resulting refresh_token can be safely handed to the
    /// push worker for server-side inbox-add classification. The primary
    /// gmail.modify/send token stays on device and is never uploaded.
    ///
    /// `loginHint` pre-fills the Google account chooser so the user isn't
    /// asked to pick the account a second time. Still shows the consent
    /// screen because this is a distinct scope set.
    ///
    /// Run the metadata-scope consent flow entirely server-side: ask the
    /// push worker for a one-shot start URL, open it in
    /// ASWebAuthenticationSession, and wait for the worker-hosted callback
    /// to redirect back with `status=ok|error`. The refresh_token lives
    /// only on the worker (encrypted in KV) — we never see it on-device.
    ///
    /// This is the verified-app / CASA-friendly flow. The prior on-device
    /// PKCE version has been replaced.
    ///
    /// Throws `OAuthError.cancelled` on explicit user decline (caller
    /// disables NSE globally). Throws `OAuthError.consentFailed` on
    /// non-cancel errors (transient network, worker 5xx, scope mismatch).
    ///
    /// Must be called from the main actor (uses ASWebAuthenticationSession).
    func authenticateGoogleMetadataScope(loginHint: String, pushClient: PushClient) async throws {
        let redirectScheme = OAuthConfig.googleRedirectScheme
        guard !redirectScheme.isEmpty else {
            throw OAuthError.notConfigured("GOOGLE_REDIRECT_SCHEME not set")
        }
        // Distinct path on the existing Google redirect scheme. The scheme
        // is already registered in Info.plist for the on-device sign-in
        // flow; reusing it avoids plumbing a second URL type. The path
        // (`metadata-consent`) is what distinguishes callback destinations.
        let iosRedirect = "\(redirectScheme)://metadata-consent"

        let startURL: URL
        do {
            startURL = try await pushClient.initGmailConsentWeb(
                userEmail: loginHint,
                iosRedirect: iosRedirect
            )
        } catch {
            print("[MetadataConsent] /init failed: \(error)")
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
        if reason == "access_denied" {
            throw OAuthError.cancelled
        }
        print("[MetadataConsent] consent failed: reason=\(reason ?? "unknown")")
        throw OAuthError.consentFailed(reason ?? "unknown")
    }

    // MARK: - Google User Info

    func fetchGoogleUserInfo(accessToken: String) async throws -> (email: String, name: String) {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await sharedEphemeralSession.data(for: request)
        let info = try JSONDecoder().decode(GoogleUserInfo.self, from: data)
        return (info.email, info.name ?? info.email)
    }

    // MARK: - PKCE Helpers

    func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Response Models

private struct GoogleTokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
    let error: String?
}

private struct GoogleUserInfo: Decodable {
    let email: String
    let name: String?
}

enum OAuthError: Error {
    case notConfigured(String)
    case cancelled
    case noAuthCode
    case tokenExchangeFailed(String)
    case consentFailed(String)
}

// MARK: - Presentation Context

extension OAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        return ASPresentationAnchor(windowScene: scenes.first!)
    }
}

