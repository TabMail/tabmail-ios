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
/// overflowed the response parser's buffer — so neither body queue may retire the
/// row with `bodyEmptyConfirmed`. (The overflow is also NOT size-deterministic: the
/// bound is on unread aggregate bytes after the decode loop stops, so it depends on
/// wire fragmentation. Nothing may treat it as a verdict that the body is unfetchable.)
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
        // 🚨 LOAD-BEARING, and it is the whole reason the funnel tests below cannot reach
        // the network: `AccountManager.createIMAPProvider` opens with
        // `guard let host = account.imapHost`, so a host-less account makes `connectAccount`
        // throw `authenticationFailed` before a provider is built or registered. Give this
        // fixture a host and those tests start attempting real connections from the unit
        // suite. Asserted, not assumed. (Found by audit.)
        #expect(account.imapHost == nil,
                "fixture precondition: the account must have no imapHost, or the funnel tests will attempt a live connection")
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

    /// Seeds an extra account + folder + FLAGGED header alongside whatever `makeSwappedDB`
    /// already installed, so a scoping assertion has something to be scoped AGAINST.
    ///
    /// ⚠️ The row is flagged through the production writer, not by setting the column on
    /// the struct: `BodyFetchProcessor.markBodyMetadataOversized` carries the re-minted-key
    /// guard (`id = accountId || ':' || folderPath || ':' || messageId`), so a bystander
    /// seeded any other way could be flagged in a way production never produces, and the
    /// scoping assertion would be about a row that cannot exist.
    @discardableResult
    private func seedFlaggedBystander(
        accountId: String, folderPath: String, messageId: String
    ) async throws -> String {
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: messageId)
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(
                    emailAddress: "bystander@example.com", displayName: "Bystander", provider: .imap)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
            if try Folder.fetchOne(db, key: folderId) == nil {
                var folder = Folder(
                    name: folderPath, path: folderPath, role: .archive, accountId: accountId)
                folder.lastKnownUidValidity = 1000
                try folder.insert(db)
            }
            var header = MessageHeader(
                messageId: messageId,
                subject: "A bystander in another scope",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: Date(),
                snippet: "",
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            header.headerComplete = true
            try header.insert(db)
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: headerId)
        }
        return headerId
    }

    /// Reads one row's durable flag. `#require`s the row so a fixture that silently failed
    /// to insert cannot read as "not flagged".
    private func durableFlag(_ headerId: String) async throws -> Bool {
        let row = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }, "fixture row \(headerId) must exist")
        return row.bodyMetadataOversized
    }

    /// "Still reachable by a later BACKGROUND body fetch" IS membership in the body
    /// queues' candidate set — the predicate shared verbatim by
    /// `ActiveBodyQueue.repopulateFromDatabase`, `BackfillBodyQueue
    /// .repopulateFromDatabase` and both `repopulateOnDrain`s.
    /// A row excluded from it is reachable by no background body fetch at all.
    ///
    /// ⚠️ `bodyMetadataOversized = 0` is part of it, and the FTS self-heal scope is
    /// NOT: `SyncEngineFTS.selfHealBackfillFTSMembership` deliberately omits the
    /// oversized conjunct because it re-indexes HEADERS, and an oversized row's header
    /// is healthy. The two predicates diverged when the durable flag shipped; do not
    /// re-merge them.
    /// ⚠️ NOT a transcription of the admission predicate. A hand-copied `SELECT` here
    /// could not go red when production's changed — it would keep asserting the old
    /// predicate against a queue that had stopped using it, which is precisely how a test
    /// blesses the regression it was written to catch. So this drives the REAL queue:
    /// a fresh instance, its real `repopulateFromDatabase()`, and whether the row is in
    /// the work it admitted. "Reachable by a later background body fetch" has no more
    /// direct definition than that.
    private func isEligibleForLaterBodyFetch(headerId: String) async throws -> Bool {
        let header = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        guard let header else { return false }
        // Inbox rows are the ACTIVE queue's; everything else the BACKFILL queue's. The
        // split is the `isInInbox` conjunct in the two admission queries, so asking the
        // wrong queue would report a false negative for every row.
        if header.isInInbox {
            let queue = ActiveBodyQueue()
            await queue.repopulateFromDatabase()
            return await queue.queuedItemsForTesting.contains { $0.headerId == headerId }
        }
        let queue = BackfillBodyQueue()
        await queue.repopulateFromDatabase()
        return await queue.queuedItemsForTesting.contains { $0.headerId == headerId }
    }

    /// The same predicate MINUS the oversized flag. Pairing the two is what makes the
    /// quarantine assertions two-sided: it proves the row left background admission
    /// BECAUSE of the flag, and not because it was marked complete, marked empty, or
    /// deleted — i.e. that it is still an ordinary pending-body row underneath, which is
    /// what keeps the quarantine reversible (a UIDVALIDITY reset, Smart Reindex, or the
    /// migration that ships a raised parser bound clears the flag and the row is
    /// immediately eligible again).
    ///
    /// ⚠️ This is NOT a claim that the row is still reachable on demand. Since the owner
    /// decision of 2026-09-01 the user-open path (`MessageDetailViewModel.loadBody`)
    /// reads the flag too and reports "unable to load" without a wire attempt; the
    /// remaining live retry is pull-to-refresh (`refetchBody`).
    /// Also a production symbol, not a replica: `SyncEngine.backfillFTSSelfHealCandidateSQL`
    /// IS this predicate — `headerComplete = 1 AND bodyComplete = 0 AND
    /// bodyEmptyConfirmed = 0`, with no oversized conjunct — because the FTS self-heal is
    /// the one scope that deliberately keeps quarantined rows. Reusing it here makes the
    /// control real and pins the divergence from both directions at once: if anyone ever
    /// adds the flag to that scope, every two-sided assertion in this suite goes red.
    private func isPendingBodyIgnoringOversizedFlag(headerId: String) async throws -> Bool {
        let ids: [String] = try await AppDatabase.dbPool.read { db in
            try String.fetchAll(db, sql: SyncEngine.backfillFTSSelfHealCandidateSQL)
        }
        return ids.contains(headerId)
    }

    // MARK: Side 1 — oversized must never be recorded as fetched

    @Test("ActiveBodyQueue: an oversized single-item batch leaves the row bodyComplete=0/bodyEmptyConfirmed=0, durably flagged out of background admission, and an ordinary pending-body row underneath")
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
        // The durable half is dispatched, not awaited, so the row assertions below must
        // wait for it — otherwise they race and pass or fail by timing.
        await queue.awaitDurableWritesForTesting()

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
        #expect(stored.missFetchCount == 0, "nor a strike from the MISS budget — the server answered, and the answer was merely too big to parse; a miss is a message that was not there at all")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "the durable flag must take the row OUT of background admission — that is the fix; an in-memory-only quarantine re-fetched it every launch")
        #expect(try await isPendingBodyIgnoringOversizedFlag(headerId: header.id),
                "…and ONLY the flag may exclude it: underneath it is still an ordinary pending-body row, so clearing the flag restores eligibility with no other repair")
        #expect(stored.bodyMetadataOversized, "the flag is the durable half of the quarantine")

        // ...and the quarantine really is the in-memory one, not a completion.
        #expect(await queue.oversizedDeferredThisSession.contains(header.id))
        let snapshot = await queue.storageSnapshotForTesting
        #expect(snapshot.recentlyCompletedCount == 0, "a quarantined item must never be recorded as completed")
        #expect(snapshot.activeJobs == 0, "the defer must not touch activeJobs — this queue tracks activeBatchCount instead")
    }

    @Test("BackfillBodyQueue: an oversized single-item batch leaves the row bodyComplete=0/bodyEmptyConfirmed=0, durably flagged out of background admission, and an ordinary pending-body row underneath")
    func backfillOversizedNeverMarksRowFetched() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        await queue.setFolderMaxBatchForTesting(1, folderPath: header.folderPath)
        let item = backfillItem(header.id, folderPath: header.folderPath)
        #expect(await queue.admit(item) == true)

        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        // The durable half is dispatched, not awaited, so the row assertions below must
        // wait for it — otherwise they race and pass or fail by timing.
        await queue.awaitDurableWritesForTesting()

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
        #expect(stored.missFetchCount == 0, "nor a strike from the MISS budget — the server answered, and the answer was merely too big to parse; a miss is a message that was not there at all")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "the durable flag must take the row OUT of background admission")
        #expect(try await isPendingBodyIgnoringOversizedFlag(headerId: header.id),
                "…and ONLY the flag may exclude it — clearing it restores eligibility with no other repair")
        #expect(stored.bodyMetadataOversized)

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
            hasUnresolvedICS: false,
            // This fixture's row was never moved (its key encodes its own folder) and its
            // rfc822 id is nil, so `BodyAddressGate` has nothing to refuse and the
            // confirmed-empty path runs exactly as before.
            fetchedRfc822MessageId: nil
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
                "a confirmed-empty message is correctly retired from the body queues — by bodyEmptyConfirmed, a different clause than the oversized flag")
    }

    // MARK: Side 3 — the quarantine must survive the process that made it

    /// THE HEADLINE INVARIANT. The pre-fix quarantine lived only in
    /// `oversizedDeferredThisSession`, an in-memory Set rebuilt empty on every launch,
    /// so every launch re-fetched every oversized message and failed again — each
    /// failure tearing down the connection and forcing a full TCP+TLS+LOGIN+SELECT on
    /// the next attempt.
    ///
    /// Asserted as a SYSTEM PROPERTY, not a mechanism: a queue that has just been
    /// constructed (in-memory set provably empty — i.e. the relaunch condition) must
    /// still not see the row as admissible. Pre-fix this fails, because the only thing
    /// excluding the row was the set that a relaunch clears.
    @Test("ActiveBodyQueue: the oversized quarantine survives a relaunch — a fresh queue with an empty in-memory set still does not re-admit the row")
    func activeOversizedQuarantineSurvivesRelaunch() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        await queue.setFolderMaxBatchForTesting(1, folderPath: header.folderPath)
        let item = activeItem(header.id, folderPath: header.folderPath)
        #expect(await queue.admit(item) == true)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        // The relaunch: a brand-new actor, so nothing survives in memory.
        let afterRelaunch = ActiveBodyQueue()
        #expect(await afterRelaunch.oversizedDeferredThisSession.isEmpty,
                "precondition — a fresh queue's in-memory quarantine is empty, which is exactly why the pre-fix build re-fetched")

        // Drive the REAL launch-path repopulate, not a replica of its predicate: a
        // test that re-typed the SQL would stay green against a build whose production
        // query had lost the oversized conjunct.
        await afterRelaunch.repopulateFromDatabase()
        #expect(await afterRelaunch.queuedItemsForTesting.contains { $0.headerId == header.id } == false,
                "the durable flag, not process memory, must keep the row out of the launch repopulate")

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false)
        #expect(try await isPendingBodyIgnoringOversizedFlag(headerId: header.id),
                "and it is still an ordinary pending-body row underneath — nothing was marked complete or empty")

        // Two-sided, and the forward path the owner asked for on 2026-09-01: once an
        // upstream parser fix lands, clearing the flag is the whole re-fetch mechanism.
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 0 WHERE id = ?",
                           arguments: [header.id])
        }
        let afterUpstreamFix = ActiveBodyQueue()
        await afterUpstreamFix.repopulateFromDatabase()
        #expect(await afterUpstreamFix.queuedItemsForTesting.contains { $0.headerId == header.id },
                "clearing the flag must be sufficient to re-admit the row — nothing else about it was mutated")
    }

    @Test("BackfillBodyQueue: the oversized quarantine survives a relaunch")
    func backfillOversizedQuarantineSurvivesRelaunch() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        await queue.setFolderMaxBatchForTesting(1, folderPath: header.folderPath)
        let item = backfillItem(header.id, folderPath: header.folderPath)
        #expect(await queue.admit(item) == true)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        let afterRelaunch = BackfillBodyQueue()
        #expect(await afterRelaunch.oversizedDeferredThisSession.isEmpty)
        await afterRelaunch.repopulateFromDatabase()
        #expect(await afterRelaunch.queuedItemsForTesting.contains { $0.headerId == header.id } == false,
                "the durable flag must keep the row out of the real launch repopulate")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false)
        #expect(try await isPendingBodyIgnoringOversizedFlag(headerId: header.id))

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 0 WHERE id = ?",
                           arguments: [header.id])
        }
        let afterUpstreamFix = BackfillBodyQueue()
        await afterUpstreamFix.repopulateFromDatabase()
        #expect(await afterUpstreamFix.queuedItemsForTesting.contains { $0.headerId == header.id },
                "clearing the flag must be sufficient to re-admit the row")
    }

    /// A multi-item overflow does not say WHICH item was too large. Flagging there
    /// would durably quarantine healthy siblings — a permanent version of the bug the
    /// isolation branch exists to avoid.
    @Test("A multi-item overflow durably flags NOTHING — the batch error does not identify the oversized item")
    func multiItemOverflowFlagsNothing() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        // A healthy sibling sharing the batch.
        var sibling = MessageHeader(
            messageId: "4243", subject: "An ordinary message",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "recipient@example.com", date: Date(), snippet: "",
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: header.folderPath),
            accountId: "acc1", folderPath: header.folderPath, isInInbox: false
        )
        sibling.headerComplete = true
        let siblingRow = sibling
        try await AppDatabase.dbPool.write { db in try siblingRow.insert(db) }

        let queue = BackfillBodyQueue()
        let items = [backfillItem(header.id, folderPath: header.folderPath),
                     backfillItem(sibling.id, folderPath: header.folderPath)]
        await queue.handlePayloadTooLarge(items: items, folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        for id in [header.id, sibling.id] {
            #expect(try await isEligibleForLaterBodyFetch(headerId: id),
                    "neither item may be durably flagged from an unattributed batch failure")
        }
        #expect(await queue.isolationPendingForTesting.count == 2,
                "both are isolated instead, so a later single-item dispatch can attribute the overflow")
    }

    /// The generation guard already refuses the in-memory insert when a UIDVALIDITY
    /// reset raced the fetch window. The durable write must obey the SAME guard —
    /// otherwise the flag outlives the address it describes, which is the stale
    /// quarantine the guard exists to prevent, made permanent.
    @Test("A stale generation skips the durable write, not just the in-memory insert")
    func staleGenerationSkipsTheDurableWrite() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        let captured = await queue.resetGenerationForTesting
        // A UIDVALIDITY reset lands mid-flight: this bumps resetGeneration.
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)

        let item = backfillItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(
            items: [item], folderPath: header.folderPath, capturedGeneration: captured
        )
        await queue.awaitDurableWritesForTesting()

        #expect(await queue.oversizedDeferredThisSession.isEmpty,
                "precondition — the in-memory insert is skipped as stale")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the durable write must be skipped too — a stale flag would starve a new-epoch message reusing this UID")
    }

    /// A UIDVALIDITY reset means the folder's UIDs no longer address the same
    /// messages, so a per-address observation is void and must not outlive it.
    @Test("A UIDVALIDITY reset clears the DURABLE flag, not only the in-memory set")
    func uidValidityResetClearsTheDurableFlag() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        let item = backfillItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "precondition — the row is durably flagged")

        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the reset releases the durable quarantine as well as the in-memory one")
    }

    // MARK: The same three durable properties on the ACTIVE queue

    /// The three tests above ran only on `BackfillBodyQueue`. Both queues carry their
    /// OWN copy of `markOversizedDurably` / `clearOversizedDurably` / the generation
    /// guard, so a defect in either copy is invisible to a suite that exercises one.
    /// (`feedback_half_port_drops_the_guard`: the half that is never driven is exactly
    /// where the guard goes missing.) The inbox fixture is the only difference.
    @Test("ActiveBodyQueue: a multi-item overflow durably flags NOTHING")
    func activeMultiItemOverflowFlagsNothing() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        var sibling = MessageHeader(
            messageId: "4243", subject: "An ordinary message",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "recipient@example.com", date: Date(), snippet: "",
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: header.folderPath),
            accountId: "acc1", folderPath: header.folderPath, isInInbox: true
        )
        sibling.headerComplete = true
        let siblingRow = sibling
        try await AppDatabase.dbPool.write { db in try siblingRow.insert(db) }

        let queue = ActiveBodyQueue()
        let items = [activeItem(header.id, folderPath: header.folderPath),
                     activeItem(sibling.id, folderPath: header.folderPath)]
        await queue.handlePayloadTooLarge(items: items, folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        for id in [header.id, sibling.id] {
            #expect(try await isEligibleForLaterBodyFetch(headerId: id),
                    "neither item may be durably flagged from an unattributed batch failure")
        }
        #expect(await queue.isolationPendingForTesting.count == 2)
    }

    @Test("ActiveBodyQueue: a stale generation skips the durable write, not just the in-memory insert")
    func activeStaleGenerationSkipsTheDurableWrite() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let captured = await queue.resetGenerationForTesting
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)

        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(
            items: [item], folderPath: header.folderPath, capturedGeneration: captured
        )
        await queue.awaitDurableWritesForTesting()

        #expect(await queue.oversizedDeferredThisSession.isEmpty,
                "precondition — the in-memory insert is skipped as stale")
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the durable write must be skipped too — a stale flag would starve a new-epoch message reusing this UID")
    }

    @Test("ActiveBodyQueue: a UIDVALIDITY reset clears the DURABLE flag, not only the in-memory set")
    func activeUidValidityResetClearsTheDurableFlag() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "precondition — the row is durably flagged")

        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the reset releases the durable quarantine as well as the in-memory one")
    }

    // MARK: The mark and the release cannot land out of order

    /// Both durable writes are dispatched off the actor (they must not block the queue
    /// on a `.background` pool write), so their ORDER is a property of the serializing
    /// chain, not of the actor. If they could interleave, a UIDVALIDITY reset arriving
    /// right after an overflow could be overtaken by the mark it is meant to release —
    /// leaving a new-epoch message quarantined by an observation about a message that
    /// no longer exists at that address, with no further event to clear it.
    ///
    /// Asserted as the observable end state after BOTH orders, with no drain in
    /// between, which is the only condition under which a race can express itself.
    @Test("ActiveBodyQueue: a release issued after a mark wins, with no intervening drain")
    func activeReleaseAfterMarkWins() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        // No drain here — this is the point of the test.
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the LAST issued write is the release, so the row must end up admissible")
        try await Self.settleAndExpectStable(headerId: header.id, eligible: true) {
            try await isEligibleForLaterBodyFetch(headerId: $0)
        }
    }

    @Test("ActiveBodyQueue: a mark issued after a release wins, with no intervening drain")
    func activeMarkAfterReleaseWins() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "the LAST issued write is the mark, so the row must end up quarantined — the mirror image of the case above")
        try await Self.settleAndExpectStable(headerId: header.id, eligible: false) {
            try await isEligibleForLaterBodyFetch(headerId: $0)
        }
    }

    /// ⚠️ WITHOUT THIS THE ORDERING TESTS ARE HALF-BLIND, and that was MEASURED, not
    /// assumed. `awaitDurableWritesForTesting()` awaits the LAST chain task. When the
    /// chain is intact that transitively awaits every predecessor — but a build whose
    /// chaining was removed leaves the earlier write still in flight, and the
    /// direction whose LAST write is not the one under assertion then reads the right
    /// value for the wrong reason — the earlier write simply had not landed yet — and
    /// passes. Removing `await previous?.value` from `enqueueDurableWrite` left both
    /// directions GREEN until this settle window was added.
    ///
    /// So: after the drain, give any straggler a bounded window and re-read. Against a
    /// correctly chained build nothing is outstanding, so the value cannot change and
    /// this cannot flake; against an unchained one the late write lands inside the
    /// window and flips it.
    ///
    /// ✅ BOTH directions are now provably red, each against the mutant that delays the
    /// write it is blind to: chain removed + 60 ms on the MARK fails
    /// `activeReleaseAfterMarkWins`; chain removed + 60 ms on the CLEAR fails
    /// `activeMarkAfterReleaseWins`. Neither direction is a decorative control.
    private static func settleAndExpectStable(
        headerId: String,
        eligible: Bool,
        _ read: (String) async throws -> Bool
    ) async throws {
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await read(headerId) == eligible,
                "a durable write was still in flight after the drain — the writes are not serialized behind one chain")
    }

    @Test("BackfillBodyQueue: a release issued after a mark wins, with no intervening drain")
    func backfillReleaseAfterMarkWins() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        let item = backfillItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id))
        try await Self.settleAndExpectStable(headerId: header.id, eligible: true) {
            try await isEligibleForLaterBodyFetch(headerId: $0)
        }
    }

    @Test("BackfillBodyQueue: a mark issued after a release wins, with no intervening drain")
    func backfillMarkAfterReleaseWins() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        let queue = BackfillBodyQueue()
        await queue.clearOversizedDeferred(accountId: "acc1", folderPath: header.folderPath)
        let item = backfillItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false)
        try await Self.settleAndExpectStable(headerId: header.id, eligible: false) {
            try await isEligibleForLaterBodyFetch(headerId: $0)
        }
    }

    // MARK: A successful fetch retracts the observation

    /// 🚨 THE STALE-FLAG INVARIANT. The flag records ONE failed wire attempt against one
    /// address; the parser bound is fragmentation-dependent, so the very next attempt on
    /// a different connection can succeed. If a success left the flag standing, the row
    /// would carry a permanent lie — and `BodyAssetMaintenance` (which evicts the
    /// `messageBody` row while deliberately leaving `bodyComplete = 1`, relying on the
    /// detail view's cache-miss fetch as the sole recovery) would turn that lie into a
    /// permanently unopenable message that this build had already fetched once.
    ///
    /// Driven through the REAL success write (`BodyFetchProcessor.flushBatch`), not a
    /// replica of its UPDATE.
    @Test("A successful body write retracts the oversized observation")
    func successfulBodyWriteClearsTheFlag() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "precondition — the row is durably flagged")

        // flushBatch only writes the header once the FTS row is confirmed present.
        let record = FTSHeaderRecord(
            contentKey: ContentKey(rawValue: header.id),
            headerId: header.id, messageId: header.messageId, subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>", to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        try await SearchIndex.shared.removeMessages(contentKeys: [ContentKey(rawValue: header.id)])
        _ = try await SearchIndex.shared.indexHeaders([record])
        defer {
            let key = ContentKey(rawValue: header.id)
            Task { try? await SearchIndex.shared.removeMessages(contentKeys: [key]) }
        }

        await BodyFetchProcessor.flushBatch([
            BodyFetchProcessor.ProcessedItem(
                contentKey: ContentKey(rawValue: header.id),
                headerId: header.id, accountId: header.accountId, isInInbox: true,
                body: "the body did arrive on a differently fragmented connection",
                snippet: "it arrived")
        ], enableAI: false)

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(row?.bodyComplete == true, "precondition — the success write landed")
        #expect(row?.bodyMetadataOversized == false,
                "a written body refutes the overflow observation; leaving it set would brick this row on the next cache eviction")
    }

    // MARK: The mark's own `AND bodyComplete = 0` guard

    /// The durable mark is dispatched, not awaited — so a body can land between the
    /// overflow and the write. `markOversizedDurably` carries `AND bodyComplete = 0`
    /// precisely for that window: quarantining a row that now HAS a body would create
    /// the stale flag the eviction fail-safe exists to survive, at the one moment the
    /// system knows better.
    ///
    /// The property is the end state, not the statement: after an overflow on a row that
    /// has since completed, the row is not quarantined.
    @Test("ActiveBodyQueue: an overflow cannot quarantine a row that acquired a body first")
    func activeMarkSkipsARowThatAlreadyHasABody() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        // The body landed while the overflow was still in flight.
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                           arguments: [header.id])
        }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.bodyMetadataOversized == false,
                "a row that already has a body must never acquire the flag — that is a stale flag minted deliberately")
        #expect(stored.bodyComplete, "and the body it acquired is untouched")
    }

    /// NON-VACUITY for the guard above, from the other side. Without it the assertion
    /// could pass on a build whose mark had stopped writing at all.
    @Test("CONTROL: the identical overflow DOES quarantine the same row when it has no body")
    func activeMarkStillFlagsABodylessRow() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.bodyMetadataOversized,
                "the ONLY difference from the case above is bodyComplete, so the mark must land here")
    }

    @Test("BackfillBodyQueue: an overflow cannot quarantine a row that acquired a body first")
    func backfillMarkSkipsARowThatAlreadyHasABody() async throws {
        let (header, restore) = try makeSwappedDB(folderPath: "Archive", isInInbox: false)
        defer { restore() }

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                           arguments: [header.id])
        }

        let queue = BackfillBodyQueue()
        let item = backfillItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.bodyMetadataOversized == false,
                "the backfill queue runs over whole mailboxes, so a mark that ignores the guard mints stale flags in bulk")
    }

    // MARK: The confirmed-empty success write

    /// The FOURTH clear site, and the least obvious one: a body fetch that comes back
    /// empty three times writes `bodyComplete = 1` for the UI. That write must clear the
    /// flag too — it is a success write like any other, and leaving the flag standing
    /// beside `bodyComplete = 1` is exactly the stale-flag shape the detail view's
    /// fail-safe has to absorb. Driven through the REAL `BodyFetchProcessor.process`.
    @Test("The confirmed-empty write clears the oversized flag, through the real processor")
    func confirmedEmptyWriteClearsTheFlag() async throws {
        // Two prior empties already recorded — this fetch is the third, which confirms.
        let (header, restore) = try makeSwappedDB(emptyFetchCount: 2)
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "precondition — the row is durably flagged")

        let result = await BodyFetchProcessor.process(
            fetchResult: BodyFetchProcessor.FetchResult(
                item: BodyFetchProcessor.Item(
                    headerId: header.id, accountId: header.accountId,
                    folderPath: header.folderPath, messageId: header.messageId,
                    isInInbox: header.isInInbox),
                renderedBody: MessageBody(contentKey: ContentKey(rawValue: header.id), htmlContent: ""),
                plainText: nil,
                hasAttachments: false,
                hasUnresolvedICS: false,
                fetchedRfc822MessageId: nil),
            enableAI: false)

        #expect(result.0 == .confirmedEmpty, "precondition — the third empty fetch confirms")
        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.bodyComplete, "precondition — the confirmed-empty write landed")
        #expect(stored.bodyMetadataOversized == false,
                "every write that sets bodyComplete = 1 must retract the overflow observation, or the row carries a permanent lie")
    }

    // MARK: Smart Reindex, through the real method

    /// Smart Reindex is the user-invoked "try everything again" gesture, and — until an
    /// upstream parser fix ships — it is the one gesture that releases a whole account's
    /// quarantine. Driven through the PRODUCTION method, not a copy of its `UPDATE`:
    /// a replica cannot go red when production's statement regresses, and this
    /// statement has a known silent-failure mode (the flag must appear in the `WHERE`
    /// as well as the `SET`, since a flagged row has `bodyEmptyConfirmed = 0`).
    ///
    /// The property asserted is the end state a user would observe: the row is no
    /// longer quarantined AND the launch repopulate admits it again.
    @Test("Smart Reindex releases the quarantine, through the real resetCrawlState()")
    func smartReindexReleasesTheQuarantineThroughTheRealMethod() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let queue = ActiveBodyQueue()
        let item = activeItem(header.id, folderPath: header.folderPath)
        await queue.handlePayloadTooLarge(items: [item], folderPath: header.folderPath)
        await queue.awaitDurableWritesForTesting()
        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id) == false,
                "precondition — the row is durably flagged")

        await SyncEngine().resetCrawlState()

        #expect(try await isEligibleForLaterBodyFetch(headerId: header.id),
                "the user's try-everything-again gesture must release the quarantine")
        let afterReindex = ActiveBodyQueue()
        await afterReindex.repopulateFromDatabase()
        #expect(await afterReindex.queuedItemsForTesting.contains { $0.headerId == header.id },
                "and the row must actually come back into the queue, not merely lose a column value")
    }

    // MARK: - Round-3 audit findings

    @Test("An overflow observed inside an optimistic-move window is not recorded against the row it cannot be about")
    func midMoveOverflowIsNotRecordedAgainstThatRow() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        // Reproduce the `optimisticMoveToFolder` window exactly: the row's COLUMNS are
        // rewritten to the destination while its PRIMARY KEY still encodes the SOURCE
        // folder and UID. In that window the bytes fetched at the columns' address belong
        // to a DIFFERENT message, so an overflow observed there is not evidence about the
        // message this row's key names.
        let destination: Folder = {
            var f = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
            f.lastKnownUidValidity = 1000
            return f
        }()
        try await AppDatabase.dbPool.write { db in
            try destination.insert(db)
            try db.execute(
                sql: "UPDATE messageHeader SET folderPath = ?, folderId = ? WHERE id = ?",
                arguments: ["Archive",
                            MessageIdentity.folderId(accountId: "acc1", folderPath: "Archive"),
                            header.id])
        }
        #expect(
            BodyAddressGate.addressIsInFlight(
                id: header.id, accountId: "acc1", folderPath: "Archive", messageId: header.messageId),
            "fixture check: the row must actually be mid-move, or this test proves nothing")

        await BodyFetchProcessor.markOversizedDurably(headerId: header.id)
        // The mark is enqueued on `ActiveBodyQueue`'s serialized durable-write chain,
        // shared with the UIDVALIDITY reset's clear so the two cannot commit out of
        // order. Drain it before reading, or this asserts on a write that has not run.
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let moved = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        // The INVARIANT: a durable quarantine may only record an observation that is
        // about the row it is written to. Marking here is permanent — the flag rides the
        // re-key — so a fetchable message would be excluded from both admission queries,
        // counted as settled, and refused by every read gate, forever.
        #expect(
            moved.bodyMetadataOversized == false,
            "an overflow seen at the destination address must not be recorded against a row still keyed to the source")

        // Positive control on the SAME statement, so the refusal above cannot be vacuous:
        // once key and columns agree, the identical call does flag the row.
        try await AppDatabase.dbPool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderPath = ?, folderId = ? WHERE id = ?",
                arguments: [header.folderPath,
                            MessageIdentity.folderId(accountId: "acc1", folderPath: header.folderPath),
                            header.id])
        }
        await BodyFetchProcessor.markOversizedDurably(headerId: header.id)
        // The mark is enqueued on `ActiveBodyQueue`'s serialized durable-write chain,
        // shared with the UIDVALIDITY reset's clear so the two cannot commit out of
        // order. Drain it before reading, or this asserts on a write that has not run.
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()
        let settled = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(settled.bodyMetadataOversized, "control: a row whose key matches its columns is still flagged")
    }

    /// 🚨 THE ORDERING PROPERTY the source calls "a CORRECTNESS requirement, not tidiness".
    ///
    /// `BodyFetchProcessor.markOversizedDurably` deliberately routes the two NON-queue
    /// writers (the user-open funnel and the snippet loader's tier 2) onto
    /// `ActiveBodyQueue.shared`'s serialized chain — the same chain the UIDVALIDITY reset's
    /// clear uses. Ordering between a mark and a clear is defined only for writers that
    /// SHARE that chain: a mark that wrote directly could commit after a reset's clear and
    /// re-quarantine a row whose address no longer refers to the message that overflowed.
    ///
    /// The observable form of "they share the chain" is that dispatch order survives to the
    /// database: mark first, clear second, and the row ends up RELEASED. Nothing else in the
    /// suite pins this — the existing tests drain the chain and assert the mark landed,
    /// which a chain-bypassing implementation also satisfies. (Found by audit.)
    @Test("A non-queue mark and the reset's clear commit in dispatch order, because they share one chain")
    func nonQueueMarkIsOrderedAgainstTheResetClear() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        // Enqueued, not awaited to completion: `markOversizedDurably` returns once the
        // write is ON the chain, which is exactly the window this test is about.
        await BodyFetchProcessor.markOversizedDurably(headerId: header.id)
        await ActiveBodyQueue.shared.clearOversizedDeferred(accountId: "acc1", folderPath: "INBOX")
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let afterReset = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(afterReset.bodyMetadataOversized == false,
                "a UIDVALIDITY reset dispatched after a mark must win — the reset is newer evidence, and an observation about an address the reset invalidated must not survive it")
        // Same settle window the queue-writer ordering tests use, and for the same measured
        // reason: `awaitDurableWritesForTesting()` awaits the LAST chain task, so on a build
        // whose chaining was removed this would read the right value for the wrong reason —
        // the mark simply had not landed yet. Against a correctly chained build nothing is
        // outstanding, so this cannot flake.
        try await Self.settleAndExpectStable(headerId: header.id, eligible: true) {
            try await isEligibleForLaterBodyFetch(headerId: $0)
        }

        // NON-VACUITY, and it is what stops this passing on a build that never marks at
        // all: the identical mark with no clear behind it DOES leave the row quarantined.
        await BodyFetchProcessor.markOversizedDurably(headerId: header.id)
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()
        let afterMark = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(afterMark.bodyMetadataOversized,
                "control: the same call, with nothing dispatched behind it, records the observation")

        // Leave the shared queue's session state as it was found — this suite's other
        // tests construct their own instances, but `.shared` is process-wide.
        await ActiveBodyQueue.shared.clearOversizedDeferred(accountId: "acc1", folderPath: "INBOX")
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()
    }

    @Test("The snippet-tier body write clears the quarantine, like every other success write")
    func applySnippetUpdatesClearsTheFlag() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
        }
        #expect(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)?.bodyMetadataOversized == true
        }, "fixture check: the row starts quarantined")

        await SyncEngine().applySnippetUpdates([(headerId: header.id, snippet: "a body arrived")])

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        // The INVARIANT: any successful body write is positive evidence refuting the
        // observation, so it must retract it. This writer is a GRDB `updateAll` chain and
        // is invisible to an `rg 'bodyMetadataOversized = 0'` census — the reason it needs
        // its own pin rather than relying on that census.
        #expect(stored.bodyComplete, "fixture check: the snippet write completes the body")
        #expect(
            stored.bodyMetadataOversized == false,
            "a success write must retract the quarantine, or eviction later strands a body this build already fetched")
    }

    /// TWO quarantined rows, because the bucket predicates subtract the quarantine from
    /// two different siblings and one fixture cannot exercise both. A quarantined row with
    /// `emptyFetchCount > 0` is the overlap the FAILING bucket must subtract; a quarantined
    /// row with `emptyFetchCount = 0` is the overlap the PENDING bucket must subtract.
    ///
    /// ⚠️ MEASURED TWICE, and the second time is why every bucket is now occupied.
    /// (1) With only the `emptyFetchCount = 2` row, deleting `AND m.bodyMetadataOversized = 0`
    /// from `bodylessPendingPredicate` left this test GREEN — that row fails
    /// `emptyFetchCount = 0` either way, so the mutation was invisible to it.
    /// (2) With two rows that were BOTH quarantined, three of the four buckets were pinned
    /// only at zero, so deleting `AND m.bodyEmptyConfirmed = 0` or
    /// `AND m.bodyMetadataOversized = 1` from `bodylessQuarantinedPredicate` was still
    /// invisible. A partition assertion over an empty bucket proves nothing about that
    /// bucket. (Found by audit.)
    @Test("The bodyless diagnostic buckets stay an exact partition with every bucket occupied")
    func bodylessDiagnosticBucketsArePartition() async throws {
        let (header, restore) = try makeSwappedDB(emptyFetchCount: 2)
        defer { restore() }

        // Additional rows, all in the same account+folder so they share the `folder` join
        // the production scan does. One per bucket, so NO bucket is pinned only at zero —
        // an all-quarantined fixture left the `bodyEmptyConfirmed = 0` and
        // `bodyMetadataOversized = 1` conjuncts of the QUARANTINED predicate invisible.
        // (Found by audit.)
        func row(_ messageId: String, emptyFetchCount: Int = 0, confirmedEmpty: Bool = false) -> MessageHeader {
            var h = MessageHeader(
                messageId: messageId,
                subject: "A message in the bodyless backlog",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: Date(),
                snippet: "",
                folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            h.headerComplete = true
            h.emptyFetchCount = emptyFetchCount
            h.bodyEmptyConfirmed = confirmedEmpty
            return h
        }
        // QUARANTINED, no strikes — the overlap the PENDING bucket must subtract.
        let clean = row("4243")
        // LOCKED, and ALSO flagged: `bodylessLockedPredicate` does not exclude the flag,
        // while `bodylessQuarantinedPredicate` excludes confirmed-empty. So this row must
        // land in exactly ONE bucket, and it is what makes that conjunct falsifiable.
        let lockedRow = row("4244", emptyFetchCount: 3, confirmedEmpty: true)
        // FAILING, unflagged — the overlap the FAILING bucket must subtract.
        let failingRow = row("4245", emptyFetchCount: 1)
        // PENDING, unflagged — ordinary work remaining.
        let pendingRow = row("4246")
        // Every flag is written through the production writer, not by raw SQL, so the
        // fixture cannot drift from what that writer would actually record.
        try await AppDatabase.dbPool.write { db in
            try clean.insert(db)
            try lockedRow.insert(db)
            try failingRow.insert(db)
            try pendingRow.insert(db)
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: clean.id)
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: lockedRow.id)
        }

        // `rawPool`, not `dbPool`: `StuckMessageDiagnostics.count` takes the bare
        // `DatabasePool` the production scan uses, not the prioritized wrapper.
        let pool = AppDatabase.rawPool
        let bodyless = await StuckMessageDiagnostics.countForTesting(pool, "m.bodyComplete = 0")
        let locked = await StuckMessageDiagnostics.countForTesting(
            pool, StuckMessageDiagnostics.bodylessLockedPredicate)
        let quarantined = await StuckMessageDiagnostics.countForTesting(
            pool, StuckMessageDiagnostics.bodylessQuarantinedPredicate)
        let failing = await StuckMessageDiagnostics.countForTesting(
            pool, StuckMessageDiagnostics.bodylessFailingPredicate)
        let pending = await StuckMessageDiagnostics.countForTesting(
            pool, StuckMessageDiagnostics.bodylessPendingPredicate)

        #expect(bodyless == 5, "fixture check: exactly five bodyless rows")
        // The INVARIANT: the buckets partition `bodyless`. Double-counting a quarantined
        // row reports work still queued that no queue will ever offer again, which is the
        // exact misreading this scan exists to prevent. Stated as a sum, not as four
        // separate equalities, so it holds however the buckets are later re-cut.
        #expect(
            locked + quarantined + failing + pending == bodyless,
            "the four buckets must partition bodyless — got \(locked)+\(quarantined)+\(failing)+\(pending) vs \(bodyless)")
        // …and NON-VACUITY, one row per bucket. Without these the sum above is satisfied
        // by a build where three buckets are permanently empty, which is how the previous
        // version of this fixture hid two live mutations.
        #expect(locked == 1, "the confirmed-empty row belongs to LOCKED — and only there, though it also carries the flag")
        #expect(quarantined == 2, "both flagged, not-confirmed-empty rows belong to QUARANTINED, regardless of strikes")
        #expect(failing == 1, "the unflagged row with strikes is FAILING; the flagged one with strikes must not join it")
        #expect(pending == 1, "the unflagged row with no strikes is PENDING; the flagged one with no strikes must not join it")
    }

    /// The durable clear's SCOPE, which nothing else pins.
    ///
    /// Every other clear test in this tree asserts the in-memory
    /// `oversizedDeferredThisSession` / `isolationPendingForTesting` sets — a header-id
    /// STRING filter that the production comment itself records as a DIFFERENT predicate
    /// from the SQL column filter. And every DB fixture here seeds exactly one account,
    /// one folder and one row, so `WHERE accountId = ? AND folderPath = ?` is satisfied
    /// vacuously: drop either conjunct and the whole suite stays green.
    ///
    /// What that would cost in production: any folder's UIDVALIDITY reset (or Smart
    /// Reindex, which shares this writer) would release the quarantine for every flagged
    /// row in the account — or, without the accountId term, on the device. Those rows
    /// re-enter admission, overflow the response buffer again, and re-trigger the
    /// connection-teardown loop this change exists to stop, now fanned out across folders
    /// no gesture named. That is issue #104's own regression, wider.
    ///
    /// TWO-SIDED BY CONSTRUCTION: one bystander defeats only the `folderPath` conjunct and
    /// the other only the `accountId` conjunct, so each term is pinned separately rather
    /// than both together. (Found by audit.)
    @Test("The durable clear releases ONE account's ONE folder — a sibling folder and a second account keep theirs")
    func durableClearIsScopedToItsAccountAndFolder() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        let sameAccountOtherFolder = try await seedFlaggedBystander(
            accountId: "acc1", folderPath: "Archive", messageId: "7001")
        let otherAccountSameFolder = try await seedFlaggedBystander(
            accountId: "acc2", folderPath: "INBOX", messageId: "7002")
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
        }
        // Fixture check: all three are flagged BEFORE the clear, or the assertions below
        // are satisfied by rows that were never quarantined in the first place.
        #expect(try await durableFlag(header.id))
        #expect(try await durableFlag(sameAccountOtherFolder))
        #expect(try await durableFlag(otherAccountSameFolder))

        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.clearBodyMetadataOversized(
                db, accountId: "acc1", folderPath: "INBOX")
        }

        #expect(try await durableFlag(header.id) == false,
                "the named folder is released — this is the clear doing its job")
        #expect(try await durableFlag(sameAccountOtherFolder),
                "a DIFFERENT folder of the SAME account keeps its quarantine: dropping `AND folderPath = ?` releases every folder the gesture never named")
        #expect(try await durableFlag(otherAccountSameFolder),
                "a folder with the SAME PATH under a DIFFERENT account keeps its quarantine: dropping `AND accountId = ?` releases it across every account on the device")
    }

    @Test("The body-fetch funnel refuses a quarantined row, so every caller is covered without its own gate")
    func funnelRefusesQuarantinedRow() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
        }
        let quarantined = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(quarantined.isBodyQuarantined, "fixture check: the row is quarantined")

        // The INVARIANT: the refusal is at the FUNNEL, so a caller that never heard of the
        // flag cannot spend a connection on it. `MessageDetailViewModel.loadThreadMessageBody`
        // (expanding a collapsed thread bubble) is exactly such a caller — it had no gate
        // and swallowed the failure into a debug print.
        //
        // Asserting the SPECIFIC refusal is what makes this non-vacuous: without the gate
        // the call proceeds past it and fails differently (provider resolution), so a
        // bare "it threw" would stay green on the unfixed code.
        var refusal: NSError?
        do {
            try await AccountManager.shared.fetchBody(for: quarantined)
            Issue.record("the funnel must refuse a quarantined row before any provider work")
        } catch let ProviderError.networkError(underlying) {
            refusal = underlying as NSError
        } catch {
            Issue.record("expected the funnel's typed refusal, got \(error)")
        }
        let ns = try #require(refusal, "the funnel must refuse with its own error, not fall through")
        #expect(ns.domain == BodyFetchRefusal.domain, "the refusal must be the funnel's, not a provider failure")
        #expect(ns.code == BodyFetchRefusal.quarantined, "…and specifically the oversized-quarantine refusal")
    }

    /// The funnel re-reads the header from the database instead of trusting the one the
    /// caller handed it, and THAT is what makes "any future caller is covered for free"
    /// true rather than "covered as far as the caller's copy is fresh".
    ///
    /// Every other funnel test passes a header whose in-memory state already matches its
    /// row, so replacing the fresh read with `message.isBodyQuarantined` survives them all.
    /// The caller this protects is real: `MessageDetailViewModel.loadThreadMessageBody`
    /// (expanding a collapsed thread bubble) holds headers captured when the thread was
    /// loaded, which a background queue can flag at any time afterwards. Under the
    /// mutation every tap on such a row spends a full TCP + TLS + LOGIN + SELECT on a
    /// fetch that overflows, and tears the folder connection down for whatever else was
    /// using it.
    ///
    /// The poll side already has this twin (`bodyPollHonoursAFlagSetWhileItIsRunning`);
    /// the funnel did not. (Found by audit.)
    @Test("The funnel gates on the FRESH row, not the caller's stale copy of it")
    func funnelGatesOnTheFreshRowNotTheCallersStaleCopy() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }

        // `header` is the pre-flag struct and is never re-read — it is deliberately the
        // stale copy a thread bubble would still be holding.
        #expect(header.isBodyQuarantined == false, "fixture check: the caller's copy does NOT know about the flag")
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
        }

        var refusal: NSError?
        do {
            try await AccountManager.shared.fetchBody(for: header)
            Issue.record("the funnel must refuse on the row's CURRENT state, not the caller's snapshot of it")
        } catch let ProviderError.networkError(underlying) {
            refusal = underlying as NSError
        } catch {
            Issue.record("expected the funnel's typed refusal, got \(error)")
        }
        let ns = try #require(refusal, "the funnel must refuse with its own error, not fall through to provider work")
        #expect(ns.domain == BodyFetchRefusal.domain)
        #expect(ns.code == BodyFetchRefusal.quarantined,
                "the refusal must be the oversized-quarantine one — reached only by re-reading the row")
    }

    /// THE ESCAPE HATCH, at the funnel. `replaceExistingBody: true` is pull-to-refresh, and
    /// it is the whole reason the flag is an OBSERVATION rather than a verdict: the parser's
    /// bound is on unread aggregate bytes measured after the decode loop stops, so it is
    /// fragmentation-dependent and the same message can parse fine on a different
    /// connection. Delete the `if !replaceExistingBody` condition — make the gate
    /// unconditional — and the quarantine becomes unfalsifiable by the user, with nothing
    /// else in the build able to retract it.
    ///
    /// Non-vacuity: `funnelRefusesQuarantinedRow` above passes `replaceExistingBody: false`
    /// on the same fixture and demands the refusal, so the two together pin the CONDITION
    /// rather than either outcome. A gate that always fires fails this test; a gate that
    /// never fires fails that one.
    @Test("Pull-to-refresh is exempt at the funnel — the quarantine stays falsifiable by the user")
    func funnelExemptsPullToRefresh() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
        }
        let quarantined = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(quarantined.isBodyQuarantined, "fixture check: the row is quarantined")

        // This call cannot reach the wire and must fail for SOME reason. The assertion is
        // about WHICH reason: anything other than the quarantine refusal means the gate let
        // it past, which is the property under test.
        //
        // ⚠️ WHAT ACTUALLY KEEPS IT OFF THE WIRE is `makeSwappedDB`'s account having no
        // `imapHost`, NOT the absence of a registered provider. An earlier version of this
        // comment said the latter, which is backwards: the quarantine gate sits BEFORE the
        // provider block in `fetchBody`, so `providers[accountId] == nil` is what causes
        // `connectAccount` to be CALLED. It is `createIMAPProvider`'s
        // `guard let host = account.imapHost else { throw .authenticationFailed }` that
        // throws first — before any `IMAPProvider` is constructed, registered in the
        // process-wide `AccountManager.shared`, or asked to `connect()`. `makeSwappedDB`
        // asserts that precondition so a future edit adding host/port here fails loudly
        // instead of silently opening a live connection from a unit test. (Found by audit.)
        var refusalCode: Int?
        do {
            try await AccountManager.shared.fetchBody(for: quarantined, replaceExistingBody: true)
        } catch let ProviderError.networkError(underlying) {
            let ns = underlying as NSError
            if ns.domain == BodyFetchRefusal.domain { refusalCode = ns.code }
        } catch {
            // Provider resolution failing is the expected outcome here — it means the
            // quarantine gate was passed, which is exactly what this test wants.
        }
        #expect(
            refusalCode != BodyFetchRefusal.quarantined,
            "pull-to-refresh must reach past the quarantine gate — without this exemption the flag can never be disproved")
    }

    /// THE EVICTION FAIL-SAFE, at the funnel. `BodyAssetMaintenance` and
    /// `SyncEngine.runEvictStaleBodies` delete a `messageBody` row while deliberately
    /// leaving `bodyComplete = 1` (ADR-IOS-050), and the detail view's cache-miss fetch is
    /// the ONLY recovery. So the funnel must gate on `isBodyQuarantined`
    /// (`bodyMetadataOversized && !bodyComplete`), never on `bodyMetadataOversized` alone —
    /// weaken it to the bare column and a message this build already fetched successfully
    /// becomes permanently unopenable, which is strictly worse than the bug being fixed.
    ///
    /// This cannot be covered by the `MessageDetailViewModel` suites: every test there
    /// injects `_fetchBodyOverride`, and all three of that view model's fetch sites
    /// short-circuit to the override before reaching `AccountManagerFetch.fetchBody`.
    @Test("A stale flag on a proven-fetchable row does not reach the funnel's refusal")
    func funnelDoesNotRefuseAProvenFetchableRow() async throws {
        let (header, restore) = try makeSwappedDB()
        defer { restore() }
        // Flag it, THEN complete it — the eviction shape: fetched once, flag left behind,
        // `messageBody` since deleted. `markBodyMetadataOversized` refuses a completed row,
        // so the flag has to be set first for this state to be reachable at all.
        try await AppDatabase.dbPool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: header.id)
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                           arguments: [header.id])
        }
        let evicted = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(evicted.bodyMetadataOversized, "fixture check: the stale flag is still set")
        #expect(!evicted.isBodyQuarantined, "fixture check: but the row is not quarantined, because it is complete")

        var refusalCode: Int?
        do {
            try await AccountManager.shared.fetchBody(for: evicted)
        } catch let ProviderError.networkError(underlying) {
            let ns = underlying as NSError
            if ns.domain == BodyFetchRefusal.domain { refusalCode = ns.code }
        } catch {
            // Provider resolution failing means the gate was passed — the desired outcome.
        }
        #expect(
            refusalCode != BodyFetchRefusal.quarantined,
            "a stale flag may cost a wasted round trip, never a permanently unopenable message — eviction's only recovery runs through this funnel")
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
/// `.serialized, .processGlobalState`: every `handlePayloadTooLarge` /
/// `clearOversizedDeferred` below dispatches a DURABLE write off the actor, and that
/// write targets the process-global `AppDatabase.shared`. Without the trait the sink
/// database is not guaranteed installed (an escaped write can trip `rawPool`'s
/// force-unwrap and kill the whole test process), and without the drain at each test's
/// end the write can land inside a LATER suite's swapped database. Each affected test
/// therefore ends with `awaitDurableWritesForTesting()` on every queue it touched.
@Suite("Oversized body quarantine terminates the drain/repopulate cycle", .serialized, .processGlobalState)
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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
/// `.serialized, .processGlobalState`: every `handlePayloadTooLarge` /
/// `clearOversizedDeferred` below dispatches a DURABLE write off the actor, and that
/// write targets the process-global `AppDatabase.shared`. Without the trait the sink
/// database is not guaranteed installed (an escaped write can trip `rawPool`'s
/// force-unwrap and kill the whole test process), and without the drain at each test's
/// end the write can land inside a LATER suite's swapped database. Each affected test
/// therefore ends with `awaitDurableWritesForTesting()` on every queue it touched.
@Suite("A UIDVALIDITY reset releases the folder's oversized quarantine", .serialized, .processGlobalState)
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await queue.awaitDurableWritesForTesting()
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

        // Durable writes escape the actor — settle them inside this test's scope.
        await active.awaitDurableWritesForTesting()
        await backfill.awaitDurableWritesForTesting()
    }
}

