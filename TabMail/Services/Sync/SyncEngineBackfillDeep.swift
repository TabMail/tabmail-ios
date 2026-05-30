/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

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
        var allCcBccUpdates: [(headerId: String, cc: String, bcc: String)] = []

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
                let sqlChunkSize = 500
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
                var headers = try await workQueue.execute(priority: .headerFetch) {
                    try await provider.fetchMessageHeaders(
                        folder: folder.path, uids: chunk, batchSize: imapBatchSize, interBatchDelay: imapDelay
                    )
                }
                // Retry silently dropped UIDs — IMAP FETCH can return fewer results
                // than requested without an error. One retry catches transient issues.
                if headers.count < chunk.count {
                    let returnedIds = Set(headers.map(\.messageId))
                    let droppedUIDs = chunk.filter { !returnedIds.contains("\($0)") }
                    print("[Backfill-FETCH-GAP] \(folder.path): requested \(chunk.count) UIDs, got \(headers.count). Retrying \(droppedUIDs.count) dropped UIDs: \(droppedUIDs.sorted().prefix(20))")
                    if !droppedUIDs.isEmpty {
                        let retryHeaders = try await workQueue.execute(priority: .headerFetch) {
                            try await provider.fetchMessageHeaders(
                                folder: folder.path, uids: droppedUIDs, batchSize: imapBatchSize, interBatchDelay: imapDelay
                            )
                        }
                        if !retryHeaders.isEmpty {
                            print("[Backfill-FETCH-GAP] \(folder.path): retry recovered \(retryHeaders.count)/\(droppedUIDs.count)")
                            headers.append(contentsOf: retryHeaders)
                        } else {
                            print("[Backfill-FETCH-GAP] \(folder.path): retry returned 0 — UIDs may be expunged: \(droppedUIDs.sorted().prefix(20))")
                        }
                    }
                }
                let (inserted, ftsRecords, ccBccUpdates) = insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
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
                let sqlChunkSize = 500
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
                let (inserted, ftsRecords, ccBccUpdates) = insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
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
                let sqlChunkSize = 500
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
                let (inserted, ftsRecords, ccBccUpdates) = insertBackfillBatch(
                    headers, folderId: folderId, accountId: folder.accountId,
                    folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
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

    /// Insert headers into a folder. Returns (insertedCount, ftsRecords) so the caller
    /// can coalesce FTS indexing across multiple batches within a window.
    func insertBackfillBatch(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        folderRole: FolderRole,
        isInInbox: Bool
    ) -> (inserted: Int, ftsRecords: [FTSHeaderRecord], ccBccFtsUpdates: [(headerId: String, cc: String, bcc: String)]) {
        guard !headers.isEmpty else { return (0, [], []) }

        var ftsRecords: [FTSHeaderRecord] = []
        var count = 0
        var unreadInserted = 0
        var discoveredParents: [String] = []

        var ccBccFtsUpdates: [(headerId: String, cc: String, bcc: String)] = []
        do {
            try dbPool.write { db in
                // Load pending destructive IDs to skip messages with optimistic moves.
                // Scoped to (accountId, folderPath) to prevent IMAP cross-folder UID collisions.
                let scopedOps = try PendingOperation
                    .filter(Column("accountId") == accountId && Column("folderPath") == folderPath)
                    .fetchAll(db)
                let snapshot = PendingOperationSnapshot(ops: scopedOps)

                // Batch existence check: one query instead of per-row fetchCount
                let incomingIds = headers.map(\.messageId)
                var existingIds = Set<String>()
                let sqlChunkSize = 500
                for start in stride(from: 0, to: incomingIds.count, by: sqlChunkSize) {
                    let end = min(start + sqlChunkSize, incomingIds.count)
                    let chunk = Array(incomingIds[start..<end])
                    let found = try String.fetchSet(db,
                        MessageHeader
                            .select(Column("messageId"))
                            .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                    )
                    existingIds.formUnion(found)
                }

                let needsCcBccBackfill = !UserDefaults.standard.bool(forKey: "ccBccBackfillDone")
                for info in headers {
                    if snapshot.destructive.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId) { continue }
                    if existingIds.contains(info.messageId) {
                        // v10 cc/bcc backfill: update existing messages with cc/bcc from server
                        if needsCcBccBackfill && (!info.cc.isEmpty || !info.bcc.isEmpty) {
                            let headerId = "\(accountId):\(folderPath):\(info.messageId)"
                            try db.execute(
                                sql: "UPDATE messageHeader SET cc = ?, bcc = ? WHERE id = ?",
                                arguments: [info.cc, info.bcc, headerId]
                            )
                            ccBccFtsUpdates.append((headerId: headerId, cc: info.cc, bcc: info.bcc))
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
                        try UserLabel(id: labelId, accountId: accountId, name: labelId, isSystem: false)
                            .insert(db, onConflict: .ignore)
                        try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                            .insert(db, onConflict: .ignore)
                    }

                    count += 1
                    if !info.isRead { unreadInserted += 1 }

                    ftsRecords.append(FTSHeaderRecord(
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
                    inReplyTos: headers.map(\.inReplyTo),
                    folderRole: folderRole,
                    accountId: accountId,
                    db: db
                )
                discoveredParents.append(contentsOf: parents)

            }
        } catch {
            print("[Backfill] Insert failed: \(error)")
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
        return (count, ftsRecords, ccBccFtsUpdates)
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

            try await dbPool.write { db in
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

