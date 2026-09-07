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
        _ context: AccountOperationExecutor.DrainContext, accountId: String, folderPath: String,
        pool: DatabasePool
    ) throws -> [(headerId: String, accountId: String)] {
        let entries = context.enteredInbox.withLock { $0["\(accountId)|\(folderPath)"] ?? [] }
        return try pool.read { db in
            try AccountManager.resolveInboxEntryAITargets(
                entries: entries, folderPath: folderPath, db: db)
        }
    }

    private func runMove(
        accountId: String, from: String, to: String, uids: [String], pool: DatabasePool
    ) async throws -> AccountOperationExecutor.DrainContext {
        let op = PendingOperation(
            type: .move, messageIds: uids, accountId: accountId,
            folderPath: from, destinationPath: to)
        try await pool.write { db in _ = try op.inserted(db) }
        let context = AccountOperationExecutor.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: MockEmailProvider(), context: context)
        #expect(outcome == .completed, "the mock move succeeds, so the op must retire")
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

        // The sync then corrects the address — AFTER the drain recorded the member.
        let remappedId = try await applySyncUidRemap(
            oldHeaderId: sourceId, accountId: accountId, folderPath: "INBOX",
            newUid: "250", pool: pool)
        defer { Task { try? await index.removeMessages(contentKeys: [ContentKey(rawValue: remappedId)]) } }

        let targets = try resolveTargets(context, accountId: accountId, folderPath: "INBOX", pool: pool)

        #expect(targets.count == 1, "the message that entered the inbox must produce exactly one AI target")
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

    // MARK: - 1b. Every member the drain PROVES, whichever path proves it

    /// **THE INVARIANT: every member a retirement path proves gets the same
    /// post-retirement treatment as a member proven by the whole-op path — so a
    /// multi-member move into the Inbox produces an AI target for EVERY member,
    /// not only the one that happens to settle last.**
    ///
    /// This is the ordinary shape of multi-member Gmail and Graph traffic, not a
    /// contingency. `GmailProvider.modifyEachMessage`,
    /// `ExchangeProvider.patchEachMessage` and
    /// `ExchangeProvider.moveProvingDestinations` each address exactly ONE id per
    /// attempt and report it (`MIS-IOS-022`: an attempt may commit to one request
    /// and no elapsed-time margin can bound the next one), so the FIRST attempt of
    /// every two-member move on those providers proves a strict subset and retires
    /// through `AccountManager.retirePartiallyCompletedOp`. Only the final member
    /// is ever proven by the whole-op arm.
    ///
    /// A path that commits a retirement without recording the inbox entry is not
    /// recovered by anything downstream: `ActiveAIQueue.repopulateFromDatabase`
    /// runs `repopulationCandidates`, bounded in SQL to the newest
    /// `SyncConfig.maxRecentEmails` Inbox rows, and escaping exactly that bound is
    /// why this producer is window-EXEMPT (ADR-IOS-078, `IOS-AI-007`). The member
    /// silently gets no summary and no action tag — the user-must-click gap
    /// ADR-IOS-008 decision 3 exists to close.
    ///
    /// **THE ORACLE IS EACH MEMBER'S OWN INDEXED BODY**, for the reason the suite
    /// header gives: a target id that no longer addresses an FTS row yields a job
    /// that is silently dropped, so "an entry was recorded" is not the property.
    /// The two members carry DIFFERENT bodies, so an implementation that records
    /// one member twice cannot satisfy it either.
    ///
    /// RED PROOF (recorded 2026-09-06): with the `recordMembersThatEnteredInbox`
    /// call commented out of `retirePartiallyCompletedOp`, this fails
    /// `(recorded.count → 1) == 2` with `enteredInbox recorded 1 of 2 proven
    /// members (["301"])`, and then `(targets.count → 1) == 2` — only the member
    /// the SECOND attempt settles through the whole-op arm is enqueued, and the
    /// member the narrowing pass proved has no AI target at all.
    ///
    /// The two attempts are the executor's own continuous run: a narrowing that
    /// COMMITS leaves a strictly smaller operation at the SAME `queuePosition`,
    /// so the next iteration re-claims that same durable row as the live front
    /// row and finishes it — which is why both attempts share one `DrainContext`,
    /// exactly as they do in production, and why one drain settles the whole
    /// gesture instead of one member per drain.
    @Test("Every member proven by a narrowing retirement is AI-enqueued, not just the last one")
    func everyProvenMemberOfAMultiMemberMoveIntoInboxIsEnqueued() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-enter-inbox-narrowed"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)

        // Distinct bodies: the oracle below reads each target's indexed body, so
        // one member resolved twice cannot pass for two members.
        let narrowedBody = "the member the NARROWING pass proves"
        let wholeOpBody = "the member the whole-op pass proves"
        let narrowedId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "300",
            rfc822: "narrowed-member@example.com", isInInbox: false, pool: pool)
        let wholeOpId = try insertHeader(
            accountId: accountId, folderPath: "Archive", uid: "301",
            rfc822: "whole-op-member@example.com", isInInbox: false, pool: pool)
        try await seedIndexedBody(headerId: narrowedId, body: narrowedBody)
        try await seedIndexedBody(headerId: wholeOpId, body: wholeOpBody)
        defer {
            Task {
                try? await index.removeMessages(contentKeys: [
                    ContentKey(rawValue: narrowedId), ContentKey(rawValue: wholeOpId)])
            }
        }

        // The gesture moves BOTH members at once, so both rows sit at the
        // destination locally while the queue still owes the server both moves.
        for headerId in [narrowedId, wholeOpId] {
            try applyOptimisticMove(
                headerId: headerId, accountId: accountId, toFolderPath: "INBOX",
                isInInbox: true, pool: pool)
        }
        let op = PendingOperation(
            type: .move, messageIds: ["300", "301"], accountId: accountId,
            folderPath: "Archive", destinationPath: "INBOX")
        try await pool.write { db in _ = try op.inserted(db) }

        // Attempt 1 settles ONE member and reports it — the shape every
        // multi-member Gmail/Graph move takes on its first attempt.
        let provider = MockEmailProvider()
        await provider.setMoveThrowsOnId(
            "301",
            error: ProviderMembersDispositioned(
                dispositionedMemberIds: ["300"], absentMemberIds: []))
        let context = AccountOperationExecutor.DrainContext()
        let firstOutcome = await AccountManager.shared.executeSingleOp(
            op, provider: provider, context: context)

        // NON-VACUITY: the first attempt really did take the NARROWING path —
        // the durable row survived, narrowed to the member still owed. If it
        // retired whole, this test would be measuring the whole-op arm twice.
        #expect(firstOutcome == .progressed,
                "a narrowing is strict progress, so the executor keeps claiming")
        let narrowed = try await pool.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(narrowed?.messageIds == ["301"],
                "precondition: the row must narrow to the unproven member, not retire whole")
        #expect(narrowed?.status == PendingStatus.queued.rawValue)

        // Attempt 2 is the drain's next pass over the same row, now single-member,
        // which the provider settles silently — the whole-op success arm.
        await provider.clearMoveThrowsOnId()
        guard let remainingOp = narrowed else { return }
        let secondOutcome = await AccountManager.shared.executeSingleOp(
            remainingOp, provider: provider, context: context)
        #expect(secondOutcome == .completed)

        // THE PROPERTY: both proven members produced an AI target, and each one
        // addresses its OWN indexed body.
        let recorded = context.enteredInbox.withLock { $0["\(accountId)|INBOX"] ?? [] }
        #expect(recorded.count == 2, """
            enteredInbox recorded \(recorded.count) of 2 proven members \
            (\(recorded.map(\.messageId).sorted())). A member proven by the narrowing \
            retirement owes the same ADR-IOS-008 decision-3 event as one proven whole; \
            the window-bounded repopulation sweep cannot recover it.
            """)
        let targets = try resolveTargets(context, accountId: accountId, folderPath: "INBOX", pool: pool)
        #expect(targets.count == 2, "every recorded member must resolve to a live inbox row")
        guard targets.count == 2 else { return }
        var resolvedBodies: Set<String> = []
        for target in targets {
            if let body = try await index.bodyText(contentKey: ContentKey(rawValue: target.headerId)) {
                resolvedBodies.insert(body)
            }
            #expect(target.accountId == accountId)
        }
        #expect(resolvedBodies == [narrowedBody, wholeOpBody], """
            the AI targets must address BOTH moved messages' own indexed bodies — got \
            \(resolvedBodies.sorted()). A job whose id addresses no FTS row is silently \
            dropped, which the user cannot tell apart from never enqueueing at all.
            """)
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

        let context = AccountOperationExecutor.DrainContext()
        context.enteredInbox.withLock {
            $0["\(accountId)|INBOX"] = [AccountOperationExecutor.DrainContext.InboxEntry(
                accountId: accountId, messageId: "stale-source-uid", rfc822MessageId: sharedRfc)]
        }
        let targets = try resolveTargets(
            context, accountId: accountId, folderPath: "INBOX", pool: pool)

        #expect(targets.map { $0.headerId } == [lowestId],
                "the first-inserted row must not win merely because the RFC index reaches it first")
    }
}
