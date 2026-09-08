/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

/// Renders the production swipe controls with observable, side-effect-free callbacks.
struct InboxSwipeControlsTestScene: View {
    @State private var archived = 0
    @State private var deleted = 0

    var body: some View {
        VStack {
            Text("Archived: \(archived) Deleted: \(deleted)")
            List {
                row("Ordinary mail", isArchive: false, isTrash: false)
                row("Archive folder", isArchive: true, isTrash: false)
                row("Trash folder", isArchive: false, isTrash: true)
            }
        }
    }

    private func row(_ title: String, isArchive: Bool, isTrash: Bool) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                InboxTrailingSwipeActions(
                    isDrafts: false, isArchive: isArchive, isTrash: isTrash,
                    archive: { archived += 1 }, delete: { deleted += 1 })
            }
    }
}
#endif
