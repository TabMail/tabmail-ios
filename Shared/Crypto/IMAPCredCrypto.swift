/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CryptoKit

// =============================================================================
// IMAPCredCrypto — AES-GCM encryption of IMAP credentials for transmission
// to the IMAP IDLE droplet via the push-worker.
//
// Contract:
//   • iOS encrypts a JSON-serialized `{host, port?, username, password, security?}`
//     blob with AES-GCM using a 32-byte symmetric key pre-shared between iOS
//     and the droplet (`IMAP_CRED_ENCRYPTION_KEY`).
//   • iOS POSTs the ciphertext to the push-worker; the worker is a dumb
//     forwarder — it NEVER holds the decryption key, NEVER persists creds.
//   • The droplet decrypts just-in-time, performs ImapFlow LOGIN, and zeros
//     the plaintext buffer immediately after.
//
// Ciphertext format (matches the push-worker's credential-encryption module):
//   "v1:" + base64(iv ‖ ciphertext ‖ authTag)
//     • iv:       12 bytes, freshly random per encryption call (AES-GCM
//                 nonce reuse is catastrophic — NEVER reuse an iv/key pair).
//     • authTag:  16 bytes, CryptoKit appends it to the sealed ciphertext
//                 automatically via `combined`.
//
// Version prefix `v1:` leaves room for future format migrations. The worker
// + droplet check for the prefix before attempting decryption.
//
// Key selection: always read `IMAP_CRED_ENCRYPTION_KEY_PROD`. Per the
// global CLAUDE.md rules (single KV_ENTITLEMENTS, single Stripe env),
// all shared infrastructure — push-worker, droplet, KV — is prod-only.
// A dev/prod split on this key would mean a Debug iOS build can't talk
// to the prod droplet, which is the only droplet that exists. The
// xcconfig still ships a _DEV variant for future isolation, but the
// runtime always picks _PROD.
//
// Shared across main-app + NSE targets via the `Shared/` glob. The NSE's
// silent-reconnect flow needs to encrypt too.
// =============================================================================

enum IMAPCredCryptoError: Error {
    /// Info.plist key missing or empty. Project config broke — shouldn't
    /// happen in a properly-built binary, but surface it loudly if it does.
    case keyMissing
    /// Decoded key is not exactly 32 bytes (AES-256).
    case keyWrongSize(Int)
    /// JSON encode of the creds dict failed. Every input is a String so this
    /// essentially can't happen; we surface it rather than crash.
    case encodeFailed
    /// CryptoKit sealing threw.
    case sealFailed
}

/// IMAP credential plaintext shape. Matches the droplet's `/start-idle`
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
    private static let versionPrefix = "v1:"
    private static let ivBytes = 12

    /// Encrypt an IMAP credential payload and return the `v1:<base64>` string
    /// to POST to `/subscribe-imap`. Fresh IV per call.
    static func encrypt(_ payload: IMAPCredPayload) throws -> String {
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(payload)
        } catch {
            throw IMAPCredCryptoError.encodeFailed
        }

        let key = try loadKey()
        let nonce = try AES.GCM.Nonce(data: randomBytes(ivBytes))
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        } catch {
            throw IMAPCredCryptoError.sealFailed
        }

        // Pack: iv ‖ ciphertext ‖ authTag (16 bytes). CryptoKit's `combined`
        // already concatenates all three in that order, which matches the
        // worker + droplet's decrypt expectation.
        guard let combined = sealed.combined else {
            throw IMAPCredCryptoError.sealFailed
        }
        return versionPrefix + combined.base64EncodedString()
    }

    // MARK: - Key loading

    /// Load the AES key bytes from Info.plist. Target-agnostic: works the
    /// same in main app + NSE because Info.plist is per-bundle and both
    /// bundles get the same xcconfig substitution.
    private static func loadKey() throws -> SymmetricKey {
        // Always use the PROD key — the push-worker and droplet are
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

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return data
    }
}
