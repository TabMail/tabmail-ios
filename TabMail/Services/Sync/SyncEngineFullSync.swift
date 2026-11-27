/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

extension SyncEngine {

    /// Render one segment of the debug-gated `fullSync upsert` diagnostic:
    /// `"<verb> N header(s): a,b,c (+K more)"`. `verb` is `"inserted"` for the
    /// rows a pass INSERTED and `"reclaimed"` for the existing rows it re-homed
    /// into the folder in place (the orphan-reclaim arm); both segments use the
    /// same cap and overflow arithmetic, so a reader compares like with like.
    ///
    /// Extracted as a PURE, `nonisolated static` function because the diagnostic
    /// it renders
    /// is built inside a `dbPool.write` closure (and emitted only after that
    /// write commits) behind a runtime debug gate, so inline it can only be
    /// executed by a test that also unlocks that gate, and its OVERFLOW branch
    /// needs more inserted headers than any sync fixture produces. Split out,
    /// both branches are directly unit-testable and the call site is one
    /// expression per segment.
    ///
    /// ⚠️ The cap is a DISPLAY cap on synthetic header IDS and nothing else. It
    /// bounds no fetch, no batch and nothing written to the database: every
    /// inserted row is still inserted, and the elided count is STATED rather than
    /// dropped, so the line never claims to be exhaustive when it is not. Global
    /// `CLAUDE.md` rule 11 names exactly this shape as not being data truncation.
    nonisolated static func upsertInsertedIdSummary(_ ids: [String], verb: String = "inserted") -> String {
        let cap = SyncConfig.upsertInsertedIdLogCap
        let elided = ids.count - cap
        let overflow = elided > 0 ? " (+\(elided) more)" : ""
        return "\(verb) \(ids.count) header(s): "
            + ids.prefix(cap).joined(separator: ",")
            + overflow
    }

    /// The one optimistic-placeholder dedup statement shared by full sync,
    /// Gmail delta sync, and Exchange delta sync. Named so plan and consumer
    /// coverage execute the same SQL as production.
    nonisolated static let optimisticDedupSQL = """
        SELECT * FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
        WHERE folderId = ? AND rfc822MessageId = ? AND messageId <> ?
        ORDER BY id ASC
        LIMIT 1
        """

    // MARK: - Full-sync MODSEQ fetch-skip (Fix B task 4)

    /// Per-folder counter of full syncs since the last deep pass. Forces a DEEP
    /// (never-skip) pass every `SyncConfig.fullSyncDeepEveryN` so a buggy / quirky server
    /// HIGHESTMODSEQ can't permanently strand a folder — the ADR-IOS-009 self-healing net.
    /// In-memory: resets on launch (a MODSEQ-equal skip is provably safe anyway — modseq
    /// is monotonic within a UIDVALIDITY epoch, so equal means nothing changed).
    private static let fullSyncSkipStreak = Mutex<[String: Int]>([:])

    /// Is THIS full sync of `folderId` a deep (never-skip) pass? Deep every Nth; a deep
    /// pass resets the streak. Called once per candidate folder per full sync.
    nonisolated static func fullSyncIsDeepPass(folderId: String, everyN: Int) -> Bool {
        fullSyncSkipStreak.withLock { streak in
            let n = (streak[folderId] ?? 0) + 1
            if n >= max(1, everyN) { streak[folderId] = 0; return true }
            streak[folderId] = n
            return false
        }
    }

    #if DEBUG
    /// The folder's count of full syncs since its last deep pass, read without
    /// counting one (`fullSyncIsDeepPass` counts one). Nil: none counted.
    nonisolated static func fullSyncSkipStreakForTesting(folderId: String) -> Int? {
        fullSyncSkipStreak.withLock { $0[folderId] }
    }

    /// Sets the folder's count back (nil removes it), for a test that ends.
    nonisolated static func setFullSyncSkipStreakForTesting(folderId: String, _ value: Int?) {
        fullSyncSkipStreak.withLock { $0[folderId] = value }
    }
    #endif

    /// Full-sync fetch-skip decision. Skip re-fetching a folder ONLY when CONDSTORE proves
    /// nothing changed since our last sync: HIGHESTMODSEQ is present on BOTH sides and
    /// equal. NEVER skip the inbox (always fully synced), a deep pass, or a folder
    /// with no stored MODSEQ (a non-CONDSTORE server, or a listing that proved none).
    /// MODSEQ gates only the listing (never a delete); a skipped folder gets no
    /// deletion reconcile that pass. Pure + nonisolated for unit testing.
    ///
    /// The folder-list STATUS is a trigger only. A STATUS MESSAGES or UIDNEXT that
    /// differs from the counters the folder's last listing stored, or a stored
    /// UIDNEXT of none (no listing has written them), blocks the skip: on a
    /// CONDSTORE server without QRESYNC an expunge may leave HIGHESTMODSEQ
    /// unchanged (RFC 7162), and only the listing that runs then can feed the
    /// deletion check its count.
    nonisolated static func shouldSkipFolderFetch(
        role: FolderRole, freshModSeq: Int?, cachedModSeq: Int?, isDeepSync: Bool,
        freshCount: Int?, freshUidNext: Int?, listedCount: Int, listedUidNext: Int?, listingDue: Bool = false
    ) -> Bool {
        guard role != .inbox, !isDeepSync, !listingDue else { return false }
        // A count the server left out of STATUS is unknown, never 0 (#755).
        guard let freshCount else { return false }
        guard let freshModSeq = knownModSeq(freshModSeq), let cachedModSeq = knownModSeq(cachedModSeq),
              freshModSeq == cachedModSeq else { return false }
        guard let listedUidNext, let freshUidNext, freshUidNext == listedUidNext else { return false }
        return freshCount == listedCount
    }

    // MARK: - Full Sync

    /// What one full sync is told by the change read that ran before it in the
    /// same pass (ADR-IOS-111).
    struct FullSyncPlan: Sendable {
        /// The pass's own deadline: the count check (phase 2) after each listing
        /// stops there and leaves the folder's listing due.
        var deadline: Date?

        init(deadline: Date? = nil) {
            self.deadline = deadline
        }
    }

    /// What one full sync's window listings did.
    struct FullSyncListing: Sendable {
        /// The folders whose window listing finished in this pass.
        var listedFolderIds: Set<String> = []
        /// Each listed folder's count as its own listing's selection reported it,
        /// absent when that listing proved none: the one input to phase 2.
        var listedCounts: [String: Int] = [:]
        /// A started listing failed to prove its window: a lost connection (that
        /// folder and every later one), a retry that failed otherwise, a short or
        /// empty FETCH under a counted selection, or an empty count the server
        /// did not confirm (`ProviderListingUnconfirmed`). The account's
        /// full-sync stamp is withheld, so the full sync stays due (#755).
        var droppedFolder = false
        /// Folders this pass's server answer made not listable: SELECT refused,
        /// or SELECT with no usable EXISTS. Not listed and not tracked, but they
        /// do not withhold the stamp: their counters stay unwritten, so the
        /// change pass's STATUS lists them again (#755).
        var notListableFolderIds: Set<String> = []
    }

    /// Apply the provider's folder list: upsert names and roles, bootstrap epochs,
    /// insert new folders, remove vanished ones, and (a provider with a label
    /// catalog in its folder list) sync the user-label rows. Runs inside one write
    /// transaction. It writes no folder counters (count, UIDNEXT, MODSEQ): their
    /// one writer is the folder's own listing (`writeListingCounters`).
    ///
    /// Folders whose CONDSTORE HIGHESTMODSEQ, STATUS MESSAGES and UIDNEXT all equal
    /// what their last listing stored are skippable: RFC 7162 guarantees nothing
    /// changed, so the per-folder listing below is skipped. Any difference, or a
    /// stored value missing, lists the folder. NEVER includes the inbox or a deep
    /// pass (see shouldSkipFolderFetch). A skipped folder gets no deletion
    /// reconcile this pass: that runs only on a count this pass's listing proved.
    ///
    /// - Returns: the paths whose fetch the full sync may skip (MODSEQ-unchanged).
    nonisolated static func applyFolderList(_ remoteFolders: [FolderInfo], account: Account, db: Database) throws -> Set<String> {
        var skippable: Set<String> = []
        let localFolders = try Folder.filter(Column("accountId") == account.id).fetchAll(db)

        for info in remoteFolders {
            if var existing = localFolders.first(where: { $0.path == info.path }) {
                // Written back column by column (`updateChanges`): a whole-record
                // update names the backfill walk's columns, which fires
                // `folder_bumpBackfillVersion` and fails a page walk's compare-and-set,
                // and this runs on every change read with a folder list (ADR-IOS-111).
                let original = existing
                // Unconditional — it advances the per-folder deep-pass streak counter.
                let deep = Self.fullSyncIsDeepPass(
                    folderId: existing.id, everyN: SyncConfig.fullSyncDeepEveryN)
                // NOTE (T1.2): an epoch-aware term was tried here and REMOVED. Making a
                // UIDVALIDITY turnover block this skip forces the folder down
                // `runSyncMessages`, whose windowed stale sweep has NO epoch guard — so
                // "more fetching" is NOT the conservative direction here: it converts a
                // skipped folder into a swept one and DELETES the old-epoch mail that
                // HEAD leaves alone. The sweep needs the guard first (see
                // `runSyncMessages`); until then this gate stays exactly as it was.
                if Self.shouldSkipFolderFetch(
                    role: existing.role, freshModSeq: info.highestModSeq,
                    cachedModSeq: existing.lastKnownHighestModSeq, isDeepSync: deep,
                    freshCount: info.messageCountReported ? info.totalCount : nil, freshUidNext: info.uidNext,
                    listedCount: existing.totalCount, listedUidNext: existing.lastKnownUidNext,
                    listingDue: FolderChangeState(raw: existing.changeState).listingDue) {
                    skippable.insert(info.path)
                }
                // The folder list's counts are a trigger only: the folder's
                // counters are written by its listing (ADR-IOS-051 amendment).
                existing.name = info.name
                // BOOTSTRAP the epoch for a folder the deletion-reconcile walk has
                // never visited (it was previously the only writer) — and ONLY
                // bootstrap. `uidValidityBootstrapWrite` writes nothing once the column
                // holds a value, so a nil/0 observation cannot erase it and a turnover
                // cannot overwrite it (which would disarm the walk's abort guard —
                // ADR-IOS-051; see the helper's doc comment). `localFolders` is read
                // inside THIS write transaction, so `existing` is not a stale snapshot.
                //
                // T4.S6b — the header-existence term. This site is the FIRST stamper on
                // an upgrade for a UIDPLUS server: it runs before any per-folder SELECT,
                // so gating only `runSyncMessages` would leave it stamping every folder
                // by assertion. It cannot route through `bootstrapFolderUidValidity`
                // (which carries the term in its statement) because it sets the field on
                // a record it is already updating, so it discharges the same term in
                // Swift — sound HERE and only here, because the count is read inside
                // THIS write transaction with no suspension before the `update`.
                // `isEmpty` compiles to `SELECT EXISTS(SELECT … LIMIT 1)`, which
                // stops at the first index entry. `fetchCount` walks every entry
                // for a folder — pure waste for a question that is answered by
                // one row, inside the single GRDB writer. Same shape as the
                // `NOT EXISTS (SELECT 1 FROM messageHeader WHERE folderId = …)`
                // term already inside `bootstrapFolderUidValidity`'s statement;
                // this site must stay in Swift (see the note above), so it ports
                // the predicate's SHAPE rather than its location.
                let existingHoldsRows = try !MessageHeader
                    .filter(Column("folderId") == existing.id).isEmpty(db)
                if let bootstrap = Self.uidValidityBootstrapWrite(
                    observed: info.uidValidity, stored: existing.lastKnownUidValidity,
                    folderHoldsRows: existingHoldsRows) {
                    existing.lastKnownUidValidity = bootstrap
                }
                _ = try existing.updateChanges(db, from: original)
            } else {
                // No counters: the folder's first listing writes them (and the
                // catch-up's first listing stamps itself with that HIGHESTMODSEQ,
                // ADR-IOS-107).
                var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: account.id)
                // A brand-new row is by definition a first observation — the same
                // bootstrap rule, which here also filters the `0` = "not reported"
                // sentinel out of the column.
                //
                // ⚠ T4.S6b — "a new row is by definition an empty folder" is FALSE, and
                // that is residual path (b) in `UidValidityTurnoverDeletionGuardTests`:
                // `Folder.id` is the deterministic `"\(accountId):\(path)"` and the
                // vanished-folder cleanup below deletes the ROW while migration `v2`
                // leaves its headers orphaned, so a re-created path RE-ADOPTS old-epoch
                // rows the instant this insert lands. The term is therefore required on
                // BOTH arms.
                // Existence test, not a count — see the sibling arm above.
                let recreatedHoldsRows = try !MessageHeader
                    .filter(Column("folderId") == folder.id).isEmpty(db)
                folder.lastKnownUidValidity = Self.uidValidityBootstrapWrite(
                    observed: info.uidValidity, stored: nil,
                    folderHoldsRows: recreatedHoldsRows)
                try folder.insert(db)
            }
        }

        // Remove local folders that no longer exist remotely
        let remotePaths = Set(remoteFolders.map(\.path))
        for folder in localFolders where !remotePaths.contains(folder.path) {
            // NOTE: this used to say "CASCADE handles messageHeader deletion
            // automatically". That is FALSE — migration `v2_dropMessageHeaderFolderFK`
            // made `messageHeader.folderId` a plain column with NO foreign key to
            // `folder` (only `accountId` cascades). Deleting the folder row therefore
            // leaves its headers ORPHANED: they survive, still pointing at a
            // `folderId`/`folderPath` that now has no metadata. Because `Folder.id` is
            // the deterministic `"\(accountId):\(path)"`, a later re-appearance of the
            // same path re-adopts those orphans under a BRAND-NEW row whose
            // `lastKnownUidValidity` is nil — old-epoch mail under an unknown epoch.
            // See `Folder.lastKnownUidValidity`'s doc comment for why that is an open
            // hazard rather than a benign one.
            try folder.delete(db)
        }

