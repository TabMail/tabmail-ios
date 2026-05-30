/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `InboxTagTeachingTip` in `InboxView` on a row that has an action tag.
/// Seeds a message with `actionTag = .reply` so the tip has a valid anchor row.
#Preview("InboxTagTeachingTip — InboxView row") {
    // Seed already gives row 1 an action tag (.reply), so the tag-badge anchor exists.
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(InboxTagTeachingTip.self)
    let navStore = PreviewMocks.navigationStore()

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
}
#endif
