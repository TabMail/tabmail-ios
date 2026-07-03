/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UserNotifications
@testable import TabMail

/// Unit tests for the pure decision logic backing `RemindersNotificationWarning`.
/// The view itself (SwiftUI body, async `refreshAuthStatus`) is not tested here —
/// only the static helpers that decide whether/what to show given an iOS
/// authorization status and the in-app toggle state.
@Suite("RemindersNotificationWarning")
@MainActor
struct RemindersNotificationWarningTests {

    // MARK: - iosNotificationsBlocked

    @Test("authorized is not blocked")
    func authorizedIsNotBlocked() {
        #expect(RemindersNotificationWarning.iosNotificationsBlocked(status: .authorized) == false)
    }

    @Test("provisional is not blocked")
    func provisionalIsNotBlocked() {
        #expect(RemindersNotificationWarning.iosNotificationsBlocked(status: .provisional) == false)
    }

    @Test("ephemeral is not blocked")
    func ephemeralIsNotBlocked() {
        #expect(RemindersNotificationWarning.iosNotificationsBlocked(status: .ephemeral) == false)
    }

    @Test("denied is blocked")
    func deniedIsBlocked() {
        #expect(RemindersNotificationWarning.iosNotificationsBlocked(status: .denied) == true)
    }

    @Test("notDetermined is blocked")
    func notDeterminedIsBlocked() {
        // Until the user actually grants permission, no notifications fire,
        // so we treat .notDetermined as a failure.
        #expect(RemindersNotificationWarning.iosNotificationsBlocked(status: .notDetermined) == true)
    }

    // MARK: - shouldShow

    @Test("hidden until auth status has loaded")
    func hiddenBeforeAuthLoaded() {
        // Even with all-bad inputs, we must not flash the warning before
        // the async UNUserNotificationCenter fetch completes.
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: false,
                proactiveEnabled: false,
                iosAuthStatus: .denied
            ) == false
        )
    }

    @Test("hidden when everything is healthy")
    func hiddenWhenHealthy() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: true,
                iosAuthStatus: .authorized
            ) == false
        )
    }

    @Test("shown when in-app toggle is off")
    func shownWhenInAppOff() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: false,
                iosAuthStatus: .authorized
            ) == true
        )
    }

    @Test("shown when iOS permission is denied")
    func shownWhenIosDenied() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: true,
                iosAuthStatus: .denied
            ) == true
        )
    }

    @Test("shown when iOS permission is notDetermined")
    func shownWhenIosNotDetermined() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: true,
                iosAuthStatus: .notDetermined
            ) == true
        )
    }

    @Test("shown when both in-app and iOS are off")
    func shownWhenBothOff() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: false,
                iosAuthStatus: .denied
            ) == true
        )
    }

    @Test("provisional + in-app on is hidden")
    func provisionalAndInAppOnIsHidden() {
        #expect(
            RemindersNotificationWarning.shouldShow(
                hasLoadedAuthStatus: true,
                proactiveEnabled: true,
                iosAuthStatus: .provisional
            ) == false
        )
    }

    // MARK: - warningText

    @Test("in-app off text takes precedence over iOS status")
    func inAppOffTextTakesPrecedence() {
        // When the user disabled in-app, point them at the in-app fix regardless
        // of iOS state — that's the thing they can most immediately act on.
        let text = RemindersNotificationWarning.warningText(
            proactiveEnabled: false,
            iosAuthStatus: .denied
        )
        #expect(text.contains("Settings → Notifications"))
        #expect(!text.contains("iOS Settings"))
    }

    @Test("in-app off text when iOS is fine")
    func inAppOffTextWhenIosFine() {
        let text = RemindersNotificationWarning.warningText(
            proactiveEnabled: false,
            iosAuthStatus: .authorized
        )
        #expect(text.contains("Settings → Notifications"))
    }

    @Test("iOS-off text when in-app is on")
    func iosOffTextWhenInAppOn() {
        let text = RemindersNotificationWarning.warningText(
            proactiveEnabled: true,
            iosAuthStatus: .denied
        )
        #expect(text.contains("iOS Settings"))
        #expect(!text.contains("Settings → Notifications"))
    }

    @Test("iOS-off text when in-app is on and iOS notDetermined")
    func iosOffTextWhenNotDetermined() {
        let text = RemindersNotificationWarning.warningText(
            proactiveEnabled: true,
            iosAuthStatus: .notDetermined
        )
        #expect(text.contains("iOS Settings"))
    }
}
