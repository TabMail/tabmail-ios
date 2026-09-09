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

    /// A replacement login by the same user is still a different session.
    private var inFlightRefreshGeneration: String?

    static func canJoinInFlightRefresh(inFlightGeneration: String?, requestingGeneration: String) -> Bool {
        inFlightGeneration == requestingGeneration
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
               inFlightGeneration: inFlightRefreshGeneration,
               requestingGeneration: record.generation!
           ) {
            print("[TabMailToken] Awaiting in-flight refresh...")
            return await existing.value
        }

        let generation = record.generation!
        print("[TabMailToken] Token expired (expiresAt=\(session.expiresAt) now=\(now)), starting refresh...")

        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(
                record: record,
                sessionStore: sessionStore,
                dataForRequest: dataForRequest
            )
        }
        inFlightRefresh = task
        inFlightRefreshGeneration = generation

        let result = await task.value
        // Only retire the slot if it is still OURS. A different user's refresh
        // may have replaced it while we were suspended; clearing it blindly
        // would drop that task's dedup tag and let a third caller join an
        // untagged refresh.
        if inFlightRefresh == task {
            inFlightRefresh = nil
            inFlightRefreshGeneration = nil
        }
        return result
    }

    /// Force-refresh the token regardless of expiry.
    /// Used after `updateUserMetadata()` to ensure the JWT carries updated `user_metadata` claims.
    func forceRefresh() async -> RefreshResult {
        guard var record = sessionStore.loadActiveSession(),
              let session = try? JSONDecoder().decode(TabMailSession.self, from: record.data) else {
            return .noSession
        }

        if record.generation == nil {
            await retryLegacyMigration()
            guard let migrated = sessionStore.loadActiveSession(),
                  let migratedSession = try? JSONDecoder().decode(TabMailSession.self, from: migrated.data),
                  migrated.generation != nil, migratedSession.userId == session.userId else {
                return .transientFailure
            }
            record = migrated
        }

        // Deduplicate if a refresh is already in-flight — same-generation only.
        // This path has NO expiry check, so without the ownership tag it joins
        // another user's refresh unconditionally. Its sole production caller
        // (`ConsentGateView`) runs immediately after sign-in, i.e. exactly in
        // the sign-out/sign-in window where the subject can have just changed.
        if let existing = inFlightRefresh,
           Self.canJoinInFlightRefresh(
               inFlightGeneration: inFlightRefreshGeneration,
               requestingGeneration: record.generation!
           ) {
            return await existing.value
        }

        print("[TabMailToken] Force-refreshing token to pick up updated user_metadata")

        let generation = record.generation!
        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(
                record: record,
                sessionStore: sessionStore,
                dataForRequest: dataForRequest
            )
        }
        inFlightRefresh = task
        inFlightRefreshGeneration = generation

        let result = await task.value
        if inFlightRefresh == task {
            inFlightRefresh = nil
            inFlightRefreshGeneration = nil
        }
        return result
    }

    /// Both processes use the same snapshot-checked refresh persistence.
    private static func performRefresh(
        record: TabMailSessionStore.ActiveSession,
        sessionStore: TabMailSessionStore,
        dataForRequest: @escaping DataForRequest
    ) async -> RefreshResult {
        do {
            let result = try await CredentialRefreshBackgroundTask.run {
                try await TabMailSessionRefresh.token(record: record, force: true,
                    store: sessionStore, transport: dataForRequest)
            }
            // Preserve the existing held-invocation contract. This never changes
            // activation; NSE recovery separately requires durable active state.
            return .success(result.session.accessToken)
        } catch CredentialRefreshError.requiresAuthorization {
            return .permanentFailure
        } catch CredentialRefreshError.inactive {
            return .noSession
        } catch { return .transientFailure }
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
