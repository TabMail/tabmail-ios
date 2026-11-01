/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@MainActor
struct PlanPurchaseFlowTests {
    private let identity = PlanPurchaseIdentity(userId: "test-account-a", generation: 1)
    private enum Failure: Error { case refresh, purchase }

    @Test func allowedPurchaseFollowsFreshAccountAndOffer() async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: Date())
        var events: [String] = []
        let result = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
            fetchAccount: { events.append("account"); return account },
            fetchOffer: { events.append("offer"); return .init(value: 1, unit: .week) },
            accountRefreshed: { _ in events.append("display") },
            performPurchase: { id in #expect(id == identity.userId); events.append("purchase"); return "verified-jws" })
        #expect(events == ["account", "display", "offer", "purchase"])
        #expect(result == .purchased("verified-jws"))
    }

    @Test(arguments: [true, false])
    func protectedPromiseNeverInvokesPurchase(hasOffer: Bool) async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 12, reference: Date())
        var purchases = 0
        let result = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
            fetchAccount: { account }, fetchOffer: { hasOffer ? .init(value: 1, unit: .week) : nil },
            accountRefreshed: { _ in }, performPurchase: { _ in purchases += 1; return "must-not-purchase" })
        guard case .refused = result else { Issue.record("Promised free time was not protected"); return }
        #expect(purchases == 0)
    }

    @Test func ineligibleBuyerKeepsEvenTheLastSignupDay() async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 0.1, reference: Date())
        var purchases = 0
        _ = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
            fetchAccount: { account }, fetchOffer: { nil }, accountRefreshed: { _ in },
            performPurchase: { _ in purchases += 1; return nil })
        #expect(purchases == 0)
    }

    @Test func failedAccountRefreshDoesNotReadOfferOrPurchase() async {
        var effects: [String] = []
        do {
            _ = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
                fetchAccount: { throw Failure.refresh }, fetchOffer: { effects.append("offer"); return nil },
                accountRefreshed: { _ in effects.append("display") },
                performPurchase: { _ in effects.append("purchase"); return nil })
            Issue.record("Failed account authority was ignored")
        } catch {
            #expect(error is Failure)
        }
        #expect(effects.isEmpty)
    }

    @Test(arguments: [true, false])
    func accountSwitchAfterEitherRefreshPreventsPurchase(duringAccount: Bool) async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 1, reference: Date())
        var current: PlanPurchaseIdentity? = identity
        let next = PlanPurchaseIdentity(userId: "test-account-b", generation: 2)
        var purchases = 0
        var displays = 0
        let result = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { current },
            fetchAccount: { if duringAccount { current = next }; return account },
            fetchOffer: { current = next; return .init(value: 1, unit: .week) },
            accountRefreshed: { _ in displays += 1 },
            performPurchase: { _ in purchases += 1; return "must-not-purchase" })
        guard case .refused = result else { Issue.record("Changed account was accepted"); return }
        #expect(purchases == 0)
        #expect(displays == (duringAccount ? 0 : 1))
    }

    @Test func signOutDuringOfferRefreshPreventsPurchase() async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 1, reference: Date())
        var current: PlanPurchaseIdentity? = identity
        var purchases = 0
        _ = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { current },
            fetchAccount: { account }, fetchOffer: { current = nil; return .init(value: 1, unit: .week) },
            accountRefreshed: { _ in }, performPurchase: { _ in purchases += 1; return nil })
        #expect(purchases == 0)
    }

    @Test func endedSignupCanPurchaseAndCancellationRemainsCancellation() async throws {
        let account = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        var purchases = 0
        let result = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
            fetchAccount: { account }, fetchOffer: { nil }, accountRefreshed: { _ in },
            performPurchase: { _ in purchases += 1; return nil })
        #expect(purchases == 1)
        #expect(result == .cancelled)
    }

    @Test func purchaseFailureIsSurfaced() async throws {
        let account = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        do {
            _ = try await PlanPurchaseFlow.purchase(identity: identity, currentIdentity: { identity },
                fetchAccount: { account }, fetchOffer: { nil }, accountRefreshed: { _ in },
                performPurchase: { _ in throw Failure.purchase })
            Issue.record("Purchase failure was swallowed")
        } catch {
            #expect(error is Failure)
        }
    }
}
