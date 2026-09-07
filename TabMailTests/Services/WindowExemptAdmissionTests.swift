/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// ADR-IOS-078 pathway regating (owner directive 2026-08-19): the newest-
/// `SyncConfig.maxRecentEmails` window bounds SYNC-ORIGIN admission only.
/// Arrival/user-intent origins — push/NSE merge, manual open, moved-into-inbox —
/// are window-exempt end-to-end (`AIJob.windowExempt`), while inbox MEMBERSHIP
/// remains an unconditional scope for every origin.
///
/// THE SYSTEM PROPERTIES pinned here, each two-sided:
///  1. A default (sync-origin) enqueue still REFUSES an out-of-window Inbox
///     message, and still ADMITS an in-window one — the install-flood bound is
///     not vacuously "everything refused" or silently "everything admitted".
///     (`ActiveBodyQueue.repopulateFromDatabase` is Inbox-wide and UNBOUNDED, so
///     this admission window is the only thing between a first-install flood
///     and the LLM.)
///  2. A window-exempt enqueue ADMITS the same out-of-window message, and the
///     admitted jobs CARRY the exemption (the executor's re-check consumes it).
///  3. The execution-time retirement policy is origin-aware: gated jobs age out,
///     exempt jobs never window-retire — and the chained action job INHERITS its
///     parent's exemption, so an exempt summary's action cannot be killed by the
///     window either.
///  4. Manually OPENING an out-of-window Inbox message processes it (the
///     production path, observed through the LLM-free no-content shortcut), and
///     the RETAINED `isInInbox` guard still refuses a non-Inbox open — the
///     exemption removed the window, not the inbox scope.
///  5. A message MOVED into the Inbox is admitted exempt through the real
///     post-drain handler, out-of-window included.
///  6. The user-open body-FETCH path (open with the body not yet cached) admits
///     the out-of-window message exempt through
///     `BodyFetchProcessor.flushBatch(_:enableAI:aiWindowExempt:)`, while the
///     SAME flush stays window-gated for its background/sync feeders — the
///     round-1 review hole: the first cut exempted only the body-already-
///     present open arms, so an out-of-window open that had to fetch was still
///     suppressed.
///
/// The push/NSE-merge origin is pinned at the queue seam (property 2): its call
/// site (`NSEDataBridge`'s post-merge downstream loop) runs inside a detached
/// task within the staging merge, which has no deterministic production-path
/// harness; the site passes `windowExempt: true` with the producer's own
/// `item.isInInbox` check.
///
/// Admission observation: `dispatchPending` CLEARS the queue whenever
/// `canProcessAI` is false (always false in the test environment — no session),
/// so an admitted job is only observable with dispatch suppressed
/// (`setDispatchSuppressedForTesting`). The refusal direction needs no
/// suppression, but uses it anyway so that a regression to "admit everything"
/// fails the assert instead of being hidden by the async clear.
@Suite("Window exemption — sync-origin bounded, arrival/user-intent exempt",
       .serialized, .processGlobalState)
struct WindowExemptAdmissionTests {

    // MARK: - Harness

