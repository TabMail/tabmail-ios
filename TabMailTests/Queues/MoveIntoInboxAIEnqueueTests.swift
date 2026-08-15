/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// ADR-IOS-008 decision 3's third event — "message moved to inbox" — which iOS
/// was missing: a message moved into the inbox got AI only if the user OPENED
/// it, i.e. only by performing the click the action tag exists to remove. The
/// reference implementation states the requirement in its own words
/// (`tabmail-thunderbird/agent/modules/onMoved.js`, the
/// `!wasInInbox && nowInInbox` arm): *"inbox scans may not process this message
/// (e.g., sender filter or maxEmails cap). When a message ENTERS inbox,
/// proactively run the unified pipeline on just this message so action tags are
/// applied without requiring a user click."*
///
/// **WHAT THESE TESTS ASSERT IS THE SYSTEM PROPERTY, NOT THE MECHANISM.** The
/// property is *"the message that entered the inbox produced an AI enqueue
/// target whose id resolves to a REAL INDEXED BODY, and that body is the moved
/// message's own"*. It is deliberately NOT "some field got populated" and NOT
/// "the entry set is non-empty": `ActiveAIQueue.executeJob` resolves the body
/// with `ContentKey(rawValue: job.headerId)`, so an id that no longer addresses
/// an FTS row yields a job that is silently dropped — a state in which every
/// intermediate field is populated and the user still sees no action tag. A
/// mechanism-pinning test stays green on exactly that system.
///
/// The scenario is the one the owner actually hit and the one that is hardest
/// for the implementation: an IMAP move with **no `COPYUID`**, so the drain
/// cannot re-key, and the address is corrected LATER by the sync's UID remap.
/// `MockEmailProvider.move` furnishes no proven destinations, which reproduces
/// it exactly.
@Suite("A message that enters an inbox by local move is AI-enqueued under a resolvable id",
       .serialized, .processGlobalState)
struct MoveIntoInboxAIEnqueueTests {

    private var index: SearchIndex { SearchIndex.shared }

    // MARK: - Harness

    private func insertHeader(
        accountId: String, folderPath: String, uid: String, rfc822: String,
        isInInbox: Bool, pool: DatabasePool
    ) throws -> String {
        var header = MessageHeader(
            messageId: uid, subject: "enter-inbox fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "fixture",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: isInInbox
        )
        header.rfc822MessageId = rfc822
        header.headerComplete = true
        header.bodyComplete = true
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return header.id
    }

    /// Index a body under `headerId`, so a later `bodyText` probe can prove the
    /// enqueue target still addresses it.
    private func seedIndexedBody(headerId: String, body: String) async throws {
        let key = ContentKey(rawValue: headerId)
        try await index.removeMessages(contentKeys: [key])
        _ = try await index.indexHeaders([
            FTSHeaderRecord(
                contentKey: key, headerId: headerId,
                messageId: "<\(headerId)@example.com>",
                subject: "enter-inbox fixture", from: "sender@example.com",
                to: "recipient@example.com", dateMs: 1_700_000_000_000)
        ])
        try await index.updateBody(contentKey: key, body: body)
    }

