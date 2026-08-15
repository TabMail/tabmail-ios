/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("IOS-CLEANUP-001 destructive cleanup", .serialized, .processGlobalState)
struct DestructiveCleanupReliabilityTests {
    @Test("account-removal DB abort preserves credentials, files, row, and cancels prepared debt")
    func accountRemovalRollsBackAtomically() async throws {
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
        let suiteName = "DestructiveCleanupReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let nseDefaults = UserDefaults(suiteName: "group.ai.tabmail")!
        let previousNSEAccountMap = nseDefaults.string(forKey: "nse.accountMap")
        let previousNSEIMAPAccounts = nseDefaults.string(forKey: "nse.imapAccounts")
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil,
            defaults: SendableRemovedAccountCleanupDefaults(value: defaults)
        )

        var account = Account(
            emailAddress: "abort-\(UUID().uuidString)@example.com",
            displayName: "Abort",
            provider: .gmail
        )
        account.id = "abort-account-\(UUID().uuidString)"
        var outbox = OutboxMessage(
            accountId: account.id,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Keep", body: "Keep")
        )
        let attachmentDirName = outbox.id
        outbox.attachmentsDirName = attachmentDirName
        let attachmentDir = OutboxMessage.attachmentsBaseDir
            .appendingPathComponent(attachmentDirName, isDirectory: true)
        let marker = attachmentDir.appendingPathComponent("marker")
        let passwordKey = KeychainHelper.passwordKey(accountId: account.id)
        let accessKey = KeychainHelper.accessTokenKey(accountId: account.id)
        let refreshKey = KeychainHelper.refreshTokenKey(accountId: account.id)
        let accountSnapshot = account
        let outboxSnapshot = outbox

        let cleanup: () async -> Void = {
            await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
                client: nil,
                defaults: nil
            )
            KeychainHelper.delete(key: passwordKey)
            KeychainHelper.delete(key: accessKey)
            KeychainHelper.delete(key: refreshKey)
            try? FileManager.default.removeItem(at: attachmentDir)
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap {
                nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap")
            } else {
                nseDefaults.removeObject(forKey: "nse.accountMap")
            }
            if let previousNSEIMAPAccounts {
                nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts")
            } else {
                nseDefaults.removeObject(forKey: "nse.imapAccounts")
            }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        do {
            try await pool.write { conn in
                try accountSnapshot.insert(conn)
                try outboxSnapshot.insert(conn)
            }
            try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
            try Data("must survive".utf8).write(to: marker)
            try KeychainHelper.save("password", for: passwordKey)
            try KeychainHelper.save("access", for: accessKey)
            try KeychainHelper.save("refresh", for: refreshKey)

            try await pool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_removal
                BEFORE DELETE ON account
                BEGIN SELECT RAISE(ABORT, 'injected account removal failure'); END;
                """)
            }

            await #expect(throws: (any Error).self) {
                try await AccountManager.shared.removeAccount(account)
            }

            #expect(try await pool.read { try Account.fetchCount($0) } == 1)
            #expect(try await pool.read { try OutboxMessage.fetchCount($0) } == 1)
            #expect(KeychainHelper.loadString(key: passwordKey) == "password")
            #expect(KeychainHelper.loadString(key: accessKey) == "access")
            #expect(KeychainHelper.loadString(key: refreshKey) == "refresh")
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test("a stale Account value cannot resurrect runtime state after committed removal")
    func staleAccountCannotReconnect() async {
        var account = Account(
            emailAddress: "stale-\(UUID().uuidString)@example.com",
            displayName: "Removed",
            provider: .gmail
        )
        account.id = "removed-runtime-\(UUID().uuidString)"
        let manager = AccountManager.shared

        await manager.disconnectAccount(account, deletingCredentials: [])
        await #expect(throws: ProviderError.self) {
            try await manager.connectAccount(account)
        }

        #expect(await manager.providers[account.id] == nil)
        #expect(await manager.workQueues[account.id] == nil)
        #expect(await manager.calendarProviders[account.id] == nil)
        await #expect(throws: ProviderError.self) {
            try await manager.freshAccessToken(for: account)
        }
    }

    @Test("Reset Message Data rolls every GRDB mutation back on an injected mid-transaction ABORT")
    func accountResetRollsBackAtomically() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        try db.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_reset
                BEFORE DELETE ON messageBody
                BEGIN SELECT RAISE(ABORT, 'injected account reset failure'); END;
                """)
        }

        #expect(throws: (any Error).self) {
            try db.write { conn in
                try AccountDetailView.resetMessageDataTxn(conn, accountId: "acc1")
            }
        }

        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
        #expect(try db.read { try MessageBody.fetchCount($0) } == 1)
        #expect(try db.read { try Account.fetchCount($0) } == 1)
    }

}
