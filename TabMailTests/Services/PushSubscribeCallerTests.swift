/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import GRDB
import Testing
import UserNotifications
@testable import TabMail

private actor SubscriptionAuthGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitOnce() async {
        if entered || released { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@Suite("Foreground subscription continuation", .serialized, .processGlobalState)
@MainActor
struct PushSubscribeCallerTests {
    private final class VisibleSettings: NotificationSettingsProviding, @unchecked Sendable {
        func currentVisibility() async -> NotificationVisibilitySnapshot {
            NotificationVisibilitySnapshot(authorizationStatus: .authorized, alertSetting: .enabled,
                lockScreenSetting: .enabled, notificationCenterSetting: .enabled)
        }
    }

    @Test(arguments: [(AccountProvider.gmail, "rotate"), (.outlook, "remove"),
        (.imap, "rotate"), (.imap, "remove"), (.imap, "token_callback"), (.icloud, "token_callback")])
    func contextChangesDuringAuthentication(provider: AccountProvider, change: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        let appDB = try AppDatabase(dbPool: pool)
        let previousDB = AppDatabase.shared.withLock { current in
            let previous = current; current = appDB; return previous
        }
        defer { AppDatabase.shared.withLock { $0 = previousDB } }
        let previousSession = TabMailSessionStore.shared.loadActiveSession()?.data
        defer {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previousSession { _ = try? TabMailSessionStore.shared.installNewSession(previousSession) }
        }
        let sessionData = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-worker-token", "refresh_token": "synthetic-refresh-token",
            "expires_at": Int(Date().addingTimeInterval(86400).timeIntervalSince1970),
            "user": ["id": "11111111-1111-4111-8111-111111111111", "email": "user@example.test"],
        ])
        _ = try TabMailSessionStore.shared.installNewSession(sessionData)
        let previousDemo = DemoModeStore.shared.isActive
        DemoModeStore.shared.isActive = false
        defer { DemoModeStore.shared.isActive = previousDemo }
        let tokenKey = PushConfig.lastDeviceTokenKey
        let toggleKey = PushConfig.pushNotificationsEnabledKey
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousToggle = UserDefaults.standard.object(forKey: toggleKey)
        UserDefaults.standard.set("token-old", forKey: tokenKey)
        UserDefaults.standard.set(true, forKey: toggleKey)
        defer {
            if let previousToken { UserDefaults.standard.set(previousToken, forKey: tokenKey) }
            else { UserDefaults.standard.removeObject(forKey: tokenKey) }
            if let previousToggle { UserDefaults.standard.set(previousToggle, forKey: toggleKey) }
            else { UserDefaults.standard.removeObject(forKey: toggleKey) }
        }
        let account: Account = {
            var account = Account(emailAddress: "mail@example.test", displayName: "Synthetic", provider: provider)
            account.id = UUID().uuidString
            account.imapHost = "imap.example.test"
            account.imapPort = 993
            return account
        }()
        try await pool.write { db in try account.insert(db) }
        let passwordKey = KeychainHelper.passwordKey(accountId: account.id)
        try KeychainHelper.save("synthetic-password", for: passwordKey)
        defer { KeychainHelper.delete(key: passwordKey) }

        PushRequestProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let gate = SubscriptionAuthGate()
        let client = PushClient(baseURL: URL(string: "https://push.example.test")!, session: session,
            encryptIMAP: { payload, context in
                try IMAPCredCrypto.sealAuthorityPayload(payload, context: context,
                    key: SymmetricKey(data: Data(repeating: 42, count: 32)))
            }, authTokenProvider: { await gate.waitOnce(); return "synthetic-worker-token" })
        let service = PushNotificationService(pushClient: client, subscriptionAccessToken: { _ in "synthetic-provider-token" })
        await service._setNotificationSettingsProviderForTesting(VisibleSettings())
        let running = Task {
            if change == "token_callback" {
                await service.reregisterAllDeviceAccounts()
                return true
            }
            return await service.subscribeAccount(account)
        }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        do {
            switch change {
            case "rotate":
                UserDefaults.standard.set("token-new", forKey: tokenKey)
                try await client.registerDevice(deviceToken: "token-new", deviceId: "test-device",
                    userId: "11111111-1111-4111-8111-111111111111", accountEmails: [account.emailAddress], apnsSandbox: false)
            case "remove":
                try await client.unregisterDeviceAccount(deviceId: "test-device", accountEmail: account.emailAddress)
                _ = try await pool.write { db in try Account.deleteOne(db, key: account.id) }
            case "token_callback":
                break
            default:
                Issue.record("Unexpected regression case")
            }
        } catch {
            await gate.release(); _ = await running.value; throw error
        }
        await gate.release()
        let succeeded = await running.value
        let requests = PushRequestProtocol.observed()
        let subscriptions = requests.filter { $0.path == "/subscribe" }
        let shouldSubscribe = change != "remove"
        #expect(succeeded == shouldSubscribe)
        #expect(subscriptions.count == (shouldSubscribe ? 1 : 0))
        if let sent = subscriptions.first {
            let body = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
            #expect(body["deviceToken"] as? String == (change == "rotate" ? "token-new" : "token-old"))
            #expect(body["nseCapable"] as? Bool == true)
        }
        if change == "rotate" { #expect(requests.first?.path == "/register-device") }
        if change == "remove" { #expect(requests.map(\.path) == ["/register-account-device"]) }
        if change == "token_callback" { #expect(requests.map(\.path) == ["/subscribe"]) }
    }
}
