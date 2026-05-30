/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// AddAccountGeneralView wraps itself in a Form/ScrollView and reads
// AccountManager.shared internally. The previews don't trigger any
// real OAuth — the provider buttons are inert until tapped, and the
// shared manager handles the no-op gracefully in DEBUG.

#Preview("AddAccountGeneral – Default") {
    NavigationStack {
        AddAccountGeneralView()
    }
}

#Preview("AddAccountGeneral – Dark") {
    NavigationStack {
        AddAccountGeneralView()
    }
    .preferredColorScheme(.dark)
}
#endif
