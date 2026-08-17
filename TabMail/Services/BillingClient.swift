/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

struct BillingScheduledCancellation: Decodable, Sendable {
    let id: String
    let cancelAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case cancelAt = "cancel_at"
    }
}

struct BillingCancellationEntitlementState: Decodable, Sendable {
    let pendingCancellation: PendingCancellation?

    enum CodingKeys: String, CodingKey {
        case pendingCancellation = "pending_cancellation"
    }
}

struct BillingCancellationResponse: Decodable, Sendable {
    let success: Bool
    let scheduledCancellations: [BillingScheduledCancellation]?
    let immediateCancellations: [String]?
    let entitlementState: BillingCancellationEntitlementState?

    enum CodingKeys: String, CodingKey {
        case success
        case scheduledCancellations = "scheduled_cancellations"
        case immediateCancellations = "immediate_cancellations"
        case entitlementState = "entitlement_state"
    }

    /// The cancellation endpoint returns only after its provider-side
    /// postcondition checks. Require concrete evidence rather than trusting
    /// a bare `success` flag before the deletion flow continues.
    var cancellationConfirmed: Bool {
        guard success else { return false }
        return entitlementState?.pendingCancellation?.cancelAt != nil
            || scheduledCancellations?.isEmpty == false
            || immediateCancellations?.isEmpty == false
    }
}

/// Client for billing worker account deletion endpoints (billing.tabmail.ai).
actor BillingClient {
    typealias CancellationResponse = BillingCancellationResponse

    private var baseURL: URL { BackendConfig.billingBaseURL }
    private let session = sharedEphemeralSession

    private func currentAuthToken() async -> String? {
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let token): return token
        case .permanentFailure, .transientFailure, .noSession: return nil
        }
    }

    // MARK: - Response Types

    struct DeletionResponse: Decodable {
        let status: String       // "scheduled" or "already_scheduled"
        // Match the established wire-facing member names used by current callers.
        // swiftlint:disable:next identifier_name
        let deletion_date: String
        // swiftlint:disable:next identifier_name
        let requested_at: String?
    }

    struct CancelDeletionResponse: Decodable {
        let status: String?      // "restored"
        let error: String?
        // Match the worker's additive wire key without changing decoder policy.
        // swiftlint:disable:next identifier_name
        let subscription_outcome: String?

        /// The account was kept, but its paid subscription ended during the
        /// deletion grace period and must be purchased again. Keep the wire
        /// value forward-compatible: an unknown future outcome must not turn a
        /// successful cancellation into a decoding failure.
        var subscriptionLapsedDuringGrace: Bool {
            subscription_outcome == "expired_during_grace"
        }
    }

    struct DeletionStatusResponse: Decodable {
        let pending: Bool
        // Match the established wire-facing member name used by current callers.
        // swiftlint:disable:next identifier_name
        let deletion_date: String?
    }

    // MARK: - Endpoints

    nonisolated static func makeCancelSubscriptionRequest(
        baseURL: URL,
        token: String
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "/billing/cancel-subscription"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    nonisolated static func decodeCancellationResponse(
        statusCode: Int,
        data: Data
    ) throws -> CancellationResponse {
        guard 200..<300 ~= statusCode else {
            throw BackendError.requestFailed(statusCode: statusCode)
        }
        return try JSONDecoder().decode(CancellationResponse.self, from: data)
    }

    func cancelSubscription() async throws -> CancellationResponse {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        let request = Self.makeCancelSubscriptionRequest(baseURL: baseURL, token: token)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.requestFailed(statusCode: 0)
        }
        return try Self.decodeCancellationResponse(
            statusCode: httpResponse.statusCode,
            data: data
        )
    }

    func requestAccountDeletion() async throws -> DeletionResponse {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/account/delete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try JSONDecoder().decode(DeletionResponse.self, from: data)
    }

    func cancelAccountDeletion() async throws -> CancelDeletionResponse {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/account/cancel-deletion"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try JSONDecoder().decode(CancelDeletionResponse.self, from: data)
    }

    func checkDeletionStatus() async throws -> DeletionStatusResponse {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/account/deletion-status"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try JSONDecoder().decode(DeletionStatusResponse.self, from: data)
    }
}
