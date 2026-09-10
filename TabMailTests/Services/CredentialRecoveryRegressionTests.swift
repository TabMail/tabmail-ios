/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin
import Security
import Synchronization
import Testing
@testable import TabMail

@Suite("Credential recovery regressions")
struct CredentialRecoveryRegressionTests {
    private func ownedDescriptorCount(in directory: URL) -> Int {
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        var count = 0
        for descriptor in 0..<getdtablesize() {
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let status = bytes.withUnsafeMutableBytes { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            guard status == 0 else { continue }
            let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(prefix) { count += 1 }
        }
        return count
    }

    @Test("Credential refresh scratch storage stays bounded across retired account lifecycles")
    func storageBoundAcrossCredentialLifecycles() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let calls = Mutex(0)
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let control = h.directory.appendingPathComponent("descriptor-census-control")
        let before = ownedDescriptorCount(in: h.directory)
        do {
            let descriptor = open(control.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            #expect(ownedDescriptorCount(in: h.directory) == before + 1)
        }
        #expect(ownedDescriptorCount(in: h.directory) == before)
        try FileManager.default.removeItem(at: control)
        for i in 0..<256 {
            let id = UUID().uuidString
            let initial = try store.install(accountId: id, tokens: CredentialTestHarness.tokens("access-\(i)", "grant-\(i)"))
            let replacement = ProviderCredentialStore.Tokens(accessToken: "next-\(i)", refreshToken: "next-grant-\(i)", expiresAt: nil)
            let next = try await store.refresh(accountId: id, generation: initial.generation) { grant in
                calls.withLock { $0 += 1 }
                #expect(grant == "grant-\(i)")
                return replacement
            }
            #expect(next == replacement)
            #expect(store.current(accountId: id) == replacement)
            try store.remove(accountId: id)
            #expect(h.provider.current(accountId: id) == nil)
        }
        #expect(calls.withLock { $0 } == 256)
        // Count only this fixture's descriptors, independent of parallel tests.
        #expect(ownedDescriptorCount(in: h.directory) == before, "Completed refreshes must release their file descriptors")
        let files = try FileManager.default.contentsOfDirectory(at: h.directory, includingPropertiesForKeys: [.fileSizeKey])
        // The current implementation's declared fixed scratch-storage budget.
        #expect(files.count <= 64, "Persistent files must not grow per retired credential")
        switch h.backend.enumerateServiceItems() {
        case .notFound: break
        case .success(let items): #expect(items.isEmpty)
        case .failed: Issue.record("Credential namespace must remain readable after churn")
        }
    }

    @Test("An omitted grant and unreadable old credential cannot replace usable durable authorization")
    func missingGrantWithLockedRead() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let accountId = "synthetic-retained-account"
        let before = CredentialTestHarness.tokens("original-access", "original-grant")
        _ = try store.install(accountId: accountId, tokens: before)
        let reads = Mutex(0)
        h.backend.observeReads { key in
            guard key == ProviderCredentialStore.pointerPrefix + accountId else { return }
            let first = reads.withLock { $0 += 1; return $0 == 1 }
            if first { h.backend.failNextSharedRead(status: errSecInteractionNotAllowed) }
        }
        _ = try? store.install(accountId: accountId, tokens: CredentialTestHarness.tokens("interactive-access", nil))
        h.backend.observeReads(nil)
        #expect(reads.withLock { $0 } >= 1)
        // Either refusing this install or selecting new access is acceptable.
        // The only required invariant is that the usable grant survives.
        #expect(store.current(accountId: accountId)?.refreshToken == "original-grant")
        let fresh = try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens("interactive-access", nil))
        let calls = Mutex(0)
        let result = try await store.refresh(accountId: accountId, generation: fresh.generation) { refresh in
            calls.withLock { $0 += 1 }
            #expect(refresh == "original-grant")
            return CredentialTestHarness.tokens("recovered-access", "rotated-grant")
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(result.accessToken == "recovered-access")
        #expect(store.current(accountId: accountId)?.refreshToken == "rotated-grant")
    }


