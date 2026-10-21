/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

#Preview("Welcome") {
    TutorialWelcomeView(onStart: {}, onSkip: {})
}

#Preview("Finish, new user") {
    TutorialFinishView(signedIn: false)
}

#Preview("Finish, signed-in replay") {
    TutorialFinishView(signedIn: true)
}

#Preview("Sidebar rows") {
    List {
        Section {
            TutorialSidebarRow(state: .progress(done: 1, total: 3, next: .reuseReply)) {}
            Label("TabMail Settings", systemImage: "brain")
            TutorialSidebarRow(state: .replay) {}
        }
    }
}
#endif
