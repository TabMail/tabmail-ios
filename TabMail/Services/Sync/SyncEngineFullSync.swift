/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Full Sync

    func fullSync(account: Account, provider: any EmailProvider) async throws {
        let fs0 = CFAbsoluteTimeGetCurrent()
        // Sync folder list
        let remoteFolders = try await provider.fetchFolders()
        print("[FullSync] \(account.emailAddress) fetchFolders: \(Int((CFAbsoluteTimeGetCurrent() - fs0) * 1000))ms (\(remoteFolders.count) folders)")

        let pool = AppDatabase.dbPool
        try await pool.write { db in
            let localFolders = try Folder.filter(Column("accountId") == account.id).fetchAll(db)

            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    try existing.update(db)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: account.id)
                    folder.totalCount = info.totalCount
                    folder.lastKnownUidNext = info.uidNext
                    try folder.insert(db)
                }
            }

            // Remove local folders that no longer exist remotely
            let remotePaths = Set(remoteFolders.map(\.path))
            for folder in localFolders where !remotePaths.contains(folder.path) {
                // CASCADE handles messageHeader deletion automatically
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
        // Snapshot recentlyCompleted (30s TTL) — replaces per-folder recentActions
        let recentlyCompletedSnapshot = await mgr.recentlyCompleted

        // Heavy per-folder sync — run off main thread.
        // All network + DB operations (provider.fetchMessages, dbPool.read/write) are
        // thread-safe. Running here avoids dozens of MainActor await-resume hops.
        // Helper: process sync result — FTS indexing, ReplyDetect notifications, collect migrated IDs.
        // Extracted to avoid duplication between initial sync and connection-error retry.
        @Sendable func processSyncResult(_ result: SyncMessagesResult, folder: Folder) async -> [String] {
            ReplyParentResolver.postParentNotifications(result.replyDetectIds)
            if !result.ftsRekeys.isEmpty {
                // In-place FTS re-key (UID remap / remnant canonicalization) —
                // preserves the indexed body text + embedding under the new id.
                try? await SearchIndex.shared.rekeyHeaders(result.ftsRekeys)
            }
            if !result.staleIds.isEmpty {
                try? await SearchIndex.shared.removeMessages(headerIds: result.staleIds)
            }
            if !result.newHeaders.isEmpty {
                let records = result.newHeaders.map { header in
                    FTSHeaderRecord(
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
            for folder in syncableFolders where !folder.path.isEmpty {
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
            try? await SearchIndex.shared.rekeyHeaders(result.ftsRekeys)
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
    nonisolated static func canonicalizeLocalRows(
        accountId: String,
        folderPath: String,
        folderId: String,
        messageId: String,
        isInInbox: Bool,
        db: Database
    ) throws -> (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?) {
        let rows = try MessageHeader
            .filter(Column("messageId") == messageId && Column("folderId") == folderId)
            .fetchAll(db)
        guard !rows.isEmpty else { return (nil, [], nil) }

        let canonicalId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
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
        if let body = bestBody, try MessageBody.fetchOne(db, key: survivor.id) == nil {
            var rekeyedBody = body
            rekeyedBody.id = survivor.id
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

    /// Core message sync logic — runs entirely off the main thread.
    /// Fetches messages from provider, performs stale detection + upsert in a single
    /// DB write transaction. No MainActor state accessed.
    nonisolated static func runSyncMessages(
        for folder: Folder,
        provider: any EmailProvider,
        limit: Int,
        dbPool: DatabasePool,
        recentlyCompleted: [String: Date] = [:]
    ) async throws -> SyncMessagesResult {
        let messages = try await provider.fetchMessages(folder: folder.path, limit: limit, offset: 0)
        let folderPath = folder.path
        let folderId = folder.id
        let accountId = folder.accountId
        let isInInbox = folder.role == .inbox

        let remoteIds = Set(messages.map(\.messageId))

        // Stale detection + deletion + upsert in one write block.
        // Pending ops are loaded INSIDE the write transaction to prevent TOCTOU races
        // (a user action inserting a PendingOperation between a separate read and this write
        // would cause the pendingDestructiveIds set to be stale, leading to UNIQUE constraint violations).
        let syncResult: (newHeaders: [MessageHeader], staleIds: [String], replyDetectIds: [String], uidMigratedOldIds: [String], ftsRekeys: [(oldId: String, newId: String, newMessageId: String?)]) = try await dbPool.write { db in
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
            let windowMode = provider.staleWindowMode
            if messages.count < limit {
                // Got everything — find local messages not in remote set
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
                // Folder is larger than the fetch window — load ONLY the bounded
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

            // UID remap detection: before deleting stale messages, check if any have
            // rfc822MessageId matching a NEW remote message in the same folder. This catches
            // UID changes from IMAP MOVE round-trips, server-side operations, UIDVALIDITY
            // changes, etc. Migrate the local row in-place to preserve local state (body, AI cache).
            var uidMigratedRemoteIds = Set<String>()
            var uidMigratedOldMsgIds: [String] = []
            // Reuse allLocalIds from stale detection when available; otherwise fetch just IDs (lightweight)
            let localMsgIds: Set<String>
            if let cached = allLocalIds {
                localMsgIds = cached
            } else {
                localMsgIds = try Set(String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId]))
            }
            let newRemoteIds = remoteIds.subtracting(localMsgIds)
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
                let oldBody = try MessageBody.fetchOne(db, key: oldId)
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
                    body.id = newId
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
            for info in messages where !allSkippedIds.contains(info.messageId) && !uidMigratedRemoteIds.contains(info.messageId) {
                // Canonicalize PKs + merge duplicate rows (optimistic-move
                // remnants keep their old "accountId:<oldPath>:<msgId>" PK
                // forever for stable-id providers — see canonicalizeLocalRows).
                // Drafts/Sent are exempt: DraftStore's push migration manages
                // their row identity.
                let recon: (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?)
                if folder.role == .drafts || folder.role == .sent {
                    recon = (try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                        .fetchOne(db), [], nil)
                } else {
                    recon = try Self.canonicalizeLocalRows(
                        accountId: accountId, folderPath: folderPath,
                        folderId: folderId, messageId: info.messageId,
                        isInInbox: isInInbox, db: db
                    )
                }
                if !recon.removedIds.isEmpty {
                    staleIds.append(contentsOf: recon.removedIds)
                }
                if let rekey = recon.ftsRekey {
                    // FTS entry moves to the new id in place — body text and
                    // embedding ride along. messageId is unchanged here.
                    ftsRekeys.append((oldId: rekey.oldId, newId: rekey.newId, newMessageId: nil))
                }
                if var existing = recon.row {
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
                        print("[Sync] DraftUpsertSkip: preserving local content for \(info.messageId) (folder=\(folder.role.rawValue)) — sync summary may be stale from drafts.list cache")
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
                    existing.rfc822MessageId = info.rfc822MessageId
                    existing.referencesJSON = MessageHeader.encodeReferences(info.references)
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
                    try existing.update(db)
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
                    if let body = try MessageBody.fetchOne(db, key: oldId) {
                        var newBody = body
                        newBody.id = header.id
                        try MessageBody.deleteOne(db, key: oldId)
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
                    let preSyncRows = try MessageHeader
                        .filter(Column("accountId") == accountId)
                        .filter(Column("messageId") == info.messageId)
                        .filter(Column("isInInbox") == true)
                        .filter(Column("id") != header.id)
                        .fetchAll(db)
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
                    if let body = try MessageBody.fetchOne(db, key: oldId) {
                        var newBody = body
                        newBody.id = header.id
                        try MessageBody.deleteOne(db, key: oldId)
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
                    orphaned.rfc822MessageId = header.rfc822MessageId
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

            return (newHeaders, staleIds, replyDetectIds, uidMigratedOldMsgIds, ftsRekeys)
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
