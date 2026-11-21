/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import TabMail

/// Dragging the reply field up (`ChatFieldDrag`): the field swells under the finger, only for a drag
/// that goes more up than sideways, never past its limit, and the let-go opens the panel once the
/// swell or a flick's predicted swell reaches the open distance.
@Suite("Dragging the reply field")
struct ChatFieldDragTests {
    private let open = ChatViewLayout.fieldDragOpenDistance

    @Test("The field swells by the upward distance, up to its limit")
    func swellFollowsTheFinger() {
        #expect(ChatFieldDrag.swell(translation: CGSize(width: 0, height: -30)) == 30)
        #expect(ChatFieldDrag.swell(translation: CGSize(width: 0, height: -10_000)) == ChatViewLayout.fieldDragMaxSwell)
    }

    @Test("A drag down, or one more sideways than up, does not swell the field",
          arguments: [CGSize(width: 0, height: 40), CGSize(width: 80, height: -40), CGSize(width: -80, height: -40), .zero])
    func onlyAnUpwardDragSwells(_ translation: CGSize) {
        #expect(ChatFieldDrag.swell(translation: translation) == 0)
    }

    @Test("Letting go at or past the open distance opens the panel; short of it, it settles back")
    func distanceOpens() {
        let past = CGSize(width: 0, height: -open)
        let short = CGSize(width: 0, height: -(open - 1))
        #expect(ChatFieldDrag.opens(translation: past, predictedEndTranslation: past))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: short))
    }

    @Test("A short upward flick opens; a sideways or downward flick does not")
    func flickOpens() {
        let short = CGSize(width: 0, height: -(open / 2))
        #expect(ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -open * 3)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: open * 4, height: -open * 3)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: open * 3)))
    }

