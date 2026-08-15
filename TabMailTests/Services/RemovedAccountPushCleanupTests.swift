/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("IOS-PUSH-001 removed-account cleanup", .serialized, .processGlobalState)
struct RemovedAccountPushCleanupTests {
    enum InjectedFailure: Error { case offline }

    actor MockCleanupClient: RemovedAccountPushCleaning {
        private(set) var calls: [String] = []
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
        func blockDeviceAccount(email: String) { blockedDeviceAccountEmail = email }
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

        func unregisterDeviceAccount(deviceId: String, accountEmail: String) async throws {
            calls.append("device-account:\(accountEmail)")
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
            try record("register-device:\(accountEmails.sorted().joined(separator: ","))")
        }

        func unregisterDevice(deviceId: String) async throws {
            try record("unregister-device")
        }

        func unsubscribeIMAP(userEmail: String) async throws {
            try record("imap:\(userEmail)")
        }

        func deleteGmailConsent(userEmail: String) async throws {
            try recordOwnershipCleanup("gmail-consent:\(userEmail)")
        }

        func deleteOutlookConsent(userEmail: String) async throws {
            try recordOwnershipCleanup("outlook-consent:\(userEmail)")
        }

        func unsubscribe(provider: String, userEmail: String, accessToken: String) async throws {
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

    private func installTestSession(userId: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": "test-access",
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
}
