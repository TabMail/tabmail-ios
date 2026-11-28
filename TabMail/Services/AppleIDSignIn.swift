/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Sign in with Apple through Apple's own sheet, which SwiftUI's `AuthorizationController` runs from the
/// login view. The request asks for the email address only, no name, and carries the nonce's SHA-256 as
/// lowercase hex, which Apple puts in the token's `nonce` claim; the token exchange at the auth server
/// sends the raw nonce, which the server hashes and compares with that claim.
enum AppleIDSignIn {
    /// A fresh nonce: 32 random bytes as base64url without padding (43 characters of A-Z, a-z, 0-9,
    /// `-` and `_`).
    static func makeRawNonce() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The request the sheet runs: the email scope only, and the hashed nonce.
    static func makeRequest(rawNonce: String) -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = sha256Hex(rawNonce)
        return request
    }

    /// The ID token data of the sheet's result; a result that is not an Apple ID credential is no session.
    static func identityToken(of result: ASAuthorizationResult) throws -> Data? {
        guard case .appleID(let credential) = result else { throw TabMailAuthError.noSession }
        return credential.identityToken
    }

    /// The ID token Apple returned, as text; none, or not UTF-8, is no session.
    static func idToken(from data: Data?) throws -> String {
        guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw TabMailAuthError.noSession
        }
        return token
    }

    /// The error a failed sheet ends with: the user closing it is a quiet cancel (`CancellationError`,
    /// which the login view ignores); any other error is passed on as it is.
    static func signInError(_ error: Error) -> Error {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            return CancellationError()
        }
        return error
    }

    // MARK: - Account deletion: revoke the app's Sign in with Apple authorization

    /// Runs Apple's request on its sheet and returns the authorization code data of the result. The deletion
    /// screens pass SwiftUI's `AuthorizationController`; tests pass a stand-in.
    typealias CodeAuthorization = @MainActor (ASAuthorizationAppleIDRequest) async throws -> Data?

    /// The request the deletion sheet runs: no scopes and no nonce. Only its authorization code is used,
    /// which billing exchanges and revokes at Apple once the deletion is scheduled.
    static func makeRevokeRequest() -> ASAuthorizationAppleIDRequest {
        ASAuthorizationAppleIDProvider().createRequest()
    }

    /// The authorization code data of the sheet's result; a result that is not an Apple ID credential has none.
    static func authorizationCode(of result: ASAuthorizationResult) -> Data? {
        guard case .appleID(let credential) = result else { return nil }
        return credential.authorizationCode
    }

    /// A fresh authorization code from Apple's sheet, as text. Every way the sheet can end without one (the
    /// person closes it, it fails, no code or one that is not UTF-8) gives nil and never throws, so the
    /// deletion goes ahead without it. The code is never logged.
    @MainActor
    static func freshAuthorizationCode(authorize: CodeAuthorization) async -> String? {
        let data: Data?
        do {
            data = try await authorize(makeRevokeRequest())
        } catch {
            let ending = signInError(error) is CancellationError ? "closed" : "failed"
            BackgroundSyncLogger.logDebug("[AppleIDSignIn] Revoke sheet \(ending) with no code")
            return nil
        }
        guard let data, let code = String(data: data, encoding: .utf8), !code.isEmpty else {
            BackgroundSyncLogger.logDebug("[AppleIDSignIn] Revoke sheet gave no usable code")
            return nil
        }
        return code
    }

    /// The account deletion request, with Apple's sheet in front of it for an account that signed in with
    /// Apple: called once the subscription steps are done, right before the request, so the code (valid for
    /// five minutes) is fresh. A sheet that ends without a code sends the request without one, so the deletion
    /// goes ahead either way.
    @MainActor
    static func scheduleDeletion(
        isAppleAccount: Bool,
        authorize: CodeAuthorization,
        request: (_ appleAuthorizationCode: String?) async throws -> BillingClient.DeletionResponse
    ) async throws -> BillingClient.DeletionResponse {
        let code = isAppleAccount ? await freshAuthorizationCode(authorize: authorize) : nil
        return try await request(code)
    }

    /// Whether the deletion confirmation shows how to stop using the Apple Account with TabMail by hand: for an
    /// account that signed in with Apple whose answer is not `true` (false; or nil: no code was sent, or the
    /// answer was lost and the deletion read back from its status).
    static func showsManualStopLine(isAppleAccount: Bool, appleAuthorizationRevoked: Bool?) -> Bool {
        isAppleAccount && appleAuthorizationRevoked != true
    }

    /// Whether the TabMail account signed in with Apple, from the `app_metadata.providers` list in the app's
    /// own access token. The token is decoded, not verified: the answer only decides whether to show Apple's
    /// sheet. A missing or malformed token (not three non-empty segments), or one without the list, is not an
    /// Apple account.
    static func isAppleAccount(accessToken: String?) -> Bool {
        guard let accessToken else { return false }
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts.contains(where: \.isEmpty) else { return false }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let payload = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let appMetadata = claims["app_metadata"] as? [String: Any],
              let providers = appMetadata["providers"] as? [String] else {
            return false
        }
        return providers.contains("apple")
    }
}
