/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Shared fixtures

/// The provider UID is the tail of a `headerId` (`accountId:folderPath:UID`), which is
/// exactly why the quarantine below is address-keyed and must be released on a
/// UIDVALIDITY renumber.
private func uidTail(_ headerId: String) -> String {
    headerId.split(separator: ":").last.map(String.init) ?? "0"
}

private func activeItem(
    _ headerId: String, folderPath: String = "INBOX", accountId: String = "acc1", isInInbox: Bool = true
) -> ActiveBodyQueue.Item {
    ActiveBodyQueue.Item(
        headerId: headerId, accountId: accountId, folderPath: folderPath,
        messageId: uidTail(headerId), isInInbox: isInInbox
    )
}

private func backfillItem(
    _ headerId: String, folderPath: String = "Archive", accountId: String = "acc1"
) -> BackfillBodyQueue.Item {
    BackfillBodyQueue.Item(
        headerId: headerId, accountId: accountId, folderPath: folderPath,
        messageId: uidTail(headerId), isInInbox: false
    )
}

// MARK: - Property (i) + (iii): the durable row is never lied about

/// Data-integrity rule 1 ("NEVER mark unfetched content as fetched") permits exactly
/// one exception: a *verified permanent* error where the content is confirmed GONE.
/// A `PayloadTooLargeError` is the opposite — the body demonstrably EXISTS and merely
/// overflowed the fixed per-binary NIO buffer — so neither body queue may retire the
/// row with `bodyEmptyConfirmed`.
///
/// Both queues previously did: their `dispatchBatch` catch narrowed the per-folder cap
/// to 1 and then wrote `UPDATE messageHeader SET bodyEmptyConfirmed = 1` (under a
/// `try?`, so a failed write was silent as well). Because `bodyEmptyConfirmed = 1`
/// excludes the row from every body-fetch, FTS self-heal and embedding query, the
/// message became searchable-but-unopenable, permanently. `BackfillBodyQueue` runs over
/// whole mailboxes, so it produced victims in bulk.
///
/// **The property asserted is the SYSTEM STATE, not the fix's mechanism** — the row is
/// still marked as having no body AND is still selected by the body queues' own
/// candidate predicate. Nothing here asserts the absence of a particular statement.
///
/// **The suite is deliberately TWO-SIDED.** "Oversized never confirms empty" would pass
/// vacuously against a build that had lost the ability to confirm empty at all (a
/// different bug — unbounded retry — wearing this suite's green as a disguise), so the
/// genuinely-empty side is pinned against the SAME eligibility predicate.
///
/// `.serialized, .processGlobalState`: the pre-fix write went to the process-wide
/// `AppDatabase.shared` (via `AppDatabase.syncPool` / `.backgroundPool`), so the seeded
/// row must live in THAT database for the assertion to be capable of failing.
@Suite("Oversized bodies are quarantined, never marked fetched (data-integrity rule 1)", .serialized, .processGlobalState)
struct OversizedBodyQuarantineDatabaseTests {