    @Test("An empty replacement refresh token cannot destroy working foreground authorization", arguments: ["gmail", "outlook"])
    func emptyRefresh(provider: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let original = CredentialTestHarness.tokens()
        let active = try store.install(accountId: "synthetic-account", tokens: original)
        let exchanges = Mutex(0)
        let auth = NSEAuthSource(accountId: "synthetic-account", provider: provider, store: store, clientId: "synthetic-client") { request in
            exchanges.withLock { $0 += 1 }
            return try CredentialTestHarness.response(request, access: "synthetic-new-access", refresh: "")
        }
        let result = await Result { try await auth.refresh() }
        #expect(exchanges.withLock { $0 } == 1)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(store.current(accountId: "synthetic-account") == original)
        let foregroundExchanges = Mutex(0)
        let recovered = await Result {
            try await store.refresh(accountId: "synthetic-account", generation: active.generation) { refresh in
                foregroundExchanges.withLock { $0 += 1 }
                #expect(refresh == original.refreshToken)
                return .init(accessToken: "synthetic-recovered", refreshToken: "synthetic-next", expiresAt: nil)
            }
        }
        #expect(foregroundExchanges.withLock { $0 } == 1)
        #expect((try? recovered.get())?.accessToken == "synthetic-recovered")
    }

    @Test("The retained production accessor recovers from a transient Keychain read failure")
    func retainedAccessorAfterStorageFailure() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let accountId = "synthetic-accessor-" + UUID().uuidString
        let original = ProviderCredentialStore.Tokens(accessToken: "usable-access", refreshToken: "usable-refresh",
                                                     expiresAt: Date().addingTimeInterval(3600))
        try store.install(accountId: accountId, tokens: original)
        let calls = Mutex(0)
        h.backend.failNextSharedRead(status: errSecNotAvailable)
        let accessor = await AccountManager.shared.makeOAuthAccessor(accountId: accountId, email: "user@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)) { _ in
                calls.withLock { $0 += 1 }
                return OAuthTokens(accessToken: "refreshed", refreshToken: "next", expiresAt: nil, idToken: nil)
            }
        // The failure may occur during construction or the first invocation.
        // Recovery must use this exact retained accessor and coordinator.
        _ = try? await accessor(false)
        #expect(store.current(accountId: accountId) == original)
        for attempt in 0..<3 {
            let token = try? await accessor(false)
            #expect(token == original.accessToken, "foreground attempt \(attempt) did not recover")
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(store.current(accountId: accountId) == original)
    }

    @Test("A temporary offline refresh must remain retryable on the next foreground", arguments: ["gmail", "outlook"])
    func offlineThenForeground(provider: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let activation = try store.install(accountId: "synthetic-account", tokens: CredentialTestHarness.tokens())
        let calls = Mutex(0)
        let auth = NSEAuthSource(accountId: "synthetic-account", provider: provider, store: store, clientId: "synthetic-client") { request in
            calls.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: URLError.self) { try await auth.refresh() }
        #expect(calls.withLock { $0 } == 1)
        #expect(store.activation(accountId: "synthetic-account") == activation)
        #expect(store.current(accountId: "synthetic-account")?.refreshToken == "refresh-1")
        // A new foreground owner represents a relaunched/foreground app. The
        // provider's authorization has not been revoked and the network is back.
        let foreground = OAuthRefreshCoordinator(store: h.provider)
        let result = await Result { () async throws -> String in
            try await foreground.refresh(accountId: "synthetic-account", email: "user@example.com") { refresh in
                calls.withLock { $0 += 1 }
                #expect(refresh == "refresh-1")
                return OAuthTokens(accessToken: "synthetic-recovered", refreshToken: "synthetic-next", expiresAt: Date().addingTimeInterval(3600), idToken: nil)
            }
        }
        #expect(calls.withLock { $0 } == 2)
        #expect((try? result.get()) == "synthetic-recovered")
        #expect(store.current(accountId: "synthetic-account")?.refreshToken == "synthetic-next")
    }

