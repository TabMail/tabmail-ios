/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `DeviceSyncTip` on a settings page with pull-to-refresh.
/// Hosted in CompositionPromptView (also used by TemplatesListView, ActionRulesView).
#Preview("DeviceSyncTip — CompositionPromptView") {
    _ = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(DeviceSyncTip.self)
    let navStore = PreviewMocks.navigationStore()

    return NavigationStack {
        CompositionPromptView()
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
