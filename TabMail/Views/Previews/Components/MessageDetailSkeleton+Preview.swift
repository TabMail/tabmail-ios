/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

/// Preview: the detail-view loading skeleton exactly as `MessageDetailView`
/// renders it — `bodyContent`'s nil-`message` branch is literally
/// `MessageDetailSkeleton()`, so wrapping the real component in the same
/// navigation chrome (empty inline title, as during an unresolved open) is
/// pixel-faithful to the in-app loading state.
///
/// A "real `MessageDetailView` with an unresolvable id" variant was
/// deliberately NOT added: `loadBody` flips to the Message-Not-Found state as
/// soon as its resolve + server fallback fail (fast in the preview canvas, no
/// live providers), so the skeleton only flashes — useless for look-debugging
/// and nondeterministic. The shimmer sweep (`aiWorkingShimmer`) animates live
/// in the canvas.
#Preview("MessageDetailSkeleton — light") {
    NavigationStack {
        MessageDetailSkeleton()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("MessageDetailSkeleton — dark") {
    NavigationStack {
        MessageDetailSkeleton()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
    .preferredColorScheme(.dark)
}
#endif
