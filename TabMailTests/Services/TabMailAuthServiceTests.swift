/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - TabMailSession Codable

@Suite("TabMailSession Codable")
struct TabMailSessionCodableTests {

    /// Canonical JSON matching the snake_case keys and nested `user` object
    /// that the custom Codable implementation expects.
    private func canonicalJSON(
        accessToken: String = "tok_abc",
        refreshToken: String = "ref_xyz",
        expiresAt: Int = 1_700_000_000,
        userId: String = "user-42",
        userEmail: String = "alice@example.com"
    ) -> Data {
        let json = """
        {
            "access_token": "\(accessToken)",
            "refresh_token": "\(refreshToken)",
            "expires_at": \(expiresAt),
            "user": {
                "id": "\(userId)",
                "email": "\(userEmail)"
            }
        }
        """
        return Data(json.utf8)
    }

    @Test("Round-trip encode then decode preserves all fields")
    func roundTrip() throws {
        let data = canonicalJSON()
        let decoded = try JSONDecoder().decode(TabMailSession.self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(TabMailSession.self, from: reencoded)

        #expect(redecoded.accessToken == "tok_abc")
        #expect(redecoded.refreshToken == "ref_xyz")
        #expect(redecoded.expiresAt == 1_700_000_000)
        #expect(redecoded.userId == "user-42")
        #expect(redecoded.userEmail == "alice@example.com")
    }

    @Test("Decode maps snake_case keys correctly")
    func snakeCaseMapping() throws {
        let data = canonicalJSON(accessToken: "at", refreshToken: "rt", expiresAt: 99)
        let session = try JSONDecoder().decode(TabMailSession.self, from: data)

        #expect(session.accessToken == "at")
        #expect(session.refreshToken == "rt")
        #expect(session.expiresAt == 99)
    }

    @Test("Decode flattens nested user object into userId and userEmail")
    func userFlattening() throws {
        let data = canonicalJSON(userId: "uid-1", userEmail: "bob@test.io")
        let session = try JSONDecoder().decode(TabMailSession.self, from: data)

        #expect(session.userId == "uid-1")
        #expect(session.userEmail == "bob@test.io")
    }

    @Test("Encode wraps userId and userEmail back into nested user object")
    func userWrapping() throws {
        let data = canonicalJSON(userId: "uid-2", userEmail: "carol@test.io")
        let session = try JSONDecoder().decode(TabMailSession.self, from: data)
        let encoded = try JSONEncoder().encode(session)

        let raw = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let user = raw["user"] as! [String: String]
        #expect(user["id"] == "uid-2")
        #expect(user["email"] == "carol@test.io")

        // Top-level must NOT contain userId/userEmail directly
        #expect(raw["userId"] == nil)
        #expect(raw["userEmail"] == nil)
    }

    @Test("Encode uses snake_case keys at top level")
    func encodeSnakeCase() throws {
        let data = canonicalJSON()
        let session = try JSONDecoder().decode(TabMailSession.self, from: data)
        let encoded = try JSONEncoder().encode(session)

        let raw = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(raw["access_token"] != nil)
        #expect(raw["refresh_token"] != nil)
        #expect(raw["expires_at"] != nil)
        // camelCase variants must NOT appear
        #expect(raw["accessToken"] == nil)
        #expect(raw["refreshToken"] == nil)
        #expect(raw["expiresAt"] == nil)
    }

    @Test("Decode fails when access_token is missing")
    func missingAccessToken() {
        let json = Data("""
        {
            "refresh_token": "r",
            "expires_at": 1,
            "user": {"id": "u", "email": "e"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode fails when refresh_token is missing")
    func missingRefreshToken() {
        let json = Data("""
        {
            "access_token": "a",
            "expires_at": 1,
            "user": {"id": "u", "email": "e"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode fails when expires_at is missing")
    func missingExpiresAt() {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "user": {"id": "u", "email": "e"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode fails when user object is missing")
    func missingUser() {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_at": 1
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode fails when user.id is missing")
    func missingUserId() {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_at": 1,
            "user": {"email": "e"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode fails when user.email is missing")
    func missingUserEmail() {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_at": 1,
            "user": {"id": "u"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode handles extra unknown fields gracefully")
    func extraFields() throws {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_at": 1,
            "user": {"id": "u", "email": "e", "name": "ignored"},
            "token_type": "bearer",
            "provider_token": "ignored"
        }
        """.utf8)
        let session = try JSONDecoder().decode(TabMailSession.self, from: json)
        #expect(session.accessToken == "a")
        #expect(session.userId == "u")
    }

    @Test("Decode fails when expires_at is a string instead of Int")
    func wrongTypeExpiresAt() {
        let json = Data("""
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_at": "not_an_int",
            "user": {"id": "u", "email": "e"}
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TabMailSession.self, from: json)
        }
    }

    @Test("Decode handles empty string values")
    func emptyStrings() throws {
        let data = canonicalJSON(accessToken: "", refreshToken: "", userId: "", userEmail: "")
        let session = try JSONDecoder().decode(TabMailSession.self, from: data)
        #expect(session.accessToken == "")
        #expect(session.refreshToken == "")
        #expect(session.userId == "")
        #expect(session.userEmail == "")
    }
}

// MARK: - TabMailAuthError

@Suite("TabMailAuthError")
struct TabMailAuthErrorTests {

    @Test("cancelled has non-empty description")
    func cancelledDescription() {
        let desc = TabMailAuthError.cancelled.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("noSession has non-empty description")
    func noSessionDescription() {
        let desc = TabMailAuthError.noSession.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("invalidSession has non-empty description")
    func invalidSessionDescription() {
        let desc = TabMailAuthError.invalidSession.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("invalidResponse has non-empty description")
    func invalidResponseDescription() {
        let desc = TabMailAuthError.invalidResponse.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("emailNotRegistered has non-empty description")
    func emailNotRegisteredDescription() {
        let desc = TabMailAuthError.emailNotRegistered.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("invalidOTP has non-empty description")
    func invalidOTPDescription() {
        let desc = TabMailAuthError.invalidOTP.errorDescription
        #expect(desc != nil)
        #expect(!desc!.isEmpty)
    }

    @Test("otpFailed passes through the associated message as description")
    func otpFailedDescription() {
        let msg = "Something went wrong on the server"
        let desc = TabMailAuthError.otpFailed(msg).errorDescription
        #expect(desc == msg)
    }

    @Test("otpFailed with empty string returns empty string")
    func otpFailedEmptyString() {
        let desc = TabMailAuthError.otpFailed("").errorDescription
        #expect(desc == "")
    }

    @Test("All fixed cases produce distinct descriptions")
    func distinctDescriptions() {
        let cases: [TabMailAuthError] = [
            .cancelled, .noSession, .invalidSession,
            .invalidResponse, .emailNotRegistered, .invalidOTP,
        ]
        let descriptions = cases.compactMap(\.errorDescription)
        #expect(descriptions.count == cases.count, "All cases should have descriptions")
        let unique = Set(descriptions)
        #expect(unique.count == descriptions.count, "All descriptions should be distinct")
    }

    @Test("Conforms to LocalizedError — localizedDescription uses errorDescription")
    func localizedErrorConformance() {
        let error: any Error = TabMailAuthError.cancelled
        // LocalizedError.localizedDescription should use errorDescription
        #expect(!error.localizedDescription.isEmpty)
    }
}

// MARK: - TabMailProvider

@Suite("TabMailProvider")
struct TabMailProviderTests {

    @Test("apple raw value is 'apple'")
    func appleRawValue() {
        #expect(TabMailProvider.apple.rawValue == "apple")
    }

    @Test("google raw value is 'google'")
    func googleRawValue() {
        #expect(TabMailProvider.google.rawValue == "google")
    }

    @Test("microsoft raw value is 'azure'")
    func microsoftRawValue() {
        #expect(TabMailProvider.microsoft.rawValue == "azure")
    }

    @Test("Init from raw value 'azure' produces .microsoft")
    func initFromAzure() {
        let provider = TabMailProvider(rawValue: "azure")
        #expect(provider == .microsoft)
    }

    @Test("Init from unknown raw value returns nil")
    func initFromUnknown() {
        let provider = TabMailProvider(rawValue: "facebook")
        #expect(provider == nil)
    }
}
