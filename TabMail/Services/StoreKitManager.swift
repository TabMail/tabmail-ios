/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import StoreKit
import Observation
import Synchronization
import UIKit

/// Outcome of presenting Apple's native subscription-management sheet.
///
/// Three-valued on purpose. Callers distinguish "there was no window scene to
/// present from, so nothing was shown and nothing followed" from "the sheet was
/// requested and StoreKit threw", because the two call for different follow-up:
/// the billing surfaces still refresh after a throw but not after a missing
/// scene, while account deletion refuses on both.
enum SubscriptionManagementPresentation {
    case presented
    case noWindowScene
    case failed(Error)

    /// True only when Apple's sheet was actually presented. A caller that gates
    /// a destructive flow on this — account deletion — therefore fails closed on
    /// both the missing-scene and the thrown-error outcomes.
    var didPresent: Bool {
        if case .presented = self { return true }
        return false
    }
}

enum AccountDeletionStoreKitRenewalEvidence: Equatable, Sendable {
    case unverified
    case verified(willAutoRenew: Bool)
}

enum AccountDeletionStoreKitStatusEvidence: Equatable, Sendable {
    case unverifiedTransaction
    case verifiedTransaction(
        productID: String,
        appAccountToken: String?,
        renewal: AccountDeletionStoreKitRenewalEvidence
    )
}

@Observable @MainActor
final class StoreKitManager {
    var products: [Product] = []
    var purchasedProductIDs: Set<String> = []
    var isAppleSubscriber = false
    var activePlan: String?

    /// The appAccountToken (TabMail user ID) embedded in the active subscription.
    /// If this doesn't match the currently logged-in user, the subscription belongs to a different account.
    var subscriptionOwnerUserId: String?

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

    // MARK: - Subscription Management

    /// Presents Apple's native subscription-management sheet.
    ///
    /// The single place the app looks up a window scene for StoreKit and calls
    /// `AppStore.showManageSubscriptions(in:)`. Each caller keeps its own refresh
    /// policy and error copy by switching on the result, so this helper
    /// deliberately logs nothing and surfaces nothing to the user.
    static func presentManageSubscriptions() async -> SubscriptionManagementPresentation {
        // `Info.plist` sets `UIApplicationSupportsMultipleScenes` to `false`, so
        // the app has at most one `UIWindowScene` and `.first` is deterministic.
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            return .noWindowScene
        }

        do {
            try await AppStore.showManageSubscriptions(in: windowScene)
            return .presented
        } catch {
            return .failed(error)
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

    /// Reads Apple's signed renewal information for the current TabMail user.
    /// Transaction entitlements alone cannot answer this: turning auto-renew
    /// off keeps the current transaction entitled until its paid term ends.
    func accountDeletionRenewalState(
        currentUserId: String
    ) async -> AccountDeletionAppleRenewalState {
        let canonicalUserId = currentUserId.lowercased()

        if products.isEmpty {
            await loadProducts()
        }
        guard let subscription = products.compactMap(\.subscription).first else {
            return .unavailable
        }

        let statuses: [Product.SubscriptionInfo.Status]
        do {
            statuses = try await subscription.status
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[StoreKit] Could not read subscription renewal status: \(error)")
            }
            return .unavailable
        }

        let evidence = statuses.map { status in
            guard case .verified(let transaction) = status.transaction else {
                return AccountDeletionStoreKitStatusEvidence.unverifiedTransaction
            }
            let renewalEvidence: AccountDeletionStoreKitRenewalEvidence
            switch status.renewalInfo {
            case .verified(let renewalInfo):
                renewalEvidence = .verified(willAutoRenew: renewalInfo.willAutoRenew)
            case .unverified:
                renewalEvidence = .unverified
            }
            return .verifiedTransaction(
                productID: transaction.productID,
                appAccountToken: transaction.appAccountToken?.uuidString,
                renewal: renewalEvidence
            )
        }

        return Self.accountDeletionRenewalState(
            currentUserId: canonicalUserId,
            evidence: evidence
        )
    }

    static func accountDeletionRenewalState(
        currentUserId: String,
        evidence: [AccountDeletionStoreKitStatusEvidence]
    ) -> AccountDeletionAppleRenewalState {
        let canonicalUserId = currentUserId.lowercased()
        var foundUnverifiedStatus = false
        var foundRenewalOff = false

        for status in evidence {
            switch status {
            case .unverifiedTransaction:
                // The transaction cannot be safely ruled out as belonging to
                // the current user, so the authority remains unavailable.
                foundUnverifiedStatus = true
            case .verifiedTransaction(let productID, let appAccountToken, let renewal):
                guard Self.productIDs.contains(productID),
                      appAccountToken?.lowercased() == canonicalUserId else {
                    continue
                }
                switch renewal {
                case .unverified:
                    foundUnverifiedStatus = true
                case .verified(willAutoRenew: true):
                    return .renewing
                case .verified(willAutoRenew: false):
                    foundRenewalOff = true
                }
            }
        }

        // An unverified status could itself be the current user's renewal.
        // Its transaction cannot safely be used to rule that out, even if no
        // other verified row matched the user's appAccountToken.
        if foundUnverifiedStatus {
            return .unavailable
        }
        return foundRenewalOff ? .notRenewing : .noMatchingSubscription
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

    /// Whether restoring purchases should open the AI gate for `currentUserId`.
    /// True only when there is an active Apple entitlement that is NOT owned by a
    /// different TabMail account. Fails OPEN when ownership is unknown (no
    /// appAccountToken) so a legitimate restore is never blocked; fails CLOSED only
    /// when we are certain the active entitlement belongs to someone else.
    func shouldOpenGateForRestoredEntitlement(currentUserId: String) -> Bool {
        isAppleSubscriber && !hasAccountMismatch(currentUserId: currentUserId)
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
    /// The matched substrings are PRODUCT-ID fragments, a different namespace
    /// from the tier strings returned here; only the returns are shared.
    nonisolated static func planName(for productId: String) -> String {
        if productId.contains("pro") { return AccountPlanConfig.proTierKey }
        if productId.contains("basic") { return AccountPlanConfig.basicTierKey }
        if productId.contains("byok") { return AccountPlanConfig.byokTierKey }
        return AccountPlanConfig.unknownTierKey
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
    /// `Trial` is deliberately absent: it owns no product, is not purchasable,
    /// and must never outrank one in the plan picker's direction logic.
    nonisolated static func tierRank(forTier tier: String?) -> Int {
        switch tier {
        case AccountPlanConfig.proTierKey: return 3
        case AccountPlanConfig.basicTierKey: return 2
        case AccountPlanConfig.byokTierKey: return 1
        default: return 0
        }
    }

    /// User-facing display name for a backend tier string. DISPLAY-ONLY mapping —
    /// internal ids/tier strings stay "BYOK"/"Trial" everywhere (KV, planQuotas,
    /// product IDs). Site precedent: PLAN_DISPLAY (pricing.js), PLAN_TIER_DISPLAY
    /// (dashboard.js). Tiers not in the map pass through unchanged.
    nonisolated static func displayPlanName(forTier tier: String) -> String {
        switch tier {
        case AccountPlanConfig.byokTierKey: return "Zero"
        case AccountPlanConfig.trialTierKey: return "Free Trial"
        default: return tier
        }
    }

    func monthlyProducts() -> [Product] {
        products.filter { $0.id.contains("monthly") }
    }

    func yearlyProducts() -> [Product] {
        products.filter { $0.id.contains("yearly") }
    }
}
