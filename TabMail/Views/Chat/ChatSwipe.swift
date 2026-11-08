/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// What the chat's swipes act on (S1.2 to S4).
enum ChatSwipe {
    /// A right swipe on a bubble (S3.1): "Unread from here" on a read email, "Read up to here" on
    /// an unread one.
    enum ReadAction: Equatable {
        case unreadFromHere, readUpToHere

        init(for header: MessageHeader) {
            self = header.isRead ? .unreadFromHere : .readUpToHere
        }

        var title: String { self == .unreadFromHere ? "Unread from here" : "Read up to here" }
        var systemImage: String { self == .unreadFromHere ? "envelope.badge" : "envelope.open" }
        var isRead: Bool { self == .readUpToHere }
    }

    /// The emails a read swipe changes: this one and every newer one for Unread from here, never
    /// the user's own (what you wrote is not unread to you); this one and every older one for
    /// Read up to here. Only emails not already in that state.
    static func readTargets(_ action: ReadAction, at id: String, in items: [ChatThread.Item]) -> [MessageHeader] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        switch action {
        case .unreadFromHere:
            return items[index...].filter { !$0.isOwn && $0.header.isRead }.map(\.header)
        case .readUpToHere:
            return items[...index].filter { !$0.header.isRead }.map(\.header)
        }
    }

    /// The emails the Unread line marks after a read swipe (S4.1): the ones unread once it lands.
    static func unreadIds(after action: ReadAction, targets: [MessageHeader], items: [ChatThread.Item]) -> Set<String> {
        let changed = Set(targets.map(\.id))
        return Set(items.filter { changed.contains($0.id) ? !action.isRead : !$0.header.isRead }.map(\.id))
    }

    /// S1.2: Read on a collapsed chat in the inbox reads the whole chat, as opening it does.
    /// Nil means today's single-email toggle (Unread, a single email, or the chat view off).
    static func inboxReadIds(rowIsRead: Bool, memberIds: [String], collapsedThread: Bool, chatActive: Bool) -> [String]? {
        guard chatActive, collapsedThread, !rowIsRead else { return nil }
        return memberIds
    }

    /// Where a let-go swipe goes.
    enum Settle: Equatable { case closed, open, full }

    /// `offset` and `velocity` are signed along the drag; `sign` is the opening direction (-1 left).
    /// Only a finished drag acts: one the system cancelled or failed closes, whatever its offset.
    static func settle(offset: CGFloat, velocity: CGFloat, sign: CGFloat, revealWidth: CGFloat,
                       width: CGFloat, allowsFull: Bool, finished: Bool) -> Settle {
        guard finished else { return .closed }
        let distance = offset * sign
        let flick = velocity * sign
        if allowsFull, width > 0, distance > width * ChatViewLayout.swipeFullFraction { return .full }
        if flick < -ChatViewLayout.swipeFlickVelocity { return .closed }
        if distance > revealWidth / 2 || (distance > 0 && flick > ChatViewLayout.swipeFlickVelocity) { return .open }
        return .closed
    }

    /// Keeps a drag between closed and fully open (the whole width when a full swipe can run).
    static func clamp(_ proposed: CGFloat, sign: CGFloat, revealWidth: CGFloat, width: CGFloat,
                      allowsFull: Bool) -> CGFloat {
        let limit = allowsFull ? max(width, revealWidth) : revealWidth
        return min(max(proposed * sign, 0), limit) * sign
    }
}

/// One reveal's drag: where its content sits, and where it sat when the current drag began.
struct ChatSwipeDrag: Equatable {
    var offset: CGFloat = 0
    private(set) var start: CGFloat?

    /// The drag has travelled `translation` since it began; arguments as `ChatSwipe.clamp`.
    mutating func moved(_ translation: CGFloat, sign: CGFloat, revealWidth: CGFloat, width: CGFloat,
                        allowsFull: Bool) {
        let from = start ?? offset
        start = from
        offset = ChatSwipe.clamp(from + translation, sign: sign, revealWidth: revealWidth, width: width,
                                 allowsFull: allowsFull)
    }

    /// The drag let go: where it goes (`ChatSwipe.settle`). The next drag starts from wherever the
    /// content then sits.
    mutating func letGo(velocity: CGFloat, finished: Bool, sign: CGFloat, revealWidth: CGFloat,
                        width: CGFloat, allowsFull: Bool) -> ChatSwipe.Settle {
        start = nil
        return ChatSwipe.settle(offset: offset, velocity: velocity, sign: sign, revealWidth: revealWidth,
                                width: width, allowsFull: allowsFull, finished: finished)
    }
}

/// One revealed swipe button, as today's iOS 26 list swipes: a round tinted button, label below.
struct ChatSwipeButton: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var id: String { title }
}

