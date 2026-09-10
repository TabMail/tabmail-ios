/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
#if TABMAIL_TESTS
@testable import TabMail
#endif

/// One notification operation stays bound to its original foreground activation.
struct NSEAuthSource: AuthSource {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    @TaskLocal static var transport: Transport = { try await URLSession.shared.data(for: $0) }

    struct Binding: Sendable { let accountId: String; let generation: String? }
    @TaskLocal static var binding: Binding?

    let accountId: String
    let provider: String
    private let generation: String?
    private let lastSeen: String?
    private let store: ProviderCredentialStore
    private let dataForRequest: Transport
    private let clientId: String?

    init(accountId: String, provider: String = "gmail", lastSeen: String? = nil,
         store: ProviderCredentialStore = .shared, clientId: String? = nil,
         dataForRequest: Transport? = nil) {
        self.accountId = accountId
        self.provider = provider
        self.store = store
        if let binding = Self.binding {
            self.generation = binding.accountId == accountId ? binding.generation : nil
        } else { self.generation = store.activation(accountId: accountId)?.generation }
        self.lastSeen = lastSeen
        self.dataForRequest = dataForRequest ?? Self.transport
        self.clientId = clientId ?? SharedNSEData.suite.string(
            forKey: provider == "gmail" ? "nse.googleClientId" : "nse.microsoftClientId")
    }

    func current() async -> String? {
        guard !Task.isCancelled, let generation,
              store.activation(accountId: accountId)?.generation == generation,
              let tokens = store.current(accountId: accountId, generation: generation), !tokens.accessToken.isEmpty,
              tokens.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true else {
            NSELog.step("NSE credential: scope=provider stage=lookup outcome=unusable")
            return nil
        }
        NSELog.step("NSE credential: scope=provider stage=lookup outcome=cached_usable")
        return tokens.accessToken
    }

    func refresh() async throws -> String { try await refresh(rejected: lastSeen) }
    func refresh(rejecting token: String) async throws -> String { try await refresh(rejected: token) }

    private func refresh(rejected: String?) async throws -> String {
        let scope = provider == "gmail" ? "gmail" : (provider == "outlook" ? "outlook" : "unsupported")
        let started = ProcessInfo.processInfo.systemUptime
        NSELog.step("NSE credential: scope=\(scope) stage=refresh trigger=\(rejected == nil ? "missing_or_expired" : "rejected_bearer")")
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            NSELog.step("NSE credential: scope=\(scope) stage=end elapsed_ms=\(elapsed)")
        }
        do {
            return try await CredentialRefreshGate.$diagnostic.withValue({ event in
                NSELog.step("NSE credential: scope=\(scope) \(event)")
            }) {
                try Task.checkCancellation()
                guard let generation, let clientId, !clientId.isEmpty,
                      provider == "gmail" || provider == "outlook" else {
                    NSELog.step("NSE credential: scope=\(scope) stage=prepare outcome=missing_binding_or_configuration")
                    throw AuthError.noRefreshToken
                }
                let result = try await store.refresh(accountId: accountId, generation: generation,
                                                    rejectedToken: rejected) { refreshToken in
                    let endpoint = provider == "gmail" ? "https://oauth2.googleapis.com/token" :
                        "https://login.microsoftonline.com/common/oauth2/v2.0/token"
                    var request = URLRequest(url: URL(string: endpoint)!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 10
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
                    if provider == "outlook" {
                        // The primary mail/calendar grant, matching foreground authorization.
                        fields["scope"] = "Mail.ReadWrite Mail.Send Calendars.ReadWrite offline_access User.Read"
                    }
                    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                    request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
                        $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
                    }.joined(separator: "&").data(using: .utf8)
                    NSELog.step("NSE credential: scope=\(scope) stage=network outcome=started")
                    let (data, response) = try await dataForRequest(request)
                    NSELog.step("NSE credential: scope=\(scope) stage=network http=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    guard let http = response as? HTTPURLResponse else { throw CredentialRefreshError.unavailable }
                    if [400, 401, 403].contains(http.statusCode) { throw CredentialRefreshError.rejected }
                    guard http.statusCode == 200,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let token = json["access_token"] as? String, !token.isEmpty else {
                        throw CredentialRefreshError.unavailable
                    }
                    let expiry = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
                    return .init(accessToken: token, refreshToken: json["refresh_token"] as? String, expiresAt: expiry)
                }
                try Task.checkCancellation()
                NSELog.step("NSE credential: scope=\(scope) stage=finish outcome=usable_shared_credential")
                return result.accessToken
            }
        } catch {
            NSELog.step("NSE credential: scope=\(scope) stage=finish outcome=\(NSELog.credentialFailure(error))")
            throw error
        }
    }
}
