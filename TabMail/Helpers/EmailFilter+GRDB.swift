/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// Main-app-only extension to EmailFilter — adds GRDB-bound utilities that can't
/// live in the Shared target (NSE has no access to AppDatabase).
///
/// Pure functions (parsing, HTML→plaintext, quote splitting, unsubscribe detection,
/// etc.) live in Shared/Parse/EmailFilter.swift and are compiled into both targets.
extension EmailFilter {
    /// Cached set of all user email addresses (lowercased) across all accounts.
    /// Matches TB's getUserEmailSetCached() in senderFilter.js — checks all accounts/identities.
    private static let _cachedUserEmails = Mutex<Set<String>?>(nil)

    #if DEBUG
    /// Test-only override: when set, isSelfSent uses this set instead of reading AppDatabase.
    /// Avoids race conditions from concurrent test suites overwriting the global AppDatabase.shared.
    static let _testOverrideEmails = Mutex<Set<String>?>(nil)
    #endif

    /// Returns true if the sender address matches ANY of the user's own account emails.
    /// Uses a cached set of all account emails from GRDB, refreshed when nil.
    static func isSelfSent(_ fromAddress: String) -> Bool {
        let lower = fromAddress.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return false }
        let emails = loadUserEmailsCached()
        return emails.contains(lower)
    }

    /// Invalidate the cached user emails (call when accounts are added/removed).
    static func invalidateUserEmailCache() {
        _cachedUserEmails.withLock { $0 = nil }
    }

    private static func loadUserEmailsCached() -> Set<String> {
        #if DEBUG
        if let override = _testOverrideEmails.withLock({ $0 }) {
            return override
        }
        #endif
        return _cachedUserEmails.withLock { cached in
            if let existing = cached { return existing }
            var emails = Set<String>()
            if let db = AppDatabase.shared.withLock({ $0 }) {
                let accounts = (try? db.dbPool.read { db in
                    try Account.fetchAll(db)
                }) ?? []
                for account in accounts {
                    let addr = account.emailAddress.lowercased().trimmingCharacters(in: .whitespaces)
                    if !addr.isEmpty { emails.insert(addr) }
                }
            }
            cached = emails
            return emails
        }
    }
}
