/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import StoreKit
import Observation
import Synchronization

@Observable @MainActor
final class StoreKitManager {
    var products: [Product] = []
    var purchasedProductIDs: Set<String> = []
    var isAppleSubscriber = false
    var activePlan: String?

    /// The appAccountToken (TabMail user ID) embedded in the active subscription.
    /// If this doesn't match the currently logged-in user, the subscription belongs to a different account.
    var subscriptionOwnerUserId: String?

    /// Whether the user is eligible for the introductory offer (2-week free trial).
    /// True if the user has never redeemed an intro offer in the TabMail Plans subscription group.
    var isEligibleForTrial = false

    private static let productIDs: Set<String> = [
        "ai.tabmail.byok.monthly",
        "ai.tabmail.byok.yearly",
        "ai.tabmail.basic.monthly",
        "ai.tabmail.basic.yearly",
        "ai.tabmail.pro.monthly",
        "ai.tabmail.pro.yearly",
    ]

    private let transactionListener = Mutex<Task<Void, Never>?>(nil)

    func start() {
        let task = listenForTransactions()
        transactionListener.withLock { $0 = task }
        Task {
            await loadProducts()
            await updateCurrentEntitlements()
            await checkTrialEligibility()
        }
    }

    deinit {
        transactionListener.withLock { $0?.cancel() }
    }

    /// Whether the last `loadProducts()` call failed or returned empty.
    var productsLoadError: String?

    // MARK: - Load Products

