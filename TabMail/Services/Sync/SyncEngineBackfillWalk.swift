/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
private actor ProgressThrottle {
    private var lastUpdate: Date = .distantPast
    private static let intervalSeconds: TimeInterval = 1

    func shouldUpdate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= Self.intervalSeconds else { return false }
        lastUpdate = now
        return true
    }
}

/// Thread-safe cursor for distributing UID batches to parallel workers.
/// Unlike UIDWalkCursor which generates contiguous ranges, this consumes
/// a pre-computed list of existing UIDs (from UID SEARCH).
private actor UIDListCursor {
    private let uids: [UInt32]
    private var index: Int = 0
    private let batchSize: Int

    init(uids: [UInt32], batchSize: Int) {
        self.uids = uids
        self.batchSize = batchSize
    }

    func nextBatch() -> [UInt32]? {
        guard index < uids.count else { return nil }
        let end = min(index + batchSize, uids.count)
        let batch = Array(uids[index..<end])
        index = end
        return batch
    }
}

extension SyncEngine {

    // MARK: - Unified Backfill Walk

    /// Crawl folders for this account, inserting headers AND indexing bodies in the same walk.
    /// Gmail/Exchange: single API call per message (format=full) — headers + body together.
    /// IMAP: header fetch then body fetch in the same iteration (protocol limitation).
    /// After walking all folders, runs a cleanup pass for any remaining empty bodies.
    /// Returns true if any work was done.
    func runBackfill(account: Account, deadline: Date? = nil) async -> Bool {
        var didWork = false
        let fastSync = await getIsFastSync()
        let isPastDeadline: () -> Bool = {
            guard let deadline else { return false }
            return Date() >= deadline
        }


        let incompleteFolders: [Folder]
        do {
            incompleteFolders = try await dbPool.read { db in
                try Folder.filter(
                    Column("accountId") == account.id &&
                    Column("backfillComplete") == false &&
                    Column("path") != ""
                ).fetchAll(db)
            }.sorted { a, b in
                func priority(_ f: Folder) -> Int {
                    switch f.role {
                    case .inbox: return 0
                    case .sent: return 1
                    case .archive: return 2
                    case .drafts: return 3
                    case .trash: return 4
                    case .spam: return 5
                    case .custom: return f.isFavorite ? 6 : 7
                    }
                }
                return priority(a) < priority(b)
            }
        } catch {
            print("[Backfill] Failed to fetch folders: \(error)")
            BackgroundSyncLogger.logError("Failed to fetch folders: \(error)", source: "backfill:\(account.emailAddress)")
            return false
        }

        guard !incompleteFolders.isEmpty else { return false }
        guard let provider = providers[account.id] else { return false }
        guard let workQueue = workQueues[account.id] else { return false }

        print("[Backfill] Starting for \(account.emailAddress): \(incompleteFolders.count) folders to backfill")

        var consecutiveConnectionFailures = 0
        var connectionBackoffSeconds: TimeInterval = 5  // Exponential backoff: 5, 10, 20, 40, 60 (max)
        var previousFolderId: String?  // Skip interFolderDelay when continuing same folder
        // Chunk sizes are managed per-folder by UIDWalkCursor (with recovery).
        // No cross-folder contamination — each folder gets a fresh cursor.

        await updateBackfillProgressForAccount(account)

        // ── Backward crawl — one folder at a time, most recent first ──
        // Each iteration picks the incomplete folder whose oldestSyncedDate is most
        // recent (shallowest crawl depth), fetches older messages via UID/page-token walk.
        // IMAP: walks from UIDNEXT-1 backward to UID 1.
        // Gmail/Exchange: page-token walk from newest to oldest.
        while true {
            guard !Task.isCancelled else { return didWork }
            guard !isPastDeadline() else { break }

            // Fresh DB read each iteration so we see folders completed by Step 1 or previous iterations
            let remaining: [Folder]
            do {
                remaining = try await dbPool.read { db in
                    try Folder.filter(
                        Column("accountId") == account.id &&
                        Column("backfillComplete") == false &&
                        Column("path") != ""
                    ).fetchAll(db)
                }
            } catch { break }
            guard !remaining.isEmpty else { break }

            // Pick folder by role priority (inbox→sent→archive→…→custom),
            // then most recent oldestSyncedDate within the same tier.
            func crawlPriority(_ f: Folder) -> Int {
                switch f.role {
                case .inbox: return 0
                case .sent: return 1
                case .archive: return 2
                case .drafts: return 3
                case .trash: return 4
                case .spam: return 5
                case .custom: return f.isFavorite ? 6 : 7
                }
            }
            let isExpensiveNetwork = NetworkMonitor.checkExpensive()
            let folder = remaining
                .filter { f in
                    if !fastSync && isExpensiveNetwork && !primaryRoles.contains(f.role) { return false }
                    if StorageEstimator.isOverBudget() { return false }
                    return true
                }
                .sorted { a, b in
                    let pa = crawlPriority(a), pb = crawlPriority(b)
                    if pa != pb { return pa < pb }
                    return (a.oldestSyncedDate ?? .distantFuture) > (b.oldestSyncedDate ?? .distantFuture)
                }
                .first

            guard let folder else {
                // All remaining folders are gated — done for this cycle
                break
            }

            let profile = await getBackfillProfile()
            let limit = profile.backfillChunkSize
            do {
                var headers: [MessageHeaderInfo] = []
                var isLastPage = false  // Gmail/Exchange: true when page-token walk has no more pages
                var insertedCount = 0

                if let imapProvider = provider as? IMAPProvider {
                    // IMAP: parallel UID walk with SEARCH-before-FETCH optimization.
                    // Same chunk structure as before (UIDWalkCursor, parallel workers),
                    // but each chunk does UID SEARCH first → if empty, skip FETCH entirely.
                    // For sparse folders (INBOX: 69k UIDs, 6 msgs) this skips ~99% of FETCHes.
                    // For dense folders, the extra SEARCH per chunk is ~3.5KB — negligible.

                    // Initialize cursor (from DB or UIDNEXT)
                    let cursorValue: Int
                    if let existing = folder.backfillUidCursor {
                        cursorValue = existing
                    } else {
                        let uidNext = try await workQueue.execute(priority: .headerFetch) {
                            try await imapProvider.getUidNext(folder: folder.path)
                        }
                        let initialCursor = uidNext - 1
                        if initialCursor < 1 {
                            try? await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db,
                                        Column("backfillComplete").set(to: true),
                                        Column("lastKnownUidNext").set(to: uidNext)
                                    )
                            }
                            print("[Backfill] \(folder.name) fully crawled (UIDNEXT=1, no messages)")
                            didWork = true
                            await updateBackfillProgressForAccount(account)
                            continue
                        }
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillUidCursor").set(to: initialCursor),
                                    Column("lastKnownUidNext").set(to: uidNext)
                                )
                        }
                        cursorValue = initialCursor
                    }

