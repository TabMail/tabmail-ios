/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import CryptoKit
@testable import TabMail

@Suite("OAuth PKCE and Codable")
struct OAuthTests {

    // MARK: - generateCodeVerifier

    @Test("Code verifier has expected length (32 bytes base64url = 43 chars)")
    @MainActor func codeVerifierLength() {
        let service = OAuthService()
        let verifier = service.generateCodeVerifier()
        // 32 bytes → 44 base64 chars → remove 1 padding '=' → 43
        #expect(verifier.count == 43)
    }

    @Test("Code verifier contains only base64url characters")
    @MainActor func codeVerifierCharacterSet() {
        let service = OAuthService()
        let verifier = service.generateCodeVerifier()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for scalar in verifier.unicodeScalars {
            #expect(allowed.contains(scalar), "Unexpected character: \(scalar)")
        }
    }

    @Test("Code verifier has no padding characters")
    @MainActor func codeVerifierNoPadding() {
        let service = OAuthService()
        let verifier = service.generateCodeVerifier()
        #expect(!verifier.contains("="))
    }

    @Test("Code verifier has no standard base64 characters (+, /)")
    @MainActor func codeVerifierNoStandardBase64Chars() {
        let service = OAuthService()
        let verifier = service.generateCodeVerifier()
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
    }

    @Test("Two code verifiers are different (randomness)")
    @MainActor func codeVerifierRandomness() {
        let service = OAuthService()
        let v1 = service.generateCodeVerifier()
        let v2 = service.generateCodeVerifier()
        #expect(v1 != v2)
    }

    // MARK: - generateCodeChallenge

    @Test("Code challenge is deterministic for same verifier")
    @MainActor func codeChallengeIsDeterministic() {
        let service = OAuthService()
        let verifier = "test_verifier_value"
        let c1 = service.generateCodeChallenge(from: verifier)
        let c2 = service.generateCodeChallenge(from: verifier)
        #expect(c1 == c2)
    }

    @Test("Code challenge contains only base64url characters")
    @MainActor func codeChallengeCharacterSet() {
        let service = OAuthService()
        let challenge = service.generateCodeChallenge(from: "some_verifier")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for scalar in challenge.unicodeScalars {
            #expect(allowed.contains(scalar), "Unexpected character: \(scalar)")
        }
    }

    @Test("Code challenge has no padding characters")
    @MainActor func codeChallengeNoPadding() {
        let service = OAuthService()
        let challenge = service.generateCodeChallenge(from: "verifier123")
        #expect(!challenge.contains("="))
    }

    @Test("Code challenge is SHA256 length (32 bytes base64url = 43 chars)")
    @MainActor func codeChallengeLength() {
        let service = OAuthService()
        let challenge = service.generateCodeChallenge(from: "any_verifier_string")
        #expect(challenge.count == 43)
    }

    @Test("Code challenge matches manual SHA256 computation")
    @MainActor func codeChallengeMatchesManualSHA256() {
        let service = OAuthService()
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = service.generateCodeChallenge(from: verifier)

        // Manually compute expected value
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let expected = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(challenge == expected)
    }

    @Test("Different verifiers produce different challenges")
    @MainActor func differentVerifiersDifferentChallenges() {
        let service = OAuthService()
        let c1 = service.generateCodeChallenge(from: "verifierA")
        let c2 = service.generateCodeChallenge(from: "verifierB")
        #expect(c1 != c2)
    }

    // MARK: - OAuthTokens Codable

    @Test("OAuthTokens round-trip with all fields")
    func oauthTokensFullRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1700000000)
        let tokens = OAuthTokens(
            accessToken: "ya29.access",
            refreshToken: "1//refresh",
            expiresAt: date,
            idToken: "eyJhbGciOiJSUzI1NiJ9"
        )
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: data)
        #expect(decoded.accessToken == "ya29.access")
        #expect(decoded.refreshToken == "1//refresh")
        #expect(decoded.expiresAt == date)
        #expect(decoded.idToken == "eyJhbGciOiJSUzI1NiJ9")
    }

    @Test("OAuthTokens round-trip with nil optional fields")
    func oauthTokensNilOptionals() throws {
        let tokens = OAuthTokens(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            idToken: nil
        )
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: data)
        #expect(decoded.accessToken == "token")
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.idToken == nil)
    }

    @Test("OAuthTokens decodes from JSON with missing optional keys")
    func oauthTokensDecodesFromPartialJSON() throws {
        let json = #"{"accessToken":"tok123"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: data)
        #expect(decoded.accessToken == "tok123")
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.idToken == nil)
    }
}
