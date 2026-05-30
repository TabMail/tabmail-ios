/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `OutboxSwipeActionsTip` on the first row of `OutboxView`.
#Preview("OutboxSwipeActionsTip — OutboxView") {
    let scenario = PreviewMocks.seedInbox()
    _ = PreviewMocks.seedOutbox(account: scenario.account)
    PreviewMocks.spotlight(OutboxSwipeActionsTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        OutboxView(accountId: nil)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
