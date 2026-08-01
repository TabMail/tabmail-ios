/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

extension SyncEngine {

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

    /// Full-sync fetch-skip decision. Skip re-fetching a folder ONLY when CONDSTORE proves
    /// nothing changed since our last sync: HIGHESTMODSEQ (which RFC 7162 bumps on ANY
    /// add / delete / flag change) is present on BOTH sides and equal. NEVER skip the
    /// inbox (always fully synced), a deep pass, or a non-CONDSTORE folder (nil modseq →
    /// fetch, exactly today's behavior). Deletion safety is unaffected: MODSEQ gates only
    /// the FETCH (never a delete), and the deletion-reconcile check still runs for skipped
    /// folders. Pure + nonisolated for unit testing.
    nonisolated static func shouldSkipFolderFetch(
        role: FolderRole, freshModSeq: Int?, cachedModSeq: Int?, isDeepSync: Bool
    ) -> Bool {
        guard role != .inbox, !isDeepSync else { return false }
        guard let freshModSeq, let cachedModSeq else { return false }
        return freshModSeq == cachedModSeq
    }

    // MARK: - Full Sync

    func fullSync(account: Account, provider: any EmailProvider) async throws {
        let fs0 = CFAbsoluteTimeGetCurrent()
        let acctTag = "\(account.provider):\(account.id.prefix(6))"
        BootProfiler.mark("fullSync[\(acctTag)] START (network — fetch folders + inbox headers → populates inbox)")
        // Sync folder list
        let remoteFolders = try await provider.fetchFolders()
        print("[FullSync] \(account.emailAddress) fetchFolders: \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (\(remoteFolders.count) folders)")
        BootProfiler.mark("fullSync[\(acctTag)]: fetchFolders done in \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (\(remoteFolders.count) folders)")

        let pool = dbPool
        // Fix B task 4: folders whose CONDSTORE HIGHESTMODSEQ is unchanged since last sync
        // — RFC 7162 guarantees nothing changed (add/delete/flag), so the per-folder fetch
        // below is skipped. Computed HERE, before the cursor overwrite destroys the cached
        // modseq. NEVER includes the inbox or a deep pass (see shouldSkipFolderFetch); the
        // deletion-reconcile check still runs for skipped folders (safety net).
        let skippablePaths: Set<String> = try await pool.write { db in
            var skippable: Set<String> = []
            let localFolders = try Folder.filter(Column("accountId") == account.id).fetchAll(db)

            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
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
                        cachedModSeq: existing.lastKnownHighestModSeq, isDeepSync: deep) {
                        skippable.insert(info.path)
                    }
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    if let modseq = info.highestModSeq { existing.lastKnownHighestModSeq = modseq }
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
                    let existingHoldsRows = try MessageHeader
                        .filter(Column("folderId") == existing.id).fetchCount(db) > 0
                    if let bootstrap = Self.uidValidityBootstrapWrite(
                        observed: info.uidValidity, stored: existing.lastKnownUidValidity,
                        folderHoldsRows: existingHoldsRows) {
                        existing.lastKnownUidValidity = bootstrap
                    }
                    try existing.update(db)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: account.id)
                    folder.totalCount = info.totalCount
                    folder.lastKnownUidNext = info.uidNext
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
                    let recreatedHoldsRows = try MessageHeader
                        .filter(Column("folderId") == folder.id).fetchCount(db) > 0
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

