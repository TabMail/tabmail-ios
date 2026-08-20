/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@MainActor
private enum DeletionCoordinatorFixtures {
    static let futureCancellationAt = Int(
        Date.now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970
    )
    static let futureDeletionDate = ISO8601DateFormatter().string(
        from: Date.now.addingTimeInterval(30 * 24 * 60 * 60)
    )

    static func accountInfo(
        hasSubscription: Bool,
        provider: String? = nil,
        pendingCancellationAt: Int? = nil
    ) throws -> AccountInfo {
        let providerJSON = provider.map { "\"\($0)\"" } ?? "null"
        let pendingJSON = pendingCancellationAt.map {
            "{\"cancel_at\":\($0)}"
        } ?? "null"
        return try JSONDecoder().decode(
            AccountInfo.self,
            from: Data(
                """
                {
                  "logged_in": true,
                  "has_subscription": \(hasSubscription),
                  "subscription_provider": \(providerJSON),
                  "pending_cancellation": \(pendingJSON)
                }
                """.utf8
            )
        )
    }

    static func cancellationResponse(
        scheduled: Bool = true,
        immediate: Bool = false
    ) throws -> BillingClient.CancellationResponse {
        let scheduledJSON = scheduled
            ? "[{\"id\":\"sub_1\",\"cancel_at\":\(futureCancellationAt)}]"
            : "[]"
        let immediateJSON = immediate ? "[\"sub_1\"]" : "[]"
        return try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(
                """
                {
                  "success": true,
                  "scheduled_cancellations": \(scheduledJSON),
                  "immediate_cancellations": \(immediateJSON),
                  "entitlement_state": {"pending_cancellation": null}
                }
                """.utf8
            )
        )
    }

    static func deletionResponse() throws -> BillingClient.DeletionResponse {
        return try JSONDecoder().decode(
            BillingClient.DeletionResponse.self,
            from: Data(
                """
                {"status":"scheduled","deletion_date":"\(futureDeletionDate)"}
                """.utf8
            )
        )
    }

    static func deletionStatus(
        pending: Bool,
        deletionDate: String? = nil
    ) throws -> BillingClient.DeletionStatusResponse {
        let dateJSON = deletionDate.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(
            BillingClient.DeletionStatusResponse.self,
            from: Data(
                """
                {"pending":\(pending),"deletion_date":\(dateJSON)}
                """.utf8
            )
        )
    }
}

@MainActor
@Suite("Account deletion coordinator happy paths")
struct DeletionCoordinatorHappyTests {
    @Test("No subscription reaches deletion without cancellation side effects")
    func noSubscription() async throws {
        var cancelCalls = 0
        var manageCalls = 0
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false)
            },
            cancelStripe: {
                cancelCalls += 1
                return try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: {
                manageCalls += 1
                return true
            },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            progress: { _ in }
        )

        guard case .scheduled = execution else {
            Issue.record("Expected account deletion to be scheduled")
            return
        }
        #expect(cancelCalls == 0)
        #expect(manageCalls == 0)
        #expect(deletionCalls == 1)
    }

    @Test("Stripe cancellation is followed by authority confirmation")
    func stripeSequence() async throws {
        var snapshots = [
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe"
            ),
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe",
                pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
            ),
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe",
                pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
            )
        ]
        var phases: [AccountDeletionSubscriptionCoordinator.Phase] = []
        var events: [String] = []
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                events.append("fetch")
                return snapshots.removeFirst()
            },
            cancelStripe: {
                events.append("cancel")
                return try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                events.append("delete")
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { phases.append($0) }
        )

        guard case .scheduled = execution else {
            Issue.record("Expected account deletion to be scheduled")
            return
        }
        #expect(
            phases == [
                .checking,
                .cancellingStripe,
                .confirmingCancellation,
                .schedulingDeletion
            ]
        )
        #expect(events == ["fetch", "cancel", "fetch", "fetch", "delete"])
        #expect(snapshots.isEmpty)
    }

    @Test("Apple management is followed by authority confirmation")
    func appleSequence() async throws {
        let accountInfo = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "apple"
        )
        var renewalStates: [AccountDeletionAppleRenewalState] = [
            .renewing,
            .notRenewing,
            .notRenewing
        ]
        var manageCalls = 0
        var cancelCalls = 0
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: { accountInfo },
            cancelStripe: {
                cancelCalls += 1
                return try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { renewalStates.removeFirst() },
            manageAppleSubscription: {
                manageCalls += 1
                return true
            },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .scheduled = execution else {
            Issue.record("Expected account deletion to be scheduled")
            return
        }
        #expect(manageCalls == 1)
        #expect(cancelCalls == 0)
        #expect(deletionCalls == 1)
        #expect(renewalStates.isEmpty)
    }
}

