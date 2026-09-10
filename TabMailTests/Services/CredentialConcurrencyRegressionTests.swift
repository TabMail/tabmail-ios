/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

@Suite("Credential concurrency regressions")
struct CredentialConcurrencyRegressionTests {
    @Test("A late 401 uses a peer's persisted credential while OAuth is unavailable",
          arguments: ["gmail", "outlook"], ["ordinary", "allowing404", "preserving400"])
    func late401Peer(provider: String, method: String) async throws {
        let h = CredentialTestHarness(), store = h.provider
        let active = try store.install(accountId: "account", tokens: .init(
            accessToken: "synthetic-before", refreshToken: "synthetic-grant-before",
            expiresAt: Date().addingTimeInterval(3600)))
        let oauthCalls = Mutex(0), headers = Mutex<[String]>([])
        let auth = NSEAuthSource(accountId: "account", provider: provider, store: h.provider, clientId: "synthetic-client") { _ in
            oauthCalls.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let expectedBody = Data("{\"synthetic\":\"message-body\"}".utf8)
        let scenario = FakeHTTP.Scenario()
        let received = CredentialTestLatch(), releaseResponse = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal(); scenario.close() }
        scenario.register(path: "/message", method: method == "preserving400" ? "POST" : "GET") { request in
            let bearer = request.header("Authorization") ?? ""
            let index = headers.withLock { $0.append(bearer); return $0.count }
            if index == 1 {
                Task { await received.signal() }
                return .parked {
                    guard releaseResponse.wait(timeout: .now() + 10) == .success else { return .transportError(.timedOut) }
                    return .status(401)
                }
            }
            return bearer == "Bearer synthetic-peer" ? .bytes(expectedBody) : .status(401)
        }
        let http = AuthedHTTP(auth: auth, retry: .graph, session: scenario.session)
        let request = Task { () async throws -> Data in
            let url = "https://mail.example.test/message"
            switch method {
            case "allowing404":
                let response = try await http.requestAllowing404(url: url)
                return try #require(response.data)
            case "preserving400": return try await http.requestPreservingBadRequestBody(url: url, method: "POST", body: Data())
            default: return try await http.get(url)
            }
        }
        defer { request.cancel() }
        await received.wait()
        // The foreground store finishes before the old mail request returns
        // its 401. The retained NSE accessor must reuse that durable result.
        _ = try await store.refresh(accountId: "account", generation: active.generation) { consumed in
            #expect(consumed == "synthetic-grant-before")
            return .init(accessToken: "synthetic-peer", refreshToken: "synthetic-grant-peer",
                         expiresAt: Date().addingTimeInterval(3600))
        }
        releaseResponse.signal()
        var delivered: Data?
        do { delivered = try await request.value }
        catch { Issue.record("A persisted peer credential did not complete the mail request: \(error)") }
        #expect(delivered == expectedBody)
        #expect(headers.withLock { $0 } == ["Bearer synthetic-before", "Bearer synthetic-peer"])
        #expect(oauthCalls.withLock { $0 } == 0)
        #expect(store.current(accountId: "account")?.accessToken == "synthetic-peer")
        #expect(store.current(accountId: "account")?.refreshToken == "synthetic-grant-peer")
    }

    @Test("Overlapping storage commits fail closed and preserve the next usable grant")
    func simultaneousStorageCommit() async throws {
        let h = CredentialTestHarness(), store = h.provider
        let active = try store.install(accountId: "account", tokens: CredentialTestHarness.tokens())
        let storageRead = CredentialTestLatch(), release = DispatchSemaphore(value: 0)
        let pauseNextRead = Mutex(false), exchanges = Mutex<[String]>([])
        h.backend.observeReads { account in
            guard account.hasPrefix(ProviderCredentialStore.lineagePrefix) else { return }
            let pause = pauseNextRead.withLock { state -> Bool in
                if !state { return false }; state = false; return true
            }
            if pause {
                Task { await storageRead.signal() }
                if release.wait(timeout: .now() + 10) == .timedOut {
                    Issue.record("Did not release the paused storage transaction")
                }
            }
        }
        defer { release.signal(); h.backend.observeReads(nil) }
        let first = Task {
            try await store.refresh(accountId: "account", generation: active.generation) { consumed in
                #expect(consumed == "refresh-1")
                exchanges.withLock { $0.append("first") }
                pauseNextRead.withLock { $0 = true }
                return CredentialTestHarness.tokens("synthetic-first", "synthetic-first-grant")
            }
        }
        await storageRead.wait()
        var competing: ProviderCredentialStore.Tokens?
        do {
            competing = try await h.provider.refresh(accountId: "account", generation: active.generation) { consumed in
                #expect(consumed == "refresh-1")
                exchanges.withLock { $0.append("competing") }
                return CredentialTestHarness.tokens("synthetic-competing", "synthetic-competing-grant")
            }
        } catch {}
        let expectedAccess: String, expectedGrant: String
        if let competing {
            #expect(competing.accessToken == "synthetic-competing")
            // If an implementation permits this competing commit, an additional
            // successful refresh makes its durable successor authoritative.
            let advanced = try await h.provider.refresh(accountId: "account", generation: active.generation) { consumed in
                #expect(consumed == "synthetic-competing-grant")
                return CredentialTestHarness.tokens("synthetic-advanced", "synthetic-advanced-grant")
            }
            #expect(advanced.accessToken == "synthetic-advanced")
            expectedAccess = "synthetic-advanced"; expectedGrant = "synthetic-advanced-grant"
        } else {
            // Bounded refusal is also valid, provided the retained pair survives.
            #expect(store.current(accountId: "account")?.accessToken == "expired")
            #expect(store.current(accountId: "account")?.refreshToken == "refresh-1")
            expectedAccess = "synthetic-first"; expectedGrant = "synthetic-first-grant"
        }
        release.signal()
        #expect(try await first.value.accessToken == expectedAccess)
        #expect(store.current(accountId: "account")?.accessToken == expectedAccess)
        #expect(store.current(accountId: "account")?.refreshToken == expectedGrant)
        #expect(exchanges.withLock { $0 } == ["first", "competing"])
        let next = try await h.provider.refresh(accountId: "account", generation: active.generation) { consumed in
            #expect(consumed == expectedGrant)
            return CredentialTestHarness.tokens("synthetic-next", "synthetic-next-grant")
        }
        #expect(next.accessToken == "synthetic-next")
        #expect(store.current(accountId: "account")?.refreshToken == "synthetic-next-grant")
    }
}
