/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Main-app conformer for `Shared/Auth/AuthSource`. Wraps the existing
/// closure-based token accessor used by `GmailProvider`, `ExchangeProvider`,
/// etc. so shared API layers (`GmailAPI`, `GraphAPI`) can be called from the
/// main app without changing provider public APIs.
///
/// `current()` calls the closure with `forceRefresh: false` (fast path —
/// `OAuthService` returns cached token). `refresh()` calls with
/// `forceRefresh: true` (network round-trip to the provider's token endpoint).
struct AccountAuthSource: AuthSource {
    let accountId: String
    private let getter: @Sendable (_ forceRefresh: Bool) async throws -> String

    init(
        accountId: String,
        accessToken: @Sendable @escaping (_ forceRefresh: Bool) async throws -> String
    ) {
        self.accountId = accountId
        self.getter = accessToken
    }

    func current() async -> String? {
        do { return try await getter(false) } catch { return nil }
    }

    func refresh() async throws -> String {
        do { return try await getter(true) }
        catch { throw AuthError.refreshFailed(underlying: "\(error)") }
    }
}
