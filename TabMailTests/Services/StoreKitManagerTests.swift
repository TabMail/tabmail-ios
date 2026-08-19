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
            "ai.tabmail.byok.monthly",
            "ai.tabmail.byok.yearly",
            "ai.tabmail.basic.monthly",
            "ai.tabmail.basic.yearly",
            "ai.tabmail.pro.monthly",
            "ai.tabmail.pro.yearly",
        ]
        // Verify naming convention
        for id in expectedIDs {
            #expect(id.hasPrefix("ai.tabmail."))
            #expect(id.contains("monthly") || id.contains("yearly"))
            #expect(id.contains("basic") || id.contains("pro") || id.contains("byok"))
        }
    }

    @Test("Product ID contains check distinguishes monthly vs yearly")
    func monthlyYearlyDistinction() {
        let monthlyIDs = ["ai.tabmail.byok.monthly", "ai.tabmail.basic.monthly", "ai.tabmail.pro.monthly"]
        let yearlyIDs = ["ai.tabmail.byok.yearly", "ai.tabmail.basic.yearly", "ai.tabmail.pro.yearly"]

        for id in monthlyIDs {
            #expect(id.contains("monthly"))
            #expect(!id.contains("yearly"))
        }
        for id in yearlyIDs {
            #expect(id.contains("yearly"))
            #expect(!id.contains("monthly"))
        }
    }

    @Test("Product ID contains check distinguishes tiers")
    func tierDistinction() {
        let byokIDs = ["ai.tabmail.byok.monthly", "ai.tabmail.byok.yearly"]
        let basicIDs = ["ai.tabmail.basic.monthly", "ai.tabmail.basic.yearly"]
        let proIDs = ["ai.tabmail.pro.monthly", "ai.tabmail.pro.yearly"]

        for id in byokIDs {
            #expect(id.contains("byok"))
            #expect(!id.contains("basic"))
            #expect(!id.contains("pro"))
        }
        for id in basicIDs {
            #expect(id.contains("basic"))
            #expect(!id.contains("pro"))
            #expect(!id.contains("byok"))
        }
        for id in proIDs {
            #expect(id.contains("pro"))
            #expect(!id.contains("basic"))
            #expect(!id.contains("byok"))
        }
    }
}

// MARK: - StoreKitManager Plan Ranking Tests

@Suite("StoreKitManager Plan Ranking")
struct StoreKitManagerPlanRankingTests {

    @Test("Tier ranks order Unknown < BYOK < Basic < Pro")
    func tierRankOrdering() {
        // Matches worker-side ranks: Unknown=0, BYOK=1, Basic=2, Pro=3
        #expect(StoreKitManager.tierRank(for: "ai.tabmail.byok.monthly") == 1)
        #expect(StoreKitManager.tierRank(for: "ai.tabmail.byok.yearly") == 1)
        #expect(StoreKitManager.tierRank(for: "ai.tabmail.basic.monthly") == 2)
        #expect(StoreKitManager.tierRank(for: "ai.tabmail.pro.yearly") == 3)
        #expect(StoreKitManager.tierRank(for: "com.other.app") == 0)
        #expect(StoreKitManager.tierRank(for: "") == 0)
    }

    @Test("Tier ranks for backend tier strings")
    func tierRankForTierString() {
        #expect(StoreKitManager.tierRank(forTier: "Pro") == 3)
        #expect(StoreKitManager.tierRank(forTier: "Basic") == 2)
        #expect(StoreKitManager.tierRank(forTier: "BYOK") == 1)
        #expect(StoreKitManager.tierRank(forTier: "Unknown") == 0)
        #expect(StoreKitManager.tierRank(forTier: nil) == 0)
        // Display name must NOT be accepted — internal tier strings only
        #expect(StoreKitManager.tierRank(forTier: "Zero") == 0)
    }

