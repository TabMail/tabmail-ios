/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CryptoKit

// =============================================================================
// IMAPCredCrypto — AES-GCM encryption of IMAP credentials for transmission
// to the IMAP IDLE proxy via the push-worker.
//
// Contract:
//   • iOS encrypts a JSON-serialized `{host, port?, username, password, security?}`
//     blob with AES-GCM using a 32-byte symmetric key pre-shared between iOS
//     and the IDLE proxy (`IMAP_CRED_ENCRYPTION_KEY`).
//   • iOS authenticates the unified subscribe context as AES-GCM AAD.
//     The worker reserves a generation before forwarding the ciphertext;
//     it never holds the decryption key or persists IMAP credentials.
//   • The IDLE proxy consumes admission before decrypting and constructing
//     the connection, then clears transient credential buffers.
//
// Ciphertext format (matches the push-worker's credential-encryption module):
//   "v2:" + base64(iv ‖ ciphertext ‖ authTag)
//     • iv:       12 bytes, freshly random per encryption call (AES-GCM
//                 nonce reuse is catastrophic — NEVER reuse an iv/key pair).
//     • authTag:  16 bytes, CryptoKit appends it to the sealed ciphertext
//                 automatically via `combined`.
//
// The proxy checks the version and exact authenticated request context.
//
// Key selection: always read `IMAP_CRED_ENCRYPTION_KEY_PROD`. Per the
// global CLAUDE.md rules #9 and #10 (one shared backend entitlement store, one Stripe env),
// all shared infrastructure — push-worker, IDLE proxy, entitlement store — is prod-only.
// A dev/prod split on this key would mean a Debug iOS build can't talk
// to the prod IDLE proxy. The xcconfig still ships a _DEV variant for
// future isolation, but the runtime always picks _PROD.
//
// Shared across main-app + NSE targets via the `Shared/` glob. The NSE's
// silent-reconnect flow needs to encrypt too.
// =============================================================================

enum IMAPCredCryptoError: Error {
    case invalidContext
    /// Info.plist key missing or empty. Project config broke — shouldn't
    /// happen in a properly-built binary, but surface it loudly if it does.
    case keyMissing
    /// Decoded key is not exactly 32 bytes (AES-256).
    case keyWrongSize(Int)
    /// CryptoKit sealing threw.
    case sealFailed
}

/// IMAP credential plaintext shape. Matches the IDLE proxy's `/start-idle`
/// body schema (minus `userId`/`accountEmail` which stay on the outer
/// envelope). Keeping them in sync by hand is fine — there are five
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
    /// V2 binds the envelope to the inputs of one unified subscribe request;
    /// neither the payload nor the returned envelope belongs in persistent retry state.
    static func encrypt(_ payload: IMAPCredPayload, context: IMAPSubscribeContext) throws -> String {
        try sealAuthorityPayload(payload, context: context, key: loadKey())
    }

    /// Explicit-key seam also permits cross-platform tests without loading app secrets.
    static func sealAuthorityPayload(
        _ payload: IMAPCredPayload, context: IMAPSubscribeContext, key: SymmetricKey
    ) throws -> String {
        guard key.bitCount == 256 else { throw IMAPCredCryptoError.keyWrongSize(key.bitCount / 8) }
        let authenticatedContext = try context.credentialContext()
        var plaintext = try JSONEncoder().encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedContext)
        guard let combined = sealed.combined else { throw IMAPCredCryptoError.sealFailed }
        // CryptoKit generates a fresh nonce; the default 12-byte nonce precedes
        // ciphertext and tag in combined, matching the proxy's wire contract.
        return "v2:" + combined.base64EncodedString()
    }

    // MARK: - Key loading

    /// Load the AES key bytes from Info.plist. Target-agnostic: works the
    /// same in main app + NSE because Info.plist is per-bundle and both
    /// bundles get the same xcconfig substitution.
    private static func loadKey() throws -> SymmetricKey {
        // Always use the PROD key — the push-worker and IDLE proxy are
        // prod-only (see file-level comment).
        let plistKey = "IMAP_CRED_ENCRYPTION_KEY_PROD"

        // Bundle.main resolves to the NSE binary when this code runs inside
        // the NSE (appex). That's intentional — both Info.plists get the
        // same xcconfig values, so the key is present either way.
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
            !raw.isEmpty
        else {
            throw IMAPCredCryptoError.keyMissing
        }

        guard let keyData = Data(base64Encoded: raw) else {
            throw IMAPCredCryptoError.keyMissing
        }
        guard keyData.count == 32 else {
            throw IMAPCredCryptoError.keyWrongSize(keyData.count)
        }
        return SymmetricKey(data: keyData)
    }

}
