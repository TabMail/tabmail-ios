/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `ComposeChatPillTip` on the DynamicIslandChat pill in `ComposeView`.
/// Blank compose (no replyTo) for simplicity.
#Preview("ComposeChatPillTip — ComposeView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(ComposeChatPillTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        ComposeView(account: scenario.account)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
