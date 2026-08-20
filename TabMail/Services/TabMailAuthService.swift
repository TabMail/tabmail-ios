/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import UIKit

struct TabMailSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let userId: String
    let userEmail: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresAt = try container.decode(Int.self, forKey: .expiresAt)
        let user = try container.decode(UserInfo.self, forKey: .user)
        userId = user.id
        userEmail = user.email
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(UserInfo(id: userId, email: userEmail), forKey: .user)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case user
    }

    private struct UserInfo: Codable {
        let id: String
        let email: String
    }
}

enum TabMailProvider: String {
    case apple
    case google
    case microsoft = "azure"
}

@MainActor
final class TabMailAuthService: NSObject {
    private static let sessionKey = "tabmail_session"
    private static let supabaseURL = "https://auth.tabmail.ai"
    private static let supabaseAnonKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"
    private static let callbackURL = "https://tabmail.ai/auth/ios-callback"
    private static let billingURL = "https://billing.tabmail.ai"
    private var currentSession: ASWebAuthenticationSession?

    static func hasSession() -> Bool {
        KeychainHelper.load(key: sessionKey) != nil
    }

    static func getSession() -> TabMailSession? {
        guard let data = KeychainHelper.load(key: sessionKey) else { return nil }
        return try? JSONDecoder().decode(TabMailSession.self, from: data)
    }

    static func clearSession() {
        KeychainHelper.delete(key: sessionKey)
        // Session identity changed — re-evaluate the debug-logging gate.
        DebugModeManager.invalidateLoggingCache()
    }

    /// Ordinary user-initiated sign-out: hand off any remote push-cleanup debt
    /// this session still owns, then clear the session and tell the UI.
    ///
    /// IOS-PUSH-001. Worker cleanup authenticates with `tabmail_session`, and
    /// `drainPendingRemovedAccountCleanupsOnce` re-reads that subject on every
    /// pass, so clearing the Keychain first *strands* the debt: the record
    /// survives, but no later pass can advance it until the same user signs in
    /// again. The removal flow's own drain is a detached `Task` that suspends on
    /// an account census before it reads the subject, so an ordinary "remove the
    /// account, then sign out" loses that race today and leaves the worker
    /// holding device routes and an IMAP IDLE subscription that have no TTL.
    ///
    /// The flush is bounded and best-effort. The debt is durable and every
    /// action is idempotent, so a failed or timed-out flush costs nothing that
    /// the same user's next sign-in cannot recover — which is why sign-out
    /// itself is UNCONDITIONAL: it never fails, never waits past the bound, and
    /// never depends on the flush's outcome.
    ///
    /// Bounds the scope deliberately: `AppDataWiper.wipeAll` already flushes and
    /// then blocks on undischarged debt, and both the account-deletion flow and
    /// RootView's "account no longer available" path sign out against a subject
    /// the server has already invalidated, where these calls would only 401.
    static func signOut() async {
        // The subject about to be destroyed is exactly the one allowed to
        // discharge the debt, so the gate asks about that subject specifically.
        let subject = getSession()?.userId
        if await PushNotificationService.shared.hasRemovedAccountCleanupDebt(forCurrentUser: subject) {
            let flush = Task { await PushNotificationService.shared.retryPendingRemovedAccountCleanups() }
            _ = try? await withTimeout(seconds: PushConfig.signOutCleanupFlushTimeoutSeconds) {
                await flush.value
            }
            // Cancel before the Keychain delete rather than after. An in-flight
            // cleanup request can drive `TabMailTokenCoordinator.performRefresh`,
            // which writes a refreshed session BACK to the Keychain and would
            // resurrect the session this method is about to clear. Cancelling
            // the flush task itself (not merely the `withTimeout` waiter) closes
            // the window that a timed-out flush would otherwise leave open.
            flush.cancel()
        }
        clearSession()
        NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
    }

    // MARK: - OAuth Providers

    /// Sign in with an OAuth provider (Apple, Google, Microsoft)
    func signInWithProvider(_ provider: TabMailProvider) async throws -> TabMailSession {
        var components = URLComponents(string: "\(Self.supabaseURL)/auth/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: Self.callbackURL),
        ]

        // Google: request account selection
        if provider == .google {
            components.queryItems?.append(
                URLQueryItem(name: "prompt", value: "select_account")
            )
        }

        let authURL = components.url!
        print("[TabMailAuth] Opening \(provider.rawValue) OAuth: \(authURL)")

        return try await performWebAuth(url: authURL)
    }

