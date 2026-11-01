/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

struct SubscriptionTrialOfferTests {
    @Test func noAccountAuthorityRefusesPurchase() {
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: nil, offer: nil) != nil)
    }

    @Test func newOneWeekOfferProtectsAnExistingTwoWeekPromise() throws {
        let now = Date()
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 12, reference: now)
        let week = SubscriptionTrialOffer(value: 1, unit: .week)
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: account, offer: week, now: now) != nil)
        let fortnight = SubscriptionTrialOffer(value: 2, unit: .week)
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: account, offer: fortnight, now: now) == nil)
    }

    @Test func eligibleOfferAllowsCommitmentWithoutForfeitingSignupTime() throws {
        let now = Date()
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: now)
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: account,
            offer: .init(value: 1, unit: .week), now: now) == nil)
    }

    @Test func noOfferOrIneligibleAppleIDCannotForfeitRemainingDays() throws {
        let now = Date()
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 0.1, reference: now)
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: account, offer: nil, now: now) != nil)
        let ended = try WhoamiFixture.accountInfo(hasSubscription: false, isTrial: true,
            trialEnd: now.addingTimeInterval(-1))
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: ended, offer: nil, now: now) == nil)
    }

    @Test func paidSubscriberIsNotTreatedAsASignupTrial() throws {
        let now = Date()
        let subscriber = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Basic",
            provider: "apple", isTrial: true, trialEnd: now.addingTimeInterval(86_400))
        #expect(subscriber.trialState(now: now) == .noTrial)
        #expect(subscriber.subscriptionTrialEnd(now: now) != nil)
        #expect(SubscriptionTrialPurchasePolicy.restriction(account: subscriber, offer: nil, now: now) == nil)
    }

    @Test func signupAndExpiredTrialsAreNotSubscriptionTrials() throws {
        let now = Date()
        let signup = try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now)
        #expect(signup.subscriptionTrialEnd(now: now) == nil)
        let expired = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Pro",
            provider: "stripe", isTrial: true, trialEnd: now.addingTimeInterval(-1))
        #expect(expired.subscriptionTrialEnd(now: now) == nil)
    }

    @Test func durationAndEndFollowRealOfferMetadata() throws {
        let now = Date()
        let offer = SubscriptionTrialOffer(value: 1, unit: .week)
        #expect(offer.durationDescription == "1 week")
        #expect(SubscriptionTrialOffer(value: 14, unit: .day).durationDescription == "14 days")
        #expect(SubscriptionTrialOffer(value: 0, unit: .day).endDate(from: now) == nil)
        let end = try #require(offer.endDate(from: now))
        #expect(Calendar.current.dateComponents([.day], from: now, to: end).day == 7)
    }
}
