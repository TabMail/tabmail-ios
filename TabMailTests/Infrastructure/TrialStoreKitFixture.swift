/* This Source Code Form is subject to the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import TabMail

/// One local catalog/history per test; never changes the live app scheme/offers.
@MainActor
final class TrialStoreKitFixture {
    enum Period: String, CaseIterable, Sendable {
        case threeDays = "P3D", week = "P1W", twoWeeks = "P2W", month = "P1M", year = "P1Y"

        var value: Int { self == .threeDays ? 3 : self == .twoWeeks ? 2 : 1 }
        var storeUnit: Product.SubscriptionPeriod.Unit {
            switch self {
            case .threeDays: .day
            case .week, .twoWeeks: .week
            case .month: .month
            case .year: .year
            }
        }
        var decodedUnit: SubscriptionTrialOffer.Unit {
            switch self {
            case .threeDays: .day
            case .week, .twoWeeks: .week
            case .month: .month
            case .year: .year
            }
        }
        var displayedDuration: String {
            switch self {
            case .threeDays: "3 days"
            case .week: "1 week"
            case .twoWeeks: "2 weeks"
            case .month: "1 month"
            case .year: "1 year"
            }
        }
        var promisedDays: Double { self == .threeDays ? 5 : self == .year ? 40 : 12 }
        var preservesPromise: Bool { self != .threeDays && self != .week }
    }

    let session: SKTestSession
    let manager = StoreKitManager()
    let group = UUID().uuidString
    private let url: URL
    private let original: URL
    private let productCount: Int

    init(period: Period = .week, basicOnly: Bool = false, includesFreeOffer: Bool = true) throws {
        productCount = basicOnly ? 1 : 6
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        original = root.appendingPathComponent("TabMail/Configuration.storekit")
        let data = try Data(contentsOf: original)
        var catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var groups = try #require(catalog["subscriptionGroups"] as? [[String: Any]])
        try #require(groups.count == 1)
        groups[0]["id"] = group
        var products = try #require(groups[0]["subscriptions"] as? [[String: Any]])
        if basicOnly { products = products.filter { $0["productID"] as? String == "ai.tabmail.basic.monthly" } }
        for index in products.indices {
            products[index]["subscriptionGroupID"] = group
            let id = try #require(products[index]["productID"] as? String)
            let mode: String?
            switch id {
            case "ai.tabmail.basic.monthly", "ai.tabmail.byok.monthly": mode = includesFreeOffer ? "free" : nil
            case "ai.tabmail.basic.yearly": mode = "payAsYouGo"
            case "ai.tabmail.pro.monthly": mode = "payUpFront"
            default: mode = nil
            }
            if let mode {
                products[index]["introductoryOffer"] = [
                    "internalID": "test-intro-\(id)", "numberOfPeriods": 1,
                    "paymentMode": mode,
                    "subscriptionPeriod": mode == "free" ? period.rawValue : "P1W",
                    "displayPrice": mode == "free" ? "0" : "1.00",
                ]
            } else {
                products[index].removeValue(forKey: "introductoryOffer")
            }
        }
        groups[0]["subscriptions"] = products
        catalog["subscriptionGroups"] = groups
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-offers-\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: catalog).write(to: url)
        do { session = try SKTestSession(contentsOf: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        session.clearTransactions()
        session.disableDialogs = true
    }

    func load() async throws {
        await manager.loadProducts()
        try #require(manager.products.count == productCount)
    }

    func product(_ id: String = "ai.tabmail.basic.monthly") throws -> Product {
        let product = try #require(manager.products.first { $0.id == id })
        // Mandatory local-mode precondition before any supported purchase path.
        try #require(product.subscription?.subscriptionGroupID == group)
        return product
    }

    func waitForConsumedEligibility(_ subscription: Product.SubscriptionInfo) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await subscription.isEligibleForIntroOffer {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func close() {
        session.clearTransactions()
        session.resetToDefaultState()
        do { _ = try SKTestSession(contentsOf: original) }
        catch { Issue.record("Could not restore the local StoreKit catalog: \(error)") }
        try? FileManager.default.removeItem(at: url)
    }
}
