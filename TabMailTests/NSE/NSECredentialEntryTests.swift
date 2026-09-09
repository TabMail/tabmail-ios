/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
import UserNotifications
@testable import TabMail

@Suite("NSE credential recovery through didReceive", .serialized)
struct NSECredentialEntryTests {
    @MainActor
    @Test("An authorized message lookup uses the refreshed shared grant", arguments: ["gmail", "outlook"], ["expired", "missing-access", "valid", "rejected-access"])
    func providerEntry(provider: String, state: String) async throws {
        let accountId = "nse-entry-" + UUID().uuidString
        let suiteName = "nse-entry." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ProviderCredentialStore.shared
        let h = CredentialTestHarness()
        let http = FakeHTTP.Scenario()
        defer {
            http.close()
            try? store.remove(accountId: accountId)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let access = state == "missing-access" ? "" : "synthetic-access-before"
        try store.install(accountId: accountId, tokens: .init(accessToken: access,
            refreshToken: "synthetic-refresh-before", expiresAt: Date().addingTimeInterval(
                state == "valid" || state == "rejected-access" ? 3600 : -120)))
        defaults.set("{\"user@example.com\":\"\(accountId)\"}", forKey: SharedNSEData.accountMapKey)
        defaults.set("synthetic-client", forKey: "nse.googleClientId")
        defaults.set("synthetic-client", forKey: "nse.microsoftClientId")
        let headers = Mutex<[String]>([]), refreshes = Mutex(0), deliveries = Mutex(0)
        http.register(path: "/") { request in
            let bearer = request.header("Authorization") ?? "missing"
            headers.withLock { $0.append(bearer) }
            if state == "rejected-access" && bearer == "Bearer synthetic-access-before" { return .status(401) }
            // A message removed before delivery is a real terminal lookup result.
            // The provider accepts the bearer; this fixture avoids unrelated AI.
            let expected = state == "valid" ? "Bearer synthetic-access-before" : "Bearer synthetic-access-after"
            #expect(bearer == expected)
            return .status(404)
        }
        let transport: NSEAuthSource.Transport = { request in
            refreshes.withLock { $0 += 1 }
            return try CredentialTestHarness.response(request, access: "synthetic-access-after", refresh: "synthetic-refresh-after")
        }
        let delivered = CredentialTestLatch()
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.title = "New Email"
        content.userInfo = ["provider": provider, "accountEmail": "user@example.com", "messageId": "synthetic-message"]
        await SharedNSEData.$suiteOverride.withValue(.init(defaults: defaults)) {
            await NSETokenManager.$storeOverride.withValue(h.sessions) {
                await AuthedHTTP.$sessionOverride.withValue(http.session) {
                    await NSEAuthSource.$transport.withValue(transport) {
                        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { @Sendable result in
                            deliveries.withLock { $0 += 1 }
                            #expect(!result.title.contains("synthetic-access"))
                            #expect(!result.body.contains("synthetic-refresh"))
                            Task { await delivered.signal() }
                        }
                        await delivered.wait()
                    }
                }
            }
        }
        service.serviceExtensionTimeWillExpire()
        #expect(deliveries.withLock { $0 } == 1)
        #expect(refreshes.withLock { $0 } == (state == "valid" ? 0 : 1))
        let expected = state == "valid" ? ["Bearer synthetic-access-before"] :
            state == "rejected-access" ? ["Bearer synthetic-access-before", "Bearer synthetic-access-after"] :
            ["Bearer synthetic-access-after"]
        #expect(headers.withLock { $0 } == expected)
        #expect(store.current(accountId: accountId)?.refreshToken ==
            (state == "valid" ? "synthetic-refresh-before" : "synthetic-refresh-after"))
    }

