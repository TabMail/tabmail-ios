/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    /// What a PREMISED `insertBackfillBatch` did, as a value the caller cannot
    /// half-consume.
    ///
    /// 🚨 **ROUND 13, BLOCKER 3 — THIS TYPE IS THE FIX, AND IT REPLACES A
    /// COMMENT.** The premised insert used to return a 4-tuple whose last member
    /// was a `refused` flag, and of its SIX call sites exactly ONE consumed it
    /// (`git grep -n insertBackfillBatch <pre-fix HEAD> -- '*.swift'`: three in
    /// this file, two in `SyncEngineBackfillWalk`, one in `SyncEngineSelfHeal`;
    /// no test target called it). The other five discarded it with `_`. That was
    /// safe only by accident —
    /// those five pass no premise, so their guard never runs and they can never be
    /// refused — which makes it fail-DANGEROUS coupling: the first person to arm
    /// a premise at one of them without also consuming `refused` silently DROPS
    /// the batch, with no failed range and no retry, violating both *never drop
    /// user intention* and *never mark unfetched content as fetched*. The two
    /// concerns are now welded together by the type system instead: a premise can
    /// only be supplied through the overload that returns THIS enum, and there is
    /// no way to reach `inserted` / `ftsRecords` without having named `.landed`.
    /// The premise-less overload returns a plain 3-tuple — it has no refusal
    /// channel to ignore because it can have no refusal.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`**: there `insertBackfillBatch` is a
    /// single function whose `refused` member is documented as ignorable
    /// ("callers with no per-range completeness concept … can ignore this
    /// field"). The RULE ported from the reference is the caller-side one — *a
    /// refused range is FAILED, never confirmed* — and this type is the v3
    /// mechanism for making that rule unforgettable.
    enum BackfillBatchOutcome: Sendable {
        /// The batch was admitted. `inserted == 0` is ordinary dedup, NOT a
        /// refusal — that distinction is the whole point of the other case.
        /// `allLanded` is false when a chunk's write transaction threw: that
        /// chunk rolled back as a whole, so some of the batch has no row, and
        /// the caller must not move its bookkeeping past them (the UID walk
        /// fails the range, self-heal leaves its pass open). The same report
        /// the premise-less overload gives as `failed`.
        case landed(
            inserted: Int,
            ftsRecords: [FTSHeaderRecord],
            allLanded: Bool
        )
        /// At least one chunk's in-transaction CAS refused: the folder no longer
        /// holds the `lastKnownUidValidity` the caller premised. NOTHING was
        /// written for that chunk, so the caller must treat its work as
        /// OUTSTANDING (fail the range, do not confirm it, do not advance any
        /// completeness accounting) and let a later pass re-derive it.
        case refused
    }

    /// Insert headers into a folder. Returns (insertedCount, ftsRecords) so the caller
    /// can coalesce FTS indexing across multiple batches within a window, plus
    /// whether any chunk was REFUSED on epoch grounds (see `epochPremise`).
    ///
    /// 🚨 `epochPremise` — **the C3 guard, and it must be judged against the
    /// STORED stamp, not against the caller's own walk epoch** (round 12). The
    /// backfill walk's per-chunk `epochStillAgrees()` check compares the
    /// provider's epoch MIRROR against the epoch the WALK started in; it is
    /// structurally blind to the folder's stamp changing after the walk began,
    /// because no term in it reads the folder row at all. So a sibling pass
    /// stamping the folder mid-walk (full sync's STATUS-sourced folder-list
    /// upsert, `runSyncMessages`' SELECT-sourced bootstrap, deletion-reconcile's)
    /// lets this walk's rows land under a stamp describing a DIFFERENT numbering
    /// — and since `AccountManager.newGestureRefusedForUnknownEpoch` tests only
    /// `== nil`, a non-nil wrong stamp ADMITS every bare-UID gesture on them.
    /// Re-reading the row inside THIS transaction is the only place the two can
    /// be compared without a TOCTOU.
    ///
    /// Omitting the argument entirely (the premise-LESS overload) means "this
    /// caller holds no premise; do not guard" — the Gmail/Exchange page walk (no
    /// UIDVALIDITY exists for those providers).
    /// `.init(nil)` means "the premise is that the folder is UNSTAMPED", which is
    /// a real and common crawl state (a folder holding rows of unproven epoch,
    /// which `bootstrapCrawledFolderUidValidity` refuses to stamp) and MUST still
    /// be guarded. Round 13 removed self-heal from the unguarded list (its
    /// successor, the catch-up's load of missing UIDs, inserts premised too:
    /// `SyncEngine.applyCatchUpResult`, #1062).
    ///
    /// ⚠ **A nil premise is NOT a missing folder row**, and
    /// `crawlWalkWriteAllowed` no longer treats them alike: a row that is gone
    /// refuses (round 13 blocker 1). So `.init(nil)` guards the unstamped folder
    /// exactly as before, while a caller whose folder has been deleted out from
    /// under it is refused rather than admitted.
    ///
    /// ⚑ R0 — PORTED from `v2final`'s `insertBackfillBatch(… observedEpoch:)` +
    /// `refused` return, which carries the same in-txn guard through
    /// `uidValidityWriteAllowed(resetPending:observedEpoch:storedEpoch:)` and the
    /// same "a refused range is FAILED, never confirmed" contract on the caller.
    /// TWO deviations: (1) the reference's `uidValidityResetPendingAt` term does
    /// not transfer — v3 had no such column when this was written, and T4.S6, which
    /// added it, deliberately left this guard deciding on the premise alone;
    /// (2) the reference passes a
    /// bare `UInt32?` and lets `nil` mean "no guard", which it can afford BECAUSE
    /// of that flag — v3 cannot, since the unstamped folder is exactly the one
    /// whose premise is nil, hence the wrapper type. Deviation (2) still stands
    /// after T4.S6: the wrapper type is what carries "premise absent" distinctly
    /// from "premise nil", which no quarantine flag supplies.
    ///
    /// The premised entry point. A caller that holds a premise MUST reach the
    /// insert through here, and the `BackfillBatchOutcome` it gets back cannot be
    /// used without naming the refusal case (round 13 blocker 3).
    func insertBackfillBatch(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool,
        epochPremise: SyncEngine.CrawlEpochPremise,
        observedEpoch: UInt32?,
        catchUpReadStartedAt: Date? = nil
    ) async -> SyncEngine.BackfillBatchOutcome {
        let result = await insertBackfillBatchGuardable(
            headers, folderId: folderId, accountId: accountId, folderPath: folderPath,
            folderRole: folderRole, isInInbox: isInInbox, epochPremise: epochPremise,
            observedEpoch: observedEpoch, catchUpReadStartedAt: catchUpReadStartedAt
        )
        guard !result.refused else { return .refused }
        return .landed(
            inserted: result.inserted,
            ftsRecords: result.ftsRecords,
            allLanded: !result.failed
        )
    }

    /// The premise-LESS entry point: the Gmail/Exchange page walk (neither
    /// provider has a UIDVALIDITY concept, so there is no premise to hold and
    /// nothing a guard could compare).
    ///
    /// It returns no refusal channel because it can produce no refusal: with no
    /// premise the in-transaction CAS below never runs. If a future caller of
    /// THIS overload ever needs guarding, it must move to the premised one above
    /// — which is exactly the coupling blocker 3 asked for, expressed as a
    /// signature rather than as a warning nobody reads.
    ///
    /// `failed` is true when a chunk's write transaction threw: its rows did
    /// not land (it rolled back as a whole). A caller must not move its
    /// bookkeeping past them.
    ///
    /// `catchUpReadStartedAt` is set only by the catch-up's direct load
    /// (`SyncEngine.applyCatchUpResult`): when the read that listed `headers`
    /// began, on `CatchUpWallClock`. Each chunk then skips a message the user's
    /// own action stands on (`catchUpReadPredatesAction`), and inserts nothing
    /// for a read as old as the completion log's retention
    /// (`catchUpReadIsOverAge`). A skipped message is not a failure and marks
    /// nothing: the folder still lacks it, so the next listing finds it missing
    /// again if the server still lists it there.
    func insertBackfillBatch(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool,
        observedEpoch: UInt32?,
        catchUpReadStartedAt: Date? = nil
    ) async -> (inserted: Int, ftsRecords: [FTSHeaderRecord], failed: Bool) {
        let result = await insertBackfillBatchGuardable(
            headers, folderId: folderId, accountId: accountId, folderPath: folderPath,
            folderRole: folderRole, isInInbox: isInInbox, epochPremise: nil,
            observedEpoch: observedEpoch, catchUpReadStartedAt: catchUpReadStartedAt
        )
        return (result.inserted, result.ftsRecords, result.failed)
    }

    private func insertBackfillBatchGuardable(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool,
        epochPremise: SyncEngine.CrawlEpochPremise?,
        observedEpoch: UInt32?,
        catchUpReadStartedAt: Date?
    ) async -> (inserted: Int, ftsRecords: [FTSHeaderRecord], refused: Bool, failed: Bool) {
        guard !headers.isEmpty else { return (0, [], false, false) }

        let sourceBoundEpoch = observedEpoch.flatMap { epoch in
            epoch > 0 ? Int(exactly: epoch) : nil
        }
        var ftsRecords: [FTSHeaderRecord] = []
        var count = 0
        var unreadInserted = 0
        var discoveredParents: [String] = []
        var anyChunkRefused = false
        var anyChunkFailed = false

        // CHUNKED async insert: split the batch into transactions of
        // SyncConfig.backfillInsertChunkSize rows so each holds the single GRDB
        // writer only briefly, and route each via backgroundPool so it yields to
        // foreground/UI between chunks. The pending-op snapshot + existence check
        // stay INSIDE each chunk's write txn (TOCTOU rule: a user action mustn't
        // slip a PendingOperation between a separate read and the insert). The write
        // closure RETURNS its accumulated values (no capture-mutate — required for
        // the @Sendable async write).
        let chunkSize = SyncConfig.backfillInsertChunkSize
        for start in stride(from: 0, to: headers.count, by: chunkSize) {
            let end = min(start + chunkSize, headers.count)
            let chunk = Array(headers[start..<end])
            do {
                let result: (inserted: Int, unread: Int, fts: [FTSHeaderRecord], parents: [String], refused: Bool) =
                    try await AppDatabase.backgroundPool.write { db in
                        // THE C3 GUARD — re-read the folder row INSIDE this txn and
                        // compare it against the caller's premise. A chunk refused
                        // here is simply re-fetched by a later pass; a chunk
                        // inserted under a stamp it does not belong to is silent
                        // data corruption that only surfaces as a gesture landing
                        // on the wrong message. See `epochPremise` above.
                        if let epochPremise,
                           try !SyncEngine.crawlWalkWriteAllowed(
                               db, folderId: folderId, premiseEpoch: epochPremise.epoch) {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folderId): skipping insert chunk — the folder no longer holds the UIDVALIDITY this pass premised")
                            }
                            return (inserted: 0, unread: 0, fts: [], parents: [], refused: true)
                        }
                        // Load pending destructive IDs to skip messages with optimistic moves.
                        // Scoped to (accountId, folderPath) to prevent IMAP cross-folder UID collisions.
                        let scopedOps = try PendingOperation
                            .filter(Column("accountId") == accountId && Column("folderPath") == folderPath)
                            .fetchAll(db)
                        let snapshot = PendingOperationSnapshot(ops: scopedOps)
                        // The catch-up's direct load only: a user action that
                        // completed after the read that listed these messages
                        // began is newer than that listing. A message the user
                        // moved out of this folder meanwhile must not come back
                        // under its old id (#106's ghost). Both shields are read
                        // HERE, inside the chunk's transaction, never before it
                        // (Memory 127).
                        let catchUpShield = catchUpReadStartedAt.map { readStartedAt in
                            (readStartedAt: readStartedAt,
                             recentlyCompleted: AccountManager.shared.liveRecentlyCompleted(),
                             overAge: SyncEngine.catchUpReadIsOverAge(readStartedAt: readStartedAt, now: CatchUpWallClock.now()))
                        }

                        // Existence check: the same predicate the IMAP UID walk
                        // uses to drop stored UIDs before its FETCH.
                        let existingIds = try MessageHeader.existingMessageIds(
                            db, folderId: folderId, among: chunk.map(\.messageId))

                        var fts: [FTSHeaderRecord] = []
                        // The inserted rows' In-Reply-To and Message-ID, for
                        // reply discovery in both directions after the loop.
                        var insertedInReplyTos: [String?] = []
                        var insertedRfc822Ids: [String] = []
                        var inserted = 0
                        var unread = 0
                        // Ids this chunk has inserted. `existingIds` was read
                        // before the loop, so a second entry for the same id in
                        // `chunk` would hit the primary key and roll back the
                        // whole chunk, neighbours included. Every caller hands
                        // this function one id space at a time (a Gmail or Graph
                        // id, or a UID under the one epoch the call carries), so
                        // a repeated id is the same message: it is skipped.
                        var insertedIds = Set<String>()

                        for info in chunk {
                            // IOS-IMAP-001 / D3 — a message the server reports with
                            // `\Deleted` is NOT PRESENT for display (RFC 3501 §2.3.2:
                            // "deleted for removal by later EXPUNGE"). The merge already
                            // enforces that at its two consumers — `selectStaleHeaders`
                            // subtracts it from `remoteIds`, and `runSyncMessages` adds
                            // it to the upsert loop's skip set — but this crawl
                            // materialises a `MessageHeader` from the SAME
                            // `MessageHeaderInfo`s and never read the flag. On a server
                            // without UIDPLUS a completed move leaves the source copy
                            // soft-deleted (the purge stays gated on `COPYUID`), the
                            // merge removes the local row, and a later backfill window
                            // or self-heal pass covering that UID then put it back as an
                            // ordinary visible row.
                            //
                            // NOT INSERTING is the same end state the merge reaches — no
                            // local row — so the two paths agree. Nothing is queued here,
                            // so no user intention is involved and never-drop is not
                            // engaged; and this is insert-prevention only, so an existing
                            // row is left for the merge's stale channel to remove (a
                            // crawl must never delete as a side effect).
                            if info.isDeletedOnServer { continue }
                            if snapshot.destructive.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId) { continue }
                            // A stored row is never read from its FETCH: the
                            // UID walk does not FETCH it at all, and
                            // `InsertBackfillBatchTests.existingRowsAreInert`
                            // keeps the two in step.
                            if existingIds.contains(info.messageId) { continue }
                            if let catchUpShield {
                                if catchUpShield.overAge { continue }
                                if SyncEngine.catchUpReadPredatesAction(
                                    accountId: accountId, messageId: info.messageId,
                                    rfc822MessageId: info.rfc822MessageId,
                                    readStartedAt: catchUpShield.readStartedAt,
                                    recentlyCompleted: catchUpShield.recentlyCompleted) { continue }
                            }
                            guard insertedIds.insert(info.messageId).inserted else { continue }

                            var header = MessageHeader(
                                messageId: info.messageId,
                                subject: info.subject,
                                from: info.from,
                                fromAddress: info.fromAddress,
                                to: info.to,
                                date: info.date,
                                snippet: EmailFilter.cleanSnippet(info.snippet),
                                folderId: folderId,
                                accountId: accountId,
                                folderPath: folderPath,
                                isInInbox: isInInbox,
                                providerDate: info.providerOrderDate
                            )
                            header.rfc822MessageId = info.rfc822MessageId
                            header.observedUidValidity = sourceBoundEpoch
                            header.inReplyTo = info.inReplyTo
                            header.referencesJSON = MessageHeader.encodeReferences(info.references)
                            header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: accountId, subject: header.subject)
                            try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: info.threadId, db: db)
                            header.replyTo = info.replyTo
                            header.cc = info.cc
                            header.bcc = info.bcc
                            header.isRead = info.isRead
                            header.isFlagged = info.isFlagged
                            header.hasAttachments = info.hasAttachments
                            header.isReplied = info.isReplied
                            header.isForwarded = info.isForwarded
                            header.actionTag = info.actionTag
                            header.tagSortOrder = info.actionTag?.sortOrder ?? 99
                            try MessageAICache.restoreIfCached(
                                into: &header,
                                accountId: accountId,
                                folderPath: folderPath,
                                db: db
                            )
                            // ReplyDetect: if message is already replied and tagged as "reply", override to "none"
                            // AI cache keeps original LLM value — only MessageHeader + IMAP tag change
                            if header.isReplied && header.actionTag == .reply {
                                header.actionTag = ActionTag.none
                                header.tagSortOrder = ActionTag.none.sortOrder
                                var tagOp = PendingOperation(
                                    type: .setTag,
                                    messageIds: [header.stableId],
                                    accountId: accountId,
                                    folderPath: folderPath,
                                    tagValue: ActionTag.none.rawValue
                                )
                                try tagOp.insert(db)
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[ReplyDetect] Backfill insert: reply→none for \(header.messageId) (already replied)")
                                }
                            }
                            try header.insert(db)
                            try ThreadUtils.insertMessageReferences(for: header, db: db)

                            // Insert user label associations (Gmail labels / IMAP keywords)
                            for labelId in info.userLabelIds {
                                // Auto-create UserLabel if it doesn't exist (IMAP keywords, or Gmail labels
                                // already synced via fetchFolders). INSERT OR IGNORE for idempotency.
                                let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
                                try labelRow.insert(db, onConflict: .ignore)
                                // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                                // the bare provider value (D10 / `IOS-LABEL-001`).
                                try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
                                    .insert(db, onConflict: .ignore)
                            }

                            inserted += 1
                            if !info.isRead { unread += 1 }
                            insertedInReplyTos.append(info.inReplyTo)
                            if let rfc822 = header.rfc822MessageId { insertedRfc822Ids.append(rfc822) }

                            fts.append(FTSHeaderRecord(
                                contentKey: ContentKey(rawValue: header.id),
                                headerId: header.id,
                                messageId: header.messageId,
                                subject: header.subject,
                                from: "\(header.from) <\(header.fromAddress)>",
                                to: header.to,
                                cc: header.cc,
                                bcc: header.bcc,
                                dateMs: Int64(header.date.timeIntervalSince1970 * 1000),
                                folderId: header.folderId
                            ))
                        }

                        // Sent-folder reply discovery over the rows this chunk
                        // inserted (a stored reply marked its parent when it was
                        // inserted) — no-op when folderRole != .sent.
                        var parents = try ReplyParentResolver.markParentsReplied(
                            inReplyTos: insertedInReplyTos,
                            folderRole: folderRole,
                            accountId: accountId,
                            db: db
                        )
                        // The other direction: a parent inserted after its
                        // reply was stored in Sent.
                        parents += try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                            insertedRfc822Ids: insertedRfc822Ids, accountId: accountId, db: db)
                        return (inserted, unread, fts, parents, false)
                    }
                if result.refused { anyChunkRefused = true }
                count += result.inserted
                unreadInserted += result.unread
                ftsRecords.append(contentsOf: result.fts)
                discoveredParents.append(contentsOf: result.parents)
            } catch {
                anyChunkFailed = true
                BackgroundSyncLogger.logDebug("[Backfill] Insert chunk failed: \(error)")
            }
        }

        if count > 0 {
            BackgroundSyncLogger.logDebug("[Backfill] +\(count) messages (\(unreadInserted) unread)")
            if unreadInserted > 0 {
                let fid = folderId
                Task {
                    await UnreadCountManager.shared.requestRecount(folderId: fid, notifyImmediately: true)
                }
            } else {
                NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            }
        }
        ReplyParentResolver.postParentNotifications(discoveredParents)
        return (count, ftsRecords, anyChunkRefused, anyChunkFailed)
    }
}
