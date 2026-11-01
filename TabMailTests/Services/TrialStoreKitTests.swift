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
    /// Local-only copy of the existing catalog; no scheme or live offer changes.
    private func configurationURL() throws -> (url: URL, group: String, original: URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = root.appendingPathComponent("TabMail/Configuration.storekit")
        let data = try Data(contentsOf: original)
        var catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var groups = try #require(catalog["subscriptionGroups"] as? [[String: Any]])
        #expect(groups.count == 1)
        guard groups.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        // Each run owns its eligibility history; do not depend on a previous
        // session's transaction reset propagating to StoreKit's eligibility cache.
        let group = UUID().uuidString
        groups[0]["id"] = group
        var products = try #require(groups[0]["subscriptions"] as? [[String: Any]])
        for index in products.indices {
            products[index]["subscriptionGroupID"] = group
            let id = try #require(products[index]["productID"] as? String)
            let mode: String?
            switch id {
            case "ai.tabmail.basic.monthly", "ai.tabmail.byok.monthly": mode = "free"
            case "ai.tabmail.basic.yearly": mode = "payAsYouGo"
            case "ai.tabmail.pro.monthly": mode = "payUpFront"
            default: mode = nil
            }
            if let mode {
                products[index]["introductoryOffer"] = [
                    "internalID": "test-intro-\(id)", "numberOfPeriods": 1,
                    "paymentMode": mode, "subscriptionPeriod": "P1W",
                    "displayPrice": mode == "free" ? "0" : "1.00",
                ]
            } else {
                products[index].removeValue(forKey: "introductoryOffer")
            }
        }
        groups[0]["subscriptions"] = products
        catalog["subscriptionGroups"] = groups
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-offers-\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: catalog).write(to: url)
        return (url, group, original)
    }

    @Test func realProductMetadataAndAppleEligibilityControlTheFreeOffer() async throws {
        let fixture = try configurationURL()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let session = try SKTestSession(contentsOf: fixture.url)
        session.clearTransactions()
        session.disableDialogs = true
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
            do { _ = try SKTestSession(contentsOf: fixture.original) }
            catch { Issue.record("Could not restore the local StoreKit catalog: \(error)") }
        }
        let manager = StoreKitManager()
        await manager.loadProducts()
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
}
