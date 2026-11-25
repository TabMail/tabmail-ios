/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit
// The touch callbacks the field's pan (`ChatFieldPan.Recognizer`) overrides.
import UIKit.UIGestureRecognizerSubclass

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

    /// Whether a reveal's pan takes a sideways drag, from what is open and where the drag starts.
    /// `sign` is the reveal's opening direction (-1 leftward); `velocityX` the drag's first sideways
    /// speed; `startsAtScreenEdge` whether it began in the back swipe's zone at the screen's left edge.
    ///  - Its own reveal is open: it takes the drag either way (further open, a full swipe, or shut).
    ///  - Another is open: it lets the drag go; the chat's closer (`ChatSwipeCloser`) only closes.
    ///  - Nothing open: it opens toward its buttons, except that a rightward drag from the screen's
    ///    left edge is the back swipe's.
    static func takesDrag(id: String, openId: String?, sign: CGFloat, velocityX: CGFloat,
                          startsAtScreenEdge: Bool) -> Bool {
        if let openId { return openId == id }
        guard velocityX * sign > 0 else { return false }
        return !(sign > 0 && startsAtScreenEdge)
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

/// What is open in one chat: the one reveal whose buttons show, and where it sits. Its owner is the
/// chat screen; every reveal and the chat's closer read it. Every frame here is in the chat's own
/// coordinate space (`space`), which is the closer's anchor view's, so a touch the closer reads in
/// its anchor and a frame a reveal records are measured in the same space by construction.
@MainActor
@Observable
final class ChatSwipeOpen {
    /// The chat's coordinate space, named on the view the closer's anchor fills.
    nonisolated static let space = "chat-swipe"

    /// The open reveal's id, or nil.
    private(set) var id: String?
    /// The open reveal's frame: drags inside it stay its own.
    private(set) var frame: CGRect = .null
    /// The open reveal's buttons: taps on them stay its own.
    private(set) var buttons: CGRect = .null
    /// The band of the chat a touch can reach the reveals in: below the header, above the reply
    /// field. The header, the reply field and the navigation bar are never the open reveal's.
    private(set) var reachTop = -CGFloat.infinity
    private(set) var reachBottom = CGFloat.infinity
    /// Told whenever something opens or nothing is open any more (the chat's closer).
    @ObservationIgnored var openChanged: ((Bool) -> Void)?

    func open(_ id: String, frame: CGRect, buttons: CGRect) {
        self.id = id
        self.frame = frame
        self.buttons = buttons
        openChanged?(true)
    }

    /// The open reveal moved (a scroll, a layout change, its buttons sliding).
    func moved(_ id: String, frame: CGRect, buttons: CGRect) {
        guard self.id == id else { return }
        self.frame = frame
        self.buttons = buttons
    }

    /// Where the header ends and the reply field starts.
    func reach(top: CGFloat, bottom: CGFloat) {
        reachTop = top
        reachBottom = bottom
    }

    func close() {
        let wasOpen = id != nil
        id = nil
        frame = .null
        buttons = .null
        if wasOpen { openChanged?(false) }
    }

    /// A reveal's view left the chat (its email moved away, or the chat closed): if it was the open
    /// one, nothing is open any more, so the next drag works.
    func left(_ id: String) {
        if self.id == id { close() }
    }

    /// Whether a drag starting at `point` belongs to the open reveal (it continues it).
    func ownsDrag(_ point: CGPoint) -> Bool {
        id != nil && reaches(point) && frame.contains(point)
    }

    /// Whether a tap at `point` belongs to the open reveal: only its buttons; a tap anywhere else,
    /// its own content included, only closes it.
    func ownsTap(_ point: CGPoint) -> Bool {
        id != nil && reaches(point) && buttons.contains(point)
    }

    private func reaches(_ point: CGPoint) -> Bool {
        point.y >= reachTop && point.y < reachBottom
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
/// `open` names it; while one is open only it takes drags, and the chat's closer closes it on any
/// drag or tap elsewhere (`ChatSwipe.takesDrag`, `ChatSwipeCloser`). VoiceOver's actions for the
/// buttons are named by the call site, on the element they belong to: actions on a view of several
/// elements (a bubble and its chips) reorder what VoiceOver reads in it.
struct ChatSwipeReveal: ViewModifier {
    let id: String
    let edge: HorizontalEdge
    /// Left to right on screen. A full swipe runs the one at `edge`.
    let buttons: [ChatSwipeButton]
    let allowsFullSwipe: Bool
    let open: ChatSwipeOpen

    @State private var drag = ChatSwipeDrag()
    @State private var width: CGFloat = 0
    @State private var frame: CGRect = .null
    @State private var buttonsFrame: CGRect = .null

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
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatSwipeOpen.space)) } action: {
                        buttonsFrame = $0
                        open.moved(id, frame: frame, buttons: $0)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatSwipeOpen.space)) } action: {
                frame = $0
                open.moved(id, frame: $0, buttons: buttonsFrame)
            }
            // Whether this reveal takes a drag is decided by `ChatSwipe.takesDrag`, from what is open
            // and where the drag starts; the back swipes wait for that decision.
            .gesture(ChatHorizontalPan(
                holdId: id,
                shouldBegin: { velocityX, atEdge in
                    ChatSwipe.takesDrag(id: id, openId: open.id, sign: sign, velocityX: velocityX,
                                        startsAtScreenEdge: atEdge)
                },
                changed: changed, ended: ended))
            // A swipe torn down mid-drag or while it settles lets the data it held through, and an
            // open reveal whose view leaves the chat is no longer open.
            .onDisappear {
                ChatSwipeHold.shared.releaseNow(id)
                open.left(id)
            }
            .onChange(of: open.id) { _, now in
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
            open.open(id, frame: frame, buttons: buttonsFrame)
            withAnimation(Self.spring) { drag.offset = sign * revealWidth }
        case .closed:
            close()
        }
    }

    private func close() {
        open.left(id)
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

/// A horizontal pan that starts only when `shouldBegin` takes its first motion (`ChatSwipe.takesDrag`),
/// so vertical scrolling stays the scroll view's, and the back swipes take only drags it declines.
struct ChatHorizontalPan: UIGestureRecognizerRepresentable {
    /// What the swipe holds the interaction freeze under (`ChatSwipeHold`): its reveal's id.
    let holdId: String
    /// Whether the pan takes the drag, from its first sideways speed and whether it starts at the
    /// screen's left edge.
    let shouldBegin: (CGFloat, Bool) -> Bool
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
    /// view's (`Coordinator.gestureRecognizerShouldBegin`). It takes a trackpad's two-finger swipe
    /// and a mouse's scroll wheel as well as a finger's drag, as the inbox's list swipes do: a
    /// UIKit pan takes no scrolls unless told to.
    static func makePan(delegate: any UIGestureRecognizerDelegate) -> UIPanGestureRecognizer {
        let pan = Recognizer()
        pan.delegate = delegate
        pan.allowedScrollTypesMask = .all
        return pan
    }

    /// The swipe's pan. UIKit resets it once each drag, tap or scroll is over; it then forgets
    /// where its last touch came down (`Coordinator.gestureEnded`), so a later scroll, which has no
    /// touch, never reads an earlier touch's start at the screen's edge.
    final class Recognizer: UIPanGestureRecognizer {
        override func reset() {
            super.reset()
            (delegate as? Coordinator)?.gestureEnded()
        }
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
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

    /// The swipe's reading of a pan's event (`deliver(_:moved:ended:)`): its horizontal travel
    /// while it moves; its horizontal velocity, and whether the user finished it, once it ends.
    static func deliver(_ recognizer: UIPanGestureRecognizer, changed: (CGFloat) -> Void,
                        ended: (CGFloat, Bool) -> Void) {
        deliver(recognizer, moved: { changed($0.travel.width) }, ended: { ended($0.velocity.width, $1) })
    }

    /// One reading of a pan, both axes, in its own view: its travel since it began and its velocity
    /// (points per second).
    struct Sample: Equatable {
        var travel: CGSize
        var velocity: CGSize
    }

    /// The pan's reading now.
    static func sample(_ recognizer: UIPanGestureRecognizer) -> Sample {
        let travel = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        return Sample(travel: CGSize(width: travel.x, height: travel.y),
                      velocity: CGSize(width: velocity.x, height: velocity.y))
    }

    /// Hands a pan's event on, for every pan the chat builds here (the swipes, the reply field's
    /// drag up, `ChatFieldPan`): its sample while it moves; once it ends, its last sample and one
    /// outcome, whether the user finished it (`finished`). What a pan does with them is its caller's.
    static func deliver(_ recognizer: UIPanGestureRecognizer, moved: (Sample) -> Void,
                        ended: (Sample, Bool) -> Void) {
        if let finished = finished(recognizer.state) {
            ended(sample(recognizer), finished)
        } else if recognizer.state == .began || recognizer.state == .changed {
            moved(sample(recognizer))
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (CGFloat, Bool) -> Bool
        /// Whether the touch that starts the drag landed in the back swipe's zone at the screen's
        /// left edge.
        private(set) var startsAtScreenEdge = false

        init(shouldBegin: @escaping (CGFloat, Bool) -> Bool) {
            self.shouldBegin = shouldBegin
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

        /// The drag, tap or scroll is over (`Recognizer.reset`): the next one starts with no edge
        /// start until its own first touch says so, and a scroll has none. The touch count cannot
        /// tell a scroll from a drag: UIKit can decide a quick drag's start once its touch has lifted
        /// (swipe UI run 2026-11-25: the edge drags stopped going back).
        func gestureEnded() {
            startsAtScreenEdge = false
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) && shouldBegin(velocity.x, startsAtScreenEdge)
        }

        /// A swipe runs alone: once it has the drag, nothing else acts on it (a back swipe, the
        /// scroll, or the bubble's own tap, which would open its card under the swipe).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        /// Both back swipes wait for this pan's decision (`ChatSwipe.takesDrag`): they take the drag
        /// only once it has declined.
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

/// The drag up on the chat's collapsed reply field (`ChatFieldDrag`): the swipes' pan bridge
/// (`ChatHorizontalPan`), vertical. It starts only on a first movement more up than sideways
/// (`ChatFieldDrag.begins`), so a sideways drag stays a swipe or the back swipe. Once it starts it
/// cancels the touch for the views under it (`cancelsTouchesInView`), so the field's text view
/// never takes the let-go as a tap and takes focus; a tap does not move, never starts it, and
/// focuses the field as before. In the focused field's overflowing text it runs alongside the
/// text's scroll and hands on only the field's share of the drag (`Coordinator.share`): none until
/// the text first reaches its end, the rest of the same drag from there (mock v15 H2), and none
/// again once the finger takes the drag back into the text. That text never bounces vertically (`Coordinator.touchDown`), so past its end it stays
/// at its end while the field swells.
struct ChatFieldPan: UIGestureRecognizerRepresentable {
    /// Off over the open panel and in the tutorial, so no new drag starts there. UIKit cancels an
    /// active pan once it is actually turned off, but in a UI run the update turning it off did not
    /// end a drag already held, so the panel opening cuts that drag with `cut`.
    let isEnabled: Bool
    /// Cuts the drag held on the field off (`Cut`): the chat calls it when the panel opens.
    let cut: Cut
    /// The drag's travel since it began (`ChatHorizontalPan.Sample`).
    let moved: (ChatHorizontalPan.Sample) -> Void
    /// The drag's travel and its velocity at the let-go, and whether the user finished it (false
    /// when the system cancelled or failed it, or the chat cut it off).
    let ended: (ChatHorizontalPan.Sample, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        Self.makePan(delegate: context.coordinator, isEnabled: isEnabled, cut: cut)
    }

    /// The field's pan (`Recognizer`) asking `delegate`, as the swipes' pan does
    /// (`ChatHorizontalPan.makePan`), cancelling the touch for the views under it once it starts
    /// (UIKit's default, stated because the field's focus depends on it). `cut` cuts its drags off.
    static func makePan(delegate: Coordinator, isEnabled: Bool, cut: Cut) -> Recognizer {
        let pan = Recognizer()
        pan.delegate = delegate
        pan.cancelsTouchesInView = true
        pan.isEnabled = isEnabled
        cut.recognizer = pan
        return pan
    }

    /// Cuts the drag held on the field off, as the system cancelling it (`Recognizer.cut`): it
    /// ends as an interrupted drag, springs back and opens nothing. The panel opening under a held
    /// drag (an agent's answer, the inbox's agent toast) turns the pan off, yet the drag ran on to
    /// its let-go with the swell held (UI run 2026-11-22: the opening was requested, then the drag
    /// ended, never cut), so the chat cuts it itself when the panel opens. One per chat; it holds the
    /// pan weakly.
    @MainActor
    final class Cut {
        fileprivate(set) weak var recognizer: Recognizer?

        func callAsFunction() {
            recognizer?.cut()
        }
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        // Debug UI tests only: the pan turned on or off, and its state then (`ChatFieldDragMarker`).
        ChatFieldDragMarker.panEnabling(recognizer, to: isEnabled)
        recognizer.isEnabled = isEnabled
    }

    /// The swipes' delivery (`ChatHorizontalPan.deliver`), both axes, each sample the field's
    /// share of the drag (`Coordinator.share`); the let-go at rest when the finger held still
    /// before it lifted (`ChatFieldDrag.letGo`).
    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        let coordinator = context.coordinator
        ChatHorizontalPan.deliver(recognizer, moved: { moved(coordinator.share($0)) },
                                  ended: {
            coordinator.letGo()
            ended(coordinator.share(ChatFieldDrag.letGo($0, rested: recognizer.restedBeforeLift), atLetGo: true), $1)
        })
    }

    /// UIKit's pan, noting when its finger last moved and when it lifted, on the touches' own
    /// clock: UIKit reports at the let-go the speed of the finger's last move however long it then
    /// held still, so the let-go reads how long it rested (`restedBeforeLift`).
    final class Recognizer: UIPanGestureRecognizer {
        private var lastMove: TimeInterval?
        private var lift: TimeInterval?

        /// How long the finger held still before it lifted; zero until it has lifted.
        var restedBeforeLift: TimeInterval {
            guard let lastMove, let lift else { return 0 }
            return max(0, lift - lastMove)
        }

        /// The finger moved at `time`. A touch coming down is not a move: a pan only begins once
        /// the finger moved, and a second finger landing during a hold leaves the hold a hold.
        func moved(at time: TimeInterval) {
            lastMove = time
        }

        /// The finger lifted at `time`.
        func lifted(at time: TimeInterval) {
            lift = time
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            moved(at: event.timestamp)
            super.touchesMoved(touches, with: event)
        }

        // Before UIKit ends the pan, so its let-go reads the lift.
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            lifted(at: event.timestamp)
            super.touchesEnded(touches, with: event)
        }

        override func reset() {
            super.reset()
            lastMove = nil
            lift = nil
        }

        /// Cuts the drag in progress off while the finger is still down, as the system cancelling
        /// it; a pan with no drag in progress is left as it is.
        func cut() {
            guard state == .began || state == .changed else { return }
            state = .cancelled
        }

        #if DEBUG
        // Debug UI tests only: the pan was cancelled (`ChatFieldDragMarker`; reads the new state
        // only in a debug build the swipe UI tests launch).
        override var state: UIGestureRecognizer.State {
            didSet { ChatFieldDragMarker.panState(from: oldValue, to: state) }
        }
        #endif
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Only a first movement more up than sideways starts the drag.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return ChatFieldDrag.begins(translation: ChatHorizontalPan.sample(pan).travel)
        }

        /// The drag runs alone, as a swipe does, except beside the field's own text scroll (only
        /// while its text overflows the field's six lines): both follow the finger, and the drag
        /// hands on only the field's share (`share`), so the text keeps the drag until its end.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            Self.isTextViews(other) && ChatSwipeCloser.Coordinator.isScroll(other)
        }

        /// The field's text view's long presses go first (caret placement, the loupe, selection):
        /// the drag starts only once they have declined, so a press held before moving stays the
        /// text's.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            Self.isTextViews(other) && other is UILongPressGestureRecognizer
        }

        /// The text the drag's first touch landed in, and the drag's travel, both axes, where the
        /// text last reached its end (nil until it does, and again once the text reads short of its
        /// end after the finger came back down, `share`): the field's share counts from that one
        /// point. The drag's highest travel
        /// since then, and the farthest the finger has come back down from it. The previous
        /// sample's travel and the text's place then, to find where in the next sample the text
        /// reached its end.
        private weak var text: UIScrollView?
        private var handOff: CGSize?
        private var highest: CGFloat = 0
        private var farthestDown: CGFloat = 0
        private var lastTravel = CGSize.zero
        private var lastOffset: CGFloat = 0

        /// Notes the text under a new drag's first touch.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if recognizer.numberOfTouches == 0 { touchDown(on: touch.view) }
            return true
        }

        /// A new drag's first touch landed on `view`: the text around it, if any, and its scroll
        /// position now. That text stops bouncing vertically here, before the touch has moved, and
        /// never bounces again: past its end the rest of the drag is the field's, and the text holds
        /// still at its end while the field swells (mock v15 H2). Its own scroll, caret and
        /// selection are unchanged.
        func touchDown(on view: UIView?) {
            text = Self.scrollingText(around: view)
            text?.bouncesVertically = false
            lastTravel = .zero
            highest = 0
            farthestDown = 0
            lastOffset = text?.contentOffset.y ?? 0
            // A drag that starts with the text at its end is the field's from its start.
            let end = text.map { Self.end(of: $0) }
            if let text, let end, Self.isAtEnd(text.contentOffset.y, end: end) {
                handOff = .zero
            } else {
                handOff = nil
            }
            // Debug UI tests only: the hand-off record starts (`ChatFieldDragMarker`).
            ChatFieldDragMarker.textTouchDown(end: end, handedOff: handOff != nil)
        }

        /// The field's share of `drag` (`ChatFieldDrag.fieldShare`): the drag's travel, both axes,
        /// from the point where the text under it reached its end; none while the text still has
        /// the drag (before it first reaches its end, and after the finger brings it back). The
        /// hand-off is found in the first sample with the text at its end, at the point of that
        /// sample where the text reached it (`crossing`), and dropped when the text reads short of
        /// its end once the finger has come back down (`fingerCameBack`), so a drag that reverses
        /// into the text and reaches the end again hands off afresh. That is read from how far the
        /// finger came down since the hand-off, not from the sample's direction nor from how far
        /// short the text reads: the text's own scroll and this pan run side by side, and UIKit
        /// does not say which hears a move first, so the text can show a downward move one sample
        /// late, with the finger already going up again, or only at the let-go, and can show its
        /// end in the sample the finger turned down in. A text short of its end with the finger not
        /// come down moved without it, and keeps the hand-off with the rest of the drag the field's:
        /// seen in a UI run (2026-11-22), UIKit scrolled the field's text to its caret on a layout
        /// after the field was built again while the finger was down. Once the finger has come
        /// down, a text short of its end drops the hand-off whatever moved it. Off the text, all of
        /// it. `atLetGo`: the let-go's sample (for the debug marker).
        func share(_ drag: ChatHorizontalPan.Sample, atLetGo: Bool = false) -> ChatHorizontalPan.Sample {
            guard let text else { return drag }
            let end = Self.end(of: text)
            let offset = text.contentOffset.y
            let wasHandedOff = handOff != nil
            if handOff != nil {
                highest = min(highest, drag.travel.height)
                farthestDown = max(farthestDown, drag.travel.height - highest)
            }
            if !Self.isAtEnd(offset, end: end) {
                if handOff != nil, Self.fingerCameBack(down: farthestDown) {
                    handOff = nil
                }
            } else if handOff == nil {
                handOff = Self.crossing(from: lastTravel, textAt: lastOffset, to: drag.travel, end: end)
                // A text read a sample late shows its end in the sample the finger turned down in:
                // that move down counts, from the sample before.
                highest = min(lastTravel.height, drag.travel.height)
                farthestDown = drag.travel.height - highest
            }
            lastTravel = drag.travel
            lastOffset = min(offset, end)
            let shared = ChatFieldDrag.fieldShare(of: drag, handOff: handOff)
            // Debug UI tests only: how far the text went past its end, and the hand-off as the pan
            // read it (`ChatFieldDragMarker`).
            ChatFieldDragMarker.textPastEnd(offset - end)
            ChatFieldDragMarker.textShared(end: end, offset: offset, handOff: wasHandedOff ? nil : handOff?.height,
                                           share: shared.travel.height, atLetGo: atLetGo)
            return shared
        }

        /// The drag let go or was cut off, before the view hears of it: the drag marker watches the
        /// text under it from here (debug UI tests only; nothing in release).
        func letGo() {
            ChatFieldDragMarker.textLetGo(text, lastMoved: lastOffset)
        }

        /// The drag's travel, both axes, where the text reached its end, within the sample that went
        /// from `last` (the text then at `textAt`) to `travel`: the finger's upward move in that
        /// sample took the text's remaining room first, so the hand-off is that room further up
        /// than `last`, and the sideways travel is taken at the same point of the move. Neither
        /// axis of the field's share then counts travel the text had. The text's place cannot tell
        /// where in the sample the finger was, since the text holds still at its end; the finger's
        /// travel can. A sample with no upward move hands off at its end.
        static func crossing(from last: CGSize, textAt: CGFloat, to travel: CGSize, end: CGFloat) -> CGSize {
            let up = last.height - travel.height
            guard up > 0 else { return travel }
            let room = min(up, max(0, end - textAt))
            return CGSize(width: last.width + (travel.width - last.width) * (room / up),
                          height: last.height - room)
        }

        /// Whether the finger came back down from a handed-off text's end: `down`, the farthest it
        /// came down from its highest point since the hand-off (the sample before it too, when the
        /// text first read its end on a move down), is more than
        /// `ChatViewLayout.fieldTextReversalSlack`. The rule takes the text's own scroll to follow
        /// the finger point for point while the finger drags it: a finger that came down is taken
        /// to have brought the text back with it, whenever the text shows it, and a text that reads
        /// short with the finger not come down is taken to have moved on its own (a caret scroll),
        /// which keeps the hand-off. The farthest, not where the
        /// finger is now: a text read a sample late shows where the finger was, which may be lower
        /// than now.
        static func fingerCameBack(down: CGFloat) -> Bool {
            down > ChatViewLayout.fieldTextReversalSlack
        }

        /// Whether the text at scroll position `offset` is at its `end`: within
        /// `ChatViewLayout.fieldTextEndTolerance` of it, since a text UIKit holds at its end can
        /// read a hair short of the end its sizes give.
        static func isAtEnd(_ offset: CGFloat, end: CGFloat) -> Bool {
            offset >= end - ChatViewLayout.fieldTextEndTolerance
        }

        /// The scroll position at which `text` shows its end (its top when it does not scroll).
        static func end(of text: UIScrollView) -> CGFloat {
            max(text.contentSize.height + text.adjustedContentInset.bottom - text.bounds.height,
                -text.adjustedContentInset.top)
        }

        /// The scrolling text view (`UITextInput`) that `view` is or sits in.
        static func scrollingText(around view: UIView?) -> UIScrollView? {
            var view = view
            while let current = view {
                if let scroll = current as? UIScrollView, current is UITextInput { return scroll }
                view = current.superview
            }
            return nil
        }

        /// The text view's taps wait for the drag's decision, so a drag never ends as a tap that
        /// focuses the field; a tap never starts the drag, so it focuses the field at once.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.isTextViews(other) && other is UITapGestureRecognizer
        }

        /// Whether `other` belongs to a text view (`UITextInput`): installed on it or on a view
        /// inside it.
        static func isTextViews(_ other: UIGestureRecognizer) -> Bool {
            var view = other.view
            while let current = view {
                if current is UITextInput { return true }
                view = current.superview
            }
            return false
        }
    }
}

