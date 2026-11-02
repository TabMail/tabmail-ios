/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import ObjectiveC
import Synchronization
import Testing
@testable import TabMail

/// Test-only local HTTP interception. A synthetic-origin preflight must pass
/// before a default BackendClient is permitted to build any backend request.
private final class DefaultAccountHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Packet: Sendable {
        let path: String
        let method: String?
        let authorization: String?
        let clientType: String?
        let clientVersion: String?
    }
    static let packets = Mutex<[Packet]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.packets.withLock { $0.append(Packet(path: path, method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            clientType: request.value(forHTTPHeaderField: "X-Client-Type"),
            clientVersion: request.value(forHTTPHeaderField: "X-Client-Version"))) }
        let body: String
        switch path {
        case "/default-account-preflight": body = "local-interception-confirmed"
        case "/whoami": body = "{\"logged_in\":true,\"has_subscription\":true,\"plan_tier\":\"Basic\",\"subscription_provider\":\"apple\"}"
        case "/usage/stats": body = "{\"today\":{\"calls\":17,\"tokens_input\":0,\"tokens_output\":0,\"tokens_total\":0,\"cost_cents\":0},\"daily_stats\":[]}"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

/// The app's shared session can already exist when a test starts. Intercept
/// the public configuration getter for this serialized scope, rather than
/// replacing the production global or adding a shipping transport override.
private final class DefaultAccountProtocolScope {
    private let method: Method
    private let original: IMP

    init() throws {
        let configurationClass: AnyClass = type(of: sharedEphemeralSession.configuration)
        method = try #require(class_getInstanceMethod(configurationClass, NSSelectorFromString("protocolClasses")))
        original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> AnyObject = { _ in
            [DefaultAccountHTTPProtocol.self] as NSArray
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    func close() {
        method_setImplementation(method, original)
        // Keep the tiny finite block implementations for this test process so
        // an already-entered getter can finish safely after restoration.
    }
}

@Suite("Default account HTTP routing", .serialized, .processGlobalState)
@MainActor
struct BackendClientDefaultAccountTests {
    @Test(.timeLimit(.minutes(1)))
    func defaultAccountReadUsesTheSharedTransportAndIdentity() async throws {
        try await verifyDefaultRead(account: true)
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultUsageReadUsesTheSharedTransportAndIdentity() async throws {
        try await verifyDefaultRead(account: false)
    }

    private func verifyDefaultRead(account readsAccount: Bool) async throws {
        try await exerciseDefaultRead(account: readsAccount)
        try #require(!TabMailAuthService.hasSession())
        #expect(sharedEphemeralSession.configuration.protocolClasses?.contains { $0 == DefaultAccountHTTPProtocol.self } != true)
        // A bounded credential-free request to a reserved test origin proves
        // the temporary protocol is no longer selected after scope teardown.
        var request = URLRequest(url: URL(string: "https://example.test/default-account-preflight")!)
        request.timeoutInterval = 2
        _ = try? await sharedEphemeralSession.data(for: request)
        #expect(DefaultAccountHTTPProtocol.packets.withLock { $0.isEmpty })
    }

    private func exerciseDefaultRead(account readsAccount: Bool) async throws {
        try #require(!TabMailAuthService.hasSession())
        try #require(!DemoModeStore.shared.isActive && !DemoModeStore.shared.isTutorialPractice)
        let factory = try DefaultAccountProtocolScope()
        defer { factory.close() }
        DefaultAccountHTTPProtocol.packets.withLock { $0 = [] }
        defer { DefaultAccountHTTPProtocol.packets.withLock { $0 = [] } }
        try #require(URLProtocol.registerClass(DefaultAccountHTTPProtocol.self))
        defer { URLProtocol.unregisterClass(DefaultAccountHTTPProtocol.self) }
        try #require(sharedEphemeralSession.configuration.protocolClasses?.contains { $0 == DefaultAccountHTTPProtocol.self } == true)
        // Verify the exact shared URLSession catches a synthetic URL before a
        // credential exists or any request names a real service origin.
        var preflight = URLRequest(url: URL(string: "https://example.test/default-account-preflight")!)
        preflight.timeoutInterval = 2
        let (local, _) = try await sharedEphemeralSession.data(for: preflight)
        try #require(String(decoding: local, as: UTF8.self) == "local-interception-confirmed")
        try #require(DefaultAccountHTTPProtocol.packets.withLock { $0.map(\.path) } == ["/default-account-preflight"])

        let expires = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let session = Data("{\"access_token\":\"synthetic-default-shared-token\",\"refresh_token\":\"synthetic-default-refresh\",\"expires_at\":\(expires),\"user\":{\"id\":\"11111111-1111-4111-8111-111111111111\",\"email\":\"person@example.test\"}}".utf8)
        _ = try TabMailSessionStore.shared.installNewSession(session)
        defer { _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false) }
        let backend = BackendClient()
        if readsAccount {
            let account = try await backend.fetchAccountInfo()
            #expect(account.loggedIn && account.planTier == "Basic")
        } else {
            let usage = try await backend.fetchUsageStats()
            #expect(usage.today.calls == 17)
        }
        let requests = DefaultAccountHTTPProtocol.packets.withLock { $0 }
        #expect(requests.map(\.path) == ["/default-account-preflight", readsAccount ? "/whoami" : "/usage/stats"])
        for packet in requests.dropFirst() {
            #expect(packet.method == "GET")
            #expect(packet.authorization == "Bearer synthetic-default-shared-token")
            #expect(packet.clientType == "ios")
            #expect(packet.clientVersion == BackendClient.clientVersion)
        }
    }
}
