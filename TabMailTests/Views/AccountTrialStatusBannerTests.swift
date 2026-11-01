/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

@MainActor
struct AccountTrialStatusBannerTests {
    private func account(provider: String, cancelled: Bool = false) throws -> AccountInfo {
        let end = Int(Date().addingTimeInterval(5 * 86_400).timeIntervalSince1970)
        var json: [String: Any] = ["logged_in": true, "has_subscription": true,
            "plan_tier": "Basic", "subscription_provider": provider,
            "trial": ["is_trial": true, "trial_end": end]]
        if cancelled { json["pending_cancellation"] = ["cancel_at": end] }
        return try JSONDecoder().decode(AccountInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func renderedHeight(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 390, height: 1000)).height
    }

    @Test(arguments: ["apple", "stripe"])
    func purchasedTrialRendersInBothAccountConsumers(provider: String) throws {
        let info = try account(provider: provider)
        for context in [AccountTrialStatusBanner.Context.account, .plans] {
            let banner = AccountTrialStatusBanner(accountInfo: info, context: context)
            let text = try #require(banner.presentation?.text)
            #expect(text.contains("Subscription trial"))
            #expect(text.contains("Payment begins"))
            #expect(renderedHeight(banner) > 0)
        }
    }

    @Test(arguments: ["apple", "stripe"])
    func cancelledRenewalDoesNotAdvertiseAnUpcomingPayment(provider: String) throws {
        let info = try account(provider: provider, cancelled: true)
        for context in [AccountTrialStatusBanner.Context.account, .plans] {
            let banner = AccountTrialStatusBanner(accountInfo: info, context: context)
            #expect(banner.presentation?.text.contains("Renewal is cancelled") == true)
            #expect(banner.presentation?.text.contains("Payment begins") == false)
            #expect(renderedHeight(banner) > 0)
        }
    }

    @Test func signupAndEndedAccountCopyStayDistinctFromPurchasedTrials() throws {
        let now = Date()
        let running = try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now)
        let ended = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
        for context in [AccountTrialStatusBanner.Context.account, .plans] {
            let active = AccountTrialStatusBanner(accountInfo: running, context: context, now: now)
            #expect(active.presentation?.text.contains("3 days left") == true)
            #expect(renderedHeight(active) > 0)
            let expired = AccountTrialStatusBanner(accountInfo: ended, context: context, now: now)
            #expect(expired.presentation?.text.contains("has ended") == true)
            #expect(renderedHeight(expired) > 0)
            #expect(renderedHeight(AccountTrialStatusBanner(accountInfo: nil, context: context)) == 0)
        }
    }
}
