/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Inbox trial reminder")
struct InboxTrialReminderTests {

    private func text(_ state: TrialState, isInbox: Bool = true, isSignedIn: Bool = true, isDemo: Bool = false) -> String? {
        InboxTrialReminder.text(for: state, isInbox: isInbox, isSignedIn: isSignedIn, isDemo: isDemo)
    }

    @Test("A running trial shows the days left")
    func copy() {
        #expect(text(.active(daysRemaining: 3)) == "Free trial · 3 days left")
        #expect(text(.active(daysRemaining: 1)) == "Free trial · 1 day left")
    }

    @Test("No trial or an ended trial shows no row")
    func otherTrialStates() {
        #expect(text(.noTrial) == nil)
        #expect(text(.ended) == nil)
    }

    @Test("Other folders, signed out and demo mode show no row")
    func hiddenOutsideTheSignedInInbox() {
        #expect(text(.active(daysRemaining: 3), isInbox: false) == nil)
        #expect(text(.active(daysRemaining: 3), isSignedIn: false) == nil)
        #expect(text(.active(daysRemaining: 3), isDemo: true) == nil)
    }

    /// The inbox reads `UsageThrottleStore.shared.trialState`, which the
    /// foreground `/whoami` refreshes through `update(from:)`. Each body here
    /// is decoded by the real parser, and the latest one decides, so an
    /// account switch to a non-trial account hides the row.
    @Test("The latest /whoami decides, and switching to a non-trial account hides the row")
    @MainActor
    func latestAccountDecides() throws {
        let now = Date()
        let store = UsageThrottleStore.shared
        let shown = { InboxTrialReminder.text(for: store.trialState, isInbox: true, isSignedIn: true, isDemo: false) }

        store.update(from: try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now))
        #expect(shown() == "Free trial · 3 days left")

        store.update(from: try WhoamiFixture.cardTrial(provider: "apple", planTier: AccountPlanConfig.basicTierKey, daysLeft: 3, reference: now))
        #expect(shown() == nil)

        store.update(from: try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now))
        store.update(from: try WhoamiFixture.accountInfo(hasSubscription: true, planTier: AccountPlanConfig.byokTierKey, provider: "stripe"))
        #expect(shown() == nil)

        store.update(from: try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now))
        #expect(store.trialState == .ended)
        #expect(shown() == nil)

        // Leave the shared store on a no-trial, no-banner account.
        store.update(from: try WhoamiFixture.signedInWithoutSubscription())
        #expect(store.trialState == .noTrial)
    }
}