// MARK: - The quarantine's UI consequence: wake lock vs. completion banner

/// Removing the illegal `bodyEmptyConfirmed = 1` stamp made the quarantined row stay
/// honestly incomplete, which is correct. `BackfillProgress.pendingBodyCount` then never
/// reached 0 for an account holding one oversized message, so
/// `BackfillProgress.isFullyComplete` was false forever for that account.
///
/// `FastSyncView` had TWO consumers keyed off that single durable-completeness fact:
/// the "Sync Complete" banner AND `keepScreenAwake(while: !isAllComplete)`. The second
/// one is a battery-draining defect — the device screen was pinned awake indefinitely.
///
/// The split asserted here:
///   - the WAKE LOCK is a question about the app's CURRENT activity, so it moved to
///     `FastSyncView.keepScreenAwakeWhileWorking` — the header walk plus the two body
///     queues' `isIdle`. That split is independent of everything below and still holds.
///   - the BANNER was, at that time, deliberately LEFT on `isFullyComplete` with the
///     quarantined row still counted, on the reasoning that "Sync Complete" over a
///     genuinely missing body would be a second defect. ⚠️ **Owner decision 2026-09-01
///     reversed that**: the flagged row is now excluded from `pendingBodyCount`
///     (`SyncEngineBackfill.updateBackfillProgressForAccount`), because a banner that
///     can never clear over work the build cannot perform is the worse product
///     outcome. The honesty moved to where the user can act on it — opening the
///     message reports "unable to load". The old reasoning is kept here rather than
///     erased so nobody re-derives it from a silent deletion.
///
/// The idle inputs here come from the REAL queue actors after a REAL quarantine, not
/// from hand-fed booleans, so these tests pin the causal chain
/// (quarantine → queue idle → lock released) rather than the predicate's arithmetic.
/// The suite is deliberately TWO-SIDED: a broken predicate that ALWAYS released would
/// satisfy the release cases alone, so every release case has a held counterpart driven
/// off a queue that still holds admitted work.
/// `.serialized, .processGlobalState`: every `handlePayloadTooLarge` /
/// `clearOversizedDeferred` below dispatches a DURABLE write off the actor, and that
/// write targets the process-global `AppDatabase.shared`. Without the trait the sink
/// database is not guaranteed installed (an escaped write can trip `rawPool`'s
/// force-unwrap and kill the whole test process), and without the drain at each test's
/// end the write can land inside a LATER suite's swapped database. Each affected test
/// therefore ends with `awaitDurableWritesForTesting()` on every queue it touched.
@Suite("Fast Sync keep-awake follows runnable queue state, not durable completeness", .serialized, .processGlobalState)
struct FastSyncKeepAwakeTests {