    /// The state `AccountManagerActions.optimisticMoveToFolder` leaves behind:
    /// `folderId`/`folderPath`/`isInInbox` point at the DESTINATION while the
    /// primary key still carries the SOURCE address. Written as raw SQL on
    /// purpose — a `MessageHeader.update` would re-derive `id` and destroy the
    /// very stale-PK shape under test.
    private func applyOptimisticMove(
        headerId: String, accountId: String, toFolderPath: String, isInInbox: Bool,
        pool: DatabasePool
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = ?
                WHERE id = ?
                """, arguments: [
                    MessageIdentity.folderId(accountId: accountId, folderPath: toFolderPath),
                    toFolderPath, isInInbox, headerId
                ])
        }
    }

    /// The sync's UID remap: a new provider address for the same message, with
    /// the FTS entry carried across in place. Mirrors what
    /// `SyncEngine.runSyncMessages` + `SyncEngineFullSync.syncMessages` do
    /// together (`[Sync] UID remap:` … then `SearchIndex.rekeyHeaders`).
    private func applySyncUidRemap(
        oldHeaderId: String, accountId: String, folderPath: String, newUid: String,
        pool: DatabasePool
    ) async throws -> String {
        let newHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: newUid)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET id = ?, messageId = ? WHERE id = ?",
                arguments: [newHeaderId, newUid, oldHeaderId])
        }
        try await index.rekeyHeaders([(
            oldKey: ContentKey(rawValue: oldHeaderId),
            newKey: ContentKey(rawValue: newHeaderId),
            newMessageId: newUid)])
        return newHeaderId
    }

    private func resolveTargets(
        _ context: AccountManager.DrainContext, accountId: String, folderPath: String,
        pool: DatabasePool
    ) throws -> [ActiveAIQueue.Candidate] {
        let entries = context.enteredInbox.withLock { $0["\(accountId)|\(folderPath)"] ?? [] }
        return try pool.read { db in
            try AccountManager.resolveInboxEntryAITargets(
                entries: entries, folderPath: folderPath, db: db)
        }
    }

    private func runMove(
        accountId: String, from: String, to: String, uids: [String], pool: DatabasePool
    ) async throws -> AccountManager.DrainContext {
        let op = PendingOperation(
            type: .move, messageIds: uids, accountId: accountId,
            folderPath: from, destinationPath: to)
        try await pool.write { db in try op.insert(db) }
        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: MockEmailProvider(), context: context)
        #expect(outcome == .proceed, "the mock move succeeds, so the op must retire")
        return context
    }

    // MARK: - 1. The invariant

    @Test("A move into the inbox yields an AI target whose id still addresses the indexed body")
    func moveIntoInboxYieldsResolvableAITarget() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-1"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)

        let body = "the moved message's own body text, indexed before the move"
        let sourceId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "100",
            rfc822: "enter-inbox-1@example.com", isInInbox: false, pool: pool)
        try await seedIndexedBody(headerId: sourceId, body: body)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: sourceId)]) } }

        // The gesture, then the drain: no COPYUID, so nothing is re-keyed yet.
        try applyOptimisticMove(
            headerId: sourceId, accountId: accountId, toFolderPath: "INBOX",
            isInInbox: true, pool: pool)
        let context = try await runMove(
            accountId: accountId, from: "Archive", to: "INBOX", uids: ["100"], pool: pool)
        let pendingBeforeSync = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [sourceId]) ?? 0
        }
        #expect(pendingBeforeSync == 1,
                "the move-retirement transaction must commit direct intent before the later sync")

        // The sync then corrects the address — AFTER the drain recorded the member.
        let remappedId = try await applySyncUidRemap(
            oldHeaderId: sourceId, accountId: accountId, folderPath: "INBOX",
            newUid: "250", pool: pool)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: remappedId)]) } }

        let targets = try resolveTargets(context, accountId: accountId, folderPath: "INBOX", pool: pool)
        let pendingAfterSync = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [remappedId]) ?? 0
        }

        #expect(targets.count == 1, "the message that entered the inbox must produce exactly one AI target")
        #expect(pendingAfterSync == 1,
                "a provider-address re-key must not erase the durable direct event")
        guard targets.count == 1 else { return }
        // THE SYSTEM PROPERTY: the enqueued id must still address a real indexed
        // body. An id that resolves to nothing produces a job that is dropped,
        // which is indistinguishable to the user from never enqueueing at all.
        let resolvedBody = try await index.bodyText(contentKey: ContentKey(rawValue: targets[0].headerId))
        #expect(resolvedBody == body,
                """
                the AI target must address the moved message's own indexed body — got \
                \(resolvedBody.map { "\"\($0)\"" } ?? "nil") for id \(targets[0].headerId). \
                A nil body here is the shipped bug: the job is enqueued, finds no FTS body, \
                and is silently dropped, so the row keeps its spinner and never gains a tag.
                """)
        #expect(targets[0].accountId == accountId)
    }

    @Test("A retirement failure rolls back the completed move's durable event")
    func moveRetirementAndDirectMarkerRollbackTogether() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-marker-rollback"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)

        let sourceId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "marker-rollback",
            rfc822: "marker-rollback@example.com", isInInbox: false, pool: pool)
        try applyOptimisticMove(
            headerId: sourceId, accountId: accountId, toFolderPath: "INBOX",
            isInInbox: true, pool: pool)
        var op = PendingOperation(
            type: .move, messageIds: ["marker-rollback"], accountId: accountId,
            folderPath: "Archive", destinationPath: "INBOX")
        op.status = PendingStatus.inFlight.rawValue
        let inFlightOp = op
        let opId = inFlightOp.id
        try await pool.write { db in
            try inFlightOp.insert(db)
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_move_retirement
                BEFORE DELETE ON pendingOperation
                WHEN OLD.id = '\(opId)'
                  AND EXISTS (
                      SELECT 1 FROM messageHeader
                      WHERE id = '\(sourceId)' AND aiDirectPending = 1
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'injected move retirement failure');
                END
            """)
        }

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(
            inFlightOp, provider: MockEmailProvider(), context: context)
        #expect(outcome == .proceed,
                "the marker transaction must preserve the pre-existing drain outcome")
        let evidence = try await pool.read { db -> (Bool, Int, PendingOperation?) in
            let rowExists = try MessageHeader.fetchOne(db, key: sourceId) != nil
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [sourceId]) ?? 0
            return (rowExists, pending, try PendingOperation.fetchOne(db, key: opId))
        }
        #expect(evidence.0, "the source header survives the failed retirement transaction")
        #expect(evidence.1 == 0)
        #expect(evidence.2 != nil,
                "the completed operation and its direct marker must commit atomically")
        #expect(evidence.2?.status == PendingStatus.inFlight.rawValue,
                "launch recovery, not a new same-drain replay, owns the surviving claim")
        #expect(context.enteredInbox.withLock { $0.isEmpty })
    }

    @Test("A whole proved move never gives direct authority to a contradictory collision")
    func wholeMoveContradictoryCollisionKeepsAuthorityOnSource() async throws {
        let server = StatefulExchangeActionServer(messages: [
            .init(
                rfc822MessageId: "whole-moved@example.com",
                providerMessageId: "graph-old", folderId: "Archive"),
        ])
        defer { server.close() }
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "acc-enter-inbox-whole-collision"
        _ = try FolderEpochTestFixture.makeAccount(
            id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)

        let sourceId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "graph-old",
            rfc822: "whole-moved@example.com", isInInbox: false, pool: pool)
        try applyOptimisticMove(
            headerId: sourceId, accountId: accountId,
            toFolderPath: "INBOX", isInInbox: true, pool: pool)
        let survivorId = try insertHeader(
            accountId: accountId, folderPath: "INBOX", uid: "graph/moved+1=",
            rfc822: "contradictory-survivor@example.com",
            isInInbox: true, pool: pool)
        var op = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: accountId,
            folderPath: "Archive", destinationPath: "INBOX")
        op.status = PendingStatus.inFlight.rawValue
        let inFlightOp = op
        let opId = inFlightOp.id
        try await pool.write { db in try inFlightOp.insert(db) }

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(
            inFlightOp, provider: server.provider(), context: context)
        #expect(outcome == .proceed)
        let evidence = try await pool.read {
            db -> (Bool, Int, String?, Int, PendingOperation?) in
            let oldExists = try MessageHeader.fetchOne(db, key: sourceId) != nil
            let oldPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [sourceId]) ?? 0
            let survivorRFC = try MessageHeader.fetchOne(
                db, key: survivorId)?.rfc822MessageId
            let survivorPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [survivorId]) ?? 0
            return (oldExists, oldPending, survivorRFC, survivorPending,
                    try PendingOperation.fetchOne(db, key: opId))
        }

        #expect(server.snapshot(providerMessageId: "graph/moved+1=")?.folderId == "INBOX",
                "non-vacuity: Graph proved the destination address on the wire")
        #expect(evidence.0, "contradictory content keeps the marked optimistic source")
        #expect(evidence.1 == 1)
        #expect(evidence.2 == "contradictory-survivor@example.com")
        #expect(evidence.3 == 0,
                "provider-address proof cannot overrule contradictory content identity")
        #expect(evidence.4 == nil, "the successfully completed move still retires")
    }

    // MARK: - 2. The negative direction — "always enqueue" must not pass

    @Test("A move to a non-inbox folder yields no AI target")
    func moveToNonInboxYieldsNoAITarget() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-2"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Receipts", role: .custom, pool: pool)

        let sourceId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "101",
            rfc822: "enter-inbox-2@example.com", isInInbox: false, pool: pool)
        // A move between two non-inbox folders leaves `isInInbox` false.
        try applyOptimisticMove(
            headerId: sourceId, accountId: accountId, toFolderPath: "Receipts",
            isInInbox: false, pool: pool)
        let context = try await runMove(
            accountId: accountId, from: "Archive", to: "Receipts", uids: ["101"], pool: pool)

        let recorded = context.enteredInbox.withLock { $0["\(accountId)|Receipts"] ?? [] }
        #expect(recorded.isEmpty,
                "a destination that is not an inbox must record nothing — otherwise every move enqueues AI")
        let directPending = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [sourceId]) ?? 0
        }
        #expect(directPending == 0,
                "a non-inbox move must not invent direct AI authority")
        let targets = try resolveTargets(context, accountId: accountId, folderPath: "Receipts", pool: pool)
        #expect(targets.isEmpty, "and therefore produce no AI target")
    }

    // MARK: - 3. The wrong-message oracle

    @Test("The AI target is the moved message, not another folder's message sharing its UID")
    func aiTargetIsNeverAUidCollisionVictim() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-3"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)

        // On IMAP a UID is mailbox-local, so an unrelated INBOX message may
        // legitimately already occupy UID 102 — the address the moved message
        // would be given by naive reconstruction.
        let decoyBody = "an unrelated inbox message that merely shares the UID"
        let decoyId = try insertHeader(
            accountId: accountId, folderPath: "INBOX", uid: "102",
            rfc822: "decoy-3@example.com", isInInbox: true, pool: pool)
        try await seedIndexedBody(headerId: decoyId, body: decoyBody)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: decoyId)]) } }

        let movedBody = "the message the user actually moved into the inbox"
        let sourceId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "102",
            rfc822: "enter-inbox-3@example.com", isInInbox: false, pool: pool)
        try await seedIndexedBody(headerId: sourceId, body: movedBody)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: sourceId)]) } }

        try applyOptimisticMove(
            headerId: sourceId, accountId: accountId, toFolderPath: "INBOX",
            isInInbox: true, pool: pool)
        let context = try await runMove(
            accountId: accountId, from: "Archive", to: "INBOX", uids: ["102"], pool: pool)
        let remappedId = try await applySyncUidRemap(
            oldHeaderId: sourceId, accountId: accountId, folderPath: "INBOX",
            newUid: "260", pool: pool)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: remappedId)]) } }

        let targets = try resolveTargets(context, accountId: accountId, folderPath: "INBOX", pool: pool)
        #expect(targets.count == 1)
        guard targets.count == 1 else { return }
        let resolvedBody = try await index.bodyText(contentKey: ContentKey(rawValue: targets[0].headerId))
        #expect(resolvedBody == movedBody,
                """
                the AI target must be the MOVED message. Resolving the recorded UID against the \
                destination folder would name the decoy at INBOX:102, and AI output would be \
                attributed to a message the user never touched — got \
                \(resolvedBody.map { "\"\($0)\"" } ?? "nil").
                """)
        #expect(resolvedBody != decoyBody, "and must never be the UID-collision victim's body")
    }

    @Test("Same-folder duplicate RFC targets have one deterministic lowest-id winner")
    func duplicateRfcAITargetIsDeterministic() throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-duplicate-rfc"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)

        let sharedRfc = "duplicate-target@example.com"
        let insertedFirst = try insertHeader(
            accountId: accountId, folderPath: "INBOX", uid: "z-uid",
            rfc822: sharedRfc, isInInbox: true, pool: pool)
        let lowestId = try insertHeader(
            accountId: accountId, folderPath: "INBOX", uid: "a-uid",
            rfc822: sharedRfc, isInInbox: true, pool: pool)
        #expect(lowestId < insertedFirst)

        let context = AccountManager.DrainContext()
        context.enteredInbox.withLock {
            $0["\(accountId)|INBOX"] = [AccountManager.DrainContext.InboxEntry(
                accountId: accountId, messageId: "stale-source-uid", rfc822MessageId: sharedRfc)]
        }
        let targets = try resolveTargets(
            context, accountId: accountId, folderPath: "INBOX", pool: pool)

        #expect(targets.map { $0.headerId } == [lowestId],
                "the first-inserted row must not win merely because the RFC index reaches it first")
    }
}
