/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// iOS #67 — the third manual-open arm. ADR-IOS-078 made a manual open
/// window-exempt on the two arms where the open drives the work (durable body
/// → `processOpenedMessage`; unfetched body → the open's own fetch flushes
/// exempt). When `ActiveBodyQueue` ALREADY owns the fetch, `loadBody` only polls,
/// the body lands through the queue's default (gated) flush, and the poll's
/// `adoptReadyBody` displayed it with no AI trigger — so an out-of-window Inbox
/// open in that state got no summary until Retry or reopen.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Opening an out-of-window Inbox message whose body is owned by the
///     background queue produces AI output once the body lands — through the
///     REAL `loadBody` → `isQueuedOrInFlight` → `startBodyPoll` arm, at BOTH of
///     the poll's adoption sites (the 2 s tick, and the entry check for a body
///     already durable when the poll starts). Observed via the LLM-free
///     no-content shortcut (same observable as `WindowExemptAdmissionTests`).
///  2. The wrong-message oracle (`IOS-BODY-004`): AI is initiated ONLY for the
///     identity whose body was adopted, and only when that header is present.
///     An impostor row sharing the opened message's `rfc822MessageId` and
///     subject — the exact bait the retired match-based recoveries adopted — is
///     untouched; a header that differs from the adopted id, or is missing,
///     initiates nothing for either identity.
///  3. The trigger belongs to the POLL's adoption sites only. The other two
///     production callers of `adoptReadyBody` — the merge-commit catch-up and
///     the staged-publish seed — adopt for display and initiate no AI (the NSE
///     merge that produced those bodies enqueues exempt itself).
///
/// `.processGlobalState`: `AccountManager.shared.processOpenedMessage` reads
/// `AppDatabase.shared`, and the queue-owned state is set on
/// `ActiveBodyQueue.shared`. `NSEDataBridge`'s staged snapshot is global too.
@Suite("Poll adoption triggers opened-message AI (iOS #67)", .serialized, .processGlobalState)
struct PollAdoptionAITriggerTests {

    // MARK: - Harness

    private func insertHeader(
        accountId: String, uid: String, date: Date, rfc822MessageId: String? = nil,
        subject: String? = nil, bodyComplete: Bool = true, pool: DatabasePool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: subject ?? "poll fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: date, snippet: "fixture",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
            accountId: accountId, folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId ?? "<poll-\(uid)@example.com>"
        header.headerComplete = true
        header.bodyComplete = bodyComplete
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return header
    }

    /// `SyncConfig.maxRecentEmails` + 1 Inbox rows, newest first. Returns the
    /// oldest, which is deterministically OUTSIDE the newest-N window.
    private func makeOverfullInbox(accountId: String, pool: DatabasePool) throws -> MessageHeader {
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        var oldest: MessageHeader?
        for i in 0...SyncConfig.maxRecentEmails {
            oldest = try insertHeader(
                accountId: accountId, uid: "w\(i)",
                date: now.addingTimeInterval(TimeInterval(-i)), pool: pool)
        }
        return oldest!
    }

    private func assertOutOfWindow(_ header: MessageHeader, pool: DatabasePool) async throws {
        let inWindow = try await pool.read { db in
            try ActiveAIQueue.recentInboxWindowContains(headerId: header.id, db: db)
        }
        #expect(!inWindow, "fixture must place the target outside the newest-\(SyncConfig.maxRecentEmails) window")
    }

    /// A no-content durable body: the direct path's LLM-free shortcut
    /// ("This message has no content." + delete tag) is the observable.
    private func insertNoContentBody(_ id: String, pool: DatabasePool) async throws {
        try await pool.write { db in
            try MessageBody(contentKey: ContentKey(rawValue: id), htmlContent: nil).insert(db)
        }
    }

