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
                try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
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

    /// INVARIANT (#718): account removal deletes no saved put-back file the user was not warned
    /// of. The files are counted again in the delete's own transaction; more than the warning said
    /// refuses the removal with the new count and changes nothing. As many as it said passes the
    /// count (the injected abort, which fires only at the delete, is what stops it then).
    @Test("account removal refuses, changing nothing, when more saved put-back files exist than the user was warned of")
    func accountRemovalRecountsSavedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("cleanup.sqlite").path, configuration: config)
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
            client: nil, defaults: SendableRemovedAccountCleanupDefaults(value: defaults))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap { nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap") } else { nseDefaults.removeObject(forKey: "nse.accountMap") }
            if let previousNSEIMAPAccounts { nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts") } else { nseDefaults.removeObject(forKey: "nse.imapAccounts") }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        var account = Account(emailAddress: "saved-\(UUID().uuidString)@example.com", displayName: "Saved", provider: .outlook)
        account.id = "saved-files-account-\(UUID().uuidString)"
        let bytes = Data("own notes".utf8)
        let file = PutBackFile(occurrence: "occ-1", name: "notes.txt", contentType: "text/plain", isInline: false, contentId: nil,
                               sha256: SavedFileName.of(bytes))
        let recordData = try JSONSerialization.data(
            withJSONObject: [SeriesEditRecord.argumentKey: SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: [file], write: .sent, seriesEtag: "W/\"ser-1-0\"").jsonObject])
        let op = PendingCalendarOperation(
            operationType: .edit, accountId: account.id, eventId: "ser-1", calendarId: "primary",
            arguments: try JSONDecoder().decode([String: JSONValue].self, from: recordData), eventTitle: "Planning")
        let snapshot = account
        try await pool.write { conn in
            try snapshot.insert(conn)
            try op.insert(conn)
        }
        // Saved by a drain after the user saw a warning of none.
        _ = try CalendarPutBackFiles.save(bytes, opId: op.id)

        await #expect(throws: AccountRemovalSavedFilesGrew(savedFiles: 1)) {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
        }
        #expect(try await pool.read { try Account.fetchCount($0) } == 1)
        #expect(try await pool.read { try PendingCalendarOperation.fetchCount($0) } == 1)
        #expect(CalendarPutBackFiles.holdsBytes(op.id), "the saved file went")
        #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)

        try await pool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_removal
                BEFORE DELETE ON account
                BEGIN SELECT RAISE(ABORT, 'injected account removal failure'); END;
                """)
        }
        do {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 1)
            Issue.record("the injected abort did not fire")
        } catch {
            #expect(!(error is AccountRemovalSavedFilesGrew), "warned of as many files as are saved, the removal was still refused: \(error)")
        }
        #expect(CalendarPutBackFiles.holdsBytes(op.id), "the saved file went with an aborted removal")
    }

    /// INVARIANT (#979, ADR-IOS-117): the real account removal owns its chats' unsent words. A
    /// refused removal keeps them (shown, stored, and new words still written); a committed one
    /// forgets them and writes none again.
    @Test("account removal keeps the chat words when refused and forgets them, never writing again, when it commits")
    @MainActor
    func accountRemovalOwnsTheChatWords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("cleanup.sqlite").path, configuration: config)
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
            client: nil, defaults: SendableRemovedAccountCleanupDefaults(value: defaults))
        ChatFieldWords.shared = ChatFieldWords(database: { PrioritizedDatabase(pool: pool) })
        // The shared store is reset however the test ends, so no later test reads this one's.
        defer { ChatFieldWords.shared = ChatFieldWords() }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap { nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap") } else { nseDefaults.removeObject(forKey: "nse.accountMap") }
            if let previousNSEIMAPAccounts { nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts") } else { nseDefaults.removeObject(forKey: "nse.imapAccounts") }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        var account = Account(emailAddress: "words-\(UUID().uuidString)@example.com", displayName: "Words", provider: .outlook)
        account.id = "words-account-\(UUID().uuidString)"
        let bytes = Data("own notes".utf8)
        let file = PutBackFile(occurrence: "occ-1", name: "notes.txt", contentType: "text/plain", isInline: false, contentId: nil,
                               sha256: SavedFileName.of(bytes))
        let recordData = try JSONSerialization.data(
            withJSONObject: [SeriesEditRecord.argumentKey: SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: [file], write: .sent, seriesEtag: "W/\"ser-1-0\"").jsonObject])
        let op = PendingCalendarOperation(
            operationType: .edit, accountId: account.id, eventId: "ser-1", calendarId: "primary",
            arguments: try JSONDecoder().decode([String: JSONValue].self, from: recordData), eventTitle: "Planning")
        let snapshot = account
        try await pool.write { conn in
            try snapshot.insert(conn)
            try op.insert(conn)
        }
        _ = try CalendarPutBackFiles.save(bytes, opId: op.id)
        let typed = ChatThreadKey.key(accountId: account.id, threadId: "typed-before")
        let after = ChatThreadKey.key(accountId: account.id, threadId: "typed-after")
        let words: @Sendable () async throws -> [String: String] = {
            try await pool.read { db in
                Dictionary(uniqueKeysWithValues: try ChatFieldWordsRecord.fetchAll(db).map { ($0.sessionId, $0.words) })
            }
        }
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed before"), to: typed) }
        await ChatFieldWords.shared.written()
        #expect(try await words() == [typed: "Typed before"], "control: the words are kept")

        // Refused (more saved files than warned of): the words stay, and the account's chats write again.
        await #expect(throws: AccountRemovalSavedFilesGrew(savedFiles: 1)) {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
        }
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: typed).words } == "Typed before")
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed after the refusal"), to: after) }
        await ChatFieldWords.shared.written()
        #expect(try await words() == [typed: "Typed before", after: "Typed after the refusal"],
                "the refused removal released its hold")

        // Committed: the words go from disk and the store, and new ones are never written.
        try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 1)
        #expect(try await pool.read { try Account.fetchCount($0) } == 0, "control: the removal committed")
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: typed).words } == "", "forgotten by the store")
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed after the removal"), to: after) }
        await ChatFieldWords.shared.written()
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: after).words } == "")
        #expect(try await words().isEmpty, "nothing of the removed account is written")
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
