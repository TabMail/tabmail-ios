/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure account-incarnation admission rule shared by the main app and NSE.
enum AccountPushIncarnationPolicy {
    private static let knownAccountProviders: Set<String> = [
        "gmail", "outlook", "imap", "imap_new_mail", "imap_reconnect", "consent_error",
    ]

    /// Marker the NSE stamps on a payload it stripped, so the main app refuses
    /// the same push again without re-deriving the reason. Defined once here
    /// because both targets compile `Shared`.
    static let refusedPushMarkerKey = "tabmail.rejectedAccountPush"

    /// Why an account-scoped push was refused.
    ///
    /// There is deliberately no case for a MISSING incarnation. A payload that
    /// never carried the field is one we cannot judge, and "we could not
    /// determine" is never authoritative — conflating it with a proven mismatch
    /// is the most repeated defect class in this codebase.
    enum Refusal: String {
        /// The payload named an incarnation that is not the local account row.
        case replacedAccount = "account replaced"
        /// A known account provider sent a payload with no account address.
        case unscopedAccountPayload = "unscoped account payload"
    }

    static func refusal(
        provider: String?,
        accountEmail: String,
        accountIncarnation: String?,
        accountId: (String) -> String?
    ) -> Refusal? {
        let normalizedProvider = provider?.lowercased() ?? ""
        let normalizedEmail = accountEmail.lowercased()
        if normalizedEmail.isEmpty {
            // Local/unscoped notifications carry neither an account address nor
            // a known account provider. A malformed account push must not use
            // that same escape hatch.
            return knownAccountProviders.contains(normalizedProvider) ? .unscopedAccountPayload : nil
        }
        // ABSENT IS NOT PROVEN-STALE. Refuse only on a PRESENT value that
        // disagrees with the local account row. The replacement guarantee is
        // unaffected: when an account is replaced, the registration record the
        // push was routed from still holds the OLD identifier, so a replaced
        // account arrives present-and-unequal and is still refused.
        guard let accountIncarnation, !accountIncarnation.isEmpty else { return nil }
        return accountId(normalizedEmail) == accountIncarnation ? nil : .replacedAccount
    }

    static func matches(
        provider: String?,
        accountEmail: String,
        accountIncarnation: String?,
        accountId: (String) -> String?
    ) -> Bool {
        refusal(
            provider: provider,
            accountEmail: accountEmail,
            accountIncarnation: accountIncarnation,
            accountId: accountId
        ) == nil
    }
}
