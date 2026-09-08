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

    private func checkDelete(thread: Bool = false, expand: Bool = false,
                             child: Bool = false, triage: Bool = false, expected: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-delete-ui-test"]
        if thread { app.launchArguments.append("--draft-delete-thread") }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: 20))
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
    }

    private func fullSwipe(_ row: XCUIElement, in app: XCUIApplication) {
        let y = row.frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: y))
            .press(forDuration: 0.05, thenDragTo:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: y)))
    }
}
