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

/// #309: which draft open the user sees, and what an early Close keeps.
@MainActor
final class DraftOpenOrderUITests: XCTestCase {
    private let waitSeconds: TimeInterval = 20

    /// A Drafts-row open still preparing when a pushed draft opens must not
    /// present over it when it finally ends.
    func testANewerOpenIsNotCoveredByAnOlderOne() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        row.tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds))
        app.buttons["Open push"].tap()
        let newer = app.staticTexts["Couldn't open this draft"]
        XCTAssertTrue(newer.waitForExistence(timeout: waitSeconds), "the newer open presented its card")
        // The older open ends (with no local copy) a few seconds later.
        let older = app.staticTexts["Draft unavailable"]
        let olderShown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: older)
        XCTAssertNotEqual(XCTWaiter.wait(for: [olderShown], timeout: waitSeconds), .completed,
                          "the older open presented over the newer one")
        XCTAssertTrue(newer.isHittable)
    }

    /// A tapped Drafts row shows it is opening, in either list layout.
    func testATappedDraftRowShowsItIsOpening() { checkBusyMark(triage: false) }
    func testATappedTriageDraftRowShowsItIsOpening() { checkBusyMark(triage: true) }

    private func checkBusyMark(triage: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        if triage {
            // The fixture's controls overlap the left of this toolbar button.
            app.buttons["Switch to triage"].coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Switch to list"].waitForExistence(timeout: waitSeconds),
                          "precondition: the list is in triage mode")
        }
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        row.tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds),
                      "precondition: the open is being prepared")
        XCTAssertTrue(row.isHittable, "the list stays on screen while the draft is prepared")
        let mark = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Opening draft")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: waitSeconds), "the tapped row shows no busy mark")
        XCTAssertTrue(mark.isHittable, "the busy mark is not on the visible list")
    }

    /// A draft opened from a chat's email pill keeps the previous screen until it
    /// is prepared, then opens.
    func testAPillOpenKeepsThePreviousScreenUntilPrepared() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        app.buttons["Open push"].tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds),
                      "precondition: the pill's draft is being prepared")
        XCTAssertTrue(row.isHittable, "the pill left the previous screen before the draft was prepared")
        // The fixture's first open ends after its hold with no local copy.
        XCTAssertTrue(app.staticTexts["Draft unavailable"].waitForExistence(timeout: waitSeconds),
                      "the pill's draft never opened")
    }

    /// A visit to the account screen, made and left while a Drafts-row open is
    /// still preparing, is newer than it: the older open must not present afterwards.
    func testAnAccountVisitIsNotCoveredByAnOlderOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        let began = Date()
        row.tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds))
        app.buttons["Open account"].tap()
        let account = app.navigationBars["TabMail Account"]
        XCTAssertTrue(account.waitForExistence(timeout: waitSeconds), "the account screen opened")
        account.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Drafts"].waitForExistence(timeout: waitSeconds), "back from the account")
        // The fixture holds the older open for 12 seconds.
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "precondition: the older open is still preparing")
        let older = app.staticTexts["Draft unavailable"]
        let olderShown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: older)
        XCTAssertNotEqual(XCTWaiter.wait(for: [olderShown], timeout: waitSeconds), .completed,
                          "the older open presented after the account visit")
    }

    /// Back out of a screen, taken while a chat pill's draft is still being
    /// prepared, is newer than that open: the draft must not open over the list
    /// Back returned to.
    func testBackFromAPillsMessageIsNotCoveredByAnOlderOpen() { checkBack(from: "Open message", to: "All Drafts") }
    func testBackFromANotificationsMessageIsNotCoveredByAnOlderOpen() {
        checkBack(from: "Open notification", to: "All Inboxes")
    }
    func testBackFromTheAccountIsNotCoveredByAnOlderOpen() { checkBack(from: "Open account", to: "All Drafts") }

    private func checkBack(from screen: String, to list: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering", "--draft-open-navigation"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        app.buttons[screen].tap()
        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Back", list)).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: waitSeconds), "precondition: the screen was pushed")
        let began = Date()
        app.buttons["Open push"].tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds),
                      "precondition: the pill's draft is being prepared")
        XCTAssertTrue(back.isHittable, "precondition: the screen stays while the draft is prepared")
        back.tap()
        XCTAssertTrue(app.navigationBars[list].waitForExistence(timeout: waitSeconds), "Back returned to the list")
        // The fixture holds the pill's open for 12 seconds, then ends it with no local copy.
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "precondition: the draft is still being prepared")
        let older = app.staticTexts["Draft unavailable"]
        let olderShown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: older)
        XCTAssertNotEqual(XCTWaiter.wait(for: [olderShown], timeout: waitSeconds), .completed,
                          "the draft opened over the list Back returned to")
        XCTAssertTrue(app.navigationBars[list].isHittable, "Back did not return to the list")
    }

    /// Another screen chosen while a chat pill's draft is still being prepared is
    /// newer than that open: the draft must not open over it.
    func testAnotherScreenIsNotCoveredByAnOlderOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering", "--draft-open-navigation"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let began = Date()
        app.buttons["Open push"].tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds),
                      "precondition: the pill's draft is being prepared")
        app.buttons["Open settings"].tap()
        let settings = app.navigationBars["Email Accounts"]
        XCTAssertTrue(settings.waitForExistence(timeout: waitSeconds), "precondition: the other screen opened")
        // The fixture holds the pill's open for 12 seconds, then ends it with no local copy.
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "precondition: the draft is still being prepared")
        let older = app.staticTexts["Draft unavailable"]
        let olderShown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: older)
        XCTAssertNotEqual(XCTWaiter.wait(for: [olderShown], timeout: waitSeconds), .completed,
                          "the draft opened over the screen chosen after it")
        XCTAssertTrue(settings.isHittable, "the other screen is no longer usable")
    }

    /// A new compose opened, and closed, while a Drafts-row open is still
    /// preparing is newer than it: the older open must not present afterwards.
    func testANewComposeIsNotCoveredByAnOlderOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-close-ui-test", "--draft-open-ordering"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture ready"].waitForExistence(timeout: waitSeconds))
        let row = app.staticTexts["Draft close fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: waitSeconds))
        let began = Date()
        row.tap()
        XCTAssertTrue(app.staticTexts["Resolution attempts: 1"].waitForExistence(timeout: waitSeconds))
        app.buttons["Compose"].firstMatch.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: waitSeconds), "the new compose opened")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: waitSeconds), "the new compose closed")
        // The fixture holds the older open for 12 seconds.
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "precondition: the older open is still preparing")
        XCTAssertFalse(app.staticTexts["Draft unavailable"].waitForExistence(timeout: waitSeconds),
                       "the older open presented after the newer compose")
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
        XCTAssertTrue(compose.waitForExistence(timeout: waitSeconds), "the button's busy mark ended with the open")

        app.buttons["Agent finished"].tap()
        let toast = app.staticTexts["Agent draft ready"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: waitSeconds))
        toast.tap()
        XCTAssertTrue(subject.waitForExistence(timeout: waitSeconds), "the toast opened the agent's draft")
    }

    /// A draft that changed while it was opening offers Try Again, and trying
    /// again opens it filled.
    func testAChangedDraftOpensOnTryAgain() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-splash", "--draft-open-early-close", "--draft-open-changed-while-opening"]
        app.launch()
        defer { app.terminate() }
        let message = app.staticTexts["This draft changed while it was opening. Please try again."]
        XCTAssertTrue(message.waitForExistence(timeout: waitSeconds), "the changed draft's card")
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: waitSeconds), "the changed draft's card offers no Try Again")
        retry.tap()
        XCTAssertTrue(app.staticTexts["initial=held"].firstMatch.waitForExistence(timeout: waitSeconds),
                      "Try Again did not open the draft")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Ready before inner load")).firstMatch.exists,
                      "the reopened compose lacks the subject")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Keep this local attachment")).firstMatch.exists,
                      "the reopened compose lacks the body")
        XCTAssertFalse(message.exists)
        guard let release = app.buttons.matching(identifier: "Release initial read").allElementsBoundByIndex
            .first(where: { $0.isHittable }) else {
            XCTFail("No hittable button: Release initial read")
            return
        }
        release.tap()
        XCTAssertTrue(app.staticTexts["initial=released"].firstMatch.waitForExistence(timeout: waitSeconds))
    }

    /// A prepared draft's compose shows the draft before it has read the row, and
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
