/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import XCTest

@MainActor
final class TabMailScreenshots: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Launch the app with given arguments.
    /// SnapshotHelper's `setupSnapshot` appends Fastlane's `launch_arguments`
    /// (e.g. `--screenshot-dark`) from the snapshot-launch_arguments.txt cache file.
    private func launchApp(arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        setupSnapshot(app)
        app.launch()
    }

    // MARK: - Helpers

    /// Poll until an element is hittable (visible and interactable), up to `timeout` seconds.
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists && element.isHittable
    }

    /// Navigate from sidebar to inbox by tapping the first mailbox cell.
    private func navigateToInbox() {
        let mailboxesTitle = app.staticTexts["Mailboxes"]
        if mailboxesTitle.waitForExistence(timeout: 10) {
            let firstCell = app.cells.element(boundBy: 0)
            if firstCell.waitForExistence(timeout: 5) {
                firstCell.tap()
            }
        }
        Thread.sleep(forTimeInterval: 3)
    }

    /// Navigate back to the sidebar from wherever we are.
    private func navigateToSidebar() {
        // Tap back buttons until we see "Mailboxes" or run out of nav buttons
        for _ in 0..<5 {
            let mailboxes = app.staticTexts["Mailboxes"]
            if mailboxes.waitForExistence(timeout: 1) {
                return // We're at the sidebar
            }
            let backBtn = app.navigationBars.buttons.firstMatch
            if backBtn.waitForExistence(timeout: 1) {
                backBtn.tap()
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Scroll the plan picker all the way down so the full Apple disclosure +
    /// Terms/Privacy links are visible. One fixed swipe is not enough since the
    /// Zero card + cost-note footnote lengthened the page; anchor on the
    /// "Restore Purchases" button — the last element in the scroll content.
    private func scrollPlanPickerToBottom() {
        let restoreButton = app.buttons["Restore Purchases"]
        for _ in 0..<8 {
            if restoreButton.exists && restoreButton.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// Scroll the plan picker back to the top (Monthly/Yearly toggle visible).
    private func scrollPlanPickerToTop() {
        let monthlyTab = app.buttons["Monthly"]
        for _ in 0..<8 {
            if monthlyTab.exists && monthlyTab.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - 01. Splash / Login Screen
    // Named test00 so it runs BEFORE other tests (alphabetical order).
    // Erase simulator ensures no persisted data.

    func test00_SplashScreenshot() {
        launchApp(arguments: ["--screenshot-splash"])

        Thread.sleep(forTimeInterval: 3)
        snapshot("01_Splash")
    }

    // MARK: - 02–06. Main App Flow (inbox → detail → compose)

    func test01_MainFlow() {
        launchApp(arguments: ["--screenshot-mode"])

        navigateToInbox()

        // 02. Inbox — hero screenshot showing triage tags + chat pill
        snapshot("02_Inbox")

        // 03. Agent Chat (inbox) — calendar scheduling conversation + reminders
        let chatPill = app.buttons["chatPill"]
        if chatPill.waitForExistence(timeout: 3) {
            chatPill.tap()
            // Wait for chat to fully expand and render messages
            let closeBtn = app.buttons["chatClose"]
            _ = closeBtn.waitForExistence(timeout: 5)
            Thread.sleep(forTimeInterval: 3)
            snapshot("03_AgentChat")

            if closeBtn.exists {
                closeBtn.tap()
            }
            Thread.sleep(forTimeInterval: 3)
        }

        // 04. Message Detail — tap first message for AI summary + body
        let firstMessage = app.cells.firstMatch
        if firstMessage.waitForExistence(timeout: 3) {
            firstMessage.tap()
            // Wait longer for WebView body to render (Pro Max needs extra time)
            Thread.sleep(forTimeInterval: 8)
            snapshot("04_MessageDetail")

            // 05. Agent Chat (detail) — contextual chat from message detail
            let detailChatPill = app.buttons["chatPill"]
            if detailChatPill.waitForExistence(timeout: 3) {
                detailChatPill.tap()
                let detailClose = app.buttons["chatClose"]
                _ = detailClose.waitForExistence(timeout: 5)
                Thread.sleep(forTimeInterval: 3)
                snapshot("05_ChatFromDetail")

                if detailClose.exists {
                    detailClose.tap()
                }
                // Extra wait for chat collapse animation to fully complete
                Thread.sleep(forTimeInterval: 5)
            }

            // 06. Compose Reply — tap reply menu, select Reply for AI suggestion bubble
            let replyMenu = app.buttons["replyMenu"]
            if replyMenu.waitForExistence(timeout: 10) {
                replyMenu.tap()
                Thread.sleep(forTimeInterval: 2)

                Thread.sleep(forTimeInterval: 2)

                // Try every possible query
                var menuReplyButton = app.collectionViews.buttons["Reply"].firstMatch
                if !menuReplyButton.waitForExistence(timeout: 1) {
                    menuReplyButton = app.menuItems["Reply"].firstMatch
                }
                if !menuReplyButton.exists {
                    menuReplyButton = app.scrollViews.buttons["Reply"].firstMatch
                }
                if !menuReplyButton.exists {
                    // Try tapping the first menu item by label
                    menuReplyButton = app.staticTexts["Reply"].firstMatch
                }
                if menuReplyButton.waitForExistence(timeout: 3) {
                    menuReplyButton.tap()
                    Thread.sleep(forTimeInterval: 5)
                    snapshot("06_ComposeReply")

                    // 07. Compose Edit Chat — accept suggestion, then tap Edit pill
                    let useSuggestion = app.buttons["Use Suggestion"]
                    if useSuggestion.waitForExistence(timeout: 5) {
                        useSuggestion.tap()
                        Thread.sleep(forTimeInterval: 2)
                    }

                    let editPill = app.buttons.matching(identifier: "chatPill").matching(NSPredicate(format: "label == 'Edit'")).firstMatch
                    if editPill.waitForExistence(timeout: 8) {
                        editPill.tap()
                        Thread.sleep(forTimeInterval: 3)
                        snapshot("07_ComposeEditChat")
                    }
                }
            }
        }
    }

    // MARK: - 08. Search

    func test02_Search() {
        launchApp(arguments: ["--screenshot-mode"])

        navigateToInbox()

        let searchButton = app.buttons["magnifyingglass"]
        if searchButton.waitForExistence(timeout: 5) {
            searchButton.tap()
            Thread.sleep(forTimeInterval: 2)
            snapshot("08_Search")
        }
    }

    // MARK: - 11. Triage View

    func test04_Triage() {
        launchApp(arguments: ["--screenshot-mode"])

        navigateToInbox()

        // Tap the triage mode toggle (rectangle.stack icon in toolbar)
        let triageButton = app.buttons["Switch to triage"]
        if triageButton.waitForExistence(timeout: 5) {
            triageButton.tap()
            Thread.sleep(forTimeInterval: 2)
            snapshot("11_Triage")
        }
    }

    // MARK: - 12–13. Plan Picker (IAP review screenshots)

    func test05_PlanPicker() {
        launchApp(arguments: ["--screenshot-mode"])

        // Navigate to sidebar
        Thread.sleep(forTimeInterval: 3)
        navigateToSidebar()

        // Tap "TabMail Account"
        let tabMailAccount = app.staticTexts["TabMail Account"]
        if tabMailAccount.waitForExistence(timeout: 5) {
            tabMailAccount.tap()
            Thread.sleep(forTimeInterval: 2)

            // Tap "Subscribe" or "Change Plan" to open PlanPickerView
            let subscribe = app.staticTexts["Subscribe"]
            let changePlan = app.staticTexts["Change Plan"]
            if subscribe.waitForExistence(timeout: 3) {
                subscribe.tap()
            } else if changePlan.waitForExistence(timeout: 3) {
                changePlan.tap()
            }
            // Wait for StoreKit products to load — the "Most Popular" badge only
            // renders once the plan cards exist. (The old probe was the intro-offer
            // "2 weeks free" badge, deleted with the ASC offers — issue #55.)
            let proBadge = app.staticTexts["Most Popular"]
            _ = proBadge.waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 1)

            // 12. Monthly plans (default view)
            snapshot("12_PlanMonthly")

            // 14. Scroll to bottom to show Apple disclosure + links (monthly)
            scrollPlanPickerToBottom()
            snapshot("14_PlanMonthlyDisclosure")

            // Scroll back to top for yearly tab
            scrollPlanPickerToTop()

            // 13. Switch to Yearly and capture
            let yearlyTab = app.buttons["Yearly"]
            if yearlyTab.waitForExistence(timeout: 3) {
                yearlyTab.tap()
                Thread.sleep(forTimeInterval: 1)
                snapshot("13_PlanYearly")

                // 15. Scroll to bottom to show Apple disclosure + links (yearly)
                scrollPlanPickerToBottom()
                snapshot("15_PlanYearlyDisclosure")
            }
        }
    }

    // MARK: - 09–10. Settings Screenshots

    func test03_Settings() {
        launchApp(arguments: ["--screenshot-mode"])

        // App auto-navigates to inbox on iPhone. Go back to sidebar.
        Thread.sleep(forTimeInterval: 3)
        navigateToSidebar()

        // 09. Email Accounts Settings — shows multiple providers
        let emailAccounts = app.staticTexts["Email Accounts"]
        if emailAccounts.waitForExistence(timeout: 5) {
            emailAccounts.tap()
            Thread.sleep(forTimeInterval: 1)
            snapshot("09_EmailAccounts")

            navigateToSidebar()
        }

        // 10. TabMail Settings — personalization, prompts, local storage
        let tabMailSettings = app.staticTexts["TabMail Settings"]
        if tabMailSettings.waitForExistence(timeout: 3) {
            tabMailSettings.tap()
            Thread.sleep(forTimeInterval: 1)
            snapshot("10_TabMailSettings")
        }
    }
}
