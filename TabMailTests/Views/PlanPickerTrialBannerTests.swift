/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
@testable import TabMail

@Suite("Plan picker trial banner")
struct PlanPickerTrialBannerTests {

    @Test("A running trial shows the days left and what subscribing does")
    func activeTrialBanner() {
        let several = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: 5))
        #expect(several?.icon == "clock")
        #expect(several?.text == "Free trial · 5 days left. Subscribing resets your free trial.")
        #expect(several?.color == .blue)

        let lastDay = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: 1))
        #expect(lastDay?.text == "Free trial · 1 day left. Subscribing resets your free trial.")
        #expect(lastDay?.color == .blue)
    }

    @Test("An ended trial asks the user to subscribe")
    func endedTrialBanner() {
        let ended = PlanPickerView.trialBannerCopy(for: .ended)
        #expect(ended?.icon == "clock.badge.exclamationmark")
        #expect(ended?.text == "Your free trial has ended — subscribe to continue using AI features.")
        #expect(ended?.color == .orange)
    }

    @Test("No trial story, or no account yet, shows no banner")
    func noBanner() {
        #expect(PlanPickerView.trialBannerCopy(for: .noTrial) == nil)
        #expect(PlanPickerView.trialBannerCopy(for: nil) == nil)
    }

    /// The view shows `trialBannerCopy(for: accountInfo?.trialState())`. These
    /// run the same chain from `/whoami`-shaped bodies decoded by the real
    /// parser, so a wire shape that stops reaching the banner fails here.
    @Test("Account info from the wire reaches the right banner")
    func bannerFromAccountInfo() throws {
        let now = Date()
        let banner = { (info: AccountInfo?) in PlanPickerView.trialBannerCopy(for: info?.trialState(now: now)) }

        let running = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: now)
        #expect(banner(running)?.text == "Free trial · 5 days left. Subscribing resets your free trial.")

        let ended = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
        #expect(banner(ended)?.icon == "clock.badge.exclamationmark")

        let endedNullTrial = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now, trialIsNull: true)
        #expect(banner(endedNullTrial)?.icon == "clock.badge.exclamationmark")

        let cardTrial = try WhoamiFixture.cardTrial(provider: "apple", planTier: "Basic", daysLeft: 5, reference: now)
        #expect(banner(cardTrial) == nil)

        #expect(banner(try WhoamiFixture.signedInWithoutSubscription()) == nil)
        #expect(banner(nil) == nil)
    }
}
