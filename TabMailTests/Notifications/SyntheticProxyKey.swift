/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
@testable import TabMail

/// Synthetic proxy key pairs (SHA-256 of fixed labels, the same pair the proxy's tests use)
/// and an opener that reads a sent subscribe request the way the proxy does.
enum SyntheticProxyKey {
    enum OpenError: Error { case malformed, body }

    static func key(_ label: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(label.utf8))))
    }

    static func a() throws -> Curve25519.KeyAgreement.PrivateKey { try key("tabmail-hpke-test-key-a") }
    static func b() throws -> Curve25519.KeyAgreement.PrivateKey { try key("tabmail-hpke-test-key-b") }

    /// The base64 form `IMAPCredCrypto.sealingKey` takes.
    static func encoded(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Opens a v3 envelope with `key`, taking the key id, encapsulated key and sealed bytes
    /// from the wire. It does not pick a key by id, so another key reaches the HPKE open.
    static func open(_ wire: String, with key: Curve25519.KeyAgreement.PrivateKey, aad: Data) throws -> Data {
        guard wire.hasPrefix("v3:"), let packed = Data(base64Encoded: String(wire.dropFirst(3))),
              packed.count > 8 + 32 + 16 else { throw OpenError.malformed }
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: IMAPCredCrypto.envelopeInfo(keyId: Data(packed.prefix(8))),
            encapsulatedKey: Data(packed.dropFirst(8).prefix(32)))
        return try recipient.open(Data(packed.dropFirst(40)), authenticating: aad)
    }

    /// The authenticated data assembled from a sent request body's own fields, in the
    /// proxy's order, independent of `IMAPSubscribeContext`.
    static func aad(ofBody body: [String: Any]) throws -> Data {
        guard let userId = body["userId"] as? String, let deviceId = body["deviceId"] as? String,
              let accountEmail = body["accountEmail"] as? String, let deviceToken = body["deviceToken"] as? String,
              let apnsSandbox = body["apnsSandbox"] as? Bool, let nseCapable = body["nseCapable"] as? Bool
        else { throw OpenError.body }
        return try JSONSerialization.data(withJSONObject: [
            "tabmail-imap-subscribe-v2", userId, deviceId, "imap", accountEmail, deviceToken, apnsSandbox, nseCapable,
        ] as [Any], options: [.withoutEscapingSlashes])
    }

    /// Opens the credentials a sent subscribe body carries, authenticated by that body's fields.
    static func openSentBody(_ data: Data, with key: Curve25519.KeyAgreement.PrivateKey) throws -> IMAPCredPayload {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wire = body["credsCiphertext"] as? String else { throw OpenError.body }
        return try JSONDecoder().decode(IMAPCredPayload.self, from: open(wire, with: key, aad: aad(ofBody: body)))
    }
}
