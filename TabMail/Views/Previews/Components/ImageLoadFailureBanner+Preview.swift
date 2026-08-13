/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

/// Preview: the P4 image-failure banner as `AutoSizingHTMLView` renders it —
/// same 16pt horizontal inset and 8pt bottom gap the real call site applies, so
/// the canvas shows the actual spacing above a message body rather than the
/// component floating on its own.
///
/// The dismiss button is wired to local state so the canvas exercises the ONLY
/// affordance the banner has. There is deliberately no "Load anyway" variant to
/// preview — see the component's doc comment for why one cannot exist.
#Preview("ImageLoadFailureBanner — light") {
    ImageLoadFailureBannerPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("ImageLoadFailureBanner — dark") {
    ImageLoadFailureBannerPreviewHost()
        .preferredColorScheme(.dark)
}

private struct ImageLoadFailureBannerPreviewHost: View {
    @State private var dismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if dismissed {
                Text("dismissed — the banner never returns for this document")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                ImageLoadFailureBanner { dismissed = true }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Text("Message body renders here.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 24)
    }
}
#endif
