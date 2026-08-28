/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

#if TABMAIL_TESTS
@testable import TabMail
#endif

/// Supabase session access for the NSE. The active pointer is read-only here;
/// refresh persistence is update-only against the generation captured before
/// the request.
enum NSETokenManager {
    typealias DataForRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let supabaseURL = "https://auth.tabmail.ai"
    private static let supabaseAnonKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"

    static func supabaseUserId(sessionStore: TabMailSessionStore = .shared) -> String? {
        guard let record = sessionStore.loadActiveSession(),
              let json = decodedSession(record.data) else { return nil }
        return userId(inSessionJSON: json)
    }

    static func userId(inSessionJSON json: [String: Any]) -> String? {
        if let user = json["user"] as? [String: Any], let id = user["id"] as? String {
            return id
        }
        return json["sub"] as? String
    }

    static func validAccessToken(
        sessionStore: TabMailSessionStore = .shared,
        dataForRequest: @escaping DataForRequest = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> String? {
        guard let record = sessionStore.loadActiveSession(),
              let json = decodedSession(record.data),
              let accessToken = json["access_token"] as? String,
              let expiresAt = json["expires_at"] as? Int else {
            NSELog.step("NSE token: no active session")
            return nil
        }

        let now = Int(Date().timeIntervalSince1970)
        if expiresAt > now + 60 { return accessToken }

        // The NSE never migrates and never rotates a generationless legacy
        // refresh token. The next main-app launch performs the local migration.
        guard let generation = record.generation else {
            NSELog.step("NSE token: expired legacy session awaits main-app migration")
            return nil
        }
        guard let refreshToken = json["refresh_token"] as? String else {
            NSELog.step("NSE token: no refresh token")
            return nil
        }

        return await performRefresh(
            refreshToken: refreshToken,
            generation: generation,
            sessionStore: sessionStore,
            dataForRequest: dataForRequest
        )
    }

    private static func performRefresh(
        refreshToken: String,
        generation: String,
        sessionStore: TabMailSessionStore,
        dataForRequest: DataForRequest
    ) async -> String? {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 10

        guard let (data, response) = try? await dataForRequest(request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = decodedSession(data),
              let accessToken = json["access_token"] as? String else {
            NSELog.step("NSE token: refresh failed")
            return nil
        }

        let result = sessionStore.updateCapturedGeneration(generation, data: data)
        switch result {
        case .updated:
            NSELog.step("NSE token: refreshed active generation")
        case .inactive:
            NSELog.step("NSE token: refreshed generation is inactive; persistence withheld")
        case .failed(let status):
            NSELog.step("NSE token: generation update failed (OSStatus \(status))")
        }
        // The held invocation may finish with its bearer even when its captured
        // generation lost activation while the request was in flight.
        return accessToken
    }

    private static func decodedSession(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
