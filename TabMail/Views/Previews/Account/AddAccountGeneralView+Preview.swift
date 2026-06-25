/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// AddAccountGeneralView wraps itself in a Form/ScrollView and reads
// AccountManager.shared internally. The previews don't trigger any
// real OAuth — the provider buttons are inert until tapped, and the
// shared manager handles the no-op gracefully in DEBUG.
// A bare (empty) NavigationStore is injected because the view now reads
// it to refresh the sidebar before dismissing on a successful add.

#Preview("AddAccountGeneral – Default") {
    NavigationStack {
        AddAccountGeneralView()
    }
    .environment(NavigationStore())
}

#Preview("AddAccountGeneral – Dark") {
    NavigationStack {
        AddAccountGeneralView()
    }
    .environment(NavigationStore())
    .preferredColorScheme(.dark)
}
#endif
