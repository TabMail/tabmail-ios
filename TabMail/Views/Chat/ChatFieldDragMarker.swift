/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// What a drag on the reply field did to the chat, as an accessibility-only marker for the chat
/// swipe UI tests: XCUITest reads a frame only once the app is idle, well after the swell and its
/// settle, so the app records the newest row's largest vertical move itself, from a drag's start
/// until `watchAfterLetGo` after it lets go, beside whether the user-interaction freeze is held.
/// Active only in debug builds launched with the swipe UI test's argument (`--chat-swipe-ui-test`),
/// as the reply field's focus marker (`chatReplyFieldFocus`); it draws nothing (clear text in the
/// background, so no layout change).
///
/// The label reads `drags=<n> watching=<0|1> move=<points> frozen=<0|1>`.
enum ChatFieldDragMarker {
    static let identifier = "chatFieldDragMarker"

    /// On the pill: watches the drag and shows the marker.
    struct Field: ViewModifier {
        let dragging: Bool

        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content.modifier(Shown(dragging: dragging))
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// On each chat row: the newest row reports where its top is.
    struct Row: ViewModifier {
        let isNewest: Bool

        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive && isNewest {
                content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    Probe.shared.newestMoved(to: $0)
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    #if DEBUG
    @MainActor @Observable
    final class Probe {
        static let shared = Probe()
        static let isActive = ProcessInfo.processInfo.arguments.contains("--chat-swipe-ui-test")
        /// How long after a let-go the move is still recorded: past the field's settle
        /// (`ChatThreadView.fieldDragSettle`) and the freeze's hold (`swipeSettleHold`).
        static let watchAfterLetGo: Duration = .milliseconds(1500)

        private(set) var drags = 0
        private(set) var watching = false
        private(set) var largestMove: CGFloat = 0
        private var newestMinY: CGFloat?
        private var baseline: CGFloat?
        private var watchToken: UUID?

        func newestMoved(to minY: CGFloat) {
            newestMinY = minY
            guard watching, let baseline else { return }
            largestMove = max(largestMove, abs(minY - baseline))
        }

        func dragChanged(_ dragging: Bool) {
            if dragging {
                drags += 1
                watching = true
                watchToken = nil
                baseline = newestMinY
                largestMove = 0
                return
            }
            let token = UUID()
            watchToken = token
            Task { @MainActor in
                try? await Task.sleep(for: Self.watchAfterLetGo)
                guard self.watchToken == token else { return }
                self.watching = false
            }
        }

        var label: String {
            let move = String(format: "%.1f", largestMove)
            return "drags=\(drags) watching=\(watching ? 1 : 0) move=\(move) frozen=\(PreviewFreezeGate.shared.isFrozen ? 1 : 0)"
        }
    }

    private struct Shown: ViewModifier {
        let dragging: Bool

        func body(content: Content) -> some View {
            content
                .background(
                    Text(Probe.shared.label)
                        .foregroundStyle(.clear)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(ChatFieldDragMarker.identifier))
                .onChange(of: dragging) { _, now in Probe.shared.dragChanged(now) }
        }
    }
    #endif
}
