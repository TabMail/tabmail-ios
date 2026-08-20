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
        print("[TabMailToken] Token expired (expiresAt=\(session.expiresAt) now=\(now)), starting refresh...")

        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(refreshToken: refreshToken)
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
        // Read current session for its refresh token
        guard let data = KeychainHelper.load(key: "tabmail_session"),
              let session = try? JSONDecoder().decode(TabMailSession.self, from: data) else {
            return .noSession
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
        let task = Task<RefreshResult, Never> {
            await Self.performRefresh(refreshToken: refreshToken)
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
            // Clobber-guard (auth-safe). A sign-out cleanup can drive this
            // refresh, and it runs in an UNSTRUCTURED task that `signOut()`'s
            // `flush.cancel()` cannot reach, so it can complete after the slot
            // has changed owner (empty after `clearSession`, or a DIFFERENT
            // user after someone else signs in). Persist only if the slot is
            // empty, unreadable, or still owned by THIS user; never over a
            // different, valid user (that would overwrite an active B with A —
            // an identity clobber). Never infer sign-out from an ambiguous
            // read: empty/unreadable ⇒ SAVE, so a transient miss cannot strand
            // a stale token and log the user out. Returning `.success`
            // regardless keeps the in-flight caller's token valid for its
            // current request (IOS-PUSH-001) — only the Keychain write is
            // gated.
            await Self.persistRefreshedSession(encoded: encoded, newUserId: newSession.userId)
            AuthDiagnostics.log("Token refreshed, expiresAt=\(newSession.expiresAt)")
            return .success(newSession.accessToken)
        } catch {
            AuthDiagnostics.log("Token refresh error: \(error)")
            return .transientFailure
        }
    }

    // MARK: - Clobber guard (auth-safe session persistence)

    /// Pure save-decision for a refreshed session: should it overwrite the
    /// shared `"tabmail_session"` slot?
    ///
    /// SAVE when the slot is empty, unreadable/undecodable, OR owned by the
    /// SAME user (`userId` matches). An ambiguous or missing read must never be
    /// treated as "signed out": withholding a legitimate save would strand a
    /// stale token and log the user out on next launch — worse than the
    /// clobber, and the overriding priority. SKIP only when the slot decodes to
    /// a VALID session for a DIFFERENT user; there is no legitimate case where
    /// one account's refreshed token should overwrite another account's active
    /// session, so a skip is only ever the clobber.
    static func shouldPersistRefreshedSession(currentSlot: Data?, newUserId: String) -> Bool {
        guard let currentSlot,
              let current = try? JSONDecoder().decode(TabMailSession.self, from: currentSlot) else {
            return true // empty or unreadable — save (never infer sign-out)
        }
        return current.userId == newUserId
    }

    /// Re-read the slot and persist the refreshed session iff the clobber guard
    /// allows it.
    ///
    /// Runs on the MainActor deliberately: the in-process writers of
    /// `"tabmail_session"` are `TabMailAuthService`'s sign-in saves and
    /// `clearSession`, all MainActor-isolated. So this read → decide → write
    /// executes as one synchronous MainActor step that no IN-PROCESS sign-in
    /// write can interleave, and the compare is therefore always against the
    /// owner this process last saw. `loadCurrent` / `save` are injected for
    /// tests; production uses the Keychain.
    ///
    /// ⚠️ **This is NOT atomic against the notification-service extension.**
    /// `NSETokenManager.performRefresh` writes the identical Keychain item
    /// (service `ai.tabmail.ios`, access group `group.ai.tabmail`, account
    /// `tabmail_session`) from a SEPARATE PROCESS, and `@MainActor` cannot
    /// serialize another process. The NSE runs the same auth-safe predicate,
    /// which shrinks the race to the window between its read and its write —
    /// it does not eliminate it. A cross-process guarantee would need a
    /// Keychain-level compare-and-swap, which `SecItemUpdate` does not offer.
    /// Registered as the residual on `IOS-PUSH-001`. An earlier revision of
    /// this comment claimed the MainActor made the guard atomic against ALL
    /// writers; that claim was false and is corrected here.
    @MainActor
    static func persistRefreshedSession(
        encoded: Data,
        newUserId: String,
        loadCurrent: () -> Data? = { KeychainHelper.load(key: "tabmail_session") },
        save: (Data) throws -> Void = { try KeychainHelper.save($0, for: "tabmail_session") }
    ) {
        guard shouldPersistRefreshedSession(currentSlot: loadCurrent(), newUserId: newUserId) else {
            AuthDiagnostics.log("Token refresh: session slot now owned by a different user — withholding save (clobber-guard)")
            return
        }
        do {
            try save(encoded)
        } catch {
            AuthDiagnostics.log("CRITICAL: Keychain save failed after refresh — stale token on next launch. Error: \(error)")
        }
    }
}
