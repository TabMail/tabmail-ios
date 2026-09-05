/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A3.5 (`IOS-QUEUE-008` follow-up) — the six decision sites Gmail's label-based
/// delta arm (`SyncEngineDeltaSync.gmailDeltaSync`) reaches for each changed
/// message: remove, skip removal, skip insert (pending destructive op), skip
/// insert (recently completed op), insert, and skip orphan reclaim.
///
/// ⚠️ **This suite was written to pin the `[MoveTrace] deltaSync` line each site
/// emitted. All six lines — and the file-private façade onto
/// `BackgroundSyncLogger.logQueue` that carried them — were DELETED on
/// 2026-09-05 by owner decision, so every expectation about them is gone from
/// this file.** They were emitted from INSIDE the changed-message
/// `dbPool.write` closure, and `AppLogStore.append` enqueues file I/O that no
/// SQLite `ROLLBACK` can retract: a batch that rolled back still left a durable
/// line claiming it had inserted, removed or skipped a message. A debug
/// instrument may miss a line, but it must not lie, and deletion was the
/// smallest resolution the round-5 reviewers themselves named. The delta arm now
/// writes no per-message line at all, which is also how the exported log
/// attributes a reappearing message: no `fullSync upsert` line for it means the
/// delta arm put it back.
///
/// What survives here is exactly what the deletion did not touch — each site's
/// DURABLE effect, which is the behaviour worth a test either way.
///
/// 🚨 These tests drive PRODUCTION `SyncEngine.performDeltaSync` end to end
/// (`FakeHTTP` + a real `GmailProvider` + a real `DatabasePool`-backed
/// `AppDatabase`), the same shape `SentDedupUserLabelCarryTests` uses and for the
/// same reason (`IOS-OUTBOX-002`): a re-implementation of the branch logic would
/// stay green no matter how the real branch broke.
///
/// For each of the six sites, one `@Test` drives TWO phases against two
/// independently-seeded message ids in the SAME fixture: once with the debug
/// gate UNLOCKED and once with it LOCKED. BOTH phases assert the same durable
/// DB effect, and each asserts the account's `lastHistoryId` advancing to that
/// phase's value — which proves the delta pass ran to completion rather than
/// bailing early, and that the debug gate changes nothing the branch does.
///
/// **A seventh site — the post-snapshot re-read guard, whose skip line read
/// `SKIPPING insert for id=… — already exists (post-snapshot)` — was REMOVED
/// 2026-09-04 together with that guard, and so is deliberately absent from this
/// file.** The `guard try MessageHeader.fetchOne(db,
/// key: header.id) == nil` that sat right before `header.insert` re-read, inside
/// the SAME `dbPool.write` closure, the exact key the orphan check
/// (`MessageHeader.fetchOne(db, key: header.id)`) had read moments earlier, and
/// three facts made those two reads unable to disagree — which is why no fixture
/// could ever construct the site, and why it was deleted rather than pinned:
///   * `DatabasePool.write` serializes real writers (and SQLite's write lock
///     excludes the NSE process), so no concurrent writer can interleave a write
///     between those two reads.
///   * The only `messageHeader` writer inside this SAME transaction between them
///     is the Sent-dedup block's DELETE, and its own SQL predicate
///     (`messageId <> header.messageId`) proves algebraically that the row it
///     deletes can never BE `header.id`. `messageHeader` has no triggers (v87
///     dropped them) and `MessageHeader` has no persistence callbacks.
///   * The outer loops (`for detail in details { for folder in folders {...} }`)
///     can never visit the same `(folder, messageId)` pair twice: `details` is
///     built from `Array(toFetch)`, and `toFetch` is a `Set<String>`, so no Gmail
///     message id repeats within one call.
/// The invariant now lives in the comment above `header.insert` in
/// `gmailDeltaSync` (and its Exchange twin); a colliding insert would surface as a
/// thrown `UNIQUE` that rolls the batch back with the cursor untouched, not as a
/// silent skip. Register: `IOS-LABEL-004` and its 2026-09-04 amendment.
///
/// `.serialized, .processGlobalState` — these tests replace `AppDatabase.shared`,
/// read/write the process-global `AppLogStore` file backing and
/// `DebugModeManager` gate override, and (Site 4) write
/// `AccountManager.shared.recentlyCompleted`; `.processGlobalState` also clears
/// that map at the start of every scoped test (`ProcessGlobalTestState.withLock`
/// → `AccountManager.shared.clearRecentlyCompletedForTesting()`), so Site 4's
/// entries can never leak into a sibling test.
@Suite("Gmail delta sync's six decision sites — all constructible, with the same durable effect whether or not debug logging is unlocked", .serialized, .processGlobalState)
struct GmailDeltaMoveTraceLogTests {

