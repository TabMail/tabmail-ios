/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One calendar change that failed after its chat turn ended (`LateCalendarFailureStore`),
/// laid out like the inbox error banner. Dismiss is its only button.
struct LateCalendarFailureBanner: View {
    let failure: LateCalendarFailure
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(failure.bannerText)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.errorBg)
        .foregroundStyle(Theme.errorFg)
    }
}
