/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

/// The window's keyboard-dismiss tap runs alongside every recognizer (`KeyboardDismissView`), so a
/// tap on a control whose action focuses a text field must still end with that field focused and the
/// keyboard up: the dismiss tap's `endEditing` must never land after the control's focus change.
/// The control here is a reply template's plus button (`TemplateDetailView.addInstruction`).
@MainActor
final class KeyboardFocusRaceUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 15
    private let focusSeconds: TimeInterval = 5
    /// Long enough for a late `endEditing` to have landed.
    private let holdSeconds: TimeInterval = 1

    func testPlusOnATemplateKeepsTheInstructionFieldFocused() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--keyboard-focus-ui-test"]
        app.launch()
        defer { app.terminate() }

        let field = app.textFields["Add instruction..."].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the template opened")
        let plus = app.buttons["Add"].firstMatch
        XCTAssertTrue(plus.exists, "control: the plus button shows")

        // The instruction field already has the keyboard; the plus tap must leave it there.
        let first = "First rule \(UUID().uuidString.prefix(6))"
        field.tap()
        field.typeText(first)
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "control: the instruction field has the keyboard")
        plus.tap()
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: focusSeconds), "control: the plus button added the instruction")
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the field kept the keyboard after the plus tap")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")

        // Another field has the keyboard; the plus tap moves it to the instruction field.
        let second = "Second rule \(UUID().uuidString.prefix(6))"
        field.typeText(second)
        let name = app.textFields["Template name"].firstMatch
        name.tap()
        XCTAssertTrue(waitForFocus(name, timeout: focusSeconds), "control: the name field has the keyboard")
        plus.tap()
        XCTAssertTrue(app.staticTexts[second].waitForExistence(timeout: focusSeconds), "control: the plus button added the second instruction")
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the plus tap gave the instruction field the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
