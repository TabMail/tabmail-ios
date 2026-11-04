/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The Account dashboard's date row must not say "Renewal" for a card-free
/// signup trial: that trial ends without a charge, and nothing renews.
@Suite("Account dashboard period-end label")
struct AccountDashboardPeriodEndLabelTests {

    @Test("A signup trial says when it ends; anything else says Renewal")
    func labelForEachTrialState() {
        #expect(AccountDashboardView.periodEndLabel(for: .active(daysRemaining: 3)) == "Trial ends")
        #expect(AccountDashboardView.periodEndLabel(for: .active(daysRemaining: 1)) == "Trial ends")
        #expect(AccountDashboardView.periodEndLabel(for: .ended) == "Trial ended")
        #expect(AccountDashboardView.periodEndLabel(for: .noTrial) == "Renewal")
    }

    /// Bodies decoded by the real `/whoami` parser: only the signup trial
    /// changes the label. A card trial on any plan and a BYOK plan are
    /// subscriptions that renew.
    @Test("Account info from the wire picks the right label")
    func labelFromAccountInfo() throws {
        let now = Date()
        let label = { (info: AccountInfo) in AccountDashboardView.periodEndLabel(for: info.trialState(now: now)) }

        #expect(label(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now)) == "Trial ends")
        #expect(label(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)) == "Trial ended")
        #expect(label(try WhoamiFixture.cardTrial(provider: "apple", planTier: AccountPlanConfig.basicTierKey, daysLeft: 3, reference: now)) == "Renewal")
        #expect(label(try WhoamiFixture.cardTrial(provider: "stripe", planTier: AccountPlanConfig.basicTierKey, daysLeft: 3, reference: now)) == "Renewal")
        #expect(label(try WhoamiFixture.cardTrial(provider: "stripe", planTier: AccountPlanConfig.proTierKey, daysLeft: 3, reference: now)) == "Renewal")
        // Zero is the other zero-budget tier: its card trial renews too.
        #expect(label(try WhoamiFixture.cardTrial(provider: "stripe", planTier: AccountPlanConfig.byokTierKey, daysLeft: 3, reference: now)) == "Renewal")
        #expect(label(try WhoamiFixture.accountInfo(hasSubscription: true, planTier: AccountPlanConfig.byokTierKey, provider: "stripe")) == "Renewal")
        #expect(label(try WhoamiFixture.signedInWithoutSubscription()) == "Renewal")
    }

    /// A hosted dashboard cannot be driven from a unit test: it fetches its own
    /// account from the backend. So this reads the view's source: the date row
    /// takes its label from the account's trial state, and no fixed "Renewal"
    /// label is left in the view.
    @Test("The dashboard's date row uses the account's label, never a fixed Renewal")
    func viewUsesTheAccountsLabel() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Account/AccountDashboardView.swift"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let count = { (needle: String) in text.components(separatedBy: needle).count - 1 }

        #expect(count("Label(\"Renewal\"") == 0, "no fixed Renewal label")
        #expect(count("Label(Self.periodEndLabel(for: accountInfo?.trialState() ?? .noTrial), systemImage: \"calendar\")") == 1)
    }
}
