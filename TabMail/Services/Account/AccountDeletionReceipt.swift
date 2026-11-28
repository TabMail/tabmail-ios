/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Carries the "Deletion Scheduled" confirmation from the deletion screen to
/// `RootView` across the sign-out that ends a deletion.
///
/// Signing out moves `RootView.routedContent` to another branch, which removes
/// the signed-in navigation and the deletion screen with it, so the screen's own
/// confirmation never appears. The screen hands a receipt here right before it
/// signs out; `RootView` takes it when the sign-out notification arrives and
/// shows the confirmation as a sheet in place of the "Signed Out" alert.
///
/// In memory only: nothing is stored. When the sign-out fails no notification
/// follows, so the receipt is dropped at once and the deletion screen, still
/// shown, gives the confirmation itself.
@MainActor
enum AccountDeletionReceipt {
    struct Receipt: Identifiable, Equatable, Sendable {
        let id = UUID()
        /// The server's deletion date, formatted for display; nil when it could
        /// not be read, and the confirmation then names no date.
        let scheduledDateText: String?
        /// The confirmation shows how to stop using the Apple Account with
        /// TabMail by hand (`AppleIDSignIn.showsManualStopLine`).
        let showsAppleManualStop: Bool
    }

    private static var pending: Receipt?

    /// Runs `signOut` with `receipt` waiting for `RootView`. A failed sign-out
    /// drops the receipt, so no later sign-out can show it.
    static func signOut(handing receipt: Receipt, signOut: () -> Bool) -> Bool {
        pending = receipt
        guard signOut() else {
            pending = nil
            return false
        }
        return true
    }

    /// The receipt of the deletion that just signed out, once; nil after any
    /// other sign-out.
    static func take() -> Receipt? {
        defer { pending = nil }
        return pending
    }
}
