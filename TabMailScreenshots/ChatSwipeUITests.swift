/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

/// Real drags on a real chat (ADR-IOS-114 decision 12), as Mail does it:
///  - A rightward drag that starts on a bubble never goes back.
///  - With nothing open, a drag from the screen's left edge goes back.
///  - While a bubble's actions or the chat's buttons are open, only that reveal takes sideways
///    drags; any drag or tap anywhere else (another bubble, the reply field, the header, the
///    screen's edge) only closes it, and the next drag goes back. A vertical drag both scrolls the
///    chat and closes it, and a closing tap also drops the keyboard.
///  - Under the header, the reply field and the navigation bar nothing is the open reveal's, and a
///    tap on a bubble while something is open only closes; the open bubble's own buttons still work,
///    also in a chat opened inside a presented sheet or, as from a mailbox, from a collapsed split
///    view.
///  - A bubble whose actions were open and whose email then leaves the chat leaves nothing open.
///  - The header is the subject AND the tutorial's coach card under it: a drag or tap on the card
///    only closes the chat's buttons, and once the card goes the chat under where it sat is the
///    reveal's again.
/// "Went back" is read from the screen: the fixture's list shows again and the chat is gone.
@MainActor
final class ChatSwipeUITests: XCTestCase {
    // MARK: - The four open states, a rightward drag on a bubble

