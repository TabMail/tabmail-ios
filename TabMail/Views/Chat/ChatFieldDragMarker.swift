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
/// frozen=<0|1> tip=<top>:<bottom>|none room=<top>:<bottom>|none field=<points> rise=<points>
/// dims=<n> over=<points> events=<event>,…|none`: `base` once the drag's start had the newest row's place,
/// `at` the newest row's last reported top, `held` whether the freeze was still held halfway
/// through the cooldown after the settle (`heldAtSettle`), `frozen` whether it is held now, `tip`
/// the field's drag tip's whole card while it shows (XCUITest sees only its words), `room` the space
/// it must fit in, both in the chat's space; `field` the top of the field's glass on screen, swell
/// included (the open panel's top while it is open), `rise` how far that top rose above where it
/// was at the last drag's start while the finger moved (the swell XCUITest cannot see), `dims`
/// how many taps the open panel's dim has taken, `over` how far the text under the last drag went
/// past its end while the drag moved (its scroll position as the field's pan read it; 0 if it never
/// did), and `events` what happened to the last drag, in order (`Probe.events`).
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

    /// On the field's glass, swell included (before `pill(on:)` takes the swell back out of the
    /// layout): reports its top on screen.
    struct Glass: ViewModifier {
        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    Probe.shared.glassMoved(to: $0)
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// The open panel's dim took a tap (debug builds only; nothing in release).
    @MainActor
    static func dimTapped() {
        #if DEBUG
        if Probe.isActive { Probe.shared.dims += 1 }
        #endif
    }

    /// The field's pan read the text under its drag `points` past its end (negative short of it)
    /// (debug builds only; nothing in release).
    @MainActor
    static func textPastEnd(_ points: CGFloat) {
        #if DEBUG
        if Probe.isActive { Probe.shared.textPastEnd(points) }
        #endif
    }

    /// The drag on the field ended: let go (`finished`) or cut off while the finger was still down
    /// (debug builds only; nothing in release).
    @MainActor
    static func dragEnded(finished: Bool) {
        #if DEBUG
        if Probe.isActive { Probe.shared.dragEnded(finished: finished) }
        #endif
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

        /// The field's glass top on screen now, where it was at the last drag's start, and how far
        /// it rose above that while the drag moved.
        private(set) var glassTop: CGFloat?
        private var glassRest: CGFloat?
        private(set) var rise: CGFloat = 0
        private var dragging = false
        var dims = 0
        /// How far the text under the last drag went past its end while it moved.
        private(set) var pastEnd: CGFloat = 0

        func textPastEnd(_ points: CGFloat) {
            pastEnd = max(pastEnd, points)
        }

        /// What happened to the last drag, in order: `open` when the armed opening ran under it,
        /// then `end` when it was let go or `cut` when it was cut off with the finger still down.
        private(set) var events: [String] = []
        /// Armed by the swipe fixture (`openUnderTheNextDrag`): opens the panel the moment a drag
        /// held on the field has swollen it past the open distance, then disarms.
        @ObservationIgnored private var opensUnderTheDrag: (@MainActor @Sendable () -> Void)?

        /// The next drag on the field that swells it past the open distance runs `open` while the
        /// finger is still down, as the panel opening under a held drag does.
        func openUnderTheNextDrag(_ open: @escaping @MainActor @Sendable () -> Void) {
            opensUnderTheDrag = open
        }

        func dragEnded(finished: Bool) {
            events.append(finished ? "end" : "cut")
        }

        func glassMoved(to minY: CGFloat) {
            glassTop = minY
            guard dragging, let glassRest else { return }
            rise = max(rise, glassRest - minY)
            if rise >= ChatViewLayout.fieldDragOpenDistance, let open = opensUnderTheDrag {
                opensUnderTheDrag = nil
                events.append("open")
                // After this geometry callback, not inside it.
                Task { @MainActor in open() }
            }
        }

        func newestMoved(to minY: CGFloat) {
            newestMinY = minY
            guard watching, let baseline else { return }
            largestMove = max(largestMove, abs(minY - baseline))
        }

        func dragChanged(_ dragging: Bool) {
            self.dragging = dragging
            if dragging {
                drags += 1
                watching = true
                watchToken = nil
                baseline = newestMinY
                largestMove = 0
                heldAtSettle = false
                glassRest = glassTop
                rise = 0
                pastEnd = 0
                events = []
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
            return "drags=\(drags) watching=\(watching ? 1 : 0) base=\(baseline == nil ? 0 : 1) at=\(at) move=\(move) held=\(heldAtSettle ? 1 : 0) frozen=\(PreviewFreezeGate.shared.isFrozen ? 1 : 0) tip=\(tip) room=\(room.isEmpty ? "none" : room) field=\(String(format: "%.1f", glassTop ?? -1)) rise=\(String(format: "%.1f", rise)) dims=\(dims) over=\(String(format: "%.1f", pastEnd)) events=\(events.isEmpty ? "none" : events.joined(separator: ","))"
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