    // MARK: - ID Token Sign-In (merged OAuth flow)

    /// Sign in with an ID token obtained from a direct OAuth flow (Google/Microsoft).
    /// This calls Supabase's `grant_type=id_token` endpoint instead of opening a second browser popup.
    func signInWithIdToken(provider: TabMailProvider, idToken: String) async throws -> TabMailSession {
        let providerName: String
        switch provider {
        case .google: providerName = "google"
        case .microsoft: providerName = "azure"
        case .apple: throw TabMailAuthError.invalidSession // Apple doesn't use this flow
        }

        let url = URL(string: "\(Self.supabaseURL)/auth/v1/token?grant_type=id_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["provider": providerName, "id_token": idToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TabMailAuth] Signing in with \(providerName) id_token")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TabMailAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = errorInfo["msg"] as? String
                    ?? errorInfo["error_description"] as? String
                    ?? errorInfo["error"] as? String
                    ?? "Unknown error"
                print("[TabMailAuth] id_token sign-in failed: \(msg)")
                throw TabMailAuthError.otpFailed(msg)
            }
            throw TabMailAuthError.otpFailed("Sign in failed (HTTP \(httpResponse.statusCode))")
        }

        let session = try JSONDecoder().decode(TabMailSession.self, from: data)

        // Persist in Keychain
        // Read the outgoing subject BEFORE overwriting it: the entitlement
        // epoch must advance here, at the identity change, not on the later
        // `.tabMailDidSignIn` notification (that is posted by UI callers only
        // after `syncStripeCustomer` below and further plumbing, and a prior
        // account's `/whoami` landing in that gap would still pass the
        // un-bumped epoch and vouch for the new account).
        let previousUserId = Self.getSession()?.userId
        let encoded = try JSONEncoder().encode(session)
        try KeychainHelper.save(encoded, for: Self.sessionKey)
        AISubscriptionGate.shared.noteSignedIn(userId: session.userId, previousUserId: previousUserId)
        // Session identity changed — re-evaluate the debug-logging gate.
        DebugModeManager.invalidateLoggingCache()

        // Sync Stripe customer (non-fatal)
        await syncStripeCustomer(accessToken: session.accessToken)

        print("[TabMailAuth] ID token sign-in successful, signed in as: \(session.userEmail)")
        return session
    }

    // MARK: - Email OTP (native)

    /// Send a one-time code to the given email address
    func sendEmailOTP(email: String) async throws {
        let url = URL(string: "\(Self.supabaseURL)/auth/v1/otp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["email": email, "create_user": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TabMailAuth] Sending OTP to: \(email)")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TabMailAuthError.invalidResponse
        }

        print("[TabMailAuth] OTP response: HTTP \(httpResponse.statusCode)")
        if let bodyStr = String(data: data, encoding: .utf8) {
            print("[TabMailAuth] OTP response body: \(bodyStr)")
        }

        if httpResponse.statusCode == 200 {
            print("[TabMailAuth] OTP sent successfully")
            return
        }

        // Parse Supabase error
        if let errorInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let msg = errorInfo["msg"] as? String
                ?? errorInfo["error_description"] as? String
                ?? errorInfo["error"] as? String
                ?? "Unknown error"

            if msg.contains("not found") || msg.contains("not allowed") || msg.contains("Signups") {
                throw TabMailAuthError.emailNotRegistered
            }
            throw TabMailAuthError.otpFailed(msg)
        }

        throw TabMailAuthError.otpFailed("Failed to send code (HTTP \(httpResponse.statusCode))")
    }

    /// Verify the OTP code and return a session
    func verifyEmailOTP(email: String, code: String) async throws -> TabMailSession {
        let url = URL(string: "\(Self.supabaseURL)/auth/v1/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["email": email, "token": code, "type": "email"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TabMailAuth] Verifying OTP for: \(email)")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TabMailAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = errorInfo["msg"] as? String
                    ?? errorInfo["error_description"] as? String
                    ?? errorInfo["error"] as? String
                    ?? "Unknown error"

                if msg.contains("Invalid") || msg.contains("expired") {
                    throw TabMailAuthError.invalidOTP
                }
                throw TabMailAuthError.otpFailed(msg)
            }
            throw TabMailAuthError.otpFailed("Verification failed (HTTP \(httpResponse.statusCode))")
        }

        let session = try JSONDecoder().decode(TabMailSession.self, from: data)

        // Persist in Keychain
        // Epoch advances at the identity change — see `signInWithIdToken`.
        let previousUserId = Self.getSession()?.userId
        let encoded = try JSONEncoder().encode(session)
        try KeychainHelper.save(encoded, for: Self.sessionKey)
        AISubscriptionGate.shared.noteSignedIn(userId: session.userId, previousUserId: previousUserId)
        // Session identity changed — re-evaluate the debug-logging gate.
        DebugModeManager.invalidateLoggingCache()

        // Sync Stripe customer (non-fatal)
        await syncStripeCustomer(accessToken: session.accessToken)

        print("[TabMailAuth] Email OTP verified, signed in as: \(session.userEmail)")
        return session
    }

    // MARK: - User Metadata (Consent)

    /// Update user metadata on the Supabase user record (GoTrue REST API).
    /// Used to persist consent flags (age, terms, privacy) matching the web consent flow.
    static func updateUserMetadata(_ metadata: [String: Any]) async throws {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/user") else {
            throw TabMailAuthError.invalidResponse
        }

        let tokenResult = await TabMailTokenCoordinator.shared.validToken()
        let accessToken: String
        switch tokenResult {
        case .success(let token):
            accessToken = token
        case .permanentFailure, .noSession:
            throw TabMailAuthError.invalidSession
        case .transientFailure:
            throw TabMailAuthError.otpFailed("Unable to get valid token")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["data": metadata]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TabMailAuth] Updating user metadata")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TabMailAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = errorInfo["msg"] as? String
                    ?? errorInfo["error_description"] as? String
                    ?? errorInfo["error"] as? String
                    ?? "Unknown error"
                print("[TabMailAuth] User metadata update failed: \(msg)")
                throw TabMailAuthError.otpFailed(msg)
            }
            throw TabMailAuthError.otpFailed("Metadata update failed (HTTP \(httpResponse.statusCode))")
        }

        print("[TabMailAuth] User metadata updated successfully")
    }

    // MARK: - Private

    private func performWebAuth(url: URL) async throws -> TabMailSession {
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme("tabmail-ios")
            ) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: TabMailAuthError.cancelled) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.currentSession = session
            session.start()
        }

        // Extract session from: tabmail-ios://auth#s=<base64>
        guard let fragment = callbackURL.fragment,
              fragment.hasPrefix("s=") else {
            throw TabMailAuthError.noSession
        }

        let base64 = String(fragment.dropFirst(2))
        guard let data = Data(base64Encoded: base64) else {
            throw TabMailAuthError.invalidSession
        }

        let session = try JSONDecoder().decode(TabMailSession.self, from: data)

        // Persist in Keychain (survives app restarts)
        // Epoch advances at the identity change — see `signInWithIdToken`.
        let previousUserId = Self.getSession()?.userId
        let encoded = try JSONEncoder().encode(session)
        try KeychainHelper.save(encoded, for: Self.sessionKey)
        AISubscriptionGate.shared.noteSignedIn(userId: session.userId, previousUserId: previousUserId)
        // Session identity changed — re-evaluate the debug-logging gate.
        DebugModeManager.invalidateLoggingCache()

        print("[TabMailAuth] Signed in as: \(session.userEmail)")
        return session
    }

    private func syncStripeCustomer(accessToken: String) async {
        do {
            let url = URL(string: "\(Self.billingURL)/billing/sync-customer")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await sharedEphemeralSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("[TabMailAuth] Stripe sync: HTTP \(httpResponse.statusCode)")
            }
        } catch {
            print("[TabMailAuth] Stripe sync failed (non-fatal): \(error)")
        }
    }
}

extension TabMailAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        return ASPresentationAnchor(windowScene: scenes.first!)
    }
}

enum TabMailAuthError: LocalizedError {
    case cancelled
    case noSession
    case invalidSession
    case invalidResponse
    case emailNotRegistered
    case invalidOTP
    case otpFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign in was cancelled."
        case .noSession: return "No session received."
        case .invalidSession: return "Invalid session data."
        case .invalidResponse: return "Invalid response from server."
        case .emailNotRegistered: return "This email is not registered. Sign-up is currently invite-only."
        case .invalidOTP: return "Invalid or expired code. Please try again."
        case .otpFailed(let msg): return msg
        }
    }
}
