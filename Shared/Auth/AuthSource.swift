/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Single abstraction for supplying and refreshing auth tokens to shared API/command layers.
/// Main app provides `AccountAuthSource` (backed by OAuthService/TabMailTokenCoordinator).
/// NSE provides `NSEAuthSource` (backed by SharedKeychain/NSETokenManager).
/// IMAP providers supply an `IMAPPasswordAuthSource` for password accounts.
protocol AuthSource: Sendable {
    /// Identifier of the account this auth is for. Useful for logging + persisting
    /// refreshed tokens to the right slot.
    var accountId: String { get }

    /// Current cached token. Fast path — no network I/O expected. Return nil when
    /// the caller should force a refresh immediately (e.g. no token stored).
    func current() async -> String?

    /// Force refresh. Called on 401 or when `current()` returns nil/expired.
    /// Throws `AuthError` on permanent failure (revoked, invalid refresh token).
    func refresh() async throws -> String
}

enum AuthError: Error, Sendable {
    /// Refresh endpoint call failed (non-200, missing token, network error).
    /// `underlying` carries the provider-side error string for logging.
    case refreshFailed(underlying: String)
    /// No refresh token available for this account (user never authorized, or
    /// credentials were wiped). Caller should prompt re-auth.
    case noRefreshToken
    /// Used only in tests to simulate a closure throwing from `current()`.
    case noToken
}
