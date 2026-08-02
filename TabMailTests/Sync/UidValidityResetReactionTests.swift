/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T4.S6 — the D5 purge-and-resync reaction, asserted on SYSTEM END STATES.
///
/// Every expectation here names a durable property of the database after the
/// reaction ran, never a mechanism ("the flag was written", "the guard returned
/// false"). A mechanism-pinning test inherits a wrong spec's error and stays green
/// on a broken system; this project has shipped two regressions that way.
///
/// The four invariants under test:
///  1. **A queued user op survives the reaction.** An op carrying a durable rfc822
///     identity is still in `pendingOperation` after the folder has been purged,
///     re-stamped and resynced. The purge is forbidden from touching the queue —
///     the row IS the user's intention (Law 5).
///  2. **An aborted reaction leaves the folder RETRYABLE, not half-reset.** After a
///     failure between the purge and the stamp, `uidValidityResetPendingAt` is
///     still set and `lastKnownUidValidity` still holds the OLD epoch, so the next
///     full-sync pass re-drives instead of merging new-epoch mail under an old
///     stamp.
///  3. **The fresh epoch, the exit from reset, and the invalidation of
///     address-only intentions land TOGETHER or not at all.** They share one write
///     transaction. Split across two commits, the window between them un-parks the
///     drain over UIDs from a numbering the server has discarded — C3.
///  4. **A purge that could not run ABORTS before the stamp.** Clearing the flag
///     over undeleted old-epoch rows leaves no re-drive and no second line of
///     defence.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, mutates
/// `AccountManager.shared`'s provider table and change-handler seam, and (for the
/// end-to-end cases) binds a listening socket via `FakeIMAPServer`.
@Suite("T4.S6 — the UIDVALIDITY purge-and-resync reaction", .serialized, .processGlobalState)
struct UidValidityResetReactionTests {

    // MARK: - Fixture

    private static let oldEpoch = 700_001
    private static let newEpoch = 700_002

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: reset fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        reset fixture body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func imapProvider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    /// Insert a `PendingOperation` verbatim (bypassing the admission guards, which
    /// have their own tests) so the queue's CONTENTS are the thing under test.
    private static func insertOp(
        id: String, type: OperationType, messageIds: [String],
        accountId: String, folderPath: String, destinationPath: String? = nil,
        pool: DatabasePool
    ) throws {
        var op = PendingOperation(
            type: type, messageIds: messageIds, accountId: accountId,
            folderPath: folderPath, destinationPath: destinationPath)
        op.id = id
        let toInsert = op
        try pool.write { db in try toInsert.insert(db) }
    }

