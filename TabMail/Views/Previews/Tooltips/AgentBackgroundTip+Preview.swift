/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `AgentBackgroundTip` on the chat pill in `InboxView`.
/// Rendered by `AgentBackgroundTipModifier` when a different view has an
/// active agent working. Spotlight bypasses the parameter rule.
#Preview("AgentBackgroundTip — InboxView chat pill") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(AgentBackgroundTip.self)
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