/// Slides its content to reveal buttons at `edge` (S2, S3). Only one reveal is open at a time:
/// `openId` names it, and a drag elsewhere is ignored until it closes.
struct ChatSwipeReveal: ViewModifier {
    let id: String
    let edge: HorizontalEdge
    /// Left to right on screen. A full swipe runs the one at `edge`.
    let buttons: [ChatSwipeButton]
    let allowsFullSwipe: Bool
    @Binding var openId: String?

    @State private var drag = ChatSwipeDrag()
    @State private var width: CGFloat = 0

    private var sign: CGFloat { edge == .trailing ? -1 : 1 }
    private var revealWidth: CGFloat { CGFloat(buttons.count) * ChatViewLayout.swipeButtonWidth }
    private var edgeButton: ChatSwipeButton? { edge == .trailing ? buttons.last : buttons.first }
    private static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)

    func body(content: Content) -> some View {
        content
            .offset(x: drag.offset)
            .overlay(alignment: edge == .trailing ? .trailing : .leading) {
                if drag.offset != 0 {
                    HStack(spacing: 0) {
                        ForEach(buttons) { button in
                            buttonView(button)
                        }
                    }
                    .frame(width: abs(drag.offset), alignment: edge == .trailing ? .leading : .trailing)
                    .clipped()
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(ChatHorizontalPan(
                shouldBegin: { velocityX in openId == id || (openId == nil && velocityX * sign > 0) },
                changed: changed, ended: ended))
            .onChange(of: openId) { _, now in
                if now != id, drag.offset != 0 { withAnimation(Self.spring) { drag.offset = 0 } }
            }
            .accessibilityActions {
                ForEach(buttons) { button in
                    Button(button.title, action: button.action)
                }
            }
    }

    private func changed(_ translation: CGFloat) {
        drag.moved(translation, sign: sign, revealWidth: revealWidth, width: width, allowsFull: allowsFullSwipe)
    }

    private func ended(_ velocity: CGFloat, finished: Bool) {
        switch drag.letGo(velocity: velocity, finished: finished, sign: sign, revealWidth: revealWidth,
                          width: width, allowsFull: allowsFullSwipe) {
        case .full:
            close()
            edgeButton?.action()
        case .open:
            openId = id
            withAnimation(Self.spring) { drag.offset = sign * revealWidth }
        case .closed:
            close()
        }
    }

    private func close() {
        if openId == id { openId = nil }
        withAnimation(Self.spring) { drag.offset = 0 }
    }

    private func buttonView(_ button: ChatSwipeButton) -> some View {
        Button {
            close()
            button.action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: button.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: ChatViewLayout.swipeCircleSize, height: ChatViewLayout.swipeCircleSize)
                    .background(button.tint, in: Circle())
                Text(button.title)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: ChatViewLayout.swipeButtonWidth)
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal pan that starts only when `shouldBegin` accepts its first motion, so vertical
/// scrolling stays the scroll view's.
struct ChatHorizontalPan: UIGestureRecognizerRepresentable {
    let shouldBegin: (CGFloat) -> Bool
    let changed: (CGFloat) -> Void
    /// The drag's last velocity, and whether the user finished it (false when the system cancelled
    /// or failed it).
    let ended: (CGFloat, Bool) -> Void

    /// Whether a recognizer state ends the drag as finished (true) or interrupted (false); nil
    /// while it is still moving.
    static func finished(_ state: UIGestureRecognizer.State) -> Bool? {
        switch state {
        case .ended: true
        case .cancelled, .failed: false
        default: nil
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(shouldBegin: shouldBegin)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        Self.makePan(delegate: context.coordinator)
    }

    /// The swipe's pan, asking `delegate` before it starts so a vertical drag stays the scroll
    /// view's (`Coordinator.gestureRecognizerShouldBegin`).
    static func makePan(delegate: Coordinator) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = delegate
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        Self.deliver(recognizer, changed: changed, ended: ended)
    }

    /// Hands a pan's event on: its horizontal travel while it moves; its velocity, and whether the
    /// user finished it, once it ends.
    static func deliver(_ recognizer: UIPanGestureRecognizer, changed: (CGFloat) -> Void,
                        ended: (CGFloat, Bool) -> Void) {
        if let finished = finished(recognizer.state) {
            ended(recognizer.velocity(in: recognizer.view).x, finished)
        } else if recognizer.state == .began || recognizer.state == .changed {
            changed(recognizer.translation(in: recognizer.view).x)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (CGFloat) -> Bool

        init(shouldBegin: @escaping (CGFloat) -> Bool) {
            self.shouldBegin = shouldBegin
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) && shouldBegin(velocity.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
