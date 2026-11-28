/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Sign in with Apple through Apple's own sheet (`ASAuthorizationController`). It returns Apple's ID
/// token and the raw nonce. The request asks for the email address only, no name, and carries the
/// nonce's SHA-256 as lowercase hex, which Apple puts in the token's `nonce` claim; the token exchange
/// at the auth server sends the raw nonce, which the server hashes and compares with that claim.
@MainActor
final class AppleIDSignIn: NSObject {
    struct Credential {
        let idToken: String
        let rawNonce: String
    }

    /// A fresh nonce: 32 random bytes as base64url without padding (43 characters of A-Z, a-z, 0-9,
    /// `-` and `_`).
    nonisolated static func makeRawNonce() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The request the sheet runs: the email scope only, and the hashed nonce.
    static func makeRequest(rawNonce: String) -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = sha256Hex(rawNonce)
        return request
    }

    /// The ID token Apple returned, as text; none, or not UTF-8, is no session.
    nonisolated static func idToken(from data: Data?) throws -> String {
        guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw TabMailAuthError.noSession
        }
        return token
    }

    /// The error a failed sheet ends with: the user closing it is a quiet cancel (`CancellationError`,
    /// which the login view ignores); any other error is passed on as it is.
    nonisolated static func signInError(_ error: Error) -> Error {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            return CancellationError()
        }
        return error
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var controller: ASAuthorizationController?
    private var rawNonce = ""

    /// Shows the sheet and waits for it to finish.
    func run() async throws -> Credential {
        let rawNonce = Self.makeRawNonce()
        self.rawNonce = rawNonce
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [Self.makeRequest(rawNonce: rawNonce)])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credential, Error>) {
        controller = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension AppleIDSignIn: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(TabMailAuthError.noSession))
            return
        }
        finish(Result { Credential(idToken: try Self.idToken(from: credential.identityToken), rawNonce: rawNonce) })
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(Self.signInError(error)))
    }
}

extension AppleIDSignIn: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        return ASPresentationAnchor(windowScene: scenes.first!)
    }
}