    private func insertHeader(
        accountId: String, uid: String, date: Date, isInInbox: Bool = true,
        folderPath: String = "INBOX", pool: DatabasePool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "window fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: date, snippet: "fixture",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: isInInbox
        )
        header.rfc822MessageId = "<window-\(uid)@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return header
    }

    /// `SyncConfig.maxRecentEmails` + 1 Inbox rows. Returns (oldest, newest):
    /// the oldest is deterministically OUTSIDE the newest-N window, the newest
    /// deterministically inside it.
    private func makeOverfullInbox(
        accountId: String, pool: DatabasePool
    ) throws -> (oldest: MessageHeader, newest: MessageHeader) {
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        var newest: MessageHeader?
        var oldest: MessageHeader?
        for i in 0...SyncConfig.maxRecentEmails {
            let header = try insertHeader(
                accountId: accountId, uid: "w\(i)",
                date: now.addingTimeInterval(TimeInterval(-i)), pool: pool)
            if i == 0 { newest = header }
            oldest = header
        }
        return (oldest!, newest!)
    }

    private func assertOutOfWindow(_ header: MessageHeader, pool: DatabasePool) async throws {
        let inWindow = try await pool.read { db in
            try ActiveAIQueue.recentInboxWindowContains(headerId: header.id, db: db)
        }
        #expect(!inWindow, "fixture must place the target outside the newest-\(SyncConfig.maxRecentEmails) window")
    }

    // MARK: - 1+2. Queue admission: the bound holds for sync origin, yields for exempt origin

    @Test("A sync-origin enqueue refuses an out-of-window inbox message; a window-exempt enqueue admits it, carrying the flag")
    func syncOriginRefusesAndExemptAdmitsOutOfWindow() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (oldest, _) = try makeOverfullInbox(accountId: "acc-wx-1", pool: pool)
        try await assertOutOfWindow(oldest, pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)

        // Sync origin (default): the install-flood bound must still refuse.
        await queue.enqueue(headerId: oldest.id, accountId: oldest.accountId)
        var queued = await queue.queuedJobsForTesting
        #expect(queued.isEmpty,
                "a SYNC-ORIGIN enqueue of an out-of-window inbox message must be refused — the newest-\(SyncConfig.maxRecentEmails) bound is the only protection against the first-install flood")

        // Exempt origin: the same message is admitted, and the jobs carry the flag.
        await queue.enqueue(headerId: oldest.id, accountId: oldest.accountId, windowExempt: true)
        queued = await queue.queuedJobsForTesting
        let mine = queued.filter { $0.headerId == oldest.id }
        #expect(mine.count == 2, "a window-exempt enqueue admits S + R for the out-of-window message")
        #expect(Set(mine.map(\.jobType)) == [.summary, .reply])
        #expect(mine.allSatisfy { $0.windowExempt },
                "admitted arrival-origin jobs must CARRY the exemption — the executor's re-check would otherwise retire them before the model call")
    }

    @Test("A sync-origin enqueue still admits an in-window inbox message (the refusal above is window-caused, not environmental)")
    func syncOriginAdmitsInWindow() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (_, newest) = try makeOverfullInbox(accountId: "acc-wx-2", pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.enqueue(headerId: newest.id, accountId: newest.accountId)
        let queued = await queue.queuedJobsForTesting
        let mine = queued.filter { $0.headerId == newest.id }
        #expect(mine.count == 2,
                "an in-window sync-origin enqueue must be admitted — otherwise the refusal direction of this suite is vacuous")
        #expect(mine.allSatisfy { !$0.windowExempt },
                "sync-origin jobs stay NON-exempt so the executor's age-out retirement keeps enforcing the bound end-to-end")
    }

    // MARK: - 3. Execution-time policy and chain inheritance

    @Test("Window retirement is origin-aware: gated jobs age out, exempt jobs never window-retire")
    func windowRetirementIsOriginAware() {
        let gated = ActiveAIQueue.AIJob(headerId: "h1", accountId: "a1", jobType: .summary)
        let exempt = ActiveAIQueue.AIJob(headerId: "h1", accountId: "a1", jobType: .summary, windowExempt: true)
        // Out of window: only the gated job retires.
        #expect(ActiveAIQueue.windowRetires(job: gated, inRecentWindow: false),
                "a sync-origin job that ages out of the window must retire — the bound stays enforced end-to-end")
        #expect(!ActiveAIQueue.windowRetires(job: exempt, inRecentWindow: false),
                "a window-exempt job must never be window-retired — that would silently undo the exemption at execution time")
        // In window: nobody retires.
        #expect(!ActiveAIQueue.windowRetires(job: gated, inRecentWindow: true))
        #expect(!ActiveAIQueue.windowRetires(job: exempt, inRecentWindow: true))
    }

    @Test("The chained action job inherits its parent's window exemption")
    func chainedActionJobInheritsExemption() {
        let exemptParent = ActiveAIQueue.AIJob(headerId: "h2", accountId: "a2", jobType: .summary, windowExempt: true)
        let gatedParent = ActiveAIQueue.AIJob(headerId: "h3", accountId: "a3", jobType: .summary)

        let exemptChild = ActiveAIQueue.chainedActionJob(after: exemptParent)
        #expect(exemptChild.jobType == .action)
        #expect(exemptChild.headerId == "h2")
        #expect(exemptChild.accountId == "a2")
        #expect(exemptChild.windowExempt,
                "an exempt summary's chained action must inherit the exemption — otherwise the window kills the action half of every arrival-origin job")

        let gatedChild = ActiveAIQueue.chainedActionJob(after: gatedParent)
        #expect(gatedChild.jobType == .action)
        #expect(!gatedChild.windowExempt,
                "a sync-origin summary's chained action stays gated — inheritance must not grant exemptions")
    }

    @Test("An exempt offer upgrades a pending gated twin — dedupe must not swallow the exemption")
    func exemptOfferUpgradesPendingGatedTwin() async throws {
        // The scenario (codex round-1 SPEC finding): a sync-origin job is
        // admitted while in-window, sits pending (offline/backoff), the message
        // ages out, and an arrival event (push/move) then offers the same
        // message exempt. If dedupe swallows the offer, the stored job keeps
        // windowExempt == false and the executor window-retires it — the
        // arrival exemption is silently dropped. THE INVARIANT: after an exempt
        // offer, the pending jobs for that message ARE exempt.
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (_, newest) = try makeOverfullInbox(accountId: "acc-wx-6", pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        // Gated admission first (in-window, so the sync origin admits it).
        await queue.enqueue(headerId: newest.id, accountId: newest.accountId)
        // The arrival's exempt offer for the same message.
        await queue.enqueue(headerId: newest.id, accountId: newest.accountId, windowExempt: true)

        let mine = await queue.queuedJobsForTesting.filter { $0.headerId == newest.id }
        #expect(mine.count == 2, "still exactly one S and one R — the offer must upgrade, not duplicate")
        #expect(mine.allSatisfy { $0.windowExempt },
                "the exempt offer must WIN on dedupe: a pending gated twin that keeps windowExempt == false is window-retired at execution, silently dropping the arrival event")
    }

    @Test("A gated re-offer never downgrades a pending exempt job")
    func gatedOfferNeverDowngradesPendingExemptJob() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (_, newest) = try makeOverfullInbox(accountId: "acc-wx-7", pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.enqueue(headerId: newest.id, accountId: newest.accountId, windowExempt: true)
        // A sync-origin re-offer (in-window, passes the gate, hits dedupe).
        await queue.enqueue(headerId: newest.id, accountId: newest.accountId)

        let mine = await queue.queuedJobsForTesting.filter { $0.headerId == newest.id }
        #expect(mine.count == 2)
        #expect(mine.allSatisfy { $0.windowExempt },
                "exemption is a one-way upgrade: a later sync-origin offer must not strip it")
    }

    @Test("An exempt summary's chained action upgrades a gated action twin already pending from enqueueBatch; a gated chain never downgrades it")
    func chainedActionUpgradesPendingGatedActionTwin() async throws {
        // Round-2 review finding (SPEC): `enqueueBatch` (the sync sweep) enqueues
        // a GATED action job. When an exempt arrival's summary later completes and
        // chains its action, the chain must UPGRADE that pending gated twin — a
        // plain `storage.enqueue` dedupes against it (windowExempt is not identity)
        // and leaves it gated, so the executor window-retires the action half of
        // the arrival-origin job after age-out. THE INVARIANT: after an exempt
        // summary chains its action, the pending action for that message IS exempt;
        // a subsequent gated chain must not strip it. No DB: `chainActionJob` and
        // the storage dedupe operate purely on in-memory job identity.
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)

        // Sync sweep seeds a gated S + R + A for the message.
        await queue.enqueueBatch([(headerId: "chain-h", accountId: "chain-a")])
        let seeded = await queue.queuedJobsForTesting.filter { $0.headerId == "chain-h" }
        #expect(Set(seeded.map(\.jobType)) == [.summary, .reply, .action],
                "enqueueBatch must seed a gated action twin — otherwise this test is vacuous")
        #expect(seeded.allSatisfy { !$0.windowExempt })

        // An exempt arrival's summary completes and chains its (exempt) action.
        let exemptSummary = ActiveAIQueue.AIJob(
            headerId: "chain-h", accountId: "chain-a", jobType: .summary, windowExempt: true)
        await queue.chainActionJob(after: exemptSummary)

        let afterExempt = await queue.queuedJobsForTesting.filter { $0.headerId == "chain-h" && $0.jobType == .action }
        #expect(afterExempt.count == 1, "still exactly one action job — the chain upgrades, not duplicates")
        #expect(afterExempt.allSatisfy { $0.windowExempt },
                "the exempt chained action must UPGRADE the pending gated action twin — a rejected offer leaves it gated and window-retirable")

        // A later gated summary's chain must not downgrade the now-exempt action.
        let gatedSummary = ActiveAIQueue.AIJob(
            headerId: "chain-h", accountId: "chain-a", jobType: .summary)
        await queue.chainActionJob(after: gatedSummary)
        let afterGated = await queue.queuedJobsForTesting.filter { $0.headerId == "chain-h" && $0.jobType == .action }
        #expect(afterGated.count == 1)
        #expect(afterGated.allSatisfy { $0.windowExempt },
                "exemption is a one-way upgrade at the chain site too: a later gated chain must not strip it")
    }

    @Test("windowExempt is context, not identity: exempt and gated twins dedupe as one job")
    func windowExemptIsNotJobIdentity() {
        var storage = QueueStorage<ActiveAIQueue.AIJob>()
        let gated = ActiveAIQueue.AIJob(headerId: "h4", accountId: "a4", jobType: .summary)
        let exempt = ActiveAIQueue.AIJob(headerId: "h4", accountId: "a4", jobType: .summary, windowExempt: true)
        #expect(gated == exempt, "identity is (headerId, jobType) — accountId and windowExempt are context")
        _ = storage.enqueue(gated)
        let addedTwin = storage.enqueue(exempt)
        #expect(!addedTwin, "the exempt twin dedupes against the gated job already queued")
        #expect(storage.count == 1)
    }

    // MARK: - 4. Manual open: window-exempt, inbox-scoped

    @Test("Manually opening an out-of-window no-content inbox message processes it (no-content shortcut writes)")
    func manualOpenProcessesOutOfWindowMessage() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (oldest, _) = try makeOverfullInbox(accountId: "acc-wx-3", pool: pool)
        try await assertOutOfWindow(oldest, pool: pool)
        // No-content body row: the direct path's LLM-free shortcut is the
        // deterministic observable ("This message has no content." + delete tag).
        let body = MessageBody(contentKey: ContentKey(rawValue: oldest.id), htmlContent: nil)
        try await pool.write { db in try body.insert(db) }

        await AccountManager.shared.processOpenedMessage(oldest)

        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: oldest.id) }
        #expect(after?.summaryBlurb == "This message has no content.",
                "a user-opened out-of-window inbox message must be processed — manual open is window-exempt (ADR-IOS-078 pathway regating)")
        #expect(after?.actionTag == ActionTag.delete,
                "the no-content shortcut also stamps the delete tag")
    }

    @Test("Opening a non-inbox message still processes nothing — the isInInbox guard is retained")
    func manualOpenStillRefusesNonInboxMessage() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-wx-4"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)
        let archived = try insertHeader(
            accountId: accountId, uid: "arch-1", date: Date(),
            isInInbox: false, folderPath: "Archive", pool: pool)
        let body = MessageBody(contentKey: ContentKey(rawValue: archived.id), htmlContent: nil)
        try await pool.write { db in try body.insert(db) }

        await AccountManager.shared.processOpenedMessage(archived)

        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: archived.id) }
        #expect(after?.summaryBlurb == nil,
                "window exemption must NOT remove the inbox scope: a non-inbox open still processes nothing")
        #expect(after?.actionTag == nil)
    }

    // MARK: - 5. Moved into the inbox: exempt through the real post-drain handler

    @Test("A message moved into the inbox is admitted window-exempt, even when out of window")
    func moveIntoInboxAdmitsExemptOutOfWindow() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-wx-5"
        let (_, _) = try makeOverfullInbox(accountId: accountId, pool: pool)
        // The moved-in member: OLDER than every fixture row, so out of window
        // among the (window+2) inbox rows — the hardest case for the exemption.
        let moved = try insertHeader(
            accountId: accountId, uid: "moved-1",
            date: Date().addingTimeInterval(-3_600), pool: pool)
        try await assertOutOfWindow(moved, pool: pool)

        // Shared queue: the handler enqueues on `ActiveAIQueue.shared`. The
        // restores at the end are AWAITED — never `defer { Task { … } }`, which
        // only ENQUEUES actor jobs that can land after the process-global lock
        // is released (the `TestProviderRegistry.withRegisteredProvider`
        // contract; round-1 review finding). No statement between here and the
        // restores can throw, so the single awaited exit is every exit.
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(true)
        await ActiveAIQueue.shared.clearForTesting()

        let key = "\(accountId)|INBOX"
        let context = AccountOperationExecutor.DrainContext()
        context.enteredInbox.withLock {
            $0[key] = [AccountOperationExecutor.DrainContext.InboxEntry(
                accountId: accountId, messageId: "moved-1",
                rfc822MessageId: moved.rfc822MessageId)]
        }
        await AccountManager.shared.enqueueAIForMembersThatEnteredInbox(
            key: key, folderPath: "INBOX", context: context)

        let queued = await ActiveAIQueue.shared.queuedJobsForTesting
        let mine = queued.filter { $0.headerId == moved.id }
        #expect(mine.count == 2,
                "a member that entered the inbox by move must be admitted regardless of the window — gating it would recreate the user-must-click gap ADR-IOS-008 decision 3 closed")
        #expect(Set(mine.map(\.jobType)) == [.summary, .reply])
        #expect(mine.allSatisfy { $0.windowExempt },
                "moved-into-inbox jobs are window-exempt end-to-end (coordinator-ruled, ADR-IOS-078)")

        await ActiveAIQueue.shared.clearForTesting()
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(false)
    }

    // MARK: - 6. User-open body fetch: the deferred-body half of the manual-open exemption

    @Test("The user-open body-fetch flush admits an out-of-window inbox message exempt; the default (sync-origin) flush stays gated")
    func userOpenBodyFetchFlushExemptSyncFlushGated() async throws {
        // Round-1 review finding (Claude F1): `processOpenedMessage` covers only
        // the body-already-present arms of a manual open. When the open must
        // FETCH the body, the AI enqueue happens later, inside
        // `BodyFetchProcessor.flushBatch` — and the first cut left that producer
        // window-gated, so an out-of-window open with an unfetched body was
        // silently suppressed (only Retry recovered). THE INVARIANT, two-sided
        // at the changed seam: the flush admits EXEMPT when its caller declares
        // user-open origin (`AccountManager.fetchBody` → `fetchAndProcess(
        // aiWindowExempt: true)`), and the same flush still refuses by window
        // for its background/sync feeders (the default).
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (oldest, _) = try makeOverfullInbox(accountId: "acc-wx-8", pool: pool)
        try await assertOutOfWindow(oldest, pool: pool)

        // flushBatch admits an item downstream only after its FTS write is
        // confirmed (`updateBodies` returns the written set), so the FTS header
        // row must pre-exist — same seeding as WriteTierRoutingTests.
        let key = ContentKey(rawValue: oldest.id)
        try await SearchIndex.shared.removeMessages(contentKeys: [key])
        _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
            contentKey: key, headerId: oldest.id, messageId: oldest.messageId,
            subject: oldest.subject, from: "\(oldest.from) <\(oldest.fromAddress)>",
            to: oldest.to, dateMs: Int64(oldest.date.timeIntervalSince1970 * 1000)
        )])
        let item = BodyFetchProcessor.ProcessedItem(
            contentKey: key, headerId: oldest.id, accountId: oldest.accountId,
            isInInbox: true, body: "window exemption flush fixture body",
            snippet: "window exemption flush fixture snippet"
        )

        // Shared queue (flushBatch hardwires `ActiveAIQueue.shared`); restores
        // are AWAITED on the single exit — nothing below can throw. The
        // `enableAI: true` arm also offers the item to ActiveEmbeddingQueue on the
        // same singleton; its dispatch no-ops while EmbeddingService.shared is nil
        // (always, in unit tests), so the offered item would sit pending — this
        // suite clears BOTH queues before and after so it leaves no residue for a
        // later suite (round-2 review finding).
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(true)
        await ActiveAIQueue.shared.clearForTesting()
        await ActiveEmbeddingQueue.shared.clearForTesting()

        // Default flush (background/sync feeders): the window bound must refuse.
        await BodyFetchProcessor.flushBatch([item], enableAI: true)
        let afterSync = await ActiveAIQueue.shared.queuedJobsForTesting.filter { $0.headerId == oldest.id }
        #expect(afterSync.isEmpty,
                "the body pipeline's DEFAULT flush stays window-gated — it also feeds the unbounded background producers, and this is the install-flood bound")

        // User-open flush: the same item is admitted, exempt end-to-end.
        await BodyFetchProcessor.flushBatch([item], enableAI: true, aiWindowExempt: true)
        let afterOpen = await ActiveAIQueue.shared.queuedJobsForTesting.filter { $0.headerId == oldest.id }
        #expect(afterOpen.count == 2,
                "a user-open fetch must admit the out-of-window message — the open is user intent regardless of which arm supplies the body (ADR-IOS-078 pathway regating)")
        #expect(Set(afterOpen.map(\.jobType)) == [.summary, .reply])
        #expect(afterOpen.allSatisfy { $0.windowExempt },
                "jobs admitted for a user-open fetch must CARRY the exemption — the executor's re-check would otherwise retire them before the model call")

        await ActiveAIQueue.shared.clearForTesting()
        await ActiveEmbeddingQueue.shared.clearForTesting()
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(false)
        // Best-effort FTS hygiene (after the restores; ids are suite-unique).
        try? await SearchIndex.shared.removeMessages(contentKeys: [key])
    }
}
