/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security
import Synchronization
import Testing
import UIKit
@testable import TabMail

@Suite("Credential caller and account isolation regressions")
struct CredentialCallerRegressionTests {
    @Test("Cleanup for one account preserves the other account's usable authorization", arguments: ["install", "migrate", "remove"])
    func sweepBystander(operation: String) async throws {
        let h = CredentialTestHarness(), second = CredentialTestHarness()
        let store = h.provider
        let accountA = UUID().uuidString, accountB = UUID().uuidString
        let firstTokens = CredentialTestHarness.tokens("access-a", "grant-a")
        let secondTokens = CredentialTestHarness.tokens("access-b", "grant-b")
        let obsoleteA = try store.install(accountId: accountA, tokens: CredentialTestHarness.tokens("old-a", "old-grant-a"))
        let obsoleteKey = ProviderCredentialStore.lineagePrefix + accountA + ":" + obsoleteA.lineage
        let obsoleteRow = try #require(h.backend.item(account: obsoleteKey, accessGroup: TabMailSessionStore.accessGroup))
        try store.install(accountId: accountA, tokens: firstTokens)
        // The real install writer produced this obsolete grant. Restore the
        // reachable checkpoint where best-effort post-activation cleanup failed.
        h.backend.insertShared(account: obsoleteKey, data: obsoleteRow.data)
        let ownerB = try second.provider.install(accountId: accountB, tokens: secondTokens)
        // Both rows come from the real installation writer. Restore a checkpoint
        // containing two installed accounts before exercising the selected sweep.
        let secondItems = try #require({ () -> [TabMailSessionKeychainItem]? in
            if case .success(let values) = second.backend.enumerateServiceItems() { return values }; return nil
        }())
        for item in secondItems { h.backend.insertShared(account: item.account, data: item.data) }
        try #require(store.current(accountId: accountA) == firstTokens)
        try #require(store.current(accountId: accountB) == secondTokens)
        let grantBKey = ProviderCredentialStore.lineagePrefix + accountB + ":" + ownerB.lineage
        let grantB = try #require(h.backend.item(account: grantBKey, accessGroup: TabMailSessionStore.accessGroup))
        switch operation {
        case "install": try store.install(accountId: accountA, tokens: CredentialTestHarness.tokens("new-a", "new-grant-a"))
        case "migrate": try store.migrateLegacy(accountId: accountA)
        default: try store.remove(accountId: accountA)
        }
        #expect(store.current(accountId: accountA)?.accessToken == (operation == "remove" ? nil : operation == "install" ? "new-a" : "access-a"))
        #expect(h.backend.item(account: obsoleteKey, accessGroup: TabMailSessionStore.accessGroup) == nil)
        #expect(h.backend.item(account: grantBKey, accessGroup: TabMailSessionStore.accessGroup)?.data == grantB.data)
        #expect(store.current(accountId: accountB) == secondTokens)
        let calls = Mutex(0)
        let next = try? await h.provider.refresh(accountId: accountB, generation: ownerB.generation) { refresh in
            calls.withLock { $0 += 1 }
            #expect(refresh == "grant-b")
            return CredentialTestHarness.tokens("next-b", "next-grant-b")
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(next?.accessToken == "next-b")
        #expect(h.provider.current(accountId: accountB)?.refreshToken == "next-grant-b")
    }

    @MainActor
    @Test("A forced refresh changes an unexpired bearer and persists its replacement grant")
    func forceValidSession() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        let old = try CredentialTestHarness.sessionData(access: "before-metadata-change", refresh: "current-grant", expired: false)
        try store.installNewSession(old)
        let requests = Mutex(0)
        let coordinator = TabMailTokenCoordinator(sessionStore: store) { request in
            requests.withLock { $0 += 1 }
            let data = try #require(request.httpBody)
            let body = try JSONSerialization.jsonObject(with: data) as? [String:String]
            #expect(body?["refresh_token"] == "current-grant")
            return (try CredentialTestHarness.sessionData(access: "after-metadata-change", refresh: "next-grant", expired: false),
                    HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if case .success(let cached) = await coordinator.validToken() { #expect(cached == "before-metadata-change") }
        else { Issue.record("valid fixture did not reach cached bearer path") }
        #expect(requests.withLock { $0 } == 0)
        let result = await coordinator.forceRefresh()
        if case .success(let fresh) = result { #expect(fresh == "after-metadata-change") }
        else { Issue.record("force refresh failed") }
        #expect(requests.withLock { $0 } == 1)
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "after-metadata-change")
        #expect(saved.refreshToken == "next-grant")
    }

    @MainActor
    @Test("Each foreground coordinator honors execution admission and interruption", arguments: ["provider", "session-valid", "session-force"], ["denied", "early-expiry", "during-transport"])
    func callerAllowance(owner: String, interruption: String) async throws {
        let h = CredentialTestHarness(), store = h.sessions, providerStore = h.provider
        let originalSession = try CredentialTestHarness.sessionData()
        try store.installNewSession(originalSession)
        let id = UUID().uuidString, tokens = CredentialTestHarness.tokens()
        try providerStore.install(accountId: id, tokens: tokens)
        let providerCalls = Mutex(0), sessionCalls = Mutex(0)
        let allowance = CredentialRefreshBackgroundTaskTests.Allowance()
        allowance.mode = interruption == "during-transport" ? "success" : interruption
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let shouldSuspend = Mutex(interruption == "during-transport")
        let sessionCoordinator = TabMailTokenCoordinator(sessionStore: store) { request in
            sessionCalls.withLock { $0 += 1 }
            #expect(await MainActor.run { !allowance.outstanding.isEmpty })
            if shouldSuspend.withLock({ $0 }) {
                await started.signal(); await release.wait()
                try Task.checkCancellation()
            }
            return (try CredentialTestHarness.sessionData(access: "session-next", refresh: "session-grant-next", expired: false),
                    HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let providerCoordinator = OAuthRefreshCoordinator(store: providerStore)
        let perform: @MainActor () async -> String? = {
            if owner == "provider" {
                return try? await providerCoordinator.refresh(accountId: id, email: "user@example.com") { input in
                    providerCalls.withLock { $0 += 1 }
                    #expect(await MainActor.run { !allowance.outstanding.isEmpty })
                    #expect(input == "refresh-1")
                    if shouldSuspend.withLock({ $0 }) {
                        await started.signal(); await release.wait()
                        try Task.checkCancellation()
                    }
                    return OAuthTokens(accessToken: "provider-next", refreshToken: "provider-grant-next", expiresAt: nil, idToken: nil)
                }
            }
            let result = owner == "session-force" ? await sessionCoordinator.forceRefresh() : await sessionCoordinator.validToken()
            if case .success(let token) = result { return token }; return nil
        }
        let attempt = Task {
            await CredentialRefreshBackgroundTask.$platform.withValue(allowance.platform) { await perform() }
        }
        if interruption == "during-transport" {
            await started.wait()
            allowance.expiration?()
            #expect(allowance.outstanding.isEmpty)
            await release.signal()
        }
        let denied = await attempt.value
        #expect(denied == nil)
        let expectedInitialCalls = interruption == "during-transport" ? 1 : 0
        #expect(providerCalls.withLock { $0 } + sessionCalls.withLock { $0 } == expectedInitialCalls)
        #expect(providerStore.current(accountId: id) == tokens)
        #expect(store.loadActiveSession()?.data == originalSession)
        #expect(allowance.begins == 1)
        #expect(allowance.outstanding.isEmpty)
        let expectedInitialEnds = interruption == "denied" ? 0 : 1
        #expect(allowance.ended.count == expectedInitialEnds)
        allowance.mode = "success"
        shouldSuspend.withLock { $0 = false }
        let admitted = await CredentialRefreshBackgroundTask.$platform.withValue(allowance.platform) { await perform() }
        #expect(admitted == (owner == "provider" ? "provider-next" : "session-next"))
        #expect(providerCalls.withLock { $0 } + sessionCalls.withLock { $0 } == expectedInitialCalls + 1)
        #expect(allowance.begins == 2)
        #expect(allowance.outstanding.isEmpty)
        #expect(allowance.ended.count == expectedInitialEnds + 1)
        if owner == "provider" { #expect(providerStore.current(accountId: id)?.refreshToken == "provider-grant-next") }
        else {
            let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
            #expect(saved.refreshToken == "session-grant-next")
        }
    }

}