    /// A progress snapshot with an explicit `pendingBodyCount`, hand-built so these
    /// tests exercise the PREDICATE arithmetic directly. The production count that
    /// feeds it now excludes flagged rows — that exclusion is pinned separately in
    /// `OversizedDurableFlagConfinementTests.pendingBodyCountExcludesFlaggedRows`, which
    /// runs the real query shape against a real flagged row. Dates derive from `Date()`;
    /// the address is a placeholder domain.
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

        // Hold `pendingBodyCount` non-zero ON PURPOSE here. Production now excludes the
        // flagged row from that count, so this snapshot no longer describes the oversized
        // case — but the wake lock must be independent of durable completeness for EVERY
        // reason a body can still be pending (a body genuinely mid-fetch elsewhere, a
        // count read that failed closed at 1). Pinning the harder input keeps this test
        // testing the split rather than the banner decision, which is pinned elsewhere.
        let progress = progressWithPendingBodies(1)
        #expect(!progress.isFullyComplete, "the snapshot is deliberately incomplete-by-count")

        // …and the wake lock is nonetheless released, because it no longer asks that
        // question. This exact pairing IS the defect: pre-fix these two lines could not
        // both hold.
        #expect(FastSyncView.keepScreenAwakeWhileWorking(
            accountHeadersDone: [progress.headersDone],
            activeBodyIdle: activeIdle,
            backfillBodyIdle: backfillIdle
        ) == false, "an oversized-only remainder must not pin the screen awake")

        // Durable writes escape the actor — settle them inside this test's scope.
        await active.awaitDurableWritesForTesting()
        await backfill.awaitDurableWritesForTesting()
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

    /// 🚨 THE JOIN BETWEEN THE TWO HALVES, and the whole user-visible point of the change.
    ///
    /// `pendingBodyCountExcludesFlaggedRows` pins `MessageHeader.pendingBodyRequest`, and
    /// `syncCompleteBannerGate` below pins `BackfillProgress.isFullyComplete`'s arithmetic
    /// on hand-built values — but nothing drove the function that CONNECTS them. Re-inlining
    /// the old `filter(…)` chain inside `updateBackfillProgressForAccount` restores the
    /// never-clearing "Sync Complete" banner with both of those tests, and the rest of the
    /// suite, still green. That is exactly the shape `pendingBodyRequest`'s own doc says the
    /// hoist exists to prevent. (Found by audit.)
    ///
    /// Two-sided in one fixture: the same two rows are measured with the flag set and with
    /// it cleared, so an implementation that reported 0 unconditionally — or that never
    /// reached 0 — fails one side or the other.
    @Test("End to end: a quarantined row lets an account reach Sync Complete, and an identical unflagged row does not")
    func quarantinedRowLetsTheAccountReachSyncComplete() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Built through immediately-invoked closures so both land as `let`: a `var`
        // captured by the `@Sendable` write closure below is a concurrency error.
        let account: Account = {
            var a = Account(emailAddress: "oversize@example.com", displayName: "Oversize", provider: .imap)
            a.id = "acc1"
            return a
        }()
        // `backfillComplete` is what makes `headersDone` true, which also keeps this test
        // off the `uidTotal == 0 && !headersDone` branch that would ask a provider for a
        // server total. No provider is registered, and none should be needed.
        let folder: Folder = {
            var f = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            f.backfillComplete = true
            f.lastKnownUidNext = 3
            return f
        }()

        func header(_ messageId: String, complete: Bool, oversized: Bool) -> MessageHeader {
            var h = MessageHeader(
                messageId: messageId, subject: "s",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "recipient@example.com", date: Date(), snippet: "",
                folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            h.headerComplete = true
            h.bodyComplete = complete
            h.bodyMetadataOversized = oversized
            return h
        }
        let flagged = header("1", complete: false, oversized: true)
        let settled = header("2", complete: true, oversized: false)
        try await pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try flagged.insert(db)
            try settled.insert(db)
        }

        let engine = await AccountManager.shared.syncEngine
        await engine.updateBackfillProgressForAccount(account)
        // `_backfillBacking`, not `backfillProgressByAccount`: the published dictionary is
        // throttled to one write per second, so reading it would make this test's result a
        // function of how fast the suite before it ran.
        let complete = await AccountManager.shared._backfillBacking["acc1"]
        #expect(complete?.pendingBodyCount == 0,
                "an unfetchable body must not be counted as work remaining — otherwise this count never reaches 0")
        #expect(complete?.isFullyComplete == true,
                "…and therefore the account reaches Sync Complete. Owner decision 2026-09-01: a banner that never clears is worse product behaviour than rounding an unfetchable message up to done")

        // THE CONTROL. The identical two rows with the flag cleared MUST still be counted,
        // or the first assertion is satisfied by a build that stopped counting anything.
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 0 WHERE id = ?",
                           arguments: [flagged.id])
        }
        await engine.updateBackfillProgressForAccount(account)
        let incomplete = await AccountManager.shared._backfillBacking["acc1"]
        #expect(incomplete?.pendingBodyCount == 1,
                "a bodyless row with no quarantine is ordinary work remaining")
        #expect(incomplete?.isFullyComplete == false,
                "…and the banner must stay up for it")

        await AccountManager.shared.clearBackfillProgress(accountId: "acc1")
    }

    /// The banner's GATE is unchanged — it is still `pendingBodyCount == 0`. What the
    /// owner's 2026-09-01 decision changed is the count that feeds it, one layer down.
    /// Both halves stay pinned here so a future change to the gate itself is visible.
    @Test("The Sync Complete banner is gated on pendingBodyCount reaching 0, in both directions")
    func syncCompleteBannerGate() {
        // Withheld while anything is genuinely pending…
        #expect(!progressWithPendingBodies(1).isFullyComplete)
        // …and reachable once nothing is, so the gate is not simply dead (a gate that
        // never fired would pass the first case alone).
        #expect(progressWithPendingBodies(0).isFullyComplete)
    }
}
