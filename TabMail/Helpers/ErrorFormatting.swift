/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension Error {
    /// Returns a user-friendly error description.
    /// In debug mode, returns the full `localizedDescription`.
    /// In production, strips parenthesized technical details (error domains, codes)
    /// like "(com.apple.AuthenticationServices.WebAuthenticationSession error 1.)".
    var userFacingDescription: String {
        let full = localizedDescription
        if DebugModeManager.isLoggingEnabled() {
            return full
        }
        // Strip parenthesized technical details containing dot-separated domains
        // e.g. "(com.apple.AuthenticationServices... error 1.)" or "(NSURLErrorDomain error -1009.)"
        let stripped = full.replacingOccurrences(
            of: #"\s*\([^)]*\.[^)]*\)"#,
            with: "",
            options: .regularExpression
        )
        let result = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? full : result
    }
}