    /// Temp file-backed `DatabasePool` with all migrations applied (`DatabasePool`
    /// requires WAL, unavailable with `:memory:`), swapped in as `AppDatabase.shared`.
    /// Returns the seeded header and a restore closure the caller MUST run in `defer`.
    /// The date is derived from `Date()`, never hardcoded.
    private func makeSwappedDB(
        folderPath: String = "INBOX",
        isInInbox: Bool = true,
        emptyFetchCount: Int = 0
    ) throws -> (header: MessageHeader, restore: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var account = Account(emailAddress: "oversize@example.com", displayName: "Oversize", provider: .imap)
        account.id = "acc1"
        var folder = Folder(name: folderPath, path: folderPath, role: isInInbox ? .inbox : .archive, accountId: "acc1")
        folder.lastKnownUidValidity = 1000
        var header = MessageHeader(
            messageId: "4242",
            subject: "A message whose body overflows the buffer",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: folderPath),
            accountId: "acc1",
            folderPath: folderPath,
            isInInbox: isInInbox
        )
        header.headerComplete = true
        header.emptyFetchCount = emptyFetchCount
        try pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try header.insert(db)
        }
        let restore: () -> Void = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        return (header, restore)
    }

    /// "Still reachable by a later body fetch" IS membership in the body queues'
    /// candidate set — the predicate shared verbatim by
    /// `ActiveBodyQueue.repopulateFromDatabase`, `BackfillBodyQueue
    /// .repopulateFromDatabase`, both `repopulateOnDrain`s and the FTS self-heal scope.
    /// A row excluded from it is reachable by no background body fetch at all.
    private func isEligibleForLaterBodyFetch(headerId: String) async throws -> Bool {
        let found: Int = try await AppDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE id = ? AND headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                """, arguments: [headerId]) ?? 0
        }
        return found == 1
    }

    // MARK: Side 1 — oversized must never be recorded as fetched

    @Test("ActiveBodyQueue: an oversized single-item batch leaves the row bodyComplete=0/bodyEmptyConfirmed=0 and still eligible for a later body fetch")
    func activeOversizedNeverMarksRowFetched() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        // The shared per-folder cap is already at 1 — exactly the state in which the
        // pre-fix catch took its mark-empty branch. The disposition must key on THIS
        // batch's item count, not on the cap.
        await queue.setFolderMaxBatchForTesting(1, folderPath: header.folderPath)
        let item = activeItem(header.id, folderPath: header.folderPath)
        #expect(await queue.admit(item) == true)

        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        let stored = try #require(row, "the header must survive an oversized body fetch")
        #expect(
            stored.bodyEmptyConfirmed == false,
            "an oversized body is not a confirmed-empty body — the content demonstrably exists, it merely did not fit"
        )
        #expect(stored.bodyComplete == false, "nothing was indexed, so the body is not complete")
        #expect(stored.emptyFetchCount == 0, "a too-large response is not an empty response — it must not spend a strike from the empty-confirmation budget")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the row must stay in the body queues' candidate set — the quarantine is in memory, not in the database")

        // ...and the quarantine really is the in-memory one, not a completion.
        #expect(await queue.oversizedDeferredThisSession.contains(header.id))
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.recentlyCompletedCount == 0, "a quarantined item must never be recorded as completed")
        #expect(snapshot.activeJobs == 0, "the defer must not touch activeJobs — this queue tracks activeBatchCount instead")
    }

    @Test("BackfillBodyQueue: an oversized single-item batch leaves the row bodyComplete=0/bodyEmptyConfirmed=0 and still eligible for a later body fetch")
    func backfillOversizedNeverMarksRowFetched() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        await queue.setFolderMaxBatchForTesting(1, folderPath: header.folderPath)
        let item = backfillItem(header.id, folderPath: header.folderPath)
        #expect(await queue.admit(item) == true)

        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        let stored = try #require(row, "the header must survive an oversized body fetch")
        #expect(
            stored.bodyEmptyConfirmed == false,
            "an oversized body is not a confirmed-empty body — the backfill queue walks whole mailboxes, so this branch retires messages in bulk"
        )
        #expect(stored.bodyComplete == false)
        #expect(stored.emptyFetchCount == 0)
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id))

        #expect(await queue.oversizedDeferredThisSession.contains(header.id))
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.recentlyCompletedCount == 0, "a quarantined item must never be recorded as completed")
        #expect(snapshot.activeJobs == 0)
    }

    // MARK: Side 2 — the non-vacuity control

    @Test("A genuinely empty body still confirms empty and leaves the body queues' candidate set")
    func genuinelyEmptyBodyStillConfirmsEmpty() async throws {
        // Budget already spent by prior consecutive empty responses — this attempt is
        // the one that permanently confirms.
        let (header, restore) = try makeSwappedDB(emptyFetchCount: 2)
        defer { restore() }

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "precondition: the row starts inside the candidate set")

        // No text, no attachments, no unresolved invite: a genuinely contentless
        // message, which IS this codebase's "verified permanent / content confirmed
        // gone" case for bodies — the one exception data-integrity rule 1 allows.
        let fetchResult = BodyFetchProcessor.FetchResult(
            item: BodyFetchProcessor.Item(
                headerId: header.id, accountId: header.accountId,
                folderPath: header.folderPath, messageId: header.messageId,
                isInInbox: header.isInInbox
            ),
            renderedBody: MessageBody.create(contentKey: ContentKey(rawValue: header.id), htmlBody: nil),
            plainText: nil,
            hasAttachments: false,
            hasUnresolvedICS: false
        )
        let (outcome, processed) = await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
        #expect(outcome == .confirmedEmpty)
        #expect(processed == nil, "a confirmed-empty message contributes no FTS row")

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        let stored = try #require(row)
        #expect(stored.bodyEmptyConfirmed,
                "the permanent-empty path must still work — otherwise the oversized assertions above are vacuous")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "a confirmed-empty message is correctly retired from the body queues — the SAME predicate the oversized row must stay inside")
    }
}

// MARK: - Property (ii): the quarantine terminates the drain/repopulate cycle

/// The reason a plain deletion of the `bodyEmptyConfirmed` write would be a
/// permanent-brick-shaped regression: both queues' repopulate predicates gate on
/// `bodyEmptyConfirmed = 0`, and both re-enqueue whatever the predicate returns. With
/// nothing else in place an oversized message repopulates forever — overflow →
/// retry-exhaust → repopulate → overflow. The stamp was the (illegal) thing making the
/// cycle terminate.
///
/// The replacement bound is `oversizedDeferredThisSession` + `admit`, and the
/// mechanism that makes an oversized item REACH that bound in a bounded number of
/// attempts is failure-local isolation: a multi-item overflow marks every member
/// isolation-pending, and `groupCandidatesForDispatch` then dispatches each ALONE,
/// independent of `folderMaxBatch` (which any sibling success used to reset).
///
/// These tests drive the modelled drain/repopulate cycle off the queue's REAL contents
/// and assert convergence with an explicit pass and overflow budget.
@Suite("Oversized body quarantine terminates the drain/repopulate cycle")
struct OversizedBodyQuarantineConvergenceTests {

    @Test("ActiveBodyQueue: an oversized message reaches a quiescent queue within a bounded number of drain/repopulate passes")
    func activeConvergesInBoundedPasses() async {
        let queue = ActiveBodyQueue()
        let oversized = activeItem("acc1:INBOX:1")
        let sibling = activeItem("acc1:INBOX:2")

        var overflows = 0
        var quiescedAtPass: Int?
        let maxPasses = 8

        for pass in 1...maxPasses {
            // 1. Repopulate: BOTH rows are honestly retryable in the database (the
            //    oversized one is never stamped), so the SELECT re-offers both every
            //    pass. `admit` is the only thing that can refuse them.
            _ = await queue.admit(oversized)
            _ = await queue.admit(sibling)

            // 2. Quiescence is "the queue holds nothing", measured on the real queue.
            let queued = await queue.queuedItemsForTesting
            if queued.isEmpty {
                quiescedAtPass = pass
                break
            }

            // 3. Dispatch: group exactly as production does, then let the server
            //    overflow on any batch containing the oversized message and succeed on
            //    every other batch.
            let groups = ActiveBodyQueue.groupCandidatesForDispatch(
                queued, isolationPending: await queue.isolationPendingForTesting
            )
            for (_, items) in groups {
                if items.contains(where: { $0.headerId == oversized.headerId }) {
                    overflows += 1
                    await queue.handlePayloadTooLarge(items: items, folderPath: "INBOX")
                } else {
                    for item in items { await queue.completeItemForTesting(item, shouldRetry: false) }
                }
            }
        }

        #expect(quiescedAtPass != nil,
                "the queue must reach quiescence — an unbounded cycle is the hot loop this quarantine exists to stop")
        #expect((quiescedAtPass ?? Int.max) <= 3, "one multi-item overflow, one single-item overflow, then quiescent")
        #expect(overflows == 2, "an oversized message costs at most TWO provider attempts: one in a coalesced batch, one alone")

        #expect(await queue.oversizedDeferredThisSession == [oversized.headerId],
                "only the genuinely oversized message is quarantined")
        #expect(await queue.isolationPendingForTesting.isEmpty, "both items left isolation")
        #expect(await queue.admit(oversized) == false, "a quarantined item is never re-admitted this process lifetime")

        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.queueCount == 0, "no residual queued item to hot-loop")
        #expect(snapshot.enqueuedCount == 0)
        #expect(snapshot.activeJobs == 0, "activeJobs is never touched — a stray decrement would drive it negative")
        #expect(snapshot.recentlyCompletedCount == 1,
                "exactly ONE completion — the sibling that genuinely fetched. The quarantined message is deferred, NOT completed")
    }

    @Test("BackfillBodyQueue: an oversized message reaches a quiescent queue within a bounded number of drain/repopulate passes")
    func backfillConvergesInBoundedPasses() async {
        let queue = BackfillBodyQueue()
        let oversized = backfillItem("acc1:Archive:1")
        let sibling = backfillItem("acc1:Archive:2")

        var overflows = 0
        var quiescedAtPass: Int?
        let maxPasses = 8

        for pass in 1...maxPasses {
            _ = await queue.admit(oversized)
            _ = await queue.admit(sibling)

            let queued = await queue.queuedItemsForTesting
            if queued.isEmpty {
                quiescedAtPass = pass
                break
            }

            let groups = BackfillBodyQueue.groupCandidatesForDispatch(
                queued, isolationPending: await queue.isolationPendingForTesting
            )
            for (_, items) in groups {
                if items.contains(where: { $0.headerId == oversized.headerId }) {
                    overflows += 1
                    await queue.handlePayloadTooLarge(items: items, folderPath: "Archive")
                } else {
                    for item in items { await queue.completeItemForTesting(item, shouldRetry: false) }
                }
            }
        }

        #expect(quiescedAtPass != nil, "the queue must reach quiescence — the backfill queue walks whole mailboxes, so a hot loop here burns the whole mailbox")
        #expect((quiescedAtPass ?? Int.max) <= 3)
        #expect(overflows == 2, "an oversized message costs at most TWO provider attempts")

        #expect(await queue.oversizedDeferredThisSession == [oversized.headerId])
        #expect(await queue.isolationPendingForTesting.isEmpty)
        #expect(await queue.admit(oversized) == false)

        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.queueCount == 0)
        #expect(snapshot.enqueuedCount == 0)
        #expect(snapshot.activeJobs == 0)
        #expect(snapshot.recentlyCompletedCount == 1,
                "exactly ONE completion — the sibling that genuinely fetched")
    }

    @Test("An isolation-pending item is dispatched alone while ordinary items coalesce per folder")
    func isolationPendingItemsFormSingleItemGroups() {
        let a = activeItem("acc1:INBOX:1")
        let b = activeItem("acc1:INBOX:2")
        let c = activeItem("acc1:INBOX:3")
        let activeGroups = ActiveBodyQueue.groupCandidatesForDispatch(
            [a, b, c], isolationPending: [a.headerId, b.headerId]
        )
        let activeIsolation = activeGroups.filter { $0.key.isolationHeaderId != nil }
        let activeNormal = activeGroups.filter { $0.key.isolationHeaderId == nil }
        #expect(activeIsolation.count == 2, "each suspect is its OWN group, so its next attempt is a size-1 batch")
        #expect(activeIsolation.allSatisfy { $0.value.count == 1 })
        #expect(activeNormal.count == 1, "the ordinary item still coalesces into one folder group")
        #expect(activeNormal.first?.value.map(\.headerId) == ["acc1:INBOX:3"])

        let x = backfillItem("acc1:Archive:1")
        let y = backfillItem("acc1:Archive:2")
        let z = backfillItem("acc1:Archive:3")
        let backfillGroups = BackfillBodyQueue.groupCandidatesForDispatch(
            [x, y, z], isolationPending: [x.headerId]
        )
        let backfillIsolation = backfillGroups.filter { $0.key.isolationHeaderId != nil }
        let backfillNormal = backfillGroups.filter { $0.key.isolationHeaderId == nil }
        #expect(backfillIsolation.count == 1)
        #expect(backfillIsolation.first?.value.map(\.headerId) == ["acc1:Archive:1"])
        #expect(backfillNormal.count == 1)
        #expect(backfillNormal.first?.value.count == 2, "the two ordinary items coalesce")
    }

    @Test("ActiveBodyQueue: a multi-item PayloadTooLarge quarantines nothing and completes nothing, even when the per-folder cap is already 1")
    func activeMultiItemBatchQuarantinesNothing() async {
        let queue = ActiveBodyQueue()
        // A concurrent fast-failing batch has lowered the SHARED per-folder cap to 1.
        // The disposition must key on THIS batch's actual item count, not on the cap —
        // otherwise a whole batch of ORDINARY messages is quarantined (pre-fix: marked
        // empty) for the process lifetime.
        await queue.setFolderMaxBatchForTesting(1, folderPath: "INBOX")
        let a = activeItem("acc1:INBOX:10")
        let b = activeItem("acc1:INBOX:11")
        #expect(await queue.admit(a) == true)
        #expect(await queue.admit(b) == true)

        await queue.handlePayloadTooLarge(items: [a, b], folderPath: "INBOX")

        #expect(await queue.oversizedDeferredThisSession.isEmpty,
                "a multi-item overflow names no culprit, so it may quarantine nobody")
        #expect(await queue.isolationPendingForTesting == [a.headerId, b.headerId],
                "instead every member is isolated so its next attempt is alone")
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.queueCount == 2, "both stay in the queue, retryable")
        #expect(snapshot.recentlyCompletedCount == 0, "and neither is falsely completed")
    }

    @Test("BackfillBodyQueue: a multi-item PayloadTooLarge quarantines nothing and completes nothing, even when the per-folder cap is already 1")
    func backfillMultiItemBatchQuarantinesNothing() async {
        let queue = BackfillBodyQueue()
        await queue.setFolderMaxBatchForTesting(1, folderPath: "Archive")
        let a = backfillItem("acc1:Archive:10")
        let b = backfillItem("acc1:Archive:11")
        #expect(await queue.admit(a) == true)
        #expect(await queue.admit(b) == true)

        await queue.handlePayloadTooLarge(items: [a, b], folderPath: "Archive")

        #expect(await queue.oversizedDeferredThisSession.isEmpty)
        #expect(await queue.isolationPendingForTesting == [a.headerId, b.headerId])
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.queueCount == 2, "both stay in the queue, retryable")
        #expect(snapshot.recentlyCompletedCount == 0)
    }

    @Test("A per-(account,folder) batch cap keeps one account's isolation singleton reachable while other accounts saturate the same folder name")
    func folderBatchCapIsPerAccount() async {
        let active = ActiveBodyQueue()
        // Accounts A and B each fill both "INBOX" batch slots.
        await active.noteFolderBatchDispatchedForTesting(accountId: "accA", folderPath: "INBOX")
        await active.noteFolderBatchDispatchedForTesting(accountId: "accA", folderPath: "INBOX")
        await active.noteFolderBatchDispatchedForTesting(accountId: "accB", folderPath: "INBOX")
        await active.noteFolderBatchDispatchedForTesting(accountId: "accB", folderPath: "INBOX")
        // Account C's INBOX must be untouched. With a folderPath-only key all four
        // increments landed under "INBOX", so C read 4 (≥ cap) and its size-1 isolation
        // group — which sorts LAST under the size-descending dispatch order — was
        // starved every cycle, i.e. its oversized message was never size-tested alone
        // and therefore never reached the quarantine.
        #expect(await active.folderActiveBatchCountForTesting(accountId: "accC", folderPath: "INBOX") == 0)
        #expect(await active.folderActiveBatchCountForTesting(accountId: "accA", folderPath: "INBOX") == 2)
        #expect(await active.folderActiveBatchCountForTesting(accountId: "accB", folderPath: "INBOX") == 2)

        let backfill = BackfillBodyQueue()
        await backfill.noteFolderBatchDispatchedForTesting(accountId: "accA", folderPath: "Archive")
        await backfill.noteFolderBatchDispatchedForTesting(accountId: "accA", folderPath: "Archive")
        await backfill.noteFolderBatchDispatchedForTesting(accountId: "accB", folderPath: "Archive")
        await backfill.noteFolderBatchDispatchedForTesting(accountId: "accB", folderPath: "Archive")
        #expect(await backfill.folderActiveBatchCountForTesting(accountId: "accC", folderPath: "Archive") == 0)
        #expect(await backfill.folderActiveBatchCountForTesting(accountId: "accA", folderPath: "Archive") == 2)
    }
}

// MARK: - Property (iv): a UIDVALIDITY reset RELEASES the quarantine

/// The quarantine keys by headerId = `accountId:folderPath:UID`, a mutable ADDRESS and
/// not an identity. A UIDVALIDITY reset renumbers the mailbox and the reaction purges +
/// resyncs the folder in-process, so a new-epoch message can land on a quarantined
/// item's UID and therefore inherit its headerId. Without the release, `admit` would
/// refuse a message that was never oversized — the quarantine would have become a
/// permanent discard by another name, and the deferral would no longer be a deferral.
///
/// The generation guard is the other half: a batch already awaiting a network response
/// when the reset lands must not resume afterwards and re-insert its stale OLD-epoch
/// headerId, which would silently undo the clear.
@Suite("A UIDVALIDITY reset releases the folder's oversized quarantine")
struct OversizedQuarantineResetReleaseTests {

    @Test("ActiveBodyQueue: clearOversizedDeferred re-admits the reset-renumbered UID and leaves other folders quarantined")
    func activeResetReleasesOnlyItsOwnFolder() async {
        let queue = ActiveBodyQueue()
        let inboxItem = activeItem("acc1:INBOX:5")
        let archiveItem = activeItem("acc1:Archive:9", folderPath: "Archive", isInInbox: false)
        #expect(await queue.admit(inboxItem) == true)
        #expect(await queue.admit(archiveItem) == true)
        await queue.handlePayloadTooLarge(items: [inboxItem], folderPath: "INBOX")
        await queue.handlePayloadTooLarge(items: [archiveItem], folderPath: "Archive")
        #expect(await queue.admit(inboxItem) == false, "quarantined → refused, which also refuses the reset-renumbered message sharing that UID")

        // The reset reaction purges + resyncs INBOX only.
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: "INBOX")

        #expect(await queue.oversizedDeferredThisSession.contains(inboxItem.headerId) == false)
        #expect(await queue.admit(inboxItem) == true,
                "the message now occupying that UID is eligible again — the deferral is released, not permanent")
        #expect(await queue.oversizedDeferredThisSession.contains(archiveItem.headerId),
                "a folder the reset did not touch keeps its quarantine")
        #expect(await queue.admit(archiveItem) == false)
    }

    @Test("BackfillBodyQueue: clearOversizedDeferred re-admits the reset-renumbered UID and leaves other folders quarantined")
    func backfillResetReleasesOnlyItsOwnFolder() async {
        let queue = BackfillBodyQueue()
        let archiveItem = backfillItem("acc1:Archive:5")
        let sentItem = backfillItem("acc1:Sent:9", folderPath: "Sent")
        #expect(await queue.admit(archiveItem) == true)
        #expect(await queue.admit(sentItem) == true)
        await queue.handlePayloadTooLarge(items: [archiveItem], folderPath: "Archive")
        await queue.handlePayloadTooLarge(items: [sentItem], folderPath: "Sent")
        #expect(await queue.admit(archiveItem) == false)

        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: "Archive")

        #expect(await queue.oversizedDeferredThisSession.contains(archiveItem.headerId) == false)
        #expect(await queue.admit(archiveItem) == true)
        #expect(await queue.oversizedDeferredThisSession.contains(sentItem.headerId))
    }

    @Test("clearOversizedDeferred also drops the folder's isolation-pending keys, and never a nested colon-delimited sibling folder's")
    func resetClearIsFolderScopedAndColonSafe() async {
        let queue = ActiveBodyQueue()
        let parent = activeItem("acc1:INBOX:1")
        // RFC 3501 allows ':' as an IMAP hierarchy delimiter, so a child folder's
        // headerId shares the parent's prefix. Clearing the parent must not clear it.
        let nestedSibling = activeItem("acc1:INBOX:Sub:1", folderPath: "INBOX:Sub")
        #expect(await queue.admit(parent) == true)
        #expect(await queue.admit(nestedSibling) == true)
        await queue.handlePayloadTooLarge(items: [nestedSibling], folderPath: "INBOX:Sub")
        // A multi-item overflow leaves `parent` isolation-pending rather than quarantined.
        let other = activeItem("acc1:INBOX:2")
        #expect(await queue.admit(other) == true)
        await queue.handlePayloadTooLarge(items: [parent, other], folderPath: "INBOX")
        #expect(await queue.isolationPendingForTesting.isEmpty == false)

        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: "INBOX")

        #expect(await queue.isolationPendingForTesting.isEmpty,
                "isolation-pending keys for the reset folder are dropped too — they name the same discarded numbering")
        #expect(await queue.oversizedDeferredThisSession.contains(nestedSibling.headerId),
                "a nested ':'-delimited child folder is a DIFFERENT folder and keeps its quarantine")
    }

    @Test("ActiveBodyQueue: a UIDVALIDITY reset landing inside a batch's fetch window cannot re-quarantine the renumbered UID")
    func activeGenerationGuardRejectsStaleQuarantine() async {
        let queue = ActiveBodyQueue()
        let item = activeItem("acc1:INBOX:7")
        #expect(await queue.admit(item) == true)
        // What a batch captures at dispatch, before its fetch await.
        let captured = await queue.resetGenerationForTesting
        // The reset lands DURING the fetch window: it bumps the generation and clears
        // the sets.
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: "INBOX")
        // The batch's overflow now resumes carrying the STALE captured generation.
        await queue.handlePayloadTooLarge(items: [item], folderPath: "INBOX", capturedGeneration: captured)

        #expect(await queue.oversizedDeferredThisSession.contains(item.headerId) == false,
                "the stale OLD-epoch headerId must not re-enter the quarantine — that would undo the clear and starve whatever message now holds that UID")
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.queueCount == 1,
                "the item is released RETRYABLE, so its next fetch resolves whatever message now lives at that UID")
        #expect(snapshot.recentlyCompletedCount == 0,
                "and it is not falsely completed either")
    }

    @Test("BackfillBodyQueue: a UIDVALIDITY reset landing inside a batch's fetch window cannot re-quarantine the renumbered UID")
    func backfillGenerationGuardRejectsStaleQuarantine() async {
        let queue = BackfillBodyQueue()
        let a = backfillItem("acc1:Archive:7")
        let b = backfillItem("acc1:Archive:8")
        #expect(await queue.admit(a) == true)
        #expect(await queue.admit(b) == true)
        let captured = await queue.resetGenerationForTesting
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: "Archive")

        // Both dispositions must respect the guard: the single-item one must not
        // quarantine, and the multi-item one must not re-populate isolation.
        await queue.handlePayloadTooLarge(items: [a], folderPath: "Archive", capturedGeneration: captured)
        await queue.handlePayloadTooLarge(items: [a, b], folderPath: "Archive", capturedGeneration: captured)

        #expect(await queue.oversizedDeferredThisSession.isEmpty, "stale single-item quarantine skipped")
        #expect(await queue.isolationPendingForTesting.isEmpty, "stale multi-item isolation skipped")
        #expect(await queue.storageSnapshotForTesting.recentlyCompletedCount == 0, "nothing falsely completed")
    }

    @Test("A batch whose captured generation still matches quarantines normally")
    func generationGuardDoesNotOverFire() async {
        let active = ActiveBodyQueue()
        let activeTarget = activeItem("acc1:INBOX:8")
        #expect(await active.admit(activeTarget) == true)
        let activeCaptured = await active.resetGenerationForTesting  // no reset happens
        await active.handlePayloadTooLarge(items: [activeTarget], folderPath: "INBOX", capturedGeneration: activeCaptured)
        #expect(await active.oversizedDeferredThisSession.contains(activeTarget.headerId),
                "a non-stale batch quarantines as normal — otherwise the guard would disable the bound entirely")

        let backfill = BackfillBodyQueue()
        let backfillTarget = backfillItem("acc1:Archive:8")
        #expect(await backfill.admit(backfillTarget) == true)
        let backfillCaptured = await backfill.resetGenerationForTesting
        await backfill.handlePayloadTooLarge(items: [backfillTarget], folderPath: "Archive", capturedGeneration: backfillCaptured)
        #expect(await backfill.oversizedDeferredThisSession.contains(backfillTarget.headerId))
    }
}

// MARK: - The quarantine's UI consequence: wake lock vs. completion banner

/// Removing the illegal `bodyEmptyConfirmed = 1` stamp made the quarantined row stay
/// honestly incomplete, which is correct — and which means
/// `BackfillProgress.pendingBodyCount` (`headerComplete = 1 AND bodyComplete = 0 AND
/// bodyEmptyConfirmed = 0`) never reaches 0 for an account holding one oversized
/// message, so `BackfillProgress.isFullyComplete` is false forever for that account.
///
/// `FastSyncView` had TWO consumers keyed off that single durable-completeness fact:
/// the "Sync Complete" banner AND `keepScreenAwake(while: !isAllComplete)`. The second
/// one is a battery-draining defect — the device screen was pinned awake indefinitely.
///
/// The split asserted here:
///   - the WAKE LOCK is a question about the app's CURRENT activity, so it moved to
///     `FastSyncView.keepScreenAwakeWhileWorking` — the header walk plus the two body
///     queues' `isIdle`;
///   - the BANNER is a TRUTH CLAIM about the mailbox, so it stays on
///     `isFullyComplete`. Telling the user "Sync Complete" while a body is genuinely
///     missing would be a second defect, not a fix.
///
/// The idle inputs here come from the REAL queue actors after a REAL quarantine, not
/// from hand-fed booleans, so these tests pin the causal chain
/// (quarantine → queue idle → lock released) rather than the predicate's arithmetic.
/// The suite is deliberately TWO-SIDED: a broken predicate that ALWAYS released would
/// satisfy the release cases alone, so every release case has a held counterpart driven
/// off a queue that still holds admitted work.
@Suite("Fast Sync keep-awake follows runnable queue state, not durable completeness")
struct FastSyncKeepAwakeTests {

    /// A progress snapshot for an account whose header walk is done and whose ONLY
    /// remaining work is `pendingBodyCount` quarantined oversized bodies. Dates derive
    /// from `Date()`; the address is a placeholder domain.
    private func progressWithPendingBodies(_ pendingBodyCount: Int) -> BackfillProgress {
        var p = BackfillProgress(
            accountId: "acc1",
            email: "oversize@example.com",
            startedAt: Date(),
            isPaused: false,
            headersDone: true,
            totalEmails: 1200,
            ftsIndexed: 1199
        )
        p.pendingBodyCount = pendingBodyCount
        return p
    }

    @Test("A quarantined oversized message leaves both body queues idle, so the keep-awake lock is RELEASED even though pendingBodyCount is still non-zero")
    func quarantinedOversizedReleasesTheWakeLock() async {
        let active = ActiveBodyQueue()
        let backfill = BackfillBodyQueue()
        let activeOversized = activeItem("acc1:INBOX:1")
        let backfillOversized = backfillItem("acc1:Archive:1")
        #expect(await active.admit(activeOversized) == true)
        #expect(await backfill.admit(backfillOversized) == true)

        // The real quarantine disposition — not a model of it.
        await active.handlePayloadTooLarge(items: [activeOversized], folderPath: "INBOX")
        await backfill.handlePayloadTooLarge(items: [backfillOversized], folderPath: "Archive")

        let activeIdle = await active.isIdle
        let backfillIdle = await backfill.isIdle
        #expect(activeIdle, "a quarantined item is removed from the queue, so the queue has no runnable work")
        #expect(backfillIdle)

        // The account is genuinely NOT fully complete — the count still sees the row.
        let progress = progressWithPendingBodies(1)
        #expect(progress.pendingBodyCount == 1, "the quarantined row is still counted; the fix must not hide it")
        #expect(!progress.isFullyComplete, "durable completeness is honestly withheld")

        // …and the wake lock is nonetheless released, because it no longer asks that
        // question. This exact pairing IS the defect: pre-fix these two lines could not
        // both hold.
        #expect(FastSyncView.keepScreenAwakeWhileWorking(
            accountHeadersDone: [progress.headersDone],
            activeBodyIdle: activeIdle,
            backfillBodyIdle: backfillIdle
        ) == false, "an oversized-only remainder must not pin the screen awake")
    }

    @Test("The keep-awake lock is HELD while the ACTIVE body queue still holds admitted work")
    func heldWhileActiveQueueHasWork() async {
        let active = ActiveBodyQueue()
        #expect(await active.admit(activeItem("acc1:INBOX:2")) == true)
        let activeIdle = await active.isIdle
        #expect(activeIdle == false, "an admitted, un-quarantined item leaves the queue runnable")

        #expect(FastSyncView.keepScreenAwakeWhileWorking(
            accountHeadersDone: [true],
            activeBodyIdle: activeIdle,
            backfillBodyIdle: true
        ) == true, "the screen stays awake while bodies are actually being fetched")
    }

    @Test("The keep-awake lock is HELD while the BACKFILL body queue still holds admitted work")
    func heldWhileBackfillQueueHasWork() async {
        let backfill = BackfillBodyQueue()
        #expect(await backfill.admit(backfillItem("acc1:Archive:2")) == true)
        let backfillIdle = await backfill.isIdle
        #expect(backfillIdle == false)

        #expect(FastSyncView.keepScreenAwakeWhileWorking(
            accountHeadersDone: [true],
            activeBodyIdle: true,
            backfillBodyIdle: backfillIdle
        ) == true)
    }

    @Test("The keep-awake lock is HELD while any account's header walk is unfinished, including an account with no progress entry yet")
    func heldWhileAnyHeaderWalkUnfinished() {
        // `FastSyncView.holdAwake` maps a MISSING progress entry to `false`
        // (`…?.headersDone == true`), so a not-yet-reporting account holds the lock.
        #expect(FastSyncView.keepScreenAwakeWhileWorking(
            accountHeadersDone: [true, false],
            activeBodyIdle: true,
            backfillBodyIdle: true
        ) == true)
    }

    @Test("DECISION: the Sync Complete banner stays gated on isFullyComplete — one quarantined oversized body withholds it rather than claiming a complete mailbox")
    func syncCompleteBannerStaysTruthful() {
        // Withheld while a body is genuinely missing…
        #expect(!progressWithPendingBodies(1).isFullyComplete)
        // …and still reachable once nothing is pending, so the banner is not simply
        // dead (a gate that never fired would pass the first case alone).
        #expect(progressWithPendingBodies(0).isFullyComplete)
    }
}
