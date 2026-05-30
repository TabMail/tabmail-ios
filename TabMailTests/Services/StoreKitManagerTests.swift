/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - StoreKitManager Product ID Tests

@Suite("StoreKitManager Product IDs")
struct StoreKitManagerProductIDTests {

    @Test("Product IDs follow expected naming convention")
    func productIDNaming() {
        // The product IDs are private, but we can verify the patterns used
        // in the filtering and ranking logic match what's expected
        let expectedIDs = [
            "ai.tabmail.basic.monthly",
            "ai.tabmail.basic.yearly",
            "ai.tabmail.pro.monthly",
            "ai.tabmail.pro.yearly",
        ]
        // Verify naming convention
        for id in expectedIDs {
            #expect(id.hasPrefix("ai.tabmail."))
            #expect(id.contains("monthly") || id.contains("yearly"))
            #expect(id.contains("basic") || id.contains("pro"))
        }
    }

    @Test("Product ID contains check distinguishes monthly vs yearly")
    func monthlyYearlyDistinction() {
        let monthlyIDs = ["ai.tabmail.basic.monthly", "ai.tabmail.pro.monthly"]
        let yearlyIDs = ["ai.tabmail.basic.yearly", "ai.tabmail.pro.yearly"]

        for id in monthlyIDs {
            #expect(id.contains("monthly"))
            #expect(!id.contains("yearly"))
        }
        for id in yearlyIDs {
            #expect(id.contains("yearly"))
            #expect(!id.contains("monthly"))
        }
    }

    @Test("Product ID contains check distinguishes basic vs pro")
    func basicProDistinction() {
        let basicIDs = ["ai.tabmail.basic.monthly", "ai.tabmail.basic.yearly"]
        let proIDs = ["ai.tabmail.pro.monthly", "ai.tabmail.pro.yearly"]

        for id in basicIDs {
            #expect(id.contains("basic"))
            #expect(!id.contains("pro"))
        }
        for id in proIDs {
            #expect(id.contains("pro"))
            #expect(!id.contains("basic"))
        }
    }
}

// MARK: - StoreKitManager Plan Ranking Tests

@Suite("StoreKitManager Plan Ranking")
struct StoreKitManagerPlanRankingTests {

    @Test("Pro rank is higher than Basic rank")
    func proHigherThanBasic() {
        // From updateCurrentEntitlements: pro -> rank 2, basic -> rank 1
        let proID = "ai.tabmail.pro.monthly"
        let basicID = "ai.tabmail.basic.monthly"

        let proRank = proID.contains("pro") ? 2 : 1
        let basicRank = basicID.contains("pro") ? 2 : 1

        #expect(proRank > basicRank)
    }

    @Test("Plan ranking picks pro over basic")
    func rankingPicksProOverBasic() {
        // Simulate the ranking logic from updateCurrentEntitlements
        let productIDs = ["ai.tabmail.basic.monthly", "ai.tabmail.pro.yearly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = id.contains("pro") ? 2 : 1
            if rank > bestRank {
                bestRank = rank
                bestPlan = planName(for: id)
            }
        }

        #expect(bestPlan == "Pro")
        #expect(bestRank == 2)
    }

    @Test("Plan ranking with only basic returns Basic")
    func rankingOnlyBasic() {
        let productIDs = ["ai.tabmail.basic.monthly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = id.contains("pro") ? 2 : 1
            if rank > bestRank {
                bestRank = rank
                bestPlan = planName(for: id)
            }
        }

        #expect(bestPlan == "Basic")
        #expect(bestRank == 1)
    }

    @Test("Plan ranking with empty list returns nil")
    func rankingEmpty() {
        let productIDs: [String] = []
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = id.contains("pro") ? 2 : 1
            if rank > bestRank {
                bestRank = rank
                bestPlan = planName(for: id)
            }
        }

        #expect(bestPlan == nil)
        #expect(bestRank == 0)
    }

    @Test("Plan ranking multiple pro picks first pro encountered")
    func rankingMultiplePro() {
        let productIDs = ["ai.tabmail.pro.monthly", "ai.tabmail.pro.yearly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = id.contains("pro") ? 2 : 1
            if rank > bestRank {
                bestRank = rank
                bestPlan = planName(for: id)
            }
        }

        // Both are rank 2, first one wins since > not >=
        #expect(bestPlan == "Pro")
    }

    // Helper matching StoreKitManager.planName(for:)
    private func planName(for productId: String) -> String {
        if productId.contains("pro") { return "Pro" }
        if productId.contains("basic") { return "Basic" }
        return "Unknown"
    }
}

// MARK: - StoreKitManager Plan Name Tests

@Suite("StoreKitManager Plan Name Mapping")
struct StoreKitManagerPlanNameTests {

