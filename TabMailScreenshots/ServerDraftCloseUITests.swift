/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

@MainActor
final class ServerDraftCloseUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 15

    func testUnavailableCoverCloses() { checkClose(host: "cover", failure: false) }
    func testFailedCoverClosesAfterRetry() { checkClose(host: "cover", failure: true) }
    func testRefusedCoverCloses() { checkClose(host: "cover", failure: false, refused: true) }
    func testUnavailablePushCloses() { checkClose(host: "push", failure: false) }
    func testFailedPushClosesAfterRetry() { checkClose(host: "push", failure: true) }
    func testRefusedPushCloses() { checkClose(host: "push", failure: false, refused: true) }
    func testUnavailableDetailCloses() { checkClose(host: "detail", failure: false) }
    func testFailedDetailClosesAfterRetry() { checkClose(host: "detail", failure: true) }
    func testRefusedDetailCloses() { checkClose(host: "detail", failure: false, refused: true) }

    /// A saved draft selected into the detail column opens there, filled from
    /// its first frame, with no failure card.
    func testADraftOpensFilledInTheDetailColumn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-detail-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        app.buttons["Open detail"].tap()
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Detail ready draft")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "the detail column opened the draft")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Detail ready body")).firstMatch.exists)
        XCTAssertEqual(app.textFields["recipientInput-to"].firstMatch.label, "detail-to@example.com")
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].exists)
        XCTAssertFalse(app.staticTexts["Draft unavailable"].exists)
        XCTAssertFalse(app.staticTexts["Couldn't open this draft"].exists)
    }

    /// `refused`: the draft holds an attachment TabMail cannot carry (#241). Its
    /// card is final (no Retry) and must still close.
    private func checkClose(host: String, failure: Bool, refused: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test"]
        if failure { app.launchArguments.append("--draft-close-failure") }
        if refused { app.launchArguments.append("--draft-close-unsupported") }
        let kind = failure ? "failed" : refused ? "refused" : "unavailable"
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
            // The refusal card says why, which the unavailable card shares no text with.
            let refusal = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "attachment TabMail can't open")).firstMatch
            XCTAssertEqual(refusal.waitForExistence(timeout: refused ? waitSeconds : 0), refused)
            if failure && cycle == 1 {
                let retry = app.buttons["Try Again"]
                XCTAssertTrue(retry.isHittable)
                retry.tap()
                // The fixture counts actual dependency calls, so an inert Retry
                // cannot pass merely because the old error title remains visible.
                XCTAssertTrue(title.waitForExistence(timeout: waitSeconds))
            } else if !failure {
                XCTAssertFalse(app.buttons["Try Again"].exists)
            }
            let close = app.buttons["server-draft-close"]
            XCTAssertTrue(close.waitForExistence(timeout: waitSeconds))
            XCTAssertTrue(close.isHittable)
            if cycle == 1 { capture(app, name: "\(host)-\(kind)-before-close") }
            close.tap()
            let mailbox = app.navigationBars[host == "detail" ? "All Inboxes" : "All Drafts"]
            expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: mailbox)
            waitForExpectations(timeout: waitSeconds)
            XCTAssertFalse(title.isHittable, "The terminal state must no longer cover the real mailbox")
            if cycle == 1 {
                XCTAssertTrue(app.staticTexts["Resolution attempts: \(failure ? 2 : 1)"].waitForExistence(timeout: waitSeconds))
            }
            app.buttons["Check rows"].tap()
            XCTAssertTrue(app.staticTexts["Rows preserved"].waitForExistence(timeout: waitSeconds))
            if cycle == 1 { capture(app, name: "\(host)-\(kind)-after-close") }
            // Opening the same message again proves the owner can present after
            // dismissal. A split-view detail may reuse its existing resolved
            // view, so a fresh dependency read is not required on that reopen.
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// #309, #326: how a saved draft opens, and what an early Close keeps.
@MainActor
final class DraftOpenUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 20
    /// The fixture's hold on every open (`--draft-open-held`).
    private let heldSeconds: TimeInterval = 8

    /// A tapped draft opens its compose cover at once, with a spinner and no
    /// fields while the draft is read, then shows the draft filled; from the
    /// Drafts list in either layout, a chat pill and the detail column.
    func testADraftRowOpensAtOnceWithASpinner() { checkOpensAtOnce(from: "row") }
    func testATriageDraftRowOpensAtOnceWithASpinner() { checkOpensAtOnce(from: "triage") }
    func testAPillsDraftOpensAtOnceWithASpinner() { checkOpensAtOnce(from: "push") }
    func testADetailDraftOpensAtOnceWithASpinner() { checkOpensAtOnce(from: "detail") }

    private func checkOpensAtOnce(from place: String) {
        continueAfterFailure = false
        let app = launchHeld()
        defer { app.terminate() }
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        if place == "triage" {
            // The fixture's controls overlap the left of this toolbar button.
            app.buttons["Switch to triage"].coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Switch to list"].waitForExistence(timeout: waitSeconds),
                          "precondition: the list is in triage mode")
        }
        let began = Date()
        if place == "row" || place == "triage" {
            row.tap()
        } else {
            app.buttons["Open \(place)"].tap()
        }
        let spinner = openingSpinner(app)
        XCTAssertTrue(spinner.waitForExistence(timeout: waitSeconds), "the compose did not open with a spinner")
        // The cover slides up; once it is up its Close takes taps and the spinner is inside the window.
        let close = app.buttons["Close"].firstMatch
        let up = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [up], timeout: waitSeconds), .completed, "the opening compose is not on screen")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(spinner.frame), "the spinner is not on screen")
        XCTAssertLessThan(Date().timeIntervalSince(began), heldSeconds,
                          "the compose opened only once the draft was read")
        // No compose fields yet: an empty, editable compose is the blank the open must not show.
        XCTAssertFalse(app.staticTexts["Subject:"].exists, "an empty compose showed while the draft was read")
        XCTAssertFalse(app.buttons["Send"].exists, "an empty compose showed while the draft was read")
        if place != "detail" {
            XCTAssertFalse(row.isHittable, "the list, not the compose, is on screen while the draft is read")
        }
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Detail ready draft")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "the draft never opened")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Detail ready body")).firstMatch.exists,
                      "the opened compose lacks the body")
        XCTAssertFalse(spinner.exists, "the spinner stayed over the opened draft")
    }

    /// Close while the draft is read returns to the list, and the open shows
    /// nothing when the read ends.
    func testClosingWhileADraftOpensReturnsToTheList() {
        continueAfterFailure = false
        let app = launchHeld()
        defer { app.terminate() }
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        let began = Date()
        row.tap()
        let spinner = openingSpinner(app)
        XCTAssertTrue(spinner.waitForExistence(timeout: waitSeconds))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(spinner.waitForNonExistence(timeout: waitSeconds), "Close left the opening compose up")
        XCTAssertLessThan(Date().timeIntervalSince(began), heldSeconds, "precondition: closed while the draft was read")
        XCTAssertTrue(row.isHittable, "Close did not return to the list")
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Detail ready draft")).firstMatch
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: subject)
        XCTAssertNotEqual(XCTWaiter.wait(for: [opened], timeout: heldSeconds + 4), .completed,
                          "the closed open showed the draft when its read ended")
        XCTAssertFalse(app.staticTexts["Couldn't open this draft"].exists, "the closed open showed a card")
        XCTAssertTrue(row.isHittable)
    }

    /// A failed open offers Try Again, which opens the draft filled.
    func testTryAgainOpensTheDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-retry"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        row.tap()
        XCTAssertTrue(app.staticTexts["Couldn't open this draft"].waitForExistence(timeout: waitSeconds))
        app.buttons["Try Again"].tap()
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Detail ready draft")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "Try Again did not open the draft")
        XCTAssertFalse(app.staticTexts["Couldn't open this draft"].exists)
    }

    private func launchHeld() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-held"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        return app
    }

    private func openingSpinner(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Opening draft")).firstMatch
    }

    /// The compose button opens the draft a compose agent is working on, and the
    /// agent's finished toast opens it too, each already filled.
    func testTheAgentsDraftOpensFromTheButtonAndTheToast() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-agent"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Agent working draft")).firstMatch
        let compose = app.buttons["Compose"].firstMatch

        app.buttons["Agent working"].tap()
        XCTAssertTrue(compose.waitForExistence(timeout: waitSeconds))
        compose.tap()
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "the button opened the agent's draft")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(subject.waitForNonExistence(timeout: waitSeconds))
        XCTAssertTrue(compose.waitForExistence(timeout: waitSeconds), "the button is back after the compose closed")

        app.buttons["Agent finished"].tap()
        let toast = app.staticTexts["Agent draft ready"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: waitSeconds))
        toast.tap()
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "the toast opened the agent's draft")
    }

    /// A draft's compose shows the draft before it has read the row, and
    /// closing it then leaves the saved draft, its attachment included, exactly
    /// as it was.
    func testClosingBeforeTheDraftLoadsKeepsItAsSaved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-open-early-close"]
        app.launch()
        defer { app.terminate() }
        func tap(_ label: String) {
            guard let button = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .first(where: { $0.isHittable }) else {
                XCTFail("No hittable button: \(label)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(app.staticTexts["initial=held"].firstMatch.waitForExistence(timeout: waitSeconds))
        // The compose shows the draft from its first frame, and takes no edits until it has loaded.
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Ready before inner load")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds))
        XCTAssertFalse(subject.isEnabled, "an edit now would be saved without the draft's attachment")
        // Held before it has read the row, the compose still shows the draft it opened with.
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Keep this local attachment")).firstMatch.exists,
                      "the held compose lacks the body")
        XCTAssertFalse(app.staticTexts["kept.txt"].exists, "precondition: the attachment is not loaded yet")
        // Each recipient is already in its own field (debug builds label a field's
        // input with its addresses; the read-only form hides the chips themselves).
        for (role, address) in [("to", "to-person@example.com"), ("cc", "cc-person@example.com"),
                                ("bcc", "bcc-person@example.com")] {
            let input = app.textFields["recipientInput-\(role)"].firstMatch
            XCTAssertTrue(input.exists, "the held compose shows no \(role) field")
            XCTAssertEqual(input.label, address, "the held compose's \(role) field")
        }
        // Nothing can be added either: Close would drop it, and the load would replace it.
        let attach = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'attach'")).firstMatch
        XCTAssertTrue(attach.exists)
        XCTAssertFalse(attach.isEnabled, "an attachment added now is lost")
        // Send does nothing until the draft has loaded.
        tap("Send")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "Send answered before the draft loaded")
        XCTAssertTrue(subject.exists, "Send closed the compose before the draft loaded")

        tap("Close")
        XCTAssertFalse(app.alerts["Save Draft?"].waitForExistence(timeout: 2),
                       "nothing was edited, so Close offers no save")
        XCTAssertTrue(subject.waitForNonExistence(timeout: waitSeconds), "Close dismissed the compose")

        tap("Release initial read")
        XCTAssertTrue(app.staticTexts["initial=released"].firstMatch.waitForExistence(timeout: waitSeconds))
        tap("Inspect saved draft")
        XCTAssertTrue(app.staticTexts["Saved draft unchanged"].firstMatch.waitForExistence(timeout: waitSeconds))
    }

    /// Before an empty-bodied draft has loaded, Send asks nothing and the chat
    /// takes no edit.
    func testAnEmptyDraftTakesNothingBeforeItLoads() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-open-early-close", "--draft-open-early-close-empty-body"]
        app.launch()
        defer { app.terminate() }
        func tap(_ label: String) {
            guard let button = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .first(where: { $0.isHittable }) else {
                XCTFail("No hittable button: \(label)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(app.staticTexts["initial=held"].firstMatch.waitForExistence(timeout: waitSeconds))
        let subject = app.textFields.matching(NSPredicate(format: "value == %@", "Ready before inner load")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds))
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.isEnabled, "precondition: the saved To and subject enable Send")
        tap("Send")
        XCTAssertFalse(app.alerts["Empty Body"].waitForExistence(timeout: 2), "Send asked about the body before the draft loaded")
        XCTAssertTrue(subject.exists)

        // Nor can the chat edit it: an edit admitted now could save without the
        // draft's attachment. Once the draft has loaded, the same edit is offered.
        XCTAssertTrue(app.staticTexts["subscription=active"].firstMatch.exists, "precondition: the chat offers edits")
        app.buttons["chatPill"].firstMatch.tap()
        let instruction = app.textFields["Describe your edit..."].firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: waitSeconds))
        instruction.tap()
        instruction.typeText("Shorter")
        let chatSend = app.buttons["chatSend"].firstMatch
        XCTAssertTrue(chatSend.exists)
        XCTAssertFalse(chatSend.isEnabled, "the chat took an edit before the draft loaded")
        tap("Release initial read")
        XCTAssertTrue(app.staticTexts["initial=released"].firstMatch.waitForExistence(timeout: waitSeconds))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: chatSend)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: waitSeconds), .completed,
                       "the loaded draft takes the chat's edit")
    }
}