    func loadProducts() async {
        productsLoadError = nil
        print("[StoreKit] Loading products for IDs: \(Self.productIDs)")
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            // Explicit tier-order sort (Zero → Basic → Pro) so the plan picker
            // shows the lowest tier first regardless of regional pricing.
            products = storeProducts.sorted {
                let lhs = Self.tierRank(for: $0.id)
                let rhs = Self.tierRank(for: $1.id)
                if lhs != rhs { return lhs < rhs }
                return $0.price < $1.price
            }
            if products.isEmpty {
                print("[StoreKit] Product.products returned empty — products may not be configured in App Store Connect")
                productsLoadError = "No plans available. Products may not be configured in App Store Connect yet."
            } else {
                print("[StoreKit] Loaded \(products.count) products: \(products.map { "\($0.id) @ \($0.displayPrice)" })")
                productsLoadError = nil
            }
        } catch {
            print("[StoreKit] Failed to load products: \(error)")
            productsLoadError = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Failed to load plans: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    /// Purchase a product. Returns the signed transaction JWS on success, nil on cancel/pending.
    func purchase(_ product: Product, userId: String) async throws -> String? {
        guard let uuid = UUID(uuidString: userId) else {
            print("[StoreKit] Invalid userId for appAccountToken: \(userId.prefix(8))...")
            return nil
        }

        let result = try await product.purchase(options: [
            .appAccountToken(uuid),
        ])

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                print("[StoreKit] Transaction verification failed")
                return nil
            }
            let jwsRepresentation = verification.jwsRepresentation
            await transaction.finish()
            await updateCurrentEntitlements()
            await checkTrialEligibility()
            print("[StoreKit] Purchase succeeded: \(product.id)")
            return jwsRepresentation

        case .userCancelled:
            print("[StoreKit] User cancelled purchase")
            return nil

        case .pending:
            print("[StoreKit] Purchase pending (Ask to Buy, etc.)")
            return nil

        @unknown default:
            return nil
        }
    }

    // MARK: - Restore

    /// Result message from last restore attempt.
    var restoreResult: String?

    func restorePurchases() async {
        restoreResult = nil
        print("[StoreKit] Starting AppStore.sync()...")
        do {
            try await AppStore.sync()
            await updateCurrentEntitlements()
            await checkTrialEligibility()
            if purchasedProductIDs.isEmpty {
                restoreResult = "No active subscriptions found for this Apple ID."
                print("[StoreKit] Restore completed — no entitlements found")
            } else {
                restoreResult = "Restored: \(activePlan.map { Self.displayPlanName(forTier: $0) } ?? "subscription")"
                print("[StoreKit] Restore completed — found: \(purchasedProductIDs)")
            }
        } catch {
            restoreResult = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Restore failed: \(error.localizedDescription)"
            print("[StoreKit] Restore failed: \(error)")
        }
    }

    // MARK: - Entitlements

    func updateCurrentEntitlements() async {
        var purchased = Set<String>()
        var bestPlan: String?
        var bestRank = 0
        var ownerUserId: String?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // Skip expired subscriptions (currentEntitlements can briefly include them)
            if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                print("[StoreKit] Skipping expired entitlement: \(transaction.productID) expired \(expirationDate)")
                continue
            }
            purchased.insert(transaction.productID)
            // Prefer highest tier: Pro (3) > Basic (2) > BYOK/Zero (1)
            let rank = Self.tierRank(for: transaction.productID)
            if rank > bestRank {
                bestRank = rank
                bestPlan = Self.planName(for: transaction.productID)
            }
            if let token = transaction.appAccountToken {
                ownerUserId = token.uuidString.lowercased()
            }
        }

        purchasedProductIDs = purchased
        isAppleSubscriber = !purchased.isEmpty
        activePlan = bestPlan
        subscriptionOwnerUserId = ownerUserId
        print("[StoreKit] Current entitlements: \(purchased), activePlan: \(bestPlan ?? "none"), owner: \(ownerUserId?.prefix(8) ?? "none")")
    }

    /// Returns the JWS representation of the latest active entitlement, if any.
    /// Used to send to backend for immediate verification after restore.
    func latestEntitlementJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified = result else { continue }
            let transaction = result  // VerificationResult
            return transaction.jwsRepresentation
        }
        return nil
    }

    /// Returns true if the Apple ID has an active subscription that belongs to a different TabMail account.
    func hasAccountMismatch(currentUserId: String) -> Bool {
        guard isAppleSubscriber, let owner = subscriptionOwnerUserId else { return false }
        return owner != currentUserId.lowercased()
    }

    // MARK: - Trial Eligibility

    /// Check if the user is eligible for the introductory offer (2-week free trial).
    /// Eligibility is per subscription group, but it must be read from a product that
    /// actually HAS an intro offer — Zero (BYOK) has none and sorts first, so
    /// `products.first` would wrongly report ineligible.
    func checkTrialEligibility() async {
        guard let product = products.first(where: { $0.subscription?.introductoryOffer != nil }),
              let subscription = product.subscription else {
            isEligibleForTrial = false
            return
        }
        isEligibleForTrial = await subscription.isEligibleForIntroOffer
        print("[StoreKit] Trial eligibility: \(isEligibleForTrial)")
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.updateCurrentEntitlements()
                print("[StoreKit] Transaction update: \(transaction.productID)")
            }
        }
    }

    // MARK: - Helpers

    /// Backend-facing tier name — must match `AccountInfo.planTier` values ("BYOK", not "Zero").
    nonisolated static func planName(for productId: String) -> String {
        if productId.contains("pro") { return "Pro" }
        if productId.contains("basic") { return "Basic" }
        if productId.contains("byok") { return "BYOK" }
        return "Unknown"
    }

    /// Tier ranking for upgrade/downgrade direction: Unknown 0 < BYOK/Zero 1 < Basic 2 < Pro 3.
    /// Matches the worker-side ranks (billing-worker planInfo, apple-webhook PRODUCT_MAP).
    nonisolated static func tierRank(for productId: String) -> Int {
        if productId.contains("pro") { return 3 }
        if productId.contains("basic") { return 2 }
        if productId.contains("byok") { return 1 }
        return 0
    }

    /// Rank for a backend tier string ("Pro"/"Basic"/"BYOK"), nil/unknown → 0.
    nonisolated static func tierRank(forTier tier: String?) -> Int {
        switch tier {
        case "Pro": return 3
        case "Basic": return 2
        case "BYOK": return 1
        default: return 0
        }
    }

    /// User-facing display name for a backend tier string. DISPLAY-ONLY mapping —
    /// internal ids/tier strings stay "BYOK" everywhere (KV, planQuotas, product IDs).
    /// Site precedent: PLAN_DISPLAY (pricing.js), PLAN_TIER_DISPLAY (dashboard.js).
    nonisolated static func displayPlanName(forTier tier: String) -> String {
        tier == "BYOK" ? "Zero" : tier
    }

    func monthlyProducts() -> [Product] {
        products.filter { $0.id.contains("monthly") }
    }

    func yearlyProducts() -> [Product] {
        products.filter { $0.id.contains("yearly") }
    }
}
