/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// HTTP client for the push notification worker API (push[-dev].tabmail.ai).
/// Separate from BackendClient because the base URL differs.
/// Auth: Supabase JWT (via TabMailTokenCoordinator) for all endpoints.
actor PushClient {
    private let baseURL: URL
    private let session = sharedEphemeralSession

    init() {
        self.baseURL = URL(string: PushConfig.baseURL)!
    }

    private struct WorkerErrorBody: Decodable {
        let error: String?
    }

    /// Preserve the worker's stable error code for durable deletion decisions.
    /// A bare 403 can be emitted by infrastructure before the handler runs; only
    /// the handler's `user_mismatch` response proves caller-owned state was
    /// revoked before the shared singleton was refused.
    nonisolated private static func deletionError(data: Data, statusCode: Int) -> PushError {
        let errorCode = (try? JSONDecoder().decode(WorkerErrorBody.self, from: data))?.error
        return .workerRequestFailed(statusCode: statusCode, errorCode: errorCode)
    }

    // MARK: - Auth

    private func currentAuthToken() async -> String? {
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let token): return token
        case .permanentFailure, .transientFailure, .noSession: return nil
        }
    }

    private func authRequest(path: String, method: String) async throws -> URLRequest {
        guard let token = await currentAuthToken() else {
            throw PushError.noAuthToken
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Device Registration

    /// Register or update this device's APNs token with the push worker.
    func registerDevice(
        deviceToken: String,
        deviceId: String,
        userId: String,
        accountEmails: [String],
        apnsSandbox: Bool
    ) async throws {
        // Single device-level endpoint; registers device existence + email
        // list for fan-out lookups. nseCapable is decided per-account by
        // /register-account-device-{nse,silent} so this device-level call
        // never touches it (avoids racing/clobbering the per-account flag).
        var request = try await authRequest(path: "/register-device", method: "POST")
        let body: [String: Any] = [
            "deviceToken": deviceToken,
            "deviceId": deviceId,
            "userId": userId,
            "accountEmails": accountEmails,
            "apnsSandbox": apnsSandbox,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] registerDevice failed: HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        print("[PushClient] Device registered")
    }

    /// Register a single (device, account) pair with the push worker.
    /// Picks `/register-account-device-nse` when `nseCapable == true`, else
    /// `/register-account-device-silent`. Per-account records take precedence
    /// over the legacy device-level registration at dispatch time.
    ///
    /// Ground truth for `nseCapable` is
    /// `(global NSE toggle) AND NSEProviderSupport.isReady(provider)`.
    func registerDeviceAccount(
        deviceToken: String,
        deviceId: String,
        userId: String,
        accountEmail: String,
        provider: String,
        apnsSandbox: Bool,
        nseCapable: Bool
    ) async throws {
        let endpoint = nseCapable
            ? "/register-account-device-nse"
            : "/register-account-device-silent"
        var request = try await authRequest(path: endpoint, method: "POST")
        let body: [String: Any] = [
            "deviceToken": deviceToken,
            "deviceId": deviceId,
            "userId": userId,
            "accountEmail": accountEmail,
            "provider": provider,
            "apnsSandbox": apnsSandbox,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] registerDeviceAccount failed (\(accountEmail), nse=\(nseCapable)): HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        print("[PushClient] Registered \(accountEmail) (provider=\(provider), nse=\(nseCapable))")
    }

    /// Remove a single (device, account) registration.
    func unregisterDeviceAccount(deviceId: String, accountEmail: String) async throws {
        guard let token = await currentAuthToken() else {
            throw PushError.noAuthToken
        }
        var components = URLComponents(url: baseURL.appending(path: "/register-account-device"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "accountEmail", value: accountEmail),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] unregisterDeviceAccount failed (\(accountEmail)): HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Unregistered \(accountEmail)")
    }

    // MARK: - Push-Consent (server-side inbox-add classifier)
    //
    // Consent-status shape is identical across providers (ok / missing /
    // error). The HTTP endpoints differ (Gmail vs Outlook vs future IMAP)
    // so the per-provider methods stay separate — but they all return
    // `PushConsentStatus`.

    enum PushConsentStatus: Equatable {
        case ok
        case missing
        case error(reason: String?)
    }

    /// Ask the worker to mint a short-lived session for the web-hosted
    /// Gmail metadata-scope OAuth flow, bound to this user + account. The
    /// worker returns a URL to open in ASWebAuthenticationSession; after
    /// the user consents, the worker stores the resulting refresh_token
    /// server-side (we never see it on-device) and redirects back to
    /// `iosRedirect` with `?status=ok|error&reason=...`.
    func initGmailConsentWeb(
        userEmail: String,
        iosRedirect: String
    ) async throws -> URL {
        var request = try await authRequest(path: "/push-consent/gmail/init", method: "POST")
        let body: [String: Any] = [
            "userEmail": userEmail,
            "iosRedirect": iosRedirect,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] initGmailConsentWeb failed for \(userEmail): HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        struct InitResponse: Decodable { let startUrl: String }
        let parsed = try JSONDecoder().decode(InitResponse.self, from: data)
        guard let url = URL(string: parsed.startUrl) else {
            throw PushError.requestFailed(statusCode: 0)
        }
        return url
    }

    /// Revoke the stored refresh token at Google and remove the consent
    /// record from the worker's KV. Called on NSE toggle OFF, account
    /// removal, or explicit user revocation.
    ///
    /// POST with `userEmail` in JSON body (not query param): email stays
    /// out of Cloudflare's HTTP access log. See log-privacy audit 2026-04-16.
    func deleteGmailConsent(userEmail: String) async throws {
        var request = try await authRequest(path: "/push-consent/gmail/revoke", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userEmail": userEmail])

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] deleteGmailConsent failed: HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Deleted Gmail consent")
    }

    /// Query the worker for this account's consent state. Used on app
    /// foreground to surface a "fix smart notifications" banner when the
    /// server has flagged a classification error (refresh-failed, Gmail
    /// 401/404/5xx, etc.).
    func getGmailConsentStatus(userEmail: String) async throws -> PushConsentStatus {
        var request = try await authRequest(path: "/push-consent/gmail/status", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userEmail": userEmail])

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] getGmailConsentStatus failed: HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }

        struct Resp: Decodable { let status: String; let errorReason: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        switch parsed.status {
        case "ok":      return .ok
        case "missing": return .missing
        case "error":   return .error(reason: parsed.errorReason)
        default:
            print("[PushClient] Unknown consent status: \(parsed.status)")
            return .missing
        }
    }

    /// Unregister this device from the push worker.
    func unregisterDevice(deviceId: String) async throws {
        guard let token = await currentAuthToken() else {
            throw PushError.noAuthToken
        }
        var components = URLComponents(url: baseURL.appending(path: "/register-device"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] unregisterDevice failed: HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Device unregistered")
    }

    // MARK: - Task Alarm Registration

    /// Register task alarm wake times with the push worker.
    /// The worker sends silent pushes at these absolute UTC times to wake the app.
    func registerAlarms(
        deviceToken: String,
        wakeTimes: [String],
        apnsSandbox: Bool
    ) async throws {
        var request = try await authRequest(path: "/alarms", method: "POST")
        let body: [String: Any] = [
            "deviceToken": deviceToken,
            "wakeTimes": wakeTimes,
            "apnsSandbox": apnsSandbox,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] registerAlarms failed: HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        print("[PushClient] Registered \(wakeTimes.count) alarm wake times")
    }

    // MARK: - Push Subscriptions

    /// Subscribe an account for push (Gmail watch / Outlook Graph subscription).
    /// `accessToken` is the per-account OAuth token, NOT the Supabase JWT.
    func subscribe(
        provider: String,
        userId: String,
        userEmail: String,
        accessToken: String
    ) async throws {
        var request = try await authRequest(path: "/subscribe", method: "POST")
        let body: [String: String] = [
            "provider": provider,
            "userId": userId,
            "userEmail": userEmail,
            "accessToken": accessToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] subscribe failed for \(userEmail): HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        print("[PushClient] Subscribed \(provider) push for \(userEmail)")
    }

    /// Subscribe an IMAP account for push via the DigitalOcean IDLE proxy.
    ///
    /// End-to-end credential path:
    ///   iOS → AES-GCM encrypts `{host, port, username, password, security}`
    ///         with `IMAP_CRED_ENCRYPTION_KEY` (pre-shared iOS ↔ droplet).
    ///   iOS → POSTs `{userId, userEmail, credsCiphertext}` to push-worker.
    ///   Worker → forwards ciphertext to droplet `/start-idle` (never
    ///            holds the key, never persists creds).
    ///   Droplet → decrypts just-in-time, ImapFlow LOGIN, zeros plaintext
    ///            immediately after LOGIN returns OK.
    ///
    /// The worker stores only a credless subscription record
    /// `{userId, accountEmail, dropletId, subscribedAt}`. The privacy
    /// policy §3 invariant "no host/port/username/password at rest" is
    /// preserved end-to-end.
    func subscribeIMAP(
        userId: String,
        userEmail: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        security: String? = nil
    ) async throws {
        let payload = IMAPCredPayload(
            host: host,
            port: port,
            username: username,
            password: password,
            security: security
        )
        let credsCiphertext: String
        do {
            credsCiphertext = try IMAPCredCrypto.encrypt(payload)
        } catch {
            // Don't print the error — its type (e.g. keyMissing, sealFailed)
            // is itself build-config-sensitive information. A generic line
            // is enough for the device console; the thrown PushError tells
            // the caller exactly which path failed.
            print("[PushClient] subscribeIMAP: credential encryption failed")
            throw PushError.requestFailed(statusCode: 0)
        }

        var request = try await authRequest(path: "/subscribe-imap", method: "POST")
        let body: [String: Any] = [
            "userId": userId,
            "userEmail": userEmail,
            "credsCiphertext": credsCiphertext,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] subscribeIMAP failed for \(userEmail): HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        print("[PushClient] Subscribed IMAP push for \(userEmail) via DO IDLE proxy")
    }

    /// Unsubscribe an IMAP account from the DigitalOcean IDLE proxy.
    /// Server deletes stored credentials and tells the proxy to disconnect IDLE.
    func unsubscribeIMAP(userEmail: String) async throws {
        var request = try await authRequest(path: "/unsubscribe-imap", method: "POST")
        let body: [String: Any] = ["userEmail": userEmail]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] unsubscribeIMAP failed for \(userEmail): HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Unsubscribed IMAP push for \(userEmail)")
    }

    /// Unsubscribe an account from push notifications.
    func unsubscribe(
        provider: String,
        userEmail: String,
        accessToken: String
    ) async throws {
        var request = try await authRequest(path: "/unsubscribe", method: "POST")
        let body: [String: String] = [
            "provider": provider,
            "userEmail": userEmail,
            "accessToken": accessToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] unsubscribe failed for \(userEmail): HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Unsubscribed \(provider) push for \(userEmail)")
    }

    // MARK: - Outlook Push-Consent

    /// Mint a short-lived session on the worker for the web-hosted Outlook
    /// metadata-scope OAuth flow, bound to this user + email + iOS callback
    /// scheme. Returns the `/start` URL for iOS to open in
    /// ASWebAuthenticationSession; Microsoft redirects to the worker's
    /// `/callback` which stores tokens server-side and redirects back to
    /// `iosRedirect` with `?status=ok|error&reason=...`. Tokens never reach
    /// iOS. Mirror of `initGmailConsentWeb`.
    func initOutlookConsentWeb(
        userEmail: String,
        iosRedirect: String
    ) async throws -> URL {
        var request = try await authRequest(path: "/push-consent/outlook/init", method: "POST")
        let body: [String: Any] = [
            "userEmail": userEmail,
            "iosRedirect": iosRedirect,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] initOutlookConsentWeb failed for \(userEmail): HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }
        struct InitResponse: Decodable { let startUrl: String }
        let parsed = try JSONDecoder().decode(InitResponse.self, from: data)
        guard let url = URL(string: parsed.startUrl) else {
            throw PushError.requestFailed(statusCode: 0)
        }
        return url
    }

    /// Delete server-side Outlook consent. No Microsoft-side revocation —
    /// see worker docstring for why (cascading grant invalidation risk).
    ///
    /// POST with `userEmail` in JSON body (not query param): email stays
    /// out of Cloudflare's HTTP access log. See log-privacy audit 2026-04-16.
    func deleteOutlookConsent(userEmail: String) async throws {
        var request = try await authRequest(path: "/push-consent/outlook/revoke", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userEmail": userEmail])

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] deleteOutlookConsent failed: HTTP \(code)")
            throw Self.deletionError(data: data, statusCode: code)
        }
        print("[PushClient] Deleted Outlook consent")
    }

    /// Query the worker for the Outlook account's consent state.
    func getOutlookConsentStatus(userEmail: String) async throws -> PushConsentStatus {
        var request = try await authRequest(path: "/push-consent/outlook/status", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userEmail": userEmail])

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= code else {
            print("[PushClient] getOutlookConsentStatus failed: HTTP \(code)")
            throw PushError.requestFailed(statusCode: code)
        }

        struct Resp: Decodable { let status: String; let errorReason: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        switch parsed.status {
        case "ok":      return .ok
        case "missing": return .missing
        case "error":   return .error(reason: parsed.errorReason)
        default:
            print("[PushClient] Unknown Outlook consent status: \(parsed.status)")
            return .missing
        }
    }
}

enum PushError: Error {
    case noAuthToken
    case requestFailed(statusCode: Int)
    /// Worker deletion failure with a parsed stable JSON `error` code.
    case workerRequestFailed(statusCode: Int, errorCode: String?)
}

/// Narrow seam consumed by `PushNotificationService.checkPushConsentStatusForForeground`
/// so the per-account status scan can be unit-tested without network I/O. Production
/// code always uses the real `PushClient` conformance; tests install a mock via
/// `PushNotificationService._setConsentCheckerForTesting` (DEBUG-only).
protocol PushConsentChecking: Sendable {
    func getGmailConsentStatus(userEmail: String) async throws -> PushClient.PushConsentStatus
    func getOutlookConsentStatus(userEmail: String) async throws -> PushClient.PushConsentStatus
}

extension PushClient: PushConsentChecking {}

/// Narrow worker API used to retire every device-side route for a removed
/// account. Keeping this separate from the full client makes the durable retry
/// path failure-injectable without teaching tests about URLSession or auth.
protocol RemovedAccountPushCleaning: Sendable {
    func unregisterDeviceAccount(deviceId: String, accountEmail: String) async throws
    func registerDevice(
        deviceToken: String,
        deviceId: String,
        userId: String,
        accountEmails: [String],
        apnsSandbox: Bool
    ) async throws
    func unregisterDevice(deviceId: String) async throws
    func unsubscribeIMAP(userEmail: String) async throws
    func deleteGmailConsent(userEmail: String) async throws
    func deleteOutlookConsent(userEmail: String) async throws
    func unsubscribe(provider: String, userEmail: String, accessToken: String) async throws
}

extension PushClient: RemovedAccountPushCleaning {}
