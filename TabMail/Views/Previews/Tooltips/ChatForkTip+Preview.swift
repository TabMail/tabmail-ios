/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `ChatForkTip` on a user chat bubble inside the DynamicIslandChat
/// pill, embedded in `InboxView`.
///
/// LIMITATION: the chat pill defaults to collapsed (`chatExpanded` is private
/// `@State` inside `InboxView`), and the tip's bubble anchor only exists after
/// the user has sent at least one chat message. We can't force either from
/// outside the view, so this preview shows the host chrome but the popover
/// has no visible anchor. Use it for tip-text review; for anchor placement,
/// verify in the running app.
#Preview("ChatForkTip — InboxView chat") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(ChatForkTip.self)
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
