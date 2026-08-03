/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T4.S4 / T4.V11 — the two purge companions of the D5 UIDVALIDITY
/// purge-and-resync reaction: the NSE staged-state purges
/// (`NSEDataBridge.purgeStagedStateForFolder`,
/// `NSEDataBridge.purgeInboxRemovalMarkersForAccount`) and the chat-pill identity
/// purge (`ChatIdTranslator.purgeMappingsForFolder`).
///
/// THE INVARIANT ALL FOUR TESTS PIN, stated once: **after a folder's UIDVALIDITY is
/// reset, nothing anywhere may still resolve one of that folder's old headerIds to
/// content.** A headerId is `accountId:folderPath:UID` — an ADDRESS. The server has
/// just re-issued that address space, so any surviving row keyed by one of those
/// strings hands a NEW message's slot a stale answer: an NSE-staged row re-inserts
/// a header the purge removed, and a chat pill in an old turn resolves to whatever
/// message now occupies the UID. Both are C3 — the wrong message, misattributed.
///
/// Deliberately asserted on END STATES (what is resolvable, what is still in the
/// staging file, what the folder's stored epoch is), never on which function was
/// called or which flag was written.
///
/// WHAT ABORTS THE REACTION AND WHAT DOES NOT — the second thing under test here.
/// Exactly ONE step-4 purge aborts, the FTS one, and its abort leg is already pinned
/// by `UidValidityResetReactionTests.abortBeforeStampLeavesTheFolderRetryable`. The
/// NSE staging purges are BEST-EFFORT by design; `stagingPurgeFailureDoesNotAbort`
/// below is the two-sided proof that a purge which genuinely could not write leaves
/// the reaction free to complete.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, mutates
/// `AccountManager.shared`'s provider table, the process-wide
/// `NSEDataBridge.latestStagedRows` / `latestStagedBodies` snapshots and the
/// `ChatIdTranslator.shared` actor, and binds a listening socket via `FakeIMAPServer`.
@Suite("T4.S4/T4.V11 — the reset's NSE-staging and chat-id purges", .serialized, .processGlobalState)
struct UidValidityResetPurgeCompanionTests {

    // MARK: - Fixture

