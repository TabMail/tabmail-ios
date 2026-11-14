/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One calendar change still queued for a reason the user can act on (`LateCalendarFailureStore.waiting`),
/// laid out like the failure banner. It has no button: the change is still going to be made, and the
/// banner goes once it is.
struct WaitingCalendarChangeBanner: View {
    let change: WaitingCalendarChange

    var body: some View {
        HStack {
            Image(systemName: "clock.badge.exclamationmark")
            Text(change.bannerText)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.errorBg)
        .foregroundStyle(Theme.errorFg)
    }
}
