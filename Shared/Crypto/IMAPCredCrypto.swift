/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CryptoKit

// =============================================================================
// IMAPCredCrypto — seals IMAP credentials to the IMAP push proxy's public key
// for one subscribe request through the push worker.
//
// Contract:
//   • The app seals a JSON-serialized `{host, port?, username, password, security?}`
//     blob with HPKE base mode (RFC 9180): DHKEM(X25519, HKDF-SHA256),
//     HKDF-SHA256, ChaCha20-Poly1305. The recipient is the proxy's public key,
//     which ships in the app; only the proxy holds the private key, so the app
//     carries nothing that can open an envelope.
//   • The unified subscribe context is the authenticated data, so the envelope
//     is bound to user, device, account, device token, sandbox flag and NSE
//     capability. The worker forwards the envelope unopened; it holds no key.
//
// Envelope format:
//   "v3:" + base64(keyId ‖ enc ‖ ciphertext ‖ tag)
//     • keyId: the first 8 bytes of SHA-256 over the raw 32-byte public key,
//              derived from the key, never configured. The HPKE info is
//              "tabmail-imap-subscribe-v3" ‖ 0x00 ‖ keyId, which binds it, and
//              the proxy uses it to pick its key while it holds two.
//     • enc:   the 32-byte encapsulated key; one seal per envelope.
//     • tag:   16 bytes, appended to the ciphertext by CryptoKit.
//
// One key for every build: the app always talks to the prod push worker and
// proxy, Debug builds included. A new key pair reaches the app in a release;
// the proxy keeps the previous key until clients have moved.
//
// Shared across main-app + NSE targets via the `Shared/` glob. The NSE's
// silent-reconnect flow needs to seal too.
// =============================================================================

enum IMAPCredCryptoError: Error {
    case invalidContext
    /// The shipped proxy key is not a 32-byte X25519 public key. A build
    /// problem: the subscribe fails without sending anything, and the
    /// shipped-key test (`shippedProxyKeySeals`) catches it before release.
    case invalidProxyKey
}

/// IMAP credential plaintext shape. Matches the IDLE proxy's credential
/// payload schema (minus `userId`/`accountEmail` which stay on the outer
/// request). Keeping them in sync by hand is fine — there are five
/// fields and both sides have a schema guard.
struct IMAPCredPayload: Codable {
    let host: String
    let port: Int?
    let username: String
    let password: String
    let security: String?

    init(host: String, port: Int?, username: String, password: String, security: String?) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
    }
}

enum IMAPCredCrypto {
    /// The IMAP push proxy's public key: raw X25519, base64. Not a secret.
    static let proxyPublicKey = "z3K5rZvDFFUDkENNlcSA807/uZbQrzRrJ22cHaFvLQ4="

    /// The key `encrypt` seals to: the shipped proxy key. Only tests bind another,
    /// so both callers' real wiring can be opened with a synthetic key.
    @TaskLocal static var sealingKey = proxyPublicKey

    /// V3 binds the envelope to the inputs of one unified subscribe request;
    /// neither the payload nor the returned envelope belongs in persistent retry state.
    static func encrypt(_ payload: IMAPCredPayload, context: IMAPSubscribeContext) throws -> String {
        try sealAuthorityPayload(payload, context: context, to: proxyKey(sealingKey))
    }

    /// Explicit-recipient seam also permits cross-platform tests with test keys.
    static func sealAuthorityPayload(
        _ payload: IMAPCredPayload, context: IMAPSubscribeContext,
        to recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> String {
        let authenticatedContext = try context.credentialContext()
        let id = keyId(of: recipient)
        var sender = try HPKE.Sender(recipientKey: recipient,
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: envelopeInfo(keyId: id))
        var plaintext = try JSONEncoder().encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let sealed = try sender.seal(plaintext, authenticating: authenticatedContext)
        var packed = id
        packed.append(sender.encapsulatedKey)
        packed.append(sealed)
        return "v3:" + packed.base64EncodedString()
    }

    /// The first 8 bytes of SHA-256 over the raw public key.
    static func keyId(of key: Curve25519.KeyAgreement.PublicKey) -> Data {
        Data(SHA256.hash(data: key.rawRepresentation).prefix(8))
    }

    static func envelopeInfo(keyId: Data) -> Data {
        var info = Data("tabmail-imap-subscribe-v3".utf8)
        info.append(0)
        info.append(keyId)
        return info
    }

    static func proxyKey(_ encoded: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: encoded), raw.count == 32 else {
            throw IMAPCredCryptoError.invalidProxyKey
        }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }
}
