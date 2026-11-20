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
    /// waits for RootView (a compose to reopen, or the "Couldn't undo" notice), the sheet closes,
    /// and RootView presents the outcome when it is gone: Undo from a chat opened here ends at the
    /// top level, as the toast's did. It never closes on the tap itself, only on the outcome.
    func chatModalSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(ChatModalSheet(isPresented: isPresented, sheet: content))
    }
}

private struct ChatModalSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheet: () -> Sheet

    private var service: PendingSendService { PendingSendService.shared }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                sheet()
                    .onAppear { service.chatModalOpened() }
                    .onDisappear { service.chatModalClosed() }
            }
            .onChange(of: service.outcomeWaits) { _, waits in
                if waits { isPresented = false }
            }
    }
}
