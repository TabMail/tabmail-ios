/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Centralized Supabase token refresh coordinator.
/// Prevents race conditions where multiple callers (BackendClient, TemplateMarketplaceClient,
/// DeviceSyncService) independently refresh the same Supabase refresh token. Supabase uses
/// refresh token rotation — once used, the old token is invalidated. Without coordination,
/// the second caller gets a 400, which DeviceSyncService interprets as permanent failure → logout.
///
/// All callers should use `TabMailTokenCoordinator.shared.validToken()` instead of
/// implementing their own refresh logic.
actor TabMailTokenCoordinator {
    static let shared = TabMailTokenCoordinator()

    enum RefreshResult: Sendable {
        case success(String)       // valid access token
        case permanentFailure      // 400/401/403 — refresh token revoked, re-auth needed
        case transientFailure      // network error, 5xx — retry later
        case noSession             // no session in Keychain
    }

    private static let supabaseURL = "https://auth.tabmail.ai"
    private static let supabaseAnonKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"

    /// In-flight refresh task. Subsequent callers await this instead of starting a new refresh.
    private var inFlightRefresh: Task<RefreshResult, Never>?

    /// Get a valid access token, refreshing if needed.
    /// Deduplicates concurrent refresh attempts — only one HTTP refresh call is made.
    func validToken() async -> RefreshResult {
        // Read current session from Keychain
        guard let data = KeychainHelper.load(key: "tabmail_session"),
              let session = try? JSONDecoder().decode(TabMailSession.self, from: data) else {
            return .noSession
        }

        // Token still valid? Return immediately.
        let now = Int(Date().timeIntervalSince1970)
        if session.expiresAt > now + 60 {
            return .success(session.accessToken)
        }

        // Token expired — deduplicate the refresh
        if let existing = inFlightRefresh {
            print("[TabMailToken] Awaiting in-flight refresh...")
            return await existing.value
        }

        let refreshToken = session.refreshToken
        print("[TabMailToken] Token expired (expiresAt=\(session.expiresAt) now=\(now)), starting refresh...")

        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(refreshToken: refreshToken)
        }
        inFlightRefresh = task

        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    /// Force-refresh the token regardless of expiry.
    /// Used after `updateUserMetadata()` to ensure the JWT carries updated `user_metadata` claims.
    func forceRefresh() async -> RefreshResult {
        // Read current session for its refresh token
        guard let data = KeychainHelper.load(key: "tabmail_session"),
              let session = try? JSONDecoder().decode(TabMailSession.self, from: data) else {
            return .noSession
        }

        // Deduplicate if a refresh is already in-flight
        if let existing = inFlightRefresh {
            return await existing.value
        }

        print("[TabMailToken] Force-refreshing token to pick up updated user_metadata")

        let refreshToken = session.refreshToken
        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(refreshToken: refreshToken)
        }
        inFlightRefresh = task

        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    /// Perform the actual HTTP refresh call to Supabase.
    private static func performRefresh(refreshToken: String) async -> RefreshResult {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            return .transientFailure
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        do {
            let (data, response) = try await sharedEphemeralSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }

            guard httpResponse.statusCode == 200 else {
                let code = httpResponse.statusCode
                AuthDiagnostics.log("Token refresh HTTP \(code)")
                // 400/401/403 = refresh token revoked or invalid — permanent, needs re-auth.
                // Do NOT auto-logout — only the user can sign out. Callers should
                // treat this as a transient-like failure and retry on next attempt.
                if code == 400 || code == 401 || code == 403 {
                    AuthDiagnostics.log("Refresh permanently failed (HTTP \(code)) — token may be revoked")
                    return .permanentFailure
                }
                return .transientFailure
            }

            let newSession = try JSONDecoder().decode(TabMailSession.self, from: data)
            let encoded = try JSONEncoder().encode(newSession)
            do {
                try KeychainHelper.save(encoded, for: "tabmail_session")
            } catch {
                AuthDiagnostics.log("CRITICAL: Keychain save failed after refresh — stale token on next launch. Error: \(error)")
            }
            AuthDiagnostics.log("Token refreshed, expiresAt=\(newSession.expiresAt)")
            return .success(newSession.accessToken)
        } catch {
            AuthDiagnostics.log("Token refresh error: \(error)")
            return .transientFailure
        }
    }
}