    @MainActor
    @Test("A temporary offline TabMail refresh must recover without a new login")
    func sessionOfflineThenForeground() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let calls = Mutex(0)
        let first = TabMailTokenCoordinator(sessionStore: store) { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        guard case .transientFailure = await first.validToken() else { Issue.record("Initial offline failure was misclassified"); return }
        let next = TabMailTokenCoordinator(sessionStore: h.sessions) { request in
            calls.withLock { $0 += 1 }
            return (try CredentialTestHarness.sessionData(access: "synthetic-recovered", refresh: "synthetic-next", expired: false),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = await next.validToken()
        #expect(calls.withLock { $0 } == 2)
        if case .success(let token) = result { #expect(token == "synthetic-recovered") }
        else { Issue.record("The next foreground refused recovery despite restored network and valid authorization") }
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.refreshToken == "synthetic-next")
    }

    @Test("Removal erases the grant while another owner holds its storage stripe; later login remains usable")
    func removalWhileRefreshOwnsStripe() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let accountId = "synthetic-held-stripe-account"
        let active = try store.install(accountId: accountId,
            tokens: CredentialTestHarness.tokens("old-access", "retired-secret"))
        let grantKey = ProviderCredentialStore.lineagePrefix + accountId + ":" + active.lineage
        let before = try #require(h.backend.item(account: grantKey, accessGroup: TabMailSessionStore.accessGroup))
        #expect(String(decoding: before.data, as: UTF8.self).contains("retired-secret"))
        // Same filesystem lock and a second open file description, as an app/NSE
        // refresh uses. Holding it is real, not inferred from a wire counter.
        try h.storageLock.withLock(grantKey) {
            var excluded = false
            do { try h.storageLock.withLock(grantKey) {} }
            catch CredentialRefreshError.busy { excluded = true }
            catch { Issue.record("Unexpected lock fixture error: \(error)") }
            try #require(excluded, "Lock fixture must exclude a competing owner")
            do { try store.remove(accountId: accountId) }
            catch { Issue.record("Provider removal depended on a busy refresh stripe: \(error)") }
            #expect(store.activation(accountId: accountId) == nil)
            #expect(store.current(accountId: accountId) == nil)
            #expect(h.backend.item(reference: before.persistentReference) == nil)
            switch h.backend.enumerateServiceItems() {
            case .notFound: break
            case .success(let items): #expect(items.isEmpty, "Erasure must remove secret bytes, not merely hide activation")
            case .failed: Issue.record("Erased credential namespace could not be read")
            }
        }
        // Positive control: erasure must not permanently fence later authorization.
        let next = try store.install(accountId: accountId,
            tokens: CredentialTestHarness.tokens("new-access", "new-grant"))
        let calls = Mutex(0)
        let refreshed = try await store.refresh(accountId: accountId, generation: next.generation) { grant in
            calls.withLock { $0 += 1 }
            #expect(grant == "new-grant")
            return CredentialTestHarness.tokens("usable-access", "usable-grant")
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(refreshed.accessToken == "usable-access")
        #expect(h.provider.current(accountId: accountId)?.refreshToken == "usable-grant")
        #expect(h.backend.item(reference: before.persistentReference) == nil)
    }

    @MainActor
    @Test("Successful sign-out must delete its secret even while its storage stripe is busy")
    func signOutDuringStorageLock() throws {
        let h = CredentialTestHarness(), store = h.sessions
        let record = try store.installNewSession(CredentialTestHarness.sessionData())
        let key = TabMailSessionStore.generationPrefix + (try #require(record.generation))
        #expect(h.backend.hasAccount(key))
        // Each withLock opens a distinct descriptor, as the other process does.
        try h.storageLock.withLock(key) { try store.deactivate() }
        #expect(store.loadActiveSession() == nil)
        #expect(!h.backend.hasAccount(TabMailSessionStore.pointerAccount))
        #expect(h.backend.sessionNamespaceItems().isEmpty)
        #expect(!store.isCleanupPending)
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
