/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// RootView's presenter of a confirmed Undo's reopened compose, the one presenter for the toast's
/// Undo and a chat bubble's. It presents the head of `PendingSendService.reopenQueue` only while no
/// chat modal is open (`topLevelReopen`); closing the compose opens the next.
struct UndoReopenPresenter: ViewModifier {
    private var service: PendingSendService { PendingSendService.shared }

    private var reopen: Binding<PendingSendService.ReopenSnapshot?> {
        Binding(get: { service.topLevelReopen },
                set: { if $0 == nil { service.finishReopen() } })
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(item: reopen) { snapshot in
            UndoReopenCompose(snapshot: snapshot)
        }
    }
}

extension View {
    /// A sheet that can hold a chat, and so a bubble's Undo (Search). Once an Undo's outcome
    /// waits (a compose to reopen, or the "Couldn't undo" notice) while the sheet is the chat modal
    /// on top (`PendingSendService.closesForOutcome`), the sheet closes, and RootView presents the
    /// outcome when it is gone: Undo from a chat opened here ends at the top level, as the toast's
    /// did. It never closes on the tap itself, only on the outcome.
    func chatModalSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(ChatModalSheet(isPresented: isPresented, sheet: content))
    }

    /// A new email's chat, which can hold a bubble's Undo while it is over RootView's screens (a
    /// cover, or pushed): while it is the chat modal on top, it presents an Undo's outcome over
    /// itself, the reopened compose and the "Couldn't undo" notice, as RootView would, so closing
    /// that compose returns to the chat. `id` is the screen's own, kept for its whole presentation.
    func undoOutcomesPresented(by id: UUID) -> some View {
        modifier(UndoOutcomesPresenter(id: id))
    }
}

private struct ChatModalSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheet: () -> Sheet
    @State private var id = UUID()

    private var service: PendingSendService { PendingSendService.shared }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                sheet()
                    .onAppear { service.chatModalOpened(id) }
                    .onDisappear { service.chatModalClosed(id) }
            }
            .onChange(of: service.closesForOutcome(id)) { _, closes in
                if closes { isPresented = false }
            }
    }
}

private struct UndoOutcomesPresenter: ViewModifier {
    let id: UUID

    private var service: PendingSendService { PendingSendService.shared }

    private var reopen: Binding<PendingSendService.ReopenSnapshot?> {
        Binding(get: { service.reopen(presentedBy: id) },
                set: { if $0 == nil { service.finishReopen() } })
    }

    private var notice: Binding<Bool> {
        Binding(get: { service.undoFailureMessage(presentedBy: id) != nil },
                set: { if !$0 { service.dismissUndoFailure() } })
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: reopen) { snapshot in
                UndoReopenCompose(snapshot: snapshot)
            }
            // RootView's own words for it (`UndoFailureAlertHost`).
            .alert("Couldn't undo", isPresented: notice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(service.undoFailureMessage(presentedBy: id) ?? "")
            }
            .onAppear { service.chatModalOpened(id) }
            .onDisappear { service.chatModalClosed(id) }
    }
}