/// The chat's closer: while a reveal is open, any drag or tap anywhere on the chat's screen outside
/// that reveal (another bubble, empty space, the reply field, the header, the navigation bar, the
/// screen's edge), and a vertical drag anywhere, closes it, as in Mail. It is a pair of recognizers
/// on the navigation controller's own view, not a view over the chat, so VoiceOver and every control
/// see the chat as before; they take no touch at all while nothing is open. The screen's own
/// recognizers on such a touch wait for them, so a sideways drag or a tap does nothing else; a
/// vertical drag also scrolls the chat (the scroll views' pans run alongside), and the window's own
/// recognizers, the keyboard-dismiss tap among them, run alongside too, so a closing tap also drops
/// the keyboard. The screen-edge back swipe is a system recognizer that starts on its own, so it is
/// off while something is open, and on again once nothing is.
struct ChatSwipeCloser: UIViewRepresentable {
    let open: ChatSwipeOpen
    /// What the closing drag holds the interaction freeze under (`ChatSwipeHold`).
    static let holdId = "chat-swipe-closer"

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {}

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    /// An empty view that installs the closer on its navigation controller once it is on screen.
    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            if window == nil {
                coordinator.uninstall()
                return
            }
            var responder: UIResponder? = self
            while let current = responder, !(current is UINavigationController) { responder = current.next }
            guard let nav = responder as? UINavigationController else { return }
            coordinator.install(on: nav.view, anchor: self, edgePop: nav.interactivePopGestureRecognizer)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let open: ChatSwipeOpen
        let pan = UIPanGestureRecognizer()
        let tap = UITapGestureRecognizer()
        private weak var host: UIView?
        /// The view filling the chat's coordinate space (`ChatSwipeOpen.space`): touches are read in it.
        private(set) weak var anchor: UIView?
        /// The navigation controller's screen-edge back swipe, off while something is open.
        private weak var edgePop: UIGestureRecognizer?

