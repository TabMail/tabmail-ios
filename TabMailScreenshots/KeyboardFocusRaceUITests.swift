/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

/// The window's keyboard-dismiss tap runs alongside every recognizer (`KeyboardDismissView`), so a
/// tap on a control whose action focuses a text field must still end with that field focused and the
/// keyboard up: the dismiss tap's `endEditing` must never land after the control's focus change.
/// The controls: a reply template's plus button, a rejected recipient chip, a bullet list's Add,
/// search opened from its button, and chat's "Fork and re-send" (`KeyboardFocusTestScene`). A tap
/// inside a field that already has the keyboard (to move the caret) must also leave the keyboard up,
/// as must selecting a word and choosing Copy, then Paste, from the edit menu.
@MainActor
final class KeyboardFocusRaceUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 15
    private let focusSeconds: TimeInterval = 5
    /// Long enough for a late `endEditing` to have landed.
    private let holdSeconds: TimeInterval = 1
    /// Where inside a field a caret-moving tap lands, as a fraction of its frame (near the top left).
    private let caretTapOffset: CGFloat = 0.2
    /// Where a word-selecting double tap lands horizontally: on the one typed word, near the start.
    private let wordTapOffset: CGFloat = 0.1
    /// Where the Paste press lands horizontally: past the end of the text, so the caret goes to the end.
    private let endTapOffset: CGFloat = 0.9
    private let pressSeconds: TimeInterval = 1.0
    /// A single-line field's text sits at its vertical middle.
    private let singleLineOffset: CGFloat = 0.5

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

    func testRejectedChipTapPutsItsTextInTheFocusedInput() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-chip")
        defer { app.terminate() }

        let other = app.textFields["Other field"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        let chip = app.descendants(matching: .any)["notanaddress, not an email address"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: waitSeconds), "control: the rejected chip shows")
        other.tap()
        XCTAssertTrue(waitForFocus(other, timeout: focusSeconds), "control: the other field has the keyboard")
        chip.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        let input = app.textFields["recipientInput-to"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: focusSeconds), "control: the recipient input shows")
        XCTAssertEqual(input.value as? String, "notanaddress", "the chip's text is back in the input")
        XCTAssertTrue(waitForFocus(input, timeout: focusSeconds), "the chip tap gave the recipient input the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    func testBulletListAddKeepsTheInputFocused() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-bullet")
        defer { app.terminate() }

        let field = app.textFields["Add item..."].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the list opened")
        let item = "Bullet rule \(UUID().uuidString.prefix(6))"
        field.tap()
        field.typeText(item)
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "control: the input has the keyboard")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[item].waitForExistence(timeout: focusSeconds), "control: Add added the row")
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertNotEqual(field.value as? String, item, "the input was cleared")
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the input kept the keyboard after Add")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    func testSearchOpenedFromItsButtonHasTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-search")
        defer { app.terminate() }

        let other = app.textFields["Other field"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        other.tap()
        XCTAssertTrue(waitForFocus(other, timeout: focusSeconds), "control: the other field has the keyboard")
        app.buttons["Open search"].firstMatch.tap()
        let search = app.textFields["Search emails..."].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: waitSeconds), "control: the search sheet opened")
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(search, timeout: focusSeconds), "the search field has the keyboard once the sheet settles")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    func testForkAndResendKeepsTheFilledInputFocused() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-fork")
        defer { app.terminate() }

        let pill = app.descendants(matching: .any)["chatPill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: waitSeconds), "control: the chat pill shows")
        pill.tap()
        // The first open asks once whether to auto-start dictation.
        let noThanks = app.alerts["Auto-Enable Dictation"].buttons["No Thanks"]
        if noThanks.waitForExistence(timeout: focusSeconds) { noThanks.tap() }
        let pages = app.collectionViews.firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: focusSeconds), "control: the chat pages show")
        let question = "Keyboard focus fixture question"
        let bubble = app.staticTexts[question].firstMatch
        for _ in 0..<3 where !bubble.exists {
            pages.swipeRight()
            _ = bubble.waitForExistence(timeout: focusSeconds)
        }
        XCTAssertTrue(bubble.exists, "control: the past session shows its question")
        bubble.press(forDuration: 1.0)
        let fork = app.buttons["Fork and re-send"].firstMatch
        XCTAssertTrue(fork.waitForExistence(timeout: focusSeconds), "control: the menu offers Fork and re-send")
        fork.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        let input = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND value == %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue, question)).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: focusSeconds), "the input holds the question")
        let marker = app.descendants(matching: .any)["chatReplyFieldFocus"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: focusSeconds), "control: the focus marker shows")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'focused'"), object: marker)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: focusSeconds), .completed, "the input kept the keyboard after the menu closed")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    func testTapInsideAFocusedSingleLineFieldKeepsTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let field = app.textFields["Other field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        tapInsideKeepsTheKeyboard(field, in: app)
    }

    func testTapInsideAFocusedMultiLineFieldKeepsTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            "Multi-line field")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        tapInsideKeepsTheKeyboard(field, in: app)
    }

    /// The dismiss rule itself: a tap on empty space outside every input closes the keyboard.
    func testTapOnEmptySpaceDismissesTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let field = app.textFields["Other field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        let empty = app.descendants(matching: .any)["keyboardFocusEmptyArea"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: waitSeconds), "control: the empty area shows")
        field.tap()
        field.typeText("Dismiss text")
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "control: the field has the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: focusSeconds), "control: the keyboard is up")
        empty.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: focusSeconds), .completed, "the tap outside closed the keyboard")
        let unfocused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == false"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [unfocused], timeout: focusSeconds), .completed, "and the field lost focus")
    }

    func testSelectCopyPasteInAFocusedSingleLineFieldKeepsTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let field = app.textFields["Other field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        selectCopyPasteKeepsTheKeyboard(field, lineOffset: singleLineOffset, in: app)
    }

    func testSelectCopyPasteInAFocusedMultiLineFieldKeepsTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            "Multi-line field")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        selectCopyPasteKeepsTheKeyboard(field, lineOffset: caretTapOffset, in: app)
    }

    func testSelectCopyPasteInAFocusedTextEditorKeepsTheKeyboard() {
        continueAfterFailure = false
        let app = launch("--keyboard-focus-caret")
        defer { app.terminate() }

        let editor = app.textViews["keyboardFocusTextEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: waitSeconds), "control: the fixture opened")
        selectCopyPasteKeepsTheKeyboard(editor, lineOffset: caretTapOffset, in: app)
    }

    /// Focuses `field` and types one word; double taps the word to select it, chooses Copy from the edit
    /// menu, presses at the end of the text and chooses Paste. The selection (Copy offered) and the
    /// pasted word (now there twice) are the controls; the field must keep the keyboard after each step.
    /// `lineOffset` is the vertical fraction of the field's frame where its first line sits.
    /// XCUITest has no API for a selection handle, so a handle drag is not exercised here.
    private func selectCopyPasteKeepsTheKeyboard(_ field: XCUIElement, lineOffset: CGFloat, in app: XCUIApplication) {
        let word = "Selectword\(String(UUID().uuidString.filter(\.isLetter).prefix(6)).lowercased())"
        field.tap()
        field.typeText(word)
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "control: the field has the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: focusSeconds), "control: the keyboard is up")

        field.coordinate(withNormalizedOffset: CGVector(dx: wordTapOffset, dy: lineOffset)).doubleTap()
        let copy = editMenuItem("Copy", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: focusSeconds), "control: the double tap selected the word (Copy offered)")
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the field kept focus after selecting a word")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up after selecting")

        copy.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the field kept focus after Copy")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up after Copy")

        field.coordinate(withNormalizedOffset: CGVector(dx: endTapOffset, dy: lineOffset)).press(forDuration: pressSeconds)
        let paste = editMenuItem("Paste", in: app)
        XCTAssertTrue(paste.waitForExistence(timeout: focusSeconds), "control: the press offered Paste")
        paste.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        let value = field.value as? String ?? ""
        XCTAssertEqual(value.components(separatedBy: word).count - 1, 2, "control: Paste put the copied word in again")
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the field kept focus after Paste")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up after Paste")
    }

    /// An edit-menu command by its visible title; the menu shows it as a menu item or a button.
    private func editMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label == %@",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue, title)).firstMatch
    }

    /// Focuses `field`, types into it, then taps inside it away from the caret, as a user moving the
    /// caret does; the field must keep the keyboard.
    private func tapInsideKeepsTheKeyboard(_ field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        field.typeText("Caret text \(UUID().uuidString.prefix(6))")
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "control: the field has the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: focusSeconds), "control: the keyboard is up")
        // Near the start of the text, away from the caret at its end.
        field.coordinate(withNormalizedOffset: CGVector(dx: caretTapOffset, dy: caretTapOffset)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(holdSeconds))
        XCTAssertTrue(waitForFocus(field, timeout: focusSeconds), "the field kept focus after a tap inside it")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "and the keyboard is up")
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--keyboard-focus-ui-test", mode]
        app.launch()
        return app
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
