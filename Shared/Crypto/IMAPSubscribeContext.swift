/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Request inputs available before the single subscribe call. Server admission
/// identities remain internal; this context is not a client subscription ledger.
struct IMAPSubscribeContext: Codable, Sendable, Equatable {
    let userId: String
    let deviceId: String
    let accountEmail: String
    let deviceToken: String
    let apnsSandbox: Bool
    let nseCapable: Bool

    /// UTF-8 compact ordered JSON, byte-compatible with the proxy's v2 AAD.
    func credentialContext() throws -> Data {
        let strings = [userId, deviceId, accountEmail, deviceToken]
        guard strings.allSatisfy({ value in
            !value.isEmpty && value.utf16.count <= 512
                && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        }) else {
            throw IMAPCredCryptoError.invalidContext
        }
        return try JSONSerialization.data(withJSONObject: [
            "tabmail-imap-subscribe-v2", userId, deviceId, "imap",
            accountEmail, deviceToken, apnsSandbox, nseCapable,
        ], options: [.withoutEscapingSlashes])
    }

    /// Foreground and NSE send this same body; no server admission round-trip.
    /// The returned data is transient and must never become persisted retry work.
    func requestBody(credentialEnvelope: String) throws -> Data {
        _ = try credentialContext()
        guard credentialEnvelope.hasPrefix("v2:"), credentialEnvelope.utf8.count > 3,
              credentialEnvelope.utf8.count <= 65_536 else {
            throw IMAPCredCryptoError.invalidContext
        }
        return try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 2, "userId": userId, "deviceId": deviceId,
            "provider": "imap", "accountEmail": accountEmail,
            "deviceToken": deviceToken, "apnsSandbox": apnsSandbox,
            "nseCapable": nseCapable, "credsCiphertext": credentialEnvelope,
        ])
    }
}

enum IMAPSubscribeOutcome: Equatable {
    case active
    case inProgress
    case cooldown
    case refused

    /// Only the explicit committed-active outcome may update restored UI/health.
    static func decode(statusCode: Int, body: Data) -> Self {
        if statusCode == 429 { return .cooldown }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let outcome = object["outcome"] as? String else { return .refused }
        if statusCode == 200 && outcome == "active" { return .active }
        if statusCode == 202 && outcome == "in_progress" { return .inProgress }
        return .refused
    }
}
