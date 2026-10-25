/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Compose toolbar button that pulses when a compose agent is working.
/// When agent is working: tapping prepares the in-progress draft
/// (`DraftOpenPreparation`, the button busy meanwhile) and opens it filled.
/// When idle: tapping opens new compose.
struct ComposeToolbarButton: View {
    let onNewCompose: () -> Void
    @State private var preparedDraftOpen: PreparedDraftOpen?
    /// Busy while this button's open is being prepared; a newer open or an
    /// accepted navigation cancels it (`DraftOpenTracker`).
    private var isOpeningDraft: Bool { DraftOpenTracker.shared.mark == DraftOpenTracker.toolbarMark }

    var body: some View {
        Button {
            if let draftId = ActiveAgentTracker.shared.workingComposeDraftId {
                BackgroundSyncLogger.logDebug("[ComposeToolbar] Opening working draft: \(draftId)")
                Task {
                    guard let open = await DraftOpenPreparation.open(
                        .draftId(draftId), mark: DraftOpenTracker.toolbarMark) else { return }
                    preparedDraftOpen = open
                }
            } else {
                onNewCompose()
            }
        } label: {
            if isOpeningDraft {
                ProgressView()
                    .accessibilityLabel("Opening draft")
            } else {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(ActiveAgentTracker.shared.anyComposeWorking ? Theme.accent : .primary)
                    .symbolEffect(.pulse, isActive: ActiveAgentTracker.shared.anyComposeWorking)
            }
        }
        .fullScreenCover(item: $preparedDraftOpen) { open in
            DraftComposePresenter(source: open.source, prepared: open.outcome)
        }
    }
}
