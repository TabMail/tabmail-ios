/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

/// Real drags on a real chat (ADR-IOS-114 decision 12), as Mail does it:
///  - A rightward drag that starts on a bubble never goes back.
///  - With nothing open, a drag from the screen's left edge goes back.
///  - While a bubble's actions or the chat's buttons are open, only that reveal takes drags; any
///    drag or tap anywhere else (another bubble, the reply field, the header, the screen's edge)
///    only closes it, and the next drag goes back.
///  - A bubble whose actions were open and whose email then leaves the chat leaves nothing open.
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
        // The reply field sits just above the home indicator, below the last bubble.
        let fieldY = app.frame.height - Self.fieldFromBottom
        XCTAssertGreaterThan(fieldY, bubble(3, in: app).frame.maxY, "control: below the newest bubble")
        dragRight(atY: fieldY, in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
    }

    func testOpenActionsDragOnTheHeaderOnlyCloses() {
        let app = launchIntoChat()
        openBubble(2, in: app)
        dragRight(atY: subject(in: app).frame.midY, in: app)
        XCTAssertTrue(isInChat(app), "the chat stays")
        XCTAssertTrue(app.buttons["Move"].waitForNonExistence(timeout: 3), "it only closed the actions")
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

    // MARK: - Helpers

    /// Where the reply field sits, measured up from the screen's bottom: the home indicator's safe
    /// area, then about half the collapsed field.
    private static let fieldFromBottom: CGFloat = 60

    private func launchIntoChat(armRemoval: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--chat-swipe-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Chat swipe fixture"].waitForExistence(timeout: 20))
        if armRemoval { app.buttons["Remove a bubble"].tap() }
        app.buttons["Open chat"].tap()
        XCTAssertTrue(subject(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(bubble(3, in: app).waitForExistence(timeout: 10))
        return app
    }

    private func subject(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Swipe fixture lunch"].firstMatch
    }

    private func bubble(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Note \(index):")).firstMatch
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
        dragLeft(on: bubble(2, in: app), in: app)
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

    private func dragLeft(on element: XCUIElement, in app: XCUIApplication) {
        let dy = element.frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy)))
    }

    private func dragFromEdge(atY y: CGFloat, in app: XCUIApplication) {
        let dy = y / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: dy))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: dy)))
    }
}
