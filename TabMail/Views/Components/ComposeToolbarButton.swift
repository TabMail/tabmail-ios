/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Compose toolbar button that pulses when a compose agent is working.
/// When agent is working: tapping opens the in-progress draft via DraftComposePresenter.
/// When idle: tapping opens new compose.
struct ComposeToolbarButton: View {
    let onNewCompose: () -> Void
    @State private var showDraft = false
    @State private var draftIdToOpen: String?

    var body: some View {
        Button {
            if let draftId = ActiveAgentTracker.shared.workingComposeDraftId {
                print("[ComposeToolbar] Opening working draft: \(draftId)")
                draftIdToOpen = draftId
                showDraft = true
            } else {
                onNewCompose()
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(ActiveAgentTracker.shared.anyComposeWorking ? Theme.accent : .primary)
                .symbolEffect(.pulse, isActive: ActiveAgentTracker.shared.anyComposeWorking)
        }
        .fullScreenCover(isPresented: $showDraft) {
            if let draftId = draftIdToOpen {
                DraftComposePresenter(draftId: draftId)
            }
        }
    }
}
