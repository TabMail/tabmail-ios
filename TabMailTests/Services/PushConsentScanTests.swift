/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Unit tests for `PushNotificationService.checkPushConsentStatusForForeground`.
///
/// Covers the foreground scan that populates the "Fix smart notifications"
/// banner:
///   - Per-account errors do NOT cascade — other accounts are independent.
///   - First scan safety: on the *first* scan since process start, thrown
///     errors do NOT populate the banner (cold-launch timeouts are unknown,
///     not evidence of needs-reconsent).
///   - After first authoritative success: sticky-on-error — thrown errors
///     keep the email in the banner (false-positive over false-negative).
///   - All-throws scan produces no post at all (banner state untouched).
///   - Toggle off → no post at all.
///
/// These tests install a temp file-backed `AppDatabase.shared` and a mock
/// `PushConsentChecking` on the shared `PushNotificationService` actor, then
/// drive the scan and observe `.pushConsentErrorsDetected`. The suite
/// is `.serialized` because it mutates process-global singletons.
@Suite("PushConsentScan", .serialized)
struct PushConsentScanTests {

    // MARK: - Mock

    /// In-memory double for `PushConsentChecking`. Per-email results are
    /// supplied up front; any missing email falls through to `.ok`.
    final class MockConsentChecker: PushConsentChecking, @unchecked Sendable {
        /// Outcome carries both the intended provider (so the test can
        /// distinguish which endpoint should be exercised) and the
        /// canned `PushConsentStatus` result.
        enum Outcome {
            case gmail(Result<PushClient.PushConsentStatus, Error>)
            case outlook(Result<PushClient.PushConsentStatus, Error>)
        }
        var outcomes: [String: Outcome] = [:]

