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
    func testDraggedOpenPanelClosesOnCloseAndOnTheDim() {
        let app = launchIntoChat()
        dragFieldOpen(in: app)
        app.buttons["chatClose"].tap()
        XCTAssertTrue(app.buttons["chatClose"].waitForNonExistence(timeout: 3), "Close closed the panel")
        XCTAssertTrue(replyField(in: app).isHittable, "the collapsed field is back")

        dragFieldOpen(in: app)
        let close = app.buttons["chatClose"]
        // The dim between the navigation bar and the panel's top.
        let dimY = (navigationBarY(in: app) + close.frame.minY) / 2
        XCTAssertLessThan(navigationBarY(in: app) + 20, close.frame.minY - 20, "control: there is dim above the panel to tap")
        tap(atY: dimY, dx: 0.5, in: app)
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a tap on the dim closed the panel")
        XCTAssertTrue(isInChat(app), "the chat stays")
    }

    /// The swell is not the field's room: across a short drag and its settle the chat does not move.
    /// XCUITest reads frames only once the app is idle, after the spring, so the app's marker
    /// records the newest row's largest move from the drag's start until well after its settle.
    func testShortDragOnTheReplyFieldKeepsTheChat() {
        let app = launchIntoChat()
        let field = replyField(in: app)
        let newest = bubble(3, in: app)
        let before = restingMinY(of: newest)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: field.frame.midY / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -40)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let marker = dragMarker(afterDrags: 1, in: app)
        XCTAssertNotNil(marker, "control: the marker recorded one finished drag")
        guard let marker else { return }
        XCTAssertTrue(marker.hasBaseline, "control: the drag's start had the newest row's place")
        XCTAssertEqual(marker.newestMinY, before, accuracy: 1, "control: the marker's newest row is the bubble read at rest")
        XCTAssertLessThan(marker.move, 1, "the chat stayed through the swell and the settle: moved \(marker.move)")
        XCTAssertTrue(marker.heldAtSettle, "the freeze is still held through the cooldown after the settle")
        XCTAssertFalse(marker.frozen, "the freeze is released once the drag has settled")
        XCTAssertEqual(newest.frame.minY, before, accuracy: 1, "the chat is where it was once settled")
        XCTAssertFalse(app.buttons["chatClose"].exists, "control: the short drag did not open the panel")
    }

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

    /// With the first-time tip showing, as a new user sees it: the tip is on screen, and it takes
    /// no touch from the field. The first drag opens the panel; in a fresh launch, the first tap
    /// focuses the field.
    func testFieldDragTipShowsAndLeavesTheFieldItsTouches() {
        let app = launchIntoChat(fieldDragTip: true)
        let tip = app.staticTexts[Self.fieldDragTipText].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "the tip shows above the field")
        XCTAssertLessThanOrEqual(tip.frame.maxY, replyField(in: app).frame.minY + 1, "control: the tip is above the field")
        dragFieldOpen(in: app)
        app.terminate()

        let fresh = launchIntoChat(fieldDragTip: true)
        XCTAssertTrue(fresh.staticTexts[Self.fieldDragTipText].firstMatch.waitForExistence(timeout: 5),
                      "control: the tip shows again in the fresh launch")
        replyField(in: fresh).tap()
        XCTAssertTrue(markerReads(focused: true, in: fresh), "the first tap focused the field")
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

    private func launchIntoChat(armRemoval: Bool = false, host: Host = .stack, tall: Bool = false,
                                lateSuggestion: Bool = false, unread: Bool = false,
                                suggestionOnJump: Bool = false, fieldDragTip: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--chat-swipe-ui-test"]
            + (host == .sheet ? ["--chat-swipe-in-sheet"] : [])
            + (host == .split ? ["--chat-swipe-in-split"] : [])
            + (tall ? ["--chat-swipe-tall"] : [])
            + (unread ? ["--chat-swipe-unread"] : [])
            + (lateSuggestion ? ["--chat-swipe-late-suggestion"] : [])
            + (suggestionOnJump ? ["--chat-swipe-suggestion-on-jump"] : [])
            + (host == .tutorialCard ? ["--chat-swipe-tutorial-card"] : [])
            + (fieldDragTip ? ["--chat-field-drag-tip"] : [])
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

    private func replyField(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            Self.replyPlaceholder)).firstMatch
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
                          heldAtSettle: held == "1", move: CGFloat(move), frozen: frozen == "1")
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
