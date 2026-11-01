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
