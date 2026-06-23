/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

// Gallery of every app tip, for at-a-glance visual review of copy + layout.
#Preview("All Tips") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                TipView(SwipeActionsTip())
                TipView(TagTeachingTip())
                TipView(InboxTagTeachingTip())
                TipView(ArchiveOldEmailsTip())
                TipView(EnableInboxPushTip())
                TipView(TriageModeTip())
                TipView(SearchScopeTip())
                TipView(SummaryBubbleTip())
                TipView(InboxChatPillTip())
                TipView(ChatPillTip())
            }
            Group {
                TipView(ComposeChatPillTip())
                TipView(ChatForkTip())
                TipView(DeviceSyncTip())
                TipView(OutboxSwipeActionsTip())
                TipView(AgentBackgroundTip())
                TipView(ComposeSaveDraftTip())
                TipView(ComposeChatCollapseTip())
                TipView(InboxChatCollapseTip())
                TipView(MessageChatCollapseTip())
                TipView(RemindersMenuTip())
            }
        }
        .padding()
    }
}
#endif
