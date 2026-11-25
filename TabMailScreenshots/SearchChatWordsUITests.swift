/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

/// iOS #979 through the real Search route (`--search-chat-words-ui-test`): words typed in the reply
/// field of a chat opened from a Search result, then left by Back and Search's Done (Search cannot
/// be swiped down), are in the field when the same chat is opened from Search again.
@MainActor
final class SearchChatWordsUITests: XCTestCase {
    private static let subject = "Search words fixture picnic"
    private static let query = "picnic"
    private static let replyPlaceholder = "Sign in to reply"
    private static let words = "Count me in for Saturday"

    func testWordsTypedInAChatOpenedFromSearchSurviveClosingSearch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--search-chat-words-ui-test"]
        app.launch()

        openChatFromSearch(in: app)
        let field = replyField(in: app)
        XCTAssertEqual(text(of: field), "", "control: the field starts empty")
        field.tap()
        field.typeText(Self.words)
        XCTAssertEqual(text(of: field), Self.words, "control: the words reached the field")

        // Leave the chat and close Search through its own close path.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "control: the chat has Back")
        back.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "control: Search's root shows Done")
        done.tap()
        XCTAssertTrue(app.buttons["Show search"].waitForExistence(timeout: 10), "control: Search closed")
        XCTAssertFalse(app.buttons["Done"].exists, "control: no Search sheet is left")

        openChatFromSearch(in: app)
        let again = replyField(in: app)
        XCTAssertEqual(text(of: again), Self.words, "the words the user typed are in the field again")
    }

    /// Opens Search from the fixture's root, searches for the fixture email and taps its result.
    private func openChatFromSearch(in app: XCUIApplication) {
        let show = app.buttons["Show search"]
        XCTAssertTrue(show.waitForExistence(timeout: 20), "control: the fixture is ready")
        show.tap()
        let search = app.textFields["Search emails..."]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "control: Search is up")
        search.tap()
        search.typeText(Self.query)
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", Self.subject)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "control: the email is a result")
        result.tap()
    }

    /// The chat's reply field: by its placeholder while it is empty, by the test's words once it
    /// holds them (a multi-line field reports no placeholder while it has text). Every access
    /// queries again, so the one query has to match the field both ways.
    private func replyField(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (placeholderValue == %@ OR value == %@)",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            Self.replyPlaceholder, Self.words)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "control: the chat's reply field, found by its placeholder or the words")
        return field
    }

    /// The words the field shows: its value, or "" while it shows only its placeholder.
    private func text(of field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == Self.replyPlaceholder ? "" : value
    }
}
