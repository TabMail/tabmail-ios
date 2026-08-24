/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure account-incarnation admission rule shared by the main app and NSE.
enum AccountPushIncarnationPolicy {
    private static let knownAccountProviders: Set<String> = [
        "gmail", "outlook", "imap", "imap_new_mail", "imap_reconnect", "consent_error",
    ]

    static func matches(
        provider: String?,
        accountEmail: String,
        accountIncarnation: String?,
        accountId: (String) -> String?
    ) -> Bool {
        let normalizedProvider = provider?.lowercased() ?? ""
        let normalizedEmail = accountEmail.lowercased()
        if normalizedEmail.isEmpty {
            // Local/unscoped notifications carry neither an account address nor
            // a known account provider. A malformed account push must not use
            // that same escape hatch.
            return !knownAccountProviders.contains(normalizedProvider)
        }
        guard let accountIncarnation, !accountIncarnation.isEmpty else { return false }
        return accountId(normalizedEmail) == accountIncarnation
    }
}
