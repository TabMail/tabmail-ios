/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Reusable prompt encouraging the user to sign in to TabMail for AI features.
/// Presents `TabMailLoginView` as a sheet when tapped.
struct TabMailSignInPrompt: View {
    @State private var showLogin = false
    var onSignedIn: (() -> Void)?

    var body: some View {
        Button {
            showLogin = true
        } label: {
            Label("Sign in for AI features", systemImage: "sparkles")
        }
        .sheet(isPresented: $showLogin) {
            TabMailLoginView {
                showLogin = false
                NotificationCenter.default.post(name: .tabMailDidSignIn, object: nil)
                onSignedIn?()
            }
        }
    }
}
