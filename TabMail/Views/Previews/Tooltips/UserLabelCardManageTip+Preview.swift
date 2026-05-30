/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `UserLabelCardManageTip` on a label chip in `MessageDetailView`.
/// Seed gives the first message a "Work" label for the chip anchor.
#Preview("UserLabelCardManageTip — MessageDetailView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(UserLabelCardManageTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        MessageDetailView(messageId: scenario.headers[0].id)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