        init(open: ChatSwipeOpen) {
            self.open = open
            super.init()
            open.openChanged = { [weak self] isOpen in self?.openChanged(isOpen) }
            for recognizer in [pan, tap] as [UIGestureRecognizer] {
                recognizer.delegate = self
                recognizer.addTarget(self, action: #selector(handle(_:)))
            }
            takesScrolls(open.id != nil)
        }

        /// Something opened, or nothing is open any more: the screen-edge back swipe is off while
        /// something is open, and the closing pan takes scrolls only then.
        private func openChanged(_ isOpen: Bool) {
            setEdgePop(enabled: !isOpen)
            takesScrolls(isOpen)
        }

        /// While something is open, a trackpad's two-finger swipe or a scroll wheel elsewhere closes
        /// it as a drag does (the swipes take scrolls, `ChatHorizontalPan.makePan`). With nothing open
        /// the pan takes none, as it takes no touch then (`shouldReceive`), so no swipe ever waits for
        /// it to decline a scroll.
        private func takesScrolls(_ takes: Bool) {
            pan.allowedScrollTypesMask = takes ? .all : []
        }

        func install(on view: UIView, anchor: UIView, edgePop: UIGestureRecognizer?) {
            self.anchor = anchor
            guard host !== view else { return }
            uninstall()
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(tap)
            host = view
            self.edgePop = edgePop
            edgePop?.isEnabled = open.id == nil
            // Debug UI tests only: the back swipe's states and transition while this closer holds
            // it (`ChatFieldDragMarker`).
            ChatFieldDragMarker.watchPop(edgePop, owner: self)
        }

        func setEdgePop(enabled: Bool) {
            edgePop?.isEnabled = enabled
        }

        /// Torn down, even mid-drag: the closer holds nothing more.
        func uninstall() {
            // Debug UI tests only: the back swipe's watch ends with this closer's hold on it.
            ChatFieldDragMarker.unwatchPop(owner: self)
            host?.removeGestureRecognizer(pan)
            host?.removeGestureRecognizer(tap)
            host = nil
            edgePop?.isEnabled = true
            edgePop = nil
            ChatSwipeHold.shared.releaseNow(ChatSwipeCloser.holdId)
        }

        /// A touch is the closer's only while something is open; a tap only where it is not on the
        /// open reveal's buttons, which run. Whether a drag is the closer's is decided once it moves
        /// (`closes(velocity:startsOnTheOpenReveal:)`). Read in the anchor, the space every reveal's
        /// frame is measured in.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard open.id != nil else { return false }
            guard recognizer === tap else { return true }
            return !open.ownsTap(touch.location(in: anchor))
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard open.id != nil else { return false }
            guard recognizer === pan else { return true }
            let location = pan.location(in: anchor)
            let translation = pan.translation(in: anchor)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            return Self.closes(velocity: pan.velocity(in: anchor), startsOnTheOpenReveal: open.ownsDrag(start))
        }

