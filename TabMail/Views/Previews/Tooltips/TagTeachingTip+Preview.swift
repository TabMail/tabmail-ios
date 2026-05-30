/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `TagTeachingTip` on the tag badge in `MessageDetailView`.
/// Uses the first seeded message, which has `actionTag = .reply`.
#Preview("TagTeachingTip — MessageDetailView") {
    let scenario = PreviewMocks.seedInbox()
    let messageId = scenario.headers[0].id
    PreviewMocks.spotlight(TagTeachingTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        MessageDetailView(messageId: messageId)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