@MainActor
@Suite("Account deletion coordinator guards")
struct DeletionCoordinatorGuardTests {
    private struct SheetPresentationFailure: Error {}

    /// The account-deletion gate is a COMPOSITION: `AccountDeletionView`'s
    /// `presentAppleSubscriptions()` maps a `SubscriptionManagementPresentation`
    /// through `didPresent`, and this coordinator's
    /// `guard await manageAppleSubscription()` consumes that `Bool`. Every other
    /// test in this file injects a `Bool` literal and therefore never sees an
    /// outcome, while `StoreKitSubscriptionManagementPresentationTests` sees the
    /// outcome but never the gate — so the composition, which IS the fail-closed
    /// property, was pinned by neither. This injects the real mapping instead of
    /// a literal, needing no live `UIWindowScene` (see `IOS-TEST-004`).
    @Test("Every unpresented subscription sheet blocks deletion through the real mapping")
    func unpresentedSubscriptionSheetsBlockDeletion() async throws {
        let activeApple = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "apple"
        )
        let unpresented: [SubscriptionManagementPresentation] = [
            .noWindowScene,
            .failed(SheetPresentationFailure())
        ]

        for outcome in unpresented {
            var gateReads = 0
            let blocked = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
                fetchAccountInfo: { activeApple },
                cancelStripe: {
                    try DeletionCoordinatorFixtures.cancellationResponse()
                },
                appleRenewalState: { .renewing },
                manageAppleSubscription: {
                    gateReads += 1
                    return outcome.didPresent
                },
                waitBeforeRetry: {},
                progress: { _ in }
            )
            #expect(blocked == .appleManagementUnavailable)
            // Non-vacuity: the outcome was really mapped, not stepped over.
            #expect(gateReads == 1)
        }

        // Companion half. The same composition on `.presented` must NOT block at
        // the gate. Renewal is still on afterwards, so the coordinator stops one
        // step later on a different outcome — that difference is the evidence the
        // gate was passed rather than never reached.
        var renewalReads = 0
        let pastTheGate = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
            maxConfirmationAttempts: 2,
            fetchAccountInfo: { activeApple },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: {
                renewalReads += 1
                return .renewing
            },
            manageAppleSubscription: {
                SubscriptionManagementPresentation.presented.didPresent
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )
        #expect(pastTheGate == .appleConfirmationPending)
        // Non-vacuity for the companion half: the post-gate confirmation loop is
        // the only thing that re-reads renewal, so more than the single pre-gate
        // read proves execution continued past the gate.
        #expect(renewalReads > 1)
    }

    @Test("Stripe stops before deletion when cancellation lacks evidence")
    func stripeMissingEvidence() async throws {
        var fetchCalls = 0
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                fetchCalls += 1
                return try DeletionCoordinatorFixtures.accountInfo(
                    hasSubscription: true,
                    provider: "stripe"
                )
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse(scheduled: false)
            },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected deletion to be blocked")
            return
        }
        #expect(outcome == .cancellationNotConfirmed)
        #expect(fetchCalls == 1)
        #expect(deletionCalls == 0)
    }

    @Test("Stripe stops when authority never reports pending cancellation")
    func stripeAuthorityLag() async throws {
        var fetchCalls = 0
        var waitCalls = 0
        let outcome = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
            maxConfirmationAttempts: 3,
            fetchAccountInfo: {
                fetchCalls += 1
                return try DeletionCoordinatorFixtures.accountInfo(
                    hasSubscription: true,
                    provider: "stripe"
                )
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            waitBeforeRetry: { waitCalls += 1 },
            progress: { _ in }
        )

        #expect(outcome == .cancellationStillUpdating)
        #expect(fetchCalls == 4)
        #expect(waitCalls == 2)
    }

    @Test("Apple sheet failure and unchanged renewal both stop deletion")
    func appleStopsWithoutProof() async throws {
        let activeApple = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "apple"
        )
        let unavailable = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
            fetchAccountInfo: { activeApple },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { .renewing },
            manageAppleSubscription: { false },
            waitBeforeRetry: {},
            progress: { _ in }
        )
        #expect(unavailable == .appleManagementUnavailable)

        let stillRenewing = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
            maxConfirmationAttempts: 2,
            fetchAccountInfo: { activeApple },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { .renewing },
            manageAppleSubscription: { true },
            waitBeforeRetry: {},
            progress: { _ in }
        )
        #expect(stillRenewing == .appleConfirmationPending)
    }

    @Test("Stale Apple pending and negative backend state cannot bypass local renewal")
    func staleAppleBackendCannotBypassLocalRenewal() async throws {
        for accountInfo in [
            try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false),
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "apple",
                pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
            )
        ] {
            var deletionCalls = 0
            let execution = try await AccountDeletionSubscriptionCoordinator.execute(
                maxConfirmationAttempts: 2,
                fetchAccountInfo: { accountInfo },
                cancelStripe: {
                    try DeletionCoordinatorFixtures.cancellationResponse()
                },
                appleRenewalState: { .renewing },
                manageAppleSubscription: { true },
                scheduleDeletion: {
                    deletionCalls += 1
                    return try DeletionCoordinatorFixtures.deletionResponse()
                },
                waitBeforeRetry: {},
                progress: { _ in }
            )

            guard case .blocked(let outcome) = execution else {
                Issue.record("Expected stale Apple backend state to fail closed")
                continue
            }
            #expect(outcome == .appleConfirmationPending)
            #expect(deletionCalls == 0)
        }
    }

    @Test("Final Apple re-read blocks re-enabled renewal")
    func appleReenabledBeforeDeletion() async throws {
        var states: [AccountDeletionAppleRenewalState] = [
            .notRenewing,
            .renewing
        ]
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false)
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { states.removeFirst() },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected final Apple renewal to block deletion")
            return
        }
        #expect(outcome == .appleConfirmationPending)
        #expect(deletionCalls == 0)
        #expect(states.isEmpty)
    }

    @Test("Final backend re-read blocks a Stripe reactivation")
    func stripeReactivatedBeforeDeletion() async throws {
        let activeStripe = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "stripe"
        )
        let pendingStripe = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "stripe",
            pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
        )
        var snapshots = [activeStripe, pendingStripe, activeStripe]
        var deletionCalls = 0

        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: { snapshots.removeFirst() },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected the final Stripe reactivation to block deletion")
            return
        }
        #expect(outcome == .cancellationStillUpdating)
        #expect(deletionCalls == 0)
        #expect(snapshots.isEmpty)
    }

    @Test("An active Apple backend entitlement without a matching StoreKit row fails closed")
    func appleAccountMismatchStopsDeletion() async throws {
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(
                    hasSubscription: true,
                    provider: "apple"
                )
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { .noMatchingSubscription },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected the StoreKit/backend conflict to block deletion")
            return
        }
        #expect(outcome == .appleStatusUnavailable)
        #expect(deletionCalls == 0)
    }
}

