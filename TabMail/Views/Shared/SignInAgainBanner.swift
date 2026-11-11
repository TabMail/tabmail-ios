/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Inbox banner for one account whose sign-in the server refused, with a Sign In
/// action. Same shape as `UsageThrottleBanner`: subtle, no dismiss button (the
/// condition clears itself on the next accepted login), the tap action injected by
/// the caller.
///
/// Driven only by `AccountManagerState.authFailedAccounts`, the one "sign in
/// again" signal. Its copy is fixed; it never shows an error's text.
struct SignInAgainBanner: View {
    let emailAddress: String
    let onSignIn: () -> Void

    static let title = "Sign in again"
    static let message = "Mail for this account has stopped until you sign in."
    static let actionTitle = "Sign In"

    /// The accounts to show a banner for, in sidebar order.
    static func accounts(failed: Set<String>, in accounts: [Account]) -> [Account] {
        accounts.filter { failed.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Self.title): \(emailAddress)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textColor)
                Text(Self.message)
                    .font(.caption2)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(Self.actionTitle, action: onSignIn)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
