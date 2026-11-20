/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

/// Fixture for the keyboard focus UI test (`--keyboard-focus-ui-test`): one reply template, opened
/// at once in `TemplateDetailView`, whose plus button focuses the instruction field. The window's
/// keyboard-dismiss tap runs alongside that button (`KeyboardDismissView`), so the test checks the
/// field still has the keyboard after the tap.
struct KeyboardFocusTestScene: View {
    static let templateId = "keyboard-focus-fixture-template"
    @State private var ready = false

    var body: some View {
        NavigationStack {
            if ready {
                TemplateDetailView(templateId: Self.templateId)
            } else {
                Text("Preparing fixture")
            }
        }
        .task {
            let store = PromptStore.shared
            if !store.templates.contains(where: { $0.id == Self.templateId && !$0.deleted }) {
                store.addTemplate(ReplyTemplate(id: Self.templateId, name: "Keyboard focus fixture"))
            }
            ready = true
        }
    }
}
#endif