@MainActor
@Suite("Account deletion coordinator request boundaries")
struct DeletionCoordinatorRequestBoundaryTests {
    @Test("A lost deletion response is reconciled as scheduled")
    func lostSchedulingResponseIsReconciled() async throws {
        enum TestError: Error { case scheduling }
        var snapshots = [
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe"
            ),
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe",
                pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
            ),
            try DeletionCoordinatorFixtures.accountInfo(
                hasSubscription: true,
                provider: "stripe",
                pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
            )
        ]
        var events: [String] = []
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                events.append("fetch")
                return snapshots.removeFirst()
            },
            cancelStripe: {
                events.append("cancel")
                return try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                events.append("delete")
                throw TestError.scheduling
            },
            fetchDeletionStatus: {
                events.append("status")
                return try DeletionCoordinatorFixtures.deletionStatus(
                    pending: true,
                    deletionDate: DeletionCoordinatorFixtures.futureDeletionDate
                )
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .scheduled(let confirmedDate) = execution else {
            Issue.record("Expected status reconciliation to confirm scheduling")
            return
        }
        #expect(confirmedDate == DeletionCoordinatorFixtures.futureDeletionDate)
        #expect(events == ["fetch", "cancel", "fetch", "fetch", "delete", "status"])
        #expect(snapshots.isEmpty)
    }

    @Test("A negative status read preserves an ambiguous deletion request")
    func negativeStatusDoesNotOutrunTheOriginalRequest() async throws {
        enum TestError: Error { case scheduling }
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false)
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            scheduleDeletion: { throw TestError.scheduling },
            fetchDeletionStatus: {
                try DeletionCoordinatorFixtures.deletionStatus(pending: false)
            },
            progress: { _ in }
        )

        guard case .schedulingNotConfirmed = execution else {
            Issue.record("Expected a negative status read to remain ambiguous")
            return
        }
    }

    @Test("An unreadable deletion status preserves the ambiguous outcome")
    func schedulingFailureRemainsUnknown() async throws {
        enum TestError: Error { case scheduling, status }
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false)
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            scheduleDeletion: { throw TestError.scheduling },
            fetchDeletionStatus: { throw TestError.status },
            progress: { _ in }
        )

        guard case .schedulingNotConfirmed = execution else {
            Issue.record("Expected an explicitly ambiguous scheduling result")
            return
        }
    }

    @Test("Apple authority unavailable blocks before the deletion request")
    func unavailableAppleAuthorityStopsDeletion() async throws {
        var fetchCalls = 0
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                fetchCalls += 1
                return try DeletionCoordinatorFixtures.accountInfo(hasSubscription: false)
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            appleRenewalState: { .unavailable },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected unavailable Apple authority to fail closed")
            return
        }
        #expect(outcome == .appleStatusUnavailable)
        #expect(fetchCalls == 0)
        #expect(deletionCalls == 0)
    }

    @Test("Unknown active authority blocks the deletion request")
    func unknownAuthorityStopsDeletion() async throws {
        var deletionCalls = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                try DeletionCoordinatorFixtures.accountInfo(
                    hasSubscription: true,
                    provider: nil
                )
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { true },
            scheduleDeletion: {
                deletionCalls += 1
                return try DeletionCoordinatorFixtures.deletionResponse()
            },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        guard case .blocked(let outcome) = execution else {
            Issue.record("Expected deletion to be blocked")
            return
        }
        #expect(outcome == .unsupportedActiveProvider)
        #expect(deletionCalls == 0)
    }

    @Test("A transient authority read retries before confirming")
    func transientAuthorityRead() async throws {
        enum TestError: Error { case transient }
        let activeStripe = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "stripe"
        )
        let pendingStripe = try DeletionCoordinatorFixtures.accountInfo(
            hasSubscription: true,
            provider: "stripe",
            pendingCancellationAt: DeletionCoordinatorFixtures.futureCancellationAt
        )
        var fetchCalls = 0
        let outcome = try await AccountDeletionSubscriptionCoordinator.prepareForDeletion(
            fetchAccountInfo: {
                fetchCalls += 1
                switch fetchCalls {
                case 1: return activeStripe
                case 2: throw TestError.transient
                default: return pendingStripe
                }
            },
            cancelStripe: {
                try DeletionCoordinatorFixtures.cancellationResponse()
            },
            manageAppleSubscription: { false },
            waitBeforeRetry: {},
            progress: { _ in }
        )

        #expect(outcome == .ready)
        #expect(fetchCalls == 3)
    }

    @Test("A cancellation request error never reaches account deletion")
    func cancellationRequestErrorStopsDeletion() async throws {
        enum TestError: Error { case cancellation }
        var deletionCalls = 0

        do {
            _ = try await AccountDeletionSubscriptionCoordinator.execute(
                fetchAccountInfo: {
                    try DeletionCoordinatorFixtures.accountInfo(
                        hasSubscription: true,
                        provider: "stripe"
                    )
                },
                cancelStripe: { throw TestError.cancellation },
                manageAppleSubscription: { false },
                scheduleDeletion: {
                    deletionCalls += 1
                    return try DeletionCoordinatorFixtures.deletionResponse()
                },
                progress: { _ in }
            )
            Issue.record("Expected the cancellation error to propagate")
        } catch TestError.cancellation {
            // Expected.
        }

        #expect(deletionCalls == 0)
    }

    @Test("Cancelling the coordinator task during confirmation never reaches deletion")
    func taskCancellationStopsDeletion() async throws {
        var deletionCalls = 0
        var fetchCalls = 0
        var waitStarted = false

        let task = Task {
            try await AccountDeletionSubscriptionCoordinator.execute(
                fetchAccountInfo: {
                    fetchCalls += 1
                    return try DeletionCoordinatorFixtures.accountInfo(
                        hasSubscription: true,
                        provider: "stripe"
                    )
                },
                cancelStripe: {
                    try DeletionCoordinatorFixtures.cancellationResponse()
                },
                manageAppleSubscription: { false },
                scheduleDeletion: {
                    deletionCalls += 1
                    return try DeletionCoordinatorFixtures.deletionResponse()
                },
                waitBeforeRetry: {
                    waitStarted = true
                    try await Task.sleep(for: .seconds(60))
                },
                progress: { _ in }
            )
        }

        while !waitStarted {
            await Task.yield()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation of the coordinator task to propagate")
        } catch is CancellationError {
            // Expected.
        }

        #expect(fetchCalls == 2)
        #expect(deletionCalls == 0)
    }
}

