/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

#Preview("AddAccount – Gmail") {
    AddAccountGmailOutlookView(
        provider: .gmail,
        email: "alex@example.com",
        onConnect: { try await Task.sleep(for: .milliseconds(400)) },
        onLater: {}
    )
}

#Preview("AddAccount – Gmail (Dark)") {
    AddAccountGmailOutlookView(
        provider: .gmail,
        email: "alex@example.com",
        onConnect: { try await Task.sleep(for: .milliseconds(400)) },
        onLater: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("AddAccount – Outlook") {
    AddAccountGmailOutlookView(
        provider: .outlook,
        email: "first.last@outlook.com",
        onConnect: { try await Task.sleep(for: .milliseconds(400)) },
        onLater: {}
    )
}

#Preview("AddAccount – Long email truncates") {
    AddAccountGmailOutlookView(
        provider: .gmail,
        email: "very.long.email.address.for.testing.truncation@somecompanydomain.example.com",
        onConnect: { try await Task.sleep(for: .milliseconds(400)) },
        onLater: {}
    )
}
#endif