    private static let oldEpoch = 710_001
    private static let newEpoch = 710_002

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: purge companion fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        purge companion fixture body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func imapProvider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false
        )
    }

    /// Register `provider` for `accountId`, run `body`, then unregister — and
    /// **AWAIT** the unregister rather than firing it off a `defer { Task { … } }`.
    ///
    /// 🚨 `AccountManager` is an `actor`, so an unregister launched from a `defer`
    /// is an actor JOB that is merely ENQUEUED when this helper returns; the
    /// registry is NOT yet quiescent. A test that registers a SECOND time then has
    /// that stale first job still pending, and it runs at the next suspension —
    /// which is inside the second reaction's very first `await`. It removes the
    /// provider the reaction is about to read, `providers[accountId]` comes back
    /// nil, and `runUidValidityResetReaction` returns at its provider guard whose
    /// only witness is a `DebugModeManager.isLoggingEnabled()`-gated print (false
    /// under test). The second leg then looks exactly like "the purge did not
    /// happen" when in truth the reaction never started — which is precisely the
    /// misreading a non-vacuity check exists to prevent, and one this file's own
    /// `inboxRemovalMarkersArePurgedOnlyByAnInboxRoleReset` suffered.
    ///
    /// Awaiting on BOTH exits (normal and thrown) is what makes the teardown a
    /// contract rather than a hope: when this returns, the registry state is
    /// settled and no queued job from it can land inside a later leg.
    @MainActor
    private static func withRegisteredProvider(
        accountId: String, provider: any EmailProvider, _ body: () async throws -> Void
    ) async rethrows {
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        do {
            try await body()
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    /// A staged row for `(accountId, folderPath, messageId)`. `date` is derived from
    /// `Date()` — never a literal (a hardcoded date silently goes stale).
    private static func stagedRow(
        accountId: String, folderPath: String, messageId: String
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: "staged-\(messageId)@example.com",
            threadId: nil, inReplyTo: nil, references: [],
            subject: "staged \(messageId)", senderName: "Sender",
            senderAddress: "sender@example.com", to: "recipient@example.com",
            snippet: "staged snippet", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    /// Reset the DB-free process-wide surfaces. Safe to call before an `AppDatabase`
    /// is installed (`AppDatabase.rawPool` force-unwraps `shared`, so anything that
    /// touches GRDB must wait for the swap).
    private static func resetStagingGlobals() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
    }

    /// Full reset, including the `ChatIdTranslator` actor (which writes GRDB).
    /// The LEADING call in each test is the real isolation — a trailing one is
    /// skipped by any thrown error.
    private static func resetProcessGlobals() async {
        resetStagingGlobals()
        await ChatIdTranslator.shared.clearAll()
    }

    /// Build a real NSE staging file (production schema) inside `dir`, and point the
    /// reaction's purge helpers at it.
    private static func makeInjectedStagingFile(in dir: URL) throws -> (path: String, queue: DatabaseQueue) {
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = path }
        return (path, try DatabaseQueue(path: path))
    }

    private static func stageProcessedRow(
        _ q: DatabaseQueue, accountId: String, folderPath: String, messageId: String
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, ?, 'imap', ?, ?, ?, 'staged subject', 'Sender',
                        'sender@example.com', 'staged snippet', ?, ?, 0, 0, 1)
                """, arguments: [
                    "\(accountId):\(messageId)", accountId, "\(accountId)@example.com",
                    messageId, "staged-\(messageId)@example.com", folderPath,
                    Date().timeIntervalSince1970, Date().timeIntervalSince1970
                ])
        }
    }

    private static func stageInboxRemoval(
        _ q: DatabaseQueue, accountId: String, messageId: String
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: [
                    "\(accountId):\(messageId)", accountId, messageId, Date().timeIntervalSince1970
                ])
        }
    }

    private static func stagedProcessedIds(_ q: DatabaseQueue) throws -> Set<String> {
        try q.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM nse_processed_message")) }
    }

    private static func stagedRemovalIds(_ q: DatabaseQueue) throws -> Set<String> {
        try q.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM nse_inbox_removal")) }
    }

    private static func persistedChatRealIds(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT realId FROM chatIdMapping")) }
    }

    private static func stagedRowKeys() -> Set<String> {
        Set(NSEDataBridge.latestStagedRows.withLock { $0 }.map(\.headerId))
    }

    private static func stagedBodyKeys() -> Set<String> {
        Set(NSEDataBridge.latestStagedBodies.withLock { $0 }.keys)
    }

    // MARK: - (i) + (v) — what the reset erases, and what it must not touch

    /// 🚨 The purge, and its two-sided control in the same run.
    ///
    /// Three messages exist in every surface at once — one in the folder being reset,
    /// one in a SIBLING folder of the same account, one in a DIFFERENT account's
    /// inbox. After the reaction on `(reset account, INBOX)`:
    ///  - nothing anywhere still resolves `resetAccount:INBOX:…` — not the in-memory
    ///    staged snapshots, not the staging file, not the chat-pill map, not
    ///    `chatIdMapping` on disk;
    ///  - BOTH bystanders still resolve everywhere.
    ///
    /// The control half is what makes the first half mean anything: a purge that
    /// simply deleted everything would satisfy "nothing survives for INBOX" and be a
    /// catastrophe.
    @Test("A UIDVALIDITY reset erases every trace of the reset folder's staged rows and chat-id mappings, and none of another folder's or another account's")
    @MainActor
    func resetPurgesStagedRowsAndChatMappingsFolderScoped() async throws {
        Self.resetStagingGlobals()

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9201, id: "post-reset-9201@example.com")],
            "Archive": []
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        await ChatIdTranslator.shared.clearAll()

        let accountId = "t4s4-scope"
        let otherAccountId = "t4s4-bystander"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        _ = try FolderEpochTestFixture.makeAccount(id: otherAccountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: otherAccountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [1101], pool: pool)

        let (_, stagingQueue) = try Self.makeInjectedStagingFile(in: dir)
        ownedQueues.append(stagingQueue)

        let victimId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: "1101")
        let siblingId = MessageIdentity.headerId(accountId: accountId, folderPath: "Archive", messageId: "1102")
        let otherAccountRowId = MessageIdentity.headerId(
            accountId: otherAccountId, folderPath: "INBOX", messageId: "1103")
        // An ORPHANED chat mapping: its `messageHeader` row is already gone (a stale
        // sweep took it before this reset). The step-3 transaction's `chatIdMapping`
        // DELETE joins through `messageHeader.folderId`, so it structurally cannot see
        // this row — only the prefix-keyed companion purge can. This is the half-port
        // gap made observable.
        let orphanId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: "1104")
        // A NESTED SIBLING under a ':'-hierarchy server. It shares the reset folder's
        // `accountId:INBOX:` prefix and is a DIFFERENT folder — the no-deeper-colon
        // guard is the only thing that saves it, and sweeping it in would be worse
        // than leaving an orphan behind.
        let nestedSiblingId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "INBOX:Sub", messageId: "1105")

        // Surface 1 — the in-memory staged snapshots.
        NSEDataBridge.latestStagedRows.withLock {
            $0 = [
                Self.stagedRow(accountId: accountId, folderPath: "INBOX", messageId: "1101"),
                Self.stagedRow(accountId: accountId, folderPath: "Archive", messageId: "1102"),
                Self.stagedRow(accountId: otherAccountId, folderPath: "INBOX", messageId: "1103")
            ]
        }
        let snapshot = NSEDataBridge.StagedBodySnapshot(
            htmlContent: "<p>staged</p>", attachmentsJSON: nil, icsText: nil)
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = [
                victimId: snapshot, siblingId: snapshot,
                otherAccountRowId: snapshot, nestedSiblingId: snapshot
            ]
        }

        // Surface 2 — the staging file itself.
        try Self.stageProcessedRow(stagingQueue, accountId: accountId, folderPath: "INBOX", messageId: "1101")
        try Self.stageProcessedRow(stagingQueue, accountId: accountId, folderPath: "Archive", messageId: "1102")
        try Self.stageProcessedRow(stagingQueue, accountId: otherAccountId, folderPath: "INBOX", messageId: "1103")

        // Surface 3 — the chat-pill identity map (in memory AND persisted).
        let victimPill = await ChatIdTranslator.shared.toNumericId(victimId)
        let siblingPill = await ChatIdTranslator.shared.toNumericId(siblingId)
        let otherAccountPill = await ChatIdTranslator.shared.toNumericId(otherAccountRowId)
        let orphanPill = await ChatIdTranslator.shared.toNumericId(orphanId)
        let nestedSiblingPill = await ChatIdTranslator.shared.toNumericId(nestedSiblingId)

        // Preconditions — a green below must not be reachable by "it was never there".
        #expect(Self.stagedRowKeys().contains(victimId), "precondition: the victim was staged in memory")
        #expect(try Self.stagedProcessedIds(stagingQueue).contains("\(accountId):1101"),
                "precondition: the victim was staged in the staging file")
        let chatBefore = try Self.persistedChatRealIds(pool)
        #expect(chatBefore.contains(victimId), "precondition: the victim's chat mapping was persisted")
        #expect(chatBefore.contains(orphanId), "precondition: the ORPHAN chat mapping was persisted")
        let orphanHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: orphanId) }
        #expect(orphanHeader == nil,
                "precondition: the orphan mapping has no owning header, so the in-transaction join cannot reach it")

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        // ── The purge half.
        let stagedAfter = try Self.stagedProcessedIds(stagingQueue)
        let chatAfter = try Self.persistedChatRealIds(pool)
        #expect(!Self.stagedRowKeys().contains(victimId),
                """
                a staged NSE row for the reset folder survived. The next merge re-inserts the \
                header the reaction just deleted, under an epoch the server has discarded — C3.
                """)
        #expect(!Self.stagedBodyKeys().contains(victimId),
                "a staged BODY for the reset folder survived — a tap on the recycled UID renders the old message's body")
        #expect(!stagedAfter.contains("\(accountId):1101"),
                """
                the reset folder's row is still in the staging FILE. In-memory scrubbing alone is \
                undone by the next merge, which re-reads the file.
                """)
        #expect(await ChatIdTranslator.shared.toRealId(victimPill) == nil,
                """
                a chat pill still resolves to a headerId in the reset folder. A new message now \
                occupies that UID, so an old turn's pill renders THAT message's subject and body.
                """)
        #expect(!chatAfter.contains(victimId),
                """
                the reset folder's chat mapping is still on disk. The in-memory clear alone is \
                undone at the next launch, when ensureLoadedFromDB reloads it.
                """)
        #expect(await ChatIdTranslator.shared.toRealId(orphanPill) == nil,
                """
                an ORPHANED chat mapping for the reset folder survived. Its header row was already \
                gone, so the transaction's relational DELETE could never see it — only the \
                prefix-keyed companion purge closes this, and porting one half without the other \
                leaves exactly this row resolving to the new occupant of its UID.
                """)
        #expect(!chatAfter.contains(orphanId),
                "the orphaned chat mapping is still on disk — it is reloaded at the next launch")

        // ── The control half — two-sided non-vacuity.
        #expect(Self.stagedBodyKeys().contains(nestedSiblingId),
                """
                a NESTED SIBLING folder's staged body was swept up by the parent folder's purge. \
                Its headerId merely shares the `account:INBOX:` prefix under a ':'-hierarchy IMAP \
                server; deleting a genuinely foreign folder's rows is worse than leaving an orphan.
                """)
        #expect(await ChatIdTranslator.shared.toRealId(nestedSiblingPill) == nestedSiblingId,
                "a nested sibling folder's chat pill was purged by its PARENT folder's reset")
        #expect(chatAfter.contains(nestedSiblingId),
                "a nested sibling folder's persisted chat mapping was deleted by its parent's reset")
        #expect(Self.stagedRowKeys().contains(siblingId) && Self.stagedRowKeys().contains(otherAccountRowId),
                "the purge reached a folder/account the reaction was not resetting — that is mass data loss, not scoping")
        #expect(Self.stagedBodyKeys().contains(siblingId) && Self.stagedBodyKeys().contains(otherAccountRowId),
                "the staged-body purge was not folder-scoped")
        #expect(stagedAfter.contains("\(accountId):1102") && stagedAfter.contains("\(otherAccountId):1103"),
                "the staging-FILE delete was not scoped to (accountId, folderPath)")
        #expect(await ChatIdTranslator.shared.toRealId(siblingPill) == siblingId,
                "a sibling folder's chat pill was purged — its headerId merely shares the account prefix")
        #expect(await ChatIdTranslator.shared.toRealId(otherAccountPill) == otherAccountRowId,
                "another account's chat pill was purged by this account's reset")
        #expect(chatAfter.contains(siblingId) && chatAfter.contains(otherAccountRowId),
                "the persisted chat-mapping delete was not folder-scoped")

        await Self.resetProcessGlobals()
    }

    // MARK: - (iv) — purge FIRST, stamp LAST

    /// 🚨 ORDERING, machine-checked at the one instant where getting it backwards is
    /// observable: the reaction's `afterPurgeBeforeStamp` checkpoint.
    ///
    /// A stamp-then-purge implementation clears the quarantine while the staged rows
    /// and chat mappings still resolve — and in that window the folder reads as
    /// HEALED, so nothing re-drives it and every ordinary consumer is free to act on
    /// rows that address the discarded numbering. This test refuses to accept the
    /// final end state as evidence of order: it observes the intermediate one.
    @Test("The reset folder's staged rows and chat-id mappings are already gone at the pre-stamp checkpoint, while the old epoch still stands")
    @MainActor
    func purgesLandBeforeTheEpochStamp() async throws {
        Self.resetStagingGlobals()

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9301, id: "post-reset-9301@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        await ChatIdTranslator.shared.clearAll()

        let accountId = "t4s4-order"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [1201], pool: pool)

        let (_, stagingQueue) = try Self.makeInjectedStagingFile(in: dir)
        ownedQueues.append(stagingQueue)
        try Self.stageProcessedRow(stagingQueue, accountId: accountId, folderPath: "INBOX", messageId: "1201")

        let victimId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: "1201")
        NSEDataBridge.latestStagedRows.withLock {
            $0 = [Self.stagedRow(accountId: accountId, folderPath: "INBOX", messageId: "1201")]
        }
        let victimPill = await ChatIdTranslator.shared.toNumericId(victimId)

        // What the checkpoint saw: (reached, stagedInMemory, stagedInFile, chatResolves,
        // epoch, quarantined). The seed is the FAILING value for every field, so a hook
        // that never runs cannot produce a green.
        let observed = Mutex<(Bool, Bool, Bool, Bool, Int?, Bool)>((false, true, true, true, nil, false))
        let folderId = "\(accountId):INBOX"
        AccountManager.uidValidityResetCheckpointHooksForTesting.withLock {
            $0[.afterPurgeBeforeStamp(folderId: folderId)] = {
                let inMemory = NSEDataBridge.latestStagedRows.withLock { $0 }.contains { $0.headerId == victimId }
                let inFile = (try? await stagingQueue.read { db in
                    try Bool.fetchOne(db, sql:
                        "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)",
                        arguments: ["\(accountId):1201"]) ?? false
                }) ?? true
                let chatResolves = await ChatIdTranslator.shared.toRealId(victimPill) != nil
                let folder = try? await AppDatabase.dbPool.read { db in
                    try Folder.fetchOne(db, key: folderId)
                }
                observed.withLock {
                    $0 = (true, inMemory, inFile, chatResolves,
                          folder?.lastKnownUidValidity, folder?.uidValidityResetPendingAt != nil)
                }
            }
        }
        defer { AccountManager.uidValidityResetCheckpointHooksForTesting.withLock { $0 = [:] } }

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        let seen = observed.withLock { $0 }
        #expect(seen.0, "the pre-stamp checkpoint was never reached — every ordering claim below would be vacuous")
        guard seen.0 else { return }
        #expect(!seen.1, "a staged NSE row was still in memory at the pre-stamp checkpoint — the purge runs AFTER the stamp")
        #expect(!seen.2, "a staged NSE row was still in the staging file at the pre-stamp checkpoint")
        #expect(!seen.3, "a chat-pill mapping still resolved at the pre-stamp checkpoint")
        #expect(seen.4 == Self.oldEpoch,
                "the fresh epoch was already stamped at a checkpoint that runs BEFORE the stamp — the order is inverted")
        #expect(seen.5,
                """
                the quarantine was already cleared before the stamp step. A folder that reads as \
                healed while its old-epoch sidecars still resolve has no re-drive and no guard.
                """)

        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                "the reaction did not complete — the ordering above would then be about an aborted run")

        await Self.resetProcessGlobals()
    }

    // MARK: - (ii) — best-effort: a failing staging purge must not abort

    /// 🚨 The NSE staging purge is BEST-EFFORT. A staging DB that cannot be written
    /// must not strand the folder in quarantine with its mail already deleted.
    ///
    /// TWO-SIDED, because "nothing threw" is trivially satisfiable by a purge that
    /// SUCCEEDED: the staged row must still be in the file afterwards (proving the
    /// write genuinely failed) AND the reaction must still have stamped the fresh
    /// epoch and cleared the quarantine.
    ///
    /// WHAT DOES ABORT: the FTS purge, and every durable step (arm, purge txn, fresh
    /// observation, stamp) — pinned by
    /// `UidValidityResetReactionTests.abortBeforeStampLeavesTheFolderRetryable`.
    @Test("A staging purge that cannot write leaves the reaction free to complete, and the unpurged rows behind")
    @MainActor
    func stagingPurgeFailureDoesNotAbort() async throws {
        Self.resetStagingGlobals()

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9401, id: "post-reset-9401@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        var ownedQueues: [DatabaseQueue] = []
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
            // Restore write permission so the fixture directory can be unlinked.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: stagingPath)
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        await ChatIdTranslator.shared.clearAll()

        let accountId = "t4s4-besteffort"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [1301], pool: pool)

        let (_, stagingQueue) = try Self.makeInjectedStagingFile(in: dir)
        ownedQueues.append(stagingQueue)
        try Self.stageProcessedRow(stagingQueue, accountId: accountId, folderPath: "INBOX", messageId: "1301")
        try Self.stageInboxRemoval(stagingQueue, accountId: accountId, messageId: "1301")

        NSEDataBridge.latestStagedRows.withLock {
            $0 = [Self.stagedRow(accountId: accountId, folderPath: "INBOX", messageId: "1301")]
        }
        let victimId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: "1301")

        // Make every WRITE to the staging file fail (SQLITE_READONLY) while leaving it
        // readable, so the assertions below can still inspect it.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stagingPath)

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        // Non-vacuity: the write really did fail, so the green below is not a
        // successful purge wearing a failure's clothes.
        let survivors = try Self.stagedProcessedIds(stagingQueue)
        #expect(survivors.contains("\(accountId):1301"),
                """
                the staging write SUCCEEDED, so this test proves nothing about the failure path. \
                The read-only permission did not take effect.
                """)
        #expect(try Self.stagedRemovalIds(stagingQueue).contains("\(accountId):1301"),
                "the nse_inbox_removal write succeeded — same vacuity problem")

        // Best-effort: the reaction completed anyway.
        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                """
                a staging-DB write failure ABORTED the reaction before its stamp. The staging purge \
                is best-effort on purpose: its miss degrades to the residual the reaction already \
                accepted (the next sync pass stale-sweeps the UID), whereas aborting leaves the \
                folder quarantined with its mail already deleted.
                """)
        #expect(folder?.uidValidityResetPendingAt == nil,
                "the quarantine outlived a reaction that only failed a BEST-EFFORT purge")
        #expect(!Self.stagedRowKeys().contains(victimId),
                """
                the in-memory snapshot purge was skipped because the DB half failed. The two are \
                independent: the memory scrub cannot fail and must happen regardless.
                """)

        await Self.resetProcessGlobals()
    }

    // MARK: - (iii) + (v) — inbox-role only, account-scoped

    /// 🚨 `nse_inbox_removal` is (account, UID)-keyed with NO folderPath column, so
    /// the purge can only ever be account-wide — which makes WHEN it fires the whole
    /// safety argument.
    ///
    ///  - resetting a NON-inbox folder must leave the markers alone: they describe
    ///    inbox arrivals this reset has no claim over, and deleting them resurrects
    ///    messages the NSE already told the app to remove;
    ///  - resetting the INBOX-role folder must clear them, because each marker names a
    ///    UID in the numbering the server just discarded;
    ///  - and in both cases another account's markers are untouched.
    @Test("Inbox-removal markers survive a non-inbox folder's reset, are cleared by the inbox folder's reset, and never cross accounts")
    @MainActor
    func inboxRemovalMarkersArePurgedOnlyByAnInboxRoleReset() async throws {
        Self.resetStagingGlobals()

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9501, id: "post-reset-9501@example.com")],
            "Archive": [Self.message(uid: 9502, id: "post-reset-9502@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        await ChatIdTranslator.shared.clearAll()

        let accountId = "t4s4-role"
        let otherAccountId = "t4s4-role-bystander"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        _ = try FolderEpochTestFixture.makeAccount(id: otherAccountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [1401], pool: pool)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [1402], pool: pool)

        let (_, stagingQueue) = try Self.makeInjectedStagingFile(in: dir)
        ownedQueues.append(stagingQueue)
        try Self.stageInboxRemoval(stagingQueue, accountId: accountId, messageId: "1401")
        try Self.stageInboxRemoval(stagingQueue, accountId: otherAccountId, messageId: "1403")

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // ── Leg 1: reset the ARCHIVE-role folder.
        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "Archive")
        }
        let afterArchiveReset = try Self.stagedRemovalIds(stagingQueue)
        #expect(afterArchiveReset.contains("\(accountId):1401"),
                """
                a NON-inbox folder's reset cleared this account's inbox-removal markers. The table \
                has no folderPath column, so an unguarded purge deletes instructions that belong to \
                a folder this reset never touched — messages the NSE already removed come back.
                """)
        #expect(afterArchiveReset.contains("\(otherAccountId):1403"),
                "another account's inbox-removal markers were deleted by this account's reset")

        // Non-vacuity for leg 1: the Archive reset must actually have RUN.
        let archiveFolder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool)
        #expect(archiveFolder?.lastKnownUidValidity == Self.newEpoch,
                "the Archive reaction never completed, so leg 1's survival proves nothing")

        // ── Leg 2: reset the INBOX-role folder.
        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }
        // Non-vacuity for leg 2 — the MIRROR of leg 1's, and it must come FIRST.
        // Without it the two assertions below cannot tell "the purge is broken"
        // from "the reaction never ran", and they report the former either way.
        // That is not hypothetical: this exact check was missing while leg 1 had
        // one, and the leg-2 failure it produced was a C3-shaped accusation
        // against a reaction that had returned at its provider guard before doing
        // anything at all. The stamp is the right witness because it is the LAST
        // durable write of a completed run — every abort leg leaves the folder
        // still holding the OLD epoch (and still quarantined).
        let inboxFolder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(inboxFolder?.lastKnownUidValidity == Self.newEpoch,
                "the INBOX reaction never completed, so leg 2's purge assertions prove nothing")
        #expect(inboxFolder?.uidValidityResetPendingAt == nil,
                "the INBOX folder is still quarantined — the reaction aborted rather than completing")

        let afterInboxReset = try Self.stagedRemovalIds(stagingQueue)
        #expect(!afterInboxReset.contains("\(accountId):1401"),
                """
                an inbox-removal marker survived the INBOX folder's reset. It names a UID in the \
                numbering the server just discarded, so the next merge applies it to whichever \
                message now occupies that UID — C3.
                """)
        #expect(afterInboxReset.contains("\(otherAccountId):1403"),
                "the account-wide delete reached ANOTHER account's markers — the scope is one account, not the table")

        await Self.resetProcessGlobals()
    }

    // MARK: - The oversized-body quarantine RELEASE (wiring only)

    /// 🚨 THE WIRING, not the method. `clearOversizedDeferred` is exercised directly by
    /// `OversizedBodyQuarantineTests` (colon-hierarchy scoping, the in-flight
    /// generation guard, the set filtering); none of those tests can tell whether
    /// anything ever CALLS it. This one drives the whole reaction and asserts the
    /// system property that only a live call site can produce:
    ///
    ///   **after a folder's UIDVALIDITY is reset, that folder's oversized quarantine
    ///   no longer suppresses its messages — and no other folder's is released.**
    ///
    /// This matters because the quarantine keys by headerId, an ADDRESS. The turnover
    /// renumbers the mailbox, so the resync can re-insert a fresh message at a
    /// deferred UID; a quarantine that never lifts then starves a message that was
    /// never oversized of its body until relaunch — a bounded deferral silently
    /// promoted to a permanent discard.
    ///
    /// Asserted on the SUPPRESSION SETS rather than by calling `admit(_:)` for the
    /// released id: `admit` succeeding would ENQUEUE into a process-global actor that
    /// later tests share. The bystander leg does call the real gate, since a refusal
    /// has no side effect.
    @Test("A completed reset releases the reset folder's oversized-body quarantine, and only that folder's")
    @MainActor
    func resetReleasesTheOversizedQuarantineForItsFolderOnly() async throws {
        Self.resetStagingGlobals()

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 9601, id: "post-reset-9601@example.com")],
            "Archive": []
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.purgeStagingPathOverrideForTesting.withLock { $0 = nil }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "t4s4-oversized"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [1501], pool: pool)

        let victim = ActiveBodyQueue.Item(
            headerId: MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: "1501"),
            accountId: accountId, folderPath: "INBOX", messageId: "1501", isInInbox: true)
        let bystander = ActiveBodyQueue.Item(
            headerId: MessageIdentity.headerId(accountId: accountId, folderPath: "Archive", messageId: "1502"),
            accountId: accountId, folderPath: "Archive", messageId: "1502", isInInbox: false)
        let backfillVictim = BackfillBodyQueue.Item(
            headerId: victim.headerId, accountId: accountId,
            folderPath: "INBOX", messageId: "1501", isInInbox: true)

        // Both queues are process-global — clear this test's exact keys on entry AND on
        // exit so neither a predecessor nor this test can leak into another.
        func clearBoth() async {
            await ActiveBodyQueue.shared.clearOversizedDeferred(accountId: accountId, folderPath: "INBOX")
            await ActiveBodyQueue.shared.clearOversizedDeferred(accountId: accountId, folderPath: "Archive")
            await BackfillBodyQueue.shared.clearOversizedDeferred(accountId: accountId, folderPath: "INBOX")
        }
        await clearBoth()

        // Seed the quarantine through the REAL producer — a lone PayloadTooLarge.
        await ActiveBodyQueue.shared.handlePayloadTooLarge(items: [victim], folderPath: "INBOX")
        await ActiveBodyQueue.shared.handlePayloadTooLarge(items: [bystander], folderPath: "Archive")
        await BackfillBodyQueue.shared.handlePayloadTooLarge(items: [backfillVictim], folderPath: "INBOX")

        let activeSeeded = await ActiveBodyQueue.shared.oversizedDeferredThisSession
        let backfillSeeded = await BackfillBodyQueue.shared.oversizedDeferredThisSession
        #expect(activeSeeded.contains(victim.headerId) && activeSeeded.contains(bystander.headerId),
                "precondition: both ids are quarantined, so a release below is not vacuous")
        #expect(backfillSeeded.contains(victim.headerId),
                "precondition: the backfill queue quarantined the victim too")

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: accountId, folderPath: "INBOX")
        }

        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                "the reaction never completed, so nothing below is evidence about its call sites")

        let activeAfter = await ActiveBodyQueue.shared.oversizedDeferredThisSession
        let backfillAfter = await BackfillBodyQueue.shared.oversizedDeferredThisSession
        #expect(!activeAfter.contains(victim.headerId),
                """
                the reset folder's oversized quarantine survived a COMPLETED reaction — nothing \
                calls clearOversizedDeferred. The headerId names an address the server has just \
                reissued, so the deferral now suppresses whichever message occupies that UID, \
                permanently, and a bounded quarantine has become a discard.
                """)
        #expect(!backfillAfter.contains(victim.headerId),
                "only ONE of the two body queues is wired — the backfill queue's quarantine still suppresses the reset folder")

        // Two-sided control: a release that dropped everything would pass the two above.
        #expect(activeAfter.contains(bystander.headerId),
                "the release reached a folder the reaction was not resetting — that re-opens a hot loop the quarantine exists to stop")
        let bystanderAdmitted = await ActiveBodyQueue.shared.admit(bystander)
        #expect(!bystanderAdmitted,
                "the real admission gate let an untouched folder's quarantined item back in")

        await clearBoth()
        await Self.resetProcessGlobals()
    }
}