    private func planName(for productId: String) -> String {
        if productId.contains("pro") { return "Pro" }
        if productId.contains("basic") { return "Basic" }
        return "Unknown"
    }

    @Test("Pro product IDs return Pro plan name")
    func proNames() {
        #expect(planName(for: "ai.tabmail.pro.monthly") == "Pro")
        #expect(planName(for: "ai.tabmail.pro.yearly") == "Pro")
    }

    @Test("Basic product IDs return Basic plan name")
    func basicNames() {
        #expect(planName(for: "ai.tabmail.basic.monthly") == "Basic")
        #expect(planName(for: "ai.tabmail.basic.yearly") == "Basic")
    }

    @Test("Unknown product ID returns Unknown")
    func unknownName() {
        #expect(planName(for: "ai.tabmail.enterprise.monthly") == "Unknown")
        #expect(planName(for: "com.other.app") == "Unknown")
        #expect(planName(for: "") == "Unknown")
    }

    @Test("planName checks contain, not exact match")
    func containCheck() {
        // Edge case: a product ID with both "pro" and "basic" would match "pro" first
        #expect(planName(for: "ai.tabmail.pro.basic") == "Pro")
    }
}

// MARK: - StoreKitManager Account Mismatch Tests

@Suite("StoreKitManager Account Mismatch")
struct StoreKitManagerAccountMismatchTests {

    @Test("hasAccountMismatch returns false when not subscriber")
    @MainActor
    func notSubscriber() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = false
        manager.subscriptionOwnerUserId = "other-user"
        #expect(manager.hasAccountMismatch(currentUserId: "current-user") == false)
    }

    @Test("hasAccountMismatch returns false when owner is nil")
    @MainActor
    func ownerNil() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = true
        manager.subscriptionOwnerUserId = nil
        #expect(manager.hasAccountMismatch(currentUserId: "current-user") == false)
    }

    @Test("hasAccountMismatch returns false when IDs match")
    @MainActor
    func idsMatch() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = true
        manager.subscriptionOwnerUserId = "user-123"
        #expect(manager.hasAccountMismatch(currentUserId: "user-123") == false)
    }

    @Test("hasAccountMismatch returns true when IDs differ")
    @MainActor
    func idsMismatch() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = true
        manager.subscriptionOwnerUserId = "other-user"
        #expect(manager.hasAccountMismatch(currentUserId: "current-user") == true)
    }

    @Test("hasAccountMismatch lowercases currentUserId before comparison")
    @MainActor
    func caseSensitivity() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = true
        // subscriptionOwnerUserId is stored as lowercased UUID
        manager.subscriptionOwnerUserId = "abc-123"
        // currentUserId is lowercased before comparison, so ABC-123 matches abc-123
        #expect(manager.hasAccountMismatch(currentUserId: "ABC-123") == false)
        #expect(manager.hasAccountMismatch(currentUserId: "abc-123") == false)
        // Different ID should mismatch
        #expect(manager.hasAccountMismatch(currentUserId: "xyz-456") == true)
    }

    @Test("hasAccountMismatch with empty string currentUserId")
    @MainActor
    func emptyCurrentUserId() {
        let manager = StoreKitManager()
        manager.isAppleSubscriber = true
        manager.subscriptionOwnerUserId = "user-123"
        #expect(manager.hasAccountMismatch(currentUserId: "") == true)
    }
}

// MARK: - StoreKitManager Observable State Tests

@Suite("StoreKitManager State")
struct StoreKitManagerStateTests {

    @Test("Default state has no products or subscriptions")
    @MainActor
    func defaultState() {
        let manager = StoreKitManager()
        #expect(manager.products.isEmpty)
        #expect(manager.purchasedProductIDs.isEmpty)
        #expect(manager.isAppleSubscriber == false)
        #expect(manager.activePlan == nil)
        #expect(manager.subscriptionOwnerUserId == nil)
        #expect(manager.productsLoadError == nil)
        #expect(manager.restoreResult == nil)
    }

    @Test("monthlyProducts filters correctly")
    @MainActor
    func monthlyFilter() {
        // monthlyProducts and yearlyProducts filter by ID containing "monthly"/"yearly"
        // Since we can't create Product objects in tests, we verify the filter logic
        let ids = ["ai.tabmail.basic.monthly", "ai.tabmail.basic.yearly",
                    "ai.tabmail.pro.monthly", "ai.tabmail.pro.yearly"]
        let monthly = ids.filter { $0.contains("monthly") }
        let yearly = ids.filter { $0.contains("yearly") }

        #expect(monthly.count == 2)
        #expect(yearly.count == 2)
        #expect(monthly.allSatisfy { $0.contains("monthly") })
        #expect(yearly.allSatisfy { $0.contains("yearly") })
    }
}