    @Test("Plan ranking picks pro over basic and byok")
    func rankingPicksProOverOthers() {
        // Simulate the ranking logic from updateCurrentEntitlements
        let productIDs = ["ai.tabmail.byok.monthly", "ai.tabmail.basic.monthly", "ai.tabmail.pro.yearly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = StoreKitManager.tierRank(for: id)
            if rank > bestRank {
                bestRank = rank
                bestPlan = StoreKitManager.planName(for: id)
            }
        }

        #expect(bestPlan == "Pro")
        #expect(bestRank == 3)
    }

    @Test("Plan ranking picks basic over byok")
    func rankingPicksBasicOverByok() {
        let productIDs = ["ai.tabmail.byok.monthly", "ai.tabmail.basic.monthly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = StoreKitManager.tierRank(for: id)
            if rank > bestRank {
                bestRank = rank
                bestPlan = StoreKitManager.planName(for: id)
            }
        }

        #expect(bestPlan == "Basic")
        #expect(bestRank == 2)
    }

    @Test("Plan ranking with only byok returns BYOK")
    func rankingOnlyByok() {
        let productIDs = ["ai.tabmail.byok.monthly"]
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = StoreKitManager.tierRank(for: id)
            if rank > bestRank {
                bestRank = rank
                bestPlan = StoreKitManager.planName(for: id)
            }
        }

        #expect(bestPlan == "BYOK")
        #expect(bestRank == 1)
    }

    @Test("Plan ranking with empty list returns nil")
    func rankingEmpty() {
        let productIDs: [String] = []
        var bestRank = 0
        var bestPlan: String?

        for id in productIDs {
            let rank = StoreKitManager.tierRank(for: id)
            if rank > bestRank {
                bestRank = rank
                bestPlan = StoreKitManager.planName(for: id)
            }
        }

        #expect(bestPlan == nil)
        #expect(bestRank == 0)
    }

    @Test("Tier-order product sort places byok before basic before pro")
    func tierOrderSort() {
        // Mirrors loadProducts' sort comparator (rank ascending)
        let ids = ["ai.tabmail.pro.monthly", "ai.tabmail.basic.monthly", "ai.tabmail.byok.monthly"]
        let sorted = ids.sorted { StoreKitManager.tierRank(for: $0) < StoreKitManager.tierRank(for: $1) }
        #expect(sorted == ["ai.tabmail.byok.monthly", "ai.tabmail.basic.monthly", "ai.tabmail.pro.monthly"])
    }
}

// MARK: - StoreKitManager Plan Name Tests

@Suite("StoreKitManager Plan Name Mapping")
struct StoreKitManagerPlanNameTests {

    @Test("Pro product IDs return Pro plan name")
    func proNames() {
        #expect(StoreKitManager.planName(for: "ai.tabmail.pro.monthly") == "Pro")
        #expect(StoreKitManager.planName(for: "ai.tabmail.pro.yearly") == "Pro")
    }

    @Test("Basic product IDs return Basic plan name")
    func basicNames() {
        #expect(StoreKitManager.planName(for: "ai.tabmail.basic.monthly") == "Basic")
        #expect(StoreKitManager.planName(for: "ai.tabmail.basic.yearly") == "Basic")
    }

    @Test("BYOK product IDs return backend-facing BYOK plan name (not Zero)")
    func byokNames() {
        // planName must match AccountInfo.planTier values — display mapping is separate
        #expect(StoreKitManager.planName(for: "ai.tabmail.byok.monthly") == "BYOK")
        #expect(StoreKitManager.planName(for: "ai.tabmail.byok.yearly") == "BYOK")
    }

    @Test("Unknown product ID returns Unknown")
    func unknownName() {
        #expect(StoreKitManager.planName(for: "ai.tabmail.enterprise.monthly") == "Unknown")
        #expect(StoreKitManager.planName(for: "com.other.app") == "Unknown")
        #expect(StoreKitManager.planName(for: "") == "Unknown")
    }

    @Test("planName checks contain, not exact match")
    func containCheck() {
        // Edge case: a product ID with both "pro" and "basic" would match "pro" first
        #expect(StoreKitManager.planName(for: "ai.tabmail.pro.basic") == "Pro")
    }

