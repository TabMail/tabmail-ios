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
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)

        // Set up a fake refresh token in Keychain
        let accountId = "test-refresh-\(UUID().uuidString)"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())

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
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)
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
    func invalidatedCoordinatorRefusesRefresh() async throws {
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)

        // Set up a valid refresh token
        let accountId = "test-invalidated-\(UUID().uuidString)"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())

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
    func invalidationIsPermanent() async throws {
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)
        let accountId = "test-permanent-\(UUID().uuidString)"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())

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

    @Test("invalidation during a refresh discards a late network result without recreating credentials")
    func invalidationDuringRefreshDoesNotRecreateToken() async throws {
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)
        let accountId = "test-inflight-invalidation-\(UUID().uuidString)"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())

        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let refreshTask = Task {
            try await coordinator.refresh(
                accountId: accountId,
                email: "test@example.com"
            ) { _ in
                await started.signal()
                await release.wait()
                return OAuthTokens(
                    accessToken: "must-not-be-saved",
                    refreshToken: "must-not-be-saved-either",
                    expiresAt: nil,
                    idToken: nil
                )
            }
        }

        await started.wait()
        await coordinator.invalidate()
        try store.remove(accountId: accountId)
        await release.signal()

        await #expect(throws: (any Error).self) {
            try await refreshTask.value
        }
        #expect(store.current(accountId: accountId) == nil)
        #expect(store.activation(accountId: accountId) == nil)
    }

    // MARK: - Deduplication

    @Test("concurrent refresh calls are deduplicated")
    func concurrentRefreshDeduplicated() async throws {
        let harness = CredentialTestHarness()
        let store = harness.provider
        let coordinator = OAuthRefreshCoordinator(store: store)
        let accountId = "test-dedup-\(UUID().uuidString)"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())

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
