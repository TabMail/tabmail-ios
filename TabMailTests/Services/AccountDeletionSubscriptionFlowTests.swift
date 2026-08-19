/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Account deletion subscription flow")
struct AccountDeletionSubscriptionFlowTests {
    private func futureCancellationAt() -> Int {
        Int(Date.now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
    }

    private func accountInfo(
        hasSubscription: Bool,
        provider: String? = nil,
        pendingCancellationAt: Int? = nil
    ) throws -> AccountInfo {
        let providerJSON = provider.map { "\"\($0)\"" } ?? "null"
        let pendingJSON = pendingCancellationAt.map {
            "{\"cancel_at\":\($0),\"cancel_at_formatted\":\"Later\"}"
        } ?? "null"
        let json = """
        {
          "logged_in": true,
          "has_subscription": \(hasSubscription),
          "subscription_provider": \(providerJSON),
          "pending_cancellation": \(pendingJSON)
        }
        """
        return try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
    }

    @Test("No active subscription schedules deletion immediately")
    func noSubscription() throws {
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: try accountInfo(hasSubscription: false),
                appleRenewalState: .noMatchingSubscription
            ) == .scheduleDeletion
        )
    }

    @Test("A confirmed pending cancellation schedules deletion for either provider")
    func pendingCancellation() throws {
        let cancellationAt = futureCancellationAt()
        for provider in ["stripe", "apple"] {
            #expect(
                AccountDeletionSubscriptionPolicy.nextStep(
                    for: try accountInfo(
                        hasSubscription: true,
                        provider: provider,
                        pendingCancellationAt: cancellationAt
                    ),
                    appleRenewalState: provider == "apple" ? .notRenewing : .noMatchingSubscription
                ) == .scheduleDeletion
            )
        }
    }

    @Test("A renewable Stripe subscription is cancelled first")
    func stripeCancellationFirst() throws {
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: try accountInfo(hasSubscription: true, provider: " Stripe "),
                appleRenewalState: .noMatchingSubscription
            ) == .cancelStripe
        )
    }

    @Test("A renewable Apple subscription opens Apple management first")
    func appleManagementFirst() throws {
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: try accountInfo(hasSubscription: true, provider: "APPLE"),
                appleRenewalState: .renewing
            ) == .manageApple
        )
    }

    /// A server-granted signup trial reports an ACTIVE subscription with the
    /// provider `signup`. There is no purchase behind it — nothing renews and
    /// there is nothing to cancel first — so falling through to the unsupported
    /// arm would leave every trial user unable to delete their account at all.
    @Test("A server-granted trial has nothing to cancel, so deletion is scheduled")
    func signupTrialSchedulesDeletion() throws {
        for provider in ["signup", " Signup ", "SIGNUP"] {
            #expect(
                AccountDeletionSubscriptionPolicy.nextStep(
                    for: try accountInfo(hasSubscription: true, provider: provider),
                    appleRenewalState: .noMatchingSubscription
                ) == .scheduleDeletion
            )
        }
    }

    /// The same case built from the full running-trial wire shape rather than a
    /// provider string alone, so the policy is exercised against the body the
    /// backend actually sends.
    @Test("A full running-trial account body schedules deletion")
    func runningTrialBodySchedulesDeletion() throws {
        let info = try WhoamiFixture.runningSignupTrial(daysLeft: 9, reference: Date())
        #expect(info.trialState() == .active(daysRemaining: 9))
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: info,
                appleRenewalState: .noMatchingSubscription
            ) == .scheduleDeletion
        )
    }

    @Test("An unknown active provider fails closed")
    func unknownProvider() throws {
        // "signups"/"signup-trial" are near misses, not the exact provider —
        // the match is exact after trimming and lowercasing, never a prefix.
        let unknownProviders: [String?] = [nil, "future-provider", "signups", "signup-trial"]
        let cancellationStates: [Int?] = [nil, futureCancellationAt()]
        for provider in unknownProviders {
            for pendingCancellationAt in cancellationStates {
                #expect(
                    AccountDeletionSubscriptionPolicy.nextStep(
                        for: try accountInfo(
                            hasSubscription: true,
                            provider: provider,
                            pendingCancellationAt: pendingCancellationAt
                        ),
                        appleRenewalState: .noMatchingSubscription
                    ) == .unsupportedActiveProvider
                )
            }
        }
    }

    @Test("Missing subscription authority fails closed")
    func missingSubscriptionAuthority() throws {
        let json = #"{"logged_in":true,"subscription_provider":"stripe"}"#
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: info,
                appleRenewalState: .noMatchingSubscription
            )
                == .unsupportedActiveProvider
        )
    }

    @Test("A renewing local Apple subscription overrides stale backend state")
    func localAppleRenewalWins() throws {
        let cancellationAt = futureCancellationAt()
        for info in [
            try accountInfo(hasSubscription: false),
            try accountInfo(
                hasSubscription: true,
                provider: "apple",
                pendingCancellationAt: cancellationAt
            )
        ] {
            #expect(
                AccountDeletionSubscriptionPolicy.nextStep(
                    for: info,
                    appleRenewalState: .renewing
                ) == .manageApple
            )
        }
    }

    @Test("Unavailable Apple authority fails closed")
    func unavailableAppleAuthority() throws {
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: try accountInfo(hasSubscription: false),
                appleRenewalState: .unavailable
            ) == .appleStatusUnavailable
        )
    }

    @Test("An active Apple backend row requires a matching StoreKit subscription")
    func unmatchedAppleAuthorityFailsClosed() throws {
        #expect(
            AccountDeletionSubscriptionPolicy.nextStep(
                for: try accountInfo(hasSubscription: true, provider: "apple"),
                appleRenewalState: .noMatchingSubscription
            ) == .appleStatusUnavailable
        )
    }
}