    private static func opIds(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in Set(try PendingOperation.fetchAll(db).map(\.id)) }
    }

    /// Registers the provider on the shared `AccountManager` and cleans up.
    ///
    /// `@MainActor` so `body` stays in the CALLER's isolation domain: every test
    /// below is `@MainActor`, and a nonisolated helper would make the closure a
    /// value sent across an isolation boundary (`sending value of non-Sendable
    /// type '() async -> ()'`).
    @MainActor
    private static func withRegisteredProvider(
        accountId: String, provider: any EmailProvider, _ body: () async throws -> Void
    ) async rethrows {
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        try await body()
    }

    // MARK: - 1/3 — the happy path, and what survives it

    /// 🚨 INVARIANTS 1 + 3 together, on the end state of one real run.
    ///
    /// The folder starts stamped with `oldEpoch` and holding three old-epoch
    /// headers; the server is on `newEpoch` with entirely different mail. After the
    /// reaction:
    ///  - **no old-epoch header remains** — they addressed a numbering that no
    ///    longer exists, and leaving one lets a reused UID serve one message's
    ///    content as another's;
    ///  - **the stored epoch IS the fresh one and the quarantine is gone** — the
    ///    two are written by one transaction, so observing the second without the
    ///    first is impossible by construction;
    ///  - **the identity-carrying op is still queued** — `IMAPProvider.resolveUID`
    ///    re-resolves a non-numeric id by SEARCH, so the user's intention lands on
    ///    the right message under the new numbering. Dropping it would be the
    ///    NEVER-DROP-USER-INTENTION violation;
    ///  - **the address-only op is gone** — its every id is a bare UID in the
    ///    discarded numbering, so executing it would mutate whichever message the
    ///    new epoch put there (C3). Constraint C5 makes dropping it the correct
    ///    resolution at an identity-reset boundary;
    ///  - **the op belonging to another folder is untouched** — the sweep is
    ///    folder-scoped, and a wider one would be a mass intention drop.
    @Test("A reaction purges the old epoch, stamps the new one, and keeps every intention it can still resolve")
    @MainActor
    func reactionPurgesStampsAndPreservesResolvableIntentions() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9001, id: "post-reset-9001@example.com")],
            "Archive": []
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-happy"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 3, lastKnownUidNext: 104, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [101, 102, 103], pool: pool)

        try Self.insertOp(id: "op-identity", type: .move,
                          messageIds: ["epoch-fixture-101@example.com"],
                          accountId: accountId, folderPath: "INBOX",
                          destinationPath: "Archive", pool: pool)
        try Self.insertOp(id: "op-address-only", type: .markRead,
                          messageIds: ["102"],
                          accountId: accountId, folderPath: "INBOX", pool: pool)
        try Self.insertOp(id: "op-other-folder", type: .markRead,
                          messageIds: ["55"],
                          accountId: accountId, folderPath: "Archive", pool: pool)

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let folderId = "\(accountId):INBOX"
        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        let survivingOldEpochUIDs = try await pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter([ "101", "102", "103" ].contains(Column("messageId")))
                .fetchCount(db)
        }
        #expect(survivingOldEpochUIDs == 0,
                """
                an old-epoch header survived the reaction. Its bare UID addresses a numbering \
                the server has discarded, so any later gesture on it resolves against whichever \
                message the new epoch put at that number — C3.
                """)

        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                "the folder was not re-stamped with the epoch its rows now belong to")
        #expect(folder?.uidValidityResetPendingAt == nil,
                "the folder is still quarantined after a reaction that completed")

        let remaining = try Self.opIds(pool)
        #expect(remaining.contains("op-identity"),
                """
                a queued op carrying a durable rfc822 identity was DROPPED by the reaction. It is \
                still resolvable — `IMAPProvider.resolveUID` SEARCHes a non-numeric id — so the \
                user's intention must survive (NEVER DROP USER INTENTION, Law 5).
                """)
        #expect(!remaining.contains("op-address-only"),
                """
                an address-only op (every id a bare UID) survived the epoch stamp. Executing it \
                now mutates whichever message the NEW numbering placed at that UID — C3. C5 makes \
                dropping it at an identity-reset boundary the correct resolution.
                """)
        #expect(remaining.contains("op-other-folder"),
                "the sweep reached a folder the reaction was not resetting — that is a mass intention drop")
    }

    // MARK: - 2/4 — the abort leg

    /// 🚨 INVARIANTS 2 + 4. A failure injected between the purge and the stamp
    /// (`afterPurgeBeforeStamp`) is what a failed FTS or body-asset purge, a DB
    /// error, or a process kill all look like from the folder's point of view.
    ///
    /// The end state must be RETRYABLE:
    ///  - `uidValidityResetPendingAt` still SET, so full sync's per-folder loop
    ///    branches into the reaction again instead of running an ordinary pass;
    ///  - `lastKnownUidValidity` still the OLD epoch, so nothing downstream reads
    ///    the folder as healed;
    ///  - the address-only op still QUEUED and parked, not dropped — it is only
    ///    invalidated by the stamp that never happened, so an abort must not
    ///    consume the user's intention on its way out.
    ///
    /// The last point is the mirror image this suite exists to catch: an
    /// implementation that swept the ops in step 3 (with the purge) rather than in
    /// step 5 (with the stamp) would pass every OTHER expectation here.
    @Test("A reaction that fails before the stamp leaves the folder retryable, not half-reset")
    @MainActor
    func abortBeforeStampLeavesTheFolderRetryable() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9001, id: "post-reset-9001@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-abort"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 2, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [201, 202], pool: pool)
        try Self.insertOp(id: "op-abort-address-only", type: .markRead,
                          messageIds: ["201"],
                          accountId: accountId, folderPath: "INBOX", pool: pool)

        let folderId = "\(accountId):INBOX"
        struct InjectedPurgeFailure: Error {}
        AccountManager.uidValidityResetCheckpointHooksForTesting.withLock {
            $0[.afterPurgeBeforeStamp(folderId: folderId)] = { throw InjectedPurgeFailure() }
        }
        defer { AccountManager.uidValidityResetCheckpointHooksForTesting.withLock { $0 = [:] } }

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.uidValidityResetPendingAt != nil,
                """
                the quarantine was cleared by an ABORTED reaction. Nothing re-drives the folder \
                now: it has been purged, its epoch still describes rows that no longer exist, and \
                the next ordinary sync pass will merge NEW-epoch mail under the OLD stamp.
                """)
        #expect(folder?.lastKnownUidValidity == Self.oldEpoch,
                """
                the fresh epoch was stamped by a reaction that aborted before its stamp step. The \
                stamp and the exit from reset must land together or not at all.
                """)
        #expect(try Self.opIds(pool).contains("op-abort-address-only"),
                """
                an aborted reaction consumed the user's queued intention. Address-only ops are \
                invalidated by the STAMP (which never happened here), not by the purge — an \
                implementation that sweeps them with the purge drops intention on every retry.
                """)
        #expect(await !AccountManager.shared.isUidValidityReactionInFlightForTesting(folderId: folderId),
                "the in-memory single-flight entry leaked — no later trigger could ever re-drive this folder")
    }

    // MARK: - The re-drive path

    /// The abort above is only survivable because something re-drives it. A folder
    /// left quarantined must reach a COMPLETED reaction on a second attempt with no
    /// new trigger information — the entry point re-enters at the barrier because
    /// the flag is already set, and its trigger-validation preamble is SKIPPED for a
    /// quarantined folder (an already-armed folder is unambiguous evidence).
    @Test("A folder left quarantined by an interrupted attempt completes on re-drive")
    @MainActor
    func quarantinedFolderCompletesOnRedrive() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9101, id: "redrive-9101@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-redrive"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [301], pool: pool)
        // The durable state an interrupted attempt leaves behind.
        try await pool.write { db in
            var folder = try #require(try Folder.fetchOne(db, key: "\(accountId):INBOX"))
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.uidValidityResetPendingAt == nil,
                "a re-drive of an already-quarantined folder did not complete — the folder is bricked, not retryable")
        #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                "the re-drive completed without stamping the epoch its rows now belong to")
    }

    // MARK: - Trigger validation (over-refusal controls)

    /// THE MIRROR IMAGE of the purge: the reaction must not fire on a HEALTHY
    /// folder. Stored epoch equals the live one, no quarantine — the trigger was
    /// stale (already resolved, or a queued refusal that lost the race). Purging
    /// here would destroy mail for nothing.
    ///
    /// Passes on both trees; it is an over-refusal control, not a red proof.
    @Test("Control: a trigger whose premise no longer holds purges nothing")
    @MainActor
    func staleTriggerPurgesNothing() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 401, id: "epoch-fixture-401@example.com")]
        ])
        server.setUidValidity(Self.oldEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-stale-trigger"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [401], pool: pool)

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "INBOX", pool: pool) == 1,
                "a reaction fired on a folder whose stored epoch AGREES with the live one destroyed its mail")
        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.uidValidityResetPendingAt == nil,
                "a stale trigger quarantined a healthy folder")
    }

    /// A NEVER-OBSERVED folder (`lastKnownUidValidity == nil`) has no epoch to
    /// reset FROM. The reaction refuses to start, and — stated plainly rather than
    /// implied — this leaves the "nil epoch over pre-existing headers" residual
    /// OPEN. The reference has the identical refusal, so porting the reaction does
    /// not close it; closing it needs a separate epoch-advancement protocol.
    @Test("Control: the reaction refuses to start on a folder that has never been observed")
    @MainActor
    func nilEpochFolderIsRefused() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 501, id: "nil-epoch-501@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-nil-epoch"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: nil)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [501], pool: pool)

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "INBOX", pool: pool) == 1,
                "the reaction purged a folder it has no epoch premise for")
        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.uidValidityResetPendingAt == nil,
                "a folder with no epoch to reset from was quarantined")
        #expect(folder?.lastKnownUidValidity == nil,
                "the reaction stamped an epoch onto rows it never proved belong to it")
    }

    // MARK: - The trigger: the merge pass's in-transaction epoch guard

    /// 🚨 The merge pass must ABANDON on a proven turnover and TRIGGER the reaction.
    ///
    /// Asserted on the two things that matter to the system: the local mail is
    /// still there (the sweep's complete-knowledge branch would otherwise delete
    /// every row, since none of them come back in the fetch) and the reaction was
    /// asked to run. The handler is captured rather than executed so the assertion
    /// is about the TRIGGER, not about a second subsystem's success.
    @Test("A merge pass on a turned-over folder deletes nothing and triggers the reaction")
    @MainActor
    func mergePassAbandonsAndTriggersOnTurnover() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-merge-guard"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 3, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [601, 602, 603], pool: pool)

        let fired = Mutex<[(String, String, UInt32, UInt32)]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { acct, path, stored, observed in
            fired.withLock { $0.append((acct, path, stored, observed)) }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([])
        await mock.setMockedBoundFetchEpoch(UInt32(Self.newEpoch), folderPath: "Archive")

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "Archive", pool: pool) == 3,
                """
                a UIDVALIDITY turnover deleted local mail. The windowed sweep classifies "the \
                server did not return UID n" as stale, which on a re-created mailbox is true of \
                EVERY local row — the pass must be abandoned before it reaches that decision.
                """)
        #expect(result.staleIds.isEmpty && result.newHeaders.isEmpty,
                "the abandoned pass still reported work — its caller would act on it")

        let events = fired.withLock { $0 }
        #expect(events.count == 1, "the reaction was not triggered exactly once by the turnover")
        guard events.count == 1 else { return }
        #expect(events[0].0 == accountId && events[0].1 == "Archive")
        #expect(events[0].2 == UInt32(Self.oldEpoch) && events[0].3 == UInt32(Self.newEpoch))
    }

    /// 🚨 The QUARANTINE half of the §5.5 in-txn guard, exercised through the OTHER
    /// door into `runSyncMessages`: `SyncEngine.syncFolderMessages`.
    ///
    /// The full-sync and delta-sync loops branch into the reaction before they reach
    /// the merge pass, so a guard living only in those loops would LOOK complete —
    /// but `syncFolderMessages` is also called by on-demand folder navigation
    /// (`AccountManagerFetch`), the detail view, the outbox drain and the op drain,
    /// none of which read the flag. A user merely OPENING a quarantined folder would
    /// then insert NEW-epoch headers under the OLD stamp, which is exactly the state
    /// a bare-UID durable op mutates the wrong message from (C3).
    ///
    /// The epochs AGREE here on purpose, so the epoch half of the guard cannot be
    /// what produces the green.
    @Test("A quarantined folder's merge pass is refused at the direct entry point too")
    @MainActor
    func quarantinedFolderRefusesTheDirectMergeEntryPoint() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-direct-entry"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 3, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [101, 102, 103], pool: pool)
        try await pool.write { db in
            guard var folder = try Folder.fetchOne(db, key: "\(accountId):Archive") else { return }
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }

        let mock = MockEmailProvider()
        // The server AGREES with the stored epoch and offers ONE message. Without the
        // quarantine term the complete-knowledge stale sweep deletes all three local
        // rows and inserts this one.
        await mock.setMockedBoundFetchEpoch(UInt32(Self.oldEpoch), folderPath: "Archive")
        await mock.setFetchMessagesResult([
            MessageHeaderInfo(
                messageId: "900", rfc822MessageId: "post-quarantine@example.com",
                inReplyTo: nil, references: [], threadId: nil, subject: "new epoch",
                from: "Sender", fromAddress: "sender@example.com", to: "recipient@example.com",
                cc: "", bcc: "", replyTo: nil,
                date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "new epoch",
                isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil)
        ])

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        let engine = SyncEngine()
        try await engine.syncFolderMessages(folder: folder, provider: mock)

        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "Archive", pool: pool) == 3,
                """
                the merge pass ran on a QUARANTINED folder. The reaction owns this \
                folder's rows; anything that merges into it under the old stamp \
                recreates the exact mixed-epoch state the quarantine exists to prevent.
                """)
        let survivingNew = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: MessageIdentity.headerId(
                accountId: accountId, folderPath: "Archive", messageId: "900"))
        }
        #expect(survivingNew == nil, "a new-epoch header was inserted into a quarantined folder")
        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool)
        #expect(after?.uidValidityResetPendingAt != nil,
                "the merge pass cleared the quarantine — only the reaction's step-5 stamp may")
    }

    /// THE MIRROR IMAGE of the guard above, and the reason it tests BOTH sides for
    /// known values: a folder whose SELECT reported no epoch at all (non-UIDPLUS
    /// server, or a fetch that could not observe one) must still sync normally. A
    /// guard that refused on an unknown would silently stop every such account.
    ///
    /// Passes on both trees — an over-refusal control, not a red proof.
    @Test("Control: an unknown observed epoch does not abandon the pass")
    @MainActor
    func unknownObservedEpochStillSyncs() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-unknown-epoch"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 0, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [701, 702, 703], pool: pool)

        let fired = Mutex(0)
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, _ in
            fired.withLock { $0 += 1 }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([])
        await mock.setMockedBoundFetchEpoch(nil, folderPath: "Archive")
        await mock.setMockedUidValidity(nil, folderPath: "Archive")

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        #expect(fired.withLock { $0 } == 0,
                "a folder whose SELECT reported no epoch was treated as a turnover — that purges healthy folders")
        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "Archive", pool: pool) == 0,
                """
                the ordinary stale sweep stopped working. This control is the guard-rail: the \
                epoch guard must not become a global off-switch for deletion.
                """)
    }

    // MARK: - Admission and drain behaviour under quarantine

    /// A NEW gesture on a quarantined folder is refused. The refusal is fail-closed
    /// and TRANSIENT: the flag is cleared by the reaction's stamp, and full sync
    /// re-drives an interrupted reaction on every cycle.
    @Test("A new gesture on a quarantined folder is refused, and admitted again once the quarantine lifts")
    @MainActor
    func newGestureRefusedWhileQuarantined() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-admission"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)

        let admittedBefore = try await pool.read { db in
            try AccountManager.newGestureRefusedForUnknownEpoch(
                accountId: accountId, folderPath: "INBOX", db: db)
        }
        #expect(!admittedBefore,
                "a healthy IMAP folder with a known epoch was refused — that is a bricked account, not a guard")

        try await pool.write { db in
            var folder = try #require(try Folder.fetchOne(db, key: "\(accountId):INBOX"))
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }
        let refusedDuring = try await pool.read { db in
            try AccountManager.newGestureRefusedForUnknownEpoch(
                accountId: accountId, folderPath: "INBOX", db: db)
        }
        #expect(refusedDuring,
                """
                a gesture was admitted against a folder mid UIDVALIDITY reset. Its stored epoch is \
                non-nil but ABANDONED, so the UID this gesture records addresses whichever message \
                the new numbering puts there — C3.
                """)

        try await pool.write { db in
            var folder = try #require(try Folder.fetchOne(db, key: "\(accountId):INBOX"))
            folder.uidValidityResetPendingAt = nil
            try folder.update(db)
        }
        let admittedAfter = try await pool.read { db in
            try AccountManager.newGestureRefusedForUnknownEpoch(
                accountId: accountId, folderPath: "INBOX", db: db)
        }
        #expect(!admittedAfter,
                "the refusal outlived the quarantine — a TRANSIENT guard that never lifts is a PERMANENT brick")
    }

    /// The drain PARKS rather than drops. After a drain attempt against a
    /// quarantined folder the op row must still be present AND still `queued` (not
    /// `inFlight`, not `failed`, retry counters untouched) — anything else either
    /// executes it against the wrong numbering or ages the user's intention out.
    @Test("The drain parks a queued op for a quarantined folder without dropping or ageing it")
    @MainActor
    func drainParksOpsForQuarantinedFolder() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6-park"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try await pool.write { db in
            var folder = try #require(try Folder.fetchOne(db, key: "\(accountId):INBOX"))
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }
        try Self.insertOp(id: "op-parked", type: .markRead, messageIds: ["801"],
                          accountId: accountId, folderPath: "INBOX", pool: pool)
        try Self.insertOp(id: "op-runnable", type: .markRead, messageIds: ["802"],
                          accountId: accountId, folderPath: "Archive", pool: pool)

        let mock = MockEmailProvider()
        await Self.withRegisteredProvider(accountId: accountId, provider: mock) {
            await AccountManager.shared.drainPendingQueue()
        }

        let parked = try await pool.read { db in try PendingOperation.fetchOne(db, key: "op-parked") }
        #expect(parked != nil,
                """
                the drain DROPPED a queued op because its folder was mid UIDVALIDITY reset. The row \
                IS the user's intention — a reset must park it, never consume it (Law 5).
                """)
        #expect(parked?.status == PendingStatus.queued.rawValue,
                "the parked op did not stay `queued` — a stranded `inFlight` row wedges the queue")
        #expect(parked?.retryCount == 0,
                "the parked op's retry budget was spent — parking must not age intention toward `failed`")
        let calls = await mock.callLogSnapshot()
        #expect(!calls.contains { $0.contains("801") },
                "the parked op was EXECUTED against the folder being reset — its UID belongs to the discarded numbering (C3)")
        let runnableStillQueued = try await pool.read { db in
            try PendingOperation.fetchOne(db, key: "op-runnable") != nil
        }
        #expect(!runnableStillQueued || calls.contains { $0.contains("802") },
                "the park leaked to an unrelated folder — quarantine is per-folder, not per-account")
    }

    // MARK: - The address-only classifier

    /// The discriminator mirrors `MessageHeader.stableId`: an op whose ids are all
    /// bare numeric UIDs carries no identity that can be re-resolved under a new
    /// numbering. Everything else — an rfc822 id, a local draft UUID, a mixed set,
    /// or no ids at all — must be preserved.
    @Test("Only ops whose every id is a bare UID count as address-only")
    func addressOnlyClassification() {
        func op(_ ids: [String]) -> PendingOperation {
            PendingOperation(type: .markRead, messageIds: ids, accountId: "a", folderPath: "INBOX")
        }
        #expect(AccountManager.opIsAddressOnly(op(["101"])))
        #expect(AccountManager.opIsAddressOnly(op(["101", "102"])))
        #expect(!AccountManager.opIsAddressOnly(op(["msg-1@example.com"])),
                "an rfc822 identity re-resolves by SEARCH under any epoch — dropping it drops intention")
        #expect(!AccountManager.opIsAddressOnly(op(["101", "msg-1@example.com"])),
                "a mixed op still carries a resolvable identity; dropping the whole op over one bare UID over-drops")
        #expect(!AccountManager.opIsAddressOnly(op([])),
                "an op with no ids has nothing to be wrong about — deleting it drops intention for free")
        #expect(!AccountManager.opIsAddressOnly(op(["3F5A-DRAFT-UUID"])),
                "a local draft key is not a UID and survives every epoch")
    }
}

