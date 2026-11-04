/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
@testable import TabMail

@Suite("Plan picker trial banner")
struct PlanPickerTrialBannerTests {

    /// The same explicit line for every running trial, whatever its days
    /// left: the app cannot tell an older, longer signup trial from a new one
    /// by its days left.
    @Test("A running trial shows the days left and that subscribing starts a new 7-day free trial")
    func activeTrialBanner() {
        for days in [14, 10, 8, 7, 6, 5, 2] {
            let banner = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: days))
            #expect(banner?.icon == "clock")
            #expect(banner?.text == "Free trial · \(days) days left. Subscribing ends this trial and starts a new 7-day free trial.")
            #expect(banner?.color == .blue)
        }

        let lastDay = PlanPickerView.trialBannerCopy(for: .active(daysRemaining: 1))
        #expect(lastDay?.icon == "clock")
        #expect(lastDay?.text == "Free trial · 1 day left. Subscribing ends this trial and starts a new 7-day free trial.")
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

    /// The view shows `trialBannerCopy(for: accountInfo?.trialState())` (pinned
    /// by `viewShowsTheAccountsBanner`). These run the same chain from
    /// `/whoami`-shaped bodies decoded by the real parser, so a wire shape that
    /// stops reaching the banner fails here.
    @Test("Account info from the wire reaches the right banner")
    func bannerFromAccountInfo() throws {
        let now = Date()
        let banner = { (info: AccountInfo?) in PlanPickerView.trialBannerCopy(for: info?.trialState(now: now)) }

        let running = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: now)
        #expect(banner(running)?.text == "Free trial · 5 days left. Subscribing ends this trial and starts a new 7-day free trial.")

        let longer = try WhoamiFixture.runningSignupTrial(daysLeft: 10, reference: now)
        #expect(banner(longer)?.text == "Free trial · 10 days left. Subscribing ends this trial and starts a new 7-day free trial.")

        let ended = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
        #expect(banner(ended)?.icon == "clock.badge.exclamationmark")

        let endedNullTrial = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now, trialIsNull: true)
        #expect(banner(endedNullTrial)?.icon == "clock.badge.exclamationmark")

        let cardTrial = try WhoamiFixture.cardTrial(provider: "apple", planTier: "Basic", daysLeft: 5, reference: now)
        #expect(banner(cardTrial) == nil)

        #expect(banner(try WhoamiFixture.signedInWithoutSubscription()) == nil)
        #expect(banner(nil) == nil)
    }

    /// A hosted `PlanPickerView` cannot be driven from a unit test: it fetches
    /// its own account from the backend. So this reads the view's source and
    /// pins the one place that turns the fetched account into the banner, the
    /// last hop the tests above do not reach.
    @Test("The plan picker shows the banner for the account it fetched")
    func viewShowsTheAccountsBanner() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Account/PlanPickerView.swift"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let count = { (needle: String) in text.components(separatedBy: needle).count - 1 }

        #expect(count("trialBannerCopy(for: ") == 1, "one call site in the view")
        #expect(count("if let trialBanner = Self.trialBannerCopy(for: accountInfo?.trialState()) { StatusBanner(icon: trialBanner.icon, text: trialBanner.text, color: trialBanner.color) }") == 1)
    }
}