    @MainActor
    @Test("Expiry cancels the root task and cannot start a lookup after a late refresh")
    func expiryDuringRefresh() async throws {
        let accountId = "nse-expiry-" + UUID().uuidString
        let suiteName = "nse-expiry." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ProviderCredentialStore.shared
        let http = FakeHTTP.Scenario(), h = CredentialTestHarness()
        defer {
            http.close(); try? store.remove(accountId: accountId)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        defaults.set("{\"user@example.com\":\"\(accountId)\"}", forKey: SharedNSEData.accountMapKey)
        defaults.set("client", forKey: "nse.googleClientId")
        let started = CredentialTestLatch(), release = CredentialTestLatch(), returned = CredentialTestLatch()
        let deliveries = Mutex(0)
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.title = "New Email"
        content.userInfo = ["provider": "gmail", "accountEmail": "user@example.com", "messageId": "synthetic-message"]
        await SharedNSEData.$suiteOverride.withValue(.init(defaults: defaults)) {
            await NSETokenManager.$storeOverride.withValue(h.sessions) {
                await AuthedHTTP.$sessionOverride.withValue(http.session) {
                    await NSEAuthSource.$transport.withValue({ request in
                        await started.signal(); await release.wait()
                        defer { Task { await returned.signal() } }
                        return try CredentialTestHarness.response(request)
                    }) {
                        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { @Sendable _ in
                            deliveries.withLock { $0 += 1 }
                        }
                        await started.wait()
                        service.serviceExtensionTimeWillExpire()
                        await release.signal()
                        await returned.wait()
                        // Wait for the received rotation to become durable; the
                        // callback cannot signal processing completion itself.
                        for _ in 0..<200 where store.current(accountId: accountId)?.refreshToken != "refresh-2" {
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
            }
        }
        #expect(deliveries.withLock { $0 } == 1)
        #expect(http.recordedCalls().isEmpty)
        #expect(store.current(accountId: accountId)?.refreshToken == "refresh-2")
    }

    enum ReconnectScenario: String, CaseIterable, Sendable {
        case active, iCloudActive, inProgress, refused, missingPassword, accountRemoved, passwordChanged, signedOut, expiredDuringRefresh
    }

    @MainActor
    @Test("IMAP/iCloud reconnect requires active identity and confirmed subscription", arguments: ReconnectScenario.allCases, [false, true])
    func imapReconnect(scenario: ReconnectScenario, final: Bool) async throws {
        let status = scenario == .inProgress ? 202 : scenario == .refused ? 401 : 200
        let h = CredentialTestHarness()
        let sessionStore = h.sessions
        try sessionStore.installNewSession(CredentialTestHarness.sessionData())
        let accountId = "imap-entry-" + UUID().uuidString
        let suiteName = "imap-entry." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        if scenario != .missingPassword {
            try KeychainHelper.save("synthetic-app-password", for: KeychainHelper.passwordKey(accountId: accountId))
        }
        defer {
            KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: accountId))
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaults.set("{\"user@example.com\":\"\(accountId)\"}", forKey: SharedNSEData.accountMapKey)
        let config: [String: Any] = [accountId: ["host": scenario == .iCloudActive ? "imap.mail.me.com" : "imap.example.com", "port": 993, "username": "user@example.com", "useTLS": true]]
        defaults.set(String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8), forKey: SharedNSEData.imapAccountsKey)
        defaults.set(true, forKey: SharedNSEData.imapPushEnabledKey)
        defaults.set(true, forKey: "nse.reconnectEnabled")
        defaults.set("synthetic-device", forKey: "nse.deviceId")
        defaults.set("synthetic-apns", forKey: "nse.deviceToken")
        defaults.set(true, forKey: "nse.apnsSandbox")
        defaults.set("https://push.example.com", forKey: SharedNSEData.pushWorkerURLKey)
        let refreshes = Mutex(0), subscriptions = Mutex(0), restored = Mutex(false), deliveries = Mutex(0)
        let delivered = CredentialTestLatch(), refreshStarted = CredentialTestLatch(), releaseRefresh = CredentialTestLatch()
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.title = "TabMail"; content.body = "Reconnecting"
        content.userInfo = ["provider": "imap_reconnect", "accountEmail": "user@example.com", "final": final]
        await SharedNSEData.$suiteOverride.withValue(.init(defaults: defaults)) {
            await NSETokenManager.$storeOverride.withValue(sessionStore) {
                await NSETokenManager.$transport.withValue({ request in
                    refreshes.withLock { $0 += 1 }
                    if scenario == .expiredDuringRefresh {
                        await refreshStarted.signal(); await releaseRefresh.wait()
                    }
                    if scenario == .accountRemoved { SharedNSEData.suite.set("{}", forKey: SharedNSEData.accountMapKey) }
                    return (try CredentialTestHarness.sessionData(access: "fresh-session", refresh: "rotated-session", expired: false),
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }) {
                    await NotificationService.$visualCapability.withValue({ true }) {
                        await NotificationService.$reconnectTransport.withValue({ request in
                            subscriptions.withLock { $0 += 1 }
                            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-session")
                            #expect(request.url?.path == "/subscribe")
                            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
                            #expect((body?["credsCiphertext"] as? String)?.hasPrefix("v2:") == true)
                            if scenario == .passwordChanged {
                                try KeychainHelper.save("replacement-app-password", for: KeychainHelper.passwordKey(accountId: accountId))
                            }
                            if scenario == .signedOut { try await MainActor.run { try sessionStore.deactivate() } }
                            let outcome = status == 200 ? "active" : status == 202 ? "in_progress" : "refused"
                            return (Data("{\"outcome\":\"\(outcome)\"}".utf8),
                                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                        }) {
                            service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { @Sendable result in
                                deliveries.withLock { $0 += 1 }
                                restored.withLock { $0 = result.userInfo["reconnect_state"] as? String == "ok" }
                                Task { await delivered.signal() }
                            }
                            if scenario == .expiredDuringRefresh && !final {
                                await refreshStarted.wait()
                                service.serviceExtensionTimeWillExpire()
                                await releaseRefresh.signal()
                            }
                            await delivered.wait()
                            if scenario == .expiredDuringRefresh && !final {
                                for _ in 0..<200 {
                                    if let record = sessionStore.loadActiveSession(),
                                       let saved = try? JSONDecoder().decode(TabMailSession.self, from: record.data),
                                       saved.refreshToken == "rotated-session" { break }
                                    try? await Task.sleep(for: .milliseconds(5))
                                }
                            }
                        }
                    }
                }
            }
        }
        service.serviceExtensionTimeWillExpire()
        #expect(deliveries.withLock { $0 } == 1)
        #expect(refreshes.withLock { $0 } == (final || scenario == .missingPassword ? 0 : 1))
        #expect(subscriptions.withLock { $0 } == (final || scenario == .missingPassword || scenario == .accountRemoved || scenario == .expiredDuringRefresh ? 0 : 1))
        #expect(restored.withLock { $0 } == (!final && (scenario == .active || scenario == .iCloudActive)))
        if !final && scenario == .signedOut {
            #expect(sessionStore.loadActiveSession() == nil)
        } else {
            let persisted = try JSONDecoder().decode(TabMailSession.self, from: #require(sessionStore.loadActiveSession()).data)
            #expect(persisted.refreshToken == (final || scenario == .missingPassword ? "refresh-1" : "rotated-session"))
        }
        let expectedPassword = scenario == .missingPassword ? nil :
            (!final && scenario == .passwordChanged ? "replacement-app-password" : "synthetic-app-password")
        #expect(SharedKeychain.getPassword(for: accountId) == expectedPassword)
    }
}