@Suite("Billing cancellation handshake")
struct BillingCancellationHandshakeTests {
    @Test("Builds the existing authenticated cancellation request")
    func requestShape() throws {
        let request = BillingClient.makeCancelSubscriptionRequest(
            baseURL: try #require(URL(string: "https://billing.tabmail.ai")),
            token: "token-value"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/billing/cancel-subscription")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-value")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody == nil)
    }

    @Test("Accepts provider-verified scheduled-array evidence independently")
    func scheduledEvidence() throws {
        let cancellationAt = Int(
            Date.now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970
        )
        let json = """
        {
          "success": true,
          "scheduled_cancellations": [{"id":"sub_1","cancel_at":\(cancellationAt)}],
          "immediate_cancellations": [],
          "entitlement_state": {"pending_cancellation": null}
        }
        """
        let response = try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(json.utf8)
        )
        #expect(response.cancellationConfirmed)
        #expect(response.scheduledCancellations?.first?.id == "sub_1")
    }

    @Test("Accepts provider-verified entitlement evidence independently")
    func entitlementEvidence() throws {
        let cancellationAt = Int(
            Date.now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970
        )
        let json = """
        {
          "success": true,
          "scheduled_cancellations": [],
          "immediate_cancellations": [],
          "entitlement_state": {
            "pending_cancellation": {
              "cancel_at": \(cancellationAt),
              "cancel_at_formatted": "Future date"
            }
          }
        }
        """
        let response = try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(json.utf8)
        )
        #expect(response.cancellationConfirmed)
        #expect(response.entitlementState?.pendingCancellation?.cancelAt == cancellationAt)
    }

    @Test("Accepts an immediate trial cancellation as terminal evidence")
    func immediateEvidence() throws {
        let json = """
        {
          "success": true,
          "scheduled_cancellations": [],
          "immediate_cancellations": ["sub_trial"],
          "entitlement_state": {"pending_cancellation": null}
        }
        """
        let response = try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(json.utf8)
        )
        #expect(response.cancellationConfirmed)
    }

    @Test("Rejects a success response without cancellation evidence")
    func missingEvidence() throws {
        let json = """
        {
          "success": true,
          "scheduled_cancellations": [],
          "immediate_cancellations": [],
          "entitlement_state": {"pending_cancellation": null}
        }
        """
        let response = try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(json.utf8)
        )
        #expect(!response.cancellationConfirmed)
    }

    @Test("Rejects success false even when cancellation evidence is present")
    func falseSuccessWithEvidence() throws {
        let cancellationAt = Int(
            Date.now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970
        )
        let json = """
        {
          "success": false,
          "scheduled_cancellations": [{"id":"sub_1","cancel_at":\(cancellationAt)}],
          "immediate_cancellations": ["sub_trial"],
          "entitlement_state": {
            "pending_cancellation": {"cancel_at":\(cancellationAt)}
          }
        }
        """
        let response = try BillingClient.decodeCancellationResponse(
            statusCode: 200,
            data: Data(json.utf8)
        )
        #expect(!response.cancellationConfirmed)
    }

    @Test("Rejects a non-success HTTP response before decoding")
    func rejectsHTTPFailure() {
        #expect(throws: BackendError.self) {
            _ = try BillingClient.decodeCancellationResponse(
                statusCode: 503,
                data: Data(#"{"error":"temporarily_unavailable"}"#.utf8)
            )
        }
    }
}
