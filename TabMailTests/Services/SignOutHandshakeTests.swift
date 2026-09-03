/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Ordinary sign-out releases this device's push registration on the worker
/// and ends the auth session server-side — worker first, BOTH legs, `scope=local`
/// — inside one bounded window, and clears the local session on every path
/// regardless of how that handshake went.
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
        /// Returns SUCCESSFULLY, but only after the bound has already expired
        /// and the handshake task has been cancelled. Deliberately not
        /// cancellation-aware (a `Task.sleep` would throw instead of
        /// succeeding), which is the whole point: it is the one shape that can
        /// walk a post-bound handshake into the logout leg.
        case succeedAfterBound
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

    /// A wait that IGNORES cancellation, so the leg it guards completes normally
    /// after the caller has already given up on it. `Task.sleep` cannot express
    /// this: it throws the moment the handshake task is cancelled.
    static func waitIgnoringCancellation(seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    actor MockWorker: RemovedAccountPushCleaning {
        private let journal: Journal
        private let behavior: ReleaseBehavior
        private var releasedDeviceIds: [String] = []
        /// The identity bound to the release, read from INSIDE the client — the
        /// same propagation proof `MockCleanupClient.observedBearers` gives the
        /// cleanup drain. If the handshake stopped pinning the bearer, every
        /// entry here would be `nil`.
        private var observedBearers: [String?] = []

        init(journal: Journal, behavior: ReleaseBehavior) {
            self.journal = journal
            self.behavior = behavior
        }

        func recordedReleasedDeviceIds() -> [String] { releasedDeviceIds }
        func recordedBearers() -> [String?] { observedBearers }

        func unregisterDevice(deviceId: String) async throws {
            journal.append("unregister-device:\(deviceId)")
            releasedDeviceIds.append(deviceId)
            observedBearers.append(PushCleanupIdentity.pinnedAuthToken)
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
            case .succeedAfterBound:
                await SignOutHandshakeTests.waitIgnoringCancellation(
                    seconds: PushConfig.signOutHandshakeTimeoutSeconds + 2
                )
                journal.append("unregister-device-succeeded-after-bound")
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
    ///
    /// The isolated `UserDefaults` suite is handed to `body` because the durable
    /// effects of the release — which keys survive it and which do not — are
    /// part of the contract under test, not harness plumbing.
    private func withHarness(
        release: ReleaseBehavior = .succeed,
        logout: LogoutBehavior = .respond(statusCode: 204),
        body: (Journal, MockWorker, UserDefaults) async throws -> Void
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
            try await body(journal, worker, defaults)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }

        await TabMailAuthService._setSignOutLogoutTransportForTesting(nil)
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil,
            defaults: nil
        )
        // The registration cache is process-global in-memory state; a test that
        // seeded it must not leave it seeded for the next one.
        await PushNotificationService.shared._setDeviceRegistrationCacheForTesting(
            lastRegistrationTime: nil,
            lastRegisteredStateHash: nil
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
        try await withHarness { journal, worker, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "the worker release must run first and the logout must follow it")
            #expect(await worker.recordedReleasedDeviceIds() == [testDeviceId],
                    "the release must name the device id this install registered with")
            // The release itself must go out under the PINNED bearer, read from
            // inside the client. A task-local that silently fails to propagate
            // into the actor call would be a fail-dangerous seam: the release
            // would fall back to whatever ambient state `PushClient` finds.
            #expect(await worker.recordedBearers() == [testAccessToken],
                    "the release must carry the pinned bearer of the signing-out subject")
            let logouts = journal.logoutRequests()
            #expect(logouts.count == 1)
            guard logouts.count == 1 else { return }
            #expect(logouts[0].headers["Authorization"] == "Bearer \(testAccessToken)",
                    "the logout must carry the same bearer that owned the registration")
            #expect(!TabMailAuthService.hasSession())
        }
    }

    // A failed release used to SKIP the logout, on the theory that a
    // registration the worker still holds needs its session kept alive. The push
    // worker's own server-side sweep covers that case, so the coupling bought
    // nothing and cost this device a live server-side session after every worker
    // outage. Both legs now run, in the same order.
    @Test("sign-out still ends the session server-side when the worker release fails")
    func signOutStillLogsOutWhenReleaseFails() async throws {
        try await withHarness(release: .fail(statusCode: nil)) { journal, _, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "the logout must follow a FAILED release too, and in that order")
            let logouts = journal.logoutRequests()
            #expect(logouts.count == 1, "exactly one logout, no retry")
            guard logouts.count == 1 else { return }
            #expect(logouts[0].headers["Authorization"] == "Bearer \(testAccessToken)",
                    "the logout still carries the bearer of the session being ended")
            #expect(!TabMailAuthService.hasSession(), "the local session is cleared regardless")
        }
    }

    @Test("the sign-out logout ends only this session")
    func signOutLogoutIsScopedToThisSession() async throws {
        try await withHarness { journal, _, _ in
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
            try await withHarness(release: path.release, logout: path.logout) { journal, _, _ in
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
        try await withHarness(logout: .hang) { journal, _, _ in
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
        try await withHarness(release: .fail(statusCode: 401)) { journal, _, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "one release attempt and one logout attempt, neither retried")
            #expect(journal.logoutRequests().count == 1)
            #expect(!TabMailAuthService.hasSession())
        }
        try await withHarness(logout: .respond(statusCode: 401)) { journal, _, _ in
            let signedOut = await TabMailAuthService.signOut()

            #expect(signedOut)
            #expect(journal.snapshot() == ["unregister-device:\(testDeviceId)", "logout"],
                    "one logout attempt, no retry")
            #expect(!TabMailAuthService.hasSession())
        }
    }

    @Test("sign-out never waits past the handshake bound")
    func signOutReturnsWithinHandshakeBound() async throws {
        try await withHarness(release: .hang) { journal, _, _ in
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
            #expect(journal.logoutRequests().isEmpty,
                    "the cancelled handshake must stop at the bound instead of walking on into the logout")
            #expect(elapsed < signOutHangGuard,
                    "sign-out must return at all while the release is stuck (took \(elapsed)s)")
            #expect(!TabMailAuthService.hasSession(), "a stuck release must not keep the local session alive")
        }
    }

    // The bound is not only a wait: it is a STOP. `guard !Task.isCancelled`
    // between the two legs is what enforces that, and only a release that
    // SUCCEEDS after the bound can walk past it — a cancelled `Task.sleep`
    // throws, which the release-failure path already covers.
    @Test("a release that succeeds only after the bound must not still send the logout")
    func signOutSuppressesTheLogoutAfterTheBound() async throws {
        try await withHarness(release: .succeedAfterBound) { journal, _, _ in
            let started = Date()
            let signedOut = await TabMailAuthService.signOut()
            let elapsed = Date().timeIntervalSince(started)

            #expect(signedOut)
            #expect(!TabMailAuthService.hasSession())
            #expect(elapsed < signOutHangGuard,
                    "sign-out must return at the bound rather than wait out the slow release (took \(elapsed)s)")

            // Non-vacuity: the release must genuinely have completed, and
            // completed SUCCESSFULLY, after sign-out gave up on it. Without
            // this the empty logout list could just mean the release never ran.
            let lateSuccess = try await waitUntil(seconds: signOutHangGuard) {
                journal.snapshot().contains("unregister-device-succeeded-after-bound")
            }
            #expect(lateSuccess,
                    "the slow release must have SUCCEEDED post-bound, or the suppression below is vacuous")
            #expect(journal.logoutRequests().isEmpty,
                    "a handshake the bound already abandoned must not issue its logout afterwards")
        }
    }

    /// Bounded wait for a state a cancelled-but-still-running leg reaches
    /// asynchronously. Returns the final value so the caller asserts on it
    /// rather than hanging the test process.
    private func waitUntil(seconds: TimeInterval, _ condition: () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    // MARK: - Durable effects of the release
    //
    // The release trades a live registration for a clean local record. Which
    // keys survive it is load-bearing in BOTH directions: `lastDeviceTokenKey`
    // must survive (APNs re-delivers the device token only at launch, so losing
    // it strands a same-process sign-in with nothing to register), and the
    // registration record must NOT (a surviving 24 h "already registered" cache
    // makes the next sign-in skip registration entirely).

    @Test("the release keeps the APNs token and drops the registration record, on the success path")
    func releaseKeepsTheApnsTokenAndClearsTheRegistrationRecordOnSuccess() async throws {
        try await withHarness { journal, _, defaults in
            defaults.set("apns-device-token", forKey: PushConfig.lastDeviceTokenKey)
            defaults.set(["registered@example.com"], forKey: PushConfig.registeredEmailsKey)
            await PushNotificationService.shared._setDeviceRegistrationCacheForTesting(
                lastRegistrationTime: Date(),
                lastRegisteredStateHash: 4242
            )

            await TabMailAuthService.signOut()

            #expect(journal.snapshot().first == "unregister-device:\(testDeviceId)",
                    "the release must have been attempted, or the effects below prove nothing")
            #expect(defaults.string(forKey: PushConfig.lastDeviceTokenKey) == "apns-device-token",
                    "the cached APNs token must survive: APNs re-delivers it only at launch")
            #expect(defaults.object(forKey: PushConfig.registeredEmailsKey) == nil,
                    "the registered-emails record names a registration this call just released")
            let cache = await PushNotificationService.shared._deviceRegistrationCacheForTesting()
            #expect(cache.lastRegistrationTime == nil && cache.lastRegisteredStateHash == nil,
                    "a surviving registration cache would make the next sign-in skip registration inside its TTL")
        }
    }

    @Test("the release clears the registration record even when the worker call fails")
    func releaseClearsTheRegistrationRecordWhenTheWorkerCallFails() async throws {
        try await withHarness(release: .fail(statusCode: nil)) { journal, _, defaults in
            defaults.set("apns-device-token", forKey: PushConfig.lastDeviceTokenKey)
            defaults.set(["registered@example.com"], forKey: PushConfig.registeredEmailsKey)
            await PushNotificationService.shared._setDeviceRegistrationCacheForTesting(
                lastRegistrationTime: Date(),
                lastRegisteredStateHash: 4242
            )

            await TabMailAuthService.signOut()

            #expect(journal.snapshot().first == "unregister-device:\(testDeviceId)",
                    "the release must have been attempted, or the effects below prove nothing")
            #expect(defaults.string(forKey: PushConfig.lastDeviceTokenKey) == "apns-device-token",
                    "a failed release must not cost the install its APNs token either")
            // A client-side failure is not a server-side one: the worker may
            // have completed the delete and lost the response. Keeping the
            // local record would then mean dead push for a whole TTL, which no
            // user gesture repairs; re-registering redundantly is an idempotent
            // upsert.
            #expect(defaults.object(forKey: PushConfig.registeredEmailsKey) == nil,
                    "the registration record must not outlive a release whose outcome is unknown")
            let cache = await PushNotificationService.shared._deviceRegistrationCacheForTesting()
            #expect(cache.lastRegistrationTime == nil && cache.lastRegisteredStateHash == nil,
                    "the in-memory registration cache must be cleared on the failure path too")
        }
    }
}
