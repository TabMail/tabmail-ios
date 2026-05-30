/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import TipKit

/// Preview: `RemindersMenuTip` on the Reminders nav link in the sidebar
/// (`MailNavigationView`).
#Preview("RemindersMenuTip — Sidebar") {
    _ = PreviewMocks.seedInbox()
    PreviewMocks.spotlight(RemindersMenuTip.self)
    let navStore = PreviewMocks.navigationStore()

    return MailNavigationView()
        .environment(navStore)
        .environment(\.hasTabMailSession, true)
}
#endif
