/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

@MainActor
final class DraftSwipeDeleteUITests: XCTestCase {
    func testFullSwipeDeletesDraft() {
        checkDelete(expected: "bystander")
    }

    func testCollapsedThreadDeletesBothDrafts() {
        checkDelete(thread: true, expected: "bystander")
    }

    func testExpandedRepresentativeDeletesOnlyThatDraft() {
        checkDelete(thread: true, expand: true, expected: "bystander,child")
    }

    func testExpandedChildDeletesOnlyThatDraft() {
        checkDelete(thread: true, expand: true, child: true, expected: "bystander,target")
    }

    func testTriageDeletesOnlyThatDraft() {
        checkDelete(triage: true, expected: "bystander")
    }

    // MARK: - #147 — a refused Drafts deletion is explained, once per gesture

    func testRefusedSingleDeleteRestoresRowAndShowsNoticeUntilTapped() {
        let app = launch(refused: true)
        defer { app.terminate() }
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        fullSwipe(row, in: app)
        let notice = app.buttons[Self.noticeIdentifier]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: Self.noticeIdentifier).count, 1)
        // Tapping the notice dismisses it (before its own timer would).
        notice.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        waitForExpectations(timeout: 5)
        // The row is back, and the draft rows are untouched.
        XCTAssertTrue(app.staticTexts["Draft close fixture"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Check rows"].tap()
        XCTAssertTrue(app.staticTexts["Remaining: bystander,target"].waitForExistence(timeout: 5))
    }

    func testRefusedThreadDeleteShowsOneNoticeThatAutoDismisses() {
        let app = launch(thread: true, refused: true)
        defer { app.terminate() }
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        fullSwipe(row, in: app)
        let notice = app.buttons[Self.noticeIdentifier]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        // Two refused members, ONE notice for the gesture.
        XCTAssertEqual(app.buttons.matching(identifier: Self.noticeIdentifier).count, 1)
        app.buttons["Check rows"].tap()
        XCTAssertTrue(app.staticTexts["Remaining: bystander,child,target"].waitForExistence(timeout: 5))
        // Untouched, it dismisses itself.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        waitForExpectations(timeout: 10)
    }

    private static let noticeIdentifier = "draft-delete-refused-notice"

    private func checkDelete(thread: Bool = false, expand: Bool = false,
                             child: Bool = false, triage: Bool = false, expected: String) {
        let app = launch(thread: thread)
        defer { app.terminate() }
        let representative = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(representative.waitForExistence(timeout: 10))
        if expand {
            // The thread toggle is the trailing circular chevron on the sender line.
            let y = (representative.frame.minY - 13) / app.frame.height
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: y)).tap()
            XCTAssertTrue(app.staticTexts["Draft child"].firstMatch.waitForExistence(timeout: 5))
        }
        if triage {
            app.buttons["Switch to triage"].tap()
            XCTAssertTrue(app.buttons["Switch to list"].waitForExistence(timeout: 5))
        }
        let row = app.staticTexts[child ? "Draft child" : "Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        fullSwipe(row, in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Archive"].exists)
        app.buttons["Check rows"].tap()
        XCTAssertTrue(app.staticTexts["Remaining: \(expected)"].waitForExistence(timeout: 5))
        // A successful deletion never shows the refusal notice (#147).
        XCTAssertFalse(app.buttons[Self.noticeIdentifier].exists)
    }

    private func launch(thread: Bool = false, refused: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-delete-ui-test"]
        if thread { app.launchArguments.append("--draft-delete-thread") }
        if refused { app.launchArguments.append("--draft-delete-refused") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: 20))
        return app
    }

    private func fullSwipe(_ row: XCUIElement, in app: XCUIApplication) {
        let y = row.frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: y))
            .press(forDuration: 0.05, thenDragTo:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: y)))
    }
}