    func testNothingOpenRightDragOnABubbleOpensItAndStays() {
        let app = launchIntoChat()
        dragRight(on: bubble(2, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(bubbleActionsShow(app), "the bubble's actions show")
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "the swipe opened no card")
    }

    func testOwnActionsOpenRightDragStaysInTheChat() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragRight(on: bubble(2, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(bubbleActionsShow(app), "the open bubble followed the drag and stays open")
    }

    func testOwnActionsOpenShortDragBackStaysOpen() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        // Less than half the buttons back: only the bubble's own swipe can leave it open (the
        // closer always closes).
        let dy = bubble(2, in: app).frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: dy)))
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(bubbleActionsShow(app), "the actions stay open")
    }

    func testOpenActionsOwnButtonStillWorks() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        app.buttons["Move"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForExistence(timeout: 5), "the open bubble's Move runs")
    }

    func testOtherBubbleOpenRightDragOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragRight(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the open actions closed, and no other opened")
    }

    func testChatButtonsOpenRightDragOnABubbleOnlyCloses() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        dragRight(on: bubble(2, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the chat's buttons closed")
        XCTAssertFalse(app.buttons["Move"].exists, "and no bubble opened")
    }

    func testChatButtonsOpenTapOnABubbleOnlyCloses() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        tap(atY: bubble(2, in: app).frame.midY, dx: 0.2, in: app)
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the chat's buttons closed")
        XCTAssertFalse(app.buttons["Sheet Grabber"].waitForExistence(timeout: 2), "the tap opened no card")
    }

    // MARK: - The screen's edge

    func testNothingOpenEdgeDragGoesBack() {
        let app = launchIntoChat()
        dragFromEdge(atY: bubble(2, in: app).frame.midY, in: app)
        XCTAssertTrue(wentBack(app), "an edge drag with nothing open goes back")
    }

    func testOpenActionsFirstEdgeDragClosesThenTheNextGoesBack() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        let y = bubble(3, in: app).frame.midY
        dragFromEdge(atY: y, in: app)
        XCTAssertTrue(isInChat(app), "the first drag stays in the chat")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
        dragFromEdge(atY: y, in: app)
        XCTAssertTrue(wentBack(app), "the next drag goes back")
    }

    // MARK: - The reply field and the header

    func testOpenActionsDragOnTheReplyFieldOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        XCTAssertGreaterThan(field.frame.midY, bubble(3, in: app).frame.maxY, "control: below the newest bubble")
        dragRight(atY: field.frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
    }

    func testDragUpOnTheReplyFieldOpensTheChatPanel() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the panel is closed")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "the drag opened the TabMail chat panel")
        XCTAssertTrue(isInChat(app), "the chat stays")
    }

    /// Memory 129: a control at the bottom safe-area bar can exist yet swallow nothing, or take
    /// nothing, so the opened panel is tapped, not only found: Close closes it, and so does the dim
    /// above it.
    func testDraggedOpenPanelClosesOnCloseAndOnTheDim() throws {
        let app = launchIntoChat()
        dragFieldOpen(in: app)
        app.buttons["chatClose"].tap()
        XCTAssertTrue(app.buttons["chatClose"].waitForNonExistence(timeout: 3), "Close closed the panel")
        XCTAssertTrue(replyField(in: app).isHittable, "the collapsed field is back")

        dragFieldOpen(in: app)
        let close = app.buttons["chatClose"]
        // The dim between the navigation bar's bottom and the panel's top, both on screen: the bar
        // from its own frame, the panel's top from the app's marker (the panel's own frame), so no
        // group inside the panel stands in for its edge. A tap higher up lands on the navigation
        // bar, which takes it; lower, on the panel.
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let open = try XCTUnwrap(settledDragMarker(in: app), "control: the marker shows")
        let panelTop = try XCTUnwrap(open.fieldTop, "control: the marker shows the open panel's top")
        XCTAssertLessThan(barBottom + 2 * Self.dimTapMargin, panelTop,
                          "control: there is dim between the navigation bar \(barBottom) and the panel \(panelTop) to tap")
        tap(atY: (barBottom + panelTop) / 2, dx: 0.5, in: app)
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a tap on the dim closed the panel")
        XCTAssertEqual(readDragMarker(in: app)?.dims, open.dims + 1, "the dim's own tap handler took the tap")
        XCTAssertTrue(isInChat(app), "the chat stays")
    }

    /// How far from the navigation bar and the panel a dim tap must land to be the dim's. The open
    /// panel leaves about 17 points of dim below the bar on an iPhone, so the midpoint tap has
    /// about 8 on each side.
    private static let dimTapMargin: CGFloat = 5

    /// The swell is not the field's room: across a short drag and its settle the chat does not move.
    /// XCUITest reads frames only once the app is idle, after the spring, so the app's marker
    /// records the newest row's largest move from the drag's start until well after its settle.
    func testShortDragOnTheReplyFieldKeepsTheChat() throws {
        let app = launchIntoChat()
        let field = replyField(in: app)
        let newest = bubble(3, in: app)
        let before = restingMinY(of: newest)
        // The marker reports the newest ROW's top, its sender line included, not the bubble's: read
        // it at rest too, so the control compares a row's top with a row's top.
        let rest = try XCTUnwrap(readDragMarker(in: app), "control: the marker shows at rest")
        let restingGlass = try XCTUnwrap(rest.fieldTop, "control: the marker shows the field's glass at rest")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -Self.shortDragTravel)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let marker = dragMarker(afterDrags: 1, in: app)
        XCTAssertNotNil(marker, "control: the marker recorded one finished drag")
        guard let marker else { return }
        XCTAssertTrue(marker.hasBaseline, "control: the drag's start had the newest row's place")
        // A drag is never a tap: the field does not take focus, so no keyboard moves the chat.
        XCTAssertTrue(markerReads(focused: false, in: app), "the short drag left the field unfocused")
        XCTAssertEqual(marker.newestMinY, rest.newestMinY, accuracy: 1, "control: the marker's newest row is the row read at rest")
        // The glass rose under the held finger (read by the app while the finger was down)...
        XCTAssertGreaterThan(marker.rise, Self.shortDragTravel / 2, "the field's glass swelled under the finger: \(marker.rise)")
        XCTAssertLessThanOrEqual(marker.rise, Self.shortDragTravel + 1, "no further than the finger went")
        // ...and is back at its resting top once settled.
        XCTAssertEqual(marker.fieldTop ?? -1, restingGlass, accuracy: 1, "the swell settled back")
        XCTAssertLessThan(marker.move, 1, "the chat stayed through the swell and the settle: moved \(marker.move)")
        XCTAssertTrue(marker.heldAtSettle, "the freeze is still held through the cooldown after the settle")
        XCTAssertFalse(marker.frozen, "the freeze is released once the drag has settled")
        XCTAssertEqual(newest.frame.minY, before, accuracy: 1, "the chat is where it was once settled")
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the short drag did not open the panel")
    }

    /// The short drag's travel: under the open distance.
    private static let shortDragTravel: CGFloat = 40

    /// A drag that opens the panel lets go of the user-interaction freeze too.
    func testDragThatOpensThePanelReleasesTheFreeze() {
        let app = launchIntoChat()
        dragFieldOpen(in: app)
        let marker = dragMarker(afterDrags: 1, in: app)
        XCTAssertNotNil(marker, "control: the marker recorded one finished drag")
        guard let marker else { return }
        XCTAssertTrue(marker.heldAtSettle, "the freeze is still held through the cooldown after the settle")
        XCTAssertFalse(marker.frozen, "the freeze is released after a drag that opened the panel")
        XCTAssertTrue(app.buttons["chatClose"].exists, "control: the panel is still open")
    }

    /// A drag held past the open distance when the panel opens under it, as an agent's answer opens
    /// it: opening turns the field's pan off, which cuts the drag off while the finger is still
    /// down. The fixture opens the panel the moment the app sees the held drag swollen past the open
    /// distance, and the app records what happened to the drag in order: the opening's request, then
    /// the cut (a drag that ran on to the let-go would record `end` instead, and the swell would hold
    /// until the finger lifts). The panel's actual opening is read from its Close button. The freeze the drag held is released, and once the panel closes the field
    /// is back at rest, no swell left, and the next drag opens the panel. (A cut-off drag cannot
    /// itself open the panel, as `fieldDragWiring` pins by reading; here the panel is open either
    /// way.)
    func testDragCutOffByThePanelOpeningSettlesAndTheNextDragWorks() throws {
        let app = launchIntoChat(openPanelUnderDrag: true)
        let field = replyField(in: app)
        let restingGlass = try XCTUnwrap(settledDragMarker(in: app)?.fieldTop, "control: the marker shows the field at rest")
        app.buttons["Open the panel under the next drag"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        // Up past the open distance, then held well after the panel has opened under it.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -Self.heldDragTravel)),
                    withVelocity: .default, thenHoldForDuration: Self.holdAfterThePanelOpens)
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "control: the panel opened under the held drag")
        let marker = try XCTUnwrap(dragMarker(afterDrags: 1, in: app), "control: the marker recorded the one drag")
        XCTAssertEqual(marker.events, ["open", "cut"],
                       "the opening was requested under the held drag, and the drag was then cut off before the finger lifted: \(dragMarkerLabel(afterDrags: 1, in: app))")
        XCTAssertFalse(marker.frozen, "the cut-off drag released the freeze")
        // The open panel turns the field's pan off, and closing it turns the pan back on: the
        // marker's pan record says which way each went.
        let panOpen = try XCTUnwrap(marker.pan, "control: the marker reports the field's pan")
        XCTAssertTrue(panOpen.contains { $0.hasPrefix("off:") }, "the opening turned the field's pan off: \(panOpen)")
        app.buttons["chatClose"].tap()
        XCTAssertTrue(app.buttons["chatClose"].waitForNonExistence(timeout: 3), "control: Close closed the panel")
        let closedMarker = try XCTUnwrap(settledDragMarker(in: app), "control: the marker shows again")
        XCTAssertEqual(closedMarker.pan?.last?.hasPrefix("on:"), true,
                       "closing the panel turned the field's pan back on: \(String(describing: closedMarker.pan))")
        let closed = try XCTUnwrap(closedMarker.fieldTop, "control: the marker shows the field again")
        XCTAssertEqual(closed, restingGlass, accuracy: 1, "the field is back at rest, no swell left")
        dragFieldOpen(in: app)
    }

    /// The held drag's travel, past the open distance, and how long it is held once there: the
    /// panel opens the moment the swell passes the open distance, so this only keeps the finger
    /// down well past that.
    private static let heldDragTravel: CGFloat = 150
    private static let holdAfterThePanelOpens: TimeInterval = 1.5

    /// With the actions of a bubble open, a drag up from the reply field far enough to open the
    /// panel only closes them: the closer takes it, as it takes every drag while something is open.
    func testOpenActionsDragUpOnTheReplyFieldOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        dragUp(atY: field.frame.midY, in: app)
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it closed the actions")
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "and did not open the panel")
        XCTAssertTrue(isInChat(app), "the chat stays")
    }

    /// With nothing open, a back swipe that starts on the reply field goes back: the field's drag
    /// takes only drags more up than sideways. The drag runs most of the screen's width: the back
    /// swipe takes it once the field's drag has declined, a few dozen points in, and a back swipe
    /// that stops short of half the width before the finger lifts settles back, as iOS's does.
    func testNothingOpenRightDragOnTheReplyFieldGoesBack() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        let y = field.frame.midY / app.frame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: Self.longBackSwipeStart, dy: y))
        XCTAssertGreaterThan(start.screenPoint.x, field.frame.minX, "control: the drag starts on the field's text")
        XCTAssertGreaterThan(start.screenPoint.x, Self.backSwipeEdge, "control: outside the screen edge's own back swipe")
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: Self.longBackSwipeEnd, dy: y)))
        XCTAssertTrue(wentBack(app), "a right drag from the field goes back")
    }

    /// A right drag across most of the screen, and the screen edge's own back-swipe zone
    /// (`ChatViewLayout.backSwipeEdgeWidth`), which a content back swipe starts outside of.
    private static let longBackSwipeStart: CGFloat = 0.15
    private static let longBackSwipeEnd: CGFloat = 0.95
    private static let backSwipeEdge: CGFloat = 24

    /// Starts in the screen's margin beside the field, outside the field's glass.
    func testNothingOpenEdgeDragOnTheReplyFieldGoesBack() {
        let app = launchIntoChat()
        dragFromEdge(atY: replyField(in: app).frame.midY, in: app)
        XCTAssertTrue(wentBack(app), "an edge drag at the field goes back")
    }

    /// Starts on the field's glass itself, where it overlaps the back swipe's zone at the screen's
    /// left edge (the field's side inset is narrower than that zone): the field's own drag and its
    /// text leave the back swipe the touch, so it goes back.
    func testNothingOpenEdgeDragStartingOnTheReplyFieldGoesBack() {
        let app = launchIntoChat()
        let pill = app.descendants(matching: .any)["chatReplyPill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "control: the field's glass")
        XCTAssertTrue(pill.isHittable, "control: the field is hittable")
        let y = replyField(in: app).frame.midY
        let x = pill.frame.minX + Self.insideTheFieldsEdge
        let onTheGlass = pill.frame.contains(CGPoint(x: x, y: y))
        XCTAssertTrue(onTheGlass, "control: the start (\(x), \(y)) is on the field's glass \(pill.frame)")
        XCTAssertLessThan(x, Self.backSwipeEdgeWidth, "control: and inside the back swipe's zone")
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: y / app.frame.height)))
        XCTAssertTrue(wentBack(app), "an edge drag that starts on the field goes back")
    }

    /// `ChatViewLayout.backSwipeEdgeWidth`, the back swipe's zone at the left edge, and how far into
    /// the field's glass from its leading edge the overlap drag starts (the field's side inset,
    /// `ChatViewLayout.fieldSideInset`, is 16 points, so this lands at 20).
    private static let backSwipeEdgeWidth: CGFloat = 24
    private static let insideTheFieldsEdge: CGFloat = 4

    /// Signed in, the focused field with a short draft: the drag up opens the panel, whose editor
    /// (not the sign-in bar a signed-out panel shows) holds the same draft.
    func testDragUpOnAShortFocusedDraftOpensThePanelWithIt() {
        let app = launchIntoChat(signedIn: true)
        let field = replyField(in: app, placeholder: Self.signedInPlaceholder)
        field.tap()
        XCTAssertTrue(waitForTypingFocus(field, timeout: 5), "control: the reply field has the keyboard")
        field.typeText(Self.shortQuestion)
        let typed = typedField(containing: Self.shortQuestion, in: app)
        XCTAssertTrue(typed.waitForExistence(timeout: 5), "control: the question is in the field")
        waitForTheKeyboardBack(under: typed, in: app)
        dragUp(atY: typed.frame.midY, in: app)
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "the drag opened the panel while the field had focus")
        XCTAssertFalse(app.staticTexts[Self.signInBarText].exists, "control: signed in, the panel has its editor, not the sign-in bar")
        let open = settledDragMarker(in: app)
        let editor = typedField(containing: Self.shortQuestion, in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "the panel's editor holds the draft")
        XCTAssertEqual(editor.value as? String, Self.shortQuestion, "the draft, whole and unchanged")
        if let panelTop = open?.fieldTop {
            XCTAssertGreaterThanOrEqual(editor.frame.minY, panelTop, "inside the open panel")
        } else {
            XCTFail("control: the marker shows the open panel")
        }
    }

    /// The signed-in field's hint (`ChatReplyField.placeholder`), and the open panel's sign-in bar.
    private static let signedInPlaceholder = "Reply or ask anything"
    private static let signInBarText = "Sign in to TabMail for AI features and push notifications"

    /// With the first-time tip showing, as a new user sees it: the tip is on screen, and it takes
    /// no touch from the field. The first drag opens the panel; in a fresh launch, the first tap
    /// focuses the field.
    func testFieldDragTipShowsAndLeavesTheFieldItsTouches() {
        let app = launchIntoChat(fieldDragTip: true)
        let tip = app.staticTexts[Self.fieldDragTipText].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "the tip shows above the field")
        XCTAssertLessThanOrEqual(tip.frame.maxY, replyField(in: app).frame.minY + 1, "control: the tip is above the field")
        assertTipCardFits(shownTipCard(in: app), "the whole card, not only its words, is between the header and the field")
        dragFieldOpen(in: app)
        app.terminate()

        let fresh = launchIntoChat(fieldDragTip: true)
        XCTAssertTrue(fresh.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: 5),
                      "control: the tip shows again in the fresh launch")
        replyField(in: fresh).tap()
        XCTAssertTrue(markerReads(focused: true, in: fresh), "the first tap focused the field")
    }

    /// The card's geometry, with the tip forced on: landscape at a large text size, where the card
    /// may not fit above the field, it is either wholly between the header and the field or waiting
    /// for room (the marker's `wait`), never cut off above the screen; the read waits until one of
    /// the two holds. Turned upright, the whole card shows. (Whether waiting keeps the tip's one
    /// showing is the app's own TipKit rules' to say, so
    /// `testFieldDragTipWaitingForRoomKeepsItsOneShowing` checks it without the forcing.)
    func testFieldDragTipCardIsWholeOrWaitsForRoom() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = launchIntoChat(fieldDragTip: true, textSize: Self.largeTextSize)
        let landscape = try XCTUnwrap(decidedTipMarker(in: app), "control: the card either shows or waits for room")
        if let card = landscape.tip {
            assertTipCardFits((card: card, room: landscape.room), "in landscape the card that shows is whole")
        } else {
            XCTAssertEqual(landscape.tipWaiting, true, "in landscape a card that does not show is waiting for room")
        }
        XCTContext.runActivity(named: landscape.tip == nil ? "landscape: the tip waited for room" : "landscape: the tip fit") { _ in }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: 5),
                      "with room the tip shows")
        assertTipCardFits(shownTipCard(in: app), "upright, the whole card is between the header and the field")
    }

    /// The app's own tip rules, nothing forced, on a fresh datastore of the test's own: landscape at
    /// the largest text size the whole card has no room, so the tip waits (the marker's `wait`) and
    /// shows no card. Relaunched upright at the default size on the same datastore, it shows,
    /// whole: waiting for room did not spend its one showing.
    func testFieldDragTipWaitingForRoomKeepsItsOneShowing() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = launchIntoChat(textSize: Self.largestTextSize, tipStore: .fresh)
        let landscape = try XCTUnwrap(decidedTipMarker(in: app), "control: the tip's place is decided")
        XCTAssertEqual(landscape.tipWaiting, true, "control: the tip is eligible and its whole card has no room, so it waits")
        XCTAssertNil(landscape.tip, "no card shows without room")
        let words = app.staticTexts[Self.fieldDragTipText].firstMatch
        if words.exists {
            // What the accessibility tree holds while nothing is drawn: where the words are, and
            // whether a touch could reach them.
            let found = XCTAttachment(string: "frame=\(words.frame) hittable=\(words.isHittable)\n\n\(app.debugDescription)")
            found.name = "waiting tip words"
            found.lifetime = .keepAlways
            add(found)
        }
        // VoiceOver can still reach the waiting card's words (tabmail-ios#1255, a VoiceOver-only
        // issue fixed later): expected to fail until then. The launch helper stops at the first
        // failure and an expected one counts, so it is let through here and the upright half below
        // still runs.
        let voiceOverIssue = XCTExpectedFailure.Options()
        voiceOverIssue.isStrict = false
        continueAfterFailure = true
        XCTExpectFailure("tabmail-ios#1255: a tip card waiting for room stays in the accessibility tree", options: voiceOverIssue) {
            XCTAssertFalse(words.exists, "and none of its words")
        }
        continueAfterFailure = false
        app.terminate()

        XCUIDevice.shared.orientation = .portrait
        let upright = launchIntoChat(tipStore: .kept)
        XCTAssertTrue(upright.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: 5),
                      "with room, on the same datastore, the tip shows: waiting kept its one showing")
        assertTipCardFits(shownTipCard(in: upright), "the whole card is between the header and the field")
    }

    /// The app's own tip rules on a fresh datastore of the test's own: a short drag that opens
    /// nothing ends the tip, and it stays gone when the chat is opened again and after a relaunch on
    /// the same datastore.
    func testFieldDragTipStaysGoneAfterAShortDrag() {
        let app = launchIntoChat(tipStore: .fresh)
        let tip = app.staticTexts[Self.fieldDragTipText].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "control: on a fresh datastore the tip shows")
        let field = replyField(in: app)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -25)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "control: the short drag opened nothing")
        XCTAssertTrue(tip.waitForNonExistence(timeout: 3), "the drag ended the tip")
        XCTAssertFalse(tip.waitForExistence(timeout: Self.tipStaysGoneWait), "and it stays gone")
        assertTipStaysGoneOnTheNextPresentations(of: app)
    }

    /// The app's own tip rules on a fresh datastore of the test's own: a tap that focuses the field
    /// ends the tip, and it stays gone when the chat is opened again and after a relaunch on the
    /// same datastore.
    func testFieldDragTipStaysGoneAfterATap() {
        let app = launchIntoChat(tipStore: .fresh)
        let tip = app.staticTexts[Self.fieldDragTipText].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "control: on a fresh datastore the tip shows")
        replyField(in: app).tap()
        XCTAssertTrue(markerReads(focused: true, in: app), "control: the tap focused the field")
        XCTAssertTrue(tip.waitForNonExistence(timeout: 3), "the tap ended the tip")
        XCTAssertFalse(tip.waitForExistence(timeout: Self.tipStaysGoneWait), "and the tip stays gone")
        assertTipStaysGoneOnTheNextPresentations(of: app)
    }

    /// The app's own tip rules on a fresh datastore of the test's own: the tip shows at most once.
    /// Once its whole card has shown, it is spent even when the user leaves the chat without
    /// touching the field or closing the tip: it does not come back when the chat is opened again
    /// with room for it, nor after a relaunch on the same datastore.
    func testFieldDragTipShownOnceStaysGoneAfterLeavingTheChat() {
        let app = launchIntoChat(tipStore: .fresh)
        let tip = app.staticTexts[Self.fieldDragTipText].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "control: on a fresh datastore the tip shows")
        assertTipCardFits(shownTipCard(in: app), "control: its whole card showed between the header and the field")
        assertTipStaysGoneOnTheNextPresentations(of: app)
    }

    /// The ended tip stays gone when the chat is opened again in the same launch, and in a relaunch
    /// on the same datastore.
    private func assertTipStaysGoneOnTheNextPresentations(of app: XCUIApplication,
                                                          file: StaticString = #filePath, line: UInt = #line) {
        dragFromEdge(atY: bubble(3, in: app).frame.midY, in: app)
        XCTAssertTrue(wentBack(app), "control: back at the list", file: file, line: line)
        app.buttons["Open chat"].tap()
        XCTAssertTrue(bubble(3, in: app).waitForExistence(timeout: 10), "control: the chat is open again", file: file, line: line)
        XCTAssertFalse(app.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: Self.tipStaysGoneWait),
                       "the ended tip stays gone in the chat opened again", file: file, line: line)
        app.terminate()

        let relaunched = launchIntoChat(tipStore: .kept)
        XCTAssertFalse(relaunched.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: Self.tipStaysGoneWait),
                       "and after a relaunch on the same datastore", file: file, line: line)
    }

    /// An accessibility text size: the card grows tall enough that it may not fit in landscape,
    /// yet it fits upright.
    private static let largeTextSize = "UICTContentSizeCategoryAccessibilityXL"
    /// The largest accessibility text size: in landscape the card has no room above the field.
    private static let largestTextSize = "UICTContentSizeCategoryAccessibilityXXXL"
    /// How long a gone tip is watched for coming back.
    private static let tipStaysGoneWait: TimeInterval = 2

    /// The marker once the tip's place is decided and holds across two reads a moment apart: its
    /// whole card shows, or it waits for room. A tip TipKit has not yet made available lays out
    /// empty, so neither holds until TipKit has decided. Nil if neither holds within the poll limit.
    private func decidedTipMarker(in app: XCUIApplication) -> DragMarker? {
        let deadline = Date().addingTimeInterval(Self.dragMarkerPollLimit)
        var last: DragMarker?
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(Self.restReadInterval))
            let now = readDragMarker(in: app)
            if let now, now.tip != nil || now.tipWaiting == true,
               let last, Self.sameSpan(now.tip, last.tip), now.tipWaiting == last.tipWaiting {
                return now
            }
            last = now
        } while Date() < deadline
        return nil
    }

    /// The marker's tip card once it shows, with its room.
    private func shownTipCard(in app: XCUIApplication) -> (card: (CGFloat, CGFloat)?, room: (CGFloat, CGFloat)?) {
        let deadline = Date().addingTimeInterval(Self.dragMarkerPollLimit)
        repeat {
            if let marker = readDragMarker(in: app), let tip = marker.tip { return (tip, marker.room) }
            RunLoop.current.run(until: Date().addingTimeInterval(Self.focusMarkerPollStep))
        } while Date() < deadline
        return (nil, nil)
    }

    /// The marker after the screen has settled (read twice, a moment apart, the same).
    private func settledDragMarker(in app: XCUIApplication) -> DragMarker? {
        let deadline = Date().addingTimeInterval(Self.dragMarkerPollLimit)
        var last: DragMarker?
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(Self.restReadInterval))
            let now = readDragMarker(in: app)
            if let now, let last, Self.sameSpan(now.tip, last.tip), now.fieldTop == last.fieldTop { return now }
            last = now
        } while Date() < deadline
        return last
    }

    private static func sameSpan(_ one: (CGFloat, CGFloat)?, _ other: (CGFloat, CGFloat)?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case let (one?, other?): one == other
        default: false
        }
    }

    /// The whole card lies between the header's bottom and the field stack's top, measured by the
    /// app in one space.
    private func assertTipCardFits(_ shown: (card: (CGFloat, CGFloat)?, room: (CGFloat, CGFloat)?), _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let card = shown.card, let room = shown.room else {
            XCTFail("control: the marker reports the card and its room", file: file, line: line)
            return
        }
        XCTAssertLessThan(card.0, card.1, "control: the card has a height", file: file, line: line)
        XCTAssertGreaterThanOrEqual(card.0, room.0 - 1, "\(message): its top \(card.0) is below the header \(room.0)", file: file, line: line)
        XCTAssertLessThanOrEqual(card.1, room.1 + 1, "\(message): its bottom \(card.1) is above the field \(room.1)", file: file, line: line)
    }

    func testShortDragUpOnTheReplyFieldSettlesBack() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        // Slow and short: under the open distance, with no flick.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -25)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "a short drag does not open the panel")
        XCTAssertTrue(replyField(in: app).isHittable, "the field settled back")
        XCTAssertTrue(markerReads(focused: false, in: app), "and did not take focus, as a tap would")
    }

    /// The same short travel let go fast: the flick's predicted swell opens the panel through the
    /// installed pan, though the finger stopped short of the open distance.
    func testShortFlickUpOnTheReplyFieldOpensThePanel() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        XCTAssertLessThan(Self.shortFlick, ChatSwipeUITests.openDistance, "control: the finger stops short of the open distance")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -Self.shortFlick)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "the flick opened the panel")
        XCTAssertTrue(isInChat(app), "the chat stays")
    }

    /// `ChatViewLayout.fieldDragOpenDistance`, and a flick's travel well short of it.
    private static let openDistance: CGFloat = 60
    private static let shortFlick: CGFloat = 40

    /// The focused field: a drag up in text that overflows the field's lines, stopping short of the
    /// text's end, only scrolls that text, so the panel stays shut and the field keeps its focus. The
    /// text is first scrolled to its top, so the drag has room; which line is at the top is read by tapping the text's top-left corner and
    /// typing a mark there. A short draft's drag opens the panel
    /// (`testDragUpOnAShortFocusedDraftOpensThePanelWithIt`).
    func testDragUpInOverflowingTextScrollsIt() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        field.tap()
        XCTAssertTrue(waitForTypingFocus(field, timeout: 5), "control: the reply field has the keyboard")
        field.typeText(Self.overflowingText)
        let long = typedField(containing: Self.overflowingLastLine, in: app)
        XCTAssertTrue(long.waitForExistence(timeout: 5), "control: the typed lines are in the field")
        waitForTheKeyboardBack(under: long, in: app)
        // Down to the text's top: the field's drag takes only drags up, so this is the text's scroll.
        textScroll(long, by: Self.toTheTextsTop, in: app)
        XCTAssertEqual(topLine(of: long, in: app), "Line 1", "control: the text is at its top, with room to scroll")
        textScroll(long, by: -Self.withinTheScrollRoom, in: app)
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "the drag scrolled the overflowing text; the panel stays shut")
        XCTAssertTrue(markerReads(focused: true, in: app), "and the field kept its focus")
        let watched = dragMarkerLabel(afterDrags: 1, in: app)
        // Where the drag left it: the control read above left the caret at the draft's start, and a
        // scroll toward it after the let-go can stop with another line on top, so the top line alone
        // cannot show the text stayed put.
        XCTAssertEqual(dragMarker(afterDrags: 1, in: app)?.textMove, "none",
                       "after the let-go the text stayed where the drag left it (marker: \(watched))")
        let after = topLine(of: long, in: app)
        XCTAssertNotNil(after, "control: a line is at the text's top")
        XCTAssertNotEqual(after, "Line 1", "the text moved on under the drag (marker: \(watched))")
        XCTAssertEqual(long.value as? String, Self.overflowingText, "control: the text is unchanged")
    }

    /// Signed in, the same draft and the same start, but the drag carries on past the text's end:
    /// the rest of the same drag is the field's (mock v15 H2), so it opens the panel, whose editor
    /// holds the whole draft, inside the panel and above the keyboard when one shows.
    func testDragUpInOverflowingTextPastItsEndOpensThePanel() throws {
        let app = launchIntoChat(signedIn: true)
        let long = signedInDraftAtItsTop(Self.overflowingText, lastLine: Self.overflowingLastLine, in: app)
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the panel is shut")
        textScroll(long, by: -Self.pastTheTextsEnd, in: app)
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "the drag past the text's end opened the panel")
        let opened = try XCTUnwrap(dragMarker(afterDrags: 1, in: app), "control: the field's pan saw the drag")
        let watched = dragMarkerLabel(afterDrags: 1, in: app)
        let downBuilds = try XCTUnwrap(opened.downBuilds, "control: the marker counted the field's builds while the finger was down (marker: \(watched))")
        XCTAssertLessThanOrEqual(downBuilds, Self.dragStartBuildAllowance,
                                 "the swell growing under the finger did not rebuild the field's editor: \(downBuilds) builds while it was down (marker: \(watched))")
        XCTAssertFalse(app.staticTexts[Self.signInBarText].exists, "control: signed in, the panel has its editor, not the sign-in bar")
        let panelTop = try XCTUnwrap(settledDragMarker(in: app)?.fieldTop, "control: the marker shows the open panel")
        let editor = typedField(containing: Self.overflowingLastLine, in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "the panel's editor holds the draft")
        XCTAssertEqual(editor.value as? String, Self.overflowingText, "the whole draft, unchanged")
        XCTAssertGreaterThanOrEqual(editor.frame.minY, panelTop - 1, "inside the open panel")
        // The draft keeps the keyboard's focus in the panel's editor (read from the element, so it
        // holds whether or not the simulator shows its software keyboard), and where a software
        // keyboard shows, the editor sits above it.
        XCTAssertTrue(waitForFocus(editor, true, timeout: 3), "the panel's editor keeps the draft's focus")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1, "above the keyboard")
        }
    }

    /// Signed in, a draft whose scroll room is larger than the open distance, at its top: a drag up
    /// further than the open distance that stays inside that room is all the text's. The field's
    /// glass does not rise under it, the panel stays shut, the field keeps its focus, and the text
    /// moved on.
    func testDragUpPastTheOpenDistanceInsideTheTextsRoomIsAllTheTexts() throws {
        let app = launchIntoChat(signedIn: true)
        let long = signedInDraftAtItsTop(Self.longDraft, lastLine: Self.longDraftLastLine, in: app)
        XCTAssertGreaterThan(Self.insideTheLongDraftsRoom, Self.openDistance, "control: the drag goes past the open distance")
        textScroll(long, by: -Self.insideTheLongDraftsRoom, in: app)
        let marker = try XCTUnwrap(dragMarker(afterDrags: 1, in: app), "control: the field's pan saw the drag")
        XCTAssertLessThan(marker.rise, 1, "the text kept the whole drag; the field's glass did not rise: \(marker.rise)")
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "the panel stays shut")
        XCTAssertTrue(markerReads(focused: true, in: app), "the field kept its focus")
        let watched = dragMarkerLabel(afterDrags: 1, in: app)
        XCTAssertEqual(marker.textMove, "none", "after the let-go the text stayed where the drag left it (marker: \(watched))")
        let after = topLine(of: long, in: app)
        XCTAssertNotNil(after, "control: a line is at the text's top")
        XCTAssertNotEqual(after, "Line 1", "the text moved on under the drag (marker: \(watched))")
        XCTAssertEqual(long.value as? String, Self.longDraft, "control: the draft is unchanged")
    }

    /// Signed in, the nine-line draft at its top, and a drag up further than the open distance in
    /// all but past the text's end by less than it: the text scrolls to its end and stops there,
    /// with no bounce past it, and only the rest of the drag is the field's. The glass rises under
    /// that rest, but not far enough to open the panel, so it settles back.
    func testDragUpPastTheTextsEndByLessThanTheOpenDistanceSettlesBack() throws {
        let app = launchIntoChat(signedIn: true)
        let long = signedInDraftAtItsTop(Self.overflowingText, lastLine: Self.overflowingLastLine, in: app)
        XCTAssertGreaterThan(Self.acrossTheTextsEnd, Self.openDistance, "control: the whole drag goes past the open distance")
        textScroll(long, by: -Self.acrossTheTextsEnd, in: app)
        let marker = try XCTUnwrap(dragMarker(afterDrags: 1, in: app), "control: the field's pan saw the drag")
        let watched = dragMarkerLabel(afterDrags: 1, in: app)
        XCTAssertGreaterThan(marker.rise, 1, "past the text's end the rest of the drag swelled the field: \(marker.rise) (marker: \(watched))")
        XCTAssertLessThan(marker.rise, Self.openDistance, "only the rest past the text's end: \(marker.rise) (marker: \(watched))")
        let pastEnd = try XCTUnwrap(marker.textPastEnd, "control: the field's pan read the text's place while the drag moved (marker: \(watched))")
        XCTAssertGreaterThan(pastEnd, -1, "control: the text reached its end under the drag: \(pastEnd) (marker: \(watched))")
        XCTAssertLessThan(pastEnd, 1, "the text stopped at its end and did not bounce past it while the field swelled: \(pastEnd) (marker: \(watched))")
        let downBuilds = try XCTUnwrap(marker.downBuilds, "control: the marker counted the field's builds while the finger was down (marker: \(watched))")
        XCTAssertLessThanOrEqual(downBuilds, Self.dragStartBuildAllowance,
                                 "the moving finger and the changing swell did not rebuild the field's editor: \(downBuilds) builds while it was down (marker: \(watched))")
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2), "the panel stays shut")
        XCTAssertTrue(markerReads(focused: true, in: app), "the field kept its focus")
        XCTAssertEqual(long.value as? String, Self.overflowingText, "control: the draft is unchanged")
    }

    /// The text's scroll room (three lines, about 60 points) plus well past the open distance.
    private static let pastTheTextsEnd: CGFloat = 220
    /// Slack for editor builds while a drag's finger is down that do not come from its movement:
    /// the chat's body may run as the drag starts (its freeze and tip state), building the reply
    /// field again. A build per movement (the drag's state read where the editor is built) gives one
    /// for each of the drag's moves past the text's end, far more than this on the long drag that
    /// opens the panel.
    private static let dragStartBuildAllowance = 2
    /// Past the open distance in all, yet past the nine-line draft's end (its scroll room, more
    /// than `withinTheScrollRoom`) by less than the open distance.
    private static let acrossTheTextsEnd: CGFloat = 90
    /// A draft with ten lines past the field's six (about 220 points of scroll room), and a drag up
    /// past the open distance well inside that room.
    private static let longDraftLineCount = 16
    private static let longDraft = (1...longDraftLineCount).map { "Line \($0)" }.joined(separator: "\n")
    private static let longDraftLastLine = "Line \(longDraftLineCount)"
    private static let insideTheLongDraftsRoom: CGFloat = 120

    /// Signed in, the focused field with `text` typed into it and scrolled back to its top, so a
    /// drag up has the text's whole scroll room; returns the field, found by `lastLine`.
    private func signedInDraftAtItsTop(_ text: String, lastLine: String, in app: XCUIApplication) -> XCUIElement {
        let field = replyField(in: app, placeholder: Self.signedInPlaceholder)
        field.tap()
        XCTAssertTrue(waitForTypingFocus(field, timeout: 5), "control: the reply field has the keyboard")
        field.typeText(text)
        let long = typedField(containing: lastLine, in: app)
        XCTAssertTrue(long.waitForExistence(timeout: 5), "control: the typed lines are in the field")
        waitForTheKeyboardBack(under: long, in: app)
        // Down to the text's top: the field's drag takes only drags up, so this is the text's scroll.
        textScroll(long, by: Self.toTheTextsTop, in: app)
        XCTAssertEqual(topLine(of: long, in: app), "Line 1", "control: the text is at its top, with room to scroll")
        return long
    }

    /// A slow vertical drag in the text from its middle, held at the end so it does not coast.
    /// Both ends come from one read of the text's frame, in screen points: an element's coordinate
    /// is resolved again for each end, so a field that moves with the keyboard in between would
    /// give a press where it was and a lift where it is.
    private func textScroll(_ text: XCUIElement, by travel: CGFloat, in app: XCUIApplication) {
        let frame = text.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: travel)),
                    withVelocity: .slow, thenHoldForDuration: Self.scrollSettleHold)
    }

    /// The line at the top of the text: a tap at its top-left corner puts the caret at that line's
    /// start, a typed mark shows where, and the mark is deleted again. The typing drops the software
    /// keyboard for a moment, so it waits for it to come back before the next gesture.
    private func topLine(of text: XCUIElement, in app: XCUIApplication) -> String? {
        text.coordinate(withNormalizedOffset: .zero).withOffset(Self.insideTheTextsCorner).tap()
        text.typeText(Self.lineMark)
        let value = text.value as? String ?? ""
        text.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForTheKeyboardBack(under: text, in: app)
        return value.components(separatedBy: "\n").first { $0.hasPrefix(Self.lineMark) }.map { String($0.dropFirst(Self.lineMark.count)) }
    }

    /// Past the text's whole height, so a drag down reaches its top; a drag up of less than its
    /// scroll room (three lines past the field's six, about 20 points each); the hold after either;
    /// where in the text's top-left corner the tap lands; the mark typed there.
    private static let toTheTextsTop: CGFloat = 300
    private static let withinTheScrollRoom: CGFloat = 40
    private static let scrollSettleHold: TimeInterval = 0.5
    private static let insideTheTextsCorner = CGVector(dx: 6, dy: 6)
    private static let lineMark = "#"

    /// The focused field with words: a long press at the start of its text puts the caret there, so
    /// the next typed character lands first. The text's long press runs while the field's drag waits;
    /// were the long press made to wait for the drag, it could not begin until the finger lifts, and
    /// the caret would stay at the end.
    func testLongPressInTheFocusedFieldMovesTheCaret() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        field.tap()
        XCTAssertTrue(waitForTypingFocus(field, timeout: 5), "control: the reply field has the keyboard")
        field.typeText(Self.caretPhrase)
        let typed = typedField(containing: Self.caretPhrase, in: app)
        XCTAssertTrue(typed.waitForExistence(timeout: 5), "control: the phrase is in the field")
        waitForTheKeyboardBack(under: typed, in: app)
        typed.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: Self.caretPressInset, dy: 0))
            .press(forDuration: Self.textLongPressHold)
        typed.typeText(Self.lineMark)
        // Found again by its last word, which the mark cannot split wherever it lands.
        let marked = typedField(containing: Self.caretPhraseLastWord, in: app)
        XCTAssertTrue(marked.waitForExistence(timeout: 5), "control: the field still holds the phrase")
        XCTAssertEqual(marked.value as? String, Self.lineMark + Self.caretPhrase,
                       "the long press put the caret at the text's start")
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the press opened nothing")
    }

    /// One short line, typed so the caret ends after it, and its last word.
    private static let caretPhrase = "Lunch works"
    private static let caretPhraseLastWord = "works"
    /// Where the long press lands, from the text's leading edge: the text's long press puts the
    /// caret at the nearest character boundary, so a press past the middle of the first letter
    /// (about 4 points at the body size) would put it after that letter.
    private static let caretPressInset: CGFloat = 1

    /// Signed in, an overflowing draft at its top: a double tap on its first word makes the text
    /// view's own selection of that word, and the typed word replaces exactly that selection. The
    /// field's drag beside the text leaves its selection alone; the panel stays shut.
    func testDoubleTapInOverflowingTextSelectsAWordToReplace() {
        let app = launchIntoChat(signedIn: true)
        let long = signedInDraftAtItsTop(Self.overflowingText, lastLine: Self.overflowingLastLine, in: app)
        long.coordinate(withNormalizedOffset: .zero).withOffset(Self.insideTheTextsCorner).doubleTap()
        long.typeText(Self.replacementWord)
        let replaced = Self.replacementWord + String(Self.overflowingText.dropFirst(Self.firstWord.count))
        XCTAssertEqual(long.value as? String, replaced, "the double tap selected the first word, and the typed word replaced it")
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the panel stays shut")
        XCTAssertTrue(markerReads(focused: true, in: app), "control: the field kept its focus")
    }

    /// The overflowing draft's first word, and the word typed over its selection.
    private static let firstWord = "Line"
    private static let replacementWord = "Row"

    /// The focused field with words: a press held until the text view's own long press takes it
    /// (the loupe, caret placement), then moved up past the open distance, stays the text's. The
    /// field's drag waits for the text view's long presses, so the panel stays shut and the field
    /// keeps its focus and its words. Without that wait the drag would take the moving finger and
    /// open the panel.
    func testLongPressThenDragUpInTheFocusedFieldStaysTheTexts() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        field.tap()
        XCTAssertTrue(waitForTypingFocus(field, timeout: 5), "control: the reply field has the keyboard")
        field.typeText(Self.shortQuestion)
        let typed = typedField(containing: Self.shortQuestion, in: app)
        XCTAssertTrue(typed.waitForExistence(timeout: 5), "control: the question is in the field")
        waitForTheKeyboardBack(under: typed, in: app)
        // The caret starts at the text's start (`topLine` taps it there and shows where a mark
        // lands), away from both places the text's long press can leave it: on the words under the
        // finger, or at the text's end, where it follows a finger moved above the one-line text.
        XCTAssertEqual(topLine(of: typed, in: app), Self.shortQuestion, "control: the caret is at the text's start before the press")
        // Both ends from one read of the field's frame (`textScroll`).
        let frame = typed.frame
        let onTheWords = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * Self.onTheWordsDx, dy: frame.midY))
        onTheWords.press(forDuration: Self.textLongPressHold,
                         thenDragTo: onTheWords.withOffset(CGVector(dx: 0, dy: -Self.pastTheOpenDistance)))
        XCTAssertFalse(app.buttons["chatClose"].waitForExistence(timeout: 2),
                       "the held press stayed the text's; the panel stays shut")
        XCTAssertTrue(markerReads(focused: true, in: app), "the field kept its focus")
        XCTAssertTrue(typedField(containing: Self.shortQuestion, in: app).exists, "and its words")
        // The press reached the text: its long press moved the caret, so a typed mark no longer
        // lands at the text's start, where the caret was before the press.
        typedField(containing: Self.shortQuestion, in: app).typeText(Self.lineMark)
        let marked = typedField(containing: Self.lineMark, in: app)
        XCTAssertTrue(marked.waitForExistence(timeout: 5), "control: the mark went into the field")
        let value = marked.value as? String ?? ""
        XCTAssertEqual(value.replacingOccurrences(of: Self.lineMark, with: ""), Self.shortQuestion,
                       "control: the field holds the question and the mark")
        XCTAssertNotEqual(value, Self.lineMark + Self.shortQuestion,
                          "the held press moved the caret off the text's start: \(dragMarkerLabel(afterDrags: 0, in: app))")
    }

    /// Longer than UIKit's long press (half a second), so the text view's own long press has begun
    /// before the finger moves.
    private static let textLongPressHold: TimeInterval = 1.0
    /// Into the field from its leading edge, on the short question's words.
    private static let onTheWordsDx: CGFloat = 0.1
    /// Well past the app's open distance (`ChatViewLayout.fieldDragOpenDistance`, 60 pt), as the
    /// drags that open the panel go.
    private static let pastTheOpenDistance: CGFloat = 200

    /// More lines than the field's six, so its text scrolls; the caret ends on the last line, at the
    /// left, away from where the drag starts.
    private static let overflowingLineCount = 9
    private static let overflowingText = (1...overflowingLineCount).map { "Line \($0)" }.joined(separator: "\n")
    private static let overflowingLastLine = "Line \(overflowingLineCount)"
    /// Short, so the caret after it sits left of the field's middle, where the drag starts.
    private static let shortQuestion = "Free?"

    /// The reply field once it has words in it (it has no placeholder then), found by its text.
    private func typedField(containing words: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", words)).firstMatch
    }

    /// A drag up from the middle of the screen's width at `y`, far enough to open the panel.
    private func dragUp(atY y: CGFloat, in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
    }

    func testOpenActionsDragOnTheHeaderOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragRight(atY: subject(in: app).frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
    }

    func testChatButtonsOpenRightDragOnTheReplyFieldOnlyClosesNeverGoesBack() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        dragRight(atY: field.frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "never goes back")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "it only closed the chat's buttons")
        dragFromEdge(atY: bubble(2, in: app).frame.midY, in: app)
        XCTAssertTrue(wentBack(app), "the next drag goes back")
    }

    func testChatButtonsOpenTapOnTheReplyFieldOnlyClosesAndDoesNotFocusIt() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        let field = replyField(in: app)
        XCTAssertTrue(field.isHittable, "control: the reply field is on screen")
        let point = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.tap()
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "it closed the chat's buttons")
        XCTAssertFalse(waitForFocus(field, true, timeout: 2), "the reply field did not take focus")
        XCTAssertTrue(isInChat(app))
        // Control: with nothing open, the same tap focuses the field.
        point.tap()
        XCTAssertTrue(waitForFocus(field, true, timeout: 5), "control: the same tap focuses the field")
    }

    func testChatButtonsOpenRightDragOnTheHeaderOnlyCloses() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        dragRight(atY: subject(in: app).frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "never goes back")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "it only closed the chat's buttons")
    }

    func testChatButtonsOpenRightDragOnTheNavigationBarOnlyCloses() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        dragRight(atY: navigationBarY(in: app), in: app)
        XCTAssertTrue(isInChat(app), "never goes back")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "it only closed the chat's buttons")
    }

    func testOpenActionsRightDragOnTheNavigationBarOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragRight(atY: navigationBarY(in: app), in: app)
        XCTAssertTrue(isInChat(app), "never goes back")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
    }

    func testOpenActionsTapOnForwardOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it closed the actions")
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(app.buttons["Forward"].isHittable, "forward's compose did not open over the chat")
    }

    // MARK: - A chat opened inside a presented sheet (as search opens it)

    func testInSheetOpenActionsOwnButtonStillWorks() {
        let app = launchIntoChat(host: .sheet)
        openBubble(2, in: app)
        app.buttons["Move"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForExistence(timeout: 5), "the open bubble's Move runs")
    }

    func testInSheetOtherBubbleRightDragOnlyCloses() {
        let app = launchIntoChat(host: .sheet)
        openBubble(2, in: app)
        dragRight(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the open actions closed, and no other opened")
    }

    // MARK: - A chat opened from a mailbox: a collapsed split view's push, as the app does

    func testInSplitOpenActionsOwnButtonStillWorks() {
        let app = launchIntoChat(host: .split)
        openBubble(2, in: app)
        app.buttons["Move"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForExistence(timeout: 5), "the open bubble's Move runs")
    }

    func testInSplitOtherBubbleRightDragOnlyCloses() {
        let app = launchIntoChat(host: .split)
        openBubble(2, in: app)
        dragRight(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the open actions closed, and no other opened")
    }

    func testInSplitOpenActionsFirstEdgeDragClosesThenTheNextGoesBack() {
        let app = launchIntoChat(host: .split)
        openBubble(2, in: app)
        let y = bubble(3, in: app).frame.midY
        dragFromEdge(atY: y, in: app)
        XCTAssertTrue(isInChat(app), "the first drag stays in the chat")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
        dragFromEdge(atY: y, in: app)
        XCTAssertTrue(wentBack(app), "the next drag goes back")
    }

    func testInSplitOpenBubbleThatLeavesTheChatLeavesNothingOpen() {
        let app = launchIntoChat(armRemoval: true, host: .split)
        let removed = bubble(1, in: app)
        openBubble(1, in: app)
        XCTAssertTrue(removed.waitForNonExistence(timeout: 20), "the email left the chat, as a sync takes it")
        dragRight(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(bubbleActionsShow(app), "the next swipe opens another bubble's actions")
    }

    // MARK: - A vertical drag, and the keyboard, while something is open

    func testOpenActionsVerticalDragScrollsAndCloses() {
        let app = launchIntoChat(tall: true)
        openBubble(2, in: app)
        let newest = bubble(3, in: app)
        let before = newest.frame.minY
        // Down from another bubble, slowly and held at the end, so the chat stays where it was
        // dragged: it shows older text.
        let from = bubble(1, in: app).frame.midY
        let to = min(from + Self.verticalDrag, replyField(in: app).frame.minY - 10)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from / app.frame.height))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to / app.frame.height)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the drag closed the actions")
        XCTAssertGreaterThan(newest.frame.minY, before + Self.scrolledAtLeast, "and the chat scrolled")
        XCTAssertTrue(isInChat(app))
    }

    /// The jump button, tapped for real, runs its real animated scroll to the end: the newest
    /// bubble shows above the reply field. (The hosted pin tests read the same button's effect on
    /// the landing; an animated scroll does not run to its end in a hosted window.)
    func testJumpButtonScrollsToTheNewestBubble() {
        let app = launchIntoChat(tall: true)
        let jump = app.buttons["Jump to the newest email"]
        let middle = app.frame.height / 2
        for _ in 0..<Self.jumpScrollDrags where !jump.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (middle - Self.verticalDrag / 2) / app.frame.height))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (middle + Self.verticalDrag / 2) / app.frame.height)),
                       withVelocity: .fast, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 3), "control: scrolled up, the jump button shows")
        let newest = bubble(3, in: app)
        let fieldTop = replyField(in: app).frame.minY
        XCTAssertFalse(newest.exists && newest.frame.maxY <= fieldTop && newest.frame.maxY > 0,
                       "control: the newest bubble is off screen before the jump")
        jump.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            newest.exists && newest.frame.maxY <= fieldTop + 1 && newest.frame.maxY > fieldTop - app.frame.height / 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed,
                       "the jump ends with the newest bubble above the reply field: \(newest.frame), field at \(fieldTop)")
        XCTAssertTrue(jump.waitForNonExistence(timeout: 3), "at the bottom the jump button goes")
    }

    /// After the user scrolls away from the landing, a late AI Suggestion (a new row height below)
    /// never pulls the chat back to the bottom: the reading position stays the user's.
    func testUsersScrollKeepsItsPlaceWhenTheSuggestionArrivesLate() {
        let app = launchIntoChat(tall: true, lateSuggestion: true)
        let jump = app.buttons["Jump to the newest email"]
        let middle = app.frame.height / 2
        for _ in 0..<Self.jumpScrollDrags where !jump.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (middle - Self.verticalDrag / 2) / app.frame.height))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (middle + Self.verticalDrag / 2) / app.frame.height)),
                       withVelocity: .fast, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 3), "control: the user scrolled away from the bottom")
        let oldest = bubble(0, in: app)
        let place = restingMinY(of: oldest)
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertFalse(ghost.exists, "control: no AI Suggestion before the test releases it")
        app.buttons["Release the AI Suggestion"].tap()
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "control: the AI Suggestion lands after the user's scroll rests")
        // Let any layout the new row causes run.
        XCTAssertFalse(app.buttons["Jump to the newest email"].waitForNonExistence(timeout: 2),
                       "the chat stays away from the bottom: the jump button is still there")
        XCTAssertEqual(oldest.frame.minY, place, accuracy: 2, "the reading position is the user's")
    }

    /// While the AI Suggestion is written its working bubble is the last chat row, above the field;
    /// when it is stored the working bubble becomes the ghost, and the chat, still pinned to the
    /// bottom, keeps the ghost above the field.
    func testWorkingBubbleBecomesTheGhostAboveTheField() {
        let app = launchIntoChat(lateSuggestion: true, writing: true)
        let working = app.descendants(matching: .any)["chat.aiSuggestion.writing"].firstMatch
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 5), "the working bubble shows while the suggestion is written")
        XCTAssertFalse(ghost.exists, "control: no ghost before the test releases it")
        _ = restingMinY(of: working)
        XCTAssertLessThanOrEqual(working.frame.maxY, replyField(in: app).frame.minY + 1,
                                 "the working bubble is a chat row above the field: \(working.frame)")
        XCTAssertGreaterThanOrEqual(working.frame.minY, bubble(3, in: app).frame.maxY - 1,
                                    "the working bubble is the last chat row, below the newest email: \(working.frame)")
        app.buttons["Release the AI Suggestion"].tap()
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "the stored suggestion fills the working bubble in")
        XCTAssertTrue(working.waitForNonExistence(timeout: 3), "one row: the working bubble became the ghost")
        _ = restingMinY(of: ghost)
        XCTAssertLessThanOrEqual(ghost.frame.maxY, replyField(in: app).frame.minY + 1,
                                 "the re-pin keeps the grown ghost above the field: \(ghost.frame)")
    }

    /// Opened on a stored AI Suggestion, the chat shows the ghost and never the working bubble.
    func testReadySuggestionOpensOnTheGhostWithNoWorkingBubble() {
        let app = launchIntoChat(readyAtOpen: true)
        let working = app.descendants(matching: .any)["chat.aiSuggestion.writing"].firstMatch
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "the stored suggestion shows as the ghost")
        XCTAssertFalse(working.exists, "no working bubble on a ready suggestion")
        XCTAssertGreaterThanOrEqual(ghost.frame.minY, bubble(3, in: app).frame.maxY - 1,
                                    "the ghost is the last chat row: \(ghost.frame)")
    }

    /// Opened at the Unread line, a tap on the jump button ends that landing for good: the AI
    /// Suggestion landing late afterwards (a new row height) leaves the newest bubble in view and
    /// never pulls the chat back to the line.
    func testJumpEndsTheUnreadLandingWhenTheSuggestionArrivesLate() {
        let app = launchIntoChat(tall: true, lateSuggestion: true, unread: true)
        let jump = app.buttons["Jump to the newest email"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "control: the chat lands at the Unread line, away from the bottom")
        let newest = bubble(3, in: app)
        let fieldTop = replyField(in: app).frame.minY
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertFalse(ghost.exists, "control: no AI Suggestion before the jump")
        jump.tap()
        XCTAssertTrue(newestInView(newest, above: fieldTop, in: app, timeout: 5), "control: the jump reaches the newest bubble")
        _ = restingMinY(of: newest)
        XCTAssertFalse(ghost.exists, "control: no AI Suggestion until the test releases it, after the jump rests")
        app.buttons["Release the AI Suggestion"].tap()
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "control: the AI Suggestion lands after the jump")
        XCTAssertTrue(newestInView(newest, above: replyField(in: app).frame.minY, in: app, timeout: 3),
                      "after the late row the newest bubble is still in view: \(newest.frame)")
        XCTAssertFalse(jump.waitForExistence(timeout: 2), "and the chat was never pulled back up to the Unread line")
    }

    /// Heights that change right after the jump tap, while its scroll runs (the reply field takes
    /// focus and grows), still leave the newest bubble in view once it ends.
    func testJumpReachesTheNewestBubbleThroughHeightsChangingRightAfterTheTap() {
        let app = launchIntoChat(tall: true, unread: true)
        let jump = app.buttons["Jump to the newest email"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "control: the chat lands away from the bottom")
        let field = replyField(in: app)
        jump.tap()
        field.tap()
        field.typeText("One\nTwo\nThree\nFour")
        let newest = bubble(3, in: app)
        // With words in it the field has no placeholder: find it by its text.
        let typed = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "Four")).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 5), "control: the typed words are in the field")
        XCTAssertTrue(newestInView(newest, above: typed.frame.minY, in: app, timeout: 5),
                      "the newest bubble ends in view above the grown field: \(newest.frame), field \(typed.frame)")
    }

    /// The AI Suggestion lands the moment the jump is tapped, while its scroll animates: the jump
    /// still ends with the newest bubble in view.
    func testJumpReachesTheNewestBubbleWhenTheSuggestionLandsMidScroll() {
        let app = launchIntoChat(tall: true, unread: true, suggestionOnJump: true)
        let jump = app.buttons["Jump to the newest email"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "control: the chat lands at the Unread line, away from the bottom")
        let fieldTop = replyField(in: app).frame.minY
        jump.tap()
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "control: the AI Suggestion landed with the jump")
        let newest = bubble(3, in: app)
        XCTAssertTrue(newestInView(newest, above: fieldTop, in: app, timeout: 5),
                      "the jump ends with the newest bubble in view: \(newest.frame), field at \(fieldTop)")
    }

    /// Whether the newest bubble's bottom is on screen, above `fieldTop`, within `timeout`.
    /// `element`'s top once two reads half a second apart agree: where a scroll came to rest.
    private func restingMinY(of element: XCUIElement) -> CGFloat {
        var last = element.frame.minY
        for _ in 0..<Self.restReads {
            Thread.sleep(forTimeInterval: Self.restReadInterval)
            let now = element.frame.minY
            if abs(now - last) < 1 { return now }
            last = now
        }
        XCTFail("control: the scroll came to rest: \(element.frame)")
        return last
    }

    private func newestInView(_ newest: XCUIElement, above fieldTop: CGFloat, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            newest.exists && newest.frame.maxY <= fieldTop + 1 && newest.frame.maxY > fieldTop - app.frame.height / 2
        }, object: nil)
        return XCTWaiter.wait(for: [shown], timeout: timeout) == .completed
    }

    /// With a reply draft already saved for the email, a tap on the ghost opens the compose card
    /// with its body: the full suggestion (text only the card shows, never the ghost's), never the
    /// saved draft's words. Opened, checked and closed three times. While tabmail-ios#1124 is open
    /// the suggestion box is missing from accessibility every time, deterministically: the compose
    /// scroll view's class swap happens at its first layout update, before the suggestion arrives
    /// from `loadDraftOrPrepopulate`'s database reads. That is why the expected failure is strict.
    /// Only when Use Suggestion can be found does the third open tap it, put the suggestion in the
    /// body, and Close then Save, leaving the saved draft as it was beside one draft of the card's
    /// own; otherwise every close discards. A screenshot is attached when the test ends, pass or
    /// fail, and one more just before any tap on Use Suggestion.
    func testSavedDraftGhostCardShowsTheSuggestionAndUseSuggestionFillsTheBody() {
        let app = launchIntoChatFromSavedDraftFixture()
        addTeardownBlock {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "saved-draft-ghost-card"
            shot.lifetime = .keepAlways
            self.add(shot)
        }
        let ghost = app.descendants(matching: .any)["chat.aiSuggestion"].firstMatch
        XCTAssertTrue(ghost.waitForExistence(timeout: 10), "control: the ghost shows")
        // The row's reply changes under the ghost with no refresh: the card must still open with
        // the reply the user taps, never the row's later text.
        app.buttons["Rewrite the AI Suggestion"].tap()
        var usedSuggestion = false
        for pass in 1...Self.cardOpenPasses {
            XCTAssertTrue(ghost.waitForExistence(timeout: 10), "control: the ghost shows (pass \(pass))")
            ghost.tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "the card opens (pass \(pass))")
            XCTAssertTrue(app.buttons["Send"].firstMatch.exists, "the card shows Send (pass \(pass))")
            let use = app.buttons["Use Suggestion"]
            // The suggestion box, Dismiss and Use Suggestion: the checks the class swap hides.
            // Once tabmail-ios#1124 is fixed they pass, and the strict expectation turns this red.
            // The helper stops at the first failure; an expected one must not end the test, so the
            // later passes, the discard path, the drag back and the Drafts marker still run.
            continueAfterFailure = true
            XCTExpectFailure("tabmail-ios#1124: the compose scroll view's class swap hides the AI Suggestion box from accessibility", strict: true) {
                XCTAssertTrue(use.waitForExistence(timeout: 10), "the card opens and shows Use Suggestion (pass \(pass))")
                XCTAssertTrue(app.buttons["Dismiss"].exists, "the card shows Dismiss (pass \(pass))")
                // The full reply's closing line: only the card shows it, never the ghost's text message.
                let box = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                    Self.cardOnlyText, Self.cardOnlyText)).firstMatch
                XCTAssertTrue(box.exists, "the card shows its suggestion box (pass \(pass))")
            }
            continueAfterFailure = false
            // While tabmail-ios#1124 hides the box these two cannot fail: those words could only
            // appear inside the box. The invariant that the card never shows them rests on the hosted
            // seam test (ComposeSuggestionPersistTests.cardShowsTheTappedSuggestionNotTheRowsLaterReply).
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                Self.savedDraftWords, Self.savedDraftWords)).firstMatch.exists, "never the saved draft's words (pass \(pass))")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                Self.rewrittenWords, Self.rewrittenWords)).firstMatch.exists, "never the row's rewritten reply (pass \(pass))")
            // Steps that need a tap on Use Suggestion run only while the button can be found
            // (tabmail-ios#1124); never a tap by coordinate.
            guard pass == Self.cardOpenPasses, use.exists else {
                closeCard(in: app, saving: false)
                continue
            }
            let before = XCTAttachment(screenshot: app.screenshot())
            before.name = "saved-draft-ghost-card-before-use"
            before.lifetime = .keepAlways
            add(before)
            use.tap()
            let editor = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", Self.cardOnlyText)).firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5), "Use Suggestion fills the body")
            XCTAssertTrue(editor.isHittable, "the body editor is on screen")
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", Self.savedDraftWords)).firstMatch.exists,
                           "never the saved draft's words in the body")
            closeCard(in: app, saving: true)
            usedSuggestion = true
        }
        // Back on the fixture's list, which reads Drafts again: the saved draft keeps its words and
        // was never saved over. When Use Suggestion was tapped and saved, the card saved one draft
        // of its own, holding the suggestion; otherwise every close discarded, so it saved none.
        dragFromEdge(atY: app.frame.height / 2, in: app)
        XCTAssertTrue(wentBack(app), "an edge drag goes back to the fixture list")
        let marker = app.staticTexts["fixture.savedDraft"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let expected = usedSuggestion
            ? "Saved draft kept: yes; separate replies: 1; holding the suggestion: 1"
            : "Saved draft kept: yes; separate replies: 0; holding the suggestion: 0"
        let after = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: marker)
        XCTAssertEqual(XCTWaiter.wait(for: [after], timeout: 5), .completed, "the saved draft stays in Drafts: \(marker.label)")
    }

    /// How many times the saved-draft test opens and checks the card.
    private static let cardOpenPasses = 3

    /// Launches the saved-draft fixture and checks, before Open chat, that the reply draft is saved.
    private func launchIntoChatFromSavedDraftFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--chat-swipe-ui-test", "--chat-swipe-saved-draft"]
        // Every run proves the card asks for no Contacts access, even on a simulator that answered.
        app.resetAuthorizationStatus(for: .contacts)
        app.launch()
        XCTAssertTrue(app.staticTexts["Chat swipe fixture"].waitForExistence(timeout: 20))
        let marker = app.staticTexts["fixture.savedDraft"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "control: the fixture shows what Drafts holds")
        XCTAssertEqual(marker.label, "Saved draft kept: yes; separate replies: 0; holding the suggestion: 0", "control: the reply draft is saved")
        app.buttons["Open chat"].tap()
        XCTAssertTrue(subject(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(bubble(3, in: app).waitForExistence(timeout: 10))
        return app
    }

    /// Closes the compose card; when it asks to save, Save or Discard.
    private func closeCard(in app: XCUIApplication, saving: Bool) {
        app.buttons["Close"].firstMatch.tap()
        let prompt = app.alerts["Save Draft?"]
        if prompt.waitForExistence(timeout: 3) {
            prompt.buttons[saving ? "Save" : "Discard"].tap()
        } else {
            XCTAssertFalse(saving, "Close asks to save once the body holds the suggestion")
        }
        XCTAssertTrue(app.buttons["Close"].waitForNonExistence(timeout: 5), "the card closes")
    }

    /// The fixture's saved draft (`ChatSwipeTestScene`).
    private static let savedDraftWords = "My own words, not sent yet"
    /// The full reply's closing line, which the card's suggestion box shows and the ghost does not.
    private static let cardOnlyText = "Thanks."
    /// The fixture's quiet rewrite of the row's reply (`ChatSwipeTestScene.rewrittenReply`).
    private static let rewrittenWords = "A rewritten reply."

    func testOpenActionsTapOnAnotherBubbleClosesAndDropsTheKeyboard() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        field.tap()
        XCTAssertTrue(waitForFocus(field, true, timeout: 5), "control: the reply field has the keyboard")
        XCTAssertTrue(markerReads(focused: true, in: app), "control: the focus marker reads the field's focus")
        openBubble(2, in: app)
        XCTAssertTrue(markerReads(focused: true, in: app), "control: opening the actions left the keyboard up")
        let other = bubble(1, in: app)
        XCTAssertLessThan(other.frame.maxY, field.frame.minY, "control: the bubble shows above the field and its keyboard")
        tap(atY: other.frame.midY, dx: 0.5, in: app)
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the actions closed")
        XCTAssertTrue(markerReads(focused: false, in: app), "and the same tap dropped the keyboard")
        XCTAssertFalse(app.buttons["Sheet Grabber"].waitForExistence(timeout: 2), "the tap opened no card")
    }

    // MARK: - Left drags and taps while something is open

    func testChatButtonsOpenLeftDragOnTheChatContinues() {
        let app = launchIntoChat()
        openChatButtons(in: app)
        // A short drag further open: the chat's own swipe follows it, so its buttons stay.
        let y = bubble(2, in: app).frame.midY
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / app.frame.height))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: y / app.frame.height)))
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(app.buttons["Trash"].waitForExistence(timeout: 3), "the chat's buttons stay open")
    }

    func testOpenActionsLeftDragOnTheOpenBubbleContinuesIt() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        // The open bubble's own swipe takes a drag back the other way and follows it shut.
        dragLeft(on: bubble(2, in: app), in: app)
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the bubble followed the drag shut")
        XCTAssertFalse(app.buttons["Trash"].exists, "the chat's buttons did not open")
    }

    func testOpenActionsLeftDragElsewhereOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragLeft(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the actions closed")
        XCTAssertFalse(app.buttons["Trash"].exists, "and the chat's buttons did not open")
    }

    func testOpenActionsTapElsewhereOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        let other = bubble(3, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: other.frame.midY / app.frame.height)).tap()
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "the actions closed")
        XCTAssertTrue(isInChat(app))
        XCTAssertFalse(app.buttons["Sheet Grabber"].waitForExistence(timeout: 2), "the tap opened no card")
    }

    // MARK: - An open bubble whose email leaves the chat

    func testOpenBubbleThatLeavesTheChatLeavesNothingOpen() {
        let app = launchIntoChat(armRemoval: true)
        let removed = bubble(1, in: app)
        openBubble(1, in: app)
        XCTAssertTrue(removed.waitForNonExistence(timeout: 20), "the email left the chat, as a sync takes it")
        dragRight(on: bubble(3, in: app), in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(bubbleActionsShow(app), "the next swipe opens another bubble's actions")
    }

    // MARK: - The tutorial's coach card in the header

    /// The header the swipes measure is the whole top bar: the subject and the coach card under it.
    /// Measured from the subject alone, the card would sit inside the chat's reach, so a drag there
    /// would carry the open buttons on and a tap on its Skip would run. Once the run moves on and
    /// the card goes, the band it covered must be the chat's again.
    func testTutorialCardOpenChatButtonsDragAndTapOnTheCardOnlyClose() {
        let app = launchIntoChat(host: .tutorialCard)
        let card = coachCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "control: the coach card shows under the subject")
        XCTAssertGreaterThan(card.frame.minY, subject(in: app).frame.minY, "control: the card sits under the subject")
        let cardY = card.frame.midY

        // A leftward drag on the card: inside the chat's reach it would carry the buttons on.
        openChatButtons(in: app)
        dragLeft(atY: cardY, in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the drag on the card only closed the chat's buttons")

        // A tap on the card's own Skip: it only closes, and the run (so the card) stays.
        openChatButtons(in: app)
        app.buttons["tutorial-skip"].tap()
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the tap on the card closed the chat's buttons")
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(card.exists, "the tap ran no card action: the run and its card stay")

        // The existing header targets still only close: the subject and Forward.
        openChatButtons(in: app)
        dragRight(atY: subject(in: app).frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "never goes back")
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the drag on the subject only closed the chat's buttons")
        openChatButtons(in: app)
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.buttons["Trash"].waitForNonExistence(timeout: 3), "the tap on Forward only closed the chat's buttons")
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(card.exists, "control: the card still shows")

        // The run moves on (the fixture's strip under the chat): the card goes, the chat stays, and
        // where the card sat is the chat's.
        let moveOn = app.buttons["Move the tutorial on"]
        XCTAssertTrue(moveOn.isHittable, "control: the move-on button shows under the chat")
        XCTAssertGreaterThan(moveOn.frame.minY, app.descendants(matching: .any)["chatReplyPill"].firstMatch.frame.maxY, "control: it sits below the chat's region")
        moveOn.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "the card goes once the run moves on")
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertGreaterThan(cardY, subject(in: app).frame.maxY, "control: the card's band is below the subject")
        openChatButtons(in: app)
        // A short drag further open where the card sat: the chat's own swipe follows it.
        let dy = cardY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: dy)))
        XCTAssertTrue(isInChat(app))
        XCTAssertTrue(app.buttons["Trash"].waitForExistence(timeout: 3), "the chat's buttons stay open: the band is the chat's again")
    }

    // MARK: - Helpers

    /// The reply field's placeholder in the fixture, which has no TabMail session.
    private static let replyPlaceholder = "Sign in to reply or ask"
    /// How far the vertical drag goes, and how far the chat must have scrolled with it.
    private static let verticalDrag: CGFloat = 250
    private static let scrolledAtLeast: CGFloat = 60
    /// Drags up the tall chat until the jump button shows.
    private static let jumpScrollDrags = 8
    /// How many half-second reads `restingMinY` makes before calling the scroll still moving.
    private static let restReads = 10
    private static let restReadInterval: TimeInterval = 0.5

    /// What the fixture's list sits in: a navigation stack, a presented sheet (as search), or a
    /// collapsed split view's content column (as a mailbox).
    /// `tutorialCard`: a navigation stack opening the tutorial's practice chat, whose header holds
    /// the coach card.
    private enum Host { case stack, sheet, split, tutorialCard }

    /// The TipKit datastore of the tip tests' own, under the app's own tip rules (nothing forced):
    /// emptied at this launch, or kept from the launch before.
    private enum TipStore { case fresh, kept }
    /// With the tip rules live the onboarding gate is open, so the chat's own first-open notice (the
    /// AI summaries popover, which keeps its own flag outside TipKit) would open over the first
    /// landing of a fresh install and take the test's first touch. This launch argument marks it as
    /// already shown for that launch only (the argument domain), and stores nothing.
    private static let noticeAlreadyShown = ["-chatView.aiSummariesNotice.shownOnFirstOpen", "YES"]

    private func launchIntoChat(armRemoval: Bool = false, host: Host = .stack, tall: Bool = false,
                                lateSuggestion: Bool = false, unread: Bool = false,
                                suggestionOnJump: Bool = false, writing: Bool = false,
                                readyAtOpen: Bool = false, fieldDragTip: Bool = false,
                                textSize: String? = nil, signedIn: Bool = false,
                                openPanelUnderDrag: Bool = false, tipStore: TipStore? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--chat-swipe-ui-test"]
            + (host == .sheet ? ["--chat-swipe-in-sheet"] : [])
            + (host == .split ? ["--chat-swipe-in-split"] : [])
            + (tall ? ["--chat-swipe-tall"] : [])
            + (unread ? ["--chat-swipe-unread"] : [])
            + (lateSuggestion ? ["--chat-swipe-late-suggestion"] : [])
            + (suggestionOnJump ? ["--chat-swipe-suggestion-on-jump"] : [])
            + (writing ? ["--chat-swipe-writing"] : [])
            + (readyAtOpen ? ["--chat-swipe-ready"] : [])
            + (host == .tutorialCard ? ["--chat-swipe-tutorial-card"] : [])
            + (fieldDragTip ? ["--chat-field-drag-tip"] : [])
            + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
            + (signedIn ? ["--chat-swipe-signed-in"] : [])
            + (openPanelUnderDrag ? ["--chat-swipe-open-panel-under-drag"] : [])
        if let tipStore {
            app.launchArguments += ["--chat-field-drag-tip-store"] + Self.noticeAlreadyShown
            if tipStore == .fresh { app.launchArguments.append("--chat-field-drag-tip-fresh") }
        }
        app.launch()
        switch host {
        case .stack, .tutorialCard:
            break
        case .sheet:
            XCTAssertTrue(app.buttons["Show sheet"].waitForExistence(timeout: 20))
            app.buttons["Show sheet"].tap()
        case .split:
            let inbox = app.descendants(matching: .any)["Fixture inbox"].firstMatch
            XCTAssertTrue(inbox.waitForExistence(timeout: 20), "the split view shows its sidebar first")
            inbox.tap()
        }
        XCTAssertTrue(app.staticTexts["Chat swipe fixture"].waitForExistence(timeout: 20))
        if armRemoval { app.buttons["Remove a bubble"].tap() }
        app.buttons["Open chat"].tap()
        XCTAssertTrue(subject(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(bubble(host == .tutorialCard ? nil : 3, in: app).waitForExistence(timeout: 10))
        return app
    }

    /// Whether `element` has (or has lost) the keyboard's focus within `timeout`, read from the
    /// element, so it holds whether the simulator shows its software keyboard or not.
    private func waitForFocus(_ element: XCUIElement, _ focused: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == %@", NSNumber(value: focused)), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Whether `field` takes the keyboard's focus within `timeout`, for a caller that types next and
    /// then waits for the keyboard (`waitForTheKeyboardBack`): focus gained, it notes whether a
    /// software keyboard came up for it (`noteTheKeyboard`) before the first key.
    private func waitForTypingFocus(_ field: XCUIElement, timeout: TimeInterval) -> Bool {
        let focused = waitForFocus(field, true, timeout: timeout)
        if focused { noteTheKeyboard(in: XCUIApplication()) }
        return focused
    }

    /// Notes whether a keyboard of a software keyboard's size comes up for the field just focused,
    /// waiting up to `keyboardAppearLimit`. Typing drops a software keyboard at the first key, so
    /// only a keyboard seen here, before any key, or by `waitForTheKeyboardBack` keeps a field that
    /// holds still with the keyboard away from counting as a run with no software keyboard.
    private func noteTheKeyboard(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let deadline = Date().addingTimeInterval(Self.keyboardAppearLimit)
        repeat {
            if keyboard.exists, keyboard.frame.height > app.frame.height * Self.keyboardMinShare {
                sawSoftwareKeyboard = true
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Self.keyboardBackPollStep))
        } while Date() < deadline
    }

    /// XCUITest types like a hardware keyboard: a simulator that shows its software keyboard drops
    /// it at the first typed key and brings it back about one and a half seconds after the last,
    /// and the focused field rides down and up with it. A gesture aimed at the field in between
    /// lands where the field was. Returns once `element` holds still above the software keyboard
    /// back on screen. Only while no keyboard of a software keyboard's size has been seen in this
    /// test, on screen or parked below it (a simulator that shows none), does a field holding still
    /// for longer than the keyboard takes to come back count. A software keyboard that stays parked
    /// or covers the field fails at the deadline.
    private func waitForTheKeyboardBack(under element: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        var last: CGRect?
        var keys: CGRect?
        var stillSince = Date()
        let deadline = Date().addingTimeInterval(Self.keyboardBackLimit)
        repeat {
            // One read of the field, the screen and the keyboard per poll.
            let frame = element.frame
            let screen = app.frame
            keys = keyboard.exists ? keyboard.frame : nil
            if let keys, keys.height > screen.height * Self.keyboardMinShare { sawSoftwareKeyboard = true }
            if frame != last {
                last = frame
                stillSince = Date()
            } else if let keys, screen.intersection(keys).height > screen.height * Self.keyboardMinShare {
                // On screen only: while it is away the keyboard still exists, parked below the
                // screen, and a field resting at the bottom is above that too. On screen, the field
                // must rest above it.
                if frame.maxY <= keys.minY + 1 { return }
            } else if !sawSoftwareKeyboard, Date().timeIntervalSince(stillSince) > Self.keyboardReturnWindow {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Self.keyboardBackPollStep))
        } while Date() < deadline
        XCTFail("control: the field holds still above the keyboard after the typing (field \(String(describing: last)), "
                + "keyboard \(String(describing: keys)), software keyboard seen \(sawSoftwareKeyboard))")
    }

    /// Whether a keyboard of a software keyboard's size was seen in this test, once a field took
    /// focus (`noteTheKeyboard`) or after typing (`waitForTheKeyboardBack`).
    private var sawSoftwareKeyboard = false

    /// How long the field may keep moving after typing; how often it and the keyboard are read; the
    /// least share of the screen's height a software keyboard covers (the hardware keyboard's small
    /// bar covers less); how long a field with no software keyboard must hold still, past the
    /// keyboard's return; how long a software keyboard may take to come up once a field has focus.
    private static let keyboardBackLimit: TimeInterval = 8
    private static let keyboardBackPollStep: TimeInterval = 0.25
    private static let keyboardMinShare: CGFloat = 0.25
    private static let keyboardReturnWindow: TimeInterval = 2.5
    private static let keyboardAppearLimit: TimeInterval = 2

    /// How long a focus read through the app's marker may take to settle.
    private static let focusMarkerPollLimit: TimeInterval = 3
    private static let focusMarkerPollStep: TimeInterval = 0.1

    /// Whether the reply field's focus, read from the app's accessibility marker beside it (the
    /// field element's own focus reads lost once a swipe re-renders the chat), is `focused` within
    /// `focusMarkerPollLimit`.
    private func markerReads(focused: Bool, in app: XCUIApplication) -> Bool {
        let marker = app.descendants(matching: .any)["chatReplyFieldFocus"].firstMatch
        let want = focused ? "focused" : "unfocused"
        let deadline = Date().addingTimeInterval(Self.focusMarkerPollLimit)
        repeat {
            if marker.exists && marker.label == want { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Self.focusMarkerPollStep))
        } while Date() < deadline
        return false
    }

    private func replyField(in app: XCUIApplication, placeholder: String = ChatSwipeUITests.replyPlaceholder) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            placeholder)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "control: the reply field, found by its placeholder")
        return field
    }

    /// `ChatFieldDragTip.text`, the tip's words.
    private static let fieldDragTipText = "Drag up to see what you asked TabMail about this conversation."
    /// How long the app's drag marker may take to finish watching a drag (its watch outlasts the
    /// settle by design).
    private static let dragMarkerPollLimit: TimeInterval = 5

    /// What the app's `chatFieldDragMarker` recorded: the newest row's largest move during and
    /// after the last field drag, and whether the interaction freeze is held.
    private struct DragMarker {
        let drags: Int
        let watching: Bool
        /// Whether the drag's start had the newest row's place, and the row's last reported top.
        let hasBaseline: Bool
        let newestMinY: CGFloat
        /// Whether the freeze was still held halfway through the cooldown after the settle.
        let heldAtSettle: Bool
        let move: CGFloat
        let frozen: Bool
        /// The drag tip's whole card, top and bottom, while it shows, and its room (the header's
        /// bottom and the field stack's top), in the app's chat space.
        let tip: (CGFloat, CGFloat)?
        let room: (CGFloat, CGFloat)?
        /// The top of the field's glass on screen, swell included (the open panel's top while it is
        /// open); how far it rose above its place at the last drag's start while the finger moved;
        /// and how many taps the open panel's dim took.
        let fieldTop: CGFloat?
        let rise: CGFloat
        let dims: Int
        /// How far the text under the last drag went past its end while the drag moved (nil when
        /// the marker does not say).
        let textPastEnd: CGFloat?
        /// What happened to the last drag, in order (`open`, then `end` or `cut`); nil when the
        /// marker does not say.
        let events: [String]?
        /// Whether the drag tip is waiting for room (eligible, its whole card has none); nil when
        /// the marker does not say.
        let tipWaiting: Bool?
        /// The field's pan turned on or off (`on:<state>`, `off:<state>`) or cancelled during the
        /// last drag and since, in order; nil when the marker does not say.
        let pan: [String]?
        /// How often the reply field's editor was built while the last drag's finger was down; nil
        /// while that drag has not let go or when the marker does not say.
        let downBuilds: Int?
        /// The text under the last drag's first move of a point or more after its let-go, while the
        /// marker watched (`none`: it stayed where the drag left it); nil when the marker does not say.
        let textMove: String?
    }

    /// `<top>:<bottom>`, or nil for "none".
    private static func span(_ text: String?) -> (CGFloat, CGFloat)? {
        guard let parts = text?.split(separator: ":").compactMap({ Double($0) }), parts.count == 2 else { return nil }
        return (CGFloat(parts[0]), CGFloat(parts[1]))
    }

    private func readDragMarker(in app: XCUIApplication) -> DragMarker? {
        let marker = app.descendants(matching: .any)["chatFieldDragMarker"].firstMatch
        guard marker.exists else { return nil }
        var fields: [String: String] = [:]
        for part in marker.label.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard let drags = fields["drags"].flatMap(Int.init), let watching = fields["watching"],
              let base = fields["base"], let at = fields["at"].flatMap(Double.init), let held = fields["held"],
              let move = fields["move"].flatMap(Double.init), let frozen = fields["frozen"] else { return nil }
        return DragMarker(drags: drags, watching: watching == "1", hasBaseline: base == "1", newestMinY: CGFloat(at),
                          heldAtSettle: held == "1", move: CGFloat(move), frozen: frozen == "1",
                          tip: Self.span(fields["tip"]), room: Self.span(fields["room"]),
                          fieldTop: fields["field"].flatMap(Double.init).flatMap { $0 < 0 ? nil : CGFloat($0) },
                          rise: CGFloat(fields["rise"].flatMap(Double.init) ?? 0),
                          dims: fields["dims"].flatMap(Int.init) ?? 0,
                          textPastEnd: fields["over"].flatMap(Double.init).map { CGFloat($0) },
                          events: fields["events"].map { $0 == "none" ? [] : $0.split(separator: ",").map(String.init) },
                          tipWaiting: fields["wait"].map { $0 == "1" },
                          pan: fields["pan"].map { $0 == "none" ? [] : $0.split(separator: ",").map(String.init) },
                          downBuilds: fields["builds"]?.split(separator: ":").first.flatMap { Int($0) },
                          textMove: fields["textMove"])
    }

    /// The marker once it has seen `drags` drags and stopped watching the last one.
    private func dragMarker(afterDrags drags: Int, in app: XCUIApplication) -> DragMarker? {
        let deadline = Date().addingTimeInterval(Self.dragMarkerPollLimit)
        repeat {
            if let marker = readDragMarker(in: app), marker.drags >= drags, !marker.watching { return marker }
            RunLoop.current.run(until: Date().addingTimeInterval(Self.focusMarkerPollStep))
        } while Date() < deadline
        return nil
    }

    /// The marker's raw label once it has seen `drags` drags and stopped watching the last one
    /// (prefixed when it never stopped), for a failure message: its `textAt`, `textEnd` and
    /// `textMove` say what moved the text under the drag after its let-go.
    private func dragMarkerLabel(afterDrags drags: Int, in app: XCUIApplication) -> String {
        let settled = dragMarker(afterDrags: drags, in: app) != nil
        let marker = app.descendants(matching: .any)["chatFieldDragMarker"].firstMatch
        return (settled ? "" : "unsettled: ") + (marker.exists ? marker.label : "none")
    }

    /// Drags the collapsed reply field up past the open distance and waits for the panel.
    private func dragFieldOpen(in app: XCUIApplication) {
        let field = replyField(in: app)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
        XCTAssertTrue(app.buttons["chatClose"].waitForExistence(timeout: 3), "control: the drag opened the panel")
    }

    private func navigationBarY(in app: XCUIApplication) -> CGFloat {
        app.buttons["Forward"].frame.midY
    }

    private func tap(atY y: CGFloat, dx: CGFloat, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: y / app.frame.height)).tap()
    }

    /// The fixture's subject, or in the tutorial variant Priya's practice email's.
    private func subject(in app: XCUIApplication) -> XCUIElement {
        let fixture = app.staticTexts["Swipe fixture lunch"].firstMatch
        if fixture.exists { return fixture }
        return app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Engineering offsite")).firstMatch
    }

    private func coachCard(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["tutorial-coach"].firstMatch
    }

    /// The fixture's bubble `index`; nil, any bubble (the tutorial's chat, whose bubbles say who said
    /// what).
    private func bubble(_ index: Int?, in app: XCUIApplication) -> XCUIElement {
        let marker = index.map { "Note \($0):" } ?? " said: "
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
    }

    private func isInChat(_ app: XCUIApplication) -> Bool {
        // Give a back swipe time to finish before reading the screen.
        _ = app.staticTexts["Chat swipe fixture"].waitForExistence(timeout: 2)
        return subject(in: app).exists && !app.buttons["Open chat"].isHittable
    }

    private func wentBack(_ app: XCUIApplication) -> Bool {
        app.buttons["Open chat"].waitForExistence(timeout: 5) && subject(in: app).waitForNonExistence(timeout: 5)
    }

    private func bubbleActionsShow(_ app: XCUIApplication) -> Bool {
        app.buttons["Move"].waitForExistence(timeout: 3)
    }

    private func openBubble(_ index: Int, in app: XCUIApplication) {
        dragRight(on: bubble(index, in: app), in: app)
        XCTAssertTrue(bubbleActionsShow(app), "control: the bubble's actions open")
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "the swipe opened no card")
    }

    private func openChatButtons(in app: XCUIApplication) {
        dragLeft(on: bubble(coachCardFixture(app) ? nil : 2, in: app), in: app)
        XCTAssertTrue(app.buttons["Trash"].waitForExistence(timeout: 3), "control: the chat's buttons open")
    }

    private func dragRight(on element: XCUIElement, in app: XCUIApplication) {
        dragRight(atY: element.frame.midY, in: app)
    }

    private func dragRight(atY y: CGFloat, in app: XCUIApplication) {
        let dy = y / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy)))
    }

    /// Whether the app runs the tutorial variant, whose chat has no numbered bubbles.
    private func coachCardFixture(_ app: XCUIApplication) -> Bool {
        app.launchArguments.contains("--chat-swipe-tutorial-card")
    }

    private func dragLeft(on element: XCUIElement, in app: XCUIApplication) {
        dragLeft(atY: element.frame.midY, in: app)
    }

    private func dragLeft(atY y: CGFloat, in app: XCUIApplication) {
        let dy = y / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy)))
    }

    private func dragFromEdge(atY y: CGFloat, in app: XCUIApplication) {
        let dy = y / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy)))
    }
}
