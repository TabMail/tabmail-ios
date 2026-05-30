/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `ComposeSaveDraftTip` on the (collapsed) compose chat pill in
/// `ComposeView`. In the real app, this tip only fires after the user has
/// expanded + collapsed the compose chat at least once. `spotlight` bypasses
/// that rule for preview.
#Preview("ComposeSaveDraftTip — ComposeView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(ComposeSaveDraftTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        ComposeView(account: scenario.account)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