    private func header(_ id: String, pool: DatabasePool) async throws -> MessageHeader? {
        try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    /// Poll the durable row until the no-content shortcut has stamped it, or
    /// `seconds` elapse. The poll's DB cadence is 2 s and the trigger runs on
    /// the manager's write lane, so a few ticks of headroom are needed.
    private func waitForSummary(_ id: String, pool: DatabasePool, seconds: Double) async throws -> MessageHeader? {
        for _ in 0..<Int(seconds * 10) {
            if let h = try await header(id, pool: pool), h.summaryBlurb != nil { return h }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await header(id, pool: pool)
    }

    /// The direct path runs on the manager's write lane after a hop; a
    /// NEGATIVE assertion needs a settle that comfortably exceeds the positive
    /// cases' observed latency (milliseconds) before reading the row.
    private func settleForAbsentAI() async throws {
        try await Task.sleep(for: .milliseconds(1_500))
    }

    private func expectProcessed(_ h: MessageHeader?, _ why: Comment) {
        #expect(h?.summaryBlurb == "This message has no content.", why)
        #expect(h?.actionTag == ActionTag.delete, why)
    }

    private func expectUntouched(_ h: MessageHeader?, _ why: Comment) {
        #expect(h != nil, "the row must still exist for its fields to mean anything")
        #expect(h?.summaryBlurb == nil, why)
        #expect(h?.actionTag == nil, why)
    }

    /// Put the shared body queue in the "owns this fetch" state without a
    /// provider or a dispatch — exactly what `loadBody`'s `isQueuedOrInFlight`
    /// reads. Callers release it with `releaseQueue`.
    private func makeQueueOwnFetch(of h: MessageHeader) async {
        let item = ActiveBodyQueue.Item(
            headerId: h.id, accountId: h.accountId, folderPath: h.folderPath,
            messageId: h.messageId, isInInbox: h.isInInbox)
        let admitted = await ActiveBodyQueue.shared.admit(item)
        #expect(admitted, "the queue must hold the item, or loadBody takes the own-fetch arm and the test is vacuous")
        #expect(await ActiveBodyQueue.shared.isQueuedOrInFlight(headerId: h.id))
    }

    private func releaseQueue(_ h: MessageHeader) async {
        await ActiveBodyQueue.shared.cancelAllInFlight()
        #expect(!(await ActiveBodyQueue.shared.isQueuedOrInFlight(headerId: h.id)))
    }

    // MARK: - 1. The 2 s-tick adoption site, through the real queue-owned arm

    @Test("Queue-owned open: the body lands AFTER the poll's entry check, the 2 s tick adopts it, and the opened identity alone is processed")
    @MainActor
    func queueOwnedOpenTickAdoptionProcessesAdoptedIdentityOnly() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-p67-1"
        let opened = try makeOverfullInbox(accountId: accountId, pool: pool)
        try await assertOutOfWindow(opened, pool: pool)

        // The impostor: same rfc822MessageId and subject as the opened message,
        // also out of window, body present, nothing processed. A match-based
        // recovery (the retired IOS-BODY-004 revisions) would resolve to this row.
        let impostor = try insertHeader(
            accountId: accountId, uid: "impostor",
            date: opened.date.addingTimeInterval(-1),
            rfc822MessageId: opened.rfc822MessageId, subject: opened.subject, pool: pool)
        try await assertOutOfWindow(impostor, pool: pool)
        try await insertNoContentBody(impostor.id, pool: pool)

        await makeQueueOwnFetch(of: opened)

        let fetchCalls = Mutex(0)
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { _ in fetchCalls.withLock { $0 += 1 } })
        defer { vm.cancelBodyPollForTesting() }

        await vm.loadBody()

        // The queue-owned arm: no own fetch, a poll instead.
        #expect(vm.hasStartedBodyPollForTesting, "loadBody must defer to the poll when the queue owns the fetch")
        #expect(fetchCalls.withLock { $0 } == 0, "loadBody must not compete with the queue's fetch")
        #expect(vm.messageBody == nil)

        // Let the poll's IMMEDIATE entry check run and MISS (a pure DB read,
        // milliseconds) before the body exists, so the adoption below can only
        // happen at a 2 s tick — this pins the tick site, not the entry site.
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.messageBody == nil, "entry check must have missed — the body does not exist yet")

