/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import TabMail

@MainActor
@Suite("Real local StoreKit trial offers", .serialized, .processGlobalState)
struct TrialStoreKitTests {
    // Exercise launch and teardown twice in one process, each with a fresh group.
    @Test(arguments: 0..<2)
    func realProductMetadataAndAppleEligibilityControlTheFreeOffer(_: Int) async throws {
        let fixture = try TrialStoreKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        let session = fixture.session
        let manager = fixture.manager
        #expect(manager.products.count == 6)
        let basic = try #require(manager.products.first { $0.id == "ai.tabmail.basic.monthly" })
        let paidGo = try #require(manager.products.first { $0.id == "ai.tabmail.basic.yearly" })
        let paidUpfront = try #require(manager.products.first { $0.id == "ai.tabmail.pro.monthly" })
        let absent = try #require(manager.products.first { $0.id == "ai.tabmail.pro.yearly" })
        let zero = try #require(manager.products.first { $0.id == "ai.tabmail.byok.monthly" })
        let subscription = try #require(basic.subscription)
        // Fail before any purchase if the local catalog did not activate.
        try #require(subscription.subscriptionGroupID == fixture.group)
        let introduction = try #require(subscription.introductoryOffer)
        try #require(introduction.paymentMode == .freeTrial)
        try #require(introduction.period.unit == .week)
        try #require(introduction.period.value == 1)
        try #require(introduction.periodCount == 1)
        try #require(StoreKitManager.planName(for: basic.id) == AccountPlanConfig.basicTierKey)
        try #require(await subscription.isEligibleForIntroOffer)
        let free = try #require(await manager.freeTrialOffer(for: basic))
        #expect(free.value == 1 && free.unit == .week)
        #expect(manager.freeTrialOffers[basic.id] == free)
        try #require(paidGo.subscription?.introductoryOffer?.paymentMode == .payAsYouGo)
        try #require(paidUpfront.subscription?.introductoryOffer?.paymentMode == .payUpFront)
        #expect(await manager.freeTrialOffer(for: paidGo) == nil)
        #expect(await manager.freeTrialOffer(for: paidUpfront) == nil)
        try #require(absent.subscription?.introductoryOffer == nil)
        #expect(await manager.freeTrialOffer(for: absent) == nil)
        // Even an accidentally configured free Zero offer must not be advertised.
        try #require(zero.subscription?.introductoryOffer?.paymentMode == .freeTrial)
        #expect(await manager.freeTrialOffer(for: zero) == nil)
        let transaction = try await session.buyProduct(identifier: basic.id)
        try #require(transaction.environment == .xcode)
        try #require(transaction.offer?.paymentMode == .freeTrial)
        await transaction.finish()
        let consumed = try await fixture.waitForConsumedEligibility(subscription)
        try #require(consumed)
        // PlanPicker passes its selected cached Product to this production
        // refresh caller. Its async eligibility must reflect the consumed trial
        // before any fresh Product lookup can affect the result.
        #expect(await subscription.isEligibleForIntroOffer == false)
        #expect(await manager.freeTrialOffer(for: basic) == nil)
        let refreshed = try #require(try await Product.products(for: [basic.id]).first)
        try #require(refreshed.subscription?.subscriptionGroupID == fixture.group)
        #expect(await refreshed.subscription?.isEligibleForIntroOffer == false)
        #expect(await manager.freeTrialOffer(for: refreshed) == nil)
        await manager.loadProducts()
        #expect(manager.freeTrialOffers.isEmpty)
    }
    @Test(arguments: TrialStoreKitFixture.Period.allCases)
    func actualProductDurationControlsDisplayAndPreservation(period: TrialStoreKitFixture.Period) async throws {
        let fixture = try TrialStoreKitFixture(period: period)
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.product()
        let subscription = try #require(product.subscription)
        let rawOffer = try #require(subscription.introductoryOffer)
        try #require(rawOffer.paymentMode == .freeTrial)
        try #require(rawOffer.period.unit == period.storeUnit)
        try #require(rawOffer.period.value == period.value)
        try #require(rawOffer.periodCount == 1)
        try #require(await subscription.isEligibleForIntroOffer)
        let decoded = try #require(await fixture.manager.freeTrialOffer(for: product))
        #expect(decoded.unit == period.decodedUnit)
        #expect(decoded.value == period.value)
        #expect(decoded.durationDescription == period.displayedDuration)
        let now = Date()
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: period.promisedDays, reference: now)
        let restriction = SubscriptionTrialPurchasePolicy.restriction(account: account, offer: decoded, now: now)
        #expect((restriction == nil) == period.preservesPromise)
    }

}
