/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    /// One stored epoch may describe a combined primary+retry result only when
    /// every contributing fetch reported the same nonzero value. Any missing or
    /// mixed observation collapses to nil (fail closed; never borrow Folder state).
    nonisolated static func commonObservedUidValidity(_ epochs: [UInt32?]) -> UInt32? {
        guard !epochs.isEmpty,
              epochs.allSatisfy({ epoch in epoch.map { $0 > 0 } == true })
        else { return nil }
        let values = Set(epochs.compactMap { $0 })
        return values.count == 1 ? values.first : nil
    }

    // MARK: - Backfill Window (shared by both workers via header crawl)

    /// Fetch and insert one window of backfill messages in chunks.
    /// Returns the total number of messages inserted (0 = no missing messages in window).
    /// Chunk sizes and delays are driven by the current BackfillProfile (power-aware).
    @discardableResult
    /// Returns (inserted: new messages stored, found: messages server reported in window).
    /// `found > 0 && inserted == 0` means all messages already exist (not an empty window).
    /// `found == 0` means truly no messages in this date range.
    func backfillWindow(
        folder: Folder,
        account: Account,
        since: Date,
        before: Date? = nil
    ) async throws -> (inserted: Int, found: Int) {
        let profile = await getBackfillProfile()
        let chunkSize = profile.backfillChunkSize
        let folderId = folder.id
        var totalInserted = 0
        var totalFound = 0
        var allFTSRecords: [FTSHeaderRecord] = []
        var allCcBccUpdates: [(contentKey: ContentKey, cc: String, bcc: String)] = []

        if account.provider == .imap, let provider = providers[account.id] as? IMAPProvider {
            guard let workQueue = workQueues[account.id] else { return (inserted: 0, found: 0) }
            // Step 1: SEARCH — lightweight UID list
            let allUIDs = try await workQueue.execute(priority: .headerFetch) {
                try await provider.searchBackfillUIDs(
                    folder: folder.path, since: since, before: before
                )
            }
            totalFound = allUIDs.count
            guard !allUIDs.isEmpty else { return (inserted: 0, found: 0) }

            // Step 2: Find missing UIDs via batch IN query (efficient, no per-UID round-trips)
            let missingUIDs: [UInt32] = try await dbPool.read { db in
                let sqlChunkSize = SyncConfig.sqlChunkSize
                var existingIds = Set<String>()
                for start in stride(from: 0, to: allUIDs.count, by: sqlChunkSize) {
                    let end = min(start + sqlChunkSize, allUIDs.count)
                    let chunk = allUIDs[start..<end].map { "\($0)" }
                    let found = try String.fetchSet(db,
                        MessageHeader
                            .select(Column("messageId"))
                            .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                    )
                    existingIds.formUnion(found)
                }
                return allUIDs.filter { !existingIds.contains("\($0)") }
            }
            guard !missingUIDs.isEmpty else { return (inserted: 0, found: totalFound) }
            print("[IMAP Backfill] \(folder.path): \(missingUIDs.count) missing UIDs to fetch [\(profile)]")

            // Step 3: Chunked fetch + insert (FTS deferred to end of window)
            let imapBatchSize = profile.imapFetchBatchSize
            let imapDelay = profile.imapInterBatchDelay
            for start in stride(from: 0, to: missingUIDs.count, by: chunkSize) {
                try Task.checkCancellation()
                let end = min(start + chunkSize, missingUIDs.count)
                let chunk = Array(missingUIDs[start..<end])
                let primaryFetch = try await workQueue.execute(priority: .headerFetch) {
                    try await provider.fetchMessageHeadersWithObservedEpoch(
                        folder: folder.path, uids: chunk, batchSize: imapBatchSize, interBatchDelay: imapDelay
                    )
                }
                var headers = primaryFetch.messages
                var contributingEpochs: [UInt32?] = [primaryFetch.observedEpoch]
                // Retry silently dropped UIDs — IMAP FETCH can return fewer results
                // than requested without an error. One retry catches transient issues.
                if headers.count < chunk.count {
                    let returnedIds = Set(headers.map(\.messageId))
                    let droppedUIDs = chunk.filter { !returnedIds.contains("\($0)") }
                    print("[Backfill-FETCH-GAP] \(folder.path): requested \(chunk.count) UIDs, got \(headers.count). Retrying \(droppedUIDs.count) dropped UIDs: \(droppedUIDs.sorted().prefix(20))")
                    if !droppedUIDs.isEmpty {
                        let retryFetch = try await workQueue.execute(priority: .headerFetch) {
                            try await provider.fetchMessageHeadersWithObservedEpoch(
                                folder: folder.path, uids: droppedUIDs, batchSize: imapBatchSize, interBatchDelay: imapDelay
                            )
                        }
                        let retryHeaders = retryFetch.messages
                        contributingEpochs.append(retryFetch.observedEpoch)
                        if !retryHeaders.isEmpty {
                            print("[Backfill-FETCH-GAP] \(folder.path): retry recovered \(retryHeaders.count)/\(droppedUIDs.count)")
                            headers.append(contentsOf: retryHeaders)
                        } else {
                            print("[Backfill-FETCH-GAP] \(folder.path): retry returned 0 — UIDs may be expunged: \(droppedUIDs.sorted().prefix(20))")
                        }
                    }
                }
                let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox,
                    observedEpoch: Self.commonObservedUidValidity(contributingEpochs)
                )
                totalInserted += inserted
                allFTSRecords.append(contentsOf: ftsRecords)
                allCcBccUpdates.append(contentsOf: ccBccUpdates)
            }

        } else if account.provider == .gmail, let provider = providers[account.id] as? GmailProvider {
            guard let workQueue = workQueues[account.id] else { return (inserted: 0, found: 0) }
            // Step 1: LIST — lightweight message ID list
            let allIds = try await workQueue.execute(priority: .headerFetch) {
                try await provider.listBackfillMessageIds(
                    folder: folder.path, since: since, before: before,
                    pageSize: profile.gmailPageSize, interPageDelay: profile.gmailInterPageDelay
                )
            }
            totalFound = allIds.count
            guard !allIds.isEmpty else { return (inserted: 0, found: 0) }

            // Surface warning if the safety cap was hit
            if allIds.count >= SyncConfig.gmailBackfillIdCap {
                await AccountManager.shared.markBackfillCapReached(account.id)
            }

            // Step 2: Find missing IDs via batch IN query
            let missingIds: [String] = try await dbPool.read { db in
                let sqlChunkSize = SyncConfig.sqlChunkSize
                var existingIds = Set<String>()
                for start in stride(from: 0, to: allIds.count, by: sqlChunkSize) {
                    let end = min(start + sqlChunkSize, allIds.count)
                    let chunk = Array(allIds[start..<end])
                    let found = try String.fetchSet(db,
                        MessageHeader
                            .select(Column("messageId"))
                            .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                    )
                    existingIds.formUnion(found)
                }
                return allIds.filter { !existingIds.contains($0) }
            }
            guard !missingIds.isEmpty else { return (inserted: 0, found: totalFound) }
            print("[Gmail Backfill] \(folder.path): \(missingIds.count) missing IDs to fetch [\(profile)]")

            // Step 3: Chunked fetch + insert (FTS deferred to end of window)
            let gmailBatchSize = profile.gmailFetchBatchSize
            let gmailDelay = profile.gmailInterFetchDelay
            for start in stride(from: 0, to: missingIds.count, by: chunkSize) {
                try Task.checkCancellation()
                let end = min(start + chunkSize, missingIds.count)
                let chunk = Array(missingIds[start..<end])
                let headers = try await workQueue.execute(priority: .headerFetch) {
                    try await provider.fetchMessageHeaders(
                        ids: chunk, batchSize: gmailBatchSize, interBatchDelay: gmailDelay
                    )
                }
                let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox,
                    observedEpoch: nil
                )
                totalInserted += inserted
                allFTSRecords.append(contentsOf: ftsRecords)
                allCcBccUpdates.append(contentsOf: ccBccUpdates)
            }

        } else if account.provider == .outlook, let provider = providers[account.id] as? ExchangeProvider {
            guard let workQueue = workQueues[account.id] else { return (inserted: 0, found: 0) }
            // Step 1: LIST — lightweight message ID list (same pattern as Gmail)
            let allIds = try await workQueue.execute(priority: .headerFetch) {
                try await provider.listBackfillMessageIds(
                    folder: folder.path, since: since, before: before,
                    pageSize: profile.gmailPageSize, interPageDelay: profile.gmailInterPageDelay
                )
            }
            totalFound = allIds.count
            guard !allIds.isEmpty else { return (inserted: 0, found: 0) }

            if allIds.count >= SyncConfig.gmailBackfillIdCap {
                await AccountManager.shared.markBackfillCapReached(account.id)
            }

            // Step 2: Find missing IDs via batch IN query
            let missingIds: [String] = try await dbPool.read { db in
                let sqlChunkSize = SyncConfig.sqlChunkSize
                var existingIds = Set<String>()
                for start in stride(from: 0, to: allIds.count, by: sqlChunkSize) {
                    let end = min(start + sqlChunkSize, allIds.count)
                    let chunk = Array(allIds[start..<end])
                    let found = try String.fetchSet(db,
                        MessageHeader
                            .select(Column("messageId"))
                            .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                    )
                    existingIds.formUnion(found)
                }
                return allIds.filter { !existingIds.contains($0) }
            }
            guard !missingIds.isEmpty else { return (inserted: 0, found: totalFound) }
            print("[Exchange Backfill] \(folder.path): \(missingIds.count) missing IDs to fetch [\(profile)]")

            // Step 3: Chunked fetch + insert
            let batchSize = profile.gmailFetchBatchSize
            let batchDelay = profile.gmailInterFetchDelay
            for start in stride(from: 0, to: missingIds.count, by: chunkSize) {
                try Task.checkCancellation()
                let end = min(start + chunkSize, missingIds.count)
                let chunk = Array(missingIds[start..<end])
                let headers = try await workQueue.execute(priority: .headerFetch) {
                    try await provider.fetchMessageHeaders(
                        ids: chunk, batchSize: batchSize, interBatchDelay: batchDelay
                    )
                }
                let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox,
                    observedEpoch: nil
                )
                totalInserted += inserted
                allFTSRecords.append(contentsOf: ftsRecords)
                allCcBccUpdates.append(contentsOf: ccBccUpdates)
            }

        }

        // Coalesced FTS indexing: one call per window instead of per chunk
        if !allFTSRecords.isEmpty {
            await indexHeadersForFTS(allFTSRecords)
            // Enqueue for body fetch via backward queue
            await BackfillBodyQueue.shared.enqueueItems(
                ftsRecords: allFTSRecords, accountId: folder.accountId,
                folderPath: folder.path, isInInbox: folder.role == .inbox
            )
        }

        // v10 cc/bcc backfill: update FTS for existing messages that got cc/bcc from server
        if !allCcBccUpdates.isEmpty {
            do {
                try await SearchIndex.shared.updateCcBcc(allCcBccUpdates)
                print("[Backfill] Updated cc/bcc in FTS for \(allCcBccUpdates.count) existing messages")
            } catch {
                print("[Backfill] FTS cc/bcc update failed: \(error)")
            }
        }

        return (inserted: totalInserted, found: totalFound)
    }

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
        case landed(
            inserted: Int,
            ftsRecords: [FTSHeaderRecord],
            ccBccFtsUpdates: [(contentKey: ContentKey, cc: String, bcc: String)]
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
    /// UIDVALIDITY exists for those providers) and deep backfill's windows.
    /// `.init(nil)` means "the premise is that the folder is UNSTAMPED", which is
    /// a real and common crawl state (a folder holding rows of unproven epoch,
    /// which `bootstrapCrawledFolderUidValidity` refuses to stamp) and MUST still
    /// be guarded. Round 13 removed self-heal from the unguarded list — see
    /// `SyncEngine.selfHealFolder`.
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
        observedEpoch: UInt32?
    ) async -> SyncEngine.BackfillBatchOutcome {
        let result = await insertBackfillBatchGuardable(
            headers, folderId: folderId, accountId: accountId, folderPath: folderPath,
            folderRole: folderRole, isInInbox: isInInbox, epochPremise: epochPremise,
            observedEpoch: observedEpoch
        )
        guard !result.refused else { return .refused }
        return .landed(
            inserted: result.inserted,
            ftsRecords: result.ftsRecords,
            ccBccFtsUpdates: result.ccBccFtsUpdates
        )
    }

    /// The premise-LESS entry point: the Gmail/Exchange page walk (neither
    /// provider has a UIDVALIDITY concept, so there is no premise to hold and
    /// nothing a guard could compare) and deep backfill's windows.
    ///
    /// It returns no refusal channel because it can produce no refusal: with no
    /// premise the in-transaction CAS below never runs. If a future caller of
    /// THIS overload ever needs guarding, it must move to the premised one above
    /// — which is exactly the coupling blocker 3 asked for, expressed as a
    /// signature rather than as a warning nobody reads.
    func insertBackfillBatch(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool,
        observedEpoch: UInt32?
    ) async -> (inserted: Int, ftsRecords: [FTSHeaderRecord], ccBccFtsUpdates: [(contentKey: ContentKey, cc: String, bcc: String)]) {
        let result = await insertBackfillBatchGuardable(
            headers, folderId: folderId, accountId: accountId, folderPath: folderPath,
            folderRole: folderRole, isInInbox: isInInbox, epochPremise: nil,
            observedEpoch: observedEpoch
        )
        return (result.inserted, result.ftsRecords, result.ccBccFtsUpdates)
    }

    private func insertBackfillBatchGuardable(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool,
        epochPremise: SyncEngine.CrawlEpochPremise?,
        observedEpoch: UInt32?
    ) async -> (inserted: Int, ftsRecords: [FTSHeaderRecord], ccBccFtsUpdates: [(contentKey: ContentKey, cc: String, bcc: String)], refused: Bool) {
        guard !headers.isEmpty else { return (0, [], [], false) }

        let sourceBoundEpoch = observedEpoch.flatMap { epoch in
            epoch > 0 ? Int(exactly: epoch) : nil
        }
        var ftsRecords: [FTSHeaderRecord] = []
        var count = 0
        var unreadInserted = 0
        var discoveredParents: [String] = []
        var ccBccFtsUpdates: [(contentKey: ContentKey, cc: String, bcc: String)] = []
        var anyChunkRefused = false

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
                let result: (inserted: Int, unread: Int, fts: [FTSHeaderRecord], ccBcc: [(contentKey: ContentKey, cc: String, bcc: String)], parents: [String], refused: Bool) =
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
                            return (inserted: 0, unread: 0, fts: [], ccBcc: [], parents: [], refused: true)
                        }
                        // Load pending destructive IDs to skip messages with optimistic moves.
                        // Scoped to (accountId, folderPath) to prevent IMAP cross-folder UID collisions.
                        let scopedOps = try PendingOperation
                            .filter(Column("accountId") == accountId && Column("folderPath") == folderPath)
                            .fetchAll(db)
                        let snapshot = PendingOperationSnapshot(ops: scopedOps)

                        // Existence check — one IN query (chunk <= chunkSize < SQLite's
                        // ~999 bound-variable limit, so no sub-chunking needed).
                        let incomingIds = chunk.map(\.messageId)
                        let existingIds = try String.fetchSet(db,
                            MessageHeader
                                .select(Column("messageId"))
                                .filter(Column("folderId") == folderId && incomingIds.contains(Column("messageId")))
                        )

                        var fts: [FTSHeaderRecord] = []
                        var ccBcc: [(contentKey: ContentKey, cc: String, bcc: String)] = []
                        var inserted = 0
                        var unread = 0

                        let needsCcBccBackfill = !UserDefaults.standard.bool(forKey: "ccBccBackfillDone")
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
                            if existingIds.contains(info.messageId) {
                                // v10 cc/bcc backfill: update existing messages with cc/bcc from server
                                if needsCcBccBackfill && (!info.cc.isEmpty || !info.bcc.isEmpty) {
                                    let headerId = "\(accountId):\(folderPath):\(info.messageId)"
                                    try db.execute(
                                        sql: "UPDATE messageHeader SET cc = ?, bcc = ? WHERE id = ?",
                                        arguments: [info.cc, info.bcc, headerId]
                                    )
                                    // ⚠ STAGE E1: this list feeds `SearchIndex.updateCcBcc`,
                                    // which addresses FTS rows — content-key space. The
                                    // `UPDATE messageHeader … WHERE id = ?` two lines up
                                    // keeps using the plain `headerId` (F2).
                                    ccBcc.append((contentKey: ContentKey(rawValue: headerId),
                                                  cc: info.cc, bcc: info.bcc))
                                }
                                continue
                            }

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
                                isInInbox: isInInbox
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
                                let tagOp = PendingOperation(
                                    type: .setTag,
                                    messageIds: [header.stableId],
                                    accountId: accountId,
                                    folderPath: folderPath,
                                    tagValue: ActionTag.none.rawValue
                                )
                                try tagOp.insert(db)
                                print("[ReplyDetect] Backfill insert: reply→none for \(header.messageId) (already replied)")
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

                        // Sent-folder reply discovery — no-op when folderRole != .sent.
                        let parents = try ReplyParentResolver.markParentsReplied(
                            inReplyTos: chunk.map(\.inReplyTo),
                            folderRole: folderRole,
                            accountId: accountId,
                            db: db
                        )
                        return (inserted, unread, fts, ccBcc, parents, false)
                    }
                if result.refused { anyChunkRefused = true }
                count += result.inserted
                unreadInserted += result.unread
                ftsRecords.append(contentsOf: result.fts)
                ccBccFtsUpdates.append(contentsOf: result.ccBcc)
                discoveredParents.append(contentsOf: result.parents)
            } catch {
                print("[Backfill] Insert chunk failed: \(error)")
            }
        }

        if count > 0 {
            print("[Backfill] +\(count) messages (\(unreadInserted) unread)")
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
        return (count, ftsRecords, ccBccFtsUpdates, anyChunkRefused)
    }

    // MARK: - Deep Backfill (Past Age Limit)

    /// Crawls backward past the age cutoff in date windows, as long as under storage budget.
    /// Uses 30-day windows for IMAP (to avoid NIO 8KB buffer limit on SEARCH responses)
    /// and 90-day windows for Gmail (which uses HTTP pagination).
    func deepBackfillFolder(
        folder: Folder,
        account: Account,
        before: Date,
        deadline: Date? = nil
    ) async throws {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        var windowEnd = utcCal.startOfDay(for: before)
        var windowDays = account.provider == .imap ? 30 : 90

        print("[Backfill] Deep crawl starting for \(folder.name) (before \(before))")

        while !StorageEstimator.isOverBudget() {
            try Task.checkCancellation()
            if let deadline, Date() >= deadline {
                print("[Backfill] Deep crawl deadline reached for \(folder.name)")
                return
            }
            let windowStart = utcCal.date(byAdding: .day, value: -windowDays, to: windowEnd) ?? Date.distantPast
            // 1-day overlap into the previous window to catch messages on the boundary
            // (IMAP SINCE/BEFORE uses date-only semantics). Matches shallow backfill behavior.
            // Dedup in insertBackfillBatch prevents duplicate inserts.
            let searchSince = utcCal.date(byAdding: .day, value: -1, to: windowStart) ?? windowStart

            let result: (inserted: Int, found: Int)
            do {
                result = try await backfillWindow(
                    folder: folder, account: account,
                    since: searchSince, before: windowEnd
                )
            } catch {
                // If IMAP SEARCH response exceeds NIO buffer, halve the window and retry
                let desc = "\(error)"
                if desc.contains("PayloadTooLargeError") {
                    if windowDays > 1 {
                        windowDays = max(1, windowDays / 2)
                        print("[Backfill] Deep crawl window too large for \(folder.name) — shrinking to \(windowDays) days")
                        continue
                    }
                    // Single day still overflows — skip this day and continue deeper.
                    // Better to lose one dense day than abort the entire deep crawl.
                    print("[Backfill] Deep crawl: single day overflow for \(folder.name) at \(windowEnd) — skipping day")
                    windowEnd = windowStart
                    windowDays = account.provider == .imap ? 30 : 90 // reset window size
                    continue
                }
                throw error
            }

            // No more messages on server in this window — folder fully crawled.
            // Use found==0 (not inserted==0) because inserted==0 just means all
            // messages already exist locally (dedup). found==0 means the server has
            // no messages in this date range — truly empty.
            if result.found == 0 {
                print("[Backfill] Deep crawl complete for \(folder.name) — no more messages (found=0)")
                break
            }
            if result.inserted == 0 {
                print("[Backfill] Deep crawl \(folder.name): all \(result.found) found already exist — continuing deeper")
            }

            try await AppDatabase.backgroundPool.write { db in
                _ = try Folder.filter(Column("id") == folder.id)
                    .updateAll(db, Column("oldestSyncedDate").set(to: windowStart))
            }
            print("[Backfill] Deep crawl \(folder.name): window \(windowStart)–\(windowEnd)")

            windowEnd = windowStart

            // Throttle between deep crawl windows (shorter when on power + idle)
            try await Task.sleep(for: .seconds(await getBackfillProfile().deepCrawlInterWindowDelay))
        }

        if StorageEstimator.isOverBudget() {
            print("[Backfill] Deep crawl stopped for \(folder.name) — over storage budget")
        }
    }
}
