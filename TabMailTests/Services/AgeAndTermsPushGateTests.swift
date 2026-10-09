/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Age and terms screen (owner 2026-10-08). INVARIANT: an account that has not
/// passed the age and terms screen sets up NO push state — no device
/// registration, no per-account dispatch record, no mailbox subscription. The
/// push worker refuses it anyway (`consent_required`); the app must not try.
/// The same scaffolding with the screen passed subscribes, so the refusal is
/// not vacuous. Both cases are driven through the app's real flag
/// (`AgeAndTermsConsent.completedKey`), not a test override.
@Suite("Push setup waits for the age and terms screen", .serialized, .processGlobalState)
@MainActor
struct AgeAndTermsPushGateTests {
    private final class VisibleSettings: NotificationSettingsProviding, @unchecked Sendable {
        func currentVisibility() async -> NotificationVisibilitySnapshot {
            NotificationVisibilitySnapshot(authorizationStatus: .authorized, alertSetting: .enabled,
                lockScreenSetting: .enabled, notificationCenterSetting: .enabled)
        }
    }

    @Test(arguments: [false, true])
    func pushSetupNeedsTheScreenPassed(passed: Bool) async throws {
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
        let standard = UserDefaults.standard
        let keys = [PushConfig.lastDeviceTokenKey, PushConfig.deviceIdKey, PushConfig.pushNotificationsEnabledKey,
                    AgeAndTermsConsent.completedKey]
        let previous = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
            }
        }
        standard.set("apns-device-token", forKey: PushConfig.lastDeviceTokenKey)
        standard.set("test-device", forKey: PushConfig.deviceIdKey)
        standard.set(true, forKey: PushConfig.pushNotificationsEnabledKey)
        standard.set(passed, forKey: AgeAndTermsConsent.completedKey)

        let account: Account = {
            var account = Account(emailAddress: "mail@example.test", displayName: "Synthetic", provider: .gmail)
            account.id = UUID().uuidString
            return account
        }()
        try await pool.write { db in try account.insert(db) }

        PushRequestProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = PushClient(baseURL: URL(string: "https://push.example.test")!, session: session,
            authTokenProvider: { "synthetic-worker-token" })
        let service = PushNotificationService(pushClient: client, subscriptionAccessToken: { _ in "synthetic-provider-token" })
        await service._setNotificationSettingsProviderForTesting(VisibleSettings())
        await service._setAgeAndTermsConsentForTesting(nil)

        let subscribed = await service.subscribeAccount(account)
        await service.reregisterAllDeviceAccounts()
        if !passed {
            // Returns before any launch-readiness wait when refused.
            await service.registerDeviceWithWorker(force: true)
        }

        let paths = PushRequestProtocol.observed().map(\.path)
        if passed {
            #expect(subscribed, "control: with the screen passed the same account subscribes")
            #expect(paths.contains("/subscribe"))
        } else {
            #expect(!subscribed)
            #expect(paths.isEmpty, "no push setup request before the age and terms screen: \(paths)")
        }
    }
}
