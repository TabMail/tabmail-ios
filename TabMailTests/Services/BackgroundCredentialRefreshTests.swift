/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security
import Synchronization
import Testing
@testable import TabMail

actor CredentialTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        let timeout = Task.detached { [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await timedOut()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func timedOut() {
        guard !signaled else { return }
        Issue.record("Credential test did not reach its expected event within 10 seconds")
        signal()
    }
    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class CredentialTestHarness: @unchecked Sendable {
    let backend = MemorySessionKeychainBackend()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaultsName = "credential-tests." + UUID().uuidString
    var storageLock: CredentialStorageLock { .init(directory: directory) }
    var provider: ProviderCredentialStore { .init(backend: backend, storageLock: storageLock) }
    var sessions: TabMailSessionStore {
        .init(backend: backend, storageLock: storageLock, cleanupDefaults: UserDefaults(suiteName: defaultsName)!)
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
    static func tokens(_ access: String = "expired", _ refresh: String? = "refresh-1") -> ProviderCredentialStore.Tokens {
        .init(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(-120))
    }
    static func response(_ request: URLRequest, access: String = "access-2", refresh: String? = "refresh-2",
                         status: Int = 200) throws -> (Data, URLResponse) {
        var json: [String: Any] = ["access_token": access, "expires_in": 3600]
        if let refresh { json["refresh_token"] = refresh }
        return (try JSONSerialization.data(withJSONObject: json),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    static func sessionData(user: String = "user-a", access: String = "expired", refresh: String = "refresh-1",
                            expired: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": refresh,
            "expires_at": Int(Date().addingTimeInterval(expired ? -120 : 3600).timeIntervalSince1970),
            "user": ["id": user, "email": "user@example.com"]], options: .sortedKeys)
    }
}

@Suite("Background credential refresh ownership")
struct BackgroundCredentialRefreshTests {
    @Test("Interrupted migration erases all retired legacy credentials on next foreground", arguments: ["accessToken:", "refreshToken:"])
    func retryErasesLegacy(failingKey: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let id = "synthetic-migration-retry-account"
        let accessRef = h.backend.insertShared(account: "accessToken:" + id, data: Data("synthetic-legacy-access".utf8))
        let refreshRef = h.backend.insertShared(account: "refreshToken:" + id, data: Data("synthetic-legacy-refresh".utf8))
        let failedRef = failingKey == "accessToken:" ? accessRef : refreshRef
        h.backend.failDelete(reference: failedRef)
        #expect(throws: (any Error).self) { try store.migrateLegacy(accountId: id) }
        let active = try #require(store.activation(accountId: id))
        #expect(store.current(accountId: id)?.accessToken == "synthetic-legacy-access")
        #expect(store.current(accountId: id)?.refreshToken == "synthetic-legacy-refresh")
        #expect(h.backend.item(reference: failedRef) != nil)
        h.backend.allowDelete(reference: failedRef)
        let relaunched = h.provider
        try relaunched.migrateLegacy(accountId: id)
        #expect(relaunched.activation(accountId: id) == active)
        #expect(!h.backend.hasAccount("accessToken:" + id))
        #expect(!h.backend.hasAccount("refreshToken:" + id))
        let calls = Mutex(0)
        let refreshed = try await relaunched.refresh(accountId: id, generation: active.generation) { grant in
            calls.withLock { $0 += 1 }
            #expect(grant == "synthetic-legacy-refresh")
            return .init(accessToken: "synthetic-current-access", refreshToken: "synthetic-current-refresh", expiresAt: Date().addingTimeInterval(3600))
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(refreshed.accessToken == "synthetic-current-access")
        #expect(h.provider.current(accountId: id)?.refreshToken == "synthetic-current-refresh")
        #expect(!h.backend.hasAccount("accessToken:" + id))
        #expect(!h.backend.hasAccount("refreshToken:" + id))
    }

    @Test("Overlapping main and NSE responses preserve one coherent pair and its next refresh", arguments: ["gmail", "outlook"], [false, true])
    func overlap(provider: String, foregroundWins: Bool) async throws {
        let h = CredentialTestHarness(), store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let nseStarted = CredentialTestLatch(), foregroundStarted = CredentialTestLatch()
        let releaseNSE = CredentialTestLatch(), releaseForeground = CredentialTestLatch()
        let requests = Mutex<[String]>([])
        let auth = NSEAuthSource(accountId: "account", provider: provider, store: h.provider, clientId: "synthetic-client") { request in
            requests.withLock { $0.append("nse") }
            await nseStarted.signal(); await releaseNSE.wait()
            return try CredentialTestHarness.response(request)
        }
        let nse = Task { try await auth.refresh() }
        await nseStarted.wait()
        let coordinator = OAuthRefreshCoordinator(store: store)
        let foreground = Task {
            try await coordinator.refresh(accountId: "account", email: "user@example.com") { refresh in
                #expect(refresh == "refresh-1")
                requests.withLock { $0.append("foreground") }
                await foregroundStarted.signal(); await releaseForeground.wait()
                return OAuthTokens(accessToken: "late-access", refreshToken: "late-refresh", expiresAt: nil, idToken: nil)
            }
        }
        await foregroundStarted.wait()
        let expectedAccess = foregroundWins ? "late-access" : "access-2"
        let expectedGrant = foregroundWins ? "late-refresh" : "refresh-2"
        if foregroundWins {
            await releaseForeground.signal()
            #expect(try await foreground.value == expectedAccess)
            await releaseNSE.signal()
        } else {
            await releaseNSE.signal()
            #expect(try await nse.value == expectedAccess)
            await releaseForeground.signal()
        }
        #expect(try await foreground.value == expectedAccess)
        #expect(try await nse.value == expectedAccess)
        #expect(requests.withLock { $0 } == ["nse", "foreground"])
        #expect(store.current(accountId: "account")?.accessToken == expectedAccess)
        #expect(store.current(accountId: "account")?.refreshToken == expectedGrant)
        let next = try await coordinator.refresh(accountId: "account", email: "user@example.com") { refresh in
            #expect(refresh == expectedGrant)
            return OAuthTokens(accessToken: "access-3", refreshToken: "refresh-3", expiresAt: nil, idToken: nil)
        }
        #expect(next == "access-3")
        #expect(store.current(accountId: "account")?.accessToken == "access-3")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh-3")
    }

    @Test("Late refresh preserves newer interactive access and its retained grant rotation", arguments: [false, true])
    func sameGrantReplacement(explicitGrant: Bool) async throws {
        let h = CredentialTestHarness(), started = CredentialTestLatch(), release = CredentialTestLatch()
        let store = h.provider
        let old = try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            await started.signal(); await release.wait()
            return try CredentialTestHarness.response(request)
        }
        let task = Task { try await auth.refresh() }
        await started.wait()
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("interactive", explicitGrant ? "refresh-1" : nil), expectedGeneration: old.generation)
        await release.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(store.current(accountId: "account")?.accessToken == "interactive")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh-2")
        let coordinator = OAuthRefreshCoordinator(store: store)
        let refreshed = try await coordinator.refresh(accountId: "account", email: "user@example.com") { refresh in
            #expect(refresh == "refresh-2")
            return OAuthTokens(accessToken: "interactive-next", refreshToken: nil, expiresAt: nil, idToken: nil)
        }
        #expect(refreshed == "interactive-next")
    }

    @Test("Removal and fresh login do not wait for an old request or accept its late result", arguments: [false, true])
    func removalOrReplacement(replace: Bool) async throws {
        let h = CredentialTestHarness(), started = CredentialTestLatch(), release = CredentialTestLatch()
        let store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            await started.signal(); await release.wait()
            return try CredentialTestHarness.response(request, access: "late", refresh: "late-refresh")
        }
        let task = Task { try await auth.refresh() }
        await started.wait()
        if replace {
            try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("new-login", "new-grant"))
            let fresh = OAuthRefreshCoordinator(store: store)
            let refreshed = try await fresh.refresh(accountId: "account", email: "user@example.com") { refresh in
                #expect(refresh == "new-grant")
                return OAuthTokens(accessToken: "new-next", refreshToken: "new-next-grant", expiresAt: nil, idToken: nil)
            }
            #expect(refreshed == "new-next")
        } else { try store.remove(accountId: "account") }
        await release.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(store.current(accountId: "account")?.accessToken == (replace ? "new-next" : nil))
        #expect(store.current(accountId: "account")?.refreshToken == (replace ? "new-next-grant" : nil))
    }

    @Test("Interrupted legacy setup preserves access-only authorization and erases it on replacement")
    func accessOnlyLegacyMigration() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let id = "synthetic-access-only"
        let key = "accessToken:" + id
        let reference = h.backend.insertShared(account: key, data: Data("synthetic-legacy-access".utf8))
        try store.migrateLegacy(accountId: id)
        let migrated = try #require(store.activation(accountId: id))
        #expect(store.current(accountId: id)?.accessToken == "synthetic-legacy-access")
        #expect(store.current(accountId: id)?.refreshToken == nil)
        #expect(h.backend.item(reference: reference) == nil)
        #expect(!h.backend.hasAccount(key))
        let calls = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await store.refresh(accountId: id, generation: migrated.generation) { _ in
                calls.withLock { $0 += 1 }
                return CredentialTestHarness.tokens("forbidden", "forbidden")
            }
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(store.current(accountId: id)?.accessToken == "synthetic-legacy-access")
        let replacement = ProviderCredentialStore.Tokens(accessToken: "interactive-access", refreshToken: "interactive-grant", expiresAt: nil)
        let active = try store.install(accountId: id, tokens: replacement)
        try store.migrateLegacy(accountId: id)
        #expect(store.current(accountId: id) == replacement)
        #expect(h.backend.item(reference: reference) == nil)
        let next = try await store.refresh(accountId: id, generation: active.generation) { grant in
            calls.withLock { $0 += 1 }
            #expect(grant == "interactive-grant")
            return .init(accessToken: "refreshed-access", refreshToken: "rotated-grant", expiresAt: nil)
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(next.accessToken == "refreshed-access")
        #expect(store.current(accountId: id) == next)
        try store.remove(accountId: id)
        try store.migrateLegacy(accountId: id)
        #expect(store.current(accountId: id) == nil)
        #expect(h.backend.item(reference: reference) == nil)
    }

    @Test("Migration copies a complete legacy pair and deletion cannot import it again")
    func migrationAndRemoval() throws {
        let h = CredentialTestHarness(), store = h.provider
        h.backend.insertShared(account: "accessToken:account", data: Data("access".utf8))
        h.backend.insertShared(account: "refreshToken:account", data: Data("refresh".utf8))
        try store.migrateLegacy(accountId: "account")
        #expect(store.current(accountId: "account")?.accessToken == "access")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh")
        #expect(!h.backend.hasAccount("accessToken:account"))
        #expect(!h.backend.hasAccount("refreshToken:account"))
        try store.remove(accountId: "account")
        try store.migrateLegacy(accountId: "account")
        #expect(store.current(accountId: "account") == nil)
    }

    @Test("A failed credential write preserves the old pair and cannot report repair")
    func credentialWriteFailure() async throws {
        let h = CredentialTestHarness(), store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let called = Mutex(false)
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            called.withLock { $0 = true }
            return try CredentialTestHarness.response(request)
        }
        h.backend.failNextUpdate(status: errSecInteractionNotAllowed)
        await #expect(throws: (any Error).self) { try await auth.refresh() }
        #expect(called.withLock { $0 })
        #expect(store.current(accountId: "account")?.accessToken == "expired")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh-1")
    }

    @Test("Received rotations survive caller cancellation, but cannot authorize another operation")
    func cancellationAfterSubmission() async throws {
        let h = CredentialTestHarness(), started = CredentialTestLatch(), release = CredentialTestLatch()
        let store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            await started.signal(); await release.wait()
            return try CredentialTestHarness.response(request)
        }
        let task = Task { try await auth.refresh() }
        await started.wait()
        task.cancel()
        await release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.current(accountId: "account")?.accessToken == "access-2")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh-2")
    }

    @Test("Malformed, rejected, offline, and failed-persistence responses cannot report repair", arguments: [0, 400, 500, 200, 201])
    func failurePreservesCredentials(status: Int) async throws {
        let h = CredentialTestHarness(), store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            if status == 0 { throw URLError(.notConnectedToInternet) }
            if status == 200 { h.backend.failNextUpdate(status: errSecInteractionNotAllowed) }
            if status == 201 {
                return (Data("{bad-json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!)
            }
            return try CredentialTestHarness.response(request, status: status)
        }
        await #expect(throws: (any Error).self) { try await auth.refresh() }
        #expect(store.current(accountId: "account")?.accessToken == "expired")
        #expect(store.current(accountId: "account")?.refreshToken == "refresh-1")
        if status == 400 {
            // An explicit authorization rejection still needs interactive repair.
            try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("repaired", "new-grant"))
            #expect(store.current(accountId: "account")?.accessToken == "repaired")
        } else {
            let foreground = OAuthRefreshCoordinator(store: h.provider)
            let recovered = try await foreground.refresh(accountId: "account", email: "user@example.com") { refresh in
                #expect(refresh == "refresh-1")
                return OAuthTokens(accessToken: "recovered", refreshToken: "next-grant", expiresAt: nil, idToken: nil)
            }
            #expect(recovered == "recovered")
            #expect(store.current(accountId: "account")?.accessToken == "recovered")
            #expect(store.current(accountId: "account")?.refreshToken == "next-grant")
        }
    }

    @Test("Form encoding preserves opaque token and client values and omitted rotation retains the grant", arguments: ["gmail", "outlook"])
    func formEncoding(provider: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let opaque = "synthetic+&=% value"
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("", opaque))
        let auth = NSEAuthSource(accountId: "account", provider: provider, store: store, clientId: opaque) { request in
            let data = try #require(request.httpBody)
            let body = try #require(String(data: data, encoding: .utf8))
            var fields: [String: String] = [:]
            for field in body.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                try #require(parts.count == 2)
                let key = try #require(String(parts[0]).removingPercentEncoding)
                let value = try #require(String(parts[1]).removingPercentEncoding)
                try #require(fields.updateValue(value, forKey: key) == nil)
            }
            #expect(fields["refresh_token"] == opaque)
            #expect(fields["client_id"] == opaque)
            return try CredentialTestHarness.response(request, refresh: nil)
        }
        #expect(await auth.current() == nil)
        #expect(try await auth.refresh() == "access-2")
        #expect(store.current(accountId: "account")?.refreshToken == opaque)
    }

    @MainActor
    @Test("An already-valid replacement remains immediately usable during an older refresh")
    func sessionReplacement() async throws {
        let h = CredentialTestHarness(), started = CredentialTestLatch(), release = CredentialTestLatch()
        let store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let coordinator = TabMailTokenCoordinator(sessionStore: store) { request in
            await started.signal(); await release.wait()
            return (try CredentialTestHarness.sessionData(access: "late", refresh: "late-refresh", expired: false),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = Task { await coordinator.validToken() }
        await started.wait()
        let replacement = try store.installNewSession(CredentialTestHarness.sessionData(access: "new", refresh: "new-refresh", expired: false))
        guard case .success(let next) = await coordinator.validToken() else {
            await release.signal(); _ = await first.value
            Issue.record("A fresh login must remain immediately usable"); return
        }
        #expect(next == "new")
        await release.signal()
        _ = await first.value
        #expect(store.loadActiveSession() == replacement)
    }

    @MainActor
    @Test("Overlapping TabMail refreshes return the durably selected pair", arguments: [false, true])
    func sessionOverlap(foregroundWins: Bool) async throws {
        let h = CredentialTestHarness(), started = CredentialTestLatch(), release = CredentialTestLatch()
        let store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let requests = Mutex(0)
        let secondStarted = CredentialTestLatch(), releaseSecond = CredentialTestLatch()
        let transport: TabMailSessionRefresh.Transport = { request in
            let first = requests.withLock { count in count += 1; return count == 1 }
            if first { await started.signal(); await release.wait() }
            else { await secondStarted.signal(); await releaseSecond.wait() }
            return (try CredentialTestHarness.sessionData(access: first ? "late-access" : "fresh",
                refresh: first ? "late-refresh" : "rotated", expired: false),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = TabMailTokenCoordinator(sessionStore: store, dataForRequest: transport)
        let foreground = Task { await coordinator.validToken() }
        await started.wait()
        let nse = Task { await NSETokenManager.validAccessToken(sessionStore: h.sessions, dataForRequest: transport) }
        await secondStarted.wait()
        let expectedAccess = foregroundWins ? "late-access" : "fresh"
        let expectedGrant = foregroundWins ? "late-refresh" : "rotated"
        if foregroundWins {
            await release.signal()
            _ = await foreground.value
            await releaseSecond.signal()
        } else {
            await releaseSecond.signal()
            #expect(await nse.value == expectedAccess)
            await release.signal()
        }
        #expect(await nse.value == expectedAccess)
        guard case .success(let token) = await foreground.value else { Issue.record("Foreground refresh failed"); return }
        #expect(token == expectedAccess)
        #expect(requests.withLock { $0 } == 2)
        let persisted = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(persisted.accessToken == expectedAccess)
        #expect(persisted.refreshToken == expectedGrant)
    }

    @Test("Missing grants and locked credential reads never start HTTP", arguments: [false, true])
    func unavailableInput(locked: Bool) async throws {
        let h = CredentialTestHarness(), store = h.provider
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("", locked ? "refresh" : nil))
        let called = Mutex(false)
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            called.withLock { $0 = true }
            return try CredentialTestHarness.response(request)
        }
        if locked { h.backend.failNextSharedRead(status: errSecInteractionNotAllowed) }
        await #expect(throws: (any Error).self) { try await auth.refresh() }
        #expect(!called.withLock { $0 })
    }

    @Test("Seeded latency and cancellation preserve replacement and removal finality", arguments: Array(1...24))
    func seededLifecycle(seed: Int) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let auth = NSEAuthSource(accountId: "account", store: store, clientId: "client") { request in
            await started.signal()
            await release.wait()
            for _ in 0..<(seed * 17 % 7) { await Task.yield() }
            if seed % 5 == 0 { throw URLError(.networkConnectionLost) }
            return try CredentialTestHarness.response(request, access: "late", refresh: "late-grant")
        }
        let owner = Task { try await auth.refresh() }
        await started.wait()
        for _ in 0..<(seed * 13 % 11) { await Task.yield() }
        if seed % 2 == 0 { owner.cancel() }
        if seed % 3 == 0 {
            try store.remove(accountId: "account")
        } else {
            try store.install(accountId: "account", tokens: CredentialTestHarness.tokens("replacement", "replacement-grant"))
        }
        await release.signal()
        _ = await owner.result
        let expected = seed % 3 == 0 ? nil : "replacement"
        #expect(store.current(accountId: "account")?.accessToken == expected, "seed \(seed)")
        #expect(store.current(accountId: "account")?.refreshToken == (expected == nil ? nil : "replacement-grant"), "seed \(seed)")
    }

}