    // MARK: - Shared fixture helpers

    private static func makeAccountAndFolder(
        accountId: String,
        folderPath: String,
        historyCursor: String,
        pool: DatabasePool
    ) throws -> (account: Account, folder: Folder) {
        var account = Account(
            emailAddress: "\(accountId)@example.com",
            displayName: "A3.5 MoveTrace fixture",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = historyCursor
        let toInsertAccount = account

        let folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
        let toInsertFolder = folder

        try pool.write { db in
            try toInsertAccount.insert(db)
            try toInsertFolder.insert(db)
        }
        return (account, folder)
    }

    private static func makeHeader(
        messageId: String,
        accountId: String,
        folderId: String,
        folderPath: String
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "A3.5 MoveTrace fixture \(messageId)",
            from: "A3.5 Fixture",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: "a3.5 movetrace fixture",
            folderId: folderId,
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: true
        )
        header.headerComplete = true
        return header
    }

    private static func historyJSON(newHistoryId: String, messageId: String) -> String {
        """
        {
          "historyId": "\(newHistoryId)",
          "history": [
            { "messagesAdded": [ { "message": { "id": "\(messageId)" } } ] }
          ]
        }
        """
    }

    private static func messageDetailJSON(id: String, labelIds: [String], rfc822: String, subject: String) -> String {
        let labelIdsJSON = labelIds.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "id": "\(id)",
          "threadId": "thr-\(id)",
          "labelIds": [\(labelIdsJSON)],
          "snippet": "",
          "internalDate": "1700000000000",
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              { "name": "Subject", "value": "\(subject)" },
              { "name": "From", "value": "A3.5 Fixture <sender@example.com>" },
              { "name": "To", "value": "recipient@example.com" },
              { "name": "Message-Id", "value": "\(rfc822)" }
            ]
          }
        }
        """
    }

    private static func headerExists(_ headerId: String, pool: DatabasePool) throws -> Bool {
        try pool.read { db in try MessageHeader.fetchOne(db, key: headerId) != nil }
    }

    private static func currentLastHistoryId(accountId: String, pool: DatabasePool) throws -> String? {
        try pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastHistoryId
    }

    // MARK: - Site 1: existsLocally && !belongsInFolder && !isPendingAny → removes

    @Test("Gmail delta sync removes a header that fell out of its folder's labels — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncRemovesHeaderNoLongerInFolderLabels() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site1"
        let folderPath = "INBOX"
        let msgOpen = "s1-open-msg"
        let msgClosed = "s1-closed-msg"

        let (account, folder) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)

        // Both ids already exist LOCALLY in the target folder, and neither has a
        // PendingOperation — existsLocally && !belongsInFolder && !isPendingAny
        // once the server response drops the folder's label.
        try await pool.write { db in
            try Self.makeHeader(messageId: msgOpen, accountId: accountId, folderId: folder.id, folderPath: folderPath).insert(db)
            try Self.makeHeader(messageId: msgClosed, accountId: accountId, folderId: folder.id, folderPath: folderPath).insert(db)
        }

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: [], rfc822: "<\(msgOpen)@example.com>", subject: "site1 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        #expect(try Self.headerExists(openHeaderId, pool: pool) == false,
                "Site 1: the header must be REMOVED once it fell out of the folder's labels")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: [], rfc822: "<\(msgClosed)@example.com>", subject: "site1 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)
        #expect(try Self.headerExists(closedHeaderId, pool: pool) == false,
                "non-vacuity: the locked-gate pass must still have removed the header")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }

    // MARK: - Site 2: existsLocally && !belongsInFolder && isPendingAny → skips removal

    @Test("Gmail delta sync SKIPS removing a header out of its folder's labels when a pending op protects it — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncSkipsRemovalWhenPendingOpProtectsHeader() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site2"
        let folderPath = "INBOX"
        let msgOpen = "s2-open-msg"
        let msgClosed = "s2-closed-msg"

        let (account, folder) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)

        try await pool.write { db in
            try Self.makeHeader(messageId: msgOpen, accountId: accountId, folderId: folder.id, folderPath: folderPath).insert(db)
            try Self.makeHeader(messageId: msgClosed, accountId: accountId, folderId: folder.id, folderPath: folderPath).insert(db)
            // Any pending op protects — a non-destructive flag op keeps this
            // fixture visibly distinct from Site 3/6's destructive ops.
            try PendingOperation(type: .markRead, messageIds: [msgOpen], accountId: accountId, folderPath: folderPath).insert(db)
            try PendingOperation(type: .markRead, messageIds: [msgClosed], accountId: accountId, folderPath: folderPath).insert(db)
        }

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: [], rfc822: "<\(msgOpen)@example.com>", subject: "site2 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        #expect(try Self.headerExists(openHeaderId, pool: pool),
                "Site 2: the header must SURVIVE — the pending op must block the removal")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: [], rfc822: "<\(msgClosed)@example.com>", subject: "site2 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)
        #expect(try Self.headerExists(closedHeaderId, pool: pool),
                "non-vacuity: the locked-gate pass must still have preserved the header")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }

    // MARK: - Site 3: !existsLocally && belongsInFolder && isPendingDestructive → skips insert

    @Test("Gmail delta sync SKIPS inserting a header with a pending destructive op on its own identity — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncSkipsInsertWhenPendingDestructiveOpBlocksIt() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site3"
        let folderPath = "INBOX"
        let msgOpen = "s3-open-msg"
        let msgClosed = "s3-closed-msg"

        let (account, _) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)

        try await pool.write { db in
            // Destructive ops key by the provider's native address on Gmail — a
            // bare messageId, matching `info.messageId` directly.
            try PendingOperation(type: .archive, messageIds: [msgOpen], accountId: accountId, folderPath: folderPath).insert(db)
            try PendingOperation(type: .archive, messageIds: [msgClosed], accountId: accountId, folderPath: folderPath).insert(db)
        }

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: ["INBOX"], rfc822: "<\(msgOpen)@example.com>", subject: "site3 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        #expect(try Self.headerExists(openHeaderId, pool: pool) == false,
                "Site 3: the header must NOT be inserted — the pending destructive op must block it")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: ["INBOX"], rfc822: "<\(msgClosed)@example.com>", subject: "site3 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)
        #expect(try Self.headerExists(closedHeaderId, pool: pool) == false,
                "non-vacuity: the locked-gate pass must still have blocked the insert")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }

    // MARK: - Site 4: !existsLocally && belongsInFolder && recentlyCompleted → skips insert

    @Test("Gmail delta sync SKIPS inserting a header the queue just completed — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncSkipsInsertWhenRecentlyCompletedProtectsIt() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site4"
        let folderPath = "INBOX"
        let msgOpen = "s4-open-msg"
        let msgClosed = "s4-closed-msg"

        let (account, _) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)

        // No PendingOperation at all — `recentlyCompleted` is the only protection,
        // so this fixture cannot be confused with Site 3's.
        await AccountManager.shared.recordRecentlyCompleted(messageIds: [msgOpen, msgClosed])

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: ["INBOX"], rfc822: "<\(msgOpen)@example.com>", subject: "site4 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        #expect(try Self.headerExists(openHeaderId, pool: pool) == false,
                "Site 4: the header must NOT be inserted — the recently-completed protection must block it")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: ["INBOX"], rfc822: "<\(msgClosed)@example.com>", subject: "site4 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)
        #expect(try Self.headerExists(closedHeaderId, pool: pool) == false,
                "non-vacuity: the locked-gate pass must still have blocked the insert")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }

    // MARK: - Site 5: !existsLocally && belongsInFolder && !isPendingDestructive, no orphan → inserts

    @Test("Gmail delta sync inserts a genuinely new header when nothing local, pending or orphaned blocks it — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncInsertsNewHeaderWithNoOrphanOrPending() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site5"
        let folderPath = "INBOX"
        let msgOpen = "s5-open-msg"
        let msgClosed = "s5-closed-msg"

        let (account, _) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)
        // No header, no PendingOperation, no recentlyCompleted entry for either id.

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: ["INBOX"], rfc822: "<\(msgOpen)@example.com>", subject: "site5 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        #expect(try Self.headerExists(openHeaderId, pool: pool),
                "Site 5: the header must be INSERTED — nothing blocks it")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: ["INBOX"], rfc822: "<\(msgClosed)@example.com>", subject: "site5 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedHeaderId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)
        #expect(try Self.headerExists(closedHeaderId, pool: pool),
                "non-vacuity: the locked-gate pass must still have inserted the header")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }

    // MARK: - Site 6: orphan row found, orphan's OWN identity has a pending destructive op → skips reclaim

    @Test("Gmail delta sync SKIPS reclaiming an orphaned row whose OWN identity has a pending destructive op — identically whether or not debug logging is unlocked")
    func gmailDeltaSyncSkipsOrphanReclaimWhenOrphanHasPendingDestructiveOp() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "a35site6"
        let folderPath = "INBOX"
        let msgOpen = "s6-open-msg"
        let msgClosed = "s6-closed-msg"
        let orphanTagOpen = "s6-orphan-open-tag"
        let orphanTagClosed = "s6-orphan-closed-tag"
        let staleFolderId = "\(accountId):STALE"

        let (account, folder) = try Self.makeAccountAndFolder(
            accountId: accountId, folderPath: folderPath, historyCursor: "1000", pool: pool)

        // The orphan reclaim guard (`SyncEngineDeltaSync.swift`) finds a row by
        // PRIMARY KEY (`MessageHeader.fetchOne(db, key: header.id)`), independent
        // of the row's OWN `messageId`/`folderId` columns — `id` encodes
        // `(accountId, folderPath, messageId)` at construction time but is a
        // mutable `var`, so a fixture can force the PK to collide with a FUTURE
        // insert's key while giving the row its own distinct `messageId` (used
        // only for the orphan-pending check) and a stale `folderId` (so the
        // ordinary `existsLocally` query, which filters on the `messageId` AND
        // `folderId` COLUMNS, never finds it — it is reached only via the PK
        // fetch). This mirrors the real orphan shape (`SyncEngineDeltaSync.swift`
        // comment: "left behind by no-op optimistic move") without adding any new
        // production surface.
        let forcedOpenId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgOpen)
        let forcedClosedId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: msgClosed)

        try await pool.write { db in
            var orphanOpen = Self.makeHeader(messageId: orphanTagOpen, accountId: accountId, folderId: staleFolderId, folderPath: folderPath)
            orphanOpen.rfc822MessageId = "<\(orphanTagOpen)@example.com>"
            orphanOpen.id = forcedOpenId
            try orphanOpen.insert(db)

            var orphanClosed = Self.makeHeader(messageId: orphanTagClosed, accountId: accountId, folderId: staleFolderId, folderPath: folderPath)
            orphanClosed.rfc822MessageId = "<\(orphanTagClosed)@example.com>"
            orphanClosed.id = forcedClosedId
            try orphanClosed.insert(db)

            // Destructive op keyed on the ORPHAN's OWN identity, NOT on the
            // incoming detail's identity — this is what makes `orphanIsPending`
            // true while the OUTER `isPendingDestructive` (checked against
            // `info.messageId`/`info.rfc822MessageId`) stays false, so execution
            // reaches Site 5's arm and then Site 6's nested check rather than
            // being intercepted earlier by Site 3.
            try PendingOperation(type: .archive, messageIds: [orphanTagOpen], accountId: accountId, folderPath: folderPath).insert(db)
            try PendingOperation(type: .archive, messageIds: [orphanTagClosed], accountId: accountId, folderPath: folderPath).insert(db)
        }

        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("movetracelog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Phase OPEN
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let openScenario = FakeHTTP.Scenario()
        openScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1001", messageId: msgOpen)))
        openScenario.register(path: "/messages/\(msgOpen)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgOpen, labelIds: ["INBOX"], rfc822: "<\(msgOpen)@example.com>", subject: "site6 open")))
        let openProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: openScenario.session)
        let openOutcome = try await SyncEngine().performDeltaSync(account: account, provider: openProvider)
        openScenario.close()
        #expect(openOutcome.succeeded, "precondition: the delta pass must have run")

        let openOrphanRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: forcedOpenId) }
        #expect(openOrphanRow?.folderId == staleFolderId,
                "Site 6: the orphan reclaim must be SKIPPED — folderId must stay stale, not reclaimed to \(folder.id)")
        #expect(openOrphanRow?.messageId == orphanTagOpen,
                "Site 6: the orphan reclaim must be SKIPPED — messageId must stay the orphan's own, not overwritten to \(msgOpen)")

        AppLogStore.clear()

        // Phase CLOSED
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let closedScenario = FakeHTTP.Scenario()
        closedScenario.register(path: "/history", method: "GET", response: .json(raw: Self.historyJSON(newHistoryId: "1002", messageId: msgClosed)))
        closedScenario.register(path: "/messages/\(msgClosed)", method: "GET", response: .json(raw: Self.messageDetailJSON(id: msgClosed, labelIds: ["INBOX"], rfc822: "<\(msgClosed)@example.com>", subject: "site6 closed")))
        let closedProvider = GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: closedScenario.session)
        let closedOutcome = try await SyncEngine().performDeltaSync(account: account, provider: closedProvider)
        closedScenario.close()
        #expect(closedOutcome.succeeded, "precondition: the locked-gate delta pass must have run too")

        let closedOrphanRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: forcedClosedId) }
        #expect(closedOrphanRow?.folderId == staleFolderId,
                "non-vacuity: the locked-gate pass must still have skipped the reclaim")
        #expect(closedOrphanRow?.messageId == orphanTagClosed,
                "non-vacuity: the locked-gate pass must still have skipped the reclaim")
        #expect(try Self.currentLastHistoryId(accountId: accountId, pool: pool) == "1002",
                "non-vacuity: the whole delta pass, including its final historyId write, must have completed")
    }
}