@Suite("Account deletion UI policy")
struct AccountDeletionUIPolicyTests {
    @Test("The attempt gate rejects overlapping activation until completion")
    func attemptGateIsNotReentrant() {
        var gate = AccountDeletionAttemptGate()

        let firstAttempt = gate.begin()
        #expect(firstAttempt)
        #expect(gate.isRunning)
        let overlappingAttempt = gate.begin()
        #expect(!overlappingAttempt)

        gate.finish()
        #expect(!gate.isRunning)
        let laterAttempt = gate.begin()
        #expect(laterAttempt)
    }

    @Test("Grace-period copy does not promise paid access through deletion")
    func gracePeriodCopyIsTruthful() {
        let copy = AccountDeletionCopy.gracePeriodDescription(days: 30)
        #expect(copy.contains("account remains available"))
        #expect(copy.contains("paid access may end sooner"))
        #expect(!copy.contains("keeps working normally"))
    }

    @Test("Keep Account explicitly preserves non-renewal and ended-trial loss")
    func keepAccountCopyPinsTheRoundTripConsequence() {
        #expect(AccountDeletionCopy.keepAccountConsequence.contains("deletion only"))
        #expect(AccountDeletionCopy.keepAccountConsequence.contains("If a subscription or trial"))
        #expect(AccountDeletionCopy.keepAccountConsequence.contains("renewal stays off"))
        #expect(AccountDeletionCopy.keepAccountConsequence.contains("ended trial isn’t restored"))
    }