        // Sync user labels from the provider's label catalog in the folder list
        // (`EmailProvider.userLabelCatalog`, #500; Gmail: user labels appear as custom
        // folders). nil = the provider keeps no catalog there: the stored labels stay.
        if let catalog = account.provider.emailProviderType?.userLabelCatalog(from: remoteFolders) {
            let existingLabelIds = try String.fetchSet(db,
                UserLabel.select(Column("id")).filter(Column("accountId") == account.id)
            )
            var seenLabelIds: Set<String> = []

            for entry in catalog {
                let row = UserLabel(
                    accountId: account.id, providerLabelId: entry.providerLabelId,
                    name: entry.name, isSystem: entry.isSystem
                )
                try row.save(db) // upsert
                // 🚨 THE SWEEP BELOW COMPARES DB IDS, SO THIS MUST BE THE DB ID.
                // `existingLabelIds` is read from `userLabel.id`, which is the
                // account-prefixed surrogate (D10 / `IOS-LABEL-001`). Recording the
                // BARE `entry.providerLabelId` here would make `staleLabelIds` the whole existing
                // set on every single sync — i.e. delete every label row this account
                // has, and (via `messageUserLabel`'s `onDelete: .cascade`) every
                // association with it. This is the most dangerous consumer of the
                // surrogate, which is why the row is bound to a local and its own id
                // reused rather than the mint being repeated.
                seenLabelIds.insert(row.id)
            }

            // Remove user labels that no longer exist on server
            let staleLabelIds = existingLabelIds.subtracting(seenLabelIds)
            if !staleLabelIds.isEmpty {
                try UserLabel
                    .filter(staleLabelIds.contains(Column("id")) && Column("accountId") == account.id)
                    .deleteAll(db)
            }
        }
        return skippable
    }


    /// - Parameter plan: what this pass's change read already did
    ///   (ADR-IOS-111). Discovery always runs (`fetchFullSyncFolders`). A folder whose
    ///   change bookmark covers it (`FolderChangeState.tracking`) gets no window
    ///   listing: its changes arrive through the reader.
    /// - Returns: the folders whose window listing finished in this pass, and
    ///   whether a folder it meant to list went unlisted after a failure.
    @discardableResult
    func fullSync(account: Account, provider: any EmailProvider, plan: FullSyncPlan = FullSyncPlan()) async throws -> FullSyncListing {
        let fs0 = CFAbsoluteTimeGetCurrent()
        let acctTag = "\(account.provider):\(account.id.prefix(6))"
        BootProfiler.mark("fullSync[\(acctTag)] START (network — fetch folders + inbox headers → populates inbox)")
        let pool = dbPool
        // The provider's own discovery, every full sync: a provider whose
        // progress total comes from the folder list stores it inside (#755).
        let remoteFolders = try await provider.fetchFullSyncFolders()
        BackgroundSyncLogger.logDebug("[FullSync] \(account.emailAddress) fetchFolders: \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (\(remoteFolders.count) folders)")
        BootProfiler.mark("fullSync[\(acctTag)]: fetchFolders done in \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (\(remoteFolders.count) folders)")
        let skippablePaths = try await pool.write { db in
            try Self.applyFolderList(remoteFolders, account: account, db: db)
        }

        if !skippablePaths.isEmpty {
            BootProfiler.mark("fullSync[\(acctTag)]: skipped \(skippablePaths.count) MODSEQ-unchanged folder(s) — no listing, so no count check either")
        }

        BackgroundSyncLogger.logDebug("[FullSync] \(account.emailAddress) folder upsert: \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms")

        // Fetch fresh folder list after upsert, with whether the account holds a
        // change bookmark in the same read (the tracked skip below needs both).
        let (folders, holdsChangeBookmark) = try await pool.read { db in
            (try Folder.filter(Column("accountId") == account.id).fetchAll(db),
             try Account.fetchOne(db, key: account.id)?.lastHistoryId != nil)
        }

        // Sync messages for the syncable folders (main roles, favourites and
        // followed folders, `SyncEngine.isSyncable`), prioritized: inbox first,
        // then favorites, then secondary roles, then followed folders. A custom
        // folder no user action has landed in syncs on demand when the user
        // navigates to it, which also follows it (#1109).
        let syncableFolders = syncableFoldersInOrder(folders)

        BackgroundSyncLogger.logDebug("[FullSync] \(account.emailAddress) syncing \(syncableFolders.count) folders: \(syncableFolders.map(\.name).joined(separator: ", "))")

        // Heavy per-folder sync — run off main thread.
        // All network + DB operations (provider.fetchMessages, dbPool.read/write) are
        // thread-safe. Running here avoids dozens of MainActor await-resume hops.
        // Helper: process sync result — FTS indexing, ReplyDetect notifications, collect migrated IDs.
        // Extracted to avoid duplication between initial sync and connection-error retry.
        @Sendable func processSyncResult(_ result: SyncMessagesResult, folder: Folder) async -> [String] {
            await Self.publishHeaderRekeys(result.headerRekeys)
            // Recount right after the folder's rows are committed, as the
            // `syncMessages` wrapper does: `runSyncMessages` inserts and removes
            // rows and changes their read state, and does not recount. A change
            // read recounts only when it writes rows, so nothing later in the
            // pass counts a listing's new unread mail.
            await UnreadCountManager.shared.requestRecount(folderId: folder.id)
            // Yield to a privileged merge before this folder's FTS writes (rekey /
            // remove / index). SearchIndex is a separate pool with sync `@noasync`
            // writes, so the async caller yields on its behalf.
            await PriorityGate.shared.yield("sync-fts")
            ReplyParentResolver.postParentNotifications(result.replyDetectIds)
            if !result.ftsRekeys.isEmpty {
                // In-place FTS re-key (UID remap / remnant canonicalization) —
                // preserves the indexed body text + embedding under the new id.
                try? await SearchIndex.shared.rekeyHeaders(result.ftsRekeys.map {
                    (oldKey: ContentKey(rawValue: $0.oldId), newKey: ContentKey(rawValue: $0.newId),
                     newMessageId: $0.newMessageId)
                })
            }
            if !result.staleIds.isEmpty {
                // Routed through `MessageContentStore` (as the non-retry path's
                // `removeHeadersFromFTS` is): the stale headers are already deleted by
                // the sync write above, so the owner count here sees the post-delete
                // world — the ordering the gate depends on. `.body` joins from
                // Stage D, which dropped the FK cascade that used to reclaim it.
                await MessageContentStore.releaseUnowned(
                    result.staleIds.map(ContentKey.init(rawValue:)), stores: [.searchIndex, .body])
            }
            if !result.newHeaders.isEmpty {
                let records = result.newHeaders.map { header in
                    FTSHeaderRecord(
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
                    )
                }
                let inserted = try? await SearchIndex.shared.indexHeaders(records)
                if let inserted, inserted > 0 {
                    BackgroundSyncLogger.logDebug("[FTS] Indexed \(inserted) new messages")
                }
                // Mark headers as fully indexed
                let headerIds = records.map(\.headerId)
                try? await dbPool.write { db in
                    for hid in headerIds {
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                            arguments: [hid]
                        )
                    }
                }
                BackgroundSyncLogger.logDebug("[Sync] \(folder.name): \(result.newHeaders.count) new messages")
                await ActiveBodyQueue.shared.enqueueBatch(result.newHeaders)
            }
            return result.uidMigratedOldIds
        }

        // ADR-IOS-111: a folder the provider's change bookmark covers gets no
        // window listing. Its changes arrive through the change read; read here
        // from the folder row this full sync just loaded. With no bookmark in the
        // row nothing covers a folder, whatever its flag says (a reset that lands
        // while a pass runs can leave a flag behind), so every folder is listed:
        // the pass that does so stores a bookmark and the account never stalls.
        // A per-folder reader (IMAP, Outlook) keeps the bookmark in the folder row
        // (`Folder.changeCursor`), which every reset clears with the account's.
        let trackedFolderIds = Set(syncableFolders.filter {
            FolderChangeState(raw: $0.changeState).tracking && (holdsChangeBookmark || $0.changeCursor != nil)
        }.map(\.id))
        if !trackedFolderIds.isEmpty {
            BackgroundSyncLogger.logDebug("[FullSync] \(account.emailAddress) \(trackedFolderIds.count) tracked folder(s): no window listing")
        }

        let (uidMigratedOldIds, listing): ([String], FullSyncListing) = try await Task.detached {
            var allMigratedIds: [String] = []
            var listing = FullSyncListing()
            // `!skippablePaths.contains` — Fix B task 4: a CONDSTORE-unchanged non-inbox
            // folder is not re-fetched (its HIGHESTMODSEQ proves nothing changed). The
            // reconcile loop below still visits it, so external deletions are never missed.
            for folder in syncableFolders where !folder.path.isEmpty && !skippablePaths.contains(folder.path)
                && !trackedFolderIds.contains(folder.id) {
                // T4.S6 re-drive. A folder left quarantined by an interrupted
                // reaction (crash, transient step failure) is never listed here:
                // an ordinary pass would insert NEW-epoch headers under the OLD
                // stamp, which is precisely the state a bare-UID durable op
                // mutates the wrong message from. It BRANCHES INTO the reaction
                // after this block, in the pass's own task (`quarantinedFolders`
                // below): the reaction's resync lists inside the account's sync
                // turn, which this detached task does not hold (#755).
                if folder.uidValidityResetPendingAt != nil { continue }
                // The `recentlyCompleted` protection set is NOT read here. It is
                // read INSIDE `runSyncMessages`'s write transaction — see the note
                // there and on `AccountManager.liveRecentlyCompleted`.
                let ft0 = CFAbsoluteTimeGetCurrent()
                var outcome = await Self.runListing(for: folder, provider: provider, limit: SyncConfig.syncMessageLimit, dbPool: pool)
                BackgroundSyncLogger.logDebug("[FullSync] \(account.emailAddress) \(folder.name): \(Int((CFAbsoluteTimeGetCurrent() - ft0) * 1000))ms")
                if case .unproven(nil, connectionLost: true, _) = outcome {
                    // Connection died mid-listing: retry this folder once. The pool
                    // self-heals (a dead connection is discarded on checkin). The
                    // retry's own outcome decides the folder; the failed attempt
                    // committed nothing (`runSyncMessages` writes in one
                    // transaction after its server reads).
                    BackgroundSyncLogger.logDebug("[FullSync] Connection lost listing \(folder.name) — retrying")
                    outcome = await Self.runListing(for: folder, provider: provider, limit: SyncConfig.syncMessageLimit, dbPool: pool)
                }
                try Task.checkCancellation()
                if let result = outcome.result {
                    allMigratedIds.append(contentsOf: await processSyncResult(result, folder: folder))
                }
                Self.record(outcome, folderId: folder.id, in: &listing)
                if case .unproven(nil, connectionLost: true, _) = outcome {
                    // The retry lost its connection too: the server is unreachable.
                    BackgroundSyncLogger.logDebug("[FullSync] Retry lost its connection for \(folder.name) — skipping remaining folders")
                    break
                }
                // As before: a listing that reached its merge goes on to anchor the age cutoff.
                guard outcome.result != nil else { continue }

                // Anchor oldestSyncedDate for the age cutoff in backfill.
                // Only set if not already set (backfill or Smart Reindex may have set it).
                // Query the oldest date from ONLY the most recent N messages
                // (matching syncMessageLimit), NOT min(date) across all messages —
                // avoids skipping recent history when old messages already exist.
                if folder.oldestSyncedDate == nil {
                    let oldestDate = try await pool.read { db in
                        try Date.fetchOne(db,
                            MessageHeader
                                // Provider order: this anchor feeds Gmail
                                // `before:` cutoffs, which filter by `internalDate`.
                                .select(Column("providerDate"))
                                .filter(Column("folderId") == folder.id)
                                .order(Column("providerDate").desc)
                                .limit(1, offset: SyncConfig.syncMessageLimit - 1)
                        )
                    }
                    if let oldestDate {
                        try await pool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("oldestSyncedDate").set(to: oldestDate))
                        }
                        BackgroundSyncLogger.logDebug("[FullSync] Anchored oldestSyncedDate for \(folder.name) to \(oldestDate)")
                    }
                }

            }
            return (allMigratedIds, listing)
        }.value

        // T4.S6 re-drive, in the pass's own task (the turn's holder), after the
        // listing so no reaction delays it. The flag means "re-drive me", and
        // only incidentally "skip normal sync until then". Launch/foreground full
        // sync is therefore the re-drive OWNER; `runUidValidityResetReaction`
        // re-enters at the barrier (idempotent) when the flag is already set.
        // The same folders the listing loop skipped for it.
        let quarantinedFolders = syncableFolders.filter {
            !$0.path.isEmpty && !skippablePaths.contains($0.path) && !trackedFolderIds.contains($0.id)
                && $0.uidValidityResetPendingAt != nil
        }
        for folder in quarantinedFolders {
            try Task.checkCancellation()
            await AccountManager.shared.runUidValidityResetReaction(accountId: account.id, folderPath: folder.path)
        }

        // Clear undo protection for migrated UIDs
        // UID migration tracking — logged for diagnostics but no longer clears undoProtectedIds
        // (pending-op check in sync transaction handles undo protection now)
        if !uidMigratedOldIds.isEmpty {
            BackgroundSyncLogger.logDebug("[FullSync] UID migrated \(uidMigratedOldIds.count) messages")
        }
        BootProfiler.mark("fullSync[\(acctTag)] DONE in \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (inbox headers synced)")
        await SyncEngine.checkpointWALThrottled()

        // ADR-IOS-051 Phase 2: evaluate the deletion-reconcile predicate per
        // IMAP folder during full sync too — ghosts below the windowed sync's
        // UID floor are otherwise invisible when delta's STATUS-change gating
        // skips the folder. The server count is the one this pass's own listing
        // of the folder reported (`FullSyncListing.listedCounts`), never the
        // folder list's STATUS: a folder not listed this pass, or whose listing
        // proved no count, gets no phase 2 (a changed STATUS blocks the MODSEQ
        // skip, so a folder whose count moved is listed). The local count is read
        // live AFTER the windowed pass.
        if provider.staleWindowMode == .uid {
            for folder in syncableFolders where !folder.path.isEmpty {
                // T4.S6b — the verified door's SECOND call site, and it is not
                // redundant with the one in `runSyncMessages`. This loop visits EVERY
                // syncable folder, INCLUDING the CONDSTORE-quiet ones the per-folder
                // loop above skipped via `skippablePaths` — a quiet Archive never
                // reaches `runSyncMessages` at all, so without this its epoch would
                // stay unproven indefinitely while this very loop is about to consult
                // it. Running BEFORE the reconcile trigger is what makes the walk's
                // "epoch unverified" refusal a one-cycle over-refusal rather than a
                // standing one. A no-op for every folder the loop above already
                // settled.
                //
                // `provider` (not `imapProvider`) is passed on purpose: the seam is a
                // protocol member, and routing it through a downcast would silently
                // send every non-`IMAPProvider` conformer that models a bound epoch
                // down the do-nothing leg.
                await Self.verifyAndBootstrapPrePopulatedFolderEpoch(
                    folderId: folder.id, folderPath: folder.path, accountId: account.id,
                    provider: provider, dbPool: pool)
                // A tracked folder's removals arrive exactly through the change
                // read (QRESYNC VANISHED, or the CONDSTORE removal check, against
                // held rows): no count walk for
                // it (ADR-IOS-111). An untracked folder's removals come from its
                // listing's own sweep and from the walk below.
                if trackedFolderIds.contains(folder.id) { continue }
                guard let serverCount = listing.listedCounts[folder.id] else { continue }
                await reconcileDeletionsAfterListing(folder: folder, provider: provider, serverCount: serverCount, logPrefix: "[FullSync]", deadline: plan.deadline)
            }
        }

        // ADR-IOS-107: the catch-up of server-side changes to older mail runs in the
        // backfill worker after the folders' walk (`runBackfill` → `runCatchUpRun`),
        // in slices under the one-sync-at-a-time turn, not here (#766). *Superseded:*
        // it ran here, at the end of every full sync, one 2 s budget per pass.

        // Body fetching happens during backfill (startBackfill called after fullSync).
        // Running it inline here would block sync and explode memory for large folders.
        // Unread recount is handled per folder in `processSyncResult`, right after its listing commits.
        return listing
    }

    /// The folders the full sync syncs, the backfill worker's catch-up lists,
    /// and a per-folder change reader reads (`ChangeFolder.isSynced`): main roles,
    /// favourites and followed folders, inbox first, then favourites, then
    /// secondary roles, then followed folders. Any other folder is listed on
    /// demand, and the first user action that lands in it makes it followed
    /// (#1109, `SyncEngine.folderAccessed`).
    nonisolated func syncableFoldersInOrder(_ folders: [Folder]) -> [Folder] {
        let primary = self.primaryRoles
        let secondary = self.secondaryRoles
        return folders.filter(Self.isSyncable).sorted { a, b in
            func priority(_ f: Folder) -> Int {
                if primary.contains(f.role) { return 0 }
                if f.isFavorite { return 1 }
                if secondary.contains(f.role) { return 2 }
                return 3
            }
            return priority(a) < priority(b)
        }
    }

    /// Whether a folder is in the syncable set (`syncableFoldersInOrder`): a main
    /// role, a favourite, or a folder a user action landed in (`Folder.isFollowed`,
    /// #1109). Every other folder's changes are read by an other-folder run
    /// (#1110), and the catch-up checks it after the syncable ones.
    /// *Superseded (#1110):* "These are also the only folders the catch-up checks
    /// (`runCatchUpRun` takes `syncableFolderIds`), so only for them does arming
    /// the catch-up repair anything."
    nonisolated static func isSyncable(_ folder: Folder) -> Bool {
        syncedPrimaryRoles.contains(folder.role) || syncedSecondaryRoles.contains(folder.role)
            || folder.isFavorite || folder.isFollowed
    }

    // MARK: - Message Sync

    /// On-demand listing of a single folder: opening it, after a send, after a
    /// move, step 6 of an epoch rebuild. Publishes `.checking` for the account.
    /// Lists through the one classifier (`listFolder`): the outcome says what
    /// the server proved, and no listing error escapes it (#755). Returns nil
    /// when the folder's armed turnover reaction ran instead, or when the
    /// account was removed or the folder deleted before the sync turn was
    /// acquired (nothing is listed). Throws only
    /// `CancellationError`. `place` is where it waits in the account's turn
    /// line: at the back, except the folder view's listing (opening a folder,
    /// pulling to refresh it: `AccountManager.syncFolders`), which waits ahead
    /// of the catch-up slices already waiting
    /// (`SyncTurnPlace.aheadOfBackgroundChunks`, #1360).
    #if DEBUG
    /// Test harness only: awaited by a standalone listing after its turn-holder
    /// checks and current-folder lookup, before it reads anything else. Nil in
    /// every run but the test that sets it.
    static let standaloneListingAfterLookupTestHook = Mutex<(@Sendable (_ accountId: String) async -> Void)?>(nil)
    #endif

    @discardableResult
    func syncFolderMessages(
        folder: Folder, provider: any EmailProvider, place: SyncTurnPlace = .arrivalOrder
    ) async throws -> ListingOutcome? {
        // T4.S6 re-drive — the THIRD owner, and the ONLY one that reaches a custom
        // folder that is neither a favourite nor followed. `fullSync` (after its
        // listing, in the pass's own task) and `imapDeltaSync` both branch into the
        // reaction for a quarantined folder, but both iterate
        // `syncableFolders` (primary ∪ secondary ∪ favourite ∪ followed, #1109), so a quarantined
        // custom folder previously had NO re-drive at all: `runSyncMessages`'s
        // in-transaction quarantine term correctly SKIPS the merge pass and
        // `isFolderWalkComplete` refuses the crawl, which together left the folder
        // quarantined and unsynced FOREVER — the reaction's own abort legs
        // deliberately leave the flag set precisely because a re-drive is assumed
        // to exist. On-demand navigation is that folder's only door
        // (`AccountManager.syncFolders(_:connecting:)` → here → `runSyncMessages`, whose
        // filter is `!folder.path.isEmpty` and nothing else), so the branch belongs
        // here. Re-read the flag rather than trusting the caller's snapshot — the
        // caller's `Folder` may predate an arm by an arbitrary interval.
        //
        // No recursion through step 6: the reaction releases and resyncs only AFTER
        // step 5 cleared the flag in the same write that stamped the fresh epoch, so
        // the re-read below is nil by then. An abort leg returns before step 6 runs
        // at all, and `runUidValidityResetReaction` is single-flight regardless.
        let quarantined = (try? await dbPool.read { [folderId = folder.id] db in
            try Folder.fetchOne(db, key: folderId)?.uidValidityResetPendingAt != nil
        }) ?? false
        if quarantined {
            await AccountManager.shared.runUidValidityResetReaction(
                accountId: folder.accountId, folderPath: folder.path
            )
            return nil
        }
        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: folder.accountId) }
        // Inside the account's sync turn: no listing commits between a change
        // read and its apply (#755).
        //
        // The post-send and post-drain listings wait for this turn without a
        // work-queue slot, holding a captured provider and folder. An account
        // removed or a folder deleted while they wait must not be listed: the
        // captured IMAP provider would log in again with its retained password.
        // So the turn's holder re-checks the terminal removal fence and the
        // folder's current row, and lists nothing when either is gone.
        let outcome: ListingOutcome? = await oneSyncAtATime(accountId: folder.accountId, place: place) {
            guard !AccountManager.shared.isRuntimeRemoved(folder.accountId) else {
                BackgroundSyncLogger.logDebug("[Sync] \(folder.name): account removed while waiting for the sync turn; listing skipped")
                return nil
            }
            guard let current = try? await dbPool.read({ [folderId = folder.id] db in
                try Folder.fetchOne(db, key: folderId)
            }) else {
                BackgroundSyncLogger.logDebug("[Sync] \(folder.name): folder gone while waiting for the sync turn; listing skipped")
                return nil
            }
            // The checks above cover only up to here: removal or deletion during
            // the awaits that follow is refused by the provider's retirement
            // (no session opens) and by the listing's own folder-row read.
            #if DEBUG
            if let hook = Self.standaloneListingAfterLookupTestHook.withLock({ $0 }) { await hook(folder.accountId) }
            #endif
            return await listFolder(current, provider: provider, limit: SyncConfig.syncMessageLimit)
        }
        try Task.checkCancellation()
        // Unread recount is handled when the listing's result is published.

        // Self-heal runs during periodic background sync, not on pull-to-refresh.
        // Running a 90-day IMAP SEARCH here blocks the UI spinner unnecessarily.
        return outcome
    }

    /// One folder listing through the one classifier (`runListing`), with its
    /// merge result published (unread recount, FTS, body queue).
    /// An unproven listing owes the folder a deep pass. A folder holding the UID
    /// counters an earlier listing returned is also made due
    /// (`FolderChangeState.listingDue`), so the next pass lists it whatever those
    /// counters or STATUS say, until its count check clears it (#755). A folder
    /// whose listings return no counters (a date-window provider's) has no such
    /// counters to skip on and no count check to clear the debt, so it owes none. It counts against a pass's full-sync stamp only for
    /// the pass that ran it (`pass`); an on-demand listing (nil) belongs to no
    /// pass and never withholds a scheduled pass's stamp. `bound`: an
    /// other-folder run's listing (#1110, `ListingRequestBound`).
    func listFolder(
        _ folder: Folder, provider: any EmailProvider, limit: Int, pass: UUID? = nil, bound: ListingRequestBound? = nil
    ) async -> ListingOutcome {
        let outcome = await Self.runListing(for: folder, provider: provider, limit: limit, dbPool: dbPool, bound: bound)
        // The other-folder run's listing (`bound`, #1110) owes nothing when it
        // proves nothing: only a proven listing writes the folder's counters, so
        // they still show it changed and a later run lists it again. The deep
        // pass and the due mark are the passes' (a full sync never lists an
        // other folder, and the run ignores a due mark).
        if case .unproven = outcome, bound == nil {
            if let pass { unprovenListingPasses.insert(pass) }
            Self.oweDeepListing(folderId: folder.id)
            do {
                try await dbPool.write { db in
                    let holdsListedCounters = try Int.fetchOne(
                        db, sql: "SELECT lastKnownUidNext FROM folder WHERE id = ?", arguments: [folder.id]) != nil
                    if holdsListedCounters { try Self.markListingDue(folderId: folder.id, db: db) }
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Listing] \(folder.name): could not mark the folder due: \(error)") }
            }
        }
        if let result = outcome.result { await publishListingResult(result, folder: folder) }
        return outcome
    }

    private func publishListingResult(_ result: SyncMessagesResult, folder: Folder) async {
        if !result.uidMigratedOldIds.isEmpty {
            BackgroundSyncLogger.logDebug("[FullSync] listing — UID migrated \(result.uidMigratedOldIds.count) messages")
        }

        await Self.publishHeaderRekeys(result.headerRekeys)

        // ReplyDetect: notify UI immediately so tag badges update.
        ReplyParentResolver.postParentNotifications(result.replyDetectIds)

        // Recount unread immediately after headers are committed to GRDB —
        // don't wait for FTS indexing and body queue (which can take seconds).
        // Always recount: runSyncMessages may update flags on existing messages
        // (read→unread) without producing newHeaders or staleIds.
        await UnreadCountManager.shared.requestRecount(folderId: folder.id)

        if !result.ftsRekeys.isEmpty {
            // In-place FTS re-key (UID remap / remnant canonicalization) —
            // preserves the indexed body text + embedding under the new id.
            try? await SearchIndex.shared.rekeyHeaders(result.ftsRekeys.map {
                (oldKey: ContentKey(rawValue: $0.oldId), newKey: ContentKey(rawValue: $0.newId),
                 newMessageId: $0.newMessageId)
            })
        }
        if !result.staleIds.isEmpty {
            removeHeadersFromFTS(result.staleIds)
        }
        if !result.newHeaders.isEmpty {
            await indexHeadersForFTS(result.newHeaders)
            BackgroundSyncLogger.logDebug("[Sync] \(folder.name): \(result.newHeaders.count) new messages")
            await ActiveBodyQueue.shared.enqueueBatch(result.newHeaders)
        }
    }

    // MARK: - Background Sync Helpers

    /// Keep active view-local identities coherent with a committed sync re-key.
    /// Once publication reaches MainActor, delivery is synchronous so the model
    /// and view-owned bindings apply the same committed transition before the
    /// publisher returns.
    private static func publishHeaderRekeys(_ records: [HeaderRekeyRecord]) async {
        guard !records.isEmpty else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .messageHeadersRekeyed, object: records)
        }
    }

    /// Result from per-folder message sync. All fields are Sendable for cross-isolation transfer.
    struct SyncMessagesResult: Sendable {
        let newHeaders: [MessageHeader]
        let staleIds: [String]
        let replyDetectIds: [String]
        let uidMigratedOldIds: [String]
        /// Header re-keys (UID remap, remnant canonicalization) — callers must
        /// apply via `SearchIndex.rekeyHeaders` so the FTS rowid (indexed body
        /// text + messages_vec embedding) moves to the new id IN PLACE.
        /// `newMessageId` refreshes the FTS msgId column on UID remaps.
        let ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)]
        /// Exact committed UID-remap mappings for active view-local identities.
        /// This is intentionally narrower than `ftsRekeys`: canonicalization
        /// carriers without a new provider id cannot update a visible snapshot.
        let headerRekeys: [HeaderRekeyRecord]
        /// The counters this listing's own selection reported, written with its
        /// rows; nil when the listing proved nothing or the pass was refused
        /// (quarantine, epoch disagreement). The only input to phase 2.
        let listedCounters: ListingCounters?
        /// The listing proved the folder's window (#755): merged (not refused for
        /// quarantine or an epoch disagreement) from a selection that proved its
        /// coverage. Only such a listing counts as the folder's listing this pass
        /// (`FullSyncListing.listedFolderIds`, the baseline commit, phase 2).
        let proven: Bool
        /// The folder's selection gave no usable count (`FetchCoverage.notListable`):
        /// not listed, and not a listing that fell short.
        let notListable: Bool
    }

    /// Canonicalize the local rows for one remote message in one folder.
    ///
    /// `optimisticMoveToFolder` updates folderId/folderPath but keeps the
    /// original PK ("accountId:<oldPath>:<messageId>"). For providers with
    /// stable message ids (Gmail) the remnant's messageId stays in the remote
    /// set forever, so it never reaches the stale/UID-remap path that re-keys
    /// IMAP rows — the stale PK survives indefinitely, and historical insert
    /// paths could leave BOTH the remnant AND a canonical-PK row for the same
    /// message (observed in the field 2026-06-09 as phantom 2-member
    /// self-threads in Trash; see PROJECT_MEMORY).
    ///
    /// Merges any duplicates into one survivor (preferring the canonical-PK
    /// row, preserving AI fields and the richest cached body) and re-keys the
    /// survivor to the canonical PK. Returns the canonical row (nil when the
    /// message has no local row yet), the header ids of merge-loser rows
    /// deleted along the way (callers must drop them from FTS via staleIds),
    /// and the (oldId, newId) pair when a re-key happened (callers must
    /// re-key the FTS entry IN PLACE via `SearchIndex.rekeyHeaders` — this
    /// preserves the FTS rowid, the indexed body text, and the messages_vec
    /// embedding; the re-keyed old id must NOT ride the staleIds channel).
    ///
    /// `bodyComplete` stays truthful per row: the survivor keeps its OWN flag
    /// (no OR-merge from losers — that would claim an FTS body the survivor's
    /// row doesn't have, the FTS body-loss class). A survivor with
    /// `bodyComplete = 0` re-enters the standard body pipeline naturally.
    ///
    /// `v2final` supplies the merge/delete/re-key control-flow shape, but its
    /// RFC Message-ID discriminator is deliberately SUBTRACTED: RFC equality
    /// does not prove a provider address. For an IMAP row the proof is the
    /// exact canonical `(account, folder, UID)` key plus equality between the
    /// row's T2.5 source observation and the epoch returned beside this pass's
    /// serving FETCH. Stable-id providers need no epoch and retain the existing
    /// canonicalization behavior.
    ///
    /// ⚑ NO REFERENCE — INVENTED: `providerAddressOwnershipProven` is the
    /// minimum provider-native proof absent from v2final after the Header,
    /// Snapshot, ingress/re-key call-site, and SyncEngineFullSync history
    /// census. An optimistic cross-mailbox row cannot satisfy it. Such a row is
    /// left in place with a nil observation stamp. No RFC adoption, no
    /// compatibility shim, and no Folder-current epoch synthesis is performed
    /// here.
    ///
    /// ⚠️ **"Sync may reconcile it later" was the unverified half of that claim
    /// and it is now stated precisely, because it decides whether a refusal
    /// hides a message.** When the refused rows are the ONLY rows at this
    /// address, returning one of them makes the caller take its
    /// `sourceAddressProven` arm, which `continue`s BEFORE the insert — so the
    /// message the server just reported is neither merged nor inserted, and
    /// nothing else re-offers it: `selectStaleHeaders` cannot reach the remnant
    /// (its UID is in `remoteIds` on all three arms) and
    /// `SyncEngine`'s `missingUIDs` is keyed on
    /// (folderId, messageId), so the remnant answers for the UID and the deep
    /// crawl never re-fetches it. `incomingRfc822Identity` is what lets this
    /// function tell "a retained row might BE this message" (keep refusing)
    /// apart from "every retained row provably is NOT" (admit the insert) —
    /// see the refusal path for the gate and its fail directions.
    ///
    /// - Parameter incomingRfc822Identity: the NORMALIZED RFC 822 identity of
    ///   the message this pass is offering (`normalizedRfc822Identity`), or nil
    ///   when the envelope carries none. Used ONLY as a negative discriminator
    ///   in the refusal path; nil is the fail-closed value everywhere.
    nonisolated static func canonicalizeLocalRows(
        accountId: String,
        folderPath: String,
        folderId: String,
        messageId: String,
        isInInbox: Bool,
        windowMode: StaleWindowMode,
        sourceBoundEpoch: Int?,
        incomingRfc822Identity: String?,
        db: Database
    ) throws -> (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?, sourceAddressProven: Bool) {
        let allRows = try MessageHeader
            .filter(Column("messageId") == messageId && Column("folderId") == folderId)
            .fetchAll(db)
        guard !allRows.isEmpty else { return (nil, [], nil, false) }

        let canonicalId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)

        let proofs = allRows.map {
            providerAddressOwnershipProven(
                row: $0, accountId: accountId, folderPath: folderPath,
                folderId: folderId, messageId: messageId,
                canonicalId: canonicalId, windowMode: windowMode,
                sourceBoundEpoch: sourceBoundEpoch)
        }
        var retainedRows = allRows
        for index in retainedRows.indices where !proofs[index] && retainedRows[index].observedUidValidity != nil {
            retainedRows[index].observedUidValidity = nil
            try retainedRows[index].update(db)
        }
        let rows = zip(retainedRows, proofs).compactMap { element in
            element.1 ? element.0 : nil
        }
        guard !rows.isEmpty else {
            // No retained row owns this provider address. The disposition below
            // decides whether the message the server just reported ever becomes
            // visible, so it is gated on POSITIVE evidence of non-identity and
            // never on the mere absence of proof.
            //
            // Admit the caller's ordinary INSERT (return nil) only when:
            //   * the incoming envelope carries an identity, AND
            //   * every retained row carries one and every one of them DIFFERS,
            //     AND
            //   * no retained row already holds the canonical PK.
            // Then no retained row can be this message, and refusing would hide
            // it permanently (see this function's doc comment for why neither
            // healer reaches it).
            //
            // Same direction and same rationale as the R15-F1 identity gate on
            // the pre-sync inbox reclaim in `runSyncMessages`: RFC EQUALITY
            // never proves a provider address — that discriminator stays
            // subtracted — but RFC INEQUALITY does prove two rows are not the
            // same message. Every ambiguous shape keeps the refusal: a nil
            // identity on either side, an equal identity, or an occupied
            // canonical PK. The occupied-PK arm also keeps the insert away from
            // a PK it could not take.
            //
            // The admitted row is not a duplicate of the retained ones and
            // cannot become a wrong-message mutation target: the insert stamps
            // `observedUidValidity = sourceBoundEpoch` while an optimistic
            // remnant's stamp is nil, and `admittedOrdinaryActionTargets`
            // admits a gesture only when `observedUidValidity == liveEpoch`, so
            // the remnant stays exactly as gesture-inert as it was before.
            let admitIncomingAsNewRow: Bool = {
                guard let incoming = incomingRfc822Identity,
                      !retainedRows.contains(where: { $0.id == canonicalId })
                else { return false }
                return retainedRows.allSatisfy { row in
                    guard let stored = normalizedRfc822Identity(row.rfc822MessageId) else { return false }
                    return stored != incoming
                }
            }()
            BackgroundSyncLogger.log("[Sync] canonicalize REFUSED at (folderId=\(folderId), msgId=\(messageId)) — no row proves provider-address ownership; the incoming message is \(admitIncomingAsNewRow ? "ADMITTED as a new row (every retained row provably denotes a different message)" : "NOT admitted (no positive evidence of non-identity)")")
            if admitIncomingAsNewRow { return (nil, [], nil, false) }
            return (retainedRows.first(where: { $0.id == canonicalId }) ?? retainedRows[0], [], nil, false)
        }
        // Fast path — a single row already under the canonical PK is the
        // overwhelmingly common case. Return before ANY extra query so the
        // per-message cost of the upsert loop is identical to the plain
        // fetchOne this replaced (ADR-IOS-029 hot-path discipline).
        if rows.count == 1 && rows[0].id == canonicalId {
            return (rows[0], [], nil, true)
        }

        var survivor = rows.first(where: { $0.id == canonicalId }) ?? rows[0]
        let survivorHadObservedEpoch = survivor.observedUidValidity != nil
        // T2.5/T5.4: duplicate merging and re-keying do not prove that the
        // survivor belongs to this provider address space. T5.11 owns that
        // proof; until then canonicalization always clears source authority.
        survivor.observedUidValidity = nil
        var removedIds: [String] = []

        // Preserve the richest cached body across all rows BEFORE any delete. Each
        // loser's body row is then deleted EXPLICITLY where its header goes: Stage D
        // (`v70_dropMessageBodyHeaderFK`) removed the cascade that used to do it,
        // and leaving them behind would mean one leaked body per merged duplicate.
        // These are value copies, so deleting the rows does not disturb `bestBody`.
        var bestBody: MessageBody?
        for row in rows {
            if let body = try MessageBody.fetchOne(db, key: row.id),
               bestBody == nil || (bestBody?.htmlContent?.isEmpty ?? true) {
                bestBody = body
            }
        }

        // Merge AI/local state from duplicates into the survivor, then drop them.
        for row in rows where row.id != survivor.id {
            if survivor.actionTag == nil, let tag = row.actionTag {
                survivor.actionTag = tag
                survivor.tagSortOrder = row.tagSortOrder
            }
            if survivor.summaryBlurb == nil { survivor.summaryBlurb = row.summaryBlurb }
            if survivor.summaryTodos == nil { survivor.summaryTodos = row.summaryTodos }
            if survivor.reminderDate == nil { survivor.reminderDate = row.reminderDate }
            if survivor.reminderTime == nil { survivor.reminderTime = row.reminderTime }
            if survivor.reminderContent == nil { survivor.reminderContent = row.reminderContent }
            if survivor.cachedReply == nil { survivor.cachedReply = row.cachedReply }
            survivor.isReplied = survivor.isReplied || row.isReplied
            survivor.isForwarded = survivor.isForwarded || row.isForwarded
            survivor.isRead = survivor.isRead || row.isRead
            // Deliberately NOT merging bodyComplete/bodyEmptyConfirmed — the
            // survivor's flags must describe its OWN FTS row, and the losers'
            // FTS rows leave via staleIds.
            try row.delete(db)
            _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: row.id))
            removedIds.append(row.id)
            if DebugModeManager.isLoggingEnabled() {
                print("[Sync] Canonicalize: merged duplicate \(row.id) into \(survivor.id) (msgId=\(messageId))")
            }
        }

        let willRekey = survivor.id != canonicalId
        if willRekey || !removedIds.isEmpty {
            // Normalize folder-derived state while we're writing anyway.
            survivor.isInInbox = isInInbox
        }

        var ftsRekey: (oldId: String, newId: String)?
        if willRekey {
            // Defensive — the canonical PK can be held by a row in ANOTHER
            // folder (a message optimistically moved OUT of this folder keeps
            // its PK). Don't steal it; keep the remnant PK and retry on a
            // later sync once that row has been canonicalized in its own folder.
            guard try MessageHeader.fetchOne(db, key: canonicalId) == nil else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] Canonicalize: SKIPPING re-key \(survivor.id) → \(canonicalId) — id held by another row")
                }
                if !removedIds.isEmpty || survivorHadObservedEpoch { try survivor.update(db) }
                return (survivor, removedIds, nil, true)
            }
            // Re-key the optimistic-move remnant to the canonical PK. (The FK that
            // used to FORBID a PK `UPDATE` here is gone as of Stage D, but converting
            // this leg to an `UPDATE` is deliberately NOT part of that change — it is
            // a behaviour change riding a schema commit.)
            //
            // 🚨 R17-1 — THE CARRIER IS SHARED, NOT HAND-ROLLED. This block used to
            // run its own `delete` → reassign `id` → `insert`, which is a header
            // PRIMARY-KEY change, so it is a member of the class *"every code path
            // that changes a header's primary key"* — and it had the same gap
            // `BackfillBodyQueue.rekeyRemappedHeader` and
            // `DraftStore.migrateExactPlaceholder` had. `survivor.delete(db)` fires
            // `ON DELETE CASCADE` on BOTH surviving children of `messageHeader`, and
            // the re-insert restored NEITHER:
            //   * `messageUserLabel` (`AppDatabase` `v82`'s create, cascade on the
            //     `messageId` FK) — every label the user applied, destroyed with NO
            //     rebuild source. Nothing else in the database knows which labels the
            //     user chose.
            //   * `messageReference` (`AppDatabase` `v27`'s create, cascade on the
            //     `messageHeaderId` FK) — the message's threading edges. The
            //     existing-row merge branch in `runSyncMessages` updates
            //     `referencesJSON` but never calls
            //     `ThreadUtils.insertMessageReferences`, so nothing rebuilt them
            //     either, and the message fell out of its own conversation.
            // `MessageHeaderRekey.apply` is the sibling carrier — the very sequence
            // this file's own UID-remap block runs — which carries the labels and
            // rebuilds the references from the migrated header's own content.
            //
            // ⚠️ THE SURVIVOR ONLY, AND THAT BOUND IS LOAD-BEARING (`MIS-005`). The
            // merge loop ABOVE deletes duplicate LOSERS, and their cascade loss is
            // INTENDED — they are being discarded, not re-addressed. Only the
            // survivor's delete+reinsert is an address change wearing a deletion's
            // clothes. Carrying every loser's children onto the survivor would let
            // distinct duplicates donate unrelated labels to it: misattribution, and
            // strictly worse than the bug this closes.
            //
            // The BODY is deliberately left for the `bestBody` reattachment below
            // rather than carried by `apply`: that reattachment picks the RICHEST
            // body across every merged row, which is strictly more than the
            // survivor's own. Deleting the survivor's body row FIRST leaves `apply`'s
            // carry-forward nothing to find, so the selection below stays the sole
            // body writer and the pre-existing behaviour is preserved exactly.
            let oldId = survivor.id
            _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
            var migrated = survivor
            migrated.id = canonicalId
            migrated.folderPath = folderPath
            guard try MessageHeaderRekey.apply(from: survivor, to: migrated, db: db) else {
                // UNREACHABLE at this revision, and kept as a live arm rather than
                // discarded so a future reordering degrades instead of corrupting.
                // `apply` returns false only when `canonicalId` is already occupied,
                // which the guard above refused inside THIS write transaction, and
                // GRDB serializes writers. `apply` deletes before its own collision
                // return, so `oldId` now names no header at all — it rides
                // `removedIds`, the caller's "this id is gone, drop its FTS entry"
                // channel, and must NOT ride `ftsRekey`, which would file the index
                // under a row that was never inserted.
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] Canonicalize: re-key \(oldId) → \(canonicalId) COLLIDED — old row is gone")
                }
                removedIds.append(oldId)
                return (try MessageHeader.fetchOne(db, key: canonicalId), removedIds, nil, true)
            }
            // A reply or forward still in the Outbox names its original by header
            // id (#1479), and its completion and an unsent removal's revert read
            // the original by that key. This re-key is proven by the provider's
            // own id (the row owns the address this listing reported,
            // `providerAddressOwnershipProven`), never by Message-ID evidence, so
            // the send follows its original here, in this write, as it does
            // through a landed move (`MessageHeaderRekey.finishMove`). An original
            // archived on Gmail keeps its Inbox-shaped key until this listing
            // re-keys it, and a reply then discarded unsent must still find it to
            // take Send's mark back (#1500). Not carried by the skip above: the row
            // keeps its key there, so the send still finds it. The UID remap and
            // the body backfill's re-key, on Message-ID evidence, never carry it
            // (ADR-IOS-068 D4, `IOS-OUTBOX-012`).
            // outboxMessage holds only unsent, failed and unfinalized sends, and
            // this arm runs only when a row is re-keyed, never on the fast path.
            try db.execute(
                sql: "UPDATE outboxMessage SET originalMessageHeaderId = ? WHERE originalMessageHeaderId = ?",
                arguments: [canonicalId, oldId])
            survivor = migrated
            ftsRekey = (oldId: oldId, newId: canonicalId)
            if DebugModeManager.isLoggingEnabled() {
                print("[Sync] Canonicalize: re-keyed remnant \(oldId) → \(canonicalId)")
            }
        } else if !removedIds.isEmpty {
            try survivor.update(db)
        }

        // Reattach the preserved body under the final id if none is present.
        if let body = bestBody, try MessageBody.fetchOne(db, key: ContentKey(rawValue: survivor.id)) == nil {
            var rekeyedBody = body
            rekeyedBody.id = ContentKey(rawValue: survivor.id)
            try rekeyedBody.insert(db)
        }

        return (survivor, removedIds, ftsRekey, true)
    }

    /// ⚑ NO REFERENCE — INVENTED: minimum proof that a local row owns the
    /// provider address offered by this sync pass. The exact `v2final`
    /// canonicalizer has only an RFC discriminator and no persisted header
    /// observation epoch. See `canonicalizeLocalRows` for the census boundary.
    nonisolated static func providerAddressOwnershipProven(
        row: MessageHeader,
        accountId: String,
        folderPath: String,
        folderId: String,
        messageId: String,
        canonicalId: String,
        windowMode: StaleWindowMode,
        sourceBoundEpoch: Int?
    ) -> Bool {
        guard row.accountId == accountId, row.messageId == messageId else { return false }
        switch windowMode {
        case .date:
            return true
        case .uid:
            guard let sourceBoundEpoch, sourceBoundEpoch > 0 else { return false }
            guard row.folderId == folderId, row.folderPath == folderPath else { return false }
            // The direct canonical-PK hit is the existing T2.5 bound-observation
            // path. A non-canonical row may join it only when its persisted
            // source observation already matches this serving FETCH.
            return row.id == canonicalId || row.observedUidValidity == sourceBoundEpoch
        }
    }

    /// The one builder of the coverage a listing's stale sweep is told
    /// (ADR-IOS-111). Both sweep branches (the small whole-folder branch and the
    /// windowed slice) take it from here, so the listing's own SELECT evidence
    /// (`counters`, carrying its UIDNEXT bound) reaches the sweep whichever
    /// branch runs. `wholeFolder` is the branch's own decision: a large folder
    /// falls to the windowed slice even when the server proved whole-folder
    /// coverage, and must not then claim complete knowledge.
    nonisolated static func sweepCoverage(_ coverage: FetchCoverage, wholeFolder: Bool) -> FetchCoverage {
        var swept = coverage
        swept.spansEntireFolder = coverage.spansEntireFolder && wholeFolder
        return swept
    }

    /// The UID window a windowed IMAP sweep judges: from the lowest UID fetched
    /// to the listing's own UIDNEXT - 1. A UID at or above that UIDNEXT was
    /// allocated after its SELECT and is never evidence for removal (#755); a UID
    /// above the highest fetched but below UIDNEXT is a message the server no
    /// longer holds (the window reaches the folder's newest message), so it is
    /// judged: a deleted newest message leaves the device. The highest fetched
    /// UID is the bound only when the listing carried no UIDNEXT. The one source
    /// for both the candidate load and the removal decision. Nil when no fetched
    /// record carried a usable UID: the sweep removes nothing. Callers use it
    /// only once `listingProvedItsWindow` holds for the listing.
    nonisolated static func windowedSweepUIDBounds(fetched: [MessageHeaderInfo], coverage: FetchCoverage) -> (floor: Int64, ceiling: Int64)? {
        let fetchedUIDs = fetched.compactMap { Int64($0.messageId) }
        guard let floorUID = fetchedUIDs.min(), let fetchedMax = fetchedUIDs.max() else { return nil }
        let ceilingUID = coverage.counters?.uidNext.map { Int64($0) - 1 } ?? fetchedMax
        guard ceilingUID >= floorUID else { return nil }
        return (floorUID, ceilingUID)
    }


    /// SINGLE SOURCE OF TRUTH for "which local rows may be stale-deleted after a
    /// WINDOWED fetch". Pure + deterministic so production sync and the test harness
    /// share one rule that cannot drift.
    ///
    /// Invariant: a windowed fetch (newest `limit` rows) gives COMPLETE remote
    /// knowledge ONLY for the slice it covered, measured in the provider's
    /// fetch-ordering dimension:
    ///   - `.uid` (IMAP): the fetch returns the highest UIDs. UID == archive-time,
    ///     DECORRELATED from message `date` — archiving an old email assigns it a
    ///     fresh high UID with an old date. A DATE floor is dragged backwards by one
    ///     such message and sweeps in months of mid-range mail the fetch never
    ///     returned → mass false stale-deletion (the "Archive month-gap" data-loss
    ///     bug). Bound by UID: never delete a row whose UID is below the smallest
    ///     fetched UID — it was outside the window.
    ///   - `.date` (Gmail/Exchange): fetch is most-recent-by-date, so a date floor IS
    ///     the covered slice (and their ids aren't numeric UIDs anyway).
    ///
    /// 🚨 **COMPLETE KNOWLEDGE IS `coverage.spansEntireFolder` — A STATEMENT THE
    /// SERVER MADE — AND NEVER A COUNT OF WHAT WE MATERIALISED.** This branch used
    /// to read `fetched.count < limit`, and `fetched` is the post-`compactMap`
    /// SURVIVOR array of a `fetchMessages` implementation that drops every record
    /// it cannot parse (`IMAPProvider.mapMessageInfo`,
    /// `ExchangeProvider.parseGraphMessage`, `GmailProvider`'s task group). One
    /// malformed sibling in a FULL window therefore read as "the whole folder came
    /// back", and this branch has NO floor: every local row the fetch never went
    /// near was classified stale and deleted with its FTS entry. That is the
    /// ADR-IOS-042 / MIS-IOS-002 mass-deletion shape reached through a different
    /// door, and it is not recoverable — the catch-up's load of missing UIDs
    /// (#1062; before it, a 90-day self-heal) reloads only what it lists, and the deep crawl only re-walks folders with `backfillComplete == false`.
    /// The fix is honest evidence, NOT a narrower blast radius: adding a floor here
    /// would degenerate this branch into the windowed one and destroy its purpose
    /// (deleting rows BELOW the window that the server dropped long ago).
    /// `v2final` (`e28dd4edb`) carries the identical `fetched.count < limit` defect
    /// in the identical function — it is a floor here, not a ceiling.
    ///
    /// `coverage.unmaterialisedIds` join `remoteIds` for the same reason in reverse:
    /// the server NAMED those messages, so they are PRESENT. A record we could not
    /// parse must never read as "the server no longer has it".
    ///
    /// **PRESENCE and COVERAGE are two different questions, and `\Deleted` answers
    /// only the first (`IOS-IMAP-001` / D3).** A message the server reports with
    /// `\Deleted` is pending removal (RFC 3501 §2.3.2) and is not presented, so it
    /// does not keep a local row alive — it is subtracted from `remoteIds` below.
    /// It is NOT subtracted from `fetched.count` or from the UID floor: those
    /// measure what the FETCH covered, and a `\Deleted` record was covered. Taking
    /// this flag into the window instead of into presence would raise the floor
    /// (or trip the complete-knowledge branch) and stale-delete rows the fetch
    /// never returned — the ADR-IOS-042 / MIS-IOS-002 Archive data-loss shape.
    nonisolated static func selectStaleHeaders(
        candidates: [MessageHeader],
        fetched: [MessageHeaderInfo],
        coverage: FetchCoverage,
        windowMode: StaleWindowMode
    ) -> [MessageHeader] {
        let remoteIds = Set(fetched.lazy.filter { !$0.isDeletedOnServer }.map(\.messageId))
            .union(coverage.unmaterialisedIds)
        if coverage.spansEntireFolder {
            // Whole-folder knowledge reaches only as far as this listing's own
            // selection: on IMAP a UID at or above its UIDNEXT (or, with no
            // UIDNEXT reported, above the highest UID it fetched) arrived after
            // it, and another listing may already hold it. That row is never
            // judged by this listing.
            // With neither (an empty selection that reported no UIDNEXT, or
            // records none of which carried a usable UID) there is no bound, and
            // the sweep removes nothing: fail closed.
            if windowMode == .uid {
                let seenUIDs = fetched.compactMap({ Int64($0.messageId) })
                    + coverage.unmaterialisedIds.compactMap { Int64($0) }
                guard let ceiling = coverage.counters?.uidNext.map({ Int64($0) - 1 }) ?? seenUIDs.max() else { return [] }
                return candidates.filter { row in
                    guard let uid = Int64(row.messageId) else { return !remoteIds.contains(row.messageId) }
                    return uid <= ceiling && !remoteIds.contains(row.messageId)
                }
            }
            return candidates.filter { !remoteIds.contains($0.messageId) }
        }
        switch windowMode {
        case .uid:
            // The floor is taken over MATERIALISED records only. A record we could
            // not parse would only ever LOWER it, widening the candidate set — the
            // fail-dangerous direction — while a higher floor merely defers a
            // deletion to a later pass. Fail closed.
            //
            // The window is closed at BOTH ends: it runs from the lowest UID
            // fetched to the listing's own UIDNEXT - 1. A UID at or above that
            // UIDNEXT was allocated after the listing's SELECT (another listing
            // may already have stored it; its FETCH may still return it, e.g.
            // flagged \Deleted, while another listing stores it live), so it is
            // never evidence for removal (#755). A UID between the highest
            // fetched and UIDNEXT - 1 was assigned before the SELECT and the
            // server no longer holds it (the window reaches the folder's newest
            // message), so it is judged. The highest fetched UID is the
            // bound only when the listing carried no UIDNEXT.
            guard let (floorUID, ceilingUID) = windowedSweepUIDBounds(fetched: fetched, coverage: coverage) else { return [] }
            return candidates.filter { row in
                guard let uid = Int64(row.messageId) else { return false } // non-numeric id → never UID-stale
                return uid >= floorUID && uid <= ceilingUID && !remoteIds.contains(row.messageId)
            }
        case .date:
            // PROVIDER ORDER, not display order. Gmail pages by `internalDate`,
            // and on Gmail `date` is the top `Received:` timestamp, which can
            // sit WEEKS after `internalDate` for Google-relayed mail. A window
            // keyed on `date` would admit a row whose arrival date is inside
            // the window but whose `internalDate` is below the page's floor —
            // absent from the page for that reason alone — and delete it. Same
            // decorrelation ADR-IOS-042 keys IMAP by UID for. Graph's
            // `receivedDateTime` is both keys, so nothing changes there.
            guard let floorDate = fetched.map(\.providerOrderDate).min() else { return [] }
            return candidates.filter { $0.providerDate >= floorDate && !remoteIds.contains($0.messageId) }
        }
    }

    /// The placeholder message ids (`draft-…`) of `accountId`'s local drafts that
    /// have never reached the server (no `serverDraftId`). The full sync never
    /// stale-deletes these (#519): the server cannot list what it never received,
    /// and the placeholder header is the only row such a draft opens from
    /// (`LocallyAuthoredDraftOpenAuthority.resolve`). A placeholder whose draft is
    /// gone (sent, deleted, evicted) or has a server copy is not in this set and
    /// is removed as before.
    nonisolated static func neverUploadedDraftPlaceholderIds(accountId: String, db: Database) throws -> Set<String> {
        let drafts = try Draft.filter(Column("accountId") == accountId).fetchAll(db)
        return Set(drafts.compactMap { draft -> String? in
            guard (draft.serverDraftId ?? "").isEmpty,
                  let epoch = draft.instanceEpoch, !epoch.isEmpty else { return nil }
            return PendingOperation.draftPlaceholderMessageId(draftId: draft.id, instanceEpoch: epoch)
        })
    }

    /// The identity an rfc822 Message-ID column carries, or nil when it carries
    /// NONE. Normalized (angle brackets/whitespace stripped) so a stored
    /// `<a@example.com>` and an incoming `a@example.com` are the same identity,
    /// and empty-after-normalization collapses to nil — an empty string is the
    /// absence of an identity, not a distinct one.
    ///
    /// One helper rather than the reference's four inlined copies of
    /// `.map(EmailFilter.normalizeMessageId).flatMap { $0.isEmpty ? nil : $0 }`
    /// (`v2final:669-673, 685-690, 1946-1951, 2350-2355`): every §5 site must
    /// agree on what "same identity" means, and four copies are four chances
    /// for one to drift.
    nonisolated static func normalizedRfc822Identity(_ raw: String?) -> String? {
        raw.map(EmailFilter.normalizeMessageId).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Which of `remoteIds` are NEW (not already present locally in `folderId`) —
    /// i.e. `remoteIds − localIdsInFolder`. Feeds UID-remap detection in `runSyncMessages`.
    ///
    /// `newRemoteIds` only ever subtracts from `remoteIds`, so intersecting the local
    /// set with `remoteIds` FIRST is byte-identical to loading the whole folder and
    /// subtracting (`remoteIds − local ≡ remoteIds − (local ∩ remoteIds)`) — but WITHOUT
    /// materializing tens of thousands of rows for a huge folder (All Mail; the old
    /// unbounded `SELECT messageId WHERE folderId = ?` was ~7s of write execution INSIDE
    /// the writer). When the caller already loaded the full local-id set for stale
    /// detection (`cachedLocalIds`, the small-folder branch), reuse it; otherwise do a
    /// bounded, chunked membership check (the idiom the deleted `SyncEngineSelfHeal`
    /// used, #1062).
    ///
    /// `messageId` IS the UID for IMAP — this is pure exact membership, with NO date/UID
    /// window, so it does NOT touch stale-window semantics (ADR-IOS-042-safe). Empty
    /// `remoteIds` is a valid no-op (the loop doesn't run; returns empty) — this is why
    /// the query builder is used over a raw `IN (…)`, which would be invalid SQL for an
    /// empty list.
    nonisolated static func newRemoteIds(
        in db: Database,
        folderId: String,
        remoteIds: Set<String>,
        cachedLocalIds: Set<String>?
    ) throws -> Set<String> {
        if let cached = cachedLocalIds {
            return remoteIds.subtracting(cached)
        }
        let sqlChunkSize = SyncConfig.sqlChunkSize
        let remoteArr = Array(remoteIds)
        var existingLocalIds = Set<String>()
        for start in stride(from: 0, to: remoteArr.count, by: sqlChunkSize) {
            let end = min(start + sqlChunkSize, remoteArr.count)
            let chunk = Array(remoteArr[start..<end])
            let found = try String.fetchSet(db,
                MessageHeader
                    .select(Column("messageId"))
                    .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
            )
            existingLocalIds.formUnion(found)
        }
        return remoteIds.subtracting(existingLocalIds)
    }

    /// Core message sync logic — runs entirely off the main thread.
    /// Fetches messages from provider, performs stale detection + upsert in a single
    /// DB write transaction. No MainActor state accessed.
    /// PRIVATE: only the one classifier (`runListing`) calls it, so no route can
    /// publish a listing's rows or counters without its `ListingOutcome`.
    /// `bound`: the request bound of a listing in an other-folder run's slice
    /// (#1110, `ListingRequestBound`): the epoch check's FETCH and the listing's
    /// own read each start only while the slice has time and get its request
    /// limit. A cut or timed-out read throws, before anything is written.
    private nonisolated static func runSyncMessages(
        for folder: Folder,
        provider: any EmailProvider,
        limit: Int,
        dbPool: PrioritizedDatabase,
        bound: ListingRequestBound? = nil
    ) async throws -> SyncMessagesResult {
        // T1.2b — SELECT-sourced epoch capture, BOUND to this pass's own fetch.
        // `fetchMessagesWithObservedEpoch` SELECTs the folder
        // (`IMAPProvider.selectMailboxTracked`) and hands back the UIDVALIDITY
        // that same `Mailbox.Selection` reported, so nothing can get between the
        // two. `OK [UIDVALIDITY n]` is core IMAP4rev1, NOT a UIDPLUS extension —
        // so on a non-UIDPLUS server, where the STATUS-sourced writes T1.2 added
        // see nil forever, this is the epoch source that still answers. (The
        // deletion-reconcile walk's own SELECT is the other one, but it only runs
        // on a count mismatch, so it is not a backstop.) nil for every non-IMAP
        // provider (protocol default), and nil — never a previous SELECT's
        // value — when the SELECT that served this fetch reported no UIDVALIDITY.
        //
        // 🚨 ROUND 10 — this used to read the shared
        // `provider.lastObservedUidValidity(folderPath:)` mirror right after the
        // fetch, and that was a REGRESSION the moment round 8 routed the backfill
        // walk's three SELECTs through the tracked chokepoint: the walk's
        // `getUidNext`/`searchExistingUIDs`/`fetchMessageHeaders` — and, through
        // that last one, self-heal and the date-window deep backfill (since
        // deleted), neither of them epoch-guarded then — all replace the mirror
        // for this same folder path. One of them landing between the fetch and
        // the read let this pass bootstrap
        // the LIVE epoch while merging the PREVIOUS one's headers, which is the
        // stamp-agrees-with-live-server-over-old-rows state that disarms the
        // ADR-IOS-051 deletion-reconcile abort guard — the mass-deletion failure
        // this whole train exists to prevent, relocated into another consumer.
        //
        // REFERENCE (`v2final`, tag `e28dd4edb`): the same capture at the same
        // point of the same function reads the MIRROR
        // (`let observedEpochAtFetch = provider.lastObservedUidValidity(folderPath:)`),
        // and it is sound there: its consumer is the §5.5 in-transaction
        // COMPARISON that abandons the entire merge pass on disagreement, so a
        // race can only force a false MISMATCH (abort), never a false match — the
        // reference's own comment argues exactly that. v3 has not ported §5.5
        // (T4.S6), so here the value feeds a bootstrap WRITE, where the identical
        // race is fail-dangerous. The mechanism does NOT transfer across that
        // inversion of consumer direction; the binding below replaces it.
        // T4.S6b — the VERIFIED door, BEFORE the fetch. A folder that already holds
        // rows under a nil epoch can no longer be stamped by assertion (the blind
        // writers all carry a `NOT EXISTS (… messageHeader …)` term now), so this is
        // where such a folder either EARNS its epoch — by FETCHing a sample of its own
        // stored UIDs and finding at least one whose RFC-822 Message-ID still answers
        // there — or gets quarantined for the purge-and-resync reaction.
        //
        // The ordering is deliberate: by the time the in-transaction guards below run,
        // the folder is either stamped (guard (b) proceeds normally) or quarantined
        // (guard (a) skips this pass and the reaction owns it). It is a no-op — one
        // small read, no network — for every folder that already has an epoch, holds
        // no rows, or is already quarantined, which is the steady state.
        //
        // A folder whose row is gone by now (deleted, or its account removed while
        // this listing waited) is not read from the server at all.
        let verification = await Self.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folder.id, folderPath: folder.path, accountId: folder.accountId,
            provider: provider, dbPool: dbPool, bound: bound)
        if verification == .folderGone { throw FolderGoneBeforeListing() }
        let path = folder.path
        let read: @Sendable () async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage) = {
            try await provider.fetchMessagesWithObservedEpoch(folder: path, limit: limit, offset: 0)
        }
        let fetched: (messages: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage)
        if let bound {
            fetched = try await bound.request(read)
        } else {
            fetched = try await read()
        }
        let messages = fetched.messages
        // COVERAGE — what the SERVER said about the window, bound to this fetch and
        // computed before any client-side narrowing. Every "did we see the whole
        // folder?" decision below reads THIS, never `messages.count`. See
        // `FetchCoverage` and `selectStaleHeaders`.
        let coverage = fetched.coverage
        // A listing that did not see its whole window proves nothing about the
        // folder: its counters are neither written nor returned.
        let provedWindow = Self.listingProvedItsWindow(coverage, limit: limit)
        let observedEpochAtFetch = fetched.observedEpoch
        let sourceBoundEpoch = observedEpochAtFetch.flatMap { epoch in
            epoch > 0 ? Int(exactly: epoch) : nil
        }
        let folderPath = folder.path
        let folderId = folder.id
        let accountId = folder.accountId
        let isInInbox = folder.role == .inbox

        // IOS-IMAP-001 / D3 — a `\Deleted` remote message is NOT PRESENT for
        // display. RFC 3501 §2.3.2 defines the flag as "deleted for removal by
        // later EXPUNGE": still on the server, still holding its UID, pending
        // removal. On a server without UIDPLUS that is exactly what a completed
        // move leaves behind (`IMAPProvider.move` soft-deletes the source and the
        // purge stays gated on `COPYUID`), and ingesting it as an ordinary message
        // re-listed it in the Inbox after the protections expired.
        //
        // `messages` itself is deliberately NOT filtered. Every windowing decision
        // below — the `CAST(messageId AS INTEGER)` floor and `selectStaleHeaders`'
        // own floor — must keep measuring the whole fetch, because they describe
        // WHAT THE FETCH COVERED. Shrinking the fetch here would raise the floor
        // and stale-delete rows the fetch never returned (ADR-IOS-042 /
        // MIS-IOS-002). The complete-knowledge decision no longer reads `messages`
        // at all — it reads `coverage.spansEntireFolder`, which the provider
        // derived from the server's own EXISTS/page size.
        let deletedRemoteIds = Set(messages.lazy.filter(\.isDeletedOnServer).map(\.messageId))
        // Presence, not coverage: the id set every "does the server still have
        // this?" question is answered from. Feeds the UID-remap target map, so a
        // `\Deleted` UID can also never become the destination of a re-key.
        let remoteIds = Set(messages.lazy.filter { !$0.isDeletedOnServer }.map(\.messageId))

        // Stale detection + deletion + upsert in one write block.
        // Pending ops are loaded INSIDE the write transaction to prevent TOCTOU races
        // (a user action inserting a PendingOperation between a separate read and this write
        // would cause the pendingDestructiveIds set to be stale, leading to UNIQUE constraint violations).
        // DIAGNOSTIC (debug-gated): time this per-folder write. The merge waits ≤ ONE
        // in-flight write (DatabaseWriteQueue can't preempt SQLite), so a single long
        // folder write here is the residual cap to chunk. Remove once confirmed bounded.
        let writeStart = CFAbsoluteTimeGetCurrent()
        let syncResult: (newHeaders: [MessageHeader], staleIds: [String], replyDetectIds: [String], uidMigratedOldIds: [String], ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)], headerRekeys: [HeaderRekeyRecord], upsertLine: String?, counters: ListingCounters?, merged: Bool) = try await dbPool.write { db in
            // ⚠ PRE-EXISTING HAZARD, deliberately NOT closed by T1.2 and tracked
            // separately: this merge pass has NO UIDVALIDITY guard. `selectStaleHeaders`
            // below classifies "the server did not return UID n" as stale, which on a
            // re-created mailbox is true of EVERY local row (the new numbering restarts
            // beneath them), and old-epoch headers also upsert cleanly into a folder whose
            // numbering they no longer belong to. `v2final` closes this with its §5.5
            // universal in-txn guard (`SyncEngineFullSync.swift:1045-1070` at tag
            // `e28dd4edb`, ADR-IOS-061 Stage 1): re-read the folder row INSIDE this
            // transaction and abandon the whole pass — before any deletion or upsert —
            // when the epoch captured at fetch time disagrees with the stored one. That
            // port is its own item; T1.2 must not widen the blast radius of a deleter it
            // did not create, and must not narrow it either.
            //
            // T1.2b: bootstrap this folder's epoch from the SELECT that served the
            // fetch above, as its own conditional statement inside this SAME
            // transaction (`lastKnownUidValidity IS NULL` evaluated by SQLite at
            // write time — see `SyncEngine.bootstrapFolderUidValidity`, whose doc
            // comment enumerates all three writers of this column). On a
            // non-UIDPLUS server this is the write that reaches a folder the
            // deletion-reconcile walk has never visited — the walk's own bootstrap
            // is the only other one that can, and it needs a count mismatch to run.
            // It is BOOTSTRAP-ONLY and it is not part of the merge: it can only
            // fill a nil column, never overwrite the epoch the local UIDs belong
            // to, so it adds no deletion path — the walk's abort guard is armed by
            // a populated column, never disarmed by one.
            // T4.S6 — the §5.5 universal in-txn guard this pass had none of, and the
            // reaction's primary trigger. Re-read the folder row INSIDE this
            // transaction (the `folder` argument is a snapshot from BEFORE the
            // network fetch, so it cannot decide anything) and refuse the pass on
            // EITHER of two conditions: the folder is in UIDVALIDITY quarantine, or
            // the stored epoch disagrees with the one the SELECT that served
            // `messages` reported.
            //
            // REFERENCE (`v2final`, tag `7904961ded`):
            // `SyncEngineFullSync.swift` ~1046-1072, the same in-txn `Folder`
            // re-read feeding `uidValidityWriteAllowed(resetPending:observedEpoch:
            // storedEpoch:)` = `!resetPending && !epochMismatch`. Written out here
            // as two named branches instead of one shared pure formula because v3
            // has exactly ONE guarded writer; the reference needed a shared formula
            // because its backfill writers evaluate the same decision. The stored
            // side differs deliberately: the reference reads its in-memory epoch
            // ledger mirror, v3 reads `Folder.lastKnownUidValidity` from the row it
            // has already fetched in this transaction — strictly fresher, and one
            // fewer thing that can disagree with the durable value.
            //
            // On a proven disagreement the whole pass is ABANDONED before any
            // deletion or upsert: `selectStaleHeaders` classifies "the server did
            // not return UID n" as stale, which on a re-created mailbox is true of
            // EVERY local row, and old-epoch headers would otherwise upsert cleanly
            // into a numbering they no longer belong to. Fail-closed and TRANSIENT —
            // the reaction fired below purges and resyncs this folder, and if it
            // cannot run yet the next pass re-evaluates from scratch.
            //
            // BOTH-KNOWN is required. A nil observed epoch (the server reported no
            // UIDVALIDITY on this SELECT) and a nil stored epoch (never bootstrapped)
            // each fail OPEN, matching every other UIDVALIDITY guard in the tree —
            // refusing on an unknown would brick non-UIDPLUS/first-sync folders.
            let folderInTxn = try Folder.fetchOne(db, key: folderId)
            // (a) QUARANTINE. Re-read IN this transaction — a check outside it is
            // TOCTOU-broken by this codebase's own pending-ops-inside-txn rule.
            //
            // ⚑ This term is what makes the quarantine cover EVERY caller. The
            // full-sync and delta-sync loops branch into the reaction before they
            // reach here, but `syncFolderMessages` — the other door to this
            // function — is also called by on-demand folder navigation
            // (`AccountManagerFetch`), the detail view, the outbox drain and the
            // op drain, none of which consult the flag. Without this the user
            // merely OPENING a quarantined folder inserts NEW-epoch headers under
            // the OLD stamp, which is exactly the state a bare-UID durable op
            // mutates the wrong message from (C3).
            //
            // No self-lock: the reaction's own step-6 resync reaches this function
            // AFTER step 5 has cleared the flag in the same write that stamped the
            // fresh epoch, so the folder is out of quarantine by then. TRANSIENT —
            // full sync re-drives an interrupted reaction on every cycle.
            if folderInTxn?.uidValidityResetPendingAt != nil {
                BackgroundSyncLogger.log("[Sync] merge pass SKIPPED for \(folderId) — folder is in UIDVALIDITY quarantine; the reaction owns it")
                return (newHeaders: [], staleIds: [], replyDetectIds: [], uidMigratedOldIds: [], ftsRekeys: [], headerRekeys: [], upsertLine: nil, counters: nil, merged: false)
            }
            // (b) EPOCH DISAGREEMENT.
            let storedEpochInTxn = Self.knownUidValidity(
                folderInTxn?.lastKnownUidValidity
            ).flatMap { UInt32(exactly: $0) }
            if let observed = observedEpochAtFetch, let stored = storedEpochInTxn, observed != stored {
                // Ungated per CLAUDE.md rule 12 exception (b): production
                // observability needs the turnover itself, not just its aftermath.
                BackgroundSyncLogger.log("[Sync] UIDVALIDITY turnover at \(folderId): stored=\(stored) observed=\(observed) — abandoning this merge pass, triggering the purge-and-resync reaction")
                AccountManager.shared.fireUidValidityChangeHandler(
                    accountId: accountId, folderPath: folderPath,
                    storedValue: stored, observedValue: observed
                )
                return (newHeaders: [], staleIds: [], replyDetectIds: [], uidMigratedOldIds: [], ftsRekeys: [], headerRekeys: [], upsertLine: nil, counters: nil, merged: false)
            }
            try Self.bootstrapFolderUidValidity(
                db, folderId: folderId, observed: observedEpochAtFetch.map { Int($0) })
            // The gap trigger (#1062): a listing by UID whose lowest UID lies above
            // the newest UID the folder held before it, plus one, leaves messages
            // between the two that no window reaches. The folder's older-mail
            // check is armed at once (a lapse), so the next worker run loads
            // them, with no wait for its periodic check, and whether or not the
            // older-mail walk has started (the load floor is then the lowest
            // UID a window listing reached, `CatchUpWindowFloor`). Read before this pass
            // inserts anything.
            if provider.staleWindowMode == .uid {
                if let lowestListed = messages.compactMap({ Int($0.messageId) }).min(),
                   let newestHeld = try Int.fetchOne(db, sql: """
                       SELECT MAX(CAST(messageId AS INTEGER)) FROM messageHeader WHERE folderId = ?
                       """, arguments: [folderId]),
                   lowestListed > newestHeld + 1 {
                    try Self.markCatchUpLapse(folderId: folderId, db: db)
                }
                // Where window listings reach down to: the catch-up's load floor
                // before the walk starts (`CatchUpWindowFloor`). After the lapse
                // mark, which leaves a NULL state NULL. The lowest UID the server
                // NAMED in the window, the ones whose header could not be read
                // (`coverage.unmaterialisedIds`, from the same FETCH) included: a
                // floor from the read headers alone sits above an unreadable
                // lowest UID, and a catch-up before the walk would never load it
                // once it reads. Only under a known epoch for this response: a
                // floor from UIDs of unknown numbering could outlive an epoch
                // change (ADR-IOS-061), so none is written. Stored with that epoch
                // and read only under it, so a path that clears the folder's epoch
                // but keeps its state never carries it into another numbering.
                // *Superseded (#1062):* the floor was the lowest UID of the read
                // headers, written whatever the response's epoch, with no epoch.
                let namedUids = messages.compactMap { Int($0.messageId) }
                    + coverage.unmaterialisedIds.compactMap { Int($0) }
                if let sourceBoundEpoch, let lowestNamed = namedUids.min() {
                    try Self.recordCatchUpWindowFloor(
                        folderId: folderId, lowest: lowestNamed, epoch: sourceBoundEpoch, db: db)
                }
            }
            // Load pending operation message IDs to avoid undoing optimistic UI.
            // IMPORTANT: Filter by (accountId, folderPath) to prevent cross-folder UID collisions.
            // IMAP UIDs are per-folder — UID "500" in INBOX and UID "500" in Archive are different
            // messages. A global set would incorrectly block unrelated messages with the same UID.
            //
            // Upsert/flag filters scope to ops ORIGINATING FROM this folder (source match).
            // Stale-delete protection also includes ops TARGETING this folder (destinationPath)
            // — an optimistic move places the row at the destination with the source UID;
            // that row must survive the sync pass at the destination until the drain executes.
            let pendingOps = try PendingOperation.fetchAll(db)
            let opsForThisFolder = pendingOps.filter { $0.accountId == accountId && $0.folderPath == folderPath }
            let thisFolderSnapshot = PendingOperationSnapshot(ops: opsForThisFolder)
            let pendingDestructiveIds = thisFolderSnapshot.destructive
            let pendingFlagIds = thisFolderSnapshot.flag

            let isPendingDestructive: (MessageHeaderInfo) -> Bool = { info in
                pendingDestructiveIds.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)
            }
            let isPendingFlag: (MessageHeaderInfo) -> Bool = { info in
                pendingFlagIds.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)
            }
            // Recently completed guard — bridges gap between PendingOp deletion and
            // server-side state propagation (30s TTL). Replaces per-folder recentActions.
            //
            // 🚨 READ INSIDE THIS TRANSACTION, never passed in from before the
            // listing fetch above. Like the pending ops just loaded, the protection
            // set must be as fresh as the write that consults it: a move completing
            // during the fetch is retired (op deleted, row re-keyed to its
            // destination) while `messages` still lists its source address, and a
            // pre-fetch snapshot sees neither the op nor the entry — the
            // snippet-less ghost re-insert of issue #106. The completion records
            // its entry before its retirement transaction, and that transaction
            // and this one are serialised on the same writer, so this read sees
            // one of the two guards whichever side of the retirement it lands on.
            // Entries are expiry-filtered at read, so no prune precedes this.
            let recentlyCompleted = AccountManager.shared.liveRecentlyCompleted()
            let isRecentlyCompleted: (MessageHeaderInfo) -> Bool = { info in
                recentlyCompleted[info.messageId] != nil ||
                (info.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false)
            }
            let opsTargetingThisFolder = pendingOps.filter {
                $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
            }
            let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))
            if !pendingDestructiveIds.isEmpty || pendingAllIds.count > pendingDestructiveIds.count {
                if DebugModeManager.isLoggingEnabled() {
                    print("[MoveTrace] fullSync \(folder.name) — pendingDestructiveIds=\(pendingDestructiveIds) pendingAllIds=\(pendingAllIds)")
                }
            }
            var newHeaders: [MessageHeader] = []
            // Diagnostic-only id lists for the `[MoveTrace] fullSync upsert` line
            // rendered at the end of this closure: `insertedIds` grows ONLY next
            // to a `header.insert(db)`, `reclaimedIds` ONLY at the orphan-reclaim
            // arm's in-place update. `newHeaders` carries BOTH kinds for the FTS /
            // body-queue consumers and is deliberately not the source of either
            // list — an in-place update reported as an insert is the lie R4-RS-1
            // removed.
            var insertedIds: [String] = []
            var reclaimedIds: [String] = []
            var staleIds: [String] = []
            var ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)] = []
            var headerRekeys: [HeaderRekeyRecord] = []
            // Remove stale local messages.
            // Uses date-bounded query to load only the overlap window, not all 8000+ messages.
            // MessageAICache preserves AI state for re-inserted messages.
            var replyDetectIds: [String] = []
            let stale: [MessageHeader]
            var allLocalIds: Set<String>?
            // Stale-detection window dimension MUST match the provider's fetch ordering
            // (see selectStaleHeaders): IMAP = UID (archive-time, decorrelated from date),
            // Gmail/Exchange = date. A date window on IMAP over-deletes the Archive.
            // DIAGNOSTIC (debug-gated): decompose the per-folder write so a residual long
            // exec (e.g. All Mail) can be attributed to a PHASE, which the whole-tx
            // `DBwrite EXEC` mark can't. `staleDetect` = the stale-candidate load (:611
            // fetchAll OR :634 `CAST(messageId AS INTEGER)` scan — both scale with folder
            // size; the CAST defeats the index so it scans ALL rows). `newRemoteIds` = the
            // FIX-A bounded membership check. If newRemoteIds is ~ms while staleDetect is
            // seconds, FIX A is working and the CAST-scan is the residual to bound next.
            let staleCandT0 = CFAbsoluteTimeGetCurrent()
            let windowMode = provider.staleWindowMode
            // Complete-knowledge stale detection (treat the fetch as the whole folder and
            // stale-delete any local row not returned) is only safe AND bounded when the
            // LOCAL side is also small — so gate on a cheap index-backed COUNT (evaluated
            // ONLY when the server proved whole-folder coverage, via `&&` short-circuit)
            // and fall through to the bounded windowed slice when the folder is large.
            // This bounds the load (no whole-folder fetchAll on All Mail).
            //
            // 🚨 The first term is `coverage.spansEntireFolder` — the SERVER's statement —
            // and used to be `messages.count < limit`, a count taken AFTER the provider's
            // `compactMap`. One unparseable record in a full window made that true for a
            // 900-message folder, and this branch has no floor, so the other ~851 rows
            // were deleted. `staleDetectionMaxFullScan` was never a defence against it
            // (a 900-row folder is well under 2000). See `selectStaleHeaders`.
            //
            // `effectiveCoverage` is what `selectStaleHeaders` is told, and it is the
            // decision ACTUALLY made here: a large folder falls to the windowed slice even
            // when the server proved whole-folder coverage, so it must not then be handed
            // a complete-knowledge claim over a bounded candidate set.
            let effectiveCoverage: FetchCoverage
            if !provedWindow {
                // A listing that did not see every record its own selection
                // counted (a short FETCH, an expunge between SELECT and FETCH)
                // proves nothing about absence: no stale sweep. The next pass
                // lists again.
                effectiveCoverage = .unproven
                stale = []
            } else if coverage.spansEntireFolder,
               try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db) <= SyncConfig.staleDetectionMaxFullScan {
                // Got everything AND the folder is small enough to trust — find local
                // messages not in remote set
                let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
                let localIds = Set(allLocal.map(\.messageId))
                allLocalIds = localIds
                if !allLocal.isEmpty && !remoteIds.isEmpty {
                    if DebugModeManager.isLoggingEnabled() {
                        let onlyLocal = localIds.subtracting(remoteIds)
                        let onlyRemote = remoteIds.subtracting(localIds)
                        if !onlyLocal.isEmpty || !onlyRemote.isEmpty {
                            print("[Sync] \(folder.name) stale-check: local=\(allLocal.count) remote=\(messages.count) onlyLocal=\(Array(onlyLocal.prefix(5))) onlyRemote=\(Array(onlyRemote.prefix(5)))")
                        }
                    }
                }
                effectiveCoverage = Self.sweepCoverage(coverage, wholeFolder: true)
                stale = Self.selectStaleHeaders(
                    candidates: allLocal, fetched: messages, coverage: effectiveCoverage, windowMode: windowMode)
            } else {
                // The server did not prove whole-folder coverage — OR it did but the folder
                // holds more than `staleDetectionMaxFullScan` local rows, so a "complete"
                // read is untrustworthy. Load ONLY the bounded candidate slice (not the
                // whole folder, per the memory budget) in the fetch-ordering dimension,
                // then let selectStaleHeaders re-apply the same floor as the single source
                // of truth.
                effectiveCoverage = Self.sweepCoverage(coverage, wholeFolder: false)
                let candidates: [MessageHeader]
                switch windowMode {
                case .uid:
                    // messageId is a numeric IMAP UID; CAST avoids a lexicographic compare.
                    // At most `staleDetectionMaxFullScan` rows, newest first: after another
                    // client deletes thousands of a folder's newest messages, the window up to
                    // UIDNEXT - 1 can hold that many rows, and one write loads and removes no
                    // more than the whole-folder branch may. The rest stay (fail closed): the next
                    // listing judges those still inside its window (ADR-IOS-111, #1184 amendment).
                    if let (floorUID, ceilingUID) = Self.windowedSweepUIDBounds(fetched: messages, coverage: effectiveCoverage) {
                        candidates = try MessageHeader.fetchAll(db, sql:
                            "SELECT * FROM messageHeader WHERE folderId = ? AND CAST(messageId AS INTEGER) BETWEEN ? AND ? ORDER BY CAST(messageId AS INTEGER) DESC LIMIT ?",
                            arguments: [folderId, floorUID, ceilingUID, SyncConfig.staleDetectionMaxFullScan])
                    } else {
                        candidates = []  // no parseable UID floor → delete nothing (safe)
                    }
                case .date:
                    // `providerDate`, not `date` — the page is ordered by the
                    // provider's key; see `selectStaleHeaders` `.date` arm.
                    if let fetchCutoff = messages.map(\.providerOrderDate).min() {
                        candidates = try MessageHeader
                            .filter(Column("folderId") == folderId && Column("providerDate") >= fetchCutoff)
                            .fetchAll(db)
                    } else {
                        candidates = []
                    }
                }
                stale = Self.selectStaleHeaders(
                    candidates: candidates, fetched: messages, coverage: effectiveCoverage, windowMode: windowMode)
            }
            BootProfiler.mark("sync[\(folder.name)] staleDetect \(Int((CFAbsoluteTimeGetCurrent() - staleCandT0) * 1000))ms (stale=\(stale.count), remote=\(messages.count))")
            // Don't delete messages with pending operations or recently completed ops.
            // Undo-restored messages are protected by their PendingOp(move-back).
            let isProtectedByPending: (MessageHeader) -> Bool = { msg in
                pendingAllIds.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId)
            }
            let isProtectedByRecent: (MessageHeader) -> Bool = { msg in
                recentlyCompleted[msg.messageId] != nil ||
                (msg.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false)
            }
            // Protect optimistic Sent headers: outbox messages with sentMessageId set are
            // in-flight (sent but IMAP APPEND may not have completed). Their rfc822MessageId
            // matches the optimistic header — don't delete until the real message appears.
            var outboxProtectedRfc822s = Set<String>()
            if folder.role == .sent {
                let outboxRfc822s = try String.fetchAll(db, sql: """
                    SELECT sentMessageId FROM outboxMessage
                    WHERE accountId = ? AND sentMessageId IS NOT NULL
                """, arguments: [accountId])
                for raw in outboxRfc822s {
                    outboxProtectedRfc822s.insert(EmailFilter.normalizeMessageId(raw))
                }
            }
            let protectedIds = pendingAllIds
            if DebugModeManager.isLoggingEnabled() {
                let pendingSkipped = stale.filter { isProtectedByPending($0) || isProtectedByRecent($0) }
                if !pendingSkipped.isEmpty {
                    print("[MoveTrace] fullSync \(folder.name) — skipping stale delete for \(pendingSkipped.count) msgs with pending/recent ops: \(pendingSkipped.map(\.messageId))")
                }
            }
            // CONFIRMING INSTRUMENT (stale-race fix): a stale candidate saved ONLY by the
            // recent-arrival/completed guard (not a pending op) is a message the server
            // fetch transiently missed. A hit here right after a `merge: stale-protected …`
            // mark IS the pre-verify drop race — now caught instead of dropped. Debug-gated.
            let recentSaved = stale.filter { !isProtectedByPending($0) && isProtectedByRecent($0) }.count
            if recentSaved > 0 {
                BootProfiler.mark("fullSync \(folder.name): stale-delete SKIPPED for \(recentSaved) recently-arrived/completed msg(s) — pre-verify drop prevented")
            }

            // UID remap detection: before deleting stale messages, check if any have
            // rfc822MessageId matching a NEW remote message in the same folder. This catches
            // UID changes from IMAP MOVE round-trips, server-side operations, UIDVALIDITY
            // changes, etc. Migrate the local row in-place to preserve local state (body, AI cache).
            var uidMigratedRemoteIds = Set<String>()
            var uidMigratedOldMsgIds: [String] = []
            // Which remote ids are NEW (not already local) — bounded membership check;
            // see `newRemoteIds(in:folderId:remoteIds:cachedLocalIds:)`. Reuses the
            // allLocalIds set from stale detection when it was already loaded.
            let remapT0 = CFAbsoluteTimeGetCurrent()
            let newRemoteIds = try Self.newRemoteIds(
                in: db, folderId: folderId, remoteIds: remoteIds, cachedLocalIds: allLocalIds
            )
            BootProfiler.mark("sync[\(folder.name)] newRemoteIds \(Int((CFAbsoluteTimeGetCurrent() - remapT0) * 1000))ms")
            // Pre-build lookup by rfc822MessageId for O(1) matching (avoids O(stale × messages) scan)
            var newMessagesByRfc822: [String: [MessageHeaderInfo]] = [:]
            for msg in messages where newRemoteIds.contains(msg.messageId) {
                if let rfc822 = msg.rfc822MessageId, !rfc822.isEmpty {
                    newMessagesByRfc822[rfc822, default: []].append(msg)
                }
            }
            for staleMsg in stale {
                guard let rfc822 = staleMsg.rfc822MessageId, !rfc822.isEmpty else { continue }
                guard let match = newMessagesByRfc822[rfc822]?.first(where: {
                    !uidMigratedRemoteIds.contains($0.messageId)
                }) else { continue }
                let oldId = staleMsg.id
                let newMsgId = match.messageId
                let newId = "\(accountId):\(folderPath):\(newMsgId)"
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] UID remap: rfc822=\(rfc822) \(staleMsg.messageId)→\(newMsgId) in \(folder.name)")
                }
                var migrated = staleMsg
                migrated.id = newId
                migrated.messageId = newMsgId
                // RFC-only UID remap is corroboration, not provider-address
                // ownership. T5.11 may prove a later canonical adoption.
                migrated.observedUidValidity = nil
                // If the remote match has a broken (epoch 0) date from IMAP parse
                // failure, the entire remote record can't be trusted — preserve all
                // local fields (isRead, isFlagged, date). The UID remap still happens
                // so future syncs find the message, but we don't copy the broken
                // remote state. Next sync cycle will update with valid data.
                if match.date.timeIntervalSince1970 >= 86400 {
                    migrated.isRead = match.isRead
                    migrated.isFlagged = match.isFlagged
                    migrated.date = match.date
                    migrated.providerDate = match.providerOrderDate
                }
                // SHARED WITH THE DRAIN. `MessageHeaderRekey.apply` is this
                // block's own sequence, extracted verbatim so the drain can run
                // the IDENTICAL re-key earlier on the server's `COPYUID`
                // (`MessageHeaderRekey.finishMove`) instead of leaving every
                // moved row to be repaired here on weaker RFC 822 evidence. It
                // owns the body carry-forward, the two explicit deletes that
                // must precede every exit, the already-present collision skip,
                // and the two FK-cascading child tables (`messageReference`
                // rebuilt, `messageUserLabel` carried) this block used to
                // destroy silently.
                guard try MessageHeaderRekey.apply(from: staleMsg, to: migrated, db: db) else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] UID remap: SKIPPING migrate-insert for \(newId) — already present")
                    }
                    continue
                }
                // Move the FTS entry to the new id IN PLACE (preserves the
                // indexed body text + the messages_vec embedding). Previously
                // the old FTS row ghosted forever (search hits deep-linking to
                // a deleted header id) and the new id was invisible to search.
                ftsRekeys.append((oldId: oldId, newId: newId, newMessageId: newMsgId))
                // Only UID-scoped providers publish this weak mapping into an
                // active view. Date-window providers (notably Graph) use opaque
                // actionable ids, so RFC correlation must not immediately turn
                // an arbitrary duplicate Message-ID match into UI action state.
                // Their durable/FTS repair remains unchanged and a normal reload
                // converges from GRDB.
                if windowMode == .uid {
                    headerRekeys.append(HeaderRekeyRecord(
                        oldHeaderId: oldId,
                        newHeaderId: newId,
                        newProviderMessageId: newMsgId,
                        carriesProviderAuthority: false))
                }
                uidMigratedRemoteIds.insert(newMsgId)
                uidMigratedOldMsgIds.append(staleMsg.messageId)
            }

            let uidMigratedSet = Set(uidMigratedOldMsgIds)
            // Absence from the server is no evidence against a draft that never
            // reached it (#519): its placeholder header is the only row the draft
            // opens from. Read inside this transaction, like the pending ops.
            let neverUploadedDraftIds: Set<String>
            if stale.contains(where: { isSyntheticPlaceholderId($0.messageId) }) {
                neverUploadedDraftIds = try Self.neverUploadedDraftPlaceholderIds(accountId: accountId, db: db)
            } else {
                neverUploadedDraftIds = []
            }
            if DebugModeManager.isLoggingEnabled() {
                let kept = stale.filter { neverUploadedDraftIds.contains($0.messageId) }
                if !kept.isEmpty {
                    print("[Sync] \(folder.name): keeping \(kept.count) never-uploaded draft placeholder(s): \(kept.map(\.messageId))")
                }
            }
            let isProtected: (MessageHeader) -> Bool = { msg in
                protectedIds.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId) ||
                recentlyCompleted[msg.messageId] != nil ||
                (msg.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false) ||
                (msg.rfc822MessageId.map { outboxProtectedRfc822s.contains($0) } ?? false) ||
                neverUploadedDraftIds.contains(msg.messageId)
            }
            let staleFiltered = stale.filter { !isProtected($0) && !uidMigratedSet.contains($0.messageId) }
            // Append, never assign — re-keyed old ids ride ftsRekeys (the FTS
            // entry MOVES, it must not be removed), but staleIds may already
            // carry entries from earlier loop passes and the canonicalizer in
            // the upsert loop appends merge-loser ids later. An assignment
            // here would clobber the accumulation contract.
            staleIds.append(contentsOf: staleFiltered.map(\.id))
            for msg in staleFiltered {
                if folder.role == .drafts || folder.role == .sent {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] DraftStaleDelete: removing \(msg.id) msgId=\(msg.messageId) rfc822=\(msg.rfc822MessageId ?? "nil") snippet=\(String(msg.snippet.prefix(60)))")
                    }
                }
                try msg.delete(db)
            }
            if !staleFiltered.isEmpty {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] \(folder.name): removed \(staleFiltered.count) stale messages")
                }
            }

            // Insert new / update existing.
            // Skip messages with pending destructive ops or recently completed ops —
            // prevents re-inserting optimistically removed messages or overwriting flags
            // during the gap between PendingOp deletion and server propagation.
            let skippedByPending = messages.filter { isPendingDestructive($0) }
            let skippedByRecent = messages.filter { isRecentlyCompleted($0) && !isPendingDestructive($0) }
            let skippedByPendingIds = Set(skippedByPending.map(\.messageId))
            let skippedByRecentIds = Set(skippedByRecent.map(\.messageId))
            // IOS-IMAP-001 / D3 — the other half of "not present for display".
            // Subtracting the id from `remoteIds` above lets the stale channel
            // REMOVE a row that already exists (inheriting its pending/recent/outbox
            // protections and its FTS cleanup); this stops the upsert loop
            // RE-CREATING it in the same transaction, and stops a first sighting
            // ever materialising one. No server-side operation is issued for either.
            let allSkippedIds = skippedByPendingIds
                .union(skippedByRecentIds)
                .union(deletedRemoteIds)
            if !deletedRemoteIds.isEmpty {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] \(folder.name): \(deletedRemoteIds.count) remote message(s) carry \\Deleted — not presented (IOS-IMAP-001)")
                }
            }
            if !skippedByPendingIds.isEmpty {
                if DebugModeManager.isLoggingEnabled() {
                    print("[MoveTrace] fullSync \(folder.name) — skipping upsert for \(skippedByPendingIds.count) msgs with pending destructive ops: \(skippedByPendingIds)")
                }
            }
            if !skippedByRecentIds.isEmpty {
                if DebugModeManager.isLoggingEnabled() {
                    print("[MoveTrace] fullSync \(folder.name) — skipping upsert for \(skippedByRecentIds.count) msgs recently completed: \(skippedByRecentIds)")
                }
            }
            // DIAGNOSTIC (emitted as a debug-gated mark before this closure returns):
            // per-folder upsert churn. `noop` = existing rows whose server data did NOT
            // actually change — the redundant UPDATEs that churned the WAL on every full
            // sync before the change-detection (updateChanges) below was added.
            var upsUpdated = 0, upsNoop = 0, upsDraftSentSkip = 0
            // DIAGNOSTIC: pinpoint the residual multi-second per-folder write (boot_logs
            // 6: Sent Messages 50 msg / 3.3s, cpu-bound). `loop` = total upsert-loop wall
            // time; `recon` = time in the per-message existence lookup
            // (canonicalizeLocalRows / drafts-sent fetchOne). If loop≈writeMs the loop is
            // the cost; if recon≈loop the lookup is (planner not using the index on-device
            // despite DatabaseIndexTests); else the cost is the mutation side (updateChanges
            // / FTS / AI cache) or pre-loop stale processing (loop ≪ writeMs).
            var upsReconSeconds = 0.0
            let upsLoopT0 = CFAbsoluteTimeGetCurrent()
            for info in messages where !allSkippedIds.contains(info.messageId) && !uidMigratedRemoteIds.contains(info.messageId) {
                // Canonicalize PKs + merge duplicate rows (optimistic-move
                // remnants keep their old "accountId:<oldPath>:<msgId>" PK
                // forever for stable-id providers — see canonicalizeLocalRows).
                // Drafts/Sent are exempt: DraftStore's push migration manages
                // their row identity.
                let reconT0 = CFAbsoluteTimeGetCurrent()
                // RFC identity remains metadata/corroboration only. Provider-
                // address ownership is decided from the bound fetch provenance.
                let normalizedIncomingRfc822 = Self.normalizedRfc822Identity(info.rfc822MessageId)
                let recon: (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?, sourceAddressProven: Bool)
                if folder.role == .drafts || folder.role == .sent {
                    let row = try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                        .fetchOne(db)
                    let canonicalId = MessageIdentity.headerId(
                        accountId: accountId, folderPath: folderPath, messageId: info.messageId)
                    let sourceAddressProven = row.map {
                        Self.providerAddressOwnershipProven(
                            row: $0, accountId: accountId, folderPath: folderPath,
                            folderId: folderId, messageId: info.messageId,
                            canonicalId: canonicalId, windowMode: windowMode,
                            sourceBoundEpoch: sourceBoundEpoch)
                    } ?? false
                    recon = (row, [], nil, sourceAddressProven)
                } else {
                    recon = try Self.canonicalizeLocalRows(
                        accountId: accountId, folderPath: folderPath,
                        folderId: folderId, messageId: info.messageId,
                        isInInbox: isInInbox,
                        windowMode: windowMode,
                        sourceBoundEpoch: sourceBoundEpoch,
                        incomingRfc822Identity: normalizedIncomingRfc822, db: db
                    )
                }
                upsReconSeconds += CFAbsoluteTimeGetCurrent() - reconT0
                if !recon.removedIds.isEmpty {
                    staleIds.append(contentsOf: recon.removedIds)
                }
                if let rekey = recon.ftsRekey {
                    // FTS entry moves to the new id in place — body text and
                    // embedding ride along. messageId is unchanged here.
                    ftsRekeys.append((oldId: rekey.oldId, newId: rekey.newId, newMessageId: nil))
                }
                if var existing = recon.row {
                    // Pre-mutation snapshot so the write below can be SKIPPED when the
                    // server data changed nothing (change-detection — see updateChanges).
                    let original = existing
                    // Drafts/Sent special case: the server's drafts.list / equivalent
                    // summary metadata (date, snippet, to, rfc822) lags behind the
                    // actual message resource right after a local push. We already
                    // merged our fresh local content into this row via
                    // DraftStore.pushDraftToServer's migration step — let that
                    // be the source of truth. Overwriting here snaps date/from/to
                    // back to the server's stale view ("time snaps back" bug).
                    // Inserts and deletions for drafts still flow through sync
                    // normally via the dedup + stale-check paths above; this guard
                    // only prevents destructive metadata refresh on existing rows.
                    if folder.role == .drafts || folder.role == .sent {
                        // Preserve local drafts/sent content — the server's drafts.list /
                        // summary metadata lags behind the real message right after a local
                        // push. Counted in `upsDraftSentSkip`, reported in the aggregate
                        // `fullSync upsert[...]` mark below.
                        //
                        // NO per-message log here: it fired ~50×/full-sync INSIDE the write
                        // transaction. Even debug-gated, when logging was ON each print cost
                        // ~80ms of (stdout→file) I/O — measured loop=4130ms vs recon=11ms for
                        // a 50-skip Sent sync (boot/logmain 2026-07-06), i.e. ~4s of the
                        // single GRDB writer held per Sent sync, plus hundreds of piled log
                        // lines. The aggregate count is the diagnostic; the per-id detail
                        // isn't worth holding the writer.
                        existing.observedUidValidity = recon.sourceAddressProven ? sourceBoundEpoch : nil
                        if try existing.updateChanges(db, from: original) {
                            upsUpdated += 1
                        }
                        upsDraftSentSkip += 1
                        continue
                    }
                    // The v2final fail-closed branch is retained, but its RFC
                    // discriminator is SUBTRACTED. Only the provider-native
                    // proof computed before canonicalization can authorize any
                    // incoming field merge.
                    guard recon.sourceAddressProven else {
                        existing.observedUidValidity = nil
                        _ = try existing.updateChanges(db, from: original)
                        BackgroundSyncLogger.log("[Sync] merge REFUSED for \(existing.id) (folder=\(folderPath)) — provider-address ownership is unproven; message fields stay untouched and the source observation stamp is cleared")
                        upsNoop += 1
                        continue
                    }
                    existing.observedUidValidity = sourceBoundEpoch

                    // Update existing message with latest data from server.
                    // Skip flag/tag overwrites if message has pending queue ops OR
                    // recently completed ops (server may lag behind the executed change).
                    let hasPendingFlags = isPendingFlag(info) || isRecentlyCompleted(info)
                    if !hasPendingFlags {
                        existing.isRead = info.isRead
                        existing.isFlagged = info.isFlagged
                        if isInInbox, let serverTag = info.actionTag {
                            if existing.actionTag != serverTag {
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Sync] Remote tag change detected for \(info.messageId): \(existing.actionTag?.rawValue ?? "nil") -> \(serverTag.rawValue)")
                                }
                                try MessageAICache.writeThrough(
                                    accountId: accountId,
                                    folderPath: folderPath,
                                    rfc822MessageId: existing.rfc822MessageId,
                                    actionTag: serverTag,
                                    db: db
                                )
                            }
                            existing.actionTag = serverTag
                            existing.tagSortOrder = serverTag.sortOrder
                        }
                    }
                    existing.date = info.date
                    existing.providerDate = info.providerOrderDate
                    existing.from = info.from
                    existing.fromAddress = info.fromAddress
                    existing.to = info.to
                    existing.cc = info.cc
                    existing.bcc = info.bcc
                    existing.replyTo = info.replyTo
                    // Preserve locally-set replied/forwarded state — providers may not
                    // support these flags (Gmail REST API always returns false).
                    // Only upgrade from false→true, never downgrade.
                    existing.isReplied = existing.isReplied || info.isReplied
                    existing.isForwarded = existing.isForwarded || info.isForwarded
                    // RFC Message-ID is metadata/corroboration, not address
                    // authority. A nil incoming value carries no metadata signal
                    // and must never NULL a stored value.
                    if normalizedIncomingRfc822 != nil {
                        existing.rfc822MessageId = info.rfc822MessageId
                        existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                    }
                    // ReplyDetect: if message is replied (server or local) and has reply tag, override to none
                    // AI cache keeps original LLM value — only MessageHeader + IMAP tag change
                    if existing.isReplied && existing.actionTag == .reply {
                        existing.actionTag = ActionTag.none
                        existing.tagSortOrder = ActionTag.none.sortOrder
                        var tagOp = PendingOperation(
                            type: .setTag,
                            messageIds: [existing.stableId],
                            accountId: accountId,
                            folderPath: folderPath,
                            tagValue: ActionTag.none.rawValue
                        )
                        try tagOp.insert(db)
                        replyDetectIds.append(existing.id)
                        if DebugModeManager.isLoggingEnabled() {
                            print("[ReplyDetect] Sync update: reply→none for \(info.messageId) (already replied)")
                        }
                    }
                    // Change-detection: write ONLY when the server actually changed a
                    // column. The old unconditional `existing.update(db)` rewrote every
                    // existing row on every full sync (e.g. Archive: 50 rows × N syncs of
                    // no-op writes) — pure WAL churn. `updateChanges(from:)` is
                    // end-state-identical but skips the write (and returns false) when
                    // nothing differs.
                    if try existing.updateChanges(db, from: original) {
                        upsUpdated += 1
                    } else {
                        upsNoop += 1
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
                // Action tags are inbox-scoped — only apply server tags for inbox messages.
                if isInInbox {
                    header.actionTag = info.actionTag
                    header.tagSortOrder = info.actionTag?.sortOrder ?? 99
                }
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
                    replyDetectIds.append(header.id)
                    if DebugModeManager.isLoggingEnabled() {
                        print("[ReplyDetect] Sync insert: reply→none for \(header.messageId) (already replied)")
                    }
                }
                // Dedup by rfc822MessageId in Drafts/Sent folders: optimistic creation
                // inserts a placeholder MessageHeader before the IMAP UID is known. When
                // sync returns the real UID, match by rfc822MessageId and update in place
                // to prevent duplicate rows.
                if (folder.role == .drafts || folder.role == .sent),
                   let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
                   let optimistic = try MessageHeader.fetchOne(
                    db, sql: Self.optimisticDedupSQL,
                    arguments: [folderId, rfc822, header.messageId]) {
                    let oldId = optimistic.id
                    // RFC-only placeholder adoption is not native ownership.
                    header.observedUidValidity = nil
                    // Capture body for migration — defer insert until after header (FK constraint)
                    var deferredBody: MessageBody?
                    if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
                        var newBody = body
                        newBody.id = ContentKey(rawValue: header.id)
                        try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
                        deferredBody = newBody
                    }
                    // MessageAICache uses composite key, not headerId — unlikely for drafts
                    // but clean up if present. Shared-helper keys so any drift between
                    // writers (NSE, sync, device-sync peer) surfaces at compile time.
                    let cacheKey = MessageIdentity.aiCacheKey(
                        accountId: accountId, folderPath: folderPath,
                        rfc822MessageId: optimistic.rfc822MessageId
                    )
                    let newCacheKey = MessageIdentity.aiCacheKey(
                        accountId: accountId, folderPath: folderPath,
                        rfc822MessageId: header.rfc822MessageId
                    )
                    if let cacheKey, let newCacheKey, cacheKey != newCacheKey,
                       try MessageAICache.fetchOne(db, key: cacheKey) != nil {
                        try db.execute(sql: "UPDATE messageAICache SET key = ? WHERE key = ?", arguments: [newCacheKey, cacheKey])
                    }
                    try optimistic.delete(db)
                    guard try MessageHeader.fetchOne(db, key: header.id) == nil else {
                        if folder.role == .drafts || folder.role == .sent {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Sync] DraftDedup: SKIPPING insert for id=\(header.id) — already exists (post-snapshot). remoteSnippet=\(String(header.snippet.prefix(60)))")
                            }
                        } else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Sync] Dedup: SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                            }
                        }
                        // R16-8 — THE REMOVAL CHANNEL, because this leg discards
                        // rather than migrates. `optimistic` is already deleted and
                        // `deferredBody` is never inserted, so `oldId` names content
                        // that no longer exists; without this it rode NEITHER
                        // `ftsRekeys` nor `staleIds` and left a permanent FTS orphan.
                        staleIds.append(oldId)
                        continue
                    }
                    try header.insert(db)
                    if let body = deferredBody { try body.insert(db) }
                    // R16-8 — THE RE-KEY CHANNEL. The body (and with it the indexed
                    // text and its embedding) was CARRIED to `header.id`, so the FTS
                    // entry must MOVE, not be removed. This block ends in `continue`,
                    // which bypasses every shared disposition below, so the old id
                    // has to be routed here explicitly — the UID-remap carrier in
                    // this same function already does exactly this, which is what
                    // made these two blocks unswept MEMBERS rather than a whole-path
                    // omission. ⚠️ Not a "the next sync repairs it" case: the
                    // compensating sweep `pruneFTSOrphans` has ONE production caller,
                    // `oneTimeFTSReconciliation`, gated on a `UserDefaults` flag it
                    // sets on first success with no production reset — so it
                    // provably cannot run again (`MIS-024`).
                    ftsRekeys.append((oldId: oldId, newId: header.id, newMessageId: header.messageId))
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    // Insert user label associations
                    for labelId in info.userLabelIds {
                        let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
                        try labelRow.insert(db, onConflict: .ignore)
                        // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                        // the bare provider value (D10 / `IOS-LABEL-001`).
                        try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                    insertedIds.append(header.id)
                    if folder.role == .drafts || folder.role == .sent {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Sync] DraftDedup: replaced optimistic \(folder.role.rawValue) header \(oldId) → \(header.id) | oldSnippet=\(String(optimistic.snippet.prefix(60))) | newSnippet=\(String(header.snippet.prefix(60)))")
                        }
                    } else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Sync] Dedup: replaced optimistic \(folder.role == .drafts ? "draft" : "sent") header \(oldId) with \(header.id)")
                        }
                    }
                    continue
                }

                // Pre-sync reclaim: if NSE (or any other writer) inserted this
                // message's inbox row with a different folderPath/folderId than
                // what sync is about to use, we want to keep the AI work and
                // migrate it — not create a duplicate row. Find any existing
                // inbox row for this (accountId, messageId) and migrate it to
                // the new identity before falling through to the insert. Scope
                // to `isInInbox=true` so Gmail's label system (same messageId
                // under multiple folder-labels) still produces one row per
                // folder — only the inbox row is reclaimed here.
                //
                // This is the safety net for bug 2c: even if upstream capture
                // of folderPath drifts in the future, sync converges on one
                // row per message.
                if isInInbox {
                    // fetchAll not fetchOne: if a bug elsewhere produced two
                    // inbox rows for the same (accountId, messageId), we want
                    // to clean up BOTH — using fetchOne would migrate one and
                    // leave the other orphaned, compounding the drift.
                    let preSyncRowsAll = try MessageHeader
                        .filter(Column("accountId") == accountId)
                        .filter(Column("messageId") == info.messageId)
                        .filter(Column("isInInbox") == true)
                        .filter(Column("id") != header.id)
                        .fetchAll(db)
                    // R15-F1 identity gate — sibling of the one in
                    // `canonicalizeLocalRows` (see its parameter doc). This
                    // reclaim exists for folderPath-drift duplicates of the SAME
                    // message (NSE writer drift); its bare
                    // (accountId, messageId, isInInbox) match also catches a
                    // DIFFERENT message optimistically moved INTO the inbox whose
                    // source-folder UID coincides — the first such row is DELETED
                    // below (`try preSync.delete(db)`) and any tail rows are
                    // deleted outright, so an ungated match drops the user's moved
                    // message and grafts its AI state onto the incoming one.
                    // Exclude rows whose stored identity provably differs; with a
                    // nil incoming identity and conflicting stored identities,
                    // refuse the whole reclaim (no discriminating signal — the next
                    // identity-carrying pass discriminates). An empty result is not
                    // a dead end: control falls through to the orphan/insert path,
                    // which stores the incoming message normally.
                    let preSyncRows: [MessageHeader]
                    if let incoming = normalizedIncomingRfc822 {
                        preSyncRows = preSyncRowsAll.filter { row in
                            let stored = Self.normalizedRfc822Identity(row.rfc822MessageId)
                            return stored == nil || stored == incoming
                        }
                        if preSyncRows.count != preSyncRowsAll.count {
                            // Ungated per CLAUDE.md rule 12 exception (b).
                            BackgroundSyncLogger.log("[Sync] ERROR: pre-sync inbox reclaim identity gate at (accountId=\(accountId), msgId=\(info.messageId)) excluded \(preSyncRowsAll.count - preSyncRows.count) row(s) whose stored rfc822MessageId differs from the incoming identity (R15-F1)")
                        }
                    } else {
                        let distinctNonNil = Set(preSyncRowsAll.compactMap { Self.normalizedRfc822Identity($0.rfc822MessageId) })
                        if distinctNonNil.count > 1 {
                            BackgroundSyncLogger.log("[Sync] ERROR: pre-sync inbox reclaim at (accountId=\(accountId), msgId=\(info.messageId)) found \(distinctNonNil.count) distinct stored identities with a NIL incoming identity — refusing the reclaim (R15-F1)")
                            preSyncRows = []
                        } else {
                            preSyncRows = preSyncRowsAll
                        }
                    }
                    if preSyncRows.count > 1 {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Sync] Pre-sync reclaim: \(preSyncRows.count) matching inbox rows for \(info.messageId) — merging all")
                        }
                    }
                    if let preSync = preSyncRows.first {
                    let oldId = preSync.id
                    // Account/message reclaim is not a folder-native PK proof.
                    header.observedUidValidity = nil
                    // Preserve locally-computed AI work — sync has no actionTag
                    // / summaryBlurb / reminder fields for Outlook (Graph does
                    // not store them) and for Gmail they arrive via provider
                    // labels only, so unconditionally preferring preSync's
                    // fields when header's are nil keeps NSE's output.
                    if header.actionTag == nil, let tag = preSync.actionTag {
                        header.actionTag = tag
                        header.tagSortOrder = tag.sortOrder
                    }
                    if header.summaryBlurb == nil {
                        header.summaryBlurb = preSync.summaryBlurb
                        header.summaryTodos = preSync.summaryTodos
                        header.reminderDate = preSync.reminderDate
                        header.reminderTime = preSync.reminderTime
                        header.reminderContent = preSync.reminderContent
                    }
                    if header.cachedReply == nil { header.cachedReply = preSync.cachedReply }
                    header.notified = header.notified || preSync.notified
                    // Migrate MessageBody (FK to old id) before delete.
                    var deferredBody: MessageBody?
                    if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
                        var newBody = body
                        newBody.id = ContentKey(rawValue: header.id)
                        try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
                        deferredBody = newBody
                    }
                    // Migrate AI cache key (folderPath changed → key changed).
                    let oldCacheKey = MessageIdentity.aiCacheKey(
                        accountId: accountId, folderPath: preSync.folderPath,
                        rfc822MessageId: preSync.rfc822MessageId
                    )
                    let newCacheKey = MessageIdentity.aiCacheKey(
                        accountId: accountId, folderPath: folderPath,
                        rfc822MessageId: header.rfc822MessageId
                    )
                    if let oldCacheKey, let newCacheKey, oldCacheKey != newCacheKey,
                       try MessageAICache.fetchOne(db, key: oldCacheKey) != nil {
                        try db.execute(
                            sql: "UPDATE messageAICache SET key = ? WHERE key = ?",
                            arguments: [newCacheKey, oldCacheKey]
                        )
                    }
                    // Keep the reclaimed row's durable identity when the incoming
                    // envelope carries none. `header.rfc822MessageId` came from
                    // `info.rfc822MessageId`, which is nil whenever the envelope has
                    // no Message-ID — so without this the reclaim NULLs an identity
                    // the local row already held, flipping `MessageHeader.stableId`
                    // to the bare UID and re-admitting bare-UID gestures against a
                    // message that had a durable id a moment earlier. This is the
                    // same assign/keep rule already applied at the `existing` merge
                    // branch and at the orphan reclaim.
                    if normalizedIncomingRfc822 == nil { header.rfc822MessageId = preSync.rfc822MessageId }
                    try preSync.delete(db)
                    try header.insert(db)
                    if let body = deferredBody { try body.insert(db) }
                    // R16-8 — THE RE-KEY CHANNEL, same reason as the DraftDedup block
                    // above: the body is carried to `header.id`, this block ends in
                    // `continue`, and `pruneFTSOrphans` provably cannot run a second
                    // time. Without this the reclaimed row's indexed text stays filed
                    // under a header id that no longer exists.
                    ftsRekeys.append((oldId: oldId, newId: header.id, newMessageId: header.messageId))
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    for labelId in info.userLabelIds {
                        let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
                        try labelRow.insert(db, onConflict: .ignore)
                        // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                        // the bare provider value (D10 / `IOS-LABEL-001`).
                        try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                    // A NEW row under `header.id` (the pre-sync row was deleted
                    // above and re-inserted here), so it is an insert for the
                    // diagnostic even though the log line below says "reclaimed".
                    insertedIds.append(header.id)
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] Reclaimed pre-sync inbox row \(oldId) → \(header.id) (folderPath drift, preserved AI)")
                    }
                    // Clean up any additional duplicates — their AI fields
                    // already merged via the fetchAll scan isn't worth doing
                    // (the first row won the preservation race; the tail are
                    // stale dupes). Just delete to prevent orphaned cache
                    // rows / body rows sticking around after reclaim.
                    for extra in preSyncRows.dropFirst() {
                        let extraId = extra.id
                        if let oldCacheKey = MessageIdentity.aiCacheKey(
                            accountId: accountId, folderPath: extra.folderPath,
                            rfc822MessageId: extra.rfc822MessageId
                        ) {
                            try db.execute(
                                sql: "DELETE FROM messageAICache WHERE key = ?",
                                arguments: [oldCacheKey]
                            )
                        }
                        try MessageBody.deleteOne(db, key: extraId)
                        try extra.delete(db)
                        // R16-8 — THE REMOVAL CHANNEL. These tail duplicates are
                        // DELETED, not migrated, so their FTS entries must go with
                        // them. Third member of the same class as the two re-key
                        // legs: enumerated by *"a header row this block destroys or
                        // re-keys"*, not by *"a block that re-keys"*.
                        staleIds.append(extraId)
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Sync] Pre-sync reclaim: removed duplicate inbox row \(extraId)")
                        }
                    }
                    continue
                    }  // closes `if let preSync`
                }  // closes `if isInInbox`

                // Check for orphaned row: same id (accountId:folderPath:messageId) but
                // different folderId — left behind by a no-op optimistic move (e.g., archive
                // from All Mail on Gmail). Reclaim by updating in place to preserve
                // MessageBody and MessageAICache FK references.
                if var orphaned = try MessageHeader.fetchOne(db, key: header.id) {
                    // Respect pending user intention — if this row is queued for
                    // a destructive op, the optimistic folderPath is authoritative.
                    // Without this guard, a delta/full sync that sees the message
                    // still in the source folder (server lag) would silently undo
                    // the user's move. Uses the two-key check because pending ops
                    // key by stableId (rfc822 for IMAP, messageId for Gmail/Exchange).
                    let orphanIsPending = pendingDestructiveIds.containsAnyKey(
                        messageId: orphaned.messageId,
                        rfc822MessageId: orphaned.rfc822MessageId
                    )
                    if orphanIsPending {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[MoveTrace] fullSync — SKIPPING orphan reclaim for \(orphaned.id) — pending destructive op (server folder=\(folder.name) but user moved locally)")
                        }
                        continue
                    }
                    // The v2final orphan-reclaim fail-closed shape remains, but
                    // RFC agreement is no longer authority. An IMAP row whose
                    // membership moved away from this folder cannot prove this
                    // folder-native address, even when the RFC ids agree.
                    let orphanOriginal = orphaned
                    guard Self.providerAddressOwnershipProven(
                        row: orphaned, accountId: accountId,
                        folderPath: folderPath, folderId: folderId,
                        messageId: header.messageId, canonicalId: header.id,
                        windowMode: windowMode,
                        sourceBoundEpoch: sourceBoundEpoch
                    ) else {
                        orphaned.observedUidValidity = nil
                        _ = try orphaned.updateChanges(db, from: orphanOriginal)
                        BackgroundSyncLogger.log("[Sync] orphan reclaim REFUSED for \(orphaned.id) (folder=\(folderPath), survivor folderId=\(orphaned.folderId)) — provider-address ownership is unproven")
                        continue
                    }
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] Reclaiming orphaned row \(header.id): folderId \(orphaned.folderId) → \(folderId)")
                    }
                    orphaned.folderId = folderId
                    orphaned.folderPath = folderPath
                    // Cross-mailbox optimistic ownership is ambiguous until
                    // the destination sync proves a native address (T5.11).
                    orphaned.observedUidValidity = nil
                    orphaned.isInInbox = isInInbox
                    orphaned.messageId = header.messageId
                    orphaned.isRead = header.isRead
                    orphaned.isFlagged = header.isFlagged
                    orphaned.date = header.date
                    orphaned.providerDate = header.providerDate
                    orphaned.from = header.from
                    orphaned.fromAddress = header.fromAddress
                    orphaned.to = header.to
                    orphaned.cc = header.cc
                    orphaned.bcc = header.bcc
                    orphaned.replyTo = header.replyTo
                    // RFC Message-ID is metadata only. A nil/empty incoming value
                    // carries no signal and must never NULL the stored one.
                    if normalizedIncomingRfc822 != nil {
                        orphaned.rfc822MessageId = header.rfc822MessageId
                    }
                    orphaned.isReplied = orphaned.isReplied || header.isReplied
                    orphaned.isForwarded = orphaned.isForwarded || header.isForwarded
                    orphaned.subject = header.subject
                    orphaned.snippet = header.snippet
                    orphaned.hasAttachments = header.hasAttachments
                    orphaned.actionTag = header.actionTag
                    orphaned.tagSortOrder = header.tagSortOrder
                    try orphaned.update(db)
                    // Update user label associations for reclaimed orphan
                    for labelId in info.userLabelIds {
                        let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
                        try labelRow.insert(db, onConflict: .ignore)
                        // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                        // the bare provider value (D10 / `IOS-LABEL-001`).
                        try MessageUserLabel(messageId: orphaned.id, userLabelId: labelRow.id)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(orphaned)
                    // In-place UPDATE of an existing row, never an insert.
                    reclaimedIds.append(orphaned.id)
                } else {
                    // Defensive — the pending-op filter above should have already
                    // skipped optimistic-move rows whose id PK collides with this
                    // header.id, but rfc822-nil remote info can still slip through
                    // (UID match fails when info has no rfc822). Skip rather than
                    // throw UNIQUE — sync converges on the next cycle.
                    guard try MessageHeader.fetchOne(db, key: header.id) == nil else {
                        if folder.role == .drafts {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Sync] DraftInsert: SKIPPED id=\(header.id) — already exists (remoteSnippet=\(String(header.snippet.prefix(60))))")
                            }
                        } else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[MoveTrace] fullSync — SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                            }
                        }
                        continue
                    }
                    try header.insert(db)
                    if folder.role == .drafts {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Sync] DraftInsert: INSERTED id=\(header.id) msgId=\(header.messageId) rfc822=\(header.rfc822MessageId ?? "nil") snippet=\(String(header.snippet.prefix(60)))")
                        }
                    }
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    // Insert user label associations
                    for labelId in info.userLabelIds {
                        let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
                        try labelRow.insert(db, onConflict: .ignore)
                        // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                        // the bare provider value (D10 / `IOS-LABEL-001`).
                        try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                    insertedIds.append(header.id)
                }
            }

            // Sent-folder reply discovery: a message in this batch is the user's
            // own reply (sent from another device); flip the parent's isReplied
            // locally. No-op when folder.role != .sent.
            let discoveredParents = try ReplyParentResolver.markParentsReplied(
                sentCopies: messages.map { .init(inReplyTo: $0.inReplyTo, subject: $0.subject) },
                folderRole: folder.role,
                accountId: accountId,
                db: db
            )
            replyDetectIds.append(contentsOf: discoveredParents)
            // A parent this pass inserted whose reply is already stored in Sent.
            replyDetectIds.append(contentsOf: try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                insertedRfc822Ids: newHeaders.compactMap(\.rfc822MessageId), accountId: accountId, db: db))

            // AI cache TTL touch removed from sync transaction — it was holding the
            // GRDB writer lock for 300+ row UPDATEs during every folder sync, blocking
            // MainActor user actions. TTL is now refreshed lazily after AI queue drains
            // (see ActiveAIQueue.onDrainComplete).

            // DIAGNOSTIC: per-folder upsert breakdown. `noop` should now dominate for
            // steady-state re-syncs (Archive/etc.) — it counts the redundant writes the
            // change-detection above eliminated. A stuck-high `upd` with unchanged mail
            // fingerprints an always-dirty column to normalize.
            var upsertLine: String?
            if upsUpdated + upsNoop + upsDraftSentSkip > 0 || !newHeaders.isEmpty {
                let loopMs = Int((CFAbsoluteTimeGetCurrent() - upsLoopT0) * 1000)
                BootProfiler.mark("fullSync upsert[\(folder.name)]: ins=\(newHeaders.count) upd=\(upsUpdated) noop=\(upsNoop) dsSkip=\(upsDraftSentSkip) stale=\(staleIds.count) loop=\(loopMs)ms recon=\(Int(upsReconSeconds * 1000))ms")
                // WHICH rows, not just how many. The `ins=` count above is exactly
                // what the reappearing-message investigation (`IOS-QUEUE-008`) had
                // and could not use: it proves a full sync inserted N rows but not
                // whether the message the user had just deleted was one of them.
                // Two segments, ALWAYS both, so a reader never wonders whether one
                // was omitted: `inserted` lists the rows this pass INSERTED
                // (`insertedIds`) and `reclaimed` lists the existing rows it
                // re-homed into this folder in place (`reclaimedIds`, the
                // orphan-reclaim arm) — for `IOS-QUEUE-008` the MORE interesting
                // event, a locally moved row the server disagreed with, reported
                // as what it is rather than as an insert (R4-RS-1).
                // Debug-gated and file-backed on `.queue`, so it interleaves with
                // the drain's `queueLog` lines in the one `tabmail.log` and
                // `AppLogStore.read(channel: .queue)` returns both halves in append
                // order. ⚠️ NOT on the always-on `.sync` channel: one channel may
                // carry only one lifetime policy (memory topic 122, `IOS-LOG-002`).
                // A no-op unless debug logging is unlocked by an allowed user — it
                // IS active on device / TestFlight for such a user, which is the
                // point (global `CLAUDE.md` rule 12).
                //
                // RENDERED here, EMITTED only after `dbPool.write` has returned —
                // see the `logQueue` call below the closure. `AppLogStore.append`
                // enqueues file I/O that no SQLite ROLLBACK can retract, so a line
                // written from inside the transaction would survive a COMMIT
                // failure (I/O error, full disk) and name ids for rows that never
                // became durable. The line therefore rides the closure's return
                // tuple, nil when the pass emits nothing, and a thrown write never
                // reaches the emission at all. The rendering is a pure static
                // function so BOTH its branches can be unit-tested; it is cheap
                // (two capped joins), and `logQueue` still checks the gate, so a
                // closed gate still writes nothing.
                upsertLine = "[MoveTrace] fullSync upsert[\(folder.name)] — "
                    + SyncEngine.upsertInsertedIdSummary(insertedIds)
                    + " | "
                    + SyncEngine.upsertInsertedIdSummary(reclaimedIds, verb: "reclaimed")
            }
            // The folder's counters, from this listing's own selection and only
            // from it, in the transaction that wrote what the listing saw
            // (ADR-IOS-051 amendment: one writer of folder counters). A listing
            // that proved nothing carries none and writes none.
            let counters = provedWindow ? coverage.counters : nil
            if let counters {
                try Self.writeListingCounters(counters, folderId: folderId, db: db)
                // The count check this listing's count asks for is owed from the
                // moment the count is stored, whoever ran the listing (an
                // on-demand refresh runs no phase 2 of its own): committed with
                // the counters, so a later STATUS that matches them still lists
                // the folder until a finished walk clears it (#755).
                try Self.armListingDueIfHeldExceeds(counters.messageCount, folderId: folderId, db: db)
            }
            return (newHeaders, staleIds, replyDetectIds, uidMigratedOldMsgIds, ftsRekeys, headerRekeys, upsertLine, counters, true)
        }
        let writeMs = Int((CFAbsoluteTimeGetCurrent() - writeStart) * 1000)
        if writeMs > 30 {
            BootProfiler.mark("fullSync write[\(folder.name)]: \(messages.count) msg in \(writeMs)ms")
        }
        // Reached only when the write above COMMITTED: a rolled-back pass throws
        // past this point and reports nothing (R4-RS-1).
        if let upsertLine = syncResult.upsertLine {
            BackgroundSyncLogger.logQueue(upsertLine)
        }

        return SyncMessagesResult(
            newHeaders: syncResult.newHeaders,
            staleIds: syncResult.staleIds,
            replyDetectIds: syncResult.replyDetectIds,
            uidMigratedOldIds: syncResult.uidMigratedOldIds,
            ftsRekeys: syncResult.ftsRekeys,
            headerRekeys: syncResult.headerRekeys,
            listedCounters: syncResult.counters,
            proven: syncResult.merged && provedWindow,
            notListable: coverage.notListable
        )
    }

    /// A folder listing's outcome, classified in one place (`runListing`) by
    /// this pass's server answer (ADR-IOS-111):
    /// - `proven`: the listing proved its window; its counters, sweep and count
    ///   are the folder's this pass.
    /// - `notListable`: the server refused the folder (typed SELECT refusal) or
    ///   its SELECT sent no usable EXISTS. Nothing written; the stamp is allowed.
    /// - `unproven`: anything else after the listing started, a short FETCH, a
    ///   contradicted EXISTS 0, any error after SELECT. Nothing written; the
    ///   stamp is withheld. `connectionLost` lets the caller retry once.
    /// No error escapes the classifier, so no caller can rethrow past it.
    /// `runSyncMessages` found the folder's row gone before reading the server.
    struct FolderGoneBeforeListing: Error {}

    enum ListingOutcome: Sendable {
        case proven(SyncMessagesResult)
        /// The folder's row was gone before the listing read the server: nothing
        /// was read or written, and the folder owes nothing.
        case folderGone
        case notListable(SyncMessagesResult?)
        /// `error` is the listing's own error, when it ended with one, so a
        /// caller that shows errors (pull-to-refresh) can show the same one.
        case unproven(SyncMessagesResult?, connectionLost: Bool, error: (any Error)?)

        /// The merge result, when the listing got as far as its write (returned
        /// records are merged as positive records even when unproven).
        var result: SyncMessagesResult? {
            switch self {
            case .proven(let r): r
            case .notListable(let r): r
            case .unproven(let r, _, _): r
            case .folderGone: nil
            }
        }
    }

    /// The one classifier of a folder listing. Never throws: a cancelled pass
    /// reads as unproven here and the caller checks cancellation itself.
    nonisolated static func runListing(
        for folder: Folder, provider: any EmailProvider, limit: Int, dbPool: PrioritizedDatabase,
        bound: ListingRequestBound? = nil
    ) async -> ListingOutcome {
        do {
            let result = try await runSyncMessages(for: folder, provider: provider, limit: limit, dbPool: dbPool, bound: bound)
            if result.proven { return .proven(result) }
            return result.notListable ? .notListable(result) : .unproven(result, connectionLost: false, error: nil)
        } catch is FolderGoneBeforeListing {
            return .folderGone
        } catch is ProviderFolderNotListable {
            return .notListable(nil)
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[Listing] \(folder.name) unproven: \(error)")
            }
            return .unproven(nil, connectionLost: isConnectionError(error), error: error)
        }
    }

    /// Record a classified outcome in the full sync's listing.
    nonisolated static func record(_ outcome: ListingOutcome, folderId: String, in listing: inout FullSyncListing) {
        switch outcome {
        case .proven(let result):
            listing.listedFolderIds.insert(folderId)
            listing.listedCounts[folderId] = result.listedCounters?.messageCount
        case .notListable:
            listing.notListableFolderIds.insert(folderId)
        case .unproven:
            listing.droppedFolder = true
            oweDeepListing(folderId: folderId)
        case .folderGone:
            break
        }
    }

    /// A listing that proved nothing (a short or failed one, the deep pass's
    /// included) owes the folder a deep pass: the next full sync lists it
    /// whatever its counters say, never skips it on the MODSEQ (#755).
    nonisolated static func oweDeepListing(folderId: String) {
        fullSyncSkipStreak.withLock { streak in
            streak[folderId] = max(0, SyncConfig.fullSyncDeepEveryN - 1)
        }
    }

    /// Did this listing see every record its selection said its window holds?
    /// A positive count answered by a short or empty FETCH proves nothing: it
    /// never counts as the folder's listing, so it certifies no change baseline
    /// and drives no count-driven removal check. A provider whose listing
    /// reports no counters proves its window by any coverage other than
    /// `.unproven`.
    nonisolated static func listingProvedItsWindow(_ coverage: FetchCoverage, limit: Int) -> Bool {
        guard coverage != .unproven, !coverage.notListable else { return false }
        guard let counters = coverage.counters else { return true }
        return coverage.serverRecordCount >= min(counters.messageCount, limit)
    }

    /// The other half of the one writer of folder counters: invalidation. A
    /// reset, an epoch purge or a clean data reset forgets the listing's tuple
    /// here (UIDNEXT and MODSEQ cleared, so no STATUS can match it and no MODSEQ
    /// skip can fire; the count set to 0 when `resettingCount`), never by
    /// writing the columns itself.
    nonisolated static func invalidateListingCounters(_ folders: QueryInterfaceRequest<Folder>, resettingCount: Bool, db: Database) throws {
        var assignments: [ColumnAssignment] = [
            Column("lastKnownUidNext").set(to: nil as Int?),
            Column("lastKnownHighestModSeq").set(to: nil as Int?),
        ]
        if resettingCount { assignments.append(Column("totalCount").set(to: 0)) }
        _ = try folders.updateAll(db, assignments)
    }

    /// Mark the folder's count check owed (`FolderChangeState.listingDue`) when
    /// it holds more rows than `serverCount` beyond the reconcile tolerance.
    /// Never clears: only a finished walk does (`reconcileDeletionsAfterListing`).
    nonisolated static func armListingDueIfHeldExceeds(_ serverCount: Int, folderId: String, db: Database) throws {
        guard let accountId = try String.fetchOne(db, sql: "SELECT accountId FROM folder WHERE id = ?", arguments: [folderId]) else { return }
        let held = try heldServerRowCount(folderId: folderId, accountId: accountId, db: db)
        guard shouldReconcileDeletions(
            localCount: held, serverCount: serverCount, tolerance: SyncConfig.deletionReconcileCountTolerance) else { return }
        try markListingDue(folderId: folderId, db: db)
    }

    /// The rows a folder holds that the server can list: every row but the
    /// placeholders of local drafts that never reached the server
    /// (`neverUploadedDraftPlaceholderIds`). The count checks compare this with
    /// the server's count, as the walk only searches server UIDs: a local-only
    /// draft never makes a healthy folder look as if it held a ghost (#755).
    nonisolated static func heldServerRowCount(folderId: String, accountId: String, db: Database) throws -> Int {
        let held = MessageHeader.filter(Column("folderId") == folderId)
        let localOnly = try neverUploadedDraftPlaceholderIds(accountId: accountId, db: db)
        guard !localOnly.isEmpty else { return try held.fetchCount(db) }
        return try held.filter(!localOnly.contains(Column("messageId"))).fetchCount(db)
    }

    /// Mark an untracked folder's listing due under a fresh token.
    nonisolated static func markListingDue(folderId: String, db: Database) throws {
        guard let raw = try Row.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [folderId]) else { return }
        var state = FolderChangeState(raw: raw["changeState"])
        // A tracked folder's removals come from its change reader, which runs
        // no count check (ADR-IOS-051 phase 2 skips it). An already-due folder
        // is marked again: this listing's evidence is newer than any count
        // check still running, which then cannot clear it.
        guard !state.tracking else { return }
        state.markListingDue()
        try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folderId])
    }

    /// Write one folder's counters from the listing that observed them: the
    /// one writer of `totalCount`, `lastKnownUidNext` and `lastKnownHighestModSeq`
    /// (the change apply never writes them: a bookmark carries its own). A
    /// listing that proved no HIGHESTMODSEQ (CONDSTORE not on its connection, or
    /// NOMODSEQ) clears the stored one, so the MODSEQ skip cannot fire on a value
    /// no listing vouches for. The three are one tuple from one selection: an
    /// unreported UIDNEXT clears the stored one too, so a later STATUS never
    /// matches a mix of two listings' values.
    nonisolated static func writeListingCounters(_ counters: ListingCounters, folderId: String, db: Database) throws {
        _ = try Folder.filter(Column("id") == folderId).updateAll(db, [
            Column("totalCount").set(to: counters.messageCount),
            Column("lastKnownHighestModSeq").set(to: counters.highestModSeq),
            Column("lastKnownUidNext").set(to: counters.uidNext),
        ])
    }
}
