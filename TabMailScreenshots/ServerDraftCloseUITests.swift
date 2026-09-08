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

        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        for cycle in 1...2 {
            if host == "cover" {
                let row = app.staticTexts["Draft close fixture"].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
                XCTAssertTrue(row.isHittable)
                row.tap()
            } else {
                app.buttons["Open \(host)"].tap()
            }
            let title = app.staticTexts[failure ? "Couldn't open this draft" : "Draft unavailable"]
            XCTAssertTrue(title.waitForExistence(timeout: waitSeconds))
            if failure {
                let retry = app.buttons["Try Again"]
                XCTAssertTrue(retry.isHittable)
                retry.tap()
                // The fixture counts actual dependency calls, so an inert Retry
                // cannot pass merely because the old error title remains visible.
                XCTAssertTrue(title.waitForExistence(timeout: waitSeconds))
            } else {
                XCTAssertFalse(app.buttons["Try Again"].exists)
            }
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: waitSeconds))
            XCTAssertTrue(close.isHittable)
            if cycle == 1 { capture(app, name: "\(host)-\(failure ? "failed" : "unavailable")-before-close") }
            close.tap()
            let mailbox = app.navigationBars[host == "detail" ? "Inbox" : "Drafts"]
            expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: mailbox)
            waitForExpectations(timeout: waitSeconds)
            XCTAssertFalse(title.isHittable, "The terminal state must no longer cover the real mailbox")
            XCTAssertTrue(app.staticTexts["Resolution attempts: \(cycle * (failure ? 2 : 1))"].waitForExistence(timeout: waitSeconds))
            app.buttons["Check rows"].tap()
            XCTAssertTrue(app.staticTexts["Rows preserved"].waitForExistence(timeout: waitSeconds))
            if cycle == 1 { capture(app, name: "\(host)-\(failure ? "failed" : "unavailable")-after-close") }
            // Opening the same message a second time exercises presentation-owner
            // reset as well as actual mailbox navigation after dismissal.
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
