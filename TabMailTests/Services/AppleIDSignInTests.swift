/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import Testing
@testable import TabMail

/// Sign in with Apple through Apple's own sheet: the request it sends, how its result and its errors are
/// read, and the token exchange with the auth server.
@Suite("Sign in with Apple")
@MainActor
struct AppleIDSignInTests {

    private static let base64URL = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test("A raw nonce is 43 base64url characters (32 random bytes) and new every time")
    func rawNonce() {
        let nonces = (0..<20).map { _ in AppleIDSignIn.makeRawNonce() }
        for nonce in nonces {
            #expect(nonce.count == 43)
            let allowed = nonce.allSatisfy { Self.base64URL.contains($0) }
            #expect(allowed)
        }
        #expect(Set(nonces).count == nonces.count)
    }

    @Test("The nonce hash is SHA-256 in lowercase hex")
    func nonceHash() {
        #expect(AppleIDSignIn.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleIDSignIn.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("The sheet's request asks for the email address only and carries the hashed nonce, never the raw one")
    func request() {
        let rawNonce = "test-raw-nonce"
        let request = AppleIDSignIn.makeRequest(rawNonce: rawNonce)
        let scopes = request.requestedScopes
        #expect(scopes == [.email])
        #expect(request.nonce == AppleIDSignIn.sha256Hex(rawNonce))
        #expect(request.nonce != rawNonce)
    }

    @Test("The ID token is Apple's token as text")
    func idToken() throws {
        let token = try AppleIDSignIn.idToken(from: Data("header.payload.signature".utf8))
        #expect(token == "header.payload.signature")
    }

    @Test("No token, an empty token or one that is not UTF-8 is no session", arguments: [nil, Data(), Data([0xFF, 0xFE, 0xFD])] as [Data?])
    func noToken(data: Data?) {
        let isNoSession: Bool
        do {
            _ = try AppleIDSignIn.idToken(from: data)
            isNoSession = false
        } catch TabMailAuthError.noSession {
            isNoSession = true
        } catch {
            isNoSession = false
        }
        #expect(isNoSession)
    }

    @Test("Closing Apple's sheet ends quietly as a cancel, whether the error arrives typed or as an NSError")
    func cancel() {
        let typed = AppleIDSignIn.signInError(ASAuthorizationError(.canceled))
        #expect(typed is CancellationError)
        let bridged = AppleIDSignIn.signInError(NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue))
        #expect(bridged is CancellationError)
    }

    @Test("Any other sheet failure is passed on as it is")
    func otherFailures() {
        let failed = AppleIDSignIn.signInError(ASAuthorizationError(.failed))
        let failedCode = (failed as? ASAuthorizationError)?.code
        #expect(failedCode == .failed)
        let unknown = AppleIDSignIn.signInError(ASAuthorizationError(.unknown))
        let unknownCode = (unknown as? ASAuthorizationError)?.code
        #expect(unknownCode == .unknown)
        let offline = AppleIDSignIn.signInError(URLError(.notConnectedToInternet))
        let offlineCode = (offline as? URLError)?.code
        #expect(offlineCode == .notConnectedToInternet)
    }

    @Test("The Apple exchange posts the ID token and the raw nonce to the auth server's id_token grant")
    func appleExchange() throws {
        let request = try TabMailAuthService.idTokenGrantRequest(provider: .apple, idToken: "test-id-token", nonce: "test-raw-nonce")
        let url = request.url
        #expect(url?.scheme == "https")
        #expect(url?.host == "auth.tabmail.ai")
        #expect(url?.path == "/auth/v1/token")
        #expect(url?.query == "grant_type=id_token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let key = request.value(forHTTPHeaderField: "apikey")
        #expect(key?.isEmpty == false)
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let expectedAuthorization = key.map { "Bearer \($0)" }
        #expect(authorization == expectedAuthorization)
        let body = try Self.body(of: request)
        #expect(body == ["provider": "apple", "id_token": "test-id-token", "nonce": "test-raw-nonce"])
    }

    @Test("Google and Microsoft exchanges carry no nonce", arguments: [(TabMailProvider.google, "google"), (TabMailProvider.microsoft, "azure")])
    func exchangeWithoutNonce(provider: TabMailProvider, wireName: String) throws {
        let request = try TabMailAuthService.idTokenGrantRequest(provider: provider, idToken: "test-id-token", nonce: nil)
        let path = request.url?.path
        #expect(path == "/auth/v1/token")
        let body = try Self.body(of: request)
        #expect(body == ["provider": wireName, "id_token": "test-id-token"])
    }

    @Test("Apple sign-in no longer goes through the web: no authorize page, no callback page, no app URL scheme for it, and the app declares Sign in with Apple")
    func noWebSignIn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        let auth = try String(contentsOf: root.appendingPathComponent("TabMail/Services/TabMailAuthService.swift"), encoding: .utf8)
        #expect(!auth.contains("/auth/v1/authorize"))
        #expect(!auth.contains("ios-callback"))
        #expect(!auth.contains("ASWebAuthenticationSession"))
        let plist = try String(contentsOf: root.appendingPathComponent("TabMail/Resources/Info.plist"), encoding: .utf8)
        #expect(!plist.contains("<string>tabmail-ios</string>"))
        let entitlements = try String(contentsOf: root.appendingPathComponent("TabMail/TabMail.entitlements"), encoding: .utf8)
        #expect(entitlements.contains("<key>com.apple.developer.applesignin</key>"))
    }

    private static func body(of request: URLRequest) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        return object as? [String: String] ?? [:]
    }
}
