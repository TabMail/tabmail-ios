/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Outcome of classifying an error thrown by an `onConnect` closure
/// in `AddAccountGmailOutlookView` (and any future consent gate that
/// runs an OAuth on Connect).
///
/// We split errors into two buckets:
///
/// * `silentRetry` — the user's intent isn't ambiguous, but the
///   operation didn't complete (Swift task cancel, ASWebAuth's
///   `canceledLogin`). Showing an error would be confusing because
///   nothing actually went wrong from the user's point of view; they
///   just want to try again or tap **No Thanks**. The gate stays
///   visible with the spinner reset.
///
/// * `showError(message:)` — a real failure the user should see
///   (network timeout, server 500, OAuth `error=...` response).
///   The gate displays the message inline and stays visible. **Failure
///   never silently routes the user out of the gate** — only **No
///   Thanks** does.
enum ConnectErrorOutcome: Equatable {
    case silentRetry
    case showError(message: String)
}

enum ConnectErrorClassifier {
    /// `ASWebAuthenticationSession`'s `canceledLogin` error code. The
    /// Apple-provided enum case is `ASWebAuthenticationSessionError.canceledLogin = 1`,
    /// but matching by the raw `(domain, code)` pair lets us write
    /// tests without importing AuthenticationServices in the test
    /// target.
    static let asWebAuthSessionDomain = "com.apple.AuthenticationServices.WebAuthenticationSession"
    static let asWebAuthCanceledLoginCode = 1

    static func classify(_ error: Error) -> ConnectErrorOutcome {
        if error is CancellationError {
            return .silentRetry
        }
        let nsError = error as NSError
        if nsError.domain == asWebAuthSessionDomain
            && nsError.code == asWebAuthCanceledLoginCode {
            return .silentRetry
        }
        return .showError(message: "Couldn't connect: \(error.localizedDescription). Please try again.")
    }
}
