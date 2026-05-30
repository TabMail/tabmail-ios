/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os
import Synchronization

private let log = OSLog(subsystem: "ai.tabmail.nse", category: "auth")

/// Per-account single-flight coalescer for token refresh.
///
/// Without this, two concurrent callers on the same account would both fire
/// the OAuth token endpoint. For Google that's merely wasteful (refresh tokens
/// don't rotate, so both succeed). For providers that rotate refresh tokens
/// (Supabase, Microsoft Graph), the loser's refresh_token becomes
/// invalid the moment the winner's response is persisted — producing spurious
/// auth failures. Coalescing makes concurrent refresh() calls share a single
/// network trip.
///
/// Also provides the "keychain-recheck" race defense: before issuing a network
/// refresh, we re-read the access token from the shared keychain. If it differs
/// from what the caller saw via `current()`, another actor (main app) has
/// already refreshed — we return that token and skip the network call entirely.
private final class RefreshCoalescer: @unchecked Sendable {
    static let shared = RefreshCoalescer()
    private let inflight = Mutex<[String: Task<String, Error>]>([:])

    /// Run `work` under the per-account single-flight lock. If a refresh for
    /// `accountId` is already in flight, await its result instead of firing a
    /// second one. Cleans up on completion.
    func run(accountId: String, work: @escaping @Sendable () async throws -> String) async throws -> String {
        let (task, isOwner): (Task<String, Error>, Bool) = inflight.withLock { dict in
            if let existing = dict[accountId] { return (existing, false) }
            let t = Task { try await work() }
            dict[accountId] = t
            return (t, true)
        }
        defer {
            // Only the task that created the slot clears it. Non-owner awaiters
            // just consume the cached result — they must not touch the dict or
            // they could wipe a slot belonging to a later in-flight refresh.
            if isOwner {
                inflight.withLock { $0[accountId] = nil }
            }
        }
        return try await task.value
    }
}

/// NSE-side conformer for `Shared/Auth/AuthSource`. Backed by the shared
/// keychain group: access tokens + refresh tokens are stored per-account and
/// refreshed against the provider's OAuth endpoint when the main-app can't
/// mediate (NSE runs outside the main app process).
///
/// One instance per account. Reads/writes tokens via `SharedKeychain`; calls
/// the provider's OAuth token endpoint directly on refresh.
///
/// Concurrent-refresh safety:
///   1. `current()` always reads fresh from keychain — never caches in memory
///      (main app may have refreshed while NSE was suspended).
///   2. `refresh()` is single-flighted per accountId via `RefreshCoalescer`.
///   3. Inside the single-flight lock, we re-read the keychain before hitting
///      the network — if another process already refreshed, use that token.
struct NSEAuthSource: AuthSource {
    let accountId: String
    let provider: String  // "gmail" / "outlook"
    /// Token the caller last saw via `current()`. Used to detect cross-process
    /// refreshes: if the keychain now holds something different, another actor
    /// already did the work. `nil` means "refresh unconditionally".
    private let lastSeen: String?

    init(accountId: String, provider: String = "gmail", lastSeen: String? = nil) {
        self.accountId = accountId
        self.provider = provider
        self.lastSeen = lastSeen
    }

    func current() async -> String? {
        SharedKeychain.getAccessToken(for: accountId)
    }

    func refresh() async throws -> String {
        try await RefreshCoalescer.shared.run(accountId: accountId) {
            // Race defense: another actor (main app) may have refreshed since
            // the caller's last current() read. If so, use that token and skip
            // the network call — avoids invalidating a rotated refresh_token.
            if let seen = self.lastSeen,
               let stored = SharedKeychain.getAccessToken(for: self.accountId),
               stored != seen {
                os_log(.info, log: log, "NSEAuthSource: reusing peer-refreshed token for %{public}@", self.accountId)
                return stored
            }

            guard let refreshToken = SharedKeychain.getRefreshToken(for: self.accountId) else {
                os_log(.error, log: log, "NSEAuthSource: no refresh token for %{public}@", self.accountId)
                throw AuthError.noRefreshToken
            }

            switch self.provider {
            case "gmail":
                return try await self.refreshGoogle(refreshToken: refreshToken)
            case "outlook":
                return try await self.refreshMicrosoft(refreshToken: refreshToken)
            default:
                throw AuthError.refreshFailed(underlying: "unknown provider \(self.provider)")
            }
        }
    }

    // MARK: - Provider-specific refresh

    private func refreshGoogle(refreshToken: String) async throws -> String {
        guard let clientId = SharedNSEData.suite.string(forKey: "nse.googleClientId") else {
            throw AuthError.refreshFailed(underlying: "no googleClientId in shared defaults")
        }
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthError.refreshFailed(underlying: "invalid url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientId)"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw AuthError.refreshFailed(underlying: "google token endpoint returned non-200 or missing access_token")
        }

        SharedKeychain.setAccessToken(newToken, for: accountId)
        return newToken
    }

    private func refreshMicrosoft(refreshToken: String) async throws -> String {
        // Uses the PRIMARY (mail.readwrite / mail.send / calendar) client that
        // the user linked via in-app sign-in — NOT the metadata-scope client
        // stored server-side for the server-side classifier. The NSE fetches
        // full message bodies, which requires the broader scope that's held
        // on-device in the shared Keychain.
        guard let clientId = SharedNSEData.suite.string(forKey: "nse.microsoftClientId"), !clientId.isEmpty else {
            throw AuthError.refreshFailed(underlying: "no microsoftClientId in shared defaults")
        }
        guard let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token") else {
            throw AuthError.refreshFailed(underlying: "invalid url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Request the same broad scope the main-app holds; otherwise Graph
        // might narrow the returned access_token to a subset (e.g.
        // Mail.ReadBasic) that can't fetch body content.
        let scope = "Mail.ReadWrite Mail.Send Calendars.ReadWrite offline_access User.Read"
        let params = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)",
            "scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)",
        ]
        request.httpBody = params.joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw AuthError.refreshFailed(underlying: "microsoft token endpoint returned non-200 or missing access_token")
        }

        SharedKeychain.setAccessToken(newToken, for: accountId)
        return newToken
    }
}
