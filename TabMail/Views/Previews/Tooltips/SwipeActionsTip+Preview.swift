/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `SwipeActionsTip` in `InboxView` with mock inbox data.
/// The tip anchors on the first message row; donate the `inboxVisitCount`
/// event twice to satisfy the `>= 2` rule.
#Preview("SwipeActionsTip — InboxView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(SwipeActionsTip.self)
    let navStore = PreviewMocks.navigationStore()

    // Push InboxView onto a NavigationStack path so the back-chevron
    // renders in the nav bar (matching real app chrome where the user
    // navigates into the inbox from the sidebar).
    return NavigationStack(path: .constant([scenario.inbox])) {
        Color.clear
            .navigationDestination(for: Folder.self) { _ in
                InboxView(
                    title: "All Inboxes",
                    folders: [scenario.inbox],
                    selection: .unified(.inbox),
                    selectedMessageId: .constant(nil)
                )
            }
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
    .task {
        await SwipeActionsTip.inboxVisitCount.donate()
        await SwipeActionsTip.inboxVisitCount.donate()
    }
}
#endif