                    let cursor = UIDWalkCursor(startCursor: cursorValue, chunkSize: limit)
                    let poolMax = await imapProvider.poolMaxConnections()
                    let workerCount = poolMax < Int.max ? poolMax : SyncConfig.imapMaxConnectionCeiling
                    let folderCaptured = folder
                    let batchSize = profile.imapFetchBatchSize
                    let interBatchDelay = profile.imapInterBatchDelay
                    let lastProgressUpdate = ProgressThrottle()
                    let accountCaptured = account

                    await withTaskGroup(of: Bool.self) { group in
                        for workerIndex in 0..<workerCount {
                            group.addTask { [self] in
                                var workerDidWork = false
                                while let range = await cursor.nextRange() {
                                    guard !Task.isCancelled else {
                                        // Cancelled — return range for retry next cycle
                                        await cursor.failRange(from: range.from, to: range.to)
                                        break
                                    }

                                    // SEARCH first: discover which UIDs exist in this range
                                    let existingUIDs: [UInt32]
                                    do {
                                        existingUIDs = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.searchExistingUIDs(
                                                folder: folderCaptured.path, from: range.from, to: range.to
                                            )
                                        }
                                    } catch {
                                        // SEARCH failed — return range for retry
                                        await cursor.failRange(from: range.from, to: range.to)
                                        if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH connection error: \(error)")
                                            break
                                        }
                                        print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH error: \(error)")
                                        continue
                                    }

                                    if existingUIDs.isEmpty {
                                        // No messages in this range — confirmed empty, safe to advance
                                        await cursor.confirmRange(from: range.from, to: range.to)
                                        if await lastProgressUpdate.shouldUpdate() {
                                            let snapshotCursor = await cursor.currentCursor
                                            try? await AppDatabase.backgroundPool.write { db in
                                                _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                    .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                            }
                                            await self.updateBackfillProgressForAccount(accountCaptured)
                                        }
                                        continue
                                    }

                                    print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH found \(existingUIDs.count) UIDs in \(range.from)...\(range.to)")

                                    // FETCH only the existing UIDs
                                    let fetchedHeaders: [MessageHeaderInfo]
                                    do {
                                        fetchedHeaders = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.fetchMessageHeaders(
                                                folder: folderCaptured.path, uids: existingUIDs,
                                                batchSize: batchSize, interBatchDelay: interBatchDelay
                                            )
                                        }
                                    } catch {
                                        let desc = "\(error)"
                                        let isPayloadError = desc.contains("PayloadTooLargeError") || desc.contains("IMAPDecoderError")
                                        let isTimeout = desc.contains("timed out")
                                        if isPayloadError {
                                            let currentChunk = await cursor.currentChunkSize
                                            if currentChunk <= 1 {
                                                // Single UID too large — confirm anyway (can't split further)
                                                print("[Backfill] \(folderCaptured.name) w\(workerIndex) single UID too large — skipping")
                                                await cursor.confirmRange(from: range.from, to: range.to)
                                                continue
                                            }
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) payload too large, chunk → \(newChunk)")
                                            continue
                                        } else if isTimeout {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) timeout, chunk → \(newChunk)")
                                            continue
                                        } else if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) connection error: \(error)")
                                            break
                                        } else {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) error: \(error)")
                                            BackgroundSyncLogger.logError("\(folderCaptured.name) w\(workerIndex) error: \(error)", source: "backfill")
                                            break
                                        }
                                    }

                                    // Successfully fetched — insert to DB then confirm
                                    if !fetchedHeaders.isEmpty {
                                        let (inserted, ftsRecords, ccBccUpdates) = await self.insertBackfillBatch(
                                            fetchedHeaders, folderId: folderCaptured.id, accountId: folderCaptured.accountId,
                                            folderPath: folderCaptured.path, folderRole: folderCaptured.role, isInInbox: folderCaptured.role == .inbox
                                        )
                                        if !ftsRecords.isEmpty { await self.indexHeadersForFTS(ftsRecords) }
                                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                                        if inserted > 0 {
                                            workerDidWork = true
                                            await BackfillBodyQueue.shared.enqueueItems(
                                                ftsRecords: ftsRecords, accountId: folderCaptured.accountId,
                                                folderPath: folderCaptured.path, isInInbox: folderCaptured.role == .inbox
                                            )
                                        }
                                    }

                                    // Confirm AFTER successful DB insert
                                    await cursor.confirmRange(from: range.from, to: range.to)

                                    if await lastProgressUpdate.shouldUpdate() {
                                        let snapshotCursor = await cursor.currentCursor
                                        try? await AppDatabase.backgroundPool.write { db in
                                            _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                        }
                                        await self.updateBackfillProgressForAccount(accountCaptured)
                                    }
                                }
                                return workerDidWork
                            }
                        }
                        for await workerResult in group {
                            if workerResult { didWork = true }
                        }
                    }

                    // Persist confirmed cursor — only advances past ranges that succeeded
                    let finalCursor = await cursor.currentCursor
                    let isComplete = await cursor.isComplete
                    if isComplete {
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillUidCursor").set(to: nil as Int?)
                                )
                        }
                        print("[Backfill] \(folder.name) fully crawled (all ranges confirmed)")
                    } else {
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillUidCursor").set(to: finalCursor))
                        }
                        let hasPending = await cursor.hasPendingWork
                        if hasPending {
                            print("[Backfill] \(folder.name) has failed ranges — will retry next cycle (cursor at \(finalCursor))")
                        }
                    }
                    didWork = true
                    await updateBackfillProgressForAccount(account)
                    continue

                } else if provider is GmailProvider || provider is ExchangeProvider {
                    // Gmail/Exchange: page-token cursor walk — resumes from stored position.
                    // Each call returns one page of IDs + nextPageToken. No date filter needed;
                    // the token tracks position in the listing (newest→oldest).
                    let pageResult: (ids: [String], nextPageToken: String?)
                    if let gp = provider as? GmailProvider {
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await gp.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    } else {
                        let ep = provider as! ExchangeProvider
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await ep.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    }
                    let (pageIds, nextToken) = pageResult

                    if pageIds.isEmpty && nextToken == nil {
                        // No more pages — folder fully crawled
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillPageToken").set(to: nil as String?)
                                )
                        }
                        print("[Backfill] \(folder.name) fully crawled (no more pages)")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    // Page token is stored AFTER processing (not before) so that
                    // cancellation or failure mid-page causes the same page to be
                    // re-fetched next cycle. insertBackfillBatch handles dedup.

                    // Dedup returned IDs against DB
                    let missingIds: [String] = try await dbPool.read { db in
                        let sqlChunkSize = SyncConfig.sqlChunkSize
                        var existingIds = Set<String>()
                        for start in stride(from: 0, to: pageIds.count, by: sqlChunkSize) {
                            let end = min(start + sqlChunkSize, pageIds.count)
                            let chunk = Array(pageIds[start..<end])
                            let found = try String.fetchSet(db,
                                MessageHeader
                                    .select(Column("messageId"))
                                    .filter(Column("folderId") == folder.id && chunk.contains(Column("messageId")))
                            )
                            existingIds.formUnion(found)
                        }
                        return pageIds.filter { !existingIds.contains($0) }
                    }

                    if missingIds.isEmpty {
                        // All IDs on this page already in DB — update anchor for age cutoff tracking
                        let oldestDate: Date? = try? await dbPool.read { db in
                            try Date.fetchOne(db,
                                MessageHeader
                                    .select(min(Column("date")))
                                    .filter(Column("folderId") == folder.id && pageIds.contains(Column("messageId")))
                            )
                        }
                        if let d = oldestDate {
                            try await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db, Column("oldestSyncedDate").set(to: d))
                            }
                        }
                        // Safe to advance — all IDs on this page already exist in GRDB
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            try? await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db,
                                        Column("backfillComplete").set(to: true),
                                        Column("backfillPageToken").set(to: nil as String?)
                                    )
                            }
                            print("[Backfill] \(folder.name) fully crawled (last page, all exist)")
                            didWork = true
                        } else {
                            print("[Backfill] \(folder.name) all \(pageIds.count) IDs on page already exist — advancing to next page")
                        }
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    print("[Backfill] \(folder.name) \(missingIds.count) missing of \(pageIds.count) IDs on page")

                    // Unified fetch: headers + bodies in a single API call per message.
                    // Stream maintains `concurrency` in-flight HTTP requests at all times.
                    // We collect all results, then batch-insert headers and write bodies to FTS.
                    let stream: AsyncStream<BackfillResult>
                    let bodyConcurrency = profile.gmailBodyConcurrency
                    if let gp = provider as? GmailProvider {
                        stream = await gp.fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    } else {
                        stream = await (provider as! ExchangeProvider).fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    }

                    // Consume streaming results — collect headers + bodies together.
                    // Body data is keyed by messageId for matching after GRDB insert.
                    var bodyData: [String: (htmlBody: String?, textBody: String?)] = [:]
                    var streamInterrupted = false

                    for await result in stream {
                        if Task.isCancelled {
                            streamInterrupted = true
                            break
                        }
                        if let header = result.header {
                            headers.append(header)
                            bodyData[result.id] = (htmlBody: result.htmlBody, textBody: result.textBody)
                        }
                        if let error = result.error, case ProviderError.authenticationFailed = error {
                            await AccountManager.shared.markAuthFailed(account.id)
                            throw error
                        }
                    }

                    if !headers.isEmpty {
                        // Step 1: Insert headers to GRDB (batch dedup)
                        let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                            headers, folderId: folder.id, accountId: folder.accountId,
                            folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
                        )
                        if !ftsRecords.isEmpty { await indexHeadersForFTS(ftsRecords) }
                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                        insertedCount = inserted

                        // Step 2: Write bodies to FTS for inserted messages.
                        // Match body data to headerIds using ftsRecords (which have headerId + messageId).
                        var ftsBodyBuffer: [(headerId: String, body: String)] = []
                        var snippetBuffer: [(headerId: String, snippet: String)] = []
                        for ftsRecord in ftsRecords {
                            if let body = bodyData[ftsRecord.messageId] {
                                let plainText = EmailFilter.extractPlainText(htmlBody: body.htmlBody, textBody: body.textBody)
                                if let plainText, !plainText.isEmpty {
                                    ftsBodyBuffer.append((headerId: ftsRecord.headerId, body: plainText))
                                    let snippet = EmailFilter.snippetFromPlainText(plainText)
                                    snippetBuffer.append((headerId: ftsRecord.headerId, snippet: snippet))
                                }
                            }
                        }
                        if !ftsBodyBuffer.isEmpty {
                            do {
                                let writtenIds = try await SearchIndex.shared.updateBodies(ftsBodyBuffer)
                                // Only set bodyComplete for items actually written to FTS.
                                let confirmedSnippets = snippetBuffer.filter { writtenIds.contains($0.headerId) }
                                applySnippetUpdates(confirmedSnippets)
                                let skipped = ftsBodyBuffer.count - writtenIds.count
                                if skipped > 0 {
                                    print("[Backfill] \(folder.name) wrote \(writtenIds.count)/\(ftsBodyBuffer.count) bodies to FTS (\(skipped) deferred)")
                                } else {
                                    print("[Backfill] \(folder.name) wrote \(ftsBodyBuffer.count) bodies to FTS")
                                }
                            } catch {
                                print("[Backfill] FTS body write failed: \(error)")
                                BackgroundSyncLogger.logError("FTS body write failed for \(folder.name): \(error)", source: "backfill")
                            }
                        }

                        // Enqueue to ActiveBodyQueue — items with bodies already in FTS will be
                        // skipped (forwarding inbox items to ActiveAIQueue); items without
                        // bodies will be fetched by the queue.
                        if !ftsRecords.isEmpty {
                            await BackfillBodyQueue.shared.enqueueItems(
                                ftsRecords: ftsRecords, accountId: folder.accountId,
                                folderPath: folder.path, isInInbox: folder.role == .inbox
                            )
                        }
                    }

                    // Only advance page token if the full page was consumed.
                    // If stream was interrupted (cancellation), don't advance — the
                    // same page will be re-fetched next cycle (dedup handles duplicates).
                    if !streamInterrupted {
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            isLastPage = true
                        }
                    } else {
                        print("[Backfill] \(folder.name) stream interrupted — NOT advancing page token")
                    }
                } else {
                    break
                }

                if headers.isEmpty {
                    print("[Backfill] \(folder.name) fetch returned 0 headers — will retry next cycle")
                    continue
                }

                print("[Backfill] \(folder.name) fetched \(headers.count) older messages")

                // Update oldestSyncedDate from oldest fetched message
                if let oldest = headers.min(by: { $0.date < $1.date }) {
                    try await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db, Column("oldestSyncedDate").set(to: oldest.date))
                    }
                }

                // Gmail/Exchange: mark folder complete if this was the last page
                if isLastPage {
                    try? await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db,
                                Column("backfillComplete").set(to: true),
                                Column("backfillPageToken").set(to: nil as String?)
                            )
                    }
                    print("[Backfill] \(folder.name) fully crawled (last page processed)")
                }

                if insertedCount > 0 || isLastPage { didWork = true }
                consecutiveConnectionFailures = 0
                connectionBackoffSeconds = 5  // Reset backoff on success
            } catch is CancellationError {
                return didWork
            } catch {
                print("[Backfill] Failed for \(folder.name): \(error)")
                if !Self.isConnectionError(error) && !Self.isSelectFailedError(error) {
                    BackgroundSyncLogger.logError("Failed for \(folder.name): \(error)", source: "backfill:\(account.emailAddress)")
                }
                if case ProviderError.authenticationFailed = error {
                    await AccountManager.shared.markAuthFailed(account.id)
                    return didWork
                }
                if Self.isSelectFailedError(error) || Self.isConnectionError(error) {
                    // Treat SELECT failures as transient in backfill — the folder exists
                    // but the connection may be stale. Exponential backoff instead of aborting.
                    // Pool self-heals: dead connections are discarded on checkin(healthy: false),
                    // next checkout creates a fresh one.
                    consecutiveConnectionFailures += 1
                    print("[Backfill] Connection failure \(consecutiveConnectionFailures) — backing off \(Int(connectionBackoffSeconds))s")
                    try? await Task.sleep(for: .seconds(connectionBackoffSeconds))
                    connectionBackoffSeconds = min(60, connectionBackoffSeconds * 2)
                }
            }

            // Only delay between different folders — same folder continues immediately
            if previousFolderId != nil && previousFolderId != folder.id {
                try? await Task.sleep(for: .seconds(profile.interFolderDelay))
            }
            previousFolderId = folder.id
            await updateBackfillProgressForAccount(account)
        }

        await updateBackfillProgressForAccount(account)
        return didWork
    }

}
