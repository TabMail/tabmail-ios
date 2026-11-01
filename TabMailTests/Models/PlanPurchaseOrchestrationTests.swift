/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@MainActor
struct PlanPurchaseOrchestrationTests {
    private let identity = PlanPurchaseIdentity(userId: "test-account-a", generation: 1)
    private enum Failure: Error { case refresh, purchase }

    @Test func unchangedOwnerCompletesAfterExactlyOneSignedDelivery() async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 1, reference: Date())
        var events: [String] = []
        var delivered: [String] = []
        let result = try await PlanPurchaseFlow.run(
            identity: identity, currentIdentity: { identity },
            fetchAccount: { events.append("account"); return account },
            fetchOffer: { events.append("offer"); return .init(value: 1, unit: .week) },
            accountRefreshed: { _ in events.append("display") },
            performPurchase: { userId in
                #expect(userId == identity.userId)
                events.append("purchase")
                return "synthetic-signed-jws"
            },
            purchaseFinished: { events.append("finished") },
            deliverSignedPurchase: { delivered.append($0); events.append("deliver") },
            currentAccountDidPurchase: { events.append("current-account") }
        )
        #expect(result == .purchased("synthetic-signed-jws"))
        #expect(delivered == ["synthetic-signed-jws"])
        #expect(events == ["account", "display", "offer", "purchase", "finished", "deliver", "current-account"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func suspendedPurchaseDeliversForItsOwnerWithoutUpdatingTheNewSession(changeUser: Bool) async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 1, reference: Date())
        var current = identity
        var displayedAccount = "account-a"
        var gateOpen = false
        var delivered: [String] = []
        var completions = 0
        var finished = 0
        let started = AsyncStream<Void>.makeStream()
        let response = AsyncStream<String?>.makeStream()
        let operation = Task { @MainActor in
            try await PlanPurchaseFlow.run(
                identity: identity, currentIdentity: { current },
                fetchAccount: { account }, fetchOffer: { .init(value: 1, unit: .week) },
                accountRefreshed: { _ in displayedAccount = "account-a" },
                performPurchase: { userId in
                    #expect(userId == identity.userId)
                    started.continuation.yield(())
                    var iterator = response.stream.makeAsyncIterator()
                    return await iterator.next() ?? nil
                },
                purchaseFinished: { finished += 1 },
                deliverSignedPurchase: { delivered.append($0) },
                currentAccountDidPurchase: {
                    completions += 1
                    gateOpen = true
                    displayedAccount = "purchased-account-a"
                }
            )
        }
        var startIterator = started.stream.makeAsyncIterator()
        _ = await startIterator.next()
        current = .init(userId: changeUser ? "test-account-b" : identity.userId,
                        generation: identity.generation + 1)
        displayedAccount = "current-session"
        response.continuation.yield("synthetic-signed-jws")
        response.continuation.finish()
        started.continuation.finish()
        let result = try await operation.value
        #expect(result == .purchased("synthetic-signed-jws"))
        #expect(delivered == ["synthetic-signed-jws"])
        #expect(finished == 1)
        #expect(completions == 0)
        #expect(gateOpen == false)
        #expect(displayedAccount == "current-session")
    }

    @Test func orchestrationUsesThePreservedExpiryBoundary() async throws {
        let account = try WhoamiFixture.runningSignupTrial(daysLeft: 12, reference: Date())
        var purchases = 0
        var deliveries = 0
        var completions = 0
        var finished = 0
        let result = try await PlanPurchaseFlow.run(
            identity: identity, currentIdentity: { identity },
            fetchAccount: { account }, fetchOffer: { .init(value: 1, unit: .week) },
            accountRefreshed: { _ in },
            performPurchase: { _ in purchases += 1; return "must-not-purchase" },
            purchaseFinished: { finished += 1 },
            deliverSignedPurchase: { _ in deliveries += 1 },
            currentAccountDidPurchase: { completions += 1 }
        )
        guard case .refused = result else { Issue.record("Orchestration bypassed the preserved-expiry boundary"); return }
        #expect(purchases == 0)
        #expect(deliveries == 0 && completions == 0)
        #expect(finished == 1)
    }

    @Test func cancelledPurchaseDoesNotDeliverOrComplete() async throws {
        let account = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        var delivered = 0
        var completed = 0
        var finished = 0
        let result = try await PlanPurchaseFlow.run(
            identity: identity, currentIdentity: { identity },
            fetchAccount: { account }, fetchOffer: { nil }, accountRefreshed: { _ in },
            performPurchase: { _ in nil }, purchaseFinished: { finished += 1 },
            deliverSignedPurchase: { _ in delivered += 1 },
            currentAccountDidPurchase: { completed += 1 }
        )
        #expect(result == .cancelled)
        #expect(finished == 1)
        #expect(delivered == 0 && completed == 0)
    }

    @Test(arguments: [true, false])
    func failedRefreshOrPurchaseDoesNotDeliverOrComplete(failDuringRefresh: Bool) async throws {
        let account = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        var delivered = 0
        var completed = 0
        do {
            _ = try await PlanPurchaseFlow.run(
                identity: identity, currentIdentity: { identity },
                fetchAccount: { if failDuringRefresh { throw Failure.refresh }; return account },
                fetchOffer: { nil }, accountRefreshed: { _ in },
                performPurchase: { _ in throw Failure.purchase }, purchaseFinished: {},
                deliverSignedPurchase: { _ in delivered += 1 },
                currentAccountDidPurchase: { completed += 1 }
            )
            Issue.record("Orchestration swallowed a failure")
        } catch {
            #expect(error is Failure)
        }
        #expect(delivered == 0 && completed == 0)
    }
}
