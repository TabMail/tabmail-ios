/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Manages Supabase session tokens for the NSE.
/// Reads the full TabMailSession JSON from shared keychain, extracts the access token,
/// and refreshes it if expired — writing the new session back for both NSE and main app.
enum NSETokenManager {
    private static let supabaseURL = "https://auth.tabmail.ai"
    private static let supabaseAnonKey = "sb_publishable_1mtT87g-94P0yxFgM19Itw_P3ih9PUD"

    /// Read the Supabase `user.id` from the stored session JSON without
    /// round-tripping the token endpoint. Used by the NSE's IMAP reconnect
    /// flow (Block F) to populate the `userId` field of `/subscribe-imap`
    /// (the worker enforces `body.userId === JWT.sub`).
    static func supabaseUserId() -> String? {
        guard let sessionJSON = SharedKeychain.getSession(),
              let data = sessionJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let user = json["user"] as? [String: Any], let id = user["id"] as? String {
            return id
        }
        // Fallback — older session shapes stash the id at top level.
        return json["sub"] as? String
    }

    /// Get a valid Supabase access token, refreshing if expired.
    /// Returns nil if no session exists or refresh fails.
    static func validAccessToken() async -> String? {
        guard let sessionJSON = SharedKeychain.getSession(),
              let data = sessionJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresAt = json["expires_at"] as? Int else {
            NSELog.step("NSE token: no session in keychain")
            return nil
        }

        let now = Int(Date().timeIntervalSince1970)
        if expiresAt > now + 60 {
            // Token still valid (with 60s buffer)
            return accessToken
        }

        // Token expired — refresh it
        guard let refreshToken = json["refresh_token"] as? String else {
            NSELog.step("NSE token: no refresh_token in session")
            return nil
        }

        NSELog.step("NSE token: expired (expiresAt=\(expiresAt) now=\(now)), refreshing...")
        return await performRefresh(refreshToken: refreshToken)
    }

    private static func performRefresh(refreshToken: String) async -> String? {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            NSELog.step("NSE token: refresh failed")
            return nil
        }

        // Parse the new session
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            NSELog.step("NSE token: failed to parse refresh response")
            return nil
        }

        // Write the full new session back to shared keychain so both NSE and main app benefit
        if let sessionString = String(data: data, encoding: .utf8) {
            SharedKeychain.setSession(sessionString)
            let newExpiry = json["expires_at"] as? Int ?? 0
            NSELog.step("NSE token: refreshed OK, new expiresAt=\(newExpiry)")
        }

        return newAccessToken
    }
}
