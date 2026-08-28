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

    typealias DataForRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum RefreshResult: Sendable {
        case success(String)       // valid access token
        case permanentFailure      // 400/401/403 — refresh token revoked, re-auth needed
        case transientFailure      // network error, 5xx — retry later
        case noSession             // no session in Keychain
    }

    private static let supabaseURL = "https://auth.tabmail.ai"
    private static let supabaseAnonKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"
    private let dataForRequest: DataForRequest
    private let sessionStore: TabMailSessionStore

    init(
        sessionStore: TabMailSessionStore = .shared,
        dataForRequest: @escaping DataForRequest = { request in
            try await sharedEphemeralSession.data(for: request)
        }
    ) {
        self.sessionStore = sessionStore
        self.dataForRequest = dataForRequest
    }

    /// In-flight refresh task. Subsequent callers await this instead of starting a new refresh.
    private var inFlightRefresh: Task<RefreshResult, Never>?

    /// The Supabase subject `inFlightRefresh` was started for.
    ///
    /// Deduplication is only ever safe BETWEEN CALLERS THAT OWN THE SAME
    /// SESSION. The dedup exists to stop two callers burning the same rotated
    /// refresh token; it was never meant to hand one user another user's
    /// bearer. Without this tag, a sign-out/sign-in switch lets B join A's
    /// in-flight refresh and receive `.success(A_accessToken)` — B then makes
    /// backend requests under A's identity, and a `/whoami` fetched that way
    /// describes A while carrying B's epoch.
    private var inFlightRefreshUserId: String?

    /// Pure join-decision: may a caller owning `requestingUserId` share the
    /// in-flight refresh started for `inFlightUserId`?
    ///
    /// JOIN only on an exact subject match. Refusing to join is always
    /// auth-safe: the caller simply starts its OWN refresh with its OWN
    /// refresh token, so no legitimate session is ever denied a token. (Two
    /// different users hold two different refresh tokens, so declining to
    /// share cannot cause a rotation conflict — the failure mode the dedup
    /// exists to prevent applies only within one subject, which still dedups.)
    static func canJoinInFlightRefresh(inFlightUserId: String?, requestingUserId: String) -> Bool {
        guard let inFlightUserId else { return false }
        return inFlightUserId == requestingUserId
    }

    /// Get a valid access token, refreshing if needed.
    /// Deduplicates concurrent refresh attempts — only one HTTP refresh call is made.
    func validToken() async -> RefreshResult {
        guard var record = sessionStore.loadActiveSession(),
              var session = try? JSONDecoder().decode(TabMailSession.self, from: record.data) else {
            return .noSession
        }

        // Token still valid? Return immediately.
        let now = Int(Date().timeIntervalSince1970)
        if session.expiresAt > now + 60 {
            return .success(session.accessToken)
        }

        // A legacy token may be used while still valid, but its rotating refresh
        // token is never spent until copy-and-activation succeeds locally.
        if record.generation == nil {
            await retryLegacyMigration()
            guard let migrated = sessionStore.loadActiveSession(),
                  let migratedSession = try? JSONDecoder().decode(TabMailSession.self, from: migrated.data),
                  migrated.generation != nil else {
                return .transientFailure
            }
            record = migrated
            session = migratedSession
        }

        // Token expired — deduplicate the refresh, but ONLY with a caller that
        // owns the same session (see `canJoinInFlightRefresh`).
        if let existing = inFlightRefresh,
           Self.canJoinInFlightRefresh(
               inFlightUserId: inFlightRefreshUserId,
               requestingUserId: session.userId
           ) {
            print("[TabMailToken] Awaiting in-flight refresh...")
            return await existing.value
        }

        let refreshToken = session.refreshToken
        let generation = record.generation!
        print("[TabMailToken] Token expired (expiresAt=\(session.expiresAt) now=\(now)), starting refresh...")

        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(
                refreshToken: refreshToken,
                generation: generation,
                sessionStore: sessionStore,
                dataForRequest: dataForRequest
            )
        }
        inFlightRefresh = task
        inFlightRefreshUserId = session.userId

        let result = await task.value
        // Only retire the slot if it is still OURS. A different user's refresh
        // may have replaced it while we were suspended; clearing it blindly
        // would drop that task's dedup tag and let a third caller join an
        // untagged refresh.
        if inFlightRefresh == task {
            inFlightRefresh = nil
            inFlightRefreshUserId = nil
        }
        return result
    }

    /// Force-refresh the token regardless of expiry.
    /// Used after `updateUserMetadata()` to ensure the JWT carries updated `user_metadata` claims.
    func forceRefresh() async -> RefreshResult {
        guard var record = sessionStore.loadActiveSession(),
              var session = try? JSONDecoder().decode(TabMailSession.self, from: record.data) else {
            return .noSession
        }

        if record.generation == nil {
            await retryLegacyMigration()
            guard let migrated = sessionStore.loadActiveSession(),
                  let migratedSession = try? JSONDecoder().decode(TabMailSession.self, from: migrated.data),
                  migrated.generation != nil else {
                return .transientFailure
            }
            record = migrated
            session = migratedSession
        }

        // Deduplicate if a refresh is already in-flight — same-subject only.
        // This path has NO expiry check, so without the ownership tag it joins
        // another user's refresh unconditionally. Its sole production caller
        // (`ConsentGateView`) runs immediately after sign-in, i.e. exactly in
        // the sign-out/sign-in window where the subject can have just changed.
        if let existing = inFlightRefresh,
           Self.canJoinInFlightRefresh(
               inFlightUserId: inFlightRefreshUserId,
               requestingUserId: session.userId
           ) {
            return await existing.value
        }

        print("[TabMailToken] Force-refreshing token to pick up updated user_metadata")

        let refreshToken = session.refreshToken
        let generation = record.generation!
        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(
                refreshToken: refreshToken,
                generation: generation,
                sessionStore: sessionStore,
                dataForRequest: dataForRequest
            )
        }
        inFlightRefresh = task
        inFlightRefreshUserId = session.userId

        let result = await task.value
        if inFlightRefresh == task {
            inFlightRefresh = nil
            inFlightRefreshUserId = nil
        }
        return result
    }

    /// Perform the actual HTTP refresh call to Supabase.
    private static func performRefresh(
        refreshToken: String,
        generation: String,
        sessionStore: TabMailSessionStore,
        dataForRequest: DataForRequest
    ) async -> RefreshResult {
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
            let (data, response) = try await dataForRequest(request)
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
            // Update exactly the generation captured before the request. A
            // sign-out or later login can delete that slot, but a late response
            // can never recreate it or touch the active pointer.
            let persistence = sessionStore.updateCapturedGeneration(generation, data: encoded)
            if case .failed(let status) = persistence {
                AuthDiagnostics.log("Token refresh persistence failed (OSStatus \(status)); current invocation may continue")
            }
            AuthDiagnostics.log("Token refreshed, expiresAt=\(newSession.expiresAt)")
            return .success(newSession.accessToken)
        } catch {
            AuthDiagnostics.log("Token refresh error: \(error)")
            return .transientFailure
        }
    }

    @MainActor
    private func retryLegacyMigration() {
        do {
            try sessionStore.migrateLegacySession {
                (try? JSONDecoder().decode(TabMailSession.self, from: $0)) != nil
            }
        } catch {
            AuthDiagnostics.log("Legacy session migration before refresh remains retryable (\(error))")
        }
    }
}
