/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

@MainActor
final class ServerDraftCloseUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 15

    func testUnavailableCoverCloses() { checkClose(host: "cover", failure: false) }
    func testFailedCoverClosesAfterRetry() { checkClose(host: "cover", failure: true) }
    func testUnavailablePushCloses() { checkClose(host: "push", failure: false) }
    func testFailedPushClosesAfterRetry() { checkClose(host: "push", failure: true) }
    func testUnavailableDetailCloses() { checkClose(host: "detail", failure: false) }
    func testFailedDetailClosesAfterRetry() { checkClose(host: "detail", failure: true) }

    private func checkClose(host: String, failure: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test"]
        if failure { app.launchArguments.append("--draft-close-failure") }
        app.launch()
        defer { app.terminate() }

        let open = app.buttons["Open \(host)"]
        XCTAssertTrue(open.waitForExistence(timeout: waitSeconds))
        XCTAssertTrue(open.isHittable)
        open.tap()
        let title = app.staticTexts[failure ? "Couldn't open this draft" : "Draft unavailable"]
        XCTAssertTrue(title.waitForExistence(timeout: waitSeconds))
        if failure {
            let retry = app.buttons["Try Again"]
            XCTAssertTrue(retry.isHittable)
            retry.tap()
            XCTAssertTrue(title.waitForExistence(timeout: waitSeconds))
        } else {
            XCTAssertFalse(app.buttons["Try Again"].exists)
        }

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: waitSeconds))
        XCTAssertTrue(close.isHittable)
        close.tap()
        let mailbox = app.buttons["Mailbox ready: 0"]
        let usable = NSPredicate(format: "exists == true AND hittable == true")
        expectation(for: usable, evaluatedWith: mailbox)
        waitForExpectations(timeout: waitSeconds)
        XCTAssertFalse(title.isHittable, "The terminal state must no longer cover the mailbox")
        mailbox.tap()
        XCTAssertTrue(app.buttons["Mailbox ready: 1"].waitForExistence(timeout: waitSeconds))
    }
}
