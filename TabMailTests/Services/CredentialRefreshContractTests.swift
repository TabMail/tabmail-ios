/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

@Suite("Credential refresh contract regressions")
struct CredentialRefreshContractTests {
    @Test("A provider refresh sends its grant only to the matching token origin and completes durable recovery", arguments: ["gmail", "outlook"])
    func providerRequest(provider: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let before = CredentialTestHarness.tokens("synthetic-expired", "synthetic-grant")
        try store.install(accountId: "synthetic-contract-account", tokens: before)
        let requests = Mutex(0)
        let auth = NSEAuthSource(accountId: "synthetic-contract-account", provider: provider,
                                 store: store, clientId: "synthetic-client") { request in
            requests.withLock { $0 += 1 }
            let expectedURL = provider == "gmail" ? "https://oauth2.googleapis.com/token" :
                "https://login.microsoftonline.com/common/oauth2/v2.0/token"
            #expect(request.url?.absoluteString == expectedURL)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let data = try #require(request.httpBody)
            let text = try #require(String(data: data, encoding: .utf8))
            var fields: [String:String] = [:]
            for field in text.split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                try #require(pair.count == 2)
                let key = try #require(String(pair[0]).removingPercentEncoding)
                let value = try #require(String(pair[1]).removingPercentEncoding)
                try #require(fields.updateValue(value, forKey: key) == nil)
            }
            #expect(fields["grant_type"] == "refresh_token")
            #expect(fields["refresh_token"] == "synthetic-grant")
            #expect(fields["client_id"] == "synthetic-client")
            if provider == "outlook" {
                let scopes = Set((fields["scope"] ?? "").split(separator: " ").map(String.init))
                #expect(scopes.contains("Mail.ReadWrite"))
                #expect(scopes.contains("Mail.Send"))
                #expect(scopes.contains("Calendars.ReadWrite"))
                #expect(scopes.contains("offline_access"))
                #expect(scopes.contains("User.Read"))
            }
            return try CredentialTestHarness.response(request, access: "synthetic-recovered", refresh: "synthetic-rotated")
        }
        #expect(try await auth.refresh() == "synthetic-recovered")
        #expect(await auth.current() == "synthetic-recovered")
        #expect(store.current(accountId: "synthetic-contract-account")?.accessToken == "synthetic-recovered")
        #expect(store.current(accountId: "synthetic-contract-account")?.refreshToken == "synthetic-rotated")
        #expect(requests.withLock { $0 } == 1)
    }

    @MainActor
    @Test("Session recovery authenticates the refresh endpoint and durably returns the same subject")
    func sessionRequest() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        try store.installNewSession(CredentialTestHarness.sessionData())
        let requests = Mutex(0)
        let result = await NSETokenManager.validSession(sessionStore: store) { request in
            requests.withLock { $0 += 1 }
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "auth.tabmail.ai")
            #expect(request.url?.path == "/auth/v1/token")
            #expect(request.url?.query == "grant_type=refresh_token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let publicKey = try #require(request.value(forHTTPHeaderField: "apikey"))
            #expect(publicKey.hasPrefix("sb_publishable_"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(publicKey)")
            let body = try #require(request.httpBody)
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
            #expect(payload?["refresh_token"] == "refresh-1")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (try CredentialTestHarness.sessionData(access: "synthetic-session", refresh: "synthetic-rotation", expired: false), response)
        }
        #expect(result?.session.accessToken == "synthetic-session")
        #expect(result?.persisted == true)
        let stored = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(stored.accessToken == "synthetic-session")
        #expect(stored.refreshToken == "synthetic-rotation")
        #expect(requests.withLock { $0 } == 1)
    }

    @Test("An already-bound notification cannot adopt a replacement login before its first await")
    func capturedProviderBinding() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let account = "synthetic-bound-account"
        let old = try store.install(accountId: account, tokens: CredentialTestHarness.tokens("old", "old-grant"))
        let latest = try store.install(accountId: account, tokens: CredentialTestHarness.tokens("latest", "latest-grant"))
        let requests = Mutex(0)
        let transport: NSEAuthSource.Transport = { request in
            requests.withLock { $0 += 1 }
            return try CredentialTestHarness.response(request, access: "latest-refreshed", refresh: "latest-rotated")
        }
        let oldAuth = NSEAuthSource.$binding.withValue(.init(accountId: account, generation: old.generation)) {
            NSEAuthSource(accountId: account, provider: "outlook", store: store, clientId: "synthetic-client", dataForRequest: transport)
        }
        #expect(await oldAuth.current() == nil)
        await #expect(throws: (any Error).self) { try await oldAuth.refresh() }
        #expect(requests.withLock { $0 } == 0)
        #expect(store.current(accountId: account)?.accessToken == "latest")
        #expect(store.current(accountId: account)?.refreshToken == "latest-grant")
        let currentAuth = NSEAuthSource.$binding.withValue(.init(accountId: account, generation: latest.generation)) {
            NSEAuthSource(accountId: account, provider: "outlook", store: store, clientId: "synthetic-client", dataForRequest: transport)
        }
        #expect(try await currentAuth.refresh() == "latest-refreshed")
        #expect(requests.withLock { $0 } == 1)
        #expect(store.current(accountId: account)?.refreshToken == "latest-rotated")
    }
    @MainActor
    @Test("Sign-out between the protected commit read and update must not leave a recreated secret")
    func deletionDuringCommit() async throws {
        let h = CredentialTestHarness(), store = h.sessions
        let before = try store.installNewSession(CredentialTestHarness.sessionData())
        let key = TabMailSessionStore.generationPrefix + (try #require(before.generation))
        let armed = Mutex(false), exchanges = Mutex(0)
        let commitRead = CredentialTestLatch()
        let releaseCommit = DispatchSemaphore(value: 0)
        h.backend.observeReads { readKey in
            guard readKey == key else { return }
            let pause = armed.withLock { value in
                let was = value; value = false; return was
            }
            guard pause else { return }
            Task { await commitRead.signal() }
            if releaseCommit.wait(timeout: .now() + 10) == .timedOut {
                Issue.record("Main-actor sign-out did not release the paused commit")
            }
        }
        defer { releaseCommit.signal(); h.backend.observeReads(nil) }
        let refresh = Task.detached {
            try await store.refreshCapturedSession(before) { _ in
                exchanges.withLock { $0 += 1 }
                armed.withLock { $0 = true }
                return try CredentialTestHarness.sessionData(access: "synthetic-late", refresh: "synthetic-late-secret", expired: false)
            }
        }
        await commitRead.wait()
        // The actual lifecycle writer runs on MainActor while the independent
        // refresh holds the stripe and has already captured its commit-read bytes.
        try store.deactivate()
        #expect(store.loadActiveSession() == nil)
        #expect(h.backend.sessionNamespaceItems().isEmpty)
        releaseCommit.signal()
        let completion = try await refresh.value
        h.backend.observeReads(nil)
        #expect(exchanges.withLock { $0 } == 1)
        #expect(!completion.persisted)
        #expect(store.loadActiveSession() == nil)
        #expect(h.backend.sessionNamespaceItems().isEmpty)
        let current = try store.installNewSession(CredentialTestHarness.sessionData(access: "new-login", refresh: "new-login-grant"))
        let success = try await store.refreshCapturedSession(current) { _ in
            try CredentialTestHarness.sessionData(access: "new-access", refresh: "new-grant", expired: false)
        }
        #expect(success.persisted)
        let saved = try JSONDecoder().decode(TabMailSession.self, from: #require(store.loadActiveSession()).data)
        #expect(saved.accessToken == "new-access")
        #expect(saved.refreshToken == "new-grant")
    }

    @Test("A provider credential read proves its captured activation throughout the read", arguments: ["before-read", "during-read"])
    func providerReadOwnership(timing: String) throws {
        let h = CredentialTestHarness(), store = h.provider
        let id = "synthetic-read-account"
        let old = try store.install(accountId: id, tokens: CredentialTestHarness.tokens("old-access", "old-grant"))
        let replacement = CredentialTestHarness.tokens("new-access", "new-grant")
        let replaced = Mutex(0)
        if timing == "before-read" {
            try store.install(accountId: id, tokens: replacement)
            replaced.withLock { $0 += 1 }
        } else {
            let key = ProviderCredentialStore.lineagePrefix + id + ":" + old.lineage
            h.backend.observeReads { readKey in
                guard readKey == key else { return }
                h.backend.observeReads(nil)
                do {
                    try store.install(accountId: id, tokens: replacement)
                    replaced.withLock { $0 += 1 }
                } catch { Issue.record("Replacement writer failed to reach the intended state") }
            }
        }
        #expect(store.current(accountId: id, generation: old.generation) == nil)
        h.backend.observeReads(nil)
        #expect(replaced.withLock { $0 } == 1)
        let active = try #require(store.activation(accountId: id))
        #expect(active.generation != old.generation)
        #expect(store.current(accountId: id, generation: active.generation) == replacement)
    }

    @Test("Foreground malformed access credentials preserve the last usable pair and its next retry")
    func foregroundEmptyAccess() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let before = CredentialTestHarness.tokens("old-access", "old-grant")
        try store.install(accountId: "synthetic-malformed-account", tokens: before)
        let coordinator = OAuthRefreshCoordinator(store: store)
        let calls = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await coordinator.refresh(accountId: "synthetic-malformed-account", email: "user@example.com") { refresh in
                calls.withLock { $0 += 1 }
                #expect(refresh == "old-grant")
                return OAuthTokens(accessToken: "", refreshToken: "malformed-response-grant", expiresAt: Date().addingTimeInterval(3600), idToken: nil)
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(store.current(accountId: "synthetic-malformed-account") == before)
        let recovered = try await coordinator.refresh(accountId: "synthetic-malformed-account", email: "user@example.com") { refresh in
            #expect(refresh == "old-grant")
            return OAuthTokens(accessToken: "recovered", refreshToken: "recovered-grant", expiresAt: Date().addingTimeInterval(3600), idToken: nil)
        }
        #expect(recovered == "recovered")
        #expect(store.current(accountId: "synthetic-malformed-account")?.accessToken == "recovered")
        #expect(store.current(accountId: "synthetic-malformed-account")?.refreshToken == "recovered-grant")
    }

}
