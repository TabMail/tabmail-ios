/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// Holds a deferred email-account-add operation between the TabMail
/// sign-in and the user's explicit confirmation in the matching
/// consent gate (`AddAccountGmailOutlookView` for Gmail/Outlook,
/// `AddAccountICloudView` for iCloud).
///
/// Without this, Gmail/Outlook accounts were created silently inside
/// the merged OAuth popup with no consent gate, and iCloud accounts
/// were prompted only as a sheet over the inbox after onboarding —
/// both of which skipped the gate flow.
///
/// In-memory only on purpose: the gate is transient. If the app is
/// killed between sign-in and the gate decision, the user re-runs
/// sign-in next launch — no silent account creation is possible.
///
/// Tokens are NOT stored here for Gmail/Outlook. The first OAuth
/// (identity-only) gives us the email; the second OAuth (full mail
/// scopes) runs when the user taps **Connect**, and that's when
/// `addGmail/OutlookAccountWithTokens` finally executes.
@MainActor
@Observable
final class PendingAccountAdd {
    static let shared = PendingAccountAdd()
    private init() {}

    enum Provider: Sendable {
        case gmail
        case outlook
        case icloud
    }

    struct Pending: Sendable, Equatable {
        let provider: Provider
        let email: String
    }

    var pending: Pending?

    func clear() {
        pending = nil
    }
}