        /// Whether a drag closes what is open: any drag that starts off the open reveal, and a
        /// vertical one anywhere. A sideways drag on the open reveal is its own (it continues it).
        static func closes(velocity: CGPoint, startsOnTheOpenReveal: Bool) -> Bool {
            !startsOnTheOpenReveal || abs(velocity.y) >= abs(velocity.x)
        }

        /// The screen's recognizers on a touch the closer took wait for it, so a sideways drag or a
        /// tap only closes: the bubbles' taps and swipes, the reply field, the bar's buttons and both
        /// back swipes. Two exceptions run alongside it instead (`shouldRecognizeSimultaneouslyWith`):
        /// a scroll view's pan, so a vertical drag also scrolls, and the window's own recognizers.
        /// A reveal's pan never waits for the closer's tap: a tap tolerates a short move, so waiting
        /// would let a short sideways drag on the open reveal end as a closing tap. The pan takes only
        /// its open reveal's drags (`ChatSwipe.takesDrag`); the closer's pan still decides the rest.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other !== pan, other !== tap, Self.isTheScreens(other) else { return false }
            if recognizer === tap && Self.isRevealPan(other) { return false }
            return !(recognizer === pan && Self.isScroll(other))
        }

        /// Whether `other` is a reveal's swipe pan (`ChatHorizontalPan`).
        static func isRevealPan(_ other: UIGestureRecognizer) -> Bool {
            other.delegate is ChatHorizontalPan.Coordinator
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Self.isTheScreens(other) || (recognizer === pan && Self.isScroll(other))
        }

        /// Whether `other` is one of the screen's recognizers, not one the window itself holds. The
        /// window's are app-wide: the keyboard-dismiss tap (`dismissKeyboardOnTap`), which must still
        /// drop the keyboard on a closing tap, and the system's own.
        static func isTheScreens(_ other: UIGestureRecognizer) -> Bool {
            !(other.view is UIWindow)
        }

        /// Whether `other` is a scroll view's own pan (the chat's, or a text view's).
        static func isScroll(_ other: UIGestureRecognizer) -> Bool {
            (other.view as? UIScrollView)?.panGestureRecognizer === other
        }

        /// Closes what is open, holding the interaction freeze from the moment the closer takes the
        /// finger until the reveal has settled shut, as every swipe does (`ChatSwipeHold`).
        @objc func handle(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began:
                ChatSwipeHold.shared.begin(ChatSwipeCloser.holdId)
                open.close()
            case .ended where recognizer is UITapGestureRecognizer:
                ChatSwipeHold.shared.begin(ChatSwipeCloser.holdId)
                open.close()
                ChatSwipeHold.shared.release(ChatSwipeCloser.holdId, after: ChatViewLayout.swipeSettleHold)
            case .ended, .cancelled, .failed:
                ChatSwipeHold.shared.release(ChatSwipeCloser.holdId, after: ChatViewLayout.swipeSettleHold)
            default:
                break
            }
        }
    }
}
