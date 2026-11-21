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
/// The label reads `drags=<n> watching=<0|1> base=<0|1> at=<points> move=<points> held=<0|1>
/// frozen=<0|1> tip=<top>:<bottom>|none room=<top>:<bottom>|none`: `base` once the drag's start had the newest row's place,
/// `at` the newest row's last reported top, `held` whether the freeze was still held halfway
/// through the cooldown after the settle (`heldAtSettle`), `frozen` whether it is held now, `tip`
/// the field's drag tip's whole card while it shows (XCUITest sees only its words), `room` the space
/// it must fit in, both in the chat's space.
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
            // Attached to every row while the probe is active, so a row that stops being the
            // newest keeps its view state; only the newest one reports.
            if Probe.isActive {
                content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    if isNewest { Probe.shared.newestMoved(to: $0) }
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// On the field's drag tip: reports where its whole card is while it shows, and the room it
    /// must fit in (the header's bottom and the field stack's top), all in the chat's space
    /// (`ChatSwipeOpen.space`), so the test compares them in one space in any orientation.
    struct TipCard: ViewModifier {
        let roomTop: CGFloat
        let roomBottom: CGFloat

        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatSwipeOpen.space)) } action: {
                        Probe.shared.tipMoved(to: $0)
                    }
                    .onChange(of: [roomTop, roomBottom], initial: true) { _, room in
                        Probe.shared.tipRoom = room
                    }
                    .onDisappear { Probe.shared.tipMoved(to: nil) }
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
        /// When after a let-go the freeze is sampled: inside its hold, halfway through the cooldown
        /// that follows the field's settle.
        static var sampleAfterLetGo: Duration { ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown / 2 }
        /// How long after a let-go the move is still recorded: the settle and the cooldown, so the
        /// freeze is released by the end, twice over for margin.
        static var watchAfterLetGo: Duration { (ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown) * 2 }

        private(set) var drags = 0
        private(set) var watching = false
        private(set) var largestMove: CGFloat = 0
        /// Whether the freeze was held at `sampleAfterLetGo` after the last let-go.
        private(set) var heldAtSettle = false
        private var newestMinY: CGFloat?
        private var baseline: CGFloat?
        private var watchToken: UUID?

        /// The drag tip's card while it shows; nil while it does not (a tip TipKit no longer shows
        /// lays out empty). With the room it must fit in, top and bottom.
        private(set) var tipFrame: CGRect?
        var tipRoom: [CGFloat] = []

        func tipMoved(to frame: CGRect?) {
            tipFrame = frame.flatMap { $0.height >= 1 ? $0 : nil }
        }

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
                heldAtSettle = false
                return
            }
            let token = UUID()
            watchToken = token
            Task { @MainActor in
                try? await Task.sleep(for: Self.sampleAfterLetGo)
                guard self.watchToken == token else { return }
                self.heldAtSettle = PreviewFreezeGate.shared.isFrozen
                try? await Task.sleep(for: Self.watchAfterLetGo - Self.sampleAfterLetGo)
                guard self.watchToken == token else { return }
                self.watching = false
            }
        }

        var label: String {
            let move = String(format: "%.1f", largestMove)
            let at = String(format: "%.1f", newestMinY ?? -1)
            let tip = tipFrame.map { String(format: "%.1f:%.1f", $0.minY, $0.maxY) } ?? "none"
            let room = tipRoom.map { String(format: "%.1f", $0) }.joined(separator: ":")
            return "drags=\(drags) watching=\(watching ? 1 : 0) base=\(baseline == nil ? 0 : 1) at=\(at) move=\(move) held=\(heldAtSettle ? 1 : 0) frozen=\(PreviewFreezeGate.shared.isFrozen ? 1 : 0) tip=\(tip) room=\(room.isEmpty ? "none" : room)"
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
