/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client for billing worker account deletion endpoints (billing.tabmail.ai).
actor BillingClient {
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
        let deletion_date: String
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
        let deletion_date: String?
    }

    // MARK: - Endpoints

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
