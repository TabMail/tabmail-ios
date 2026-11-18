/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// What the chat's swipes act on (ADR-IOS-114 decision 12).
enum ChatSwipe {
    /// A right swipe on a bubble: "Unread from here" on a read email, "Read up to here" on
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

    /// The emails the Unread line marks after a read swipe: the ones unread once it lands.
    static func unreadIds(after action: ReadAction, targets: [MessageHeader], items: [ChatThread.Item]) -> Set<String> {
        let changed = Set(targets.map(\.id))
        return Set(items.filter { changed.contains($0.id) ? !action.isRead : !$0.header.isRead }.map(\.id))
    }

    /// Read on a collapsed chat in the inbox reads the whole chat, as opening it does.
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

    /// What one reveal does with a sideways drag that reaches it.
    enum DragOutcome: Equatable {
        /// It lets the drag go: the back swipe, or the other reveal, may take it.
        case declines
        /// It slides its content with the drag, opening it.
        case moves
        /// A reveal is open: the drag only closes it, and never goes back.
        case closes
    }

    /// The one rule for a sideways drag, from what is open and where the drag starts. `sign` is the
    /// reveal's (`sign` -1 opens leftward); `velocityX` is the drag's first sideways
    /// speed; `startsAtScreenEdge` whether it began in the back swipe's zone at the screen's left edge.
    ///  - Anything open: any drag, wherever it starts (the screen edge included), only closes it.
    ///    Every reveal under the drag answers the same, so no two of them move at once.
    ///  - Nothing open: a reveal opens toward its buttons, except that a drag from the screen's left
    ///    edge is the back swipe's, so a bubble (which opens rightward) leaves it alone.
    /// The back swipe runs only when every reveal under the drag declines (`backSwipeRuns`).
    static func dragOutcome(openId: String?, sign: CGFloat, velocityX: CGFloat,
                            startsAtScreenEdge: Bool) -> DragOutcome {
        if openId != nil { return .closes }
        guard velocityX * sign > 0 else { return .declines }
        return sign > 0 && startsAtScreenEdge ? .declines : .moves
    }

