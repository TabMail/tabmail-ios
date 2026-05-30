/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// Previews for the recipient-cap UI in ComposeView. Launches ComposeView with
// a prefillTo array of various sizes to exercise the three visible states:
//   - hidden counter (< 45 recipients)
//   - gray counter "N/50" (45–49)
//   - orange counter "50/50 — limit reached" (cap)
//   - orange counter "51/50" + overflow (reply-all scenario; Send will error)
//
// Bypasses the normal user-typed-in path by seeding tokens via prefillTo.

/// Generate N distinct test recipient emails. Deterministic so preview output
/// is stable.
private func recipients(_ n: Int) -> [String] {
    (0..<n).map { "recipient-\($0)@example.com" }
}

#Preview("Under threshold — no counter (10 recipients)") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        ComposeView(
            account: scenario.account,
            prefillTo: recipients(10)
        )
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Gray counter — 47/50") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        ComposeView(
            account: scenario.account,
            prefillTo: recipients(47)
        )
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Orange counter at cap — 50/50") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        ComposeView(
            account: scenario.account,
            prefillTo: recipients(50)
        )
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Reply-all overflow — 51/50 (Send will error)") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        ComposeView(
            account: scenario.account,
            prefillTo: recipients(51)
        )
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Mixed fields — 20 To + 20 Cc + 10 Bcc = 50/50 orange") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        ComposeView(
            account: scenario.account,
            prefillTo: Array(recipients(50).prefix(20)),
            prefillCc: Array(recipients(50)[20..<40]),
            prefillBcc: Array(recipients(50)[40..<50])
        )
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
