/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum TabMailSessionRefresh {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    struct Result: Sendable {
        let session: TabMailSession
        let generation: String?
        let persisted: Bool
    }

    static func token(record: TabMailSessionStore.ActiveSession, force: Bool = false,
                      store: TabMailSessionStore, transport: Transport) async throws -> Result {
        try Task.checkCancellation()
        let session = try JSONDecoder().decode(TabMailSession.self, from: record.data)
        guard !session.accessToken.isEmpty, !session.userId.isEmpty else {
            throw CredentialRefreshError.unavailable
        }
        if !force && session.expiresAt > Int(Date().timeIntervalSince1970) + 60 {
            CredentialRefreshGate.diagnostic?("stage=lookup outcome=cached_usable")
            return Result(session: session, generation: record.generation, persisted: true)
        }
        guard record.generation != nil, !session.refreshToken.isEmpty else {
            throw CredentialRefreshError.requiresAuthorization
        }
        let completed = try await store.refreshCapturedSession(record) { data in
            let captured = try JSONDecoder().decode(TabMailSession.self, from: data)
            let publicKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"
            var request = URLRequest(url: URL(string: "https://auth.tabmail.ai/auth/v1/token?grant_type=refresh_token")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(publicKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": captured.refreshToken])
            let (responseData, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw CredentialRefreshError.unavailable }
            if [400, 401, 403].contains(http.statusCode) { throw CredentialRefreshError.rejected }
            guard http.statusCode == 200 else { throw CredentialRefreshError.unavailable }
            let refreshed = try JSONDecoder().decode(TabMailSession.self, from: responseData)
            guard !refreshed.accessToken.isEmpty, !refreshed.refreshToken.isEmpty,
                  refreshed.userId == captured.userId,
                  refreshed.expiresAt > Int(Date().timeIntervalSince1970) else {
                throw CredentialRefreshError.unavailable
            }
            return try JSONEncoder().encode(refreshed)
        }
        return Result(session: try JSONDecoder().decode(TabMailSession.self, from: completed.data),
                      generation: record.generation, persisted: completed.persisted)
    }
}
