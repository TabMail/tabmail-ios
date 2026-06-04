/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import UserNotifications
@testable import TabMail

/// Unit tests for `PushNotificationService.visualAlertsEnabled()` — the
/// visible-vs-silent decision (PLAN_NSE_ENHANCE §3.1/§3.2). A VISUAL surface
/// (Lock Screen / Notification Center / Banner) must be enabled AND
/// authorization must be granted (or provisional). Sound/Badge do NOT count.
///
/// `subscribeAccount` reads this live, and the foreground re-subscribe
/// (`SyncScheduler.startForegroundPolling` → `subscribeAllAccounts`) re-registers
/// with the current value after any settings change (settings can only change
/// while the app is backgrounded), so no separate reconcile/state is needed.
///
/// Injects a mock `NotificationSettingsProviding` via the DEBUG-only
/// `_setNotificationSettingsProviderForTesting` seam so no real
/// `UNUserNotificationCenter` is touched. `.serialized` because it mutates the
/// process-global shared service.
@Suite("PushVisibility", .serialized)
struct PushVisibilityTests {

    // MARK: - Mock

    /// Returns a fixed settings snapshot. The visible-vs-silent logic lives in
    /// `visualAlertsEnabled()`, so the mock only needs to supply the raw read.
    final class MockSettingsProvider: NotificationSettingsProviding, @unchecked Sendable {
        let snapshot: NotificationVisibilitySnapshot
        init(_ snapshot: NotificationVisibilitySnapshot) { self.snapshot = snapshot }
        func currentVisibility() async -> NotificationVisibilitySnapshot { snapshot }
    }

    private static func snapshot(
        _ auth: UNAuthorizationStatus,
        alert: UNNotificationSetting = .disabled,
        lock: UNNotificationSetting = .disabled,
        center: UNNotificationSetting = .disabled
    ) -> NotificationVisibilitySnapshot {
        NotificationVisibilitySnapshot(
            authorizationStatus: auth,
            alertSetting: alert,
            lockScreenSetting: lock,
            notificationCenterSetting: center
        )
    }

    /// Installs the settings mock, runs `body`, clears the override (even on throw).
    private func withProvider(
        _ snapshot: NotificationVisibilitySnapshot,
        _ body: () async throws -> Void
    ) async throws {
        await PushNotificationService.shared._setNotificationSettingsProviderForTesting(MockSettingsProvider(snapshot))
        do {
            try await body()
        } catch {
            await PushNotificationService.shared._setNotificationSettingsProviderForTesting(nil)
            throw error
        }
        await PushNotificationService.shared._setNotificationSettingsProviderForTesting(nil)
    }

    // MARK: - Tests

    @Test("authorized + Banner enabled → true")
    func authorizedWithBanner() async throws {
        try await withProvider(Self.snapshot(.authorized, alert: .enabled)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == true)
        }
    }

    @Test("authorized + only Lock Screen → true")
    func lockScreenOnly() async throws {
        try await withProvider(Self.snapshot(.authorized, lock: .enabled)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == true)
        }
    }

    @Test("authorized but no visual surface (sound/badge only) → false")
    func authorizedNoVisual() async throws {
        try await withProvider(Self.snapshot(.authorized)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == false)
        }
    }

    @Test("denied → false even with every surface enabled")
    func deniedFalse() async throws {
        try await withProvider(Self.snapshot(.denied, alert: .enabled, lock: .enabled, center: .enabled)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == false)
        }
    }

    @Test("notDetermined → false")
    func notDeterminedFalse() async throws {
        try await withProvider(Self.snapshot(.notDetermined, alert: .enabled)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == false)
        }
    }

    @Test("provisional + Notification Center → true (delivers to a visual surface)")
    func provisionalCenter() async throws {
        try await withProvider(Self.snapshot(.provisional, center: .enabled)) {
            #expect(await PushNotificationService.shared.visualAlertsEnabled() == true)
        }
    }
}