    @Test("A slow drag past the open distance opens even when its predicted end falls short")
    func swellAloneOpens() {
        // The finger is 70 up; the predicted end (a slow let-go easing back) is only 40 up.
        #expect(ChatFieldDrag.opens(translation: CGSize(width: 0, height: -70),
                                    predictedEndTranslation: CGSize(width: 0, height: -40)))
    }

    @Test("A flick whose predicted swell is exactly the open distance opens; one point short does not")
    func flickBoundary() {
        let short = CGSize(width: 0, height: -(open / 2))
        #expect(ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -open)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -(open - 1))))
    }

    @Test("The drag's progress is the whole drag, sideways included, with the swell it makes")
    func progress() {
        #expect(ChatFieldDrag.progress(translation: CGSize(width: 0, height: -30)) == .init(isDragging: true, swell: 30))
        #expect(ChatFieldDrag.progress(translation: CGSize(width: 80, height: -10)) == .init(isDragging: true, swell: 0))
        #expect(ChatFieldDrag.Progress() == .init(isDragging: false, swell: 0), "at rest")
    }

    @Test("With the tip showing, the first drag still opens: the tip is inline beside the field, never a popover")
    func firstDragWithTheTipOpens() throws {
        let chat = try String(contentsOfFile: Self.root + "/TabMail/Views/Chat/ChatThreadView.swift", encoding: .utf8)
        // A popover tip takes the first touch (UIKit passthrough contract); an inline TipView in an
        // overlay above the field leaves the field's touches to the field and its drag.
        #expect(!chat.contains(".popoverTip("), "no popover tip on the field")
        #expect(chat.contains("TipView(ChatFieldDragTip(), arrowEdge: .bottom)"))
        #expect(chat.contains(".frame(height: 0)\n                    .overlay(alignment: .bottom) {\n                        ViewThatFits(in: .vertical) {\n                            TipView(ChatFieldDragTip(), arrowEdge: .bottom)"),
                "the tip hangs above the field from a zero-height anchor, pushing no layout")
        // The same drag that would open without the tip opens with it.
        let drag = CGSize(width: 0, height: -open)
        #expect(ChatFieldDrag.opens(translation: drag, predictedEndTranslation: drag))
    }

    @Test("Only a first movement more up than sideways starts the field's drag",
          arguments: [CGSize(width: 0, height: 40), CGSize(width: 80, height: -40), CGSize(width: -80, height: -40), .zero])
    func sidewaysOrDownDoesNotBegin(_ translation: CGSize) {
        #expect(!ChatFieldDrag.begins(translation: translation))
    }

    @Test("A movement up, or up and a little sideways, starts the field's drag")
    func upwardBegins() {
        #expect(ChatFieldDrag.begins(translation: CGSize(width: 0, height: -12)))
        #expect(ChatFieldDrag.begins(translation: CGSize(width: 5, height: -12)))
    }

    @Test("A let-go carries a quarter second of its speed further, SwiftUI's own drag projection")
    func predictedEnd() {
        let at = CGSize(width: 3, height: -20)
        #expect(ChatFieldDrag.predictedEnd(translation: at, velocity: .zero) == at, "held still, it rests where it is")
        // 8 and -400 points per second for a quarter second: 2 sideways, 100 up.
        #expect(ChatFieldDrag.predictedEnd(translation: at, velocity: CGSize(width: 8, height: -400)) == CGSize(width: 5, height: -120))
    }

    /// A let-go as UIKit reports it, and whether it opens the panel, worked out by hand from the
    /// open distance (60) and a quarter second of carry, not from `ChatFieldDrag.predictedEnd`.
    private struct LetGo {
        let travel: CGSize
        let velocity: CGSize
        let opens: Bool
        let why: String
    }

    private static let letGos: [LetGo] = [
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: 0, height: -90), opens: false,
              why: "30 up at 90 pt/s predicts 52.5: it settled back with SwiftUI's drag, and still does"),
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: 0, height: -119), opens: false,
              why: "predicts 59.75, just short"),
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: 0, height: -120), opens: true,
              why: "predicts exactly 60"),
        LetGo(travel: CGSize(width: 0, height: -10), velocity: CGSize(width: 0, height: -300), opens: true,
              why: "a short quick flick predicts 85"),
        LetGo(travel: CGSize(width: 0, height: -59), velocity: .zero, opens: false, why: "held still short of 60"),
        LetGo(travel: CGSize(width: 0, height: -60), velocity: .zero, opens: true, why: "held still at 60"),
        LetGo(travel: CGSize(width: 0, height: -70), velocity: CGSize(width: 0, height: 200), opens: true,
              why: "past 60 opens even when the let-go eases back (predicts 20)"),
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: -600, height: -300), opens: false,
              why: "a diagonal flick predicting 150 sideways and 105 up is more sideways than up"),
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: 300, height: -300), opens: true,
              why: "predicting 75 sideways and 105 up is more up than sideways"),
        LetGo(travel: CGSize(width: 0, height: -30), velocity: CGSize(width: 0, height: 400), opens: false,
              why: "a flick back down"),
    ]

    @Test("Let-go samples open the panel exactly where SwiftUI's drag did: 30 pt up at 90 pt/s settles back")
    func letGoOpens() {
        for letGo in Self.letGos {
            let drag = ChatHorizontalPan.Sample(travel: letGo.travel, velocity: letGo.velocity)
            #expect(ChatFieldDrag.opens(letGo: drag) == letGo.opens, "\(letGo.why)")
        }
    }

    /// A pan whose travel and speed the test sets, as UIKit reports them to the delegate and the
    /// action.
    private final class MovedPan: UIPanGestureRecognizer {
        var event: UIGestureRecognizer.State = .possible
        var travel = CGPoint.zero
        var speed = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { event }
            set { event = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { travel }
        override func velocity(in view: UIView?) -> CGPoint { speed }
    }

    // SwiftUI keeps a representable's recognizer outside the hosted view tree, so the pan is
    // checked where it is built, as `ChatSwipeTests` checks the swipes' pan.
    @Test("The field's pan cancels the touch for the views under it once it starts, and is off where the drag is")
    @MainActor
    func panCancelsTheFieldsTouch() {
        let coordinator = ChatFieldPan.Coordinator()
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true)
        #expect(pan.delegate === coordinator)
        #expect(pan.cancelsTouchesInView, "a started drag takes the touch from the text view, so it never focuses it")
        #expect(pan.isEnabled)
        #expect(!ChatFieldPan.makePan(delegate: coordinator, isEnabled: false).isEnabled, "off over the panel and in the tutorial")
    }

    @Test("The field's pan starts only on a first movement more up than sideways")
    @MainActor
    func panStartsOnlyUpward() {
        let coordinator = ChatFieldPan.Coordinator()
        let pan = MovedPan()
        pan.delegate = coordinator
        pan.travel = CGPoint(x: 0, y: -12)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
        for travel in [CGPoint(x: 12, y: -4), CGPoint(x: -12, y: 0), CGPoint(x: 0, y: 12)] {
            pan.travel = travel
            #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false, "\(travel)")
        }
    }

    // UIKit arbitrates two recognizers on a touch by asking their delegates; a unit test cannot make
    // a real touch, so it asks the pan's delegate about recognizers on a real text view.
    @Test("The text view's scroll and long presses go first; its taps wait for the drag; nothing else is ordered")
    @MainActor
    func textViewOrdering() {
        let coordinator = ChatFieldPan.Coordinator()
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true)
        let text = UITextView()
        let press = UILongPressGestureRecognizer()
        let tap = UITapGestureRecognizer()
        text.addGestureRecognizer(press)
        text.addGestureRecognizer(tap)
        let inner = UIView()
        text.addSubview(inner)
        let innerTap = UITapGestureRecognizer()
        inner.addGestureRecognizer(innerTap)

        #expect(coordinator.gestureRecognizer(pan, shouldRequireFailureOf: text.panGestureRecognizer),
                "overflowing text scrolls before the drag")
        #expect(coordinator.gestureRecognizer(pan, shouldRequireFailureOf: press), "a held press stays the text's")
        #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: tap), "a drag never ends as the text's tap")
        #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: innerTap), "a tap inside the text view too")
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: text.panGestureRecognizer),
                "the scroll never waits for the drag (that would wait both ways)")
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: press),
                "the text's long press never waits for the drag (it could not begin until the finger lifts)")
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: tap), "the drag never waits for a tap")
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: tap), "the drag runs alone")

        // Off the text view, nothing changes: the chat's scroll and other controls keep their order.
        let scroll = UIScrollView()
        let plain = UIView()
        let plainTap = UITapGestureRecognizer()
        let plainPress = UILongPressGestureRecognizer()
        plain.addGestureRecognizer(plainTap)
        plain.addGestureRecognizer(plainPress)
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: scroll.panGestureRecognizer))
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: plainPress))
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: plainTap))
    }

    @Test("The swipes' bridge hands the field both axes: a sample while it moves, and one outcome with its last sample at the let-go")
    @MainActor
    func deliveredPan() {
        let pan = MovedPan()
        var moves: [ChatHorizontalPan.Sample] = []
        var ends: [(ChatHorizontalPan.Sample, Bool)] = []
        func send(_ state: UIGestureRecognizer.State, travel: CGPoint, speed: CGPoint = .zero) {
            pan.event = state
            pan.travel = travel
            pan.speed = speed
            ChatHorizontalPan.deliver(pan, moved: { moves.append($0) }, ended: { ends.append(($0, $1)) })
        }
        send(.possible, travel: CGPoint(x: 0, y: -50))
        #expect(moves.isEmpty && ends.isEmpty, "not a drag yet")
        send(.began, travel: CGPoint(x: 1, y: -12), speed: CGPoint(x: 4, y: -90))
        send(.changed, travel: CGPoint(x: 2, y: -30))
        #expect(moves == [.init(travel: CGSize(width: 1, height: -12), velocity: CGSize(width: 4, height: -90)),
                          .init(travel: CGSize(width: 2, height: -30), velocity: .zero)])
        #expect(ends.isEmpty, "nothing ends while it moves")
        send(.ended, travel: CGPoint(x: 2, y: -40), speed: CGPoint(x: 0, y: -300))
        send(.cancelled, travel: CGPoint(x: 0, y: -70))
        send(.failed, travel: CGPoint(x: 0, y: -80))
        #expect(moves.count == 2, "an ending is never also a move")
        #expect(ends.count == 3)
        guard ends.count == 3 else { return }
        #expect(ends[0].0 == .init(travel: CGSize(width: 2, height: -40), velocity: CGSize(width: 0, height: -300)) && ends[0].1)
        #expect(ends[1].0.travel == CGSize(width: 0, height: -70) && !ends[1].1, "a cancelled drag is not finished, so it never opens")
        #expect(!ends[2].1, "nor a failed one")
    }

    @Test("The swipe reads the same bridge sideways: its travel while it moves, its sideways speed at the let-go")
    @MainActor
    func swipeReadsTheBridgeSideways() {
        let pan = MovedPan()
        var moves: [CGFloat] = []
        var ends: [(CGFloat, Bool)] = []
        pan.event = .changed
        pan.travel = CGPoint(x: -40, y: -7)
        ChatHorizontalPan.deliver(pan, changed: { moves.append($0) }, ended: { ends.append(($0, $1)) })
        pan.event = .ended
        pan.speed = CGPoint(x: -250, y: 900)
        ChatHorizontalPan.deliver(pan, changed: { moves.append($0) }, ended: { ends.append(($0, $1)) })
        #expect(moves == [-40])
        #expect(ends.count == 1)
        guard ends.count == 1 else { return }
        #expect(ends[0].0 == -250 && ends[0].1)
    }

    /// The project root: this file is TabMailTests/Views/ChatFieldDragTests.swift.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}