    /// Whether the back swipe takes a drag: only when every reveal under it declines.
    static func backSwipeRuns(_ outcomes: [DragOutcome]) -> Bool {
        outcomes.allSatisfy { $0 == .declines }
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

/// Slides its content to reveal buttons at `edge`. Only one reveal is open at a time:
/// `openId` names it, and while one is open any drag only closes it (`ChatSwipe.dragOutcome`). VoiceOver's actions for the
/// buttons are named by the call site, on the element they belong to: actions on a view of several
/// elements (a bubble and its chips) reorder what VoiceOver reads in it.
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
    private static let spring = Animation.spring(response: ChatViewLayout.swipeSpringResponse, dampingFraction: 0.86)

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
            // What a drag does is decided by `ChatSwipe.dragOutcome`, from what is open and where
            // the drag starts; the back swipes wait for this decision and take only declined drags.
            .gesture(ChatHorizontalPan(
                holdId: id,
                outcome: { velocityX, atEdge in
                    ChatSwipe.dragOutcome(openId: openId, sign: sign, velocityX: velocityX,
                                          startsAtScreenEdge: atEdge)
                },
                closeOpen: { openId = nil },
                changed: changed, ended: ended))
            // A swipe torn down mid-drag or while it settles lets the data it held through.
            .onDisappear { ChatSwipeHold.shared.releaseNow(id) }
            .onChange(of: openId) { _, now in
                if now != id, drag.offset != 0 { withAnimation(Self.spring) { drag.offset = 0 } }
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

/// The chat's swipes under the user-interaction freeze rule: from the moment a swipe takes the
/// finger until it has let go and settled, data that lands waits, so nothing the user is acting on
/// moves under the finger. It drives the app's one freeze, `PreviewFreezeGate`, whose readers
/// (`MessageDetailViewModel`, the sync status) keep what lands and apply it on release. Each swipe
/// holds under its reveal's id; the gate is held while any swipe holds, and only when this began
/// it (a preview that froze it first keeps it).
@MainActor
final class ChatSwipeHold {
    static let shared = ChatSwipeHold()

    private var held = Set<String>()
    /// The swipes that let go and still settle, each with its own settle's token: a settle whose
    /// token a newer begin or release replaced does nothing, and an id leaves once it settles, is
    /// taken again, or lets go at once, so nothing is kept for a swipe that is over.
    private var settling: [String: UUID] = [:]
    private var ownsGate = false

    /// Test-only: every id the hold keeps state for.
    var trackedIdsForTesting: Set<String> { held.union(settling.keys) }

    /// The swipe `id` took the finger.
    func begin(_ id: String) {
        settling[id] = nil
        guard held.insert(id).inserted, held.count == 1, !PreviewFreezeGate.shared.isFrozen else { return }
        ownsGate = true
        PreviewFreezeGate.shared.begin()
    }

    /// The swipe `id` let go: it holds while it settles, `delay`, unless it is taken again.
    func release(_ id: String, after delay: Duration) {
        guard held.contains(id) else { return }
        let token = UUID()
        settling[id] = token
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard self.settling[id] == token else { return }
            self.releaseNow(id)
        }
    }

    /// The swipe `id` holds nothing more: cancelled, settled, or its view gone.
    func releaseNow(_ id: String) {
        settling[id] = nil
        guard held.remove(id) != nil, held.isEmpty, ownsGate else { return }
        ownsGate = false
        PreviewFreezeGate.shared.end()
    }
}

/// A horizontal pan that starts only when `outcome` takes its first motion (`ChatSwipe.dragOutcome`),
/// so vertical scrolling stays the scroll view's, and the back swipes take only drags it declines.
struct ChatHorizontalPan: UIGestureRecognizerRepresentable {
    /// What the swipe holds the interaction freeze under (`ChatSwipeHold`): its reveal's id.
    let holdId: String
    /// What the drag does, from its first sideways speed and whether it starts at the screen's edge.
    let outcome: (CGFloat, Bool) -> ChatSwipe.DragOutcome
    /// Closes whatever reveal is open, for a drag whose outcome is `.closes`.
    let closeOpen: () -> Void
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
        Coordinator(outcome: outcome)
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
        context.coordinator.outcome = outcome
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if context.coordinator.current == .closes {
            if recognizer.state == .began { closeOpen() }
            return
        }
        Self.handle(recognizer, holding: holdId, changed: changed, ended: ended)
    }

    /// Every event of the swipe's pan: it holds the interaction freeze from the moment it begins
    /// until it has let go and settled (`ChatSwipeHold`), and hands the event on (`deliver`).
    @MainActor
    static func handle(_ recognizer: UIPanGestureRecognizer, holding id: String, changed: (CGFloat) -> Void,
                       ended: (CGFloat, Bool) -> Void) {
        if recognizer.state == .began { ChatSwipeHold.shared.begin(id) }
        deliver(recognizer, changed: changed, ended: ended)
        if finished(recognizer.state) != nil { ChatSwipeHold.shared.release(id, after: ChatViewLayout.swipeSettleHold) }
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
        var outcome: (CGFloat, Bool) -> ChatSwipe.DragOutcome
        /// What the drag under way does, decided once as it starts.
        private(set) var current: ChatSwipe.DragOutcome = .declines
        /// Whether the touch that starts the drag landed in the back swipe's zone at the screen's
        /// left edge.
        private(set) var startsAtScreenEdge = false

        init(outcome: @escaping (CGFloat, Bool) -> ChatSwipe.DragOutcome) {
            self.outcome = outcome
        }

        /// Where the drag starts, read from its first touch in the window's coordinates.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if recognizer.numberOfTouches == 0 {
                startsAtScreenEdge = Self.startsAtScreenEdge(touch.location(in: nil).x)
            }
            return true
        }

        static func startsAtScreenEdge(_ windowX: CGFloat) -> Bool {
            windowX <= ChatViewLayout.backSwipeEdgeWidth
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            current = .declines
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            current = outcome(velocity.x, startsAtScreenEdge)
            return current != .declines
        }

        /// A chat drag never runs together with a back swipe: the two never both act on one drag.
        /// Everything else (the chat's scroll, the other reveal) runs alongside as before.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Self.isBackSwipe(other)
        }

        /// Both back swipes wait for this drag's decision (`ChatSwipe.dragOutcome`) and take the drag
        /// only once every reveal under it has declined (`ChatSwipe.backSwipeRuns`).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.isBackSwipe(other)
        }

        /// Whether `other` is a navigation controller's back swipe, from the screen's edge or from
        /// anywhere. Read from `other` itself, which UIKit installs in its navigation controller's
        /// own views, so it holds however SwiftUI hosts this pan: the nearest navigation controller
        /// up `other`'s responder chain is the one that owns it.
        static func isBackSwipe(_ other: UIGestureRecognizer) -> Bool {
            var responder: UIResponder? = other.view
            while let current = responder {
                if let nav = current as? UINavigationController {
                    return other === nav.interactiveContentPopGestureRecognizer
                        || other === nav.interactivePopGestureRecognizer
                }
                responder = current.next
            }
            return false
        }
    }
}
