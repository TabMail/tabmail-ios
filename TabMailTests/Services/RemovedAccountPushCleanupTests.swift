/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

@Suite("IOS-PUSH-001 removed-account cleanup", .serialized, .processGlobalState)
struct RemovedAccountPushCleanupTests {
    enum InjectedFailure: Error { case offline }

    actor MockCleanupClient: RemovedAccountPushCleaning {
        private(set) var calls: [String] = []
        /// The identity pinned to the cleanup pass, as observed from INSIDE the
        /// client on every action. The mock does not go through `PushClient`,
        /// so this is a direct read of the task-local — which is exactly what
        /// makes it a propagation proof rather than an assumption: if the drain
        /// stopped binding the pin, every entry here would be `nil`.
        private(set) var observedBearers: [String?] = []
        /// The `userId` each `registerDevice` body carried.
        private(set) var registeredUserIds: [String] = []
        private(set) var deviceAccountIncarnations: [String] = []
        private var shouldFail = true
        private var ownershipRefusal = false
        private var genericForbidden = false
        private var providerFailuresRemaining = 0
        private var blockedDeviceAccountEmail: String?
        private var hasReachedBlock = false
        private var blockObservers: [CheckedContinuation<Void, Never>] = []
        private var blockRelease: CheckedContinuation<Void, Never>?

        func setShouldFail(_ value: Bool) { shouldFail = value }
        func setOwnershipRefusal(_ value: Bool) { ownershipRefusal = value }
        func setGenericForbidden(_ value: Bool) { genericForbidden = value }
        func setProviderFailuresRemaining(_ value: Int) { providerFailuresRemaining = value }
        func recordedCalls() -> [String] { calls }
        func recordedBearers() -> [String?] { observedBearers }
        func recordedRegisteredUserIds() -> [String] { registeredUserIds }
        func recordedDeviceAccountIncarnations() -> [String] { deviceAccountIncarnations }
        private func noteBearer() { observedBearers.append(PushCleanupIdentity.pinnedAuthToken) }
        func blockDeviceAccount(email: String) { blockedDeviceAccountEmail = email }
        /// Whether the blocked call has been entered at least once. Lets a test
        /// prove the flush genuinely reached the network without depending on
        /// wall-clock timing.
        func hasReachedDeviceAccountBlock() -> Bool { hasReachedBlock }
        func waitUntilDeviceAccountBlocked() async {
            if hasReachedBlock { return }
            await withCheckedContinuation { blockObservers.append($0) }
        }
        func releaseDeviceAccountBlock() {
            blockedDeviceAccountEmail = nil
            blockRelease?.resume()
            blockRelease = nil
        }

        private func record(_ value: String) throws {
            calls.append(value)
            if shouldFail { throw InjectedFailure.offline }
        }

        private func recordOwnershipCleanup(_ value: String) throws {
            calls.append(value)
            if ownershipRefusal {
                throw PushError.workerRequestFailed(statusCode: 403, errorCode: "user_mismatch")
            }
            if genericForbidden {
                throw PushError.workerRequestFailed(statusCode: 403, errorCode: nil)
            }
            if shouldFail { throw InjectedFailure.offline }
        }

        func unregisterDeviceAccount(
            deviceId: String,
            accountEmail: String,
            accountIncarnation: String
        ) async throws {
            noteBearer()
            calls.append("device-account:\(accountEmail)")
            deviceAccountIncarnations.append(accountIncarnation)
            if blockedDeviceAccountEmail == accountEmail {
                hasReachedBlock = true
                for observer in blockObservers { observer.resume() }
                blockObservers.removeAll()
                await withCheckedContinuation { blockRelease = $0 }
            }
            if shouldFail { throw InjectedFailure.offline }
        }

        func registerDevice(
            deviceToken: String,
            deviceId: String,
            userId: String,
            accountEmails: [String],
            apnsSandbox: Bool
        ) async throws {
            noteBearer()
            registeredUserIds.append(userId)
            try record("register-device:\(accountEmails.sorted().joined(separator: ","))")
        }

        func unregisterDevice(deviceId: String) async throws {
            noteBearer()
            try record("unregister-device")
        }

        func unsubscribeIMAP(userEmail: String) async throws {
            noteBearer()
            try record("imap:\(userEmail)")
        }

        func deleteGmailConsent(userEmail: String) async throws {
            noteBearer()
            try recordOwnershipCleanup("gmail-consent:\(userEmail)")
        }

        func deleteOutlookConsent(userEmail: String) async throws {
            noteBearer()
            try recordOwnershipCleanup("outlook-consent:\(userEmail)")
        }

        func unsubscribe(provider: String, userEmail: String, accessToken: String) async throws {
            noteBearer()
            let call = "provider-subscription:\(provider):\(userEmail):\(accessToken.isEmpty ? "empty" : "set")"
            calls.append(call)
            if providerFailuresRemaining > 0 {
                providerFailuresRemaining -= 1
                throw InjectedFailure.offline
            }
            if ownershipRefusal {
                throw PushError.workerRequestFailed(statusCode: 403, errorCode: "user_mismatch")
            }
            if genericForbidden {
                throw PushError.workerRequestFailed(statusCode: 403, errorCode: nil)
            }
            if shouldFail { throw InjectedFailure.offline }
        }
    }