    @Test("displayPlanName maps BYOK to Zero and Trial to Free Trial, passes other tiers through")
    func displayMapping() {
        #expect(StoreKitManager.displayPlanName(forTier: "BYOK") == "Zero")
        #expect(StoreKitManager.displayPlanName(forTier: "Trial") == "Free Trial")
        #expect(StoreKitManager.displayPlanName(forTier: "Basic") == "Basic")
        #expect(StoreKitManager.displayPlanName(forTier: "Pro") == "Pro")
        #expect(StoreKitManager.displayPlanName(forTier: "Unknown") == "Unknown")
    }

    @Test("Trial is not a purchasable tier, so it carries no upgrade rank")
    func trialHasNoRank() {
        // The plan picker's upgrade/downgrade direction is rank-driven; a
        // server-granted trial owns no product and must not outrank one.
        #expect(StoreKitManager.tierRank(forTier: "Trial") == 0)
        #expect(StoreKitManager.tierRank(forTier: "BYOK") == 1)
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
        let ids = ["ai.tabmail.byok.monthly", "ai.tabmail.byok.yearly",
                    "ai.tabmail.basic.monthly", "ai.tabmail.basic.yearly",
                    "ai.tabmail.pro.monthly", "ai.tabmail.pro.yearly"]
        let monthly = ids.filter { $0.contains("monthly") }
        let yearly = ids.filter { $0.contains("yearly") }

        #expect(monthly.count == 3)
        #expect(yearly.count == 3)
        #expect(monthly.allSatisfy { $0.contains("monthly") })
        #expect(yearly.allSatisfy { $0.contains("yearly") })
    }
}

// MARK: - StoreKit Account-Deletion Renewal Authority Tests

@Suite("StoreKit account-deletion renewal authority")
struct StoreKitManagerAccountDeletionRenewalTests {
    private let owner = "11111111-1111-4111-8111-111111111111"

    @Test("Pure signed-status reduction fails closed and preserves renewal precedence")
    @MainActor
    func signedStatusReduction() {
        let matchingRenewing = AccountDeletionStoreKitStatusEvidence.verifiedTransaction(
            productID: "ai.tabmail.byok.monthly",
            appAccountToken: owner.uppercased(),
            renewal: .verified(willAutoRenew: true)
        )
        let matchingNotRenewing = AccountDeletionStoreKitStatusEvidence.verifiedTransaction(
            productID: "ai.tabmail.byok.monthly",
            appAccountToken: owner,
            renewal: .verified(willAutoRenew: false)
        )
        let otherUser = AccountDeletionStoreKitStatusEvidence.verifiedTransaction(
            productID: "ai.tabmail.byok.monthly",
            appAccountToken: "22222222-2222-4222-8222-222222222222",
            renewal: .verified(willAutoRenew: true)
        )
        let otherProduct = AccountDeletionStoreKitStatusEvidence.verifiedTransaction(
            productID: "example.unrelated.product",
            appAccountToken: owner,
            renewal: .verified(willAutoRenew: true)
        )
        let unverifiedRenewal = AccountDeletionStoreKitStatusEvidence.verifiedTransaction(
            productID: "ai.tabmail.byok.monthly",
            appAccountToken: owner,
            renewal: .unverified
        )

        #expect(state(for: []) == .noMatchingSubscription)
        #expect(state(for: [otherUser, otherProduct]) == .noMatchingSubscription)
        #expect(state(for: [matchingNotRenewing]) == .notRenewing)
        #expect(state(for: [matchingRenewing]) == .renewing)
        #expect(state(for: [.unverifiedTransaction]) == .unavailable)
        #expect(state(for: [unverifiedRenewal]) == .unavailable)
        #expect(state(for: [matchingNotRenewing, matchingRenewing]) == .renewing)
        #expect(state(for: [.unverifiedTransaction, matchingRenewing]) == .renewing)
        #expect(state(for: [matchingNotRenewing, otherUser]) == .notRenewing)
    }

    @MainActor
    private func state(
        for evidence: [AccountDeletionStoreKitStatusEvidence]
    ) -> AccountDeletionAppleRenewalState {
        StoreKitManager.accountDeletionRenewalState(
            currentUserId: owner,
            evidence: evidence
        )
    }

}
