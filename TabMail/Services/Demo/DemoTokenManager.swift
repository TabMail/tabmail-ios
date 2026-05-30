/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Demo Mode token coordinator. Mints/refreshes the demo JWT against
/// `POST /demo/start`. Mirrors the surface of `TabMailTokenCoordinator`
/// but talks to the demo endpoint instead of Supabase.
///
/// Demo sessions are stored in Keychain under `"demo_session"` (separate key
/// from production `"tabmail_session"`) so the two never collide. The demo
/// session is wiped by `DemoModeService.exit()` (and on every demo entry,
/// defensively).
///
/// Token TTL = 4h (server-side). We re-mint when <5 min from expiry.
actor DemoTokenManager {
    static let shared = DemoTokenManager()

    private static let sessionKey = "demo_session"
    private static let refreshLeadSeconds: Int = 5 * 60 // 5-minute lead time

    private var inFlightMint: Task<MintResult, Never>?

    enum MintResult: Sendable {
        case success(String)        // valid demo access token
        case transientFailure(String)
        case configMissing          // backend returned 503 demo_not_configured
    }

    struct DemoSession: Codable, Sendable {
        let accessToken: String
        let sub: String
        let expiresAt: Int
    }

    /// Get a valid demo access token, minting/re-minting if needed.
    func validToken() async -> MintResult {
        if let session = Self.loadSession() {
            let now = Int(Date().timeIntervalSince1970)
            if session.expiresAt > now + Self.refreshLeadSeconds {
                return .success(session.accessToken)
            }
        }

        if let existing = inFlightMint {
            return await existing.value
        }

        let task = Task<MintResult, Never> { await Self.performMint() }
        inFlightMint = task
        let result = await task.value
        inFlightMint = nil
        return result
    }

    /// Force a fresh mint (used by `DemoModeService.start`).
    func mint() async -> MintResult {
        if let existing = inFlightMint {
            return await existing.value
        }
        let task = Task<MintResult, Never> { await Self.performMint() }
        inFlightMint = task
        let result = await task.value
        inFlightMint = nil
        return result
    }

    /// Wipe the demo session from Keychain. Called by `DemoModeService.exit`
    /// and on demo entry (defensive — last session may have crashed mid-flight).
    static func clearSession() {
        KeychainHelper.delete(key: sessionKey)
    }

    static func loadSession() -> DemoSession? {
        guard let data = KeychainHelper.load(key: sessionKey) else { return nil }
        return try? JSONDecoder().decode(DemoSession.self, from: data)
    }

    static func hasSession() -> Bool {
        KeychainHelper.load(key: sessionKey) != nil
    }

    // MARK: - Private

    private static func performMint() async -> MintResult {
        let url = BackendConfig.apiBaseURL.appending(path: "/demo/start")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Friction layer against curl-style abuse on /demo/start. The secret
        // ships in Secrets.xcconfig → Info.plist; backend verifies via
        // timingSafeEqual. See ADR-IOS-038.
        // Returns 503 if not configured at build time so we fail loudly.
        guard let clientSecret = Bundle.main.infoDictionary?["DEMO_CLIENT_SECRET"] as? String,
              !clientSecret.isEmpty,
              clientSecret != "demo-client-secret-hex-32-bytes"
        else {
            print("[DemoToken] DEMO_CLIENT_SECRET missing or unset in Info.plist — rebuild after editing Secrets.xcconfig")
            return .configMissing
        }
        request.setValue(clientSecret, forHTTPHeaderField: "X-Demo-Client-Secret")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await sharedEphemeralSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure("Invalid response type")
            }
            switch http.statusCode {
            case 200:
                struct DemoStartBody: Decodable {
                    let access_token: String
                    let expires_at: Int
                    let sub: String
                }
                let body = try JSONDecoder().decode(DemoStartBody.self, from: data)
                let session = DemoSession(accessToken: body.access_token, sub: body.sub, expiresAt: body.expires_at)
                if let encoded = try? JSONEncoder().encode(session) {
                    try? KeychainHelper.save(encoded, for: sessionKey)
                }
                print("[DemoToken] Minted demo JWT sub=\(body.sub.prefix(8)) exp=\(body.expires_at)")
                return .success(session.accessToken)
            case 429:
                return .transientFailure("rate_limited")
            case 503:
                return .configMissing
            default:
                return .transientFailure("HTTP \(http.statusCode)")
            }
        } catch {
            return .transientFailure(error.localizedDescription)
        }
    }
}
