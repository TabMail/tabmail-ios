/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Plan picker trial banner")
struct PlanPickerTrialBannerTests {

    @Test("A running trial shows the days left and what subscribing does")
    func activeTrialBanner() {
        let several = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: 5))
        #expect(several?.icon == "clock")
        #expect(several?.text == "Free trial · 5 days left. Subscribing resets your free trial.")

        let lastDay = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: 1))
        #expect(lastDay?.text == "Free trial · 1 day left. Subscribing resets your free trial.")
    }

    @Test("An ended trial asks the user to subscribe")
    func endedTrialBanner() {
        let ended = PlanPickerView.trialBannerCopy(for: .ended)
        #expect(ended?.icon == "clock.badge.exclamationmark")
        #expect(ended?.text == "Your free trial has ended — subscribe to continue using AI features.")
    }

    @Test("No trial story, or no account yet, shows no banner")
    func noBanner() {
        #expect(PlanPickerView.trialBannerCopy(for: .noTrial) == nil)
        #expect(PlanPickerView.trialBannerCopy(for: nil) == nil)
    }
}