        func getGmailConsentStatus(userEmail: String) async throws -> PushClient.PushConsentStatus {
            guard let o = outcomes[userEmail] else { return .ok }
            guard case .gmail(let r) = o else { return .ok }
            switch r {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }

        func getOutlookConsentStatus(userEmail: String) async throws -> PushClient.PushConsentStatus {
            guard let o = outcomes[userEmail] else { return .ok }
            guard case .outlook(let r) = o else { return .ok }
            switch r {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
    }

    enum MockError: Error { case timeout }

    // MARK: - Harness

    /// Installs a temp file-backed `AppDatabase.shared`, seeds accounts,
    /// wires `mock` onto the shared `PushNotificationService`, sets the NSE
    /// toggle, runs `body`, then tears everything down (even on throw).
    private func withHarness(
        accounts: [(email: String, provider: AccountProvider)],
        mock: MockConsentChecker,
        nseEnabled: Bool = true,
        body: () async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let appDb = try AppDatabase(dbPool: pool)

        let previousDb = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { AppDatabase.shared.withLock { $0 = previousDb } }

        try await pool.write { db in
            for (i, pair) in accounts.enumerated() {
                var acc = Account(emailAddress: pair.email, displayName: "Test\(i)", provider: pair.provider)
                acc.id = "acc\(i)"
                try acc.insert(db)
            }
        }

        let prefsKey = PushConfig.pushNotificationsEnabledKey
        let previousToggle = UserDefaults.standard.object(forKey: prefsKey) as? Bool
        UserDefaults.standard.set(nseEnabled, forKey: prefsKey)
        defer {
            if let p = previousToggle { UserDefaults.standard.set(p, forKey: prefsKey) }
            else { UserDefaults.standard.removeObject(forKey: prefsKey) }
        }

        await PushNotificationService.shared._setConsentCheckerForTesting(mock)
        // Reset first-scan-success flag at the START of each test so
        // behavior is deterministic regardless of prior test order (the
        // service is a process singleton; the suite is .serialized but
        // state leaks otherwise).
        await PushNotificationService.shared._resetConsentScanStateForTesting()
        defer {
            Task {
                await PushNotificationService.shared._setConsentCheckerForTesting(nil)
                await PushNotificationService.shared._resetConsentScanStateForTesting()
            }
        }

        try await body()
    }

    /// Subscribes to `.pushConsentErrorsDetected`, runs `action`, and
    /// returns the most recent `emails` userInfo array (or nil if no post
    /// arrived). Waits up to `timeout` after `action` completes.
    private func observePost(
        timeout: TimeInterval = 1.0,
        action: () async throws -> Void
    ) async throws -> [String]? {
        let box = Mutex<[String]?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .pushConsentErrorsDetected,
            object: nil,
            queue: nil
        ) { note in
            let emails = (note.userInfo?["emails"] as? [String]) ?? []
            box.withLock { $0 = emails }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await action()

        // `checkPushConsentStatusForForeground` hops to MainActor for the
        // post; give the main queue a tick to drain.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let seen = box.withLock({ $0 }) { return seen }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: - Tests

    @Test("All Gmail + Outlook accounts OK → banner is empty (post fires with [])")
    func allOk() async throws {
        let mock = MockConsentChecker()
        try await withHarness(
            accounts: [
                ("a@gmail.com", .gmail),
                ("b@outlook.com", .outlook),
            ],
            mock: mock
        ) {
            let emails = try await observePost {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            #expect(emails == [])
        }
    }

    @Test("Mixed statuses → only error/missing accounts land in banner")
    func mixedStatuses() async throws {
        let mock = MockConsentChecker()
        mock.outcomes = [
            "ok@gmail.com":     .gmail(.success(.ok)),
            "err@gmail.com":    .gmail(.success(.error(reason: "refresh_failed"))),
            "miss@outlook.com": .outlook(.success(.missing)),
            "ok@outlook.com":   .outlook(.success(.ok)),
        ]
        try await withHarness(
            accounts: [
                ("ok@gmail.com", .gmail),
                ("err@gmail.com", .gmail),
                ("miss@outlook.com", .outlook),
                ("ok@outlook.com", .outlook),
            ],
            mock: mock
        ) {
            let emails = try await observePost {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            #expect(emails != nil)
            guard let emails else { return }
            #expect(Set(emails) == Set(["err@gmail.com", "miss@outlook.com"]))
        }
    }

    @Test("After first authoritative success: thrown error keeps that account in banner (no silent drop)")
    func errorThrownKeepsInBanner_afterPriming() async throws {
        let mock = MockConsentChecker()
        mock.outcomes = [
            "flaky@gmail.com":  .gmail(.failure(MockError.timeout)),
            "ok@gmail.com":     .gmail(.success(.ok)),
            "flaky2@outlook.com": .outlook(.failure(MockError.timeout)),
        ]
        try await withHarness(
            accounts: [
                ("flaky@gmail.com", .gmail),
                ("ok@gmail.com", .gmail),
                ("flaky2@outlook.com", .outlook),
            ],
            mock: mock
        ) {
            // Prime: one successful scan establishes hasSucceededOnce=true so
            // sticky-on-error is active for the scan we actually measure.
            // All three accounts return .ok here.
            mock.outcomes = [
                "flaky@gmail.com":    .gmail(.success(.ok)),
                "ok@gmail.com":       .gmail(.success(.ok)),
                "flaky2@outlook.com": .outlook(.success(.ok)),
            ]
            _ = try await observePost {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }

            // Now inject flakiness for the real measurement.
            mock.outcomes = [
                "flaky@gmail.com":    .gmail(.failure(MockError.timeout)),
                "ok@gmail.com":       .gmail(.success(.ok)),
                "flaky2@outlook.com": .outlook(.failure(MockError.timeout)),
            ]
            let emails = try await observePost {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            #expect(emails != nil)
            guard let emails else { return }
            #expect(Set(emails) == Set(["flaky@gmail.com", "flaky2@outlook.com"]))
        }
    }

    @Test("First scan: thrown errors do NOT populate banner (cold-launch safety)")
    func firstScanThrownIsNotError() async throws {
        let mock = MockConsentChecker()
        mock.outcomes = [
            "flaky@gmail.com":    .gmail(.failure(MockError.timeout)),
            "ok@gmail.com":       .gmail(.success(.ok)),
            "flaky2@outlook.com": .outlook(.failure(MockError.timeout)),
        ]
        try await withHarness(
            accounts: [
                ("flaky@gmail.com", .gmail),
                ("ok@gmail.com", .gmail),
                ("flaky2@outlook.com", .outlook),
            ],
            mock: mock
        ) {
            // First scan — flag starts false (harness resets). Even though
            // two accounts throw, the ok@gmail.com probe is authoritative, so
            // a post DOES fire, but the throws are NOT included.
            let emails = try await observePost {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            #expect(emails == [])
        }
    }

    @Test("First scan with all throws → no post at all (banner state untouched)")
    func firstScanAllThrows_noPost() async throws {
        let mock = MockConsentChecker()
        mock.outcomes = [
            "a@gmail.com":   .gmail(.failure(MockError.timeout)),
            "b@outlook.com": .outlook(.failure(MockError.timeout)),
        ]
        try await withHarness(
            accounts: [
                ("a@gmail.com", .gmail),
                ("b@outlook.com", .outlook),
            ],
            mock: mock
        ) {
            let emails = try await observePost(timeout: 0.3) {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            // No authoritative result → service suppresses the post entirely.
            #expect(emails == nil)
        }
    }

    @Test("NSE toggle off → scan returns early, no post emitted")
    func toggleOffNoPost() async throws {
        let mock = MockConsentChecker()
        mock.outcomes = [
            "err@gmail.com": .gmail(.success(.error(reason: "x"))),
        ]
        try await withHarness(
            accounts: [("err@gmail.com", .gmail)],
            mock: mock,
            nseEnabled: false
        ) {
            let emails = try await observePost(timeout: 0.3) {
                await PushNotificationService.shared.checkPushConsentStatusForForeground()
            }
            #expect(emails == nil)  // no notification posted
        }
    }
}