/// T5.11 supersedes the former RFC-collision veto in this suite. Within one
/// bound UIDVALIDITY epoch the provider `(mailbox, UID)` owns the row; RFC
/// Message-ID is metadata and cannot establish a parallel identity authority.
/// A nil RFC still carries no metadata signal and therefore cannot erase a
/// stored value.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`.
@Suite("A provider-proven UID owns its row", .serialized, .processGlobalState)
struct ProviderAddressMergeAuthorityTests {

    private static let storedDate = Date(timeIntervalSince1970: 1_600_000_000)
    private static let incomingDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func insertStoredRow(
        accountId: String, path: String, uid: String, rfc822: String?, pool: DatabasePool
    ) throws {
        var header = MessageHeader(
            messageId: uid, subject: "stored subject", from: "Stored Sender",
            fromAddress: "stored-sender@example.com", to: "stored-to@example.com",
            date: storedDate, snippet: "stored snippet",
            folderId: "\(accountId):\(path)", accountId: accountId, folderPath: path,
            isInInbox: false
        )
        header.rfc822MessageId = rfc822
        header.cc = "stored-cc@example.com"
        header.headerComplete = true
        header.isRead = false
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
    }

    private static func incoming(uid: String, rfc822: String?) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid,
            rfc822MessageId: rfc822,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "incoming subject",
            from: "Incoming Sender",
            fromAddress: "incoming-sender@example.com",
            to: "incoming-to@example.com",
            cc: "incoming-cc@example.com",
            bcc: "",
            replyTo: nil,
            date: incomingDate,
            snippet: "incoming snippet",
            isRead: true,
            isFlagged: true,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
    }

    private static func storedRow(accountId: String, path: String, uid: String, pool: DatabasePool) throws -> MessageHeader? {
        try pool.read { db in
            try MessageHeader.fetchOne(db, key: MessageIdentity.headerId(
                accountId: accountId, folderPath: path, messageId: uid))
        }
    }

    @Test("A same-epoch provider address accepts current metadata even when RFC changes")
    @MainActor
    func providerAddressAcceptsCurrentMetadata() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "collide-refuse"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 1, lastKnownUidValidity: 900_001)
        try Self.insertStoredRow(accountId: accountId, path: "Archive", uid: "901",
                                 rfc822: "stored-a@example.com", pool: pool)

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([Self.incoming(uid: "901", rfc822: "incoming-b@example.com")])
        // Same bound epoch: provider address is authoritative; RFC is metadata.
        await mock.setMockedBoundFetchEpoch(900_001, folderPath: "Archive")

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        let row = try #require(try Self.storedRow(accountId: accountId, path: "Archive", uid: "901", pool: pool))
        #expect(row.rfc822MessageId == "incoming-b@example.com")
        #expect(row.from == "Incoming Sender" && row.fromAddress == "incoming-sender@example.com")
        #expect(row.date == Self.incomingDate)
        #expect(row.to == "incoming-to@example.com" && row.cc == "incoming-cc@example.com")
        #expect(row.isRead && row.isFlagged)
    }

    /// Ordinary equal-RFC metadata remains an over-refusal control.
    @Test("Control: a matching identity still merges every field")
    @MainActor
    func matchingIdentityStillMerges() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "collide-control"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 1, lastKnownUidValidity: 900_001)
        try Self.insertStoredRow(accountId: accountId, path: "Archive", uid: "902",
                                 rfc822: "same-identity@example.com", pool: pool)

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([Self.incoming(uid: "902", rfc822: "same-identity@example.com")])
        await mock.setMockedBoundFetchEpoch(900_001, folderPath: "Archive")

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        let row = try #require(try Self.storedRow(accountId: accountId, path: "Archive", uid: "902", pool: pool))
        #expect(row.from == "Incoming Sender" && row.fromAddress == "incoming-sender@example.com",
                "the ordinary merge stopped applying the server's sender — the refusal became a global off-switch")
        #expect(row.date == Self.incomingDate, "the ordinary merge stopped applying the server's date")
        #expect(row.isRead && row.isFlagged, "the ordinary merge stopped applying the server's flags")
        #expect(row.to == "incoming-to@example.com", "the ordinary merge stopped applying the server's recipients")
    }

    /// A NIL incoming RFC carries no metadata signal and must never null the
    /// stored `rfc822MessageId` while the provider-proven row still merges.
    @Test("Control: a nil incoming identity merges the row but never nulls the stored one")
    @MainActor
    func nilIncomingIdentityKeepsTheStoredOne() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "collide-nil-incoming"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 1, lastKnownUidValidity: 900_001)
        try Self.insertStoredRow(accountId: accountId, path: "Archive", uid: "903",
                                 rfc822: "durable-identity@example.com", pool: pool)

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([Self.incoming(uid: "903", rfc822: nil)])
        await mock.setMockedBoundFetchEpoch(900_001, folderPath: "Archive")

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        let row = try #require(try Self.storedRow(accountId: accountId, path: "Archive", uid: "903", pool: pool))
        #expect(row.rfc822MessageId == "durable-identity@example.com",
                "an envelope with no Message-ID NULLed a durable identity — that re-admits bare-UID gestures")
        #expect(row.from == "Incoming Sender",
                "a nil incoming identity is not a collision and must still merge the row's non-identity fields")
    }
}

