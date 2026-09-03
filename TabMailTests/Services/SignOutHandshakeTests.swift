/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Ordinary sign-out releases this device's push registration on the worker
/// and ends the auth session server-side — worker first, logout only after a
/// successful release, `scope=local` — inside one bounded window, and clears
/// the local session on every path regardless of how that handshake went.
///
/// Every test here also asserts that the handshake was ATTEMPTED (the journal
/// is non-empty), so each one is red against a sign-out that only clears the
/// Keychain: "the session is gone" alone was already true before the handshake
/// existed and would bless its absence.
@Suite("Sign-out release handshake", .serialized, .processGlobalState)
struct SignOutHandshakeTests {
    enum InjectedFailure: Error { case offline }

    struct CapturedRequest: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
    }

    /// One ordered record shared by the worker mock and the logout transport,
    /// so the ORDER of the two legs is provable rather than inferred.
    final class Journal: Sendable {
        private let entries = Mutex<[String]>([])
        private let requests = Mutex<[CapturedRequest]>([])

        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        func snapshot() -> [String] { entries.withLock { $0 } }

        func capture(_ request: URLRequest) {
            let captured = CapturedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:]
            )
            requests.withLock { $0.append(captured) }
        }
        func logoutRequests() -> [CapturedRequest] { requests.withLock { $0 } }
    }

    /// What the mocked worker does when the release request arrives.
    enum ReleaseBehavior: Sendable {
        case succeed
        /// Throws `PushError.workerRequestFailed` for the status, or a plain
        /// offline error when nil.
        case fail(statusCode: Int?)
        /// Never returns on its own; ends only when the caller cancels it.
        case hang
    }

    /// What the mocked logout transport does.
    enum LogoutBehavior: Sendable {
        case respond(statusCode: Int)
        case fail
        case hang
    }

    /// A leg that never completes on its own. `Task.sleep` is cancellation-
    /// aware, so cancelling the handshake task ends it — exactly the exit the
    /// production code must take at the bound. The cancellation is journaled
    /// from INSIDE the leg together with whether the local session still exists
    /// at that instant: the handler runs synchronously in `cancel()`, so it
    /// observes the Keychain at the moment sign-out chose to give up.
    static func hangUntilCancelled(journal: Journal, leg: String) async throws {
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(PushConfig.signOutHandshakeTimeoutSeconds * 20))
            journal.append("\(leg)-returned")
        } onCancel: {
            journal.append("\(leg)-cancelled:session-present=\(TabMailAuthService.hasSession())")
        }
    }

    actor MockWorker: RemovedAccountPushCleaning {
        private let journal: Journal
        private let behavior: ReleaseBehavior
        private var releasedDeviceIds: [String] = []

        init(journal: Journal, behavior: ReleaseBehavior) {
            self.journal = journal
            self.behavior = behavior
        }

        func recordedReleasedDeviceIds() -> [String] { releasedDeviceIds }

        func unregisterDevice(deviceId: String) async throws {
            journal.append("unregister-device:\(deviceId)")
            releasedDeviceIds.append(deviceId)
            switch behavior {
            case .succeed:
                return
            case .fail(let statusCode):
                if let statusCode {
                    throw PushError.workerRequestFailed(statusCode: statusCode, errorCode: nil)
                }
                throw InjectedFailure.offline
            case .hang:
                try await SignOutHandshakeTests.hangUntilCancelled(journal: journal, leg: "unregister-device")
            }
        }

        // No other worker call belongs to an ordinary sign-out without cleanup debt.
        func unregisterDeviceAccount(deviceId: String, accountEmail: String) async throws {
            journal.append("unexpected:device-account")
            throw InjectedFailure.offline
        }

        func registerDevice(
            deviceToken: String,
            deviceId: String,
            userId: String,
            accountEmails: [String],
            apnsSandbox: Bool
        ) async throws {
            journal.append("unexpected:register-device")
            throw InjectedFailure.offline
        }

        func unsubscribeIMAP(userEmail: String) async throws {
            journal.append("unexpected:imap")
            throw InjectedFailure.offline
        }

        func deleteGmailConsent(userEmail: String) async throws {
            journal.append("unexpected:gmail-consent")
            throw InjectedFailure.offline
        }

        func deleteOutlookConsent(userEmail: String) async throws {
            journal.append("unexpected:outlook-consent")
            throw InjectedFailure.offline
        }

        func unsubscribe(provider: String, userEmail: String, accessToken: String) async throws {
            journal.append("unexpected:provider-subscription")
            throw InjectedFailure.offline
        }
    }

    private let testDeviceId = "signout-test-device"
    private let testUserId = "signout-test-user"
    private let testAccessToken = "signout-test-access"

    private func logoutTransport(
        journal: Journal,
        behavior: LogoutBehavior
    ) -> TabMailTokenCoordinator.DataForRequest {
        { request in
            journal.capture(request)
            journal.append("logout")
            let url = request.url ?? URL(string: "https://example.com")!
            switch behavior {
            case .respond(let statusCode):
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            case .fail:
                throw URLError(.notConnectedToInternet)
            case .hang:
                try await SignOutHandshakeTests.hangUntilCancelled(journal: journal, leg: "logout")
                let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }
    }

    @MainActor
    private func installTestSession() throws {
        // Far enough ahead that `validToken()` answers from the Keychain without
        // a refresh round-trip; relative to now so it never goes stale.
        let expiresAt = Int(Date().addingTimeInterval(365 * 24 * 60 * 60).timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": testAccessToken,
            "refresh_token": "signout-test-refresh",
            "expires_at": expiresAt,
            "user": ["id": testUserId, "email": "session@example.com"],
        ])
        _ = try TabMailSessionStore.shared.installNewSession(data)
    }

    @MainActor
    private func restoreSession(_ data: Data?) throws {
        _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
        if let data {
            _ = try TabMailSessionStore.shared.installNewSession(data)
        }
    }

    /// Installs a signed-in session with no cleanup debt, the mocked worker and
    /// the mocked logout transport, runs `body`, and restores everything.
    private func withHarness(
        release: ReleaseBehavior = .succeed,
        logout: LogoutBehavior = .respond(statusCode: 204),
        body: (Journal, MockWorker) async throws -> Void
    ) async throws {
        let suiteName = "SignOutHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(testDeviceId, forKey: PushConfig.deviceIdKey)
        let previousSession = TabMailSessionStore.shared.loadActiveSession()?.data
        try await installTestSession()

        let journal = Journal()
        let worker = MockWorker(journal: journal, behavior: release)
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: worker,
            defaults: SendableRemovedAccountCleanupDefaults(value: defaults)
        )
        await TabMailAuthService._setSignOutLogoutTransportForTesting(
            logoutTransport(journal: journal, behavior: logout)
        )

        let outcome: Result<Void, any Error>
        do {
            try await body(journal, worker)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }

        await TabMailAuthService._setSignOutLogoutTransportForTesting(nil)
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil,
            defaults: nil
        )
        defaults.removePersistentDomain(forName: suiteName)
        try await restoreSession(previousSession)
        try outcome.get()
    }

    /// Wall-clock is a poor instrument on a loaded host (see the flush suite's
    /// guard of the same name), so boundedness is asserted structurally — the
    /// hung leg was entered, was cancelled, and never returned before sign-out
    /// did — and this guard only separates "finite" from "never returns".
    private var signOutHangGuard: TimeInterval { PushConfig.signOutHandshakeTimeoutSeconds + 120 }

    @Test("sign-out releases the registered device on the worker before it ends the session server-side")
    func signOutReleasesDeviceBeforeLogout() async throws {
        try await withHarness { journal, worker in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "the worker release must run first and the logout must follow it")
            #expect(await worker.recordedReleasedDeviceIds() == [testDeviceId],
                    "the release must name the device id this install registered with")
            let logouts = journal.logoutRequests()
            #expect(logouts.count == 1)
            guard logouts.count == 1 else { return }
            #expect(logouts[0].headers["Authorization"] == "Bearer \(testAccessToken)",
                    "the logout must carry the same bearer that owned the registration")
            #expect(!TabMailAuthService.hasSession())
        }
    }

    @Test("sign-out skips the server-side logout when the worker release fails")
    func signOutSkipsLogoutWhenReleaseFails() async throws {
        try await withHarness(release: .fail(statusCode: nil)) { journal, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)"],
                    "a failed release must leave the session alive server-side and must not be retried")
            #expect(journal.logoutRequests().isEmpty)
            #expect(!TabMailAuthService.hasSession(), "the local session is cleared regardless")
        }
    }

    @Test("the sign-out logout ends only this session")
    func signOutLogoutIsScopedToThisSession() async throws {
        try await withHarness { journal, _ in
            await TabMailAuthService.signOut()

            let logouts = journal.logoutRequests()
            #expect(logouts.count == 1, "exactly one logout, no retry")
            guard logouts.count == 1, let url = logouts[0].url else { return }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(components?.scheme == "https")
            #expect(components?.path == "/auth/v1/logout")
            #expect(components?.queryItems == [URLQueryItem(name: "scope", value: "local")],
                    "scope=local is mandatory: the default global scope would end every other device's session")
            #expect(logouts[0].method == "POST")
            #expect(logouts[0].headers["apikey"]?.isEmpty == false)
            #expect(logouts[0].headers["Authorization"] == "Bearer \(testAccessToken)")
        }
    }

    @Test("sign-out clears the local session on every handshake outcome")
    func signOutClearsSessionOnEveryHandshakePath() async throws {
        let paths: [(name: String, release: ReleaseBehavior, logout: LogoutBehavior)] = [
            ("both succeed", .succeed, .respond(statusCode: 204)),
            ("release fails", .fail(statusCode: nil), .respond(statusCode: 204)),
            ("logout fails", .succeed, .fail),
            ("release hangs until the bound", .hang, .respond(statusCode: 204)),
        ]
        for path in paths {
            try await withHarness(release: path.release, logout: path.logout) { journal, _ in
                let signedOut = await TabMailAuthService.signOut()

                #expect(signedOut, "\(path.name): sign-out never fails")
                #expect(!TabMailAuthService.hasSession(), "\(path.name): the local session must be gone")
                #expect(journal.snapshot().first == "unregister-device:\(testDeviceId)",
                        "\(path.name): the handshake must have been attempted")
            }
        }
    }

    @Test("sign-out cancels the handshake task before it clears the local session")
    func signOutCancelsHandshakeBeforeClearingSession() async throws {
        try await withHarness(logout: .hang) { journal, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(!TabMailAuthService.hasSession())
            let entries = journal.snapshot()
            #expect(entries.contains("logout-cancelled:session-present=true"),
                    "the stalled handshake must be cancelled while the session still exists — cancel first, then clear (journal: \(entries))")
            #expect(!entries.contains("logout-returned"))
        }
    }

    @Test("a 401 from either leg is tolerated silently: no error, no retry, session cleared")
    func signOutToleratesInvalidatedSubject() async throws {
        try await withHarness(release: .fail(statusCode: 401)) { journal, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)"],
                    "one release attempt, no retry, and no logout after a rejected release")
            #expect(!TabMailAuthService.hasSession())
        }
        try await withHarness(logout: .respond(statusCode: 401)) { journal, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "one logout attempt, no retry")
            #expect(!TabMailAuthService.hasSession())
        }
    }

    @Test("sign-out never waits past the handshake bound")
    func signOutReturnsWithinHandshakeBound() async throws {
        try await withHarness(release: .hang) { journal, _ in
            let started = Date()
            let signedOut = await TabMailAuthService.signOut()
            let elapsed = Date().timeIntervalSince(started)
            let entries = journal.snapshot()

            #expect(signedOut)
            #expect(entries.first == "unregister-device:\(testDeviceId)", "the hung leg must have been entered")
            #expect(!entries.contains("unregister-device-returned"),
                    "sign-out returned only after the hung release completed — it waited instead of bounding")
            #expect(entries.contains(where: { $0.hasPrefix("unregister-device-cancelled:") }),
                    "the handshake task itself must be cancelled at the bound, not abandoned")
            #expect(journal.logoutRequests().isEmpty, "no logout after a release that did not succeed")
            #expect(elapsed < signOutHangGuard,
                    "sign-out must return at all while the release is stuck (took \(elapsed)s)")
            #expect(!TabMailAuthService.hasSession(), "a stuck release must not keep the local session alive")
        }
    }
}