    private let sessionKey = "tabmail_session"
    private let testWorkerUserId = "cleanup-test-user"

    private func installTestSession(userId: String, accessToken: String = "test-access") throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "refresh_token": "test-refresh",
            "expires_at": 4_102_444_800,
            "user": ["id": userId, "email": "session@example.com"],
        ])
        try KeychainHelper.save(data, for: sessionKey)
    }

    private func restoreSession(_ data: Data?) throws {
        if let data {
            try KeychainHelper.save(data, for: sessionKey)
        } else {
            KeychainHelper.delete(key: sessionKey)
        }
    }

    private func withHarness(
        activeAccount: Account? = nil,
        body: (UserDefaults, MockCleanupClient) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("cleanup.sqlite").path,
            configuration: config
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }

        if let activeAccount {
            try await pool.write { db in
                let accountToInsert = activeAccount
                try accountToInsert.insert(db)
            }
        }

        let suiteName = "RemovedAccountPushCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("test-device", forKey: PushConfig.deviceIdKey)
        let previousSession = KeychainHelper.load(key: sessionKey)
        try installTestSession(userId: testWorkerUserId)
        let mock = MockCleanupClient()
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: mock,
            defaults: SendableRemovedAccountCleanupDefaults(value: defaults)
        )

        do {
            try await body(defaults, mock)
        } catch {
            await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
                client: nil,
                defaults: nil
            )
            defaults.removePersistentDomain(forName: suiteName)
            try restoreSession(previousSession)
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
            throw error
        }

        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil,
            defaults: nil
        )
        defaults.removePersistentDomain(forName: suiteName)
        try restoreSession(previousSession)
        AppDatabase.shared.withLock { $0 = previousDatabase }
        TestDatabaseTeardown.retire(pool: pool, directory: directory)
    }

    @Test("offline cleanup remains durable and the next foreground-style retry deletes it only after every route succeeds")
    func offlineFailureRetriesToCompletion() async throws {
        try await withHarness { defaults, mock in
            var account = Account(
                emailAddress: "removed@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            account.id = "removed-account"
            let caldavId = "removed-caldav-\(UUID().uuidString)"
            let passwordKey = KeychainHelper.passwordKey(accountId: account.id)
            let accessKey = KeychainHelper.accessTokenKey(accountId: account.id)
            let refreshKey = KeychainHelper.refreshTokenKey(accountId: account.id)
            let caldavKey = "caldav_password_\(caldavId)"
            try KeychainHelper.save("password", for: passwordKey)
            try KeychainHelper.save("access", for: accessKey)
            try KeychainHelper.save("refresh", for: refreshKey)
            try KeychainHelper.save("caldav", for: caldavKey)
            defer {
                KeychainHelper.delete(key: passwordKey)
                KeychainHelper.delete(key: accessKey)
                KeychainHelper.delete(key: refreshKey)
                KeychainHelper.delete(key: caldavKey)
            }

            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                account,
                caldavConfigIds: [caldavId],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()

            #expect(KeychainHelper.loadString(key: passwordKey) == nil)
            #expect(KeychainHelper.loadString(key: accessKey) == nil)
            #expect(KeychainHelper.loadString(key: refreshKey) == nil)
            #expect(KeychainHelper.loadString(key: caldavKey) == nil)

            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1)
            #expect(retained[0].email == "removed@example.com")
            #expect(retained[0].actions == [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ])

            let callsBeforeUserSwitch = await mock.recordedCalls()
            try installTestSession(userId: "different-worker-user")
            await mock.setShouldFail(false)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).count == 1)
            #expect(await mock.recordedCalls() == callsBeforeUserSwitch,
                    "a different JWT subject must not advance the original user's debt")

            try installTestSession(userId: testWorkerUserId)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)
            #expect(defaults.object(forKey: PushConfig.removedAccountCleanupKey) == nil,
                    "the removed email must not be retained after remote cleanup completes")
            let calls = await mock.recordedCalls()
            #expect(calls.contains("device-account:removed@example.com"))
            #expect(await mock.recordedDeviceAccountIncarnations().contains("removed-account"))
            #expect(calls.contains("gmail-consent:removed@example.com"))
            #expect(calls.contains("unregister-device"))
            #expect(calls.contains("provider-subscription:gmail:removed@example.com:empty"),
                    "relaunch retry must revoke worker ownership/subscription even without an OAuth token")

            var shared = Account(
                emailAddress: "shared@example.com",
                displayName: "Shared",
                provider: .gmail
            )
            shared.id = "removed-shared-account"
            let sharedGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                shared,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: sharedGeneration
            )
            await mock.setOwnershipRefusal(true)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty,
                    "shared-owner 403 means this caller's proof was revoked and must terminalize")
            let sharedCalls = await mock.recordedCalls()
            #expect(sharedCalls.contains("gmail-consent:shared@example.com"))
            #expect(sharedCalls.contains("provider-subscription:gmail:shared@example.com:empty"))

            var edgeDenied = shared
            edgeDenied.id = "edge-forbidden-account"
            edgeDenied.emailAddress = "edge-forbidden@example.com"
            let deniedGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                edgeDenied,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: deniedGeneration
            )
            await mock.setOwnershipRefusal(false)
            await mock.setGenericForbidden(true)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            let denied = PendingRemovedAccountPushCleanup.load(from: defaults)
                .first { $0.generation == deniedGeneration }
            #expect(denied?.actions.contains(.consent) == true,
                    "a bare infrastructure 403 must remain durable")
            #expect(denied?.actions.contains(.providerSubscription) == true)
            await PushNotificationService.shared.cancelPreparedRemovedAccountCleanup(
                generation: deniedGeneration
            )
        }
    }

    @Test("captured OAuth token is attempted once and a missing APNs token does not strand debt")
    func capturedTokenIsAttemptedOnce() async throws {
        var live = Account(
            emailAddress: "live@example.com",
            displayName: "Live",
            provider: .gmail
        )
        live.id = "live-account"

        try await withHarness(activeAccount: live) { defaults, mock in
            var removed = Account(
                emailAddress: "removed-token@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "removed-token-account"
            await mock.setShouldFail(false)
            await mock.setProviderFailuresRemaining(1)
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: generation,
                capturedOAuthAccessToken: "one-shot-token"
            )

            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            let afterFirst = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(afterFirst.count == 1)
            #expect(afterFirst[0].actions == [.providerSubscription])
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)

            let calls = await mock.recordedCalls()
            #expect(calls.filter { $0 == "provider-subscription:gmail:removed-token@example.com:set" }.count == 1)
            #expect(calls.filter { $0 == "provider-subscription:gmail:removed-token@example.com:empty" }.count == 1)
            #expect(!calls.contains(where: { $0.hasPrefix("register-device:") }),
                    "without an APNs token there is no legacy registration to rewrite")
        }
    }

    @Test("signed-out removal persists local cleanup only")
    func signedOutRemovalDoesNotCreateUndischargeableRemoteDebt() async throws {
        try await withHarness { defaults, mock in
            KeychainHelper.delete(key: sessionKey)
            var removed = Account(
                emailAddress: "signed-out@example.com",
                displayName: "Signed out",
                provider: .gmail
            )
            removed.id = "signed-out-account"
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            let prepared = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(prepared.count == 1)
            #expect(prepared[0].workerUserId == nil)
            #expect(prepared[0].actions == [.localArtifacts])

            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: generation
            )
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)
            #expect(await mock.recordedCalls().isEmpty)
        }
    }

    @Test("a cleanup pass cannot clobber a newer same-email account-ID generation")
    func overlappingPrepareSurvivesDrainMerge() async throws {
        try await withHarness { defaults, mock in
            var first = Account(
                emailAddress: "first@example.com",
                displayName: "First",
                provider: .gmail
            )
            first.id = "first-account"
            var second = Account(
                emailAddress: first.emailAddress,
                displayName: "Second",
                provider: .gmail
            )
            second.id = "second-account"

            await mock.setShouldFail(false)
            await mock.blockDeviceAccount(email: first.emailAddress)
            let firstGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                first,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: firstGeneration)

            let drain = Task {
                await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            }
            await mock.waitUntilDeviceAccountBlocked()

            let secondGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                second,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: secondGeneration)
            await mock.setShouldFail(true)
            await mock.releaseDeviceAccountBlock()
            await drain.value

            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(Set(retained.map(\.accountId)) == [first.id, second.id],
                    "same-email generations own distinct account-ID artifacts and must both survive")
            let secondDebt = retained.first { $0.accountId == second.id }
            #expect(secondDebt != nil, "generation merge must preserve newer removal intent")
            #expect(secondDebt?.actions == [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ])
        }
    }

    @Test("a generation stays inert until its runtime fence is committed")
    func censusDoesNotEraseInFlightPrepare() async throws {
        var account = Account(
            emailAddress: "preparing@example.com",
            displayName: "Preparing",
            provider: .gmail
        )
        account.id = "preparing-account"

        try await withHarness { defaults, mock in
            let accessKey = KeychainHelper.accessTokenKey(accountId: account.id)
            try KeychainHelper.save("must-survive-prepare", for: accessKey)
            defer { KeychainHelper.delete(key: accessKey) }
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                account,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()

            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1)
            #expect(retained[0].accountId == account.id)
            #expect(KeychainHelper.loadString(key: accessKey) == "must-survive-prepare")
            #expect(await mock.recordedCalls().isEmpty)

            await PushNotificationService.shared.cancelPreparedRemovedAccountCleanup(generation: generation)
        }
    }

    @Test("same-email re-add suppresses only replacement-owned remote state")
    func readdedEmailCancelsCleanup() async throws {
        var live = Account(
            emailAddress: "same@example.com",
            displayName: "Live again",
            provider: .gmail
        )
        live.id = "new-account-id"

        try await withHarness(activeAccount: live) { defaults, mock in
            var removed = live
            removed.id = "old-account-id"
            let oldAccessKey = KeychainHelper.accessTokenKey(accountId: removed.id)
            try KeychainHelper.save("old-token", for: oldAccessKey)
            defer { KeychainHelper.delete(key: oldAccessKey) }
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            var removedOutlook = removed
            removedOutlook.id = "old-outlook-account-id"
            removedOutlook.provider = .outlook
            let outlookGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removedOutlook,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: outlookGeneration
            )
            await mock.setShouldFail(false)

            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()

            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)
            #expect(KeychainHelper.loadString(key: oldAccessKey) == nil,
                    "same-email re-add may suppress remote deletion only after old-ID secrets are gone")
            let calls = await mock.recordedCalls()
            #expect(!calls.contains(where: { $0.hasPrefix("device-account:") || $0 == "unregister-device" }),
                    "email-global routes belong to the replacement")
            #expect(calls.contains("outlook-consent:same@example.com"))
            #expect(calls.contains("provider-subscription:outlook:same@example.com:empty"),
                    "provider-specific debt from the old provider must still be retired")

            var calendarOnly = Account(
                emailAddress: "calendar-only@example.com",
                displayName: "Calendar",
                provider: .caldav
            )
            calendarOnly.id = "calendar-only-live"
            let calendarOnlySnapshot = calendarOnly
            try await AppDatabase.dbPool.write { db in try calendarOnlySnapshot.insert(db) }
            var removedMailbox = Account(
                emailAddress: calendarOnly.emailAddress,
                displayName: "Old mailbox",
                provider: .gmail
            )
            removedMailbox.id = "calendar-only-old-mailbox"
            let calendarGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removedMailbox,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(
                generation: calendarGeneration
            )
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            #expect(await mock.recordedCalls().contains("device-account:calendar-only@example.com"),
                    "CalDAV never replaces the removed mailbox dispatch route")
        }
    }

    @Test("local NSE mirrors fail closed before commit and re-derive from the authoritative DB on rollback")
    func localMirrorsEvictAndRederive() async throws {
        var removed = Account(
            emailAddress: "removed@example.com",
            displayName: "Removed",
            provider: .imap
        )
        removed.id = "removed-id"
        removed.imapHost = "removed.test"
        removed.imapPort = 993
        removed.imapUsername = "removed"

        var kept = Account(
            emailAddress: "kept@example.com",
            displayName: "Kept",
            provider: .imap
        )
        kept.id = "kept-id"
        kept.imapHost = "kept.test"
        kept.imapPort = 993
        kept.imapUsername = "kept"
        let keptSnapshot = kept

        try await withHarness(activeAccount: removed) { defaults, _ in
            try await AppDatabase.dbPool.write { db in
                try keptSnapshot.insert(db)
            }

            let accountMap = [
                "removed@example.com": "removed-id",
                "kept@example.com": "kept-id",
            ]
            let accountData = try JSONEncoder().encode(accountMap)
            defaults.set(String(data: accountData, encoding: .utf8), forKey: "nse.accountMap")

            let imapMap: [String: [String: Any]] = [
                "removed-id": ["host": "removed.test", "port": 993, "username": "removed"],
                "kept-id": ["host": "kept.test", "port": 993, "username": "kept"],
            ]
            let imapData = try JSONSerialization.data(withJSONObject: imapMap)
            defaults.set(String(data: imapData, encoding: .utf8), forKey: "nse.imapAccounts")

            NSEDataBridge.removeAccountFromMirrors(
                accountId: "removed-id",
                email: "REMOVED@example.com",
                defaults: defaults
            )

            let remainingAccounts = try JSONDecoder().decode(
                [String: String].self,
                from: Data(defaults.string(forKey: "nse.accountMap")!.utf8)
            )
            let remainingIMAP = try JSONSerialization.jsonObject(
                with: Data(defaults.string(forKey: "nse.imapAccounts")!.utf8)
            ) as! [String: [String: Any]]
            #expect(remainingAccounts == ["kept@example.com": "kept-id"])
            #expect(Set(remainingIMAP.keys) == ["kept-id"])

            // DB failure leaves both rows authoritative, so rollback rebuilds
            // both maps from GRDB rather than trusting the captured Account.
            NSEDataBridge.mirrorAccountMap(defaults: defaults)
            NSEDataBridge.mirrorIMAPAccounts(defaults: defaults)
            let restoredAccounts = try JSONDecoder().decode(
                [String: String].self,
                from: Data(defaults.string(forKey: "nse.accountMap")!.utf8)
            )
            let restoredIMAP = try JSONSerialization.jsonObject(
                with: Data(defaults.string(forKey: "nse.imapAccounts")!.utf8)
            ) as! [String: [String: Any]]
            #expect(restoredAccounts == [
                "kept@example.com": "kept-id",
                "removed@example.com": "removed-id",
            ])
            #expect(Set(restoredIMAP.keys) == ["kept-id", "removed-id"])
            #expect(restoredIMAP["removed-id"]?["host"] as? String == "removed.test")
        }
    }

    // MARK: - IOS-PUSH-001 sign-out handoff

    /// Anti-hang guard, NOT a measurement of the production timeout.
    ///
    /// Whether sign-out is bounded is asserted structurally (the flush provably
    /// did not finish before sign-out returned); wall-clock is a poor instrument
    /// for it here, because these suites share a machine with other simulator
    /// runs and a 5s timer has been observed resuming ~30s late at a load
    /// average near 400. This bound therefore only has to separate "finite" from
    /// "never returns", so it is deliberately far above the production bound.
    private var signOutHangGuard: TimeInterval { PushConfig.signOutCleanupFlushTimeoutSeconds + 120 }

    /// Bounded wait for a state the drain reaches asynchronously. Returns the
    /// condition's final value so the caller asserts on it rather than hanging
    /// the whole test process when the property does not hold.
    private func waitUntil(seconds: TimeInterval, _ condition: () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    @Test("sign-out flushes remote cleanup debt before the session that owns it is cleared")
    func signOutFlushesRemoteDebtWhileSessionValid() async throws {
        try await withHarness { defaults, mock in
            var removed = Account(
                emailAddress: "signout-flush@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "signout-flush-account"

            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            // The removal happened offline, so its immediate drain leaves the
            // worker-owned actions durable.
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            let strandedBefore = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(strandedBefore.count == 1, "the offline removal must leave debt for sign-out to flush")
            guard strandedBefore.count == 1 else { return }
            #expect(strandedBefore[0].actions == [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ])

            // The network is back and the user signs out. The session is the
            // only credential that can ever discharge this debt, so it must be
            // spent before it is destroyed.
            await mock.setShouldFail(false)
            await TabMailAuthService.signOut()

            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty,
                    "sign-out must flush the debt while the owning session is still valid")
            #expect(defaults.object(forKey: PushConfig.removedAccountCleanupKey) == nil,
                    "the removed email must not be retained after remote cleanup completes")
            #expect(KeychainHelper.load(key: sessionKey) == nil, "sign-out must still clear the session")

            let calls = await mock.recordedCalls()
            #expect(calls.contains("device-account:signout-flush@example.com"))
            #expect(calls.contains("gmail-consent:signout-flush@example.com"))
            #expect(calls.contains("provider-subscription:gmail:signout-flush@example.com:empty"))
            #expect(calls.contains("unregister-device"))
        }
    }

    @Test("a hung cleanup flush cannot block sign-out and cannot drop the debt")
    func signOutIsNotBlockedByAHungFlushAndDoesNotDropDebt() async throws {
        try await withHarness { defaults, mock in
            var removed = Account(
                emailAddress: "signout-hung@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "signout-hung-account"

            await mock.setShouldFail(false)
            await mock.blockDeviceAccount(email: removed.emailAddress)
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            let started = Date()
            await TabMailAuthService.signOut()
            let elapsed = Date().timeIntervalSince(started)
            let callsAtSignOut = await mock.recordedCalls()

            // THE invariant, stated structurally rather than in wall-clock:
            // the blocked cleanup call never returns, so every action the drain
            // performs after it is proof that sign-out waited for the flush.
            #expect(!callsAtSignOut.contains(where: { $0.hasPrefix("gmail-consent:") }),
                    "sign-out returned only after the blocked cleanup call completed — it waited instead of bounding")
            #expect(elapsed < signOutHangGuard,
                    "sign-out must return at all while a cleanup call is stuck (took \(elapsed)s)")
            #expect(KeychainHelper.load(key: sessionKey) == nil,
                    "sign-out is unconditional — a stuck flush must not keep the session alive")
            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1, "a timed-out flush must never discard the debt")
            guard retained.count == 1 else {
                await mock.releaseDeviceAccountBlock()
                return
            }
            #expect(retained[0].actions.isSuperset(of: [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ]), "the unfinished remote actions must survive intact")

            // Non-vacuity for the assertion above: the flush really did run and
            // really did reach the network, so "no call after the blocked one"
            // describes a bounded sign-out rather than a flush that never began.
            let reachedBlock = try await waitUntil(seconds: signOutHangGuard) {
                await mock.hasReachedDeviceAccountBlock()
            }
            #expect(reachedBlock, "the flush must have reached the blocked cleanup call")

            // `withTimeout` cancels the flush task but cannot force an actor to
            // return, so the drain latch's release is proved, never assumed.
            await mock.releaseDeviceAccountBlock()
            let releasedFlushFinished = try await waitUntil(seconds: signOutHangGuard) {
                PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty
            }
            #expect(releasedFlushFinished, "the released flush must run to completion rather than stall")

            // Re-entrancy after the cancelled flush: a wedged `drainActive`
            // latch would make every later retry a no-op and strand this record.
            try installTestSession(userId: testWorkerUserId)
            var later = Account(
                emailAddress: "signout-hung-later@example.com",
                displayName: "Later",
                provider: .gmail
            )
            later.id = "signout-hung-later-account"
            let laterGeneration = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                later,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: laterGeneration)
            await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            let laterDrained = try await waitUntil(seconds: signOutHangGuard) {
                PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty
            }
            #expect(laterDrained,
                    "a cancelled flush must leave the drain re-entrant — a wedged latch strands this record")
            #expect(await mock.recordedCalls().contains("device-account:signout-hung-later@example.com"),
                    "the later drain must reach the network, not merely retire local artifacts")
        }
    }

    @Test("sign-out with no cleanup debt performs no cleanup work at all")
    func signOutWithNoDebtPerformsNoCleanupWork() async throws {
        try await withHarness { defaults, mock in
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)

            await TabMailAuthService.signOut()

            #expect(await mock.recordedCalls().isEmpty,
                    "the ordinary sign-out path must not gain a network round-trip")
            #expect(KeychainHelper.load(key: sessionKey) == nil)
        }
    }

    @Test("sign-out does not advance cleanup debt bound to a different subject")
    func signOutDoesNotAdvanceAnotherSubjectsDebt() async throws {
        try await withHarness { defaults, mock in
            var removed = Account(
                emailAddress: "signout-other-subject@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "signout-other-subject-account"

            await mock.setShouldFail(false)
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            // A different subject is signed in now. Their sign-out may not spend
            // the original user's debt, and may not retire it either.
            try installTestSession(userId: "different-worker-user")
            await TabMailAuthService.signOut()

            #expect(await mock.recordedCalls().isEmpty,
                    "only the subject that owns the debt may advance it remotely")
            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1, "another subject's sign-out must not retire the debt")
            guard retained.count == 1 else { return }
            #expect(retained[0].workerUserId == testWorkerUserId)
            #expect(retained[0].actions.isSuperset(of: [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ]))
            #expect(KeychainHelper.load(key: sessionKey) == nil)
        }
    }

    @Test("sign-out completes and notifies even when the cleanup flush fails")
    func signOutClearsTheSessionEvenWhenTheFlushFails() async throws {
        try await withHarness { defaults, mock in
            var removed = Account(
                emailAddress: "signout-offline@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "signout-offline-account"

            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)
            // The mock fails by default: the device is still offline at sign-out.

            let posted = Mutex(false)
            let token = NotificationCenter.default.addObserver(
                forName: .tabMailDidSignOut,
                object: nil,
                queue: nil
            ) { _ in
                posted.withLock { $0 = true }
            }
            await TabMailAuthService.signOut()
            NotificationCenter.default.removeObserver(token)

            let observed = posted.withLock { $0 }
            #expect(observed, "sign-out must post .tabMailDidSignOut regardless of the flush outcome")
            #expect(KeychainHelper.load(key: sessionKey) == nil,
                    "a failed flush must not leave the user signed in")
            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1, "a failed flush must leave the debt durable")
            guard retained.count == 1 else { return }
            #expect(retained[0].actions.isSuperset(of: [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ]))
            #expect(await mock.recordedCalls().contains("device-account:signout-offline@example.com"),
                    "the flush must actually be attempted before the session goes away")
        }
    }

    @Test("a same-user removal drain active at sign-out coalesces the flush; the debt is not dropped and the released drain resumes to completion")
    func signOutCoalescesWithActiveSameUserRemovalDrainThenResumesToCompletion() async throws {
        try await withHarness { defaults, mock in
            var removed = Account(
                emailAddress: "signout-concurrent-drain@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "signout-concurrent-drain-account"

            // The network is up, but the FIRST worker call blocks mid-drain, so
            // `AccountManagerSetup.removeAccount`'s detached drain is provably
            // ACTIVE — `removedAccountCleanupDrainActive` is set and the drain is
            // suspended inside the first remote call — at the moment sign-out lands.
            await mock.setShouldFail(false)
            await mock.blockDeviceAccount(email: removed.emailAddress)
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            let removalDrain = Task {
                await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            }
            await mock.waitUntilDeviceAccountBlocked()

            // Ordinary sign-out lands while that drain is active. Its flush call
            // coalesces with the in-flight drain (the early-return latch path)
            // instead of running a second drain or waiting on the first, so the
            // bounded wait completes at once and `clearSession()` proceeds.
            await TabMailAuthService.signOut()

            // (i) Sign-out is unconditional — the session is gone.
            #expect(KeychainHelper.load(key: sessionKey) == nil,
                    "sign-out must clear the session even when a removal drain is mid-flight")

            // (ii)+(iii) TRANSIENT never-drop, blocked window: the coalesced flush
            // neither discharged nor dropped the debt. The still-blocked drain has
            // persisted nothing, so the worker-owned actions are all still present
            // at the moment sign-out returns. This assertion is what a coalescing-
            // path that DROPPED the debt (clearing the pending records on the early
            // return) makes go red.
            let retained = PendingRemovedAccountPushCleanup.load(from: defaults)
            #expect(retained.count == 1, "the coalesced flush must never drop the retained debt")
            guard retained.count == 1 else {
                await mock.releaseDeviceAccountBlock()
                await removalDrain.value
                return
            }
            #expect(retained[0].actions.isSuperset(of: [
                .deviceAccount,
                .deviceRegistration,
                .consent,
                .providerSubscription,
            ]), "the concurrently-draining record's worker actions must survive intact")

            // (iv) SETTLED invariant: the coalescing neither corrupted nor stranded
            // the debt. Releasing the still-blocked SAME-user drain (the mock is
            // already non-failing) lets it run to completion under the identity it
            // was admitted with — its `currentWorkerUserId` was captured before
            // sign-out — so the same-user debt is discharged BY COMPLETION, not
            // dropped and not stranded. This is a same-user claim only: the mock
            // ignores auth, so this pins that the coalescing preserved the debt for
            // its owning drain to finish, NOT that production discharges every
            // action after `clearSession()`.
            await mock.releaseDeviceAccountBlock()
            await removalDrain.value

            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty,
                    "the released same-user drain must discharge the coalesced debt by completion, not leave it dropped or stranded")
            #expect(defaults.object(forKey: PushConfig.removedAccountCleanupKey) == nil,
                    "the removed-account record must be retired once the resumed same-user drain completes")
            let settledCalls = await mock.recordedCalls()
            #expect(settledCalls.contains("device-account:signout-concurrent-drain@example.com"),
                    "the resumed drain must complete the blocked device-account call")
            #expect(settledCalls.contains("gmail-consent:signout-concurrent-drain@example.com"),
                    "the resumed drain must reach the consent teardown")
            #expect(settledCalls.contains("provider-subscription:gmail:signout-concurrent-drain@example.com:empty"),
                    "the resumed drain must reach the provider-subscription teardown")
        }
    }

    // MARK: - Identity is pinned to the WORK, not to ambient state
    //
    // The drain admits a pass against ONE subject and then performs several
    // awaited network actions. Each production `PushClient` call used to
    // re-derive its bearer from the ambient Keychain slot, so a sign-in landing
    // mid-pass sent the REMAINDER of A's cleanup under B's identity — either
    // discharging A's debt without performing it (the worker's `user_mismatch`
    // read as proof of settlement) or mutating B-scoped worker state.

    @Test("a sign-in landing mid-pass cannot switch the bearer: every action stays pinned to the admitted subject")
    func midPassSignInCannotSwitchTheCleanupBearer() async throws {
        // A second, still-active account with a DIFFERENT email keeps the
        // legacy device-registration action live (and unsuppressed), so the
        // `registerDevice` subject assertion below is not vacuous.
        var stillActive = Account(
            emailAddress: "still-here@example.com",
            displayName: "Active",
            provider: .gmail
        )
        stillActive.id = "still-here-account"

        try await withHarness(activeAccount: stillActive) { defaults, mock in
            // An APNs token must exist or legacy device refresh short-circuits
            // before ever calling `registerDevice`.
            defaults.set("apns-device-token", forKey: PushConfig.lastDeviceTokenKey)

            var removed = Account(
                emailAddress: "pinned-identity@example.com",
                displayName: "Removed",
                provider: .gmail
            )
            removed.id = "pinned-identity-account"

            await mock.setShouldFail(false)
            await mock.blockDeviceAccount(email: removed.emailAddress)
            let generation = await PushNotificationService.shared.prepareRemovedAccountCleanup(
                removed,
                caldavConfigIds: [],
                outboxAttachmentDirNames: []
            )
            await PushNotificationService.shared.commitPreparedRemovedAccountCleanup(generation: generation)

            let drain = Task {
                await PushNotificationService.shared.retryPendingRemovedAccountCleanups()
            }
            await mock.waitUntilDeviceAccountBlocked()

            // Account B signs in while A's pass is suspended inside its FIRST
            // remote call. The ambient session slot now holds B's subject and
            // B's bearer — everything a per-action token read would pick up.
            try installTestSession(userId: "other-user", accessToken: "test-access-B")
            // Two-sided setup guard: prove the switch actually happened, so a
            // green result cannot come from the scenario never occurring.
            let liveSubject = await MainActor.run { TabMailAuthService.getSession()?.userId }
            #expect(liveSubject == "other-user",
                    "setup must genuinely switch the live session, or this test proves nothing")

            await mock.releaseDeviceAccountBlock()
            await drain.value

            let bearers = await mock.recordedBearers()
            #expect(!bearers.isEmpty, "the pass must actually have performed remote actions")

            // (i) PROPAGATION. A task-local that silently fails to reach the
            // client would be a fail-dangerous seam, so assert it arrived
            // rather than assuming actor calls inherit it.
            #expect(bearers.allSatisfy { $0 != nil },
                    "the pinned bearer must propagate into every client call")

            // (ii) IDENTITY. Every action — including those that ran AFTER B
            // signed in — went out under the ADMITTED subject's bearer.
            #expect(bearers.allSatisfy { $0 == "test-access" },
                    "every action must use the admitted subject's bearer, never the live session's")
            #expect(!bearers.contains("test-access-B"),
                    "no action may be sent under the newly signed-in user's bearer")

            // (iii) The legacy device re-registration named the ADMITTED
            // subject too — it used to re-read the ambient session here, which
            // is a cross-user worker-state mutation.
            let registeredIds = await mock.recordedRegisteredUserIds()
            #expect(!registeredIds.isEmpty,
                    "the legacy device registration must run, or (iii) proves nothing")
            #expect(registeredIds.allSatisfy { $0 == testWorkerUserId },
                    "device re-registration must name the admitted subject, not the newly signed-in one")
        }
    }
}