/// FOLDED-IN FIX (i) — the pre-sync inbox reclaim must not NULL a durable identity.
///
/// THE INVARIANT: *a row that held a durable RFC-822 identity never comes out of a
/// sync pass keyed by a bare UID.* `MessageHeader.stableId` falls back to the bare
/// `messageId` the moment `rfc822MessageId` goes nil, and a bare-UID key is exactly
/// what `AccountManager.newGestureRefusedForUnknownEpoch` exists to keep out — so
/// nulling it re-admits address-keyed gestures against a message that had a durable
/// id one pass earlier. The assertion is on `stableId` (the system property), not on
/// the column the fix happens to write.
///
/// `IMAPFetchMapping.rfc822MessageId(from:)` is nil whenever the ENVELOPE carries no
/// Message-ID, so this is an ordinary envelope, not a corrupt one.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`.
@Suite("The pre-sync inbox reclaim keeps a durable identity the envelope lacks", .serialized, .processGlobalState)
struct PreSyncReclaimIdentityKeepTests {

    private static func seed(accountId: String, pool: DatabasePool, storedRfc822: String) throws {
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: 900_001)
        // The drift row's own folder must exist (messageHeader.folderId is an FK).
        // Its ROLE is irrelevant here — the reclaim keys off the header's
        // `isInInbox` column, which is what an NSE-style writer sets.
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX-drift", role: .custom, pool: pool)
        var drifted = MessageHeader(
            messageId: "905", subject: "drifted", from: "NSE Sender",
            fromAddress: "nse-sender@example.com", to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "drifted",
            folderId: "\(accountId):INBOX-drift", accountId: accountId,
            folderPath: "INBOX-drift", isInInbox: true
        )
        drifted.rfc822MessageId = storedRfc822
        drifted.headerComplete = true
        let toInsert = drifted
        try pool.write { db in try toInsert.insert(db) }
    }

    private static func incoming(rfc822: String?) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: "905", rfc822MessageId: rfc822, inReplyTo: nil, references: [],
            threadId: nil, subject: "reclaimed", from: "Server Sender",
            fromAddress: "server-sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date(timeIntervalSince1970: 1_700_000_500), snippet: "reclaimed",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil
        )
    }

    private static func runInboxSync(accountId: String, mock: MockEmailProvider, pool: DatabasePool) async throws {
        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "INBOX", pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)
    }

    /// 🚨 RED PROOF CASE.
    @Test("A reclaim with a nil incoming identity keeps the stored one, so stableId stays durable")
    @MainActor
    func nilIncomingIdentityDoesNotNullTheReclaimedRow() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "reclaim-keep"
        try Self.seed(accountId: accountId, pool: pool, storedRfc822: "durable-drift@example.com")

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([Self.incoming(rfc822: nil)])
        await mock.setMockedBoundFetchEpoch(900_001, folderPath: "INBOX")
        try await Self.runInboxSync(accountId: accountId, mock: mock, pool: pool)

        let reclaimed = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: "\(accountId):INBOX:905")
        }, "the reclaim did not produce the INBOX row at all")
        #expect(reclaimed.rfc822MessageId == "durable-drift@example.com",
                "the reclaim NULLed a durable identity because the envelope carried no Message-ID")
        #expect(reclaimed.stableId == "durable-drift@example.com",
                """
                stableId fell back to the bare UID. That is the key
                `newGestureRefusedForUnknownEpoch` exists to keep out — the message had a durable \
                id one pass ago and is now address-keyed again.
                """)
        let drifted = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: "\(accountId):INBOX-drift:905")
        }
        #expect(drifted == nil, "the reclaim was supposed to consume the drifted row")
    }

    /// Mirror image: an envelope that DOES carry an identity must still write it —
    /// the keep rule must not become "the stored value always wins", which would
    /// freeze a row's identity forever.
    @Test("Control: an incoming identity is still written on reclaim")
    @MainActor
    func incomingIdentityIsStillApplied() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "reclaim-apply"
        try Self.seed(accountId: accountId, pool: pool, storedRfc822: "durable-drift@example.com")

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([Self.incoming(rfc822: "durable-drift@example.com")])
        await mock.setMockedBoundFetchEpoch(900_001, folderPath: "INBOX")
        try await Self.runInboxSync(accountId: accountId, mock: mock, pool: pool)

        let reclaimed = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: "\(accountId):INBOX:905")
        })
        #expect(reclaimed.rfc822MessageId == "durable-drift@example.com")
        #expect(reclaimed.from == "Server Sender",
                "the reclaim inserts the SERVER's row — only the identity is kept from the drifted one")
    }
}
