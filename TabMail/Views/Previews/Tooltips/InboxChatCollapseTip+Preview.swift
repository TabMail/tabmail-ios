/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `InboxChatCollapseTip` on the chat-pill chevron in `InboxView`.
/// Rendered by `ChatPillCollapseTipModifier` when chat is expanded and the
/// user has already sent a message. Spotlight bypasses the rule; the tip
/// anchor is the chevron button, which only appears when chat is expanded.
/// In this preview the chat pill is collapsed by default, so the popover
/// may not render on its preferred anchor — this preview is primarily for
/// visual inspection of the tip's text and chrome.
#Preview("InboxChatCollapseTip — InboxView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(InboxChatCollapseTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack(path: .constant([scenario.inbox])) {
        Color.clear
            .navigationDestination(for: Folder.self) { _ in
                InboxView(
                    title: "All Inboxes",
                    folders: [scenario.inbox],
                    selection: .unified(.inbox),
                    selectedMessageId: .constant(nil),
                    pushedMessageId: .constant(nil)
                )
            }
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
