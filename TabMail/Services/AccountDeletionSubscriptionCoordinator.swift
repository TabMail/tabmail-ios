/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum AccountDeletionAppleRenewalState: Equatable, Sendable {
    case renewing
    case notRenewing
    case noMatchingSubscription
    case unavailable

    var permitsDeletion: Bool {
        self == .notRenewing || self == .noMatchingSubscription
    }
}

struct AccountDeletionAttemptGate: Equatable {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func finish() {
        isRunning = false
    }
}

enum AccountDeletionCopy {
    static func gracePeriodDescription(days: Int) -> String {
        "Nothing is deleted today. Your TabMail account is scheduled for deletion " +
            "\(days) days from now. Your account remains available until then, but paid access " +
            "may end sooner when your current subscription or trial ends."
    }

    static let appleConfirmationPending =
        "We couldn’t confirm the Apple renewal change yet. If you turned off auto-renew, " +
        "wait a moment and try again."

    static let schedulingNotConfirmed =
        "Renewal is off, but we couldn’t confirm whether account deletion was scheduled. " +
        "Wait a moment and try again here; the request is safe to retry."

    static let keepAccountConsequence =
        "Keep Account stops the account deletion only. If a subscription or trial was active, " +
        "renewal stays off, and an ended trial isn’t restored."
}

enum AccountDeletionSubscriptionPolicy {
    enum Step: Equatable {
        case scheduleDeletion
        case cancelStripe
        case manageApple
        case appleStatusUnavailable
        case unsupportedActiveProvider
    }

    static func nextStep(
        for accountInfo: AccountInfo,
        appleRenewalState: AccountDeletionAppleRenewalState
    ) -> Step {
        switch appleRenewalState {
        case .renewing:
            return .manageApple
        case .unavailable:
            return .appleStatusUnavailable
        case .notRenewing, .noMatchingSubscription:
            break
        }

        if accountInfo.hasSubscription == false {
            return .scheduleDeletion
        }
        guard accountInfo.hasSubscription == true else {
            return .unsupportedActiveProvider
        }
        let provider = accountInfo.subscriptionProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch provider {
        case "stripe":
            return accountInfo.pendingCancellation?.cancelAt == nil
                ? .cancelStripe
                : .scheduleDeletion
        case "apple":
            // A backend Apple entitlement with no matching signed StoreKit row
            // is a conflict, not proof that renewal is off. This can happen
            // after the device's Media & Purchases account changes while the
            // original Apple subscription remains renewable.
            if appleRenewalState == .noMatchingSubscription {
                return .appleStatusUnavailable
            }
            // The signed StoreKit row for this TabMail account says renewal is
            // off. Do not wait for the webhook-backed /whoami projection to
            // catch up before scheduling deletion.
            return .scheduleDeletion
        default:
            return .unsupportedActiveProvider
        }
    }
}

@MainActor
enum AccountDeletionSubscriptionCoordinator {
    enum Phase: Equatable {
        case checking
        case cancellingStripe
        case openingAppleSubscriptions
        case confirmingCancellation
        case schedulingDeletion

        var buttonLabel: String {
            switch self {
            case .checking: "Checking Subscription…"
            case .cancellingStripe: "Turning Off Renewal…"
            case .openingAppleSubscriptions: "Opening Apple Subscriptions…"
            case .confirmingCancellation: "Confirming Cancellation…"
            case .schedulingDeletion: "Scheduling Deletion…"
            }
        }
    }

    enum Outcome: Equatable {
        case ready
        case cancellationNotConfirmed
        case cancellationStillUpdating
        case appleManagementUnavailable
        case appleConfirmationPending
        case appleStatusUnavailable
        case unsupportedActiveProvider
    }

    enum ExecutionResult {
        case scheduled(deletionDate: String?)
        case blocked(Outcome)
        case schedulingNotConfirmed
    }

    private enum ReconciliationUnavailable: Error {
        case noStatusReader
    }

