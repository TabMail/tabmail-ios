/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `SearchScopeTip` on the scope-toggle button in `SearchView`.
#Preview("SearchScopeTip — SearchView") {
    let scenario = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(SearchScopeTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        SearchView(folders: [scenario.inbox], scopeTitle: "Inbox")
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