        // The queue lands the body. Nothing else in this test can write AI
        // fields: the queue's own flush is not running, and no dispatch is
        // scheduled.
        try await insertNoContentBody(opened.id, pool: pool)

        let after = try await waitForSummary(opened.id, pool: pool, seconds: 8)
        #expect(vm.messageBody != nil, "the poll must adopt the queue-written body")
        expectProcessed(after, "an out-of-window open whose body lands via the background queue must still be processed — the third manual-open arm is window-exempt like the other two (iOS #67)")

        // Wrong-message oracle: the impostor sharing the opened identity's
        // rfc822MessageId and subject is untouched.
        expectUntouched(try await header(impostor.id, pool: pool),
                        "AI output must land only on the identity the poll adopted — never on a row found by matching (IOS-BODY-004)")

        await releaseQueue(opened)
    }

    // MARK: - 2. The entry-check adoption site (body already durable when the poll starts)

    @Test("Poll entry check: a body already durable when the poll starts is adopted at once and the opened identity is processed before the first 2 s tick")
    @MainActor
    func pollEntryAdoptionProcessesOpenedIdentity() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let opened = try makeOverfullInbox(accountId: "acc-p67-2", pool: pool)
        try await assertOutOfWindow(opened, pool: pool)
        // The queue landed the body between loadBody's checks and the poll's
        // start (or loadBody was cancelled mid-read and deferred here): the body
        // is durable BEFORE the poll's entry check.
        try await insertNoContentBody(opened.id, pool: pool)

        let fetchCalls = Mutex(0)
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { _ in fetchCalls.withLock { $0 += 1 } })
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.message == nil, "no header yet — the poll's own header recovery must supply it")

        let started = Date()
        vm.startBodyPoll()

        let after = try await waitForSummary(opened.id, pool: pool, seconds: 8)
        let elapsed = Date().timeIntervalSince(started)
        #expect(vm.messageBody != nil, "the entry check must adopt the durable body")
        #expect(vm.message?.id == opened.id, "the poll's header recovery must have resolved the opened header")
        expectProcessed(after, "a body already durable at poll start must be processed through the entry-check adoption site, not left for Retry (iOS #67)")
        #expect(elapsed < 1.5, "processing must come from the ENTRY check — the first 2 s tick cannot have fired yet (elapsed \(elapsed)s)")
        #expect(fetchCalls.withLock { $0 } == 0, "the entry check is a pure DB read — no server fetch")
    }

    // MARK: - 3. The two refusals of the trigger, driven directly

    @Test("Trigger refusals: a header that differs from the adopted id, or a missing header, initiates AI for NEITHER identity; a matching header initiates it")
    @MainActor
    func triggerRefusesMismatchedOrMissingHeader() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-p67-3"
        let a = try makeOverfullInbox(accountId: accountId, pool: pool)
        let b = try insertHeader(accountId: accountId, uid: "b", date: a.date.addingTimeInterval(-1), pool: pool)
        try await assertOutOfWindow(a, pool: pool)
        try await assertOutOfWindow(b, pool: pool)
        // Both rows have adoptable no-content bodies, so whichever identity the
        // trigger admitted WOULD be processed — the negative cases are two-sided.
        try await insertNoContentBody(a.id, pool: pool)
        try await insertNoContentBody(b.id, pool: pool)

        let vm = MessageDetailViewModel(messageId: a.id, dbPool: pool, fetchBodyOverride: { _ in })

        // (i) Missing header: the poll adopted A's body but header recovery has
        // not landed (cancelled-open recovery still pending).
        #expect(vm.message == nil)
        vm.processOpenedMessageAfterPollAdoption(adoptedId: a.id)
        try await settleForAbsentAI()
        expectUntouched(try await header(a.id, pool: pool), "no header ⇒ no AI is initiated for the adopted id")
        expectUntouched(try await header(b.id, pool: pool), "no header ⇒ no AI is initiated for any other row either")

        // (ii) Header re-resolved to B across the adoption await while the body
        // read was keyed on A: neither identity may be processed.
        vm._testSeedMessage(b)
        vm.processOpenedMessageAfterPollAdoption(adoptedId: a.id)
        try await settleForAbsentAI()
        expectUntouched(try await header(a.id, pool: pool), "a header that differs from the adopted id must not process the adopted row")
        expectUntouched(try await header(b.id, pool: pool), "…and must not process the current header's row either — that would be AI keyed off a body it never adopted")

        // (iii) Positive control: the header matches the adopted id.
        vm._testSeedMessage(a)
        vm.processOpenedMessageAfterPollAdoption(adoptedId: a.id)
        expectProcessed(try await waitForSummary(a.id, pool: pool, seconds: 5), "a matching header initiates the exempt direct path for the adopted identity")
        expectUntouched(try await header(b.id, pool: pool), "and still only for that identity")
    }

    // MARK: - 4. The other two adoption callers initiate no AI

    @Test("Merge-commit catch-up adopts the body for display and initiates no AI")
    @MainActor
    func mergeCommitCatchUpDoesNotTriggerAI() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let opened = try makeOverfullInbox(accountId: "acc-p67-4", pool: pool)
        try await assertOutOfWindow(opened, pool: pool)
        try await insertNoContentBody(opened.id, pool: pool)

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        // Header present and matching — so if the trigger had been placed in the
        // shared adoption helper, this adoption WOULD process the row.
        vm._testSeedMessage(opened)
        #expect(vm.messageBody == nil)
        #expect(!vm.hasStartedBodyPollForTesting, "no poll may be running — the poll is the one caller allowed to trigger")

        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        for _ in 0..<150 where vm.messageBody == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(vm.messageBody != nil, "the merge-commit catch-up must adopt the durable body (control: adoption happened)")

        try await settleForAbsentAI()
        expectUntouched(try await header(opened.id, pool: pool), "the merge-commit catch-up is display-only — the NSE merge enqueues its own exempt AI; the trigger belongs to the poll's adoption sites only")
    }

    @Test("Staged-publish seed adopts the body for display and initiates no AI")
    @MainActor
    func stagedPublishSeedDoesNotTriggerAI() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        let opened = try makeOverfullInbox(accountId: "acc-p67-5", pool: pool)
        try await assertOutOfWindow(opened, pool: pool)
        // Durable body present: `adoptReadyBody` is durable-first, so the seed's
        // adoption lands a REAL body — the state in which a misplaced trigger
        // would fire.
        try await insertNoContentBody(opened.id, pool: pool)

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.message == nil, "header-less open — the staged publish is what seeds it")

        // Publish the way the merge does: replace the snapshot, then post.
        let staged = StagedInboxRow(
            accountId: opened.accountId, folderPath: "INBOX", messageId: opened.messageId,
            rfc822MessageId: opened.rfc822MessageId, threadId: nil, inReplyTo: nil, references: [],
            subject: opened.subject, senderName: "Sender", senderAddress: "sender@example.com",
            to: "recipient@example.com", snippet: "fixture", date: opened.date,
            isRead: true, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil)
        #expect(staged.headerId == opened.id, "the staged row must map to the opened header id, or the seed cannot match it")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        NotificationCenter.default.post(name: .messagesStaged, object: [staged])

        for _ in 0..<150 where vm.messageBody == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(vm.message?.id == opened.id, "the staged publish must seed the header (control)")
        #expect(vm.messageBody != nil, "the seed must adopt the durable body (control: adoption happened)")
        #expect(!vm.hasStartedBodyPollForTesting, "a successful seed adoption starts no poll")

        try await settleForAbsentAI()
        expectUntouched(try await header(opened.id, pool: pool), "the staged-publish seed is display-only — the trigger belongs to the poll's adoption sites only")
    }
}
