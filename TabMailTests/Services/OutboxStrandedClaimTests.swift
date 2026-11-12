/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Regression coverage for the post-claim provider-loss window in the Outbox.
///
/// `v1.6.38` and current HEAD have the same owning sequence: the drain selects
/// a row while its provider work queue exists, `atomicClaim` changes that exact
/// unsent row from `.queued` to `.sending`, and `sendSingleOutboxMessage` then
/// returns if the work queue vanished. The row is no longer selected by an
/// ordinary drain, so re-registering the provider in the same process cannot
/// send it.
///
/// These tests drive the durable state directly through the existing claim
/// seam. They intentionally do not involve RootView, app-launch reconciliation,
/// notifications, sleeps, or a copied drain implementation.
///
/// ⚠️ RENAMED (`IOS-TEST-002`, second half). **Previous type name:
/// `OutboxStrandedClaimXfailTests`; previous file name:
/// `OutboxStrandedClaimXfailTests.swift`.** "Xfail" announces an
/// expected-failure test, and this file has never contained one — three `@Test`s,
/// no `withKnownIssue` anywhere in it, then or now. The target's single expected
/// failure lives in another file entirely, so a reader who came here looking for
/// it (or who cited this suite as evidence that the stranded-claim window is a
/// KNOWN failure rather than a FIXED one) was misled by the name alone. No test
/// was added, removed, renamed or re-scoped: only the misleading type and file
/// name changed. The `@Suite` display name — "Outbox post-claim provider loss" —
/// was already accurate and is unchanged.
@Suite(
    "Outbox post-claim provider loss",
    .serialized,
    .processGlobalState
)
struct OutboxStrandedClaimTests {
    private func makeTestDB(accountId: String) throws -> (
        pool: DatabasePool,
        directory: URL,
        previous: AppDatabase?
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }

        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "sender@example.com",
                displayName: "Sender",
                provider: .imap
            )
            account.id = accountId
            try account.insert(db)
        }
        return (pool, directory, previous)
    }

    private func restore(
        pool: DatabasePool,
        directory: URL,
        previous: AppDatabase?
    ) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: directory
        )
    }

    @discardableResult
    private func seedOutbox(
        _ pool: DatabasePool,
        accountId: String,
        id: String,
        status: OutboxStatus = .queued,
        sentAt: Date? = nil
    ) throws -> OutboxMessage {
        let draft = DraftMessage(
            to: ["recipient@example.com"],
            subject: "Post-claim provider loss \(id)",
            body: "Body"
        )
        var message = OutboxMessage(accountId: accountId, draft: draft)
        message.id = id
        message.status = status.rawValue
        message.sentAt = sentAt
        message.holdUntil = Date().addingTimeInterval(-3600)
        try pool.write { try message.insert($0) }
        return message
    }

    private func row(_ pool: DatabasePool, id: String) throws -> OutboxMessage? {
        try pool.read { try OutboxMessage.fetchOne($0, key: id) }
    }

    @Test("A claimed unsent row recovers in-process after its provider disappears")
    func claimedUnsentRowRecoversAfterProviderLoss() async throws {
        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-stranded-\(suffix)"
        let outboxId = "outbox-stranded-\(suffix)"
        let (pool, directory, previous) = try makeTestDB(accountId: accountId)
        defer { restore(pool: pool, directory: directory, previous: previous) }

        let provider = MockEmailProvider()
        let message = try seedOutbox(
            pool,
            accountId: accountId,
            id: outboxId
        )
        let claimed = await AccountManager.shared.atomicClaimForTesting(message)
        #expect(claimed)

        let persistedClaim = try row(pool, id: outboxId)
        let claimedRow = try #require(persistedClaim)
        #expect(claimedRow.outboxStatus == .sending)
        #expect(claimedRow.sentAt == nil)
        #expect(await provider.sentDrafts.isEmpty)

        let messageId = try #require(claimedRow.sentMessageId)
        await AccountManager.shared.sendClaimedOutboxMessageForTesting(
            message,
            messageId: messageId
        )

        let recoveredClaim = try row(pool, id: outboxId)
        let recoveredRow = try #require(recoveredClaim)
        #expect(recoveredRow.outboxStatus == .queued)
        #expect(recoveredRow.sentAt == nil)
        #expect(recoveredRow.sentMessageId == messageId)
        #expect(await provider.sentDrafts.isEmpty)

        // The provider returns in the same process. The ordinary drain owns the
        // preserved `.queued` row and sends it once.
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider
        )
        await AccountManager.shared.drainOutbox()

        #expect(
            await provider.sentDrafts.count == 1,
            "ordinary same-process drain must send the preserved intention exactly once"
        )
        let finalizedRow = try row(pool, id: outboxId)
        #expect(
            finalizedRow == nil,
            "a successful send must finalize the exact durable row"
        )
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    /// #531 — **a send the user already made survives an app update, goes out
    /// once, and its draft is not pushed back to Drafts.** The release boundary
    /// re-queues saves only for unsent drafts that no `outboxMessage` owns; this
    /// pins the other half: the outbox-owned draft's send is still accounted
    /// for, and no `.saveDraft` (a stray Drafts copy) is admitted for it.
    @Test("A pending outbox send survives the app-update boundary, goes out once, and leaves no Drafts copy")
    @MainActor
    func pendingOutboxSendSurvivesTheReleaseBoundary() async throws {
        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-boundary-send-\(suffix)"
        let outboxId = "outbox-boundary-send-\(suffix)"
        let draftId = "draft-boundary-send-\(suffix)"
        let (pool, directory, previous) = try makeTestDB(accountId: accountId)
        defer { restore(pool: pool, directory: directory, previous: previous) }

        let now = Date().timeIntervalSince1970
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: accountId, toJSON: "[\"recipient@example.com\"]",
                ccJSON: "[]", bccJSON: "[]", subject: "Sent before the update", body: "Body",
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: now, updatedAt: now, serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
            // The previous release's queue still held this draft's save.
            var save = PendingOperation.draftSave(
                draftId: draftId, accountId: accountId, folderPath: "Drafts", instanceEpoch: "E1")
            try save.insert(db)
        }
        var message = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Sent before the update", body: "Body"))
        message.id = outboxId
        message.draftId = draftId
        message.instanceEpoch = "E1"
        message.holdUntil = Date().addingTimeInterval(-3600)
        let storedMessage = message
        try await pool.write { try storedMessage.insert($0) }

        let ledger = IntentionLedger()
        ledger.record(label: "send queued before update", durableIdentity: outboxId) { db in
            try OutboxMessage.fetchOne(db, key: outboxId) == nil
        }

        // THE APP UPDATE.
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO appReleaseStamp (id, release) VALUES (1, '0.0.1 (1)')
                ON CONFLICT(id) DO UPDATE SET release = excluded.release
                """)
        }
        let crossed = try AppDatabase.retirePreviousReleaseActionQueue(
            on: pool, currentRelease: AppDatabase.currentAppRelease)
        #expect(crossed)
        let opsAfterBoundary = try await pool.read { try PendingOperation.fetchAll($0) }
        #expect(opsAfterBoundary.isEmpty, """
            the boundary re-queued work for a draft the Outbox owns: \
            \(opsAfterBoundary.map(\.type))
            """)
        #expect(try row(pool, id: outboxId) != nil, "the boundary destroyed the queued send")

        let provider = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainOutbox()

        #expect(await provider.sentDrafts.count == 1, "the send must go out exactly once")
        let draftSaves = await provider.callLog.filter { $0.hasPrefix("saveDraft") }
        #expect(draftSaves.isEmpty, "a stray Drafts copy was pushed for a sent draft: \(draftSaves)")
        let outcomes = await ledger.settle(pool: pool, reportedIds: [])
        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome == .executed)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    /// D-3 — Outbox Reliability Rule 2: "Never `try?` on outbox state
    /// transitions ... Silent swallowing = message loss or double-send."
    ///
    /// `sendSingleOutboxMessage`'s attachment-load branch wrapped its
    /// `.sending → .failed` write in `try?`. That write is the ONLY thing that
    /// moves the claimed row off `.sending`, and `drainOutbox` selects `.queued`
    /// ONLY, so a swallowed failure left the row where nothing would ever look
    /// at it again: not drained, not `.failed`, therefore offering the user no
    /// Retry either. The message became invisible and unsendable with nothing
    /// logged.
    ///
    /// THE SYSTEM PROPERTY, which is what this asserts: **after the attempt, the
    /// row is in a state some drain will act on.** It does not assert which
    /// branch produced it or that any particular error was logged.
    ///
    /// The failure is injected with a SQLite trigger rather than a production
    /// seam: the trigger aborts exactly the `status = 'failed'` transition and
    /// nothing else, so `retryWrite`'s three attempts all fail the way a real
    /// disk/lock failure would, while the recovery path's `status = 'queued'`
    /// write is untouched.
    ///
    /// RED PROOF (recorded): with the `try?` restored in
    /// `sendSingleOutboxMessage`, this fails on `.outboxStatus == .queued` —
    /// observed `.sending` — and on the `drainOutbox` send count, which stays 0
    /// because the stranded row is invisible to the drain.
    @Test("A failed status write cannot strand an outbox row where no drain will see it")
    func failedStatusWriteFailureLeavesTheRowDrainable() async throws {
        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-strand-write-\(suffix)"
        let outboxId = "outbox-strand-write-\(suffix)"
        let (pool, directory, previous) = try makeTestDB(accountId: accountId)
        defer { restore(pool: pool, directory: directory, previous: previous) }

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {

            var seeded = try seedOutbox(pool, accountId: accountId, id: outboxId)
            // Point the row at an attachments directory that does not exist, so
            // `loadAttachments()` throws and the send takes the branch under test.
            // Outbox Rule 5 — never send an email with missing attachments.
            seeded.attachmentsDirName = "missing-attachments-\(suffix)"
            let message = seeded
            try await pool.write { try message.update($0) }

            let claimed = await AccountManager.shared.atomicClaimForTesting(message)
            #expect(claimed)
            let claimedRow = try #require(try row(pool, id: outboxId))
            #expect(claimedRow.outboxStatus == .sending)

            // Make the `.failed` transition — and only that transition — impossible.
            try await pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER block_failed_transition
                    BEFORE UPDATE OF status ON outboxMessage
                    WHEN NEW.status = 'failed'
                    BEGIN
                        SELECT RAISE(ABORT, 'simulated durable write failure');
                    END;
                    """)
            }
            defer { try? pool.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS block_failed_transition") } }

            let messageId = try #require(claimedRow.sentMessageId)
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(
                message, messageId: messageId)

            let after = try #require(try row(pool, id: outboxId))
            #expect(
                after.outboxStatus != .sending,
                "a row left at .sending with sentAt == nil is invisible to every drain — that is the dropped send Rule 2 exists to prevent"
            )
            #expect(after.outboxStatus == .queued)
            #expect(after.sentAt == nil)
            #expect(
                await provider.sentDrafts.isEmpty,
                "nothing may be sent: the attachments could not be loaded"
            )

            // NON-VACUITY, and the property that matters to the user: the recovered
            // row is genuinely reachable again. Dropping the trigger models the
            // transient write failure clearing; the ordinary drain then owns the row
            // and completes the intention rather than leaving it stranded forever.
            try await pool.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS block_failed_transition") }
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET attachmentsDirName = NULL WHERE id = ?",
                    arguments: [outboxId])
            }
            await AccountManager.shared.drainOutbox()
            #expect(
                await provider.sentDrafts.count == 1,
                "the preserved intention must be drainable once the failure clears"
            )
        }
    }

    @Test("A stale rollback cannot clobber failed, sent, queued, or unrelated rows")
    func staleRollbackDoesNotClobberNewerState() async throws {
        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-fence-\(suffix)"
        let (pool, directory, previous) = try makeTestDB(accountId: accountId)
        defer { restore(pool: pool, directory: directory, previous: previous) }

        let failedId = "outbox-failed-\(suffix)"
        let sentId = "outbox-sent-\(suffix)"
        let queuedId = "outbox-queued-\(suffix)"
        let targetId = "outbox-target-\(suffix)"
        let unrelatedId = "outbox-unrelated-\(suffix)"
        let sentAt = Date().addingTimeInterval(-120)

        try seedOutbox(
            pool,
            accountId: accountId,
            id: failedId,
            status: .failed
        )
        try seedOutbox(
            pool,
            accountId: accountId,
            id: sentId,
            status: .sending,
            sentAt: sentAt
        )
        try seedOutbox(
            pool,
            accountId: accountId,
            id: queuedId,
            status: .queued
        )
        try seedOutbox(
            pool,
            accountId: accountId,
            id: targetId,
            status: .sending
        )
        try seedOutbox(
            pool,
            accountId: accountId,
            id: unrelatedId,
            status: .sending
        )

        #expect(
            await AccountManager.shared
                .requeueClaimedOutboxMessageForTesting(failedId) == false
        )
        #expect(
            await AccountManager.shared
                .requeueClaimedOutboxMessageForTesting(sentId) == false
        )
        #expect(
            await AccountManager.shared
                .requeueClaimedOutboxMessageForTesting(queuedId) == false
        )
        #expect(
            await AccountManager.shared
                .requeueClaimedOutboxMessageForTesting(targetId) == true
        )

        let failedResult = try row(pool, id: failedId)
        let sentResult = try row(pool, id: sentId)
        let queuedResult = try row(pool, id: queuedId)
        let targetResult = try row(pool, id: targetId)
        let unrelatedResult = try row(pool, id: unrelatedId)
        let failed = try #require(failedResult)
        let sent = try #require(sentResult)
        let queued = try #require(queuedResult)
        let target = try #require(targetResult)
        let unrelated = try #require(unrelatedResult)
        #expect(failed.outboxStatus == .failed)
        #expect(failed.sentAt == nil)
        #expect(sent.outboxStatus == .sending)
        let persistedSentAtResult = sent.sentAt
        let persistedSentAt = try #require(persistedSentAtResult)
        #expect(abs(persistedSentAt.timeIntervalSince(sentAt)) < 0.001)
        #expect(queued.outboxStatus == .queued)
        #expect(queued.sentAt == nil)
        #expect(target.outboxStatus == .queued)
        #expect(target.sentAt == nil)
        #expect(unrelated.outboxStatus == .sending)
        #expect(unrelated.sentAt == nil)
    }
}