    static func execute(
        maxConfirmationAttempts: Int = 4,
        fetchAccountInfo: () async throws -> AccountInfo,
        cancelStripe: () async throws -> BillingClient.CancellationResponse,
        appleRenewalState: () async -> AccountDeletionAppleRenewalState = {
            .noMatchingSubscription
        },
        manageAppleSubscription: () async -> Bool,
        scheduleDeletion: () async throws -> BillingClient.DeletionResponse,
        fetchDeletionStatus: () async throws -> BillingClient.DeletionStatusResponse = {
            throw ReconciliationUnavailable.noStatusReader
        },
        waitBeforeRetry: () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        },
        progress: (Phase) -> Void
    ) async throws -> ExecutionResult {
        let preparation = try await prepareForDeletion(
            maxConfirmationAttempts: maxConfirmationAttempts,
            fetchAccountInfo: fetchAccountInfo,
            cancelStripe: cancelStripe,
            appleRenewalState: appleRenewalState,
            manageAppleSubscription: manageAppleSubscription,
            waitBeforeRetry: waitBeforeRetry,
            progress: progress
        )
        guard preparation == .ready else {
            return .blocked(preparation)
        }

        // Re-read both authorities immediately before the destructive request.
        // StoreKit catches an Apple auto-renew change; /whoami catches a Stripe
        // reactivation or provider change from another client.
        let finalAppleState = await appleRenewalState()
        let finalAccountInfo = try await fetchAccountInfo()
        switch AccountDeletionSubscriptionPolicy.nextStep(
            for: finalAccountInfo,
            appleRenewalState: finalAppleState
        ) {
        case .scheduleDeletion:
            break
        case .cancelStripe:
            return .blocked(.cancellationStillUpdating)
        case .manageApple:
            return .blocked(.appleConfirmationPending)
        case .appleStatusUnavailable:
            return .blocked(.appleStatusUnavailable)
        case .unsupportedActiveProvider:
            return .blocked(.unsupportedActiveProvider)
        }

        progress(.schedulingDeletion)
        do {
            let response = try await scheduleDeletion()
            return .scheduled(deletionDate: response.deletion_date)
        } catch {
            // The request may have committed before its response was lost.
            // Resolve that ambiguity through the existing read-only status
            // endpoint before telling the user whether scheduling happened.
            do {
                let status = try await fetchDeletionStatus()
                if status.pending {
                    return .scheduled(deletionDate: status.deletion_date)
                }
                // A negative read can race a request that is still resolving
                // provider state before it creates the pending deletion. Only
                // a positive status is authoritative after a transport error.
                return .schedulingNotConfirmed
            } catch {
                return .schedulingNotConfirmed
            }
        }
    }

    static func prepareForDeletion(
        maxConfirmationAttempts: Int = 4,
        fetchAccountInfo: () async throws -> AccountInfo,
        cancelStripe: () async throws -> BillingClient.CancellationResponse,
        appleRenewalState: () async -> AccountDeletionAppleRenewalState = {
            .noMatchingSubscription
        },
        manageAppleSubscription: () async -> Bool,
        waitBeforeRetry: () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        },
        progress: (Phase) -> Void
    ) async throws -> Outcome {
        progress(.checking)
        var currentAppleState = await appleRenewalState()

        if currentAppleState == .renewing {
            progress(.openingAppleSubscriptions)
            guard await manageAppleSubscription() else {
                return .appleManagementUnavailable
            }
            progress(.confirmingCancellation)
            currentAppleState = try await confirmedAppleRenewalState(
                maxAttempts: maxConfirmationAttempts,
                appleRenewalState: appleRenewalState,
                waitBeforeRetry: waitBeforeRetry
            )
            guard currentAppleState.permitsDeletion else {
                return currentAppleState == .unavailable
                    ? .appleStatusUnavailable
                    : .appleConfirmationPending
            }
        } else if currentAppleState == .unavailable {
            return .appleStatusUnavailable
        }

        let accountInfo = try await fetchAccountInfo()
        switch AccountDeletionSubscriptionPolicy.nextStep(
            for: accountInfo,
            appleRenewalState: currentAppleState
        ) {
        case .scheduleDeletion:
            return .ready
        case .cancelStripe:
            progress(.cancellingStripe)
            guard try await cancelStripe().cancellationConfirmed else {
                return .cancellationNotConfirmed
            }
            progress(.confirmingCancellation)
            return try await stripeDeletionEligibilityWasConfirmed(
                maxAttempts: maxConfirmationAttempts,
                fetchAccountInfo: fetchAccountInfo,
                waitBeforeRetry: waitBeforeRetry
            ) ? .ready : .cancellationStillUpdating
        case .manageApple:
            // A renewing local Apple subscription is handled before /whoami.
            return .appleConfirmationPending
        case .appleStatusUnavailable:
            return .appleStatusUnavailable
        case .unsupportedActiveProvider:
            return .unsupportedActiveProvider
        }
    }

    private static func confirmedAppleRenewalState(
        maxAttempts: Int,
        appleRenewalState: () async -> AccountDeletionAppleRenewalState,
        waitBeforeRetry: () async throws -> Void
    ) async throws -> AccountDeletionAppleRenewalState {
        guard maxAttempts > 0 else { return .unavailable }

        var lastState: AccountDeletionAppleRenewalState = .unavailable
        for attempt in 0..<maxAttempts {
            lastState = await appleRenewalState()
            if lastState.permitsDeletion {
                return lastState
            }
            if attempt < maxAttempts - 1 {
                try await waitBeforeRetry()
            }
        }
        return lastState
    }

    private static func stripeDeletionEligibilityWasConfirmed(
        maxAttempts: Int,
        fetchAccountInfo: () async throws -> AccountInfo,
        waitBeforeRetry: () async throws -> Void
    ) async throws -> Bool {
        guard maxAttempts > 0 else { return false }

        for attempt in 0..<maxAttempts {
            do {
                let accountInfo = try await fetchAccountInfo()
                let provider = accountInfo.subscriptionProvider?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if accountInfo.hasSubscription == false
                    || (accountInfo.hasSubscription == true
                        && provider == "stripe"
                        && accountInfo.pendingCancellation?.cancelAt != nil) {
                    return true
                }
            } catch where attempt == maxAttempts - 1 {
                throw error
            } catch {
                // Retry a transient authority read while the progress spinner remains visible.
            }

            if attempt < maxAttempts - 1 {
                try await waitBeforeRetry()
            }
        }
        return false
    }
}
