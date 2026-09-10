/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security
import Synchronization
import Testing
@testable import TabMail

@Suite("Credential authority regressions")
struct CredentialAuthorityRegressionTests {
    @Test("A replacement selected before a verification-read failure keeps its active grant")
    func replacementVerificationFailure() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let accountId = "synthetic-existing-account"
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens("old-access", "old-refresh"))
        let reads = Mutex(0)
        h.backend.observeReads { key in
            guard key == ProviderCredentialStore.pointerPrefix + accountId else { return }
            let count = reads.withLock { $0 += 1; return $0 }
            // Existing selection, current()'s first check, and its final check
            // all succeed; only the post-write verification read fails.
            if count == 3 { h.backend.failNextSharedRead(status: errSecNotAvailable) }
        }
        #expect(throws: (any Error).self) {
            try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens("selected-access", "selected-refresh"))
        }
        h.backend.observeReads(nil)
        #expect(reads.withLock { $0 } == 4)
        #expect(store.current(accountId: accountId)?.accessToken == "selected-access")
        #expect(store.current(accountId: accountId)?.refreshToken == "selected-refresh")
        let selected = try #require(store.activation(accountId: accountId))
        let next = try await store.refresh(accountId: accountId, generation: selected.generation) { refresh in
            #expect(refresh == "selected-refresh")
            return .init(accessToken: "next-access", refreshToken: "next-refresh", expiresAt: Date().addingTimeInterval(3600))
        }
        #expect(next.accessToken == "next-access")
        #expect(store.current(accountId: accountId)?.refreshToken == "next-refresh")
        try store.migrateLegacy(accountId: accountId)
        if case .success(let items) = h.backend.enumerateServiceItems() { #expect(items.count == 2) }
        else { Issue.record("Selected login was lost") }
    }

    @Test("A failed replacement erases only its provisional secret and leaves the selected login usable", arguments: [false, true])
    func replacementPointerFailure(retainGrant: Bool) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let original = CredentialTestHarness.tokens("original-access", "original-refresh")
        try store.install(accountId: "synthetic-existing-account", tokens: original)
        let selected = try #require(store.activation(accountId: "synthetic-existing-account"))
        h.backend.failNextUpdate(status: errSecNotAvailable)
        #expect(throws: (any Error).self) {
            try store.install(accountId: "synthetic-existing-account", tokens: CredentialTestHarness.tokens("rejected-access", retainGrant ? nil : "provisional-secret"))
        }
        #expect(store.activation(accountId: "synthetic-existing-account") == selected)
        #expect(store.current(accountId: "synthetic-existing-account") == original)
        let items: [TabMailSessionKeychainItem]
        switch h.backend.enumerateServiceItems() {
        case .success(let value): items = value
        default: Issue.record("fixture lost the selected login"); return
        }
        #expect(items.count == 2)
        #expect(items.allSatisfy { !String(decoding: $0.data, as: UTF8.self).contains("provisional-secret") })
        // A normal foreground token use does not run migration/cleanup.
        let result = try await store.refresh(accountId: "synthetic-existing-account", generation: selected.generation) { refresh in
            #expect(refresh == "original-refresh")
            return .init(accessToken: "foreground-next", refreshToken: "foreground-next-refresh", expiresAt: nil)
        }
        #expect(result.accessToken == "foreground-next")
        let after = try #require({ () -> [TabMailSessionKeychainItem]? in
            if case .success(let values) = h.backend.enumerateServiceItems() { return values }; return nil
        }())
        #expect(after.allSatisfy { !String(decoding: $0.data, as: UTF8.self).contains("provisional-secret") })
    }

    @MainActor
    @Test("A valid cached session loses authority when sign-out commits during its read")
    func cachedSessionCannotSurviveDeactivation() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        let old = try store.installNewSession(CredentialTestHarness.sessionData(expired: false))
        let generation = try #require(old.generation)
        let raced = Mutex(false), calls = Mutex(0)
        h.backend.observeReads { key in
            if key == TabMailSessionStore.generationPrefix + generation, !raced.withLock({ value in let was = value; value = true; return was }) {
                // The same durable writes performed by deactivate(), scheduled
                // after this read captured its bytes and before its caller resumes.
                #expect(h.backend.deleteShared(account: TabMailSessionStore.pointerAccount) == .success)
                #expect(h.backend.deleteShared(account: key) == .success)
            }
        }
        let transport: NSETokenManager.DataForRequest = { request in
            calls.withLock { $0 += 1 }
            return (try CredentialTestHarness.sessionData(expired: false), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = await NSETokenManager.validAccessToken(sessionStore: store, dataForRequest: transport)
        h.backend.observeReads(nil)
        #expect(raced.withLock { $0 })
        #expect(calls.withLock { $0 } == 0)
        #expect(result == nil)
        #expect(store.loadActiveSession() == nil)
        #expect(h.backend.sessionNamespaceItems().isEmpty)
        // Positive control goes through the same cached-token path.
        try store.installNewSession(CredentialTestHarness.sessionData(access: "current", expired: false))
        #expect(await NSETokenManager.validAccessToken(sessionStore: store, dataForRequest: transport) == "current")
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("Foreground migration erases an interrupted activation's unselected grant")
    func migrationSweepsUnselectedGrant() throws {
        let h = CredentialTestHarness()
        try h.provider.install(accountId: "synthetic-account", tokens: CredentialTestHarness.tokens())
        // Recreate the durable state between the initial grant and pointer
        // writes. The committed account still owns this exact identifier.
        #expect(h.backend.deleteShared(account: ProviderCredentialStore.pointerPrefix + "synthetic-account") == .success)
        if case .success(let items) = h.backend.enumerateServiceItems() { #expect(items.count == 1) }
        else { Issue.record("The partial grant fixture was not reached") }
        let relaunched = h.provider
        try relaunched.migrateLegacy(accountId: "synthetic-account")
        #expect(relaunched.current(accountId: "synthetic-account") == nil)
        if case .success(let items) = h.backend.enumerateServiceItems() { #expect(items.isEmpty) }
    }

    @Test("Failed new-account activation must leave no unreachable provider grant", arguments: [false, true])
    func failedInitialActivation(verificationReadFails: Bool) throws {
        let h = CredentialTestHarness(), store = h.provider
        let firstAccount = "synthetic-initial-account"
        if verificationReadFails {
            let reads = Mutex(0)
            h.backend.observeReads { key in
                if key == ProviderCredentialStore.pointerPrefix + firstAccount {
                    let first = reads.withLock { count in count += 1; return count == 1 }
                    if first { h.backend.failNextSharedRead(status: errSecNotAvailable) }
                }
            }
        } else {
            h.backend.failNextAdd(account: ProviderCredentialStore.pointerPrefix + firstAccount,
                                  status: errSecNotAvailable)
        }
        #expect(throws: (any Error).self) {
            try store.install(accountId: firstAccount,
                              tokens: CredentialTestHarness.tokens("synthetic-access", "synthetic-abandoned-refresh"))
        }
        h.backend.observeReads(nil)
        #expect(store.activation(accountId: firstAccount) == nil)
        #expect(store.current(accountId: firstAccount) == nil)
        // Successful setup of another account must not be needed to erase
        // secrets left by this failed activation.
        let nextAccount = "synthetic-successful-retry-account"
        try store.install(accountId: nextAccount,
                          tokens: CredentialTestHarness.tokens("synthetic-retry-access", "synthetic-retry-refresh"))
        try store.migrateLegacy(accountId: nextAccount)
        #expect(store.current(accountId: nextAccount)?.refreshToken == "synthetic-retry-refresh")
        let items: [TabMailSessionKeychainItem]
        switch h.backend.enumerateServiceItems() {
        case .success(let found): items = found
        case .notFound: items = []
        case .failed: Issue.record("fixture enumeration failed"); return
        }
        let abandoned = items.filter { $0.account.hasPrefix(ProviderCredentialStore.lineagePrefix + firstAccount + ":") }
        #expect(abandoned.isEmpty)
        #expect(items.allSatisfy { !String(decoding: $0.data, as: UTF8.self).contains("synthetic-abandoned-refresh") })
    }

    @MainActor
    @Test("Received session rotation remains durable but expired invocation cannot receive a bearer")
    func sessionExpiry() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let work = Task {
            await NSETokenManager.validAccessToken(sessionStore: store) { request in
                await started.signal(); await release.wait()
                return (try CredentialTestHarness.sessionData(access: "synthetic-late-access", refresh: "synthetic-late-refresh", expired: false),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        await started.wait(); work.cancel(); await release.signal()
        let result = await work.value
        #expect(result == nil)
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "synthetic-late-access")
        #expect(saved.refreshToken == "synthetic-late-refresh")
    }

    @Test("Removal erases the actual credential items", arguments: [false, true])
    func removalErasesSecrets(replace: Bool) throws {
        let h = CredentialTestHarness(), store = h.provider
        try store.install(accountId: "synthetic-account", tokens: CredentialTestHarness.tokens())
        let before = try #require(store.current(accountId: "synthetic-account"))
        #expect(before.refreshToken == "refresh-1")
        if replace {
            try store.install(accountId: "synthetic-account", tokens: CredentialTestHarness.tokens("replacement", "replacement-refresh"))
            #expect(store.current(accountId: "synthetic-account")?.refreshToken == "replacement-refresh")
        } else {
            try store.remove(accountId: "synthetic-account")
            #expect(store.current(accountId: "synthetic-account") == nil)
        }
        let items: [TabMailSessionKeychainItem]
        switch h.backend.enumerateServiceItems() {
        case .success(let found): items = found
        case .notFound: items = []
        case .failed: Issue.record("Enumeration failed"); return
        }
        #expect(items.count == (replace ? 2 : 0))
        #expect(items.allSatisfy { !String(decoding: $0.data, as: UTF8.self).contains("refresh-1") })
    }

    @MainActor
    @Test("NSE cannot authorize follow-up work with an unpersisted session")
    func nseRequiresPersistence() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        let record = try store.installNewSession(CredentialTestHarness.sessionData())
        let calls = Mutex(0)
        let token = await NSETokenManager.validAccessToken(sessionStore: store) { request in
            calls.withLock { $0 += 1 }
            h.backend.failNextUpdate(status: errSecInteractionNotAllowed)
            return (try CredentialTestHarness.sessionData(access: "new-access", refresh: "new-refresh", expired: false),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(token == nil)
        #expect(store.loadActiveSession()?.location == record.location)
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "expired")
        #expect(saved.refreshToken == "refresh-1")
    }

    @MainActor
    @Test("An NSE invocation cannot adopt the next login before its first async operation")
    func nseCapturedGeneration() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        let first = try store.installNewSession(CredentialTestHarness.sessionData())
        try store.installNewSession(CredentialTestHarness.sessionData(access: "replacement", refresh: "replacement-refresh", expired: false))
        let calls = Mutex(0)
        let token = await NSETokenManager.$expectedGeneration.withValue(first.generation) {
            await NSETokenManager.validAccessToken(sessionStore: store) { _ in
                calls.withLock { $0 += 1 }; throw URLError(.badServerResponse)
            }
        }
        #expect(token == nil)
        #expect(calls.withLock { $0 } == 0)
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "replacement")
        #expect(saved.refreshToken == "replacement-refresh")
    }

    @MainActor
    @Test("Both real coordinator entry points keep same-user replacement refreshes separate", arguments: [false, true])
    func sameUserReplacement(force: Bool) async throws {
        let h = CredentialTestHarness(), store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let started = CredentialTestLatch(), release = CredentialTestLatch(), followerRead = CredentialTestLatch()
        let requests = Mutex<[String]>([])
        let coordinator = TabMailTokenCoordinator(sessionStore: store) { request in
            let json = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
            let refresh = try #require(json?["refresh_token"])
            requests.withLock { $0.append(refresh) }
            if refresh == "refresh-1" {
                await started.signal(); await release.wait()
            }
            let old = refresh == "refresh-1"
            return (try CredentialTestHarness.sessionData(access: old ? "old-result" : "replacement-result",
                refresh: old ? "old-next" : "replacement-next", expired: false),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let old = Task { await coordinator.validToken() }
        await started.wait()
        try store.installNewSession(CredentialTestHarness.sessionData(access: "replacement-expired", refresh: "replacement-grant"))
        h.backend.observeReads { key in
            if key.hasPrefix(TabMailSessionStore.generationPrefix) { Task { await followerRead.signal() } }
        }
        let next = Task { force ? await coordinator.forceRefresh() : await coordinator.validToken() }
        await followerRead.wait()
        h.backend.observeReads(nil)
        await release.signal()
        _ = await old.value
        let result = await next.value
        if case .success(let token) = result { #expect(token == "replacement-result") }
        else { Issue.record("Replacement refresh did not succeed") }
        #expect(requests.withLock { $0 } == ["refresh-1", "replacement-grant"])
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "replacement-result")
        #expect(saved.refreshToken == "replacement-next")
    }
}
