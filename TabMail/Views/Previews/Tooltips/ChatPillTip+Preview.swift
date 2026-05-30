/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `ChatPillTip` on the DynamicIslandChat pill inside `MessageDetailView`.
#Preview("ChatPillTip — MessageDetailView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(ChatPillTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        MessageDetailView(messageId: scenario.headers[0].id)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