    @Test("Apple propagation copy does not claim Apple still shows renewal")
    func appleConfirmationCopyIsAuthorityScoped() {
        #expect(AccountDeletionCopy.appleConfirmationPending.contains("couldn’t confirm"))
        #expect(!AccountDeletionCopy.appleConfirmationPending.contains("Apple still shows"))
    }

    @Test("Unknown scheduling copy does not claim the request failed")
    func schedulingAmbiguityCopyIsTruthful() {
        #expect(AccountDeletionCopy.schedulingNotConfirmed.contains("couldn’t confirm whether"))
        #expect(AccountDeletionCopy.schedulingNotConfirmed.contains("safe to retry"))
        #expect(!AccountDeletionCopy.schedulingNotConfirmed.contains("deletion banner"))
        #expect(!AccountDeletionCopy.schedulingNotConfirmed.contains("wasn’t scheduled"))
    }
}

@Suite("Account deletion production wiring")
struct AccountDeletionProductionWiringTests {
    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("The destructive button synchronously claims the gate and uses the coordinator")
    func destructiveButtonUsesTheGuardedCoordinator() throws {
        let source = try projectSource("TabMail/Views/Settings/AccountDeletionView.swift")
        let buttonStart = try #require(source.range(of: "Button(role: .destructive) {"))
        let buttonEnd = try #require(
            source.range(of: "} label: {", range: buttonStart.upperBound..<source.endIndex)
        )
        let buttonAction = source[buttonStart.upperBound..<buttonEnd.lowerBound]
        let functionStart = try #require(source.range(of: "private func startDeletion()"))
        let functionEnd = try #require(
            source.range(
                of: "private func deleteAccount() async",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let startFunction = source[functionStart.lowerBound..<functionEnd.lowerBound]

        #expect(buttonAction.contains("startDeletion()"))
        #expect(startFunction.contains("guard deletionAttemptGate.begin() else { return }"))
        #expect(startFunction.contains("await deleteAccount()"))
        #expect(source.contains("AccountDeletionSubscriptionCoordinator.execute("))
        #expect(source.contains("appleRenewalState:"))
        #expect(source.contains("fetchDeletionStatus:"))
        #expect(source.contains("case .schedulingNotConfirmed:"))
        #expect(!source.contains("Apple still shows auto-renew on"))
    }

    @Test("The global Keep Account banner stays neutral about subscription restoration")
    func keepAccountBannerDoesNotAssumeCancellationProvenance() throws {
        let source = try projectSource("TabMail/Views/RootView.swift")

        #expect(source.contains("Text(\"Keep Account\")"))
        #expect(source.contains("Tap Keep Account to stop the account deletion."))
        #expect(!source.contains("AccountDeletionCopy.keepAccountConsequence"))
    }
}
