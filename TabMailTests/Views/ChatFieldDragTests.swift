/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CoreGraphics
import Foundation
import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass
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

    // UIKit's pan reports at its end the speed of the finger's last move however long the finger
    // then held still, so a drag held before the let-go must not carry that speed into the flick.
    @Test("A finger held still before it lifts lets go at rest; one lifted with its move keeps its speed")
    func heldLetGoIsAtRest() {
        let rest = ChatViewLayout.fieldFlickRest
        // 25 up at 250 pt/s predicts 87.5: a flick that opens.
        let flick = ChatHorizontalPan.Sample(travel: CGSize(width: 0, height: -25), velocity: CGSize(width: 0, height: -250))
        let atRest = ChatHorizontalPan.Sample(travel: flick.travel, velocity: .zero)
        let lifted = ChatFieldDrag.letGo(flick, rested: 0)
        let liftedSoon = ChatFieldDrag.letGo(flick, rested: rest / 2)
        let justShort = ChatFieldDrag.letGo(flick, rested: rest.nextDown)
        let heldTheRest = ChatFieldDrag.letGo(flick, rested: rest)
        let heldLong = ChatFieldDrag.letGo(flick, rested: 0.3)
        #expect(lifted == flick && ChatFieldDrag.opens(letGo: lifted), "lifted with its move, it is a flick")
        #expect(liftedSoon == flick && ChatFieldDrag.opens(letGo: liftedSoon), "lifted a few frames after its move, still a flick")
        #expect(justShort == flick, "just short of the rest, its speed is kept")
        #expect(heldTheRest == atRest, "held still the rest, it lets go at rest, its travel kept")
        #expect(heldLong == atRest && !ChatFieldDrag.opens(letGo: heldLong), "held still 0.3 s at 25 up, it settles back")
        let far = ChatHorizontalPan.Sample(travel: CGSize(width: 0, height: -70), velocity: CGSize(width: 0, height: -250))
        let farHeld = ChatFieldDrag.letGo(far, rested: 0.3)
        #expect(ChatFieldDrag.opens(letGo: farHeld), "held still past the open distance, it still opens")
        // Both axes go to rest: a drag that ends more sideways than up (80 across, 65 up), held
        // after a move back toward the middle (-160 pt/s across), would predict 40 across and 65
        // up, and open, if its sideways speed were kept.
        let sideways = ChatHorizontalPan.Sample(travel: CGSize(width: 80, height: -65), velocity: CGSize(width: -160, height: 0))
        let sidewaysHeld = ChatFieldDrag.letGo(sideways, rested: 0.3)
        #expect(ChatFieldDrag.opens(letGo: sideways), "control: lifted with that speed, it would open")
        #expect(sidewaysHeld == ChatHorizontalPan.Sample(travel: sideways.travel, velocity: .zero), "held, its travel is kept and both speeds go to rest")
        #expect(!ChatFieldDrag.opens(letGo: sidewaysHeld), "held, it ends more sideways than up and settles back")
    }

    @Test("The field's pan reads how long the finger held still before it lifted: from its last move, nothing before the lift")
    @MainActor
    func panReadsTheRest() {
        let pan = ChatFieldPan.Recognizer()
        #expect(pan.restedBeforeLift == 0, "nothing before the finger moves")
        pan.moved(at: 10)
        pan.moved(at: 10.25)
        #expect(pan.restedBeforeLift == 0, "nothing while the finger is down")
        pan.lifted(at: 10.75)
        #expect(pan.restedBeforeLift == 0.5, "from the last move, not the first")
        pan.reset()
        #expect(pan.restedBeforeLift == 0, "a new drag starts with nothing")
        pan.lifted(at: 11)
        #expect(pan.restedBeforeLift == 0, "a lift with no move read is no rest")
    }

    /// A touch at a set time, as UIKit hands each new finger to the pan's delegate.
    private final class TimedTouch: UITouch {
        var time: TimeInterval = 0
        override var timestamp: TimeInterval { time }
    }

    @Test("A second finger landing during a hold leaves it a hold: the held let-go still settles back")
    @MainActor
    func secondFingerKeepsTheRest() {
        let coordinator = ChatFieldPan.Coordinator()
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: ChatFieldPan.Cut())
        // 25 up at 250 pt/s predicts 87.5: a flick that opens when lifted with its move.
        let flick = ChatHorizontalPan.Sample(travel: CGSize(width: 0, height: -25), velocity: CGSize(width: 0, height: -250))
        pan.moved(at: 10)
        let second = TimedTouch()
        second.time = 10.2
        #expect(coordinator.gestureRecognizer(pan, shouldReceive: second), "control: the pan takes the second finger")
        pan.lifted(at: 10.25)
        let rested = pan.restedBeforeLift
        let held = ChatFieldDrag.letGo(flick, rested: rested)
        #expect(rested == 0.25, "the rest counts from the last move, not from the second finger")
        #expect(!ChatFieldDrag.opens(letGo: held), "held, it settles back")
        pan.reset()
        pan.moved(at: 20)
        pan.lifted(at: 20)
        let lifted = ChatFieldDrag.letGo(flick, rested: pan.restedBeforeLift)
        #expect(ChatFieldDrag.opens(letGo: lifted), "control: the same drag lifted with its move opens")
    }

    /// A drag that started in the focused field's text, and the field's share of it, worked out by
    /// hand: the text keeps the drag until its end, the rest of the same drag is the field's, both
    /// axes counted from the hand-off (`handOff`, the drag's travel where the text reached its end;
    /// nil while the text can still scroll). Velocities are vertical only.
    private struct Shared {
        let travel: CGSize
        let velocity: CGFloat
        let handOff: CGSize?
        let share: CGSize
        let shareVelocity: CGFloat
        let opens: Bool
        let why: String
    }

    private static let shared: [Shared] = [
        Shared(travel: CGSize(width: 0, height: -30), velocity: -90, handOff: nil,
               share: .zero, shareVelocity: 0, opens: false,
               why: "the text still had room: it took the whole drag"),
        Shared(travel: CGSize(width: 0, height: -32), velocity: -2000, handOff: nil,
               share: .zero, shareVelocity: 0, opens: false,
               why: "a fast flick inside the text, the text a sample behind the finger: still the text's"),
        Shared(travel: CGSize(width: 40, height: -30), velocity: -90, handOff: nil,
               share: .zero, shareVelocity: 0, opens: false,
               why: "sideways travel while the text scrolls is not the field's either"),
        Shared(travel: CGSize(width: 0, height: -100), velocity: 0, handOff: CGSize(width: 0, height: -40),
               share: CGSize(width: 0, height: -60), shareVelocity: 0, opens: true,
               why: "the text reached its end 40 in; the rest of the same drag, 60, opens the panel"),
        Shared(travel: CGSize(width: 0, height: -90), velocity: 0, handOff: CGSize(width: 0, height: -40),
               share: CGSize(width: 0, height: -50), shareVelocity: 0, opens: false,
               why: "50 past the end is short of the open distance"),
        Shared(travel: CGSize(width: 0, height: -60), velocity: -120, handOff: CGSize(width: 0, height: -40),
               share: CGSize(width: 0, height: -20), shareVelocity: -120, opens: false,
               why: "past the end, the flick counts: 20 + 30 = 50 predicted, short"),
        Shared(travel: CGSize(width: 0, height: -60), velocity: -400, handOff: CGSize(width: 0, height: -40),
               share: CGSize(width: 0, height: -20), shareVelocity: -400, opens: true,
               why: "past the end, a quick flick predicts 120 and opens"),
        Shared(travel: CGSize(width: 0, height: -70), velocity: -300, handOff: CGSize(width: 0, height: 0),
               share: CGSize(width: 0, height: -70), shareVelocity: -300, opens: true,
               why: "text that does not scroll (a short draft) leaves the field the whole drag"),
        Shared(travel: CGSize(width: 0, height: 20), velocity: 0, handOff: nil,
               share: .zero, shareVelocity: 0, opens: false,
               why: "a drag down scrolls the text back; nothing is the field's"),
        Shared(travel: CGSize(width: 10, height: 40), velocity: 600, handOff: nil,
               share: .zero, shareVelocity: 0, opens: false,
               why: "a fast drag down in the text: neither its travel nor its speed is the field's"),
        Shared(travel: CGSize(width: 75, height: -165), velocity: 0, handOff: CGSize(width: 75, height: -100),
               share: CGSize(width: 0, height: -65), shareVelocity: 0, opens: true,
               why: "75 sideways and 100 up reached the end; 65 straight up after it is the field's and opens"),
        Shared(travel: CGSize(width: 75, height: -155), velocity: 0, handOff: CGSize(width: 75, height: -100),
               share: CGSize(width: 0, height: -55), shareVelocity: 0, opens: false,
               why: "the same drag 55 past the end: short of the open distance"),
        Shared(travel: CGSize(width: 155, height: -140), velocity: 0, handOff: CGSize(width: 75, height: -100),
               share: CGSize(width: 80, height: -40), shareVelocity: 0, opens: false,
               why: "past the end the field's own segment, 80 sideways and 40 up, is more sideways than up"),
    ]

    @Test("In the focused field's text the text keeps the drag until its end; the rest of the same drag, both axes, is the field's")
    func fieldShareOfATextDrag() {
        for one in Self.shared {
            let drag = ChatHorizontalPan.Sample(travel: one.travel, velocity: CGSize(width: 0, height: one.velocity))
            let share = ChatFieldDrag.fieldShare(of: drag, handOff: one.handOff)
            let expected = ChatHorizontalPan.Sample(travel: one.share, velocity: CGSize(width: 0, height: one.shareVelocity))
            let opens = ChatFieldDrag.opens(letGo: share)
            #expect(share == expected, "\(one.why)")
            #expect(opens == one.opens, "\(one.why)")
        }
    }

    // The real pan's coordinator on a real text view, sample by sample, with the text's scroll
    // position set as the text's own scroll would leave it. The draft is 300 tall in a 100 box, so
    // its end is at 200; each drag starts with the text halfway (100), so the touch-down offset is
    // not zero and the text has 100 of room left.
    @Test("The pan reads the field's share from the text under the drag's first touch: from where it was then, up to its end")
    @MainActor
    func panSharesWithTheTextUnderTheTouch() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        let start = end / 2
        let room = end - start

        text.contentOffset = CGPoint(x: 0, y: start)
        coordinator.touchDown(on: inner)
        text.contentOffset = CGPoint(x: 0, y: start + room / 2)
        let inside = coordinator.share(Self.sample(0, -room / 2, speed: -900))
        #expect(inside == Self.sample(0, 0), "half its room scrolled: none of it is the field's")
        text.contentOffset = CGPoint(x: 0, y: end)
        let past = coordinator.share(Self.sample(0, -room - 70, speed: -300))
        #expect(past == Self.sample(0, -70, speed: -300),
                "70 past the end is the field's, counted from where the text reached its end")
        let opens = ChatFieldDrag.opens(letGo: past)
        #expect(opens, "and it opens the panel")
        // The overshot offset a bounce would leave is still only the text's end.
        text.contentOffset = CGPoint(x: 0, y: end + Self.overshoot)
        let overshot = coordinator.share(Self.sample(0, -room - 70, speed: -300))
        #expect(overshot == Self.sample(0, -70, speed: -300), "the text's scroll counts only up to its end")

        // A drag that starts with the text at its end: the whole drag, both axes, is the field's.
        text.contentOffset = CGPoint(x: 0, y: end)
        coordinator.touchDown(on: inner)
        let fromTheEnd = coordinator.share(Self.sample(10, -70, speed: -300))
        #expect(fromTheEnd == Self.sample(10, -70, speed: -300), "the text has no room: the drag is the field's from its start")

        coordinator.touchDown(on: UIView())
        let off = coordinator.share(Self.sample(10, -70, speed: -300))
        #expect(off == Self.sample(10, -70, speed: -300), "off the text, the whole drag is the field's")
    }

    @Test("A drag that crosses the text's end, goes back into the text and reaches the end again hands off afresh")
    @MainActor
    func handOffClearsOnAReversal() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        text.contentOffset = CGPoint(x: 0, y: end / 2)
        coordinator.touchDown(on: inner)

        // Up past the end: 30 of it is the field's.
        text.contentOffset = CGPoint(x: 0, y: end)
        let crossed = coordinator.share(Self.sample(0, -130))
        #expect(crossed == Self.sample(0, -30), "control: past the end the field has the rest")
        // Back down into the text, 80 sideways on the way: the text scrolls back 20.
        text.contentOffset = CGPoint(x: 0, y: end - 20)
        let back = coordinator.share(Self.sample(80, -80, speed: 400))
        #expect(back == Self.sample(0, 0), "the text has the drag again: nothing, no speed, is the field's")
        // Up to the end again, then 65 straight up.
        text.contentOffset = CGPoint(x: 0, y: end)
        let again = coordinator.share(Self.sample(80, -100))
        #expect(again == Self.sample(0, 0), "at the end again: the field's share starts here")
        let up = coordinator.share(Self.sample(80, -165))
        #expect(up == Self.sample(0, -65), "the sideways travel made in the text is not the field's")
        let opens = ChatFieldDrag.opens(letGo: up)
        #expect(opens, "65 straight up past the end opens the panel")
    }

    // UIKit holds a text at its end on its own value, which can read a hair under the end its sizes
    // give (UI run 2026-11-22: 0.0 shown, under 0.05 short): that text is at its end.
    @Test("A text a hair short of its computed end is at its end, at the touch and while the drag moves; a point short is not")
    @MainActor
    func textEndTolerance() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        let hair = ChatViewLayout.fieldTextEndTolerance / 2
        let nearEnd = ChatFieldPan.Coordinator.isAtEnd(end - hair, end: end)
        let pointShortEnd = ChatFieldPan.Coordinator.isAtEnd(end - 1, end: end)
        #expect(nearEnd)
        #expect(!pointShortEnd)
        let tolerance = ChatViewLayout.fieldTextEndTolerance
        let atTheTolerance = ChatFieldPan.Coordinator.isAtEnd(end - tolerance, end: end)
        let pastTheTolerance = ChatFieldPan.Coordinator.isAtEnd((end - tolerance).nextDown, end: end)
        #expect(atTheTolerance, "exactly the tolerance short is at its end")
        #expect(!pastTheTolerance, "any further short is not")

        text.contentOffset = CGPoint(x: 0, y: end - hair)
        coordinator.touchDown(on: inner)
        let fromTheEnd = coordinator.share(Self.sample(0, -70, speed: -300))
        #expect(fromTheEnd == Self.sample(0, -70, speed: -300), "a hair short at the touch: the drag is the field's from its start")

        text.contentOffset = CGPoint(x: 0, y: end / 2)
        coordinator.touchDown(on: inner)
        text.contentOffset = CGPoint(x: 0, y: end - hair)
        let crossed = coordinator.share(Self.sample(0, -130))
        #expect(crossed == Self.sample(0, -30), "held a hair short of its end, the rest of the drag is the field's")

        text.contentOffset = CGPoint(x: 0, y: end - 1)
        coordinator.touchDown(on: inner)
        let pointShort = coordinator.share(Self.sample(0, -70, speed: -300))
        #expect(pointShort == Self.sample(0, 0), "a point short, the text still has room: none of it is the field's")
    }

    // The panel opening under a held drag turned the pan off, yet the drag ran on to its let-go
    // (UI run 2026-11-22), so the chat cuts it off itself.
    @Test("The chat's cut ends a held drag as cancelled, and leaves a pan with no drag held as it is")
    @MainActor
    func cutEndsAHeldDrag() {
        let coordinator = ChatFieldPan.Coordinator()
        let cut = ChatFieldPan.Cut()
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: cut)
        #expect(cut.recognizer === pan, "the chat's cut holds this pan")
        cut()
        #expect(pan.state == .possible, "no drag held: nothing to cut")
        pan.state = .began
        pan.state = .changed
        cut()
        #expect(pan.state == .cancelled, "a held drag ends as an interrupted one")
        let other = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: cut)
        #expect(cut.recognizer === other, "a rebuilt pan takes the cut over")
        other.state = .began
        cut()
        #expect(other.state == .cancelled, "a drag cut as it begins, before it moves, ends as an interrupted one")
        let finished = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: cut)
        finished.state = .began
        finished.state = .changed
        finished.state = .ended
        cut()
        #expect(finished.state == .ended, "control: a finished drag is left as it ended")
    }

    @Test("The cut holds its pan weakly, and each chat's cut ends only its own pan's drag")
    @MainActor
    func cutIsWeakAndPerChat() {
        let coordinator = ChatFieldPan.Coordinator()
        let released = ChatFieldPan.Cut()
        autoreleasepool {
            _ = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: released)
        }
        #expect(released.recognizer == nil, "a pan SwiftUI has let go of is not kept alive by the cut")
        let first = ChatFieldPan.Cut()
        let second = ChatFieldPan.Cut()
        let firstPan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: first)
        let secondPan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: second)
        for pan in [firstPan, secondPan] {
            pan.state = .began
            pan.state = .changed
        }
        first()
        #expect(firstPan.state == .cancelled, "the first chat's held drag is cut")
        #expect(secondPan.state == .changed, "the other chat's held drag is not")
    }

    @Test("Sideways travel made while the text scrolled does not turn the field's straight pull sideways")
    @MainActor
    func diagonalThenStraightUp() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        for (pastTheEnd, opens) in [(CGFloat(65), true), (CGFloat(55), false)] {
            text.contentOffset = CGPoint(x: 0, y: end / 2)
            coordinator.touchDown(on: inner)
            // 75 sideways and 100 up, more up than sideways, scroll the text to its end.
            text.contentOffset = CGPoint(x: 0, y: end)
            let atTheEnd = coordinator.share(Self.sample(75, -100))
            #expect(atTheEnd == Self.sample(0, 0), "control: the text took the drag to its end")
            let pulled = coordinator.share(Self.sample(75, -100 - pastTheEnd))
            #expect(pulled == Self.sample(0, -pastTheEnd), "\(pastTheEnd) straight up past the end")
            let opened = ChatFieldDrag.opens(letGo: pulled)
            #expect(opened == opens, "\(pastTheEnd) past the end against the open distance")
        }
    }

    // A sample that crosses the text's end: from (20, -95), 5 short of the end, to (32, -105), the
    // finger's 10 up took the last 5 of the text's room first, so on that straight segment the text
    // reached its end at (26, -100). The field's share counts both axes from there.
    @Test("In a sample that crosses the text's end, the field's sideways share starts where the text reached it")
    @MainActor
    func handOffInsideACrossingSample() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        let start = end / 2
        // (release x, opens): 65 sideways and 62 up past the end is more sideways than up and stays
        // shut; 59 sideways and 62 up opens.
        for (x, opens) in [(CGFloat(91), false), (CGFloat(85), true)] {
            text.contentOffset = CGPoint(x: 0, y: start)
            coordinator.touchDown(on: inner)
            text.contentOffset = CGPoint(x: 0, y: start + 95)
            let before = coordinator.share(Self.sample(20, -95))
            #expect(before == Self.sample(0, 0), "control: 5 short of the end the text has the drag")
            text.contentOffset = CGPoint(x: 0, y: end)
            let crossing = coordinator.share(Self.sample(32, -105))
            #expect(crossing == Self.sample(6, -5), "the crossing sample's part past the end: 6 sideways, 5 up")
            let letGo = coordinator.share(Self.sample(x, -162))
            #expect(letGo == Self.sample(x - 26, -62), "counted from (26, -100), where the text reached its end")
            let opened = ChatFieldDrag.opens(letGo: letGo)
            #expect(opened == opens, "\(x - 26) sideways and 62 up past the end")
        }
    }

    @Test("After a reversal back into the text, the next crossing sample hands off where the text reached its end again")
    @MainActor
    func handOffInsideACrossingSampleAfterAReversal() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        let start = end / 2
        for (x, opens) in [(CGFloat(111), false), (CGFloat(105), true)] {
            text.contentOffset = CGPoint(x: 0, y: start)
            coordinator.touchDown(on: inner)
            text.contentOffset = CGPoint(x: 0, y: start + 95)
            let before = coordinator.share(Self.sample(20, -95))
            #expect(before == Self.sample(0, 0), "control: 5 short of the end the text has the drag")
            text.contentOffset = CGPoint(x: 0, y: end)
            let first = coordinator.share(Self.sample(32, -105))
            #expect(first == Self.sample(6, -5), "control: the first crossing hands off at (26, -100)")
            // Back down into the text: it scrolls back 20 and has the drag again.
            text.contentOffset = CGPoint(x: 0, y: end - 20)
            let back = coordinator.share(Self.sample(40, -80))
            #expect(back == Self.sample(0, 0), "control: back in the text, nothing is the field's")
            // Up again across the end: the finger's 40 up took the text's last 20 first, so the text
            // reached its end halfway through the sample, at (46, -100).
            text.contentOffset = CGPoint(x: 0, y: end)
            let again = coordinator.share(Self.sample(52, -120))
            #expect(again == Self.sample(6, -20), "the second crossing's part past the end: 6 sideways, 20 up")
            let letGo = coordinator.share(Self.sample(x, -162))
            #expect(letGo == Self.sample(x - 46, -62), "counted from (46, -100), the second hand-off")
            let opened = ChatFieldDrag.opens(letGo: letGo)
            #expect(opened == opens, "\(x - 46) sideways and 62 up past the end")
        }
    }

    // Up past the end, back into the text, then up across the end again: both axes of the field's
    // share count from the second crossing, never from where the touch found the text.
    @Test("After a reversal, the field's upward share counts from where the text reached its end again, not from the touch")
    @MainActor
    func upwardShareCountsFromTheSecondHandOff() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        // (release height, opens): 20 up past the second hand-off stays shut; 65 up opens.
        for (y, opens) in [(CGFloat(-165), false), (CGFloat(-210), true)] {
            text.contentOffset = CGPoint(x: 0, y: end / 2)
            coordinator.touchDown(on: inner)
            text.contentOffset = CGPoint(x: 0, y: end)
            let crossed = coordinator.share(Self.sample(0, -150))
            #expect(crossed == Self.sample(0, -50), "control: past the end the field has the rest")
            // Back down into the text, 40 sideways on the way: the text scrolls back 20.
            text.contentOffset = CGPoint(x: 0, y: end - 20)
            let back = coordinator.share(Self.sample(40, -125))
            #expect(back == Self.sample(0, 0), "control: back in the text, nothing is the field's")
            // The finger's 40 up took the text's last 20 first: the text reached its end at (46, -145).
            text.contentOffset = CGPoint(x: 0, y: end)
            let again = coordinator.share(Self.sample(52, -165))
            #expect(again == Self.sample(6, -20), "the second crossing's part past the end: 6 sideways, 20 up")
            let letGo = coordinator.share(Self.sample(52, y))
            #expect(letGo == Self.sample(6, y + 145), "counted from (46, -145), the second hand-off")
            let opened = ChatFieldDrag.opens(letGo: letGo)
            #expect(opened == opens, "\(-(y + 145)) up past the second hand-off")
        }
    }

    // The text can reach its end in a sample where the finger did not move up (its own scroll still
    // carrying it): the hand-off is that sample's end, both axes.
    @Test("A sample that reaches the text's end with no upward move hands off at its end")
    @MainActor
    func handOffWithNoUpwardMove() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        // Sideways only. (release x, opens): 62 sideways and 65 up past the hand-off opens; 70
        // sideways stays shut.
        for (x, opens) in [(CGFloat(72), true), (CGFloat(80), false)] {
            text.contentOffset = CGPoint(x: 0, y: end / 2)
            coordinator.touchDown(on: inner)
            text.contentOffset = CGPoint(x: 0, y: end - 5)
            let before = coordinator.share(Self.sample(0, -95))
            #expect(before == Self.sample(0, 0), "control: 5 short of the end the text has the drag")
            text.contentOffset = CGPoint(x: 0, y: end)
            let reached = coordinator.share(Self.sample(10, -95))
            #expect(reached == Self.sample(0, 0), "reached with a sideways move only: the field's share starts at (10, -95)")
            let letGo = coordinator.share(Self.sample(x, -160))
            #expect(letGo == Self.sample(x - 10, -65), "counted from (10, -95)")
            let opened = ChatFieldDrag.opens(letGo: letGo)
            #expect(opened == opens, "\(x - 10) sideways and 65 up past the hand-off")
        }
        // Down a little: the hand-off is still the sample's end, (10, -85), not a point found by
        // reading the downward move as an upward one. (release height, opens): 60 up past it
        // opens; 55 stays shut.
        for (y, opens) in [(CGFloat(-145), true), (CGFloat(-140), false)] {
            text.contentOffset = CGPoint(x: 0, y: end / 2)
            coordinator.touchDown(on: inner)
            text.contentOffset = CGPoint(x: 0, y: end - 5)
            let before = coordinator.share(Self.sample(0, -95))
            #expect(before == Self.sample(0, 0), "control: 5 short of the end the text has the drag")
            text.contentOffset = CGPoint(x: 0, y: end)
            let reached = coordinator.share(Self.sample(10, -85))
            #expect(reached == Self.sample(0, 0), "reached on a move down: the field's share starts at (10, -85)")
            let letGo = coordinator.share(Self.sample(10, y))
            #expect(letGo == Self.sample(0, y + 85), "counted from (10, -85)")
            let opened = ChatFieldDrag.opens(letGo: letGo)
            #expect(opened == opens, "\(-(y + 85)) up past the hand-off")
        }
    }

    @Test("While the text has the drag, up or down, the field gets no travel and no speed")
    @MainActor
    func noShareWhileTheTextHasTheDrag() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        let end = Self.textEnd
        let start = end / 2
        text.contentOffset = CGPoint(x: 0, y: start)
        coordinator.touchDown(on: inner)
        // (finger travel, speed, where the text's scroll left it)
        let drags: [(CGSize, CGFloat, CGFloat)] = [
            (CGSize(width: 0, height: -40), -2000, start + 40),
            (CGSize(width: -30, height: -20), -300, start + 20),
            (CGSize(width: 5, height: 30), 800, start - 30),
            (CGSize(width: 0, height: 60), 1500, start - 60),
        ]
        for (travel, speed, offset) in drags {
            text.contentOffset = CGPoint(x: 0, y: offset)
            let share = coordinator.share(Self.sample(travel.width, travel.height, speed: speed))
            #expect(share == Self.sample(0, 0), "\(travel) at \(speed): the text has the drag")
        }
        // Up first, then back down past the text's top in the same drag: the text stops at its top
        // with the finger 130 below where it started, and still none of it is the field's.
        text.contentOffset = CGPoint(x: 0, y: start)
        coordinator.touchDown(on: inner)
        text.contentOffset = CGPoint(x: 0, y: start + 40)
        let up = coordinator.share(Self.sample(0, -40, speed: -300))
        #expect(up == Self.sample(0, 0), "control: up inside the text's room")
        text.contentOffset = CGPoint(x: 0, y: 0)
        let pastTheTop = coordinator.share(ChatHorizontalPan.Sample(travel: CGSize(width: 5, height: 130),
                                                                    velocity: CGSize(width: 300, height: 900)))
        let none = ChatHorizontalPan.Sample(travel: .zero, velocity: .zero)
        #expect(pastTheTop == none, "past the text's top: no travel and no speed, either axis")
    }

    @Test("The text under the drag's first touch never bounces vertically")
    @MainActor
    func textUnderTheTouchDoesNotBounce() {
        let coordinator = ChatFieldPan.Coordinator()
        let (text, inner) = Self.longDraft()
        #expect(text.bouncesVertically, "control: a text view bounces by default")
        coordinator.touchDown(on: inner)
        #expect(!text.bouncesVertically, "from the touch's start, before it moves")
        text.contentOffset = CGPoint(x: 0, y: Self.textEnd)
        let during = coordinator.share(Self.sample(0, -250))
        let rest = Self.sample(0, -50)
        #expect(during == rest, "control: the drag went 50 past the text's end")
        #expect(!text.bouncesVertically, "and not turned back on during the drag")
    }

    private static func sample(_ x: CGFloat, _ y: CGFloat, speed: CGFloat = 0) -> ChatHorizontalPan.Sample {
        ChatHorizontalPan.Sample(travel: CGSize(width: x, height: y), velocity: CGSize(width: 0, height: speed))
    }

    /// A text view whose content height the test fixes, as a long draft's layout makes it.
    private final class LongText: UITextView {
        var fixedContent = CGSize.zero
        override var contentSize: CGSize {
            get { fixedContent }
            set {}
        }
    }

    /// A long draft's text view and a view inside it, where a touch lands.
    @MainActor
    private static func longDraft() -> (LongText, UIView) {
        let text = LongText(frame: CGRect(origin: .zero, size: textBox))
        text.fixedContent = textContent
        let inner = UIView()
        text.addSubview(inner)
        return (text, inner)
    }

    /// A text view's box and its longer content, where its end is, and an offset past it as a
    /// bounce would leave it.
    private static let textBox = CGSize(width: 100, height: 100)
    private static let textContent = CGSize(width: 100, height: 300)
    private static let textEnd = textContent.height - textBox.height
    private static let overshoot: CGFloat = 15

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
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: ChatFieldPan.Cut())
        #expect(pan.delegate === coordinator)
        #expect(pan.cancelsTouchesInView, "a started drag takes the touch from the text view, so it never focuses it")
        #expect(pan.isEnabled)
        #expect(!ChatFieldPan.makePan(delegate: coordinator, isEnabled: false, cut: ChatFieldPan.Cut()).isEnabled, "off over the panel and in the tutorial")
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
    @Test("The text view's long presses go first, its scroll runs beside the drag, its taps wait for the drag; nothing else is ordered")
    @MainActor
    func textViewOrdering() {
        let coordinator = ChatFieldPan.Coordinator()
        let pan = ChatFieldPan.makePan(delegate: coordinator, isEnabled: true, cut: ChatFieldPan.Cut())
        let text = UITextView()
        let press = UILongPressGestureRecognizer()
        let tap = UITapGestureRecognizer()
        text.addGestureRecognizer(press)
        text.addGestureRecognizer(tap)
        let inner = UIView()
        text.addSubview(inner)
        let innerTap = UITapGestureRecognizer()
        inner.addGestureRecognizer(innerTap)

        #expect(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: text.panGestureRecognizer),
                "overflowing text scrolls beside the drag, which gets only the field's share")
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: text.panGestureRecognizer),
                "the drag does not wait for the text's scroll: a failed drag could not take the rest past the end")
        #expect(coordinator.gestureRecognizer(pan, shouldRequireFailureOf: press), "a held press stays the text's")
        #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: tap), "a drag never ends as the text's tap")
        #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: innerTap), "a tap inside the text view too")
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: text.panGestureRecognizer),
                "the scroll never waits for the drag (that would wait both ways)")
        #expect(!coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: press),
                "the text's long press never waits for the drag (it could not begin until the finger lifts)")
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: tap), "the drag never waits for a tap")
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: tap), "the drag runs alone")
        // Only the text's own scroll runs beside the drag, not every pan inside the text view: a
        // pan on a view inside it (as a selection handle's) or a second pan on the text view itself
        // keeps the order it has without the drag.
        let handlePan = UIPanGestureRecognizer()
        inner.addGestureRecognizer(handlePan)
        let otherTextPan = UIPanGestureRecognizer()
        text.addGestureRecognizer(otherTextPan)
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: handlePan),
                "a pan inside the text that is not its scroll does not run beside the drag")
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: otherTextPan),
                "nor a pan on the text view other than its scroll")

        // Off the text view, nothing changes: the chat's scroll and other controls keep their order.
        let scroll = UIScrollView()
        let plain = UIView()
        let plainTap = UITapGestureRecognizer()
        let plainPress = UILongPressGestureRecognizer()
        plain.addGestureRecognizer(plainTap)
        plain.addGestureRecognizer(plainPress)
        #expect(!coordinator.gestureRecognizer(pan, shouldRequireFailureOf: scroll.panGestureRecognizer))
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: scroll.panGestureRecognizer),
                "the chat's own scroll never runs beside the drag")
        #expect(!coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: press), "nor the text's long press")
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
