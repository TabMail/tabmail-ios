/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// ADR-IOS-121 (#1583): what the upgrade screens say about the time. The notice says
/// "up to N minutes" (`DatabaseUpgrade.noticeMinutes`, or the fallback when a database
/// cannot be read); the running screen says the minutes left, "Less than a minute
/// remaining" or "Almost done" (`DatabaseUpgradeProgress.Remaining`).
@MainActor
@Suite("What the upgrade screens say about the time")
struct DatabaseUpgradeViewTests {

    @Test("The notice: up to N minutes, one minute in the singular, and the fallback is 10 minutes")
    func theNoticeTime() {
        let fallback = DatabaseUpgradeView.noticeTime(minutes: SyncConfig.databaseUpgradeNoticeFallbackMinutes)
        let one = DatabaseUpgradeView.noticeTime(minutes: 1)
        let ten = DatabaseUpgradeView.noticeTime(minutes: 10)

        #expect(fallback == "It can take up to 10 minutes. Keep TabMail open while it runs.", "\(fallback)")
        #expect(one == "It can take up to 1 minute. Keep TabMail open while it runs.", "\(one)")
        #expect(ten == fallback, "\(ten)")
    }

    @Test("The running screen: about N minutes remaining (one minute in the singular), less than a minute, almost done")
    func theRemainingTime() {
        let two = DatabaseUpgradeView.remainingText(.minutes(2))
        let one = DatabaseUpgradeView.remainingText(.minutes(1))
        let underAMinute = DatabaseUpgradeView.remainingText(.lessThanAMinute)
        let almostDone = DatabaseUpgradeView.remainingText(.almostDone)

        #expect(two == "About 2 minutes remaining", "\(two)")
        #expect(one == "About 1 minute remaining", "\(one)")
        #expect(underAMinute == "Less than a minute remaining", "\(underAMinute)")
        #expect(almostDone == "Almost done", "\(almostDone)")
    }
}