            // Sync user labels from the folder list (Gmail: user labels appear as custom folders).
            // One UserLabel per Gmail label. Nested labels (e.g., "Work/Projects/Alpha") are stored
            // with their full name — splitting into segments happens at display time in the chip view.
            if account.provider == .gmail {
                let existingLabelIds = try String.fetchSet(db,
                    UserLabel.select(Column("id")).filter(Column("accountId") == account.id)
                )
                var seenLabelIds: Set<String> = []

                for info in remoteFolders {
                    let labelId = info.path
                    // Skip tm_* labels (handled by ActionTag) and system/auto-created labels
                    if UserLabelStore.isExcludedKeyword(info.name) { continue }

                    let isSystem = UserLabelStore.isGmailSystemLabel(id: labelId, name: info.name)
                    try UserLabel(id: labelId, accountId: account.id, name: info.name, isSystem: isSystem)
                        .save(db) // upsert
                    seenLabelIds.insert(labelId)
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

        if !skippablePaths.isEmpty {
            BootProfiler.mark("fullSync[\(acctTag)]: skipped \(skippablePaths.count) MODSEQ-unchanged folder(s) — no re-fetch (reconcile still runs)")
        }

        print("[FullSync] \(account.emailAddress) folder upsert: \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms")

        // Fetch fresh folder list after upsert
        let folders = try await pool.read { db in
            try Folder.filter(Column("accountId") == account.id).fetchAll(db)
        }

        // Sync messages for main roles + favorited folders, prioritized:
        // inbox first, then favorites, then secondary roles, then custom.
        // Custom non-favorited folders sync on-demand when the user navigates to them.
        let primary = self.primaryRoles
        let secondary = self.secondaryRoles
        let syncableFolders = folders.filter { folder in
            primary.contains(folder.role) ||
            secondary.contains(folder.role) ||
            folder.isFavorite
        }.sorted { a, b in
            func priority(_ f: Folder) -> Int {
                if primary.contains(f.role) { return 0 }
                if f.isFavorite { return 1 }
                if secondary.contains(f.role) { return 2 }
                return 3
            }
            return priority(a) < priority(b)
        }

        print("[FullSync] \(account.emailAddress) syncing \(syncableFolders.count) folders: \(syncableFolders.map(\.name).joined(separator: ", "))")

        // Capture actor state — single actor hop
        let mgr = AccountManager.shared
        // Snapshot recentlyCompleted — replaces per-folder recentActions. Prune
        // first: the reads below are presence checks (`!= nil`) that don't consult
        // per-entry expiry, so an unpruned map would treat expired entries as
        // still protected forever.
        await mgr.pruneRecentlyCompleted()
        let recentlyCompletedSnapshot = await mgr.recentlyCompleted

        // Heavy per-folder sync — run off main thread.
        // All network + DB operations (provider.fetchMessages, dbPool.read/write) are
        // thread-safe. Running here avoids dozens of MainActor await-resume hops.
        // Helper: process sync result — FTS indexing, ReplyDetect notifications, collect migrated IDs.
        // Extracted to avoid duplication between initial sync and connection-error retry.
        @Sendable func processSyncResult(_ result: SyncMessagesResult, folder: Folder) async -> [String] {
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
                try? await SearchIndex.shared.removeMessages(
                    contentKeys: result.staleIds.map(ContentKey.init(rawValue:)))
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
                    print("[FTS] Indexed \(inserted) new messages")
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
                print("[Sync] \(folder.name): \(result.newHeaders.count) new messages")
                await ActiveBodyQueue.shared.enqueueBatch(result.newHeaders)
            }
            return result.uidMigratedOldIds
        }

        let uidMigratedOldIds: [String] = try await Task.detached {
            var allMigratedIds: [String] = []
            // `!skippablePaths.contains` — Fix B task 4: a CONDSTORE-unchanged non-inbox
            // folder is not re-fetched (its HIGHESTMODSEQ proves nothing changed). The
            // reconcile loop below still visits it, so external deletions are never missed.
            for folder in syncableFolders where !folder.path.isEmpty && !skippablePaths.contains(folder.path) {
                // T4.S6 re-drive. A folder left quarantined by an interrupted
                // reaction (crash, transient step failure) BRANCHES INTO the
                // reaction instead of a normal sync — never a plain skip. The flag
                // means "re-drive me", and only incidentally "skip normal sync
                // until then": an ordinary pass here would insert NEW-epoch headers
                // under the OLD stamp, which is precisely the state a bare-UID
                // durable op mutates the wrong message from. Launch/foreground full
                // sync is therefore the re-drive OWNER; `runUidValidityResetReaction`
                // re-enters at the barrier (idempotent) when the flag is already set.
                if folder.uidValidityResetPendingAt != nil {
                    await AccountManager.shared.runUidValidityResetReaction(
                        accountId: account.id, folderPath: folder.path
                    )
                    continue
                }
                let ft0 = CFAbsoluteTimeGetCurrent()
                do {
                    let result = try await Self.runSyncMessages(
                        for: folder, provider: provider, limit: SyncConfig.syncMessageLimit,
                        dbPool: pool, recentlyCompleted: recentlyCompletedSnapshot
                    )
                    print("[FullSync] \(account.emailAddress) \(folder.name): \(Int((CFAbsoluteTimeGetCurrent() - ft0) * 1000))ms")
                    allMigratedIds.append(contentsOf: await processSyncResult(result, folder: folder))
                } catch {
                    if Self.isSelectFailedError(error) {
                        print("[FullSync] SELECT failed for \(folder.name) (\(folder.path)) — skipping: \(error)")
                        continue
                    }
                    if Self.isConnectionError(error) {
                        // Connection died mid-sync — retry this folder once.
                        // Pool self-heals: dead connections discarded on checkin(healthy: false),
                        // next checkout creates a fresh one.
                        print("[FullSync] Connection error for \(folder.name): \(error) — retrying")
                        do {
                            let retryResult = try await Self.runSyncMessages(
                                for: folder, provider: provider, limit: SyncConfig.syncMessageLimit,
                                dbPool: pool, recentlyCompleted: recentlyCompletedSnapshot
                            )
                            allMigratedIds.append(contentsOf: await processSyncResult(retryResult, folder: folder))
                        } catch {
                            if Self.isConnectionError(error) {
                                // Retry also hit connection error — server unreachable. Skip remaining folders.
                                print("[FullSync] Retry failed for \(folder.name): \(error) — skipping remaining folders")
                                break
                            }
                            // Non-connection error on retry — skip this folder, continue with rest
                            print("[FullSync] Retry failed for \(folder.name): \(error) — skipping")
                        }
                        continue
                    }
                    throw error
                }

                // Anchor oldestSyncedDate for the age cutoff in backfill.
                // Only set if not already set (backfill or Smart Reindex may have set it).
                // Query the oldest date from ONLY the most recent N messages
                // (matching syncMessageLimit), NOT min(date) across all messages —
                // avoids skipping recent history when old messages already exist.
                if folder.oldestSyncedDate == nil {
                    let oldestDate = try await pool.read { db in
                        try Date.fetchOne(db,
                            MessageHeader
                                .select(Column("date"))
                                .filter(Column("folderId") == folder.id)
                                .order(Column("date").desc)
                                .limit(1, offset: SyncConfig.syncMessageLimit - 1)
                        )
                    }
                    if let oldestDate {
                        try await pool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("oldestSyncedDate").set(to: oldestDate))
                        }
                        print("[FullSync] Anchored oldestSyncedDate for \(folder.name) to \(oldestDate)")
                    }
                }

            }
            return allMigratedIds
        }.value

        // Clear undo protection for migrated UIDs
        // UID migration tracking — logged for diagnostics but no longer clears undoProtectedIds
        // (pending-op check in sync transaction handles undo protection now)
        if !uidMigratedOldIds.isEmpty {
            print("[FullSync] UID migrated \(uidMigratedOldIds.count) messages")
        }
        BootProfiler.mark("fullSync[\(acctTag)] DONE in \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (inbox headers synced)")
        await SyncEngine.checkpointWALThrottled()

        // ADR-IOS-051 Phase 2: evaluate the deletion-reconcile predicate per
        // IMAP folder during full sync too — ghosts below the windowed sync's
        // UID floor are otherwise invisible when delta's STATUS-change gating
        // skips the folder (the cached totalCount already matches the server).
        // `folder.totalCount` here is the fresh STATUS count from fetchFolders
        // above; the local count is read live AFTER the windowed pass.
        if provider.staleWindowMode == .uid, let imapProvider = provider as? IMAPProvider {
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
                do {
                    let folderId = folder.id
                    let localCount = try await pool.read { db in
                        try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
                    }
                    if Self.shouldReconcileDeletions(
                        localCount: localCount,
                        serverCount: folder.totalCount,
                        tolerance: SyncConfig.deletionReconcileCountTolerance
                    ) {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[FullSync] \(folder.name): local=\(localCount) > server=\(folder.totalCount) — reconciling external deletions")
                        }
                        await reconcileExternallyDeletedMessages(
                            folder: folder,
                            provider: imapProvider,
                            expectedGhosts: localCount - folder.totalCount
                        )
                    }
                } catch {
                    // Best-effort — the evidence is durable and re-fires next sync.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[FullSync] reconcile trigger check failed for \(folder.name): \(error)")
                    }
                }
            }
        }

        // Body fetching happens during backfill (startBackfill called after fullSync).
        // Running it inline here would block sync and explode memory for large folders.
        // Unread recount is now handled per-folder inside syncMessages, immediately after header commit.
    }

    // MARK: - Message Sync

    /// On-demand sync for a single folder (called when user navigates to it).
    /// Publishes `.checking` phase for the folder's account.
    func syncFolderMessages(folder: Folder, provider: any EmailProvider) async throws {
        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: folder.accountId) }
        try await syncMessages(for: folder, provider: provider, limit: SyncConfig.syncMessageLimit)
        // Unread recount is now handled inside syncMessages, immediately after header commit.

        // Self-heal runs during periodic background sync, not on pull-to-refresh.
        // Running a 90-day IMAP SEARCH here blocks the UI spinner unnecessarily.
    }

    /// Instance wrapper for syncMessages — captures MainActor state and delegates
    /// to the static method, then handles MainActor-only cleanup (undo protection, FTS).
    /// Used by syncFolderMessages and delta sync paths that run on MainActor.
    func syncMessages(
        for folder: Folder,
        provider: any EmailProvider,
        limit: Int
    ) async throws {
        let syncMgr = AccountManager.shared
        // Prune before snapshotting — the reads in runSyncMessages are presence
        // checks (`!= nil`) that don't consult per-entry expiry.
        await syncMgr.pruneRecentlyCompleted()
        let recentlyCompletedSnapshot = await syncMgr.recentlyCompleted
        let result = try await Self.runSyncMessages(
            for: folder, provider: provider, limit: limit,
            dbPool: dbPool, recentlyCompleted: recentlyCompletedSnapshot
        )

        if !result.uidMigratedOldIds.isEmpty {
            print("[FullSync] syncMessages — UID migrated \(result.uidMigratedOldIds.count) messages")
        }

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
            print("[Sync] \(folder.name): \(result.newHeaders.count) new messages")
            await ActiveBodyQueue.shared.enqueueBatch(result.newHeaders)
        }
    }

    // MARK: - Background Sync Helpers

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
    /// row doesn't have, the PLAN_FTS_BODY_LOSS class). A survivor with
    /// `bodyComplete = 0` re-enters the standard body pipeline naturally.
    ///
    /// `incomingNormalizedRfc822` (ADR-IOS-061 R15-F1): the incoming server
    /// message's NORMALIZED rfc822MessageId (nil when the server carries
    /// none). **Required — never defaulted**: a dropped injection here is
    /// silent and fail-DANGEROUS, and the compiler is the only thing that can
    /// catch a new call site that forgets it.
    ///
    /// `(folderId, messageId)` equality is an ADDRESS match, not an identity
    /// proof: `optimisticMoveToFolder` writes folderId/folderPath/isInInbox
    /// but leaves BOTH the PK and the `messageId` column holding the SOURCE
    /// folder's UID, so a message archived out of INBOX parks a
    /// foreign-UID-space `messageId` under the destination `folderId`. IMAP UID
    /// spaces are PER FOLDER, so INBOX UID 500 and Archive UID 500 routinely
    /// coexist as DIFFERENT messages — **no UIDVALIDITY reset is needed for
    /// this to collide.** Without the gate, the destination folder's next sync
    /// matches the moved-in remnant, elects the folder-native canonical-PK row
    /// as survivor, and DELETES the user's just-moved message as a duplicate,
    /// OR-merging its read/AI state onto an unrelated message and cascading its
    /// body away — while the move op is still pending (this function never
    /// consults `pendingAllIds`; that set only guards the stale sweep).
    ///
    /// Rows whose stored identity PROVABLY differs (both sides non-nil,
    /// unequal) are excluded from canonicalization entirely — never merged,
    /// never deleted, never adopted as survivor.
    ///
    /// ⚠ **THE EXCLUSION IS PERMANENT, AND AN EARLIER VERSION OF THIS PARAGRAPH
    /// CLAIMED OTHERWISE.** It said such rows "heal through their own folder's
    /// rfc-verified UID remap in `runSyncMessages`". That is FALSE, and it is worth
    /// keeping the refutation visible because the false form invites deleting the
    /// gate. Three facts, each checkable in this file: (a) the gate fires while
    /// processing `info.messageId == M` for folder F, so M is in `remoteIds` BY
    /// CONSTRUCTION; (b) the excluded row satisfies this function's own predicate
    /// (same `folderId` AND same `messageId`), so it is IN folder F, not visiting
    /// from elsewhere; (c) all three return paths of `selectStaleHeaders` end in
    /// `!remoteIds.contains($0.messageId)`. So the row can never be selected as
    /// stale and the remap can never re-key it: it persists as a duplicate under a
    /// non-canonical PK until something else removes it.
    ///
    /// That outcome is ACCEPTED, not repaired here. A surviving duplicate row is
    /// strictly safer than the deletion it replaced (the gate exists because the
    /// ungated path DELETED the user's just-moved message and grafted its state
    /// onto an unrelated one), and building machinery to reconcile it is out of
    /// this guard's scope.
    ///
    /// When the incoming
    /// identity is nil AND the matching rows themselves carry conflicting
    /// non-nil identities, there is no discriminating signal at all: refuse to
    /// touch anything (loud error), returning the canonical-PK row if one
    /// exists — the next pass that carries an identity discriminates.
    ///
    /// ⚠ **THAT LAST BRANCH'S CONTRACT, STATED HONESTLY.** "Refusing to merge/
    /// re-key anything" is a statement about what THIS function writes, and only
    /// that. Returning the canonical-PK row hands it to the caller's `existing`
    /// branch, which then merges the incoming message into it — so the refusal
    /// never stopped a mutation, it only declined to re-key one. What bounds that
    /// today is the caller, not this function: `runSyncMessages` classifies the
    /// returned row's identity against the incoming one BEFORE mutating it, and
    /// refuses the entire merge when they provably disagree. With a nil incoming
    /// identity every classification is `.notACollision` by definition, so the row
    /// IS merged into — the documented nil-blindness residual, unchanged and
    /// indistinguishable from ordinary enrichment. Returning `nil` here instead
    /// would not close it either: the caller would then fall through to the
    /// insert path and create a second row at the canonical PK's address.
    /// Nil-identity rows likewise remain mergeable with anything.
    ///
    /// REFERENCE (`v2final`, tag `7904961ded`):
    /// `v2final:TabMail/Services/Sync/SyncEngineFullSync.swift:636-706`. The
    /// reference's second extra parameter, `fieldAuthority:
    /// LocalIdentityFieldAuthority`, does NOT transfer — that type is
    /// ADR-IOS-060 durable-intention machinery that does not exist anywhere in
    /// v3, and it is orthogonal to this identity gate.
    nonisolated static func canonicalizeLocalRows(
        accountId: String,
        folderPath: String,
        folderId: String,
        messageId: String,
        isInInbox: Bool,
        incomingNormalizedRfc822: String?,
        db: Database
    ) throws -> (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?) {
        let allRows = try MessageHeader
            .filter(Column("messageId") == messageId && Column("folderId") == folderId)
            .fetchAll(db)
        guard !allRows.isEmpty else { return (nil, [], nil) }

        let canonicalId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)

        // R15-F1 identity gate — see `incomingNormalizedRfc822`'s doc above.
        let rows: [MessageHeader]
        if let incoming = incomingNormalizedRfc822 {
            // The row already holding the CANONICAL PK is folder-native (it was
            // inserted under this folder's own address, not moved in) — it stays
            // visible even on an identity conflict, so the caller's `existing`
            // branch can apply the §5 classification to it. The gate excludes
            // only NON-canonical-PK rows: those are moved-in remnants, and a
            // conflicting identity there means a foreign message at a
            // coinciding address.
            rows = allRows.filter { row in
                let stored = normalizedRfc822Identity(row.rfc822MessageId)
                return row.id == canonicalId || stored == nil || stored == incoming
            }
            if rows.count != allRows.count {
                // Ungated per CLAUDE.md rule 12 exception (b): a foreign-identity
                // row at this address is exactly the R15-F1 wrong-merge input —
                // production observability needs it.
                BackgroundSyncLogger.log("[Sync] ERROR: canonicalize identity gate at (folderId=\(folderId), msgId=\(messageId)) excluded \(allRows.count - rows.count) row(s) whose stored rfc822MessageId differs from the incoming identity — address match is not an identity proof (R15-F1)")
            }
            guard !rows.isEmpty else { return (nil, [], nil) }
        } else {
            let distinctNonNil = Set(allRows.compactMap { normalizedRfc822Identity($0.rfc822MessageId) })
            if distinctNonNil.count > 1 {
                BackgroundSyncLogger.log("[Sync] ERROR: canonicalize identity conflict at (folderId=\(folderId), msgId=\(messageId)) with a NIL incoming identity — \(distinctNonNil.count) distinct stored identities among \(allRows.count) rows; refusing to merge/re-key anything (R15-F1)")
                return (allRows.first(where: { $0.id == canonicalId }), [], nil)
            }
            rows = allRows
        }
        // Fast path — a single row already under the canonical PK is the
        // overwhelmingly common case. Return before ANY extra query so the
        // per-message cost of the upsert loop is identical to the plain
        // fetchOne this replaced (ADR-IOS-029 hot-path discipline).
        if rows.count == 1 && rows[0].id == canonicalId {
            return (rows[0], [], nil)
        }

        var survivor = rows.first(where: { $0.id == canonicalId }) ?? rows[0]
        var removedIds: [String] = []

        // Preserve the richest cached body across all rows BEFORE any delete —
        // MessageBody is keyed 1:1 by header id and CASCADE-deletes with it.
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
            removedIds.append(row.id)
            print("[Sync] Canonicalize: merged duplicate \(row.id) into \(survivor.id) (msgId=\(messageId))")
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
                print("[Sync] Canonicalize: SKIPPING re-key \(survivor.id) → \(canonicalId) — id held by another row")
                if !removedIds.isEmpty { try survivor.update(db) }
                return (survivor, removedIds, nil)
            }
            // Re-key the optimistic-move remnant to the canonical PK. The PK
            // can't be UPDATEd in place (messageBody references it with
            // ON DELETE CASCADE), so delete + reinsert, body reattached below.
            let oldId = survivor.id
            try survivor.delete(db)
            survivor.id = canonicalId
            survivor.folderPath = folderPath
            try survivor.insert(db)
            ftsRekey = (oldId: oldId, newId: canonicalId)
            print("[Sync] Canonicalize: re-keyed remnant \(oldId) → \(canonicalId)")
        } else if !removedIds.isEmpty {
            try survivor.update(db)
        }

        // Reattach the preserved body under the final id if none is present.
        if let body = bestBody, try MessageBody.fetchOne(db, key: ContentKey(rawValue: survivor.id)) == nil {
            var rekeyedBody = body
            rekeyedBody.id = ContentKey(rawValue: survivor.id)
            try rekeyedBody.insert(db)
        }

        return (survivor, removedIds, ftsRekey)
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
    /// `fetched.count < limit` ⇒ the whole folder came back ⇒ complete knowledge of
    /// all of it ⇒ anything local-but-not-remote is genuinely gone.
    nonisolated static func selectStaleHeaders(
        candidates: [MessageHeader],
        fetched: [MessageHeaderInfo],
        limit: Int,
        windowMode: StaleWindowMode
    ) -> [MessageHeader] {
        let remoteIds = Set(fetched.map(\.messageId))
        if fetched.count < limit {
            return candidates.filter { !remoteIds.contains($0.messageId) }
        }
        switch windowMode {
        case .uid:
            guard let floorUID = fetched.compactMap({ Int64($0.messageId) }).min() else { return [] }
            return candidates.filter { row in
                guard let uid = Int64(row.messageId) else { return false } // non-numeric id → never UID-stale
                return uid >= floorUID && !remoteIds.contains(row.messageId)
            }
        case .date:
            guard let floorDate = fetched.map(\.date).min() else { return [] }
            return candidates.filter { $0.date >= floorDate && !remoteIds.contains($0.messageId) }
        }
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

    /// §5 merge-collision classification: is a same-(folder, UID) row's
    /// normalized rfc822MessageId changing to a DIFFERENT non-nil value (a
    /// genuine identity collision), or is this ordinary enrichment/no-op?
    /// nil→non-nil (first-time identity fill) and non-nil→nil (incoming
    /// carries no signal) are both `.notACollision` — the stored identity is
    /// authoritative either way once assigned.
    ///
    /// **This deliberately does NOT encode the assign/keep rule.**
    /// `.notACollision` covers THREE shapes — nil→non-nil enrichment,
    /// non-nil→nil, and equal values — and only the first and last may assign.
    /// A non-nil→nil incoming carries no signal and must never NULL a stored
    /// identity (that flips `MessageHeader.stableId` from the durable RFC id to
    /// the bare UID, re-admitting bare-UID gestures). Each call site owns that
    /// decision because each has a different row to write it to.
    ///
    /// Pure — no DB/IO, unit-testable like `selectStaleHeaders` above.
    ///
    /// REFERENCE (`v2final`, tag `7904961ded`): ported verbatim from
    /// `v2final:TabMail/Services/Sync/SyncEngineFullSync.swift:880-893`
    /// (ADR-IOS-061 §5, origin commit `4d34ee864`).
    enum RFC822MergeOutcome: Equatable {
        case notACollision
        case collision
    }

    nonisolated static func classifyRFC822Merge(
        storedNormalized: String?,
        incomingNormalized: String?
    ) -> RFC822MergeOutcome {
        guard let storedNormalized, let incomingNormalized, storedNormalized != incomingNormalized else {
            return .notACollision
        }
        return .collision
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
    /// bounded, chunked membership check (same idiom as `SyncEngineSelfHeal`).
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
    nonisolated static func runSyncMessages(
        for folder: Folder,
        provider: any EmailProvider,
        limit: Int,
        dbPool: PrioritizedDatabase,
        recentlyCompleted: [String: Date] = [:]
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
        // that last one, self-heal and deep backfill, neither of them
        // epoch-guarded — all replace the mirror for this same folder path. One
        // of them landing between the fetch and the read let this pass bootstrap
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
        await Self.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folder.id, folderPath: folder.path, accountId: folder.accountId,
            provider: provider, dbPool: dbPool)
        let fetched = try await provider.fetchMessagesWithObservedEpoch(
            folder: folder.path, limit: limit, offset: 0)
        let messages = fetched.messages
        let observedEpochAtFetch = fetched.observedEpoch
        let folderPath = folder.path
        let folderId = folder.id
        let accountId = folder.accountId
        let isInInbox = folder.role == .inbox

        let remoteIds = Set(messages.map(\.messageId))

        // Stale detection + deletion + upsert in one write block.
        // Pending ops are loaded INSIDE the write transaction to prevent TOCTOU races
        // (a user action inserting a PendingOperation between a separate read and this write
        // would cause the pendingDestructiveIds set to be stale, leading to UNIQUE constraint violations).
        // DIAGNOSTIC (debug-gated): time this per-folder write. The merge waits ≤ ONE
        // in-flight write (DatabaseWriteQueue can't preempt SQLite), so a single long
        // folder write here is the residual cap to chunk. Remove once confirmed bounded.
        let writeStart = CFAbsoluteTimeGetCurrent()
        let syncResult: (newHeaders: [MessageHeader], staleIds: [String], replyDetectIds: [String], uidMigratedOldIds: [String], ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)]) = try await dbPool.write { db in
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
                return (newHeaders: [], staleIds: [], replyDetectIds: [], uidMigratedOldIds: [], ftsRekeys: [])
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
                return (newHeaders: [], staleIds: [], replyDetectIds: [], uidMigratedOldIds: [], ftsRekeys: [])
            }
            try Self.bootstrapFolderUidValidity(
                db, folderId: folderId, observed: observedEpochAtFetch.map { Int($0) })
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
            let isRecentlyCompleted: (MessageHeaderInfo) -> Bool = { info in
                recentlyCompleted[info.messageId] != nil ||
                (info.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false)
            }
            let opsTargetingThisFolder = pendingOps.filter {
                $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
            }
            let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))
            if !pendingDestructiveIds.isEmpty || pendingAllIds.count > pendingDestructiveIds.count {
                print("[MoveTrace] fullSync \(folder.name) — pendingDestructiveIds=\(pendingDestructiveIds) pendingAllIds=\(pendingAllIds)")
            }
            var newHeaders: [MessageHeader] = []
            var staleIds: [String] = []
            var ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)] = []
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
            // LOCAL side is also small. A LARGE folder that returns < limit is almost
            // certainly a truncated/partial fetch, NOT genuine complete knowledge — so gate
            // on a cheap index-backed COUNT (evaluated ONLY when the fetch came back short,
            // via `&&` short-circuit) and fall through to the bounded windowed slice when
            // the folder is large. This bounds the load (no whole-folder fetchAll on All
            // Mail) AND prevents mass-stale-deleting rows a partial fetch never returned
            // (ADR-IOS-042). selectStaleHeaders / windowMode are unchanged — this only
            // decides WHICH candidate set they run against.
            if messages.count < limit,
               try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db) <= SyncConfig.staleDetectionMaxFullScan {
                // Got everything AND the folder is small enough to trust — find local
                // messages not in remote set
                let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
                let localIds = Set(allLocal.map(\.messageId))
                allLocalIds = localIds
                if !allLocal.isEmpty && !remoteIds.isEmpty {
                    let onlyLocal = localIds.subtracting(remoteIds)
                    let onlyRemote = remoteIds.subtracting(localIds)
                    if !onlyLocal.isEmpty || !onlyRemote.isEmpty {
                        print("[Sync] \(folder.name) stale-check: local=\(allLocal.count) remote=\(messages.count) onlyLocal=\(Array(onlyLocal.prefix(5))) onlyRemote=\(Array(onlyRemote.prefix(5)))")
                    }
                }
                stale = Self.selectStaleHeaders(candidates: allLocal, fetched: messages, limit: limit, windowMode: windowMode)
            } else {
                // Folder is larger than the fetch window — OR it returned < limit but has
                // more than `staleDetectionMaxFullScan` local rows, so a "complete" read is
                // untrustworthy (likely a partial fetch; ADR-IOS-042). Load ONLY the bounded
                // candidate slice (not the whole folder, per the memory budget) in the
                // fetch-ordering dimension, then let selectStaleHeaders re-apply the
                // same floor as the single source of truth.
                let candidates: [MessageHeader]
                switch windowMode {
                case .uid:
                    // messageId is a numeric IMAP UID; CAST avoids a lexicographic compare.
                    if let floorUID = messages.compactMap({ Int64($0.messageId) }).min() {
                        candidates = try MessageHeader.fetchAll(db, sql:
                            "SELECT * FROM messageHeader WHERE folderId = ? AND CAST(messageId AS INTEGER) >= ?",
                            arguments: [folderId, floorUID])
                    } else {
                        candidates = []  // no parseable UID floor → delete nothing (safe)
                    }
                case .date:
                    if let fetchCutoff = messages.map(\.date).min() {
                        candidates = try MessageHeader
                            .filter(Column("folderId") == folderId && Column("date") >= fetchCutoff)
                            .fetchAll(db)
                    } else {
                        candidates = []
                    }
                }
                stale = Self.selectStaleHeaders(candidates: candidates, fetched: messages, limit: limit, windowMode: windowMode)
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
            let pendingSkipped = stale.filter { isProtectedByPending($0) || isProtectedByRecent($0) }
            if !pendingSkipped.isEmpty {
                print("[MoveTrace] fullSync \(folder.name) — skipping stale delete for \(pendingSkipped.count) msgs with pending/recent ops: \(pendingSkipped.map(\.messageId))")
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
                print("[Sync] UID remap: rfc822=\(rfc822) \(staleMsg.messageId)→\(newMsgId) in \(folder.name)")
                // Fetch body BEFORE deleting header — CASCADE would delete body too
                let oldBody = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId))
                try staleMsg.delete(db)
                var migrated = staleMsg
                migrated.id = newId
                migrated.messageId = newMsgId
                // If the remote match has a broken (epoch 0) date from IMAP parse
                // failure, the entire remote record can't be trusted — preserve all
                // local fields (isRead, isFlagged, date). The UID remap still happens
                // so future syncs find the message, but we don't copy the broken
                // remote state. Next sync cycle will update with valid data.
                if match.date.timeIntervalSince1970 >= 86400 {
                    migrated.isRead = match.isRead
                    migrated.isFlagged = match.isFlagged
                    migrated.date = match.date
                }
                // Defensive — if a concurrent path already inserted this id, skip
                // instead of throwing UNIQUE. The migrated row's PK was just
                // rewritten; a prior upsert iteration for the same (accountId,
                // folderPath, newMsgId) could have beaten us to it.
                guard try MessageHeader.fetchOne(db, key: newId) == nil else {
                    print("[Sync] UID remap: SKIPPING migrate-insert for \(newId) — already present")
                    continue
                }
                try migrated.insert(db)
                if var body = oldBody {
                    body.id = ContentKey(rawValue: newId)
                    try body.insert(db)
                }
                // Move the FTS entry to the new id IN PLACE (preserves the
                // indexed body text + the messages_vec embedding). Previously
                // the old FTS row ghosted forever (search hits deep-linking to
                // a deleted header id) and the new id was invisible to search.
                ftsRekeys.append((oldId: oldId, newId: newId, newMessageId: newMsgId))
                uidMigratedRemoteIds.insert(newMsgId)
                uidMigratedOldMsgIds.append(staleMsg.messageId)
            }

            let uidMigratedSet = Set(uidMigratedOldMsgIds)
            let isProtected: (MessageHeader) -> Bool = { msg in
                protectedIds.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId) ||
                recentlyCompleted[msg.messageId] != nil ||
                (msg.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false) ||
                (msg.rfc822MessageId.map { outboxProtectedRfc822s.contains($0) } ?? false)
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
                    print("[Sync] DraftStaleDelete: removing \(msg.id) msgId=\(msg.messageId) rfc822=\(msg.rfc822MessageId ?? "nil") snippet=\(String(msg.snippet.prefix(60)))")
                }
                try msg.delete(db)
            }
            if !staleFiltered.isEmpty {
                print("[Sync] \(folder.name): removed \(staleFiltered.count) stale messages")
            }

            // Insert new / update existing.
            // Skip messages with pending destructive ops or recently completed ops —
            // prevents re-inserting optimistically removed messages or overwriting flags
            // during the gap between PendingOp deletion and server propagation.
            let skippedByPending = messages.filter { isPendingDestructive($0) }
            let skippedByRecent = messages.filter { isRecentlyCompleted($0) && !isPendingDestructive($0) }
            let skippedByPendingIds = Set(skippedByPending.map(\.messageId))
            let skippedByRecentIds = Set(skippedByRecent.map(\.messageId))
            let allSkippedIds = skippedByPendingIds.union(skippedByRecentIds)
            if !skippedByPendingIds.isEmpty {
                print("[MoveTrace] fullSync \(folder.name) — skipping upsert for \(skippedByPendingIds.count) msgs with pending destructive ops: \(skippedByPendingIds)")
            }
            if !skippedByRecentIds.isEmpty {
                print("[MoveTrace] fullSync \(folder.name) — skipping upsert for \(skippedByRecentIds.count) msgs recently completed: \(skippedByRecentIds)")
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
                // The §5 identity of the message the server is offering at this
                // address. Computed once per iteration and reused by the
                // canonicalizer's R15-F1 gate and the merge/reclaim
                // classifications below, so every §5 decision in this pass is
                // made against ONE value.
                let normalizedIncomingRfc822 = Self.normalizedRfc822Identity(info.rfc822MessageId)
                let recon: (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?)
                if folder.role == .drafts || folder.role == .sent {
                    recon = (try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                        .fetchOne(db), [], nil)
                } else {
                    recon = try Self.canonicalizeLocalRows(
                        accountId: accountId, folderPath: folderPath,
                        folderId: folderId, messageId: info.messageId,
                        isInInbox: isInInbox,
                        incomingNormalizedRfc822: normalizedIncomingRfc822, db: db
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
                        upsDraftSentSkip += 1
                        continue
                    }
                    // §5 merge-collision invariant (ADR-IOS-061; supersedes the
                    // old unconditional `existing.rfc822MessageId =
                    // info.rfc822MessageId` + `existing.referencesJSON = …`).
                    //
                    // ⚑ CLASSIFY BEFORE MUTATING. This switch used to run AFTER the
                    // field assignments below, and that ordering was itself a C3
                    // defect: on a collision the row kept message A's identity and
                    // PK-keyed body while taking message B's sender, date,
                    // recipients and flags, `updateChanges` persisted the hybrid,
                    // and because the UID stays in `remoteIds` the row is never
                    // stale and never UID-remapped — so every later pass re-applied
                    // it. PERMANENT, and it is a mutation landing on a message whose
                    // identity differs from the one the fetch described.
                    //
                    // Same (folder, UID) but a DIFFERENT normalized identity means
                    // the address was reassigned (a UIDVALIDITY reset reusing the
                    // UID) or the staged row is corrupt. Either way NOTHING the
                    // incoming message carries describes the stored row, so the
                    // whole merge is refused, not just the identity half. Under C6
                    // (failing closed is always acceptable) the row simply keeps its
                    // own self-consistent state; the cost is at most one cycle of
                    // stale flags on one row.
                    //
                    // nil→non-nil / non-nil→nil are NOT collisions — but
                    // "not a collision" covers THREE shapes and only
                    // nil→non-nil and equal may assign. `IMAPFetchMapping
                    // .rfc822MessageId(from:)` is `info.messageId.map { … }`, i.e.
                    // nil whenever the ENVELOPE carries no Message-ID, so an
                    // unconditional assign NULLs a durable identity — which flips
                    // `MessageHeader.stableId` from the RFC id to the bare UID and
                    // re-admits bare-UID gestures through
                    // `AccountManager.newGestureRefusedForUnknownEpoch` (that guard
                    // is `folder.lastKnownUidValidity == nil`, and
                    // `bootstrapFolderUidValidity` makes the stamp non-nil inside
                    // THIS transaction). `referencesJSON` is derived from the same
                    // fetch and rides the same decision.
                    //
                    // REFERENCE (`v2final`, tag `7904961ded`):
                    // `v2final:…/SyncEngineFullSync.swift:1935-1996`. Its collision
                    // arm branches on the epoch: mismatch → fire the
                    // purge-and-resync reaction and abort the folder pass; same (or
                    // unknown) epoch → refuse and log. T4.S6 restores the reaction,
                    // and the merge pass's own in-transaction epoch guard (at the
                    // top of this write block) now abandons the pass BEFORE this
                    // loop on a proven turnover — so by the time control reaches
                    // here, a collision is the reference's SAME-epoch arm: a genuine
                    // anomaly, never a reset. The refusal is that arm, widened from
                    // "identity fields only" to the whole row for the reason above.
                    let normalizedStoredRfc822 = Self.normalizedRfc822Identity(existing.rfc822MessageId)
                    if Self.classifyRFC822Merge(
                        storedNormalized: normalizedStoredRfc822,
                        incomingNormalized: normalizedIncomingRfc822
                    ) == .collision {
                        // Ungated per CLAUDE.md rule 12 exception (b): production
                        // observability needs this.
                        BackgroundSyncLogger.log("[Sync] ERROR: rfc822MessageId collision at \(existing.id) (folder=\(folderPath)) — stored=\(normalizedStoredRfc822 ?? "nil") incoming=\(normalizedIncomingRfc822 ?? "nil") — refusing the whole merge, the stored row is left untouched")
                        upsNoop += 1
                        continue
                    }

                    // Update existing message with latest data from server.
                    // Skip flag/tag overwrites if message has pending queue ops OR
                    // recently completed ops (server may lag behind the executed change).
                    let hasPendingFlags = isPendingFlag(info) || isRecentlyCompleted(info)
                    if !hasPendingFlags {
                        existing.isRead = info.isRead
                        existing.isFlagged = info.isFlagged
                        if isInInbox, let serverTag = info.actionTag {
                            if existing.actionTag != serverTag {
                                print("[Sync] Remote tag change detected for \(info.messageId): \(existing.actionTag?.rawValue ?? "nil") -> \(serverTag.rawValue)")
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
                    // The assign/keep half of the §5 rule (the classification itself
                    // now runs BEFORE any of the assignments above — see the block
                    // ahead of `hasPendingFlags`). Reaching here means
                    // `.notACollision`, which still covers THREE shapes: only
                    // nil→non-nil enrichment and equal values may assign. A
                    // non-nil→nil incoming carries no identity signal and must never
                    // NULL a stored one.
                    if normalizedIncomingRfc822 != nil {
                        existing.rfc822MessageId = info.rfc822MessageId
                        existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                    }
                    // ReplyDetect: if message is replied (server or local) and has reply tag, override to none
                    // AI cache keeps original LLM value — only MessageHeader + IMAP tag change
                    if existing.isReplied && existing.actionTag == .reply {
                        existing.actionTag = ActionTag.none
                        existing.tagSortOrder = ActionTag.none.sortOrder
                        let tagOp = PendingOperation(
                            type: .setTag,
                            messageIds: [existing.stableId],
                            accountId: accountId,
                            folderPath: folderPath,
                            tagValue: ActionTag.none.rawValue
                        )
                        try tagOp.insert(db)
                        replyDetectIds.append(existing.id)
                        print("[ReplyDetect] Sync update: reply→none for \(info.messageId) (already replied)")
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
                    isInInbox: isInInbox
                )
                header.rfc822MessageId = info.rfc822MessageId
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
                    let tagOp = PendingOperation(
                        type: .setTag,
                        messageIds: [header.stableId],
                        accountId: accountId,
                        folderPath: folderPath,
                        tagValue: ActionTag.none.rawValue
                    )
                    try tagOp.insert(db)
                    replyDetectIds.append(header.id)
                    print("[ReplyDetect] Sync insert: reply→none for \(header.messageId) (already replied)")
                }
                // Dedup by rfc822MessageId in Drafts/Sent folders: optimistic creation
                // inserts a placeholder MessageHeader before the IMAP UID is known. When
                // sync returns the real UID, match by rfc822MessageId and update in place
                // to prevent duplicate rows.
                if (folder.role == .drafts || folder.role == .sent),
                   let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
                   let optimistic = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                    .fetchOne(db) {
                    let oldId = optimistic.id
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
                            print("[Sync] DraftDedup: SKIPPING insert for id=\(header.id) — already exists (post-snapshot). remoteSnippet=\(String(header.snippet.prefix(60)))")
                        } else {
                            print("[Sync] Dedup: SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                        }
                        continue
                    }
                    try header.insert(db)
                    if let body = deferredBody { try body.insert(db) }
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    // Insert user label associations
                    for labelId in info.userLabelIds {
                        try UserLabel(id: labelId, accountId: accountId, name: labelId, isSystem: false)
                            .insert(db, onConflict: .ignore)
                        try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                    if folder.role == .drafts || folder.role == .sent {
                        print("[Sync] DraftDedup: replaced optimistic \(folder.role.rawValue) header \(oldId) → \(header.id) | oldSnippet=\(String(optimistic.snippet.prefix(60))) | newSnippet=\(String(header.snippet.prefix(60)))")
                    } else {
                        print("[Sync] Dedup: replaced optimistic \(folder.role == .drafts ? "draft" : "sent") header \(oldId) with \(header.id)")
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
                        print("[Sync] Pre-sync reclaim: \(preSyncRows.count) matching inbox rows for \(info.messageId) — merging all")
                    }
                    if let preSync = preSyncRows.first {
                    let oldId = preSync.id
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
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    for labelId in info.userLabelIds {
                        try UserLabel(id: labelId, accountId: accountId, name: labelId, isSystem: false)
                            .insert(db, onConflict: .ignore)
                        try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                    print("[Sync] Reclaimed pre-sync inbox row \(oldId) → \(header.id) (folderPath drift, preserved AI)")
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
                        print("[Sync] Pre-sync reclaim: removed duplicate inbox row \(extraId)")
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
                        print("[MoveTrace] fullSync — SKIPPING orphan reclaim for \(orphaned.id) — pending destructive op (server folder=\(folder.name) but user moved locally)")
                        continue
                    }
                    // §5 merge-collision invariant, orphan-reclaim leg
                    // (ADR-IOS-061 R14-F1, origin commit `711dc68cb`). This branch
                    // re-identifies a row that currently belongs to ANOTHER folder
                    // — an optimistic move's survivor whose PK still carries this
                    // folder's address (the move keeps the PK; the new UID is
                    // unknown until the destination folder's sync re-keys it).
                    // The pending-op check above is NOT the whole guard: it only
                    // covers moves whose op is still ACTIVE. Once the drain
                    // completes and the op row is deleted, the survivor is
                    // invisible to `pendingDestructiveIds` while still parked
                    // under this folder's PK.
                    //
                    // Within one epoch a PK match proves same-message (IMAP never
                    // reuses UIDs in an epoch; Gmail/Graph ids are never reused),
                    // so the reclaim is safe. Across an epoch swap the SAME address
                    // names a DIFFERENT message — reclaiming would in-place-rewrite
                    // the survivor's identity and hijack its PK-keyed
                    // body/labels/references/search index for the new-epoch
                    // occupant, while yanking the user's moved message out of its
                    // destination folder. `orphaned.id` never changes here and no
                    // ftsRekey is emitted, so the mis-attachment is PERMANENT
                    // (`bodyComplete` is untouched ⇒ nothing ever re-fetches).
                    // Classify BEFORE any mutation, mirroring the `existing`
                    // branch.
                    //
                    // `MessageAICache` is NOT PK-keyed
                    // (`MessageIdentity.aiCacheKey` is
                    // accountId:folderPath:rfc822), so it is merely orphaned by a
                    // reclaim, not mis-attached.
                    //
                    // The refusal is TRANSIENT, not a durable re-entry condition:
                    // the survivor lives in its destination folder, where its
                    // messageId is a foreign-UID-space value that folder's remote
                    // set does not contain, so it is stale there and the
                    // rfc822-keyed UID-remap above re-keys it to its real UID —
                    // vacating this PK, after which the next pass reclaims/inserts
                    // normally.
                    //
                    // REFERENCE (`v2final`, tag `7904961ded`):
                    // `v2final:…/SyncEngineFullSync.swift:2332-2393` + `2431-2433`.
                    // Its epoch-mismatch arm fires the purge-and-resync reaction and
                    // aborts the folder pass; v3 has no reaction (plan item T4.S6),
                    // so under C6 that arm collapses into the plain refusal below.
                    let normalizedSurvivorRfc822 = Self.normalizedRfc822Identity(orphaned.rfc822MessageId)
                    if Self.classifyRFC822Merge(
                        storedNormalized: normalizedSurvivorRfc822,
                        incomingNormalized: normalizedIncomingRfc822
                    ) == .collision {
                        // The survivor belongs to a different message: touching ANY
                        // of its fields is wrong, and the incoming occupant cannot
                        // be stored while the survivor occupies its PK — skip it
                        // this pass. Ungated per CLAUDE.md rule 12 exception (b).
                        BackgroundSyncLogger.log("[Sync] ERROR: orphan-reclaim rfc822MessageId collision at \(orphaned.id) (folder=\(folderPath), survivor folderId=\(orphaned.folderId)) — stored=\(normalizedSurvivorRfc822 ?? "nil") incoming=\(normalizedIncomingRfc822 ?? "nil") — refusing the reclaim")
                        continue
                    }
                    print("[Sync] Reclaiming orphaned row \(header.id): folderId \(orphaned.folderId) → \(folderId)")
                    orphaned.folderId = folderId
                    orphaned.folderPath = folderPath
                    orphaned.isInInbox = isInInbox
                    orphaned.messageId = header.messageId
                    orphaned.isRead = header.isRead
                    orphaned.isFlagged = header.isFlagged
                    orphaned.date = header.date
                    orphaned.from = header.from
                    orphaned.fromAddress = header.fromAddress
                    orphaned.to = header.to
                    orphaned.cc = header.cc
                    orphaned.bcc = header.bcc
                    orphaned.replyTo = header.replyTo
                    // R14-F1 assign/keep rule (mirrors the `existing` branch): a
                    // nil/empty incoming identity carries no signal and must never
                    // NULL the stored one — that flips `stableId` to the bare UID.
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
                        try UserLabel(id: labelId, accountId: accountId, name: labelId, isSystem: false)
                            .insert(db, onConflict: .ignore)
                        try MessageUserLabel(messageId: orphaned.id, userLabelId: labelId)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(orphaned)
                } else {
                    // Defensive — the pending-op filter above should have already
                    // skipped optimistic-move rows whose id PK collides with this
                    // header.id, but rfc822-nil remote info can still slip through
                    // (UID match fails when info has no rfc822). Skip rather than
                    // throw UNIQUE — sync converges on the next cycle.
                    guard try MessageHeader.fetchOne(db, key: header.id) == nil else {
                        if folder.role == .drafts {
                            print("[Sync] DraftInsert: SKIPPED id=\(header.id) — already exists (remoteSnippet=\(String(header.snippet.prefix(60))))")
                        } else {
                            print("[MoveTrace] fullSync — SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                        }
                        continue
                    }
                    try header.insert(db)
                    if folder.role == .drafts {
                        print("[Sync] DraftInsert: INSERTED id=\(header.id) msgId=\(header.messageId) rfc822=\(header.rfc822MessageId ?? "nil") snippet=\(String(header.snippet.prefix(60)))")
                    }
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    // Insert user label associations
                    for labelId in info.userLabelIds {
                        try UserLabel(id: labelId, accountId: accountId, name: labelId, isSystem: false)
                            .insert(db, onConflict: .ignore)
                        try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                            .insert(db, onConflict: .ignore)
                    }
                    newHeaders.append(header)
                }
            }

            // Sent-folder reply discovery: a message in this batch is the user's
            // own reply (sent from another device); flip the parent's isReplied
            // locally. No-op when folder.role != .sent.
            let discoveredParents = try ReplyParentResolver.markParentsReplied(
                inReplyTos: messages.map(\.inReplyTo),
                folderRole: folder.role,
                accountId: accountId,
                db: db
            )
            replyDetectIds.append(contentsOf: discoveredParents)

            // AI cache TTL touch removed from sync transaction — it was holding the
            // GRDB writer lock for 300+ row UPDATEs during every folder sync, blocking
            // MainActor user actions. TTL is now refreshed lazily after AI queue drains
            // (see ActiveAIQueue.onDrainComplete).

            // DIAGNOSTIC: per-folder upsert breakdown. `noop` should now dominate for
            // steady-state re-syncs (Archive/etc.) — it counts the redundant writes the
            // change-detection above eliminated. A stuck-high `upd` with unchanged mail
            // fingerprints an always-dirty column to normalize.
            if upsUpdated + upsNoop + upsDraftSentSkip > 0 || !newHeaders.isEmpty {
                let loopMs = Int((CFAbsoluteTimeGetCurrent() - upsLoopT0) * 1000)
                BootProfiler.mark("fullSync upsert[\(folder.name)]: ins=\(newHeaders.count) upd=\(upsUpdated) noop=\(upsNoop) dsSkip=\(upsDraftSentSkip) stale=\(staleIds.count) loop=\(loopMs)ms recon=\(Int(upsReconSeconds * 1000))ms")
            }
            return (newHeaders, staleIds, replyDetectIds, uidMigratedOldMsgIds, ftsRekeys)
        }
        let writeMs = Int((CFAbsoluteTimeGetCurrent() - writeStart) * 1000)
        if writeMs > 30 {
            BootProfiler.mark("fullSync write[\(folder.name)]: \(messages.count) msg in \(writeMs)ms")
        }

        return SyncMessagesResult(
            newHeaders: syncResult.newHeaders,
            staleIds: syncResult.staleIds,
            replyDetectIds: syncResult.replyDetectIds,
            uidMigratedOldIds: syncResult.uidMigratedOldIds,
            ftsRekeys: syncResult.ftsRekeys
        )
    }
}
