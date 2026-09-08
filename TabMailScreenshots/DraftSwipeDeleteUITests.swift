/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

@MainActor
final class DraftSwipeDeleteUITests: XCTestCase {
    func testFullSwipeDeletesDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-delete-ui-test"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: 20))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let rowY = row.frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: rowY))
            .press(forDuration: 0.05, thenDragTo:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: rowY)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Archive"].exists)
        app.buttons["Check rows"].tap()
        XCTAssertTrue(app.staticTexts["Draft deleted"].waitForExistence(timeout: 5))
    }
}
