/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `MessageChatCollapseTip` on the chat-pill chevron in `MessageDetailView`.
/// Anchor only visible when chat is expanded — this preview shows the collapsed
/// state; kept for visual inspection of the tip text/chrome.
#Preview("MessageChatCollapseTip — MessageDetailView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(MessageChatCollapseTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        MessageDetailView(messageId: scenario.headers[0].id)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
