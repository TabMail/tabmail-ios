/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `ComposeChatCollapseTip` on the "Edit Draft" header of the
/// expanded compose chat pill in `ComposeView`.
///
/// LIMITATION: anchor only visible while the compose chat pill is expanded
/// (private `@State` inside `DynamicIslandChat`); preview shows host chrome,
/// popover renders without visible anchor.
#Preview("ComposeChatCollapseTip — ComposeView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(ComposeChatCollapseTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        ComposeView(account: scenario.account)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
