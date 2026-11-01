/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

struct PlanPurchaseIdentity: Equatable {
    let userId: String
    let generation: Int
}

enum PlanPurchaseResult: Equatable {
    case purchased(String)
    case cancelled
    case refused(String)
}

/// The production purchase boundary, shared by the plan picker and native tests.
/// Dependencies are per operation, not global overrides or another authority.
@MainActor
enum PlanPurchaseFlow {
    /// Production orchestration keeps signed delivery separate from the current
    /// session's UI/gate completion. A finished purchase still belongs to its
    /// captured token when the user changes accounts during Apple's sheet.
    static func run(
        identity: PlanPurchaseIdentity,
        currentIdentity: () -> PlanPurchaseIdentity?,
        fetchAccount: () async throws -> AccountInfo,
        fetchOffer: () async -> SubscriptionTrialOffer?,
        accountRefreshed: (AccountInfo) -> Void,
        performPurchase: (String) async throws -> String?,
        purchaseFinished: () -> Void,
        deliverSignedPurchase: (String) -> Void,
        currentAccountDidPurchase: () async -> Void
    ) async throws -> PlanPurchaseResult {
        let result = try await purchase(
            identity: identity, currentIdentity: currentIdentity,
            fetchAccount: fetchAccount, fetchOffer: fetchOffer,
            accountRefreshed: accountRefreshed, performPurchase: performPurchase
        )
        purchaseFinished()
        guard case .purchased(let jws) = result else { return result }
        deliverSignedPurchase(jws)
        guard currentIdentity() == identity else { return result }
        await currentAccountDidPurchase()
        return result
    }

    static func purchase(
        identity: PlanPurchaseIdentity,
        currentIdentity: () -> PlanPurchaseIdentity?,
        fetchAccount: () async throws -> AccountInfo,
        fetchOffer: () async -> SubscriptionTrialOffer?,
        accountRefreshed: (AccountInfo) -> Void,
        performPurchase: (String) async throws -> String?
    ) async throws -> PlanPurchaseResult {
        let account = try await fetchAccount()
        guard currentIdentity() == identity else { return accountChanged }
        accountRefreshed(account)
        let offer = await fetchOffer()
        guard currentIdentity() == identity else { return accountChanged }
        if let restriction = SubscriptionTrialPurchasePolicy.restriction(account: account, offer: offer) {
            return .refused(restriction)
        }
        guard let jws = try await performPurchase(identity.userId) else { return .cancelled }
        return .purchased(jws)
    }

    private static var accountChanged: PlanPurchaseResult {
        .refused("Your account changed. Please choose your plan again.")
    }
}
