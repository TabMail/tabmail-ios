/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

@Suite("OAuthRefreshCoordinator")
struct OAuthRefreshCoordinatorTests {

    // MARK: - Basic Refresh

    @Test("refresh returns access token on success")
    func refreshReturnsToken() async throws {
        let coordinator = OAuthRefreshCoordinator()

        // Set up a fake refresh token in Keychain
        let accountId = "test-refresh-\(UUID().uuidString)"
        try KeychainHelper.save("fake-refresh", for: KeychainHelper.refreshTokenKey(accountId: accountId))
        defer {
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: accountId))
            KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: accountId))
        }

        let token = try await coordinator.refresh(
            accountId: accountId,
            email: "test@example.com"
        ) { _ in
            OAuthTokens(accessToken: "new-access-token", refreshToken: nil, expiresAt: nil, idToken: nil)
        }

        #expect(token == "new-access-token")
    }

    @Test("refresh throws when refresh token is missing from keychain")
    func refreshThrowsWithoutRefreshToken() async {
        let coordinator = OAuthRefreshCoordinator()
        let accountId = "test-missing-\(UUID().uuidString)"

        await #expect(throws: ProviderError.self) {
            try await coordinator.refresh(
                accountId: accountId,
                email: "test@example.com"
            ) { _ in
                OAuthTokens(accessToken: "tok", refreshToken: nil, expiresAt: nil, idToken: nil)
            }
        }
    }

    // MARK: - Invalidation

    @Test("invalidated coordinator refuses refresh immediately")
    func invalidatedCoordinatorRefusesRefresh() async {
        let coordinator = OAuthRefreshCoordinator()

        // Set up a valid refresh token
        let accountId = "test-invalidated-\(UUID().uuidString)"
        try? KeychainHelper.save("fake-refresh", for: KeychainHelper.refreshTokenKey(accountId: accountId))
        defer {
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: accountId))
        }

        // Invalidate BEFORE refresh
        await coordinator.invalidate()

        // Should throw immediately without calling the refresher
        let refresherCalled = Mutex<Bool>(false)
        await #expect(throws: ProviderError.self) {
            try await coordinator.refresh(
                accountId: accountId,
                email: "test@example.com"
            ) { _ in
                refresherCalled.withLock { $0 = true }
                return OAuthTokens(accessToken: "tok", refreshToken: nil, expiresAt: nil, idToken: nil)
            }
        }

        #expect(!refresherCalled.withLock { $0 })
    }

    @Test("invalidation is permanent — multiple refresh attempts all fail")
    func invalidationIsPermanent() async {
        let coordinator = OAuthRefreshCoordinator()
        let accountId = "test-permanent-\(UUID().uuidString)"
        try? KeychainHelper.save("fake-refresh", for: KeychainHelper.refreshTokenKey(accountId: accountId))
        defer {
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: accountId))
        }

        await coordinator.invalidate()

        for _ in 0..<3 {
            await #expect(throws: ProviderError.self) {
                try await coordinator.refresh(
                    accountId: accountId,
                    email: "test@example.com"
                ) { _ in
                    OAuthTokens(accessToken: "tok", refreshToken: nil, expiresAt: nil, idToken: nil)
                }
            }
        }
    }

    // MARK: - Deduplication

    @Test("concurrent refresh calls are deduplicated")
    func concurrentRefreshDeduplicated() async throws {
        let coordinator = OAuthRefreshCoordinator()
        let accountId = "test-dedup-\(UUID().uuidString)"
        try KeychainHelper.save("fake-refresh", for: KeychainHelper.refreshTokenKey(accountId: accountId))
        defer {
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: accountId))
            KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: accountId))
        }

        let callCount = Mutex<Int>(0)

        let refresher: @Sendable (_ refreshToken: String) async throws -> OAuthTokens = { _ in
            callCount.withLock { $0 += 1 }
            // Simulate network delay
            try await Task.sleep(for: .milliseconds(50))
            return OAuthTokens(accessToken: "deduped-token", refreshToken: nil, expiresAt: nil, idToken: nil)
        }

        // Launch two concurrent refreshes
        async let token1 = coordinator.refresh(accountId: accountId, email: "test@example.com", using: refresher)
        async let token2 = coordinator.refresh(accountId: accountId, email: "test@example.com", using: refresher)

        let results = try await [token1, token2]
        #expect(results[0] == "deduped-token")
        #expect(results[1] == "deduped-token")

        // Refresher should only have been called once (deduplication)
        let finalCount = callCount.withLock { $0 }
        #expect(finalCount == 1)
    }
}
