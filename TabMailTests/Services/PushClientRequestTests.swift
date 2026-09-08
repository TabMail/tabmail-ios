/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

final class PushRequestProtocol: URLProtocol, @unchecked Sendable {
    struct Observed: Sendable {
        let path: String
        let authorization: String?
        let body: Data
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [Observed] = []
    nonisolated(unsafe) private static var responseCode = 200
    nonisolated(unsafe) private static var responseData = Data()

    static func reset(code: Int = 200, body: String = #"{"status":"ok","startUrl":"https://auth.example.test/start","outcome":"active"}"#) {
        lock.lock(); defer { lock.unlock() }
        requests = []; responseCode = code; responseData = Data(body.utf8)
    }
    static func observed() -> [Observed] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "push.example.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.lock.lock()
        Self.requests.append(Observed(path: request.url!.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let code = Self.responseCode
        let data = Self.responseData
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Push client wire contracts", .serialized, .processGlobalState)
struct PushClientRequestTests {
    private func client() -> (PushClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushRequestProtocol.self]
        let session = URLSession(configuration: config)
        return (PushClient(baseURL: URL(string: "https://push.example.test")!, session: session,
            encryptIMAP: { payload, context in
                try IMAPCredCrypto.sealAuthorityPayload(payload, context: context,
                    key: SymmetricKey(data: Data(repeating: 42, count: 32)))
            }), session)
    }

    @Test(arguments: ["gmail", "outlook"])
    func providerRequest(provider: String) async throws {
        PushRequestProtocol.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        try await client.subscribe(provider: provider, userId: "user-a", userEmail: "mail@example.test",
            deviceId: "device-a", deviceToken: "token-new", apnsSandbox: false, nseCapable: true,
            accessToken: "synthetic-provider-token", authToken: "synthetic-worker-token")
        let requests = PushRequestProtocol.observed()
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.path == "/subscribe")
        #expect(sent.authorization == "Bearer synthetic-worker-token")
        let body = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body.count == 9)
        #expect(body["protocolVersion"] as? Int == 2)
        #expect(body["provider"] as? String == provider)
        #expect(body["deviceId"] as? String == "device-a")
        #expect(body["deviceToken"] as? String == "token-new")
        #expect(body["nseCapable"] as? Bool == true)
    }

    @Test(arguments: [200, 202, 429])
    func imapReportsOnlyActive(code: Int) async throws {
        PushRequestProtocol.reset(code: code, body: code == 200 ? #"{"outcome":"active"}"# : #"{"outcome":"in_progress"}"#)
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        var succeeded = false
        do {
            try await client.subscribeIMAP(context: IMAPSubscribeContext(userId: "user-a", deviceId: "device-a",
                accountEmail: "mail@example.test", deviceToken: "token-new", apnsSandbox: false, nseCapable: true),
                host: "imap.example.test", port: 993, username: "synthetic", password: "synthetic-password",
                authToken: "synthetic-worker-token")
            succeeded = true
        } catch { #expect(code != 200) }
        #expect(succeeded == (code == 200))
        let sent = try #require(PushRequestProtocol.observed().first)
        #expect(sent.path == "/subscribe")
        let body = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["protocolVersion"] as? Int == 2)
        #expect(body["deviceId"] as? String == "device-a")
        #expect((body["credsCiphertext"] as? String)?.hasPrefix("v2:") == true)
        #expect(String(decoding: sent.body, as: UTF8.self).contains("synthetic-password") == false)
    }

    @Test func consentAndRemovalCarryInstallation() async throws {
        PushRequestProtocol.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        try await PushCleanupIdentity.$pinnedAuthToken.withValue("synthetic-worker-token") {
            _ = try await client.initGmailConsentWeb(userEmail: "mail@example.test", deviceId: "device-a", iosRedirect: "tabmail://consent")
            _ = try await client.getGmailConsentStatus(userEmail: "mail@example.test", deviceId: "device-a")
            try await client.deleteGmailConsent(userEmail: "mail@example.test", deviceId: "device-a")
            _ = try await client.initOutlookConsentWeb(userEmail: "mail@example.test", deviceId: "device-a", iosRedirect: "tabmail://consent")
            _ = try await client.getOutlookConsentStatus(userEmail: "mail@example.test", deviceId: "device-a")
            try await client.deleteOutlookConsent(userEmail: "mail@example.test", deviceId: "device-a")
            try await client.unsubscribeIMAP(userEmail: "mail@example.test", deviceId: "device-a")
            try await client.unsubscribe(provider: "gmail", userEmail: "mail@example.test", deviceId: "device-a", accessToken: "")
        }
        let requests = PushRequestProtocol.observed()
        #expect(requests.map(\.path) == ["/push-consent/gmail/init", "/push-consent/gmail/status", "/push-consent/gmail/revoke",
            "/push-consent/outlook/init", "/push-consent/outlook/status", "/push-consent/outlook/revoke", "/unsubscribe-imap", "/unsubscribe"])
        for sent in requests {
            let body = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
            #expect(body["deviceId"] as? String == "device-a")
            #expect(body["userEmail"] as? String == "mail@example.test")
            #expect(sent.authorization == "Bearer synthetic-worker-token")
        }
    }
}
