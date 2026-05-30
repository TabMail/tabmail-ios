/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UIKit

actor SyncEngine {
    private(set) var providers: [String: any EmailProvider] = [:]
    private(set) var workQueues: [String: ProviderWorkQueue] = [:]

    /// Roles to sync messages for (inbox gets most, others get fewer)
    let primaryRoles: Set<FolderRole> = [.inbox]
    let secondaryRoles: Set<FolderRole> = [.sent, .drafts, .trash, .archive, .spam]

    var headerBackfillTasks: [String: Task<Void, Never>] = [:]

    /// Cached server-reported total message count for Gmail/Exchange accounts.
    /// Used as progress denominator instead of FTS row count (which grows with crawl).
    var serverMessageTotal: [String: Int] = [:]

    /// Generation counter per account — prevents stale task defer from clearing
    /// a replacement task's dictionary entry after resetCrawlState.
    var backfillGeneration: [String: Int] = [:]

    /// FTS bulk-indexing tasks, keyed by account ID (one per account).
    var bulkIndexTasks: [String: Task<Void, Never>] = [:]

    /// Embedding rebuild task (one at a time).

    /// One-shot flag so the `recoverIncompleteHeaders` EXPLAIN QUERY PLAN probe
    /// only logs once per process lifetime. Diagnosing the persistent 3-5s cost
    /// we see even when the query returns 0 rows.
    var recoverIncompleteExplainLogged = false

    /// GRDB DatabasePool — thread-safe, no background queue needed.
    var dbPool: DatabasePool { AppDatabase.dbPool }

    /// Read current fast sync mode state from AccountManager (MainActor hop).
    func getIsFastSync() async -> Bool {
        await MainActor.run { AccountManagerState.shared.fastSyncModeActive }
    }

    /// Notify UI + trigger unread recount after sync modifies messageHeader rows.
    /// Called at the end of each provider's delta/full sync.
    /// folderIds: the folders whose headers were modified (for targeted recount).
    /// Request unread recount for affected folders. UnreadCountManager handles
    /// debouncing, DB recount, badge update, and posts .backgroundDataDidChange.
    func requestUnreadRecount(folderIds: Set<String>) async {
        await UnreadCountManager.shared.requestRecount(folderIds: folderIds)
    }

    /// Compute current backfill profile from device power state.
    /// Four tiers:
    ///   .turbo      — user-triggered fast sync. Max throughput, UI may lag.
    ///   .aggressive — plugged in. Full throughput, UI stays responsive (priority lock).
    ///   .normal     — on battery. Moderate progress, reasonable drain.
    ///   .low        — thermal throttling. Minimal resource usage.
    /// Note: Low Power Mode and battery < 20% pause backfill entirely (getShouldPauseBackfill).
    /// Reads UIDevice state via MainActor hop — always returns latest power state.
    func getBackfillProfile() async -> BackfillProfile {
        await MainActor.run {
            let isFastSync = AccountManagerState.shared.fastSyncModeActive
            if isFastSync { return .turbo }
            let isOnPower = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            let isThermallyThrottled = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious
            if isOnPower && !isThermallyThrottled {
                return .aggressive
            }
            if isThermallyThrottled {
                return .low
            }
            return .normal
        }
    }

    /// Whether backfill should be paused entirely.
    /// Pauses when: battery < 20% (not charging), or Low Power Mode enabled.
    /// Fast sync mode bypasses this gate entirely.
    /// Reads UIDevice state via MainActor hop.
    func getShouldPauseBackfill() async -> Bool {
        await MainActor.run {
            let isFastSync = AccountManagerState.shared.fastSyncModeActive
            if isFastSync { return false }
            let isOnPower = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            if ProcessInfo.processInfo.isLowPowerModeEnabled && !isOnPower { return true }
            let level = UIDevice.current.batteryLevel
            // batteryLevel returns -1 if monitoring not enabled (shouldn't happen — set in TabMailApp.init)
            return !isOnPower && level >= 0 && level < 0.20
        }
    }

    func register(accountId: String, provider: any EmailProvider, workQueue: ProviderWorkQueue) {
        providers[accountId] = provider
        workQueues[accountId] = workQueue
    }

    /// Cancel all FTS-related tasks across all accounts. Called before index rebuild
    /// to prevent stale tasks from blocking new bulk index via the per-account guard.
    func cancelAllFTSTasks() {
        for (_, task) in bulkIndexTasks { task.cancel() }
        bulkIndexTasks.removeAll()
        // Also cancel backfill workers since they write to FTS
        for (_, task) in headerBackfillTasks { task.cancel() }
        headerBackfillTasks.removeAll()
    }

    /// Reset backfill state for a single account (e.g., Settings reset).
    /// Cancels the worker and clears completion flag so backfill re-launches.
    func resetBackfill(accountId: String) {
        headerBackfillTasks[accountId]?.cancel()
        headerBackfillTasks.removeValue(forKey: accountId)
    }

    func remove(accountId: String) async {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)

        // Cancel and await background tasks to ensure no stale references remain active
        if let backfillTask = headerBackfillTasks.removeValue(forKey: accountId) {
            backfillTask.cancel()
            await backfillTask.value // wait for cancellation to propagate
        }
        if let indexTask = bulkIndexTasks.removeValue(forKey: accountId) {
            indexTask.cancel()
            await indexTask.value // wait for cancellation to propagate
        }
    }

    // MARK: - Background Maintenance

    private var maintenanceTask: Task<Void, Never>?

    /// Run evict/purge/prune off the main thread. These use synchronous GRDB
    /// operations that would block the main actor if called inline.
    /// Captures all MainActor-isolated state before detaching.
    func scheduleMaintenanceInBackground(includePrune: Bool = false) {
        maintenanceTask?.cancel()
        let pool = AppDatabase.dbPool
        maintenanceTask = Task.detached(priority: .utility) {
            // Capture undo-protected IDs via MainActor hop (UndoService is @MainActor)
            let undoProtectedBodyIds = await MainActor.run {
                Set(UndoService.shared.undoStack.flatMap { $0.messages.map(\.id) })
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            if includePrune && !Task.isCancelled {
                SyncEngine.runPruneIfOverBudget(dbPool: pool)
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            if !Task.isCancelled {
                SyncEngine.runEvictStaleBodies(dbPool: pool, undoProtectedBodyIds: undoProtectedBodyIds)
            }
            let t2 = CFAbsoluteTimeGetCurrent()
            if !Task.isCancelled {
                SyncEngine.runPurgeExpiredAICache(dbPool: pool)
            }
            let t3 = CFAbsoluteTimeGetCurrent()
            if !Task.isCancelled {
                SyncEngine.runEvictChatSessions(dbPool: pool)
            }
            let t4 = CFAbsoluteTimeGetCurrent()
            // BodyAssetStore maintenance: evict if attachments are over the user's
            // budget, then sweep orphan files (NSE-written assets whose push got
            // dropped, eviction crashes, etc.). Both are no-ops on cold + empty state,
            // and idempotent on repeated runs. Order matters: evict first so the
            // sweep doesn't have to walk freshly-evicted-but-still-on-disk files
            // (it would skip them anyway via the min-age guard).
            if !Task.isCancelled {
                await BodyAssetMaintenance.evictIfOverCap()
            }
            let t5 = CFAbsoluteTimeGetCurrent()
            if !Task.isCancelled {
                await BodyAssetMaintenance.pruneOrphans()
            }
            let t6 = CFAbsoluteTimeGetCurrent()
            if includePrune {
                print("[Sync] Background maintenance: prune=\(Int((t1-t0)*1000))ms evict=\(Int((t2-t1)*1000))ms purge=\(Int((t3-t2)*1000))ms chatEvict=\(Int((t4-t3)*1000))ms assetEvict=\(Int((t5-t4)*1000))ms assetSweep=\(Int((t6-t5)*1000))ms")
            } else {
                print("[Sync] Background maintenance: evict=\(Int((t2-t1)*1000))ms purge=\(Int((t3-t2)*1000))ms chatEvict=\(Int((t4-t3)*1000))ms assetEvict=\(Int((t5-t4)*1000))ms assetSweep=\(Int((t6-t5)*1000))ms")
            }
        }
    }

    /// Two-tier sync: tries delta sync first (fast), falls back to full sync (robust).
    /// Delta sync runs on frequent polls (every 60s) — checks only what changed.
    // MARK: - Background-Safe Delta Sync

    /// Lightweight delta-only sync for background execution (BGAppRefreshTask, silent push).
    /// Only fetches new headers and enqueues to body/AI/embedding queues.
    /// Does NOT start backfill, bulk index, embedding rebuild, or full sync fallback.
    /// Designed to complete well within iOS's ~30s background budget.
    /// Returns (changed, reason) where reason describes what happened for diagnostics.
    @discardableResult
    func backgroundDeltaSync(account: Account, inboxOnly: Bool = false) async throws -> (changed: Bool, reason: String) {
        guard let queue = workQueues[account.id] else {
            print("[Sync:bg] No provider for \(account.emailAddress) — skipping")
            BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) noProvider")
            return (false, "noProvider")
        }
        let provider = queue.provider

        // No syncing guard here — background delta syncs run concurrently with
        // foreground syncs. Delta operations are idempotent (upserts, no-op deletes),
        // and historyId/deltaToken writes are monotonically increasing, so concurrent
        // execution is safe and prevents pushes from being blocked by slow foreground polls.

        // Pool creates connections on demand via checkout — no explicit connect needed.
        // Callers (AccountManager.backgroundSyncOne) already call ensureConnected() upstream.

        // Only attempt delta — never fall through to full sync in background.
        // Full sync is too heavy for the 30s budget and will run on next foreground poll.
        // Each provider's delta sync already checks its own cursor validity:
        // - Gmail: returns (false, false) if lastHistoryId is nil
        // - Outlook: returns (false, false) if delta token is missing
        // - IMAP/iCloud: stateless STATUS commands, always works
        // No time-based guard needed here.

        // Publish sync phase so push-triggered/background syncs show "Checking..."
        // in the subtitle, not just the foreground path. Defer clears on return.
        let accountId = account.id
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }
        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }

        do {
            let result = try await queue.execute(priority: .headerFetch) {
                try await self.performDeltaSync(account: account, provider: provider, inboxOnly: inboxOnly)
            }
            if result.succeeded {
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                }
                print("[Sync:bg] Delta sync completed for \(account.emailAddress) (changes: \(result.hadChanges))")
                return (result.hadChanges, result.hadChanges ? "deltaChanges" : "deltaNoChanges")
            } else {
                print("[Sync:bg] Delta not ready for \(account.emailAddress) (no cursor or expired) — will full-sync on foreground")
                BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) noCursor")
                return (false, "noCursor")
            }
        } catch {
            if Self.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry without disconnect/reconnect.
                print("[Sync:bg] Connection error for \(account.emailAddress): \(error) — retrying")
                let retry = try await queue.execute(priority: .headerFetch) {
                    try await self.performDeltaSync(account: account, provider: provider, inboxOnly: inboxOnly)
                }
                if retry.succeeded {
                    try await dbPool.write { db in
                        _ = try Account.filter(Column("id") == account.id)
                            .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                    }
                    print("[Sync:bg] Delta sync completed for \(account.emailAddress) after retry (changes: \(retry.hadChanges))")
                    return (retry.hadChanges, retry.hadChanges ? "deltaChanges(retry)" : "deltaNoChanges(retry)")
                }
            }
            print("[Sync:bg] Delta sync failed for \(account.emailAddress): \(error) — will full-sync on foreground")
            BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) ERROR: \(error)")
            if !(error is CancellationError) && !Self.isConnectionError(error) {
                BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
            }
            let errorDesc = String(describing: error).prefix(100)
            return (false, "error(\(errorDesc))")
        }
    }

    // MARK: - Foreground Sync

    private let fullSyncInterval: TimeInterval = 900 // 15 minutes

    /// Foreground sync: always tries delta first, then runs full sync separately
    /// if it's been >15 min since the last one (self-healing safety net).
    /// Pull-to-refresh also uses this — delta is always the fast path.
    @discardableResult
    func sync(account: Account) async throws -> Bool {
        guard let queue = workQueues[account.id] else {
            print("[Sync] No provider registered for \(account.emailAddress) — skipping")
            return false
        }
        let provider = queue.provider

        // Skip if this account was synced very recently — prevents redundant syncs
        // from overlapping callers (RootView.task, SyncScheduler, InboxViewModel).
        if let lastSync = account.lastSyncedAt, Date().timeIntervalSince(lastSync) < 15 {
            print("[Sync] Skipping \(account.emailAddress) — synced \(Int(Date().timeIntervalSince(lastSync)))s ago")
            return false
        }

        // No per-account sync guard — ProviderWorkQueue handles concurrency.
        // Duplicate foreground syncs for the same account serialize through the work queue.
        let accountId = account.id
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }

        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }

        // Pool creates connections on demand via checkout — no explicit connect needed.

        // 1. Always try delta sync first — this is the fast path for every poll/pull-to-refresh.
        var hadChanges = false
        var deltaSyncSucceeded = false
        var deltaSyncError: (any Error)?
        do {
            let deltaResult = try await queue.execute(priority: .headerFetch) {
                try await self.performDeltaSync(account: account, provider: provider)
            }
            if deltaResult.succeeded {
                deltaSyncSucceeded = true
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                }
                hadChanges = deltaResult.hadChanges
                print("[Sync] Delta sync completed for \(account.emailAddress) (changes: \(hadChanges))")
            }
        } catch {
            deltaSyncError = error
            if Self.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry without disconnect/reconnect.
                print("[Sync] Delta sync connection error for \(account.emailAddress): \(error) — retrying")
                do {
                    let retryResult = try await queue.execute(priority: .headerFetch) {
                        try await self.performDeltaSync(account: account, provider: provider)
                    }
                    if retryResult.succeeded {
                        deltaSyncSucceeded = true
                        deltaSyncError = nil
                        try await dbPool.write { db in
                            _ = try Account.filter(Column("id") == account.id)
                                .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                        }
                        hadChanges = retryResult.hadChanges
                        print("[Sync] Delta sync completed for \(account.emailAddress) (after retry, changes: \(hadChanges))")
                    }
                } catch {
                    deltaSyncError = error
                    print("[Sync] Delta sync retry also failed for \(account.emailAddress): \(error)")
                    if !(error is CancellationError) && !Self.isConnectionError(error) {
                        BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
                    }
                }
            } else {
                print("[Sync] Delta sync failed for \(account.emailAddress): \(error)")
                if !(error is CancellationError) {
                    BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
                }
            }
        }

        // 2. Full sync runs separately on its own schedule (~15 min) as a self-healing safety net.
        //    NOT a fallback from delta — runs independently regardless of delta success/failure.
        let timeSinceFullSync = account.lastFullSyncAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if timeSinceFullSync >= fullSyncInterval {
            print("[Sync] Full sync due for \(account.emailAddress) (last: \(timeSinceFullSync.isFinite ? "\(Int(timeSinceFullSync))s" : "never"))...")
            do {
                try await queue.execute(priority: .headerFetch) {
                    try await self.fullSync(account: account, provider: provider)
                }
            } catch {
                if Self.isConnectionError(error) {
                    // Pool self-heals: dead connections discarded on checkin(healthy: false),
                    // next checkout creates a fresh one. Retry without disconnect/reconnect.
                    print("[Sync] Connection lost during full sync, retrying...")
                    try await queue.execute(priority: .headerFetch) {
                        try await self.fullSync(account: account, provider: provider)
                    }
                } else {
                    if !(error is CancellationError) {
                        BackgroundSyncLogger.logError("\(error)", source: "fullSync:\(account.emailAddress)")
                    }
                    throw error
                }
            }

            await queue.execute(priority: .headerFetch) {
                await self.captureSyncCursors(account: account, provider: provider)
            }

            let now = Date()
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db,
                        Column("lastSyncedAt").set(to: now),
                        Column("lastFullSyncAt").set(to: now)
                    )
            }
            print("[Sync] Full sync completed for \(account.emailAddress)")
            hadChanges = true

            // Post-full-sync maintenance
            await queue.execute(priority: .bodyFetch) {
                await self.sweepStaleActionTags(account: account, provider: provider)
            }
            await queue.execute(priority: .bodyFetch) {
                await self.selfHealRecentMessages(account: account)
            }
        }

        // If delta sync failed and full sync didn't run (not due yet), no server contact
        // succeeded — propagate the error so the caller knows sync failed. Without this,
        // the caller reports success and updates lastSyncCompletedAt, showing "Updated less
        // than a minute ago" even when offline.
        if !deltaSyncSucceeded, timeSinceFullSync < fullSyncInterval, let error = deltaSyncError {
            throw error
        }

        // 3. Background work — runs after every sync (delta or full)
        print("[Sync] \(account.emailAddress) calling startBackfill")
        startBackfill(account: account)
        bulkIndexIfNeeded(account: account)
        backfillFolderIdsIfNeeded()

        return hadChanges
    }

    // MARK: - Infinite Scroll (Fetch Older Messages)

    /// Fetch older messages for the given folders (infinite scroll).
    /// Returns the number of new messages loaded across all folders.
    func fetchOlderMessages(folders: [Folder]) async throws -> Int {
        var totalNew = 0
        for folder in folders {
            guard let queue = workQueues[folder.accountId] else { continue }
            let provider = queue.provider

            // Find oldest date
            let oldestDate: Date = try await dbPool.read { db in
                try MessageHeader
                    .filter(Column("folderId") == folder.id)
                    .order(Column("date").asc)
                    .limit(1)
                    .fetchOne(db)?.date ?? Date()
            }

            let headers: [MessageHeaderInfo]
            do {
                headers = try await queue.execute(priority: .userAction) {
                    if let imapProvider = provider as? IMAPProvider {
                        return try await imapProvider.fetchOlderMessages(folder: folder.path, before: oldestDate, limit: 25)
                    } else if let gmailProvider = provider as? GmailProvider {
                        return try await gmailProvider.fetchOlderMessages(folder: folder.path, before: oldestDate, limit: 25)
                    } else if let exchangeProvider = provider as? ExchangeProvider {
                        return try await exchangeProvider.fetchOlderMessages(folder: folder.path, before: oldestDate, limit: 25)
                    }
                    return []
                }
            } catch {
                if SyncEngine.isSelectFailedError(error) {
                    print("[InfiniteScroll] SELECT failed for \(folder.name) — skipping")
                    BackgroundSyncLogger.logError("SELECT failed for \(folder.name): \(error)", source: "infiniteScroll")
                    continue
                }
                throw error
            }

            // Deduplicate and insert
            let writeResult: (inserted: [MessageHeader], discoveredParents: [String]) = try await dbPool.write { db in
                var inserted: [MessageHeader] = []
                for info in headers {
                    let exists = try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folder.id)
                        .fetchCount(db) > 0
                    if exists { continue }

                    var header = MessageHeader(
                        messageId: info.messageId,
                        subject: info.subject,
                        from: info.from,
                        fromAddress: info.fromAddress,
                        to: info.to,
                        date: info.date,
                        snippet: EmailFilter.cleanSnippet(info.snippet),
                        folderId: folder.id,
                        accountId: folder.accountId,
                        folderPath: folder.path,
                        isInInbox: folder.role == .inbox
                    )
                    header.rfc822MessageId = info.rfc822MessageId
                    header.inReplyTo = info.inReplyTo
                    header.referencesJSON = MessageHeader.encodeReferences(info.references)
                    header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: folder.accountId, subject: header.subject)
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
                        accountId: folder.accountId,
                        folderPath: folder.path,
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
                            accountId: folder.accountId,
                            folderPath: folder.path,
                            tagValue: ActionTag.none.rawValue
                        )
                        try tagOp.insert(db)
                        print("[ReplyDetect] Scroll insert: reply→none for \(header.messageId) (already replied)")
                    }
                    try header.save(db)
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    inserted.append(header)
                }

                // Sent-folder reply discovery — no-op when folder.role != .sent.
                let discovered = try ReplyParentResolver.markParentsReplied(
                    inReplyTos: headers.map(\.inReplyTo),
                    folderRole: folder.role,
                    accountId: folder.accountId,
                    db: db
                )

                return (inserted, discovered)
            }
            let newHeaders = writeResult.inserted
            ReplyParentResolver.postParentNotifications(writeResult.discoveredParents)

            if !newHeaders.isEmpty {
                await indexHeadersForFTS(newHeaders)
                print("[InfiniteScroll] \(folder.name): +\(newHeaders.count) older messages")
            }
            totalNew += newHeaders.count
        }
        return totalNew
    }

    /// Apply snippet updates directly to GRDB — no background queue needed.
    /// Also marks bodyComplete = true since FTS body was written in the same batch.
    func applySnippetUpdates(_ updates: [(headerId: String, snippet: String)]) {
        guard !updates.isEmpty else { return }
        do {
            try dbPool.write { db in
                for (headerId, snippet) in updates {
                    try MessageHeader.filter(Column("id") == headerId)
                        .updateAll(db,
                                   Column("snippet").set(to: snippet),
                                   Column("bodyComplete").set(to: true))
                }
            }
        } catch {
            print("[SnippetFill] Update failed: \(error)")
            BackgroundSyncLogger.logError("Snippet update failed: \(error)", source: "snippetFill")
        }
    }

    /// Detect SELECT failures (server returned BAD/NO to SELECT command).
    /// This means the folder is inaccessible — renamed, deleted, or the server rejects it.
    /// Not a connection error — the connection is fine, just this folder can't be opened.
    /// Callers should skip the folder and continue with the next one.
    nonisolated static func isSelectFailedError(_ error: Error) -> Bool {
        let msg = "\(error)"
        return msg.contains("Select mailbox failed")
    }

    /// Detect connection-related errors (stale socket, server disconnect, parser corruption, etc.)
    /// Used by sync and backfill paths to decide whether to reconnect.
    /// IMAPDecoderError = NIO parser buffer is corrupted (leftover bytes from previous response).
    /// Once this happens the connection is permanently broken — must disconnect and reconnect.
    /// NOTE: ProviderError.networkError (HTTP 4xx/5xx) is NOT a connection error — the request
    /// completed and the server responded. Only transport-level failures warrant reconnection.
    nonisolated static func isConnectionError(_ error: Error) -> Bool {
        if case ProviderError.notConnected = error { return true }
        // URLError from URLSession (Gmail/Exchange HTTP): airplane mode, DNS failure, connection lost, etc.
        if error is URLError { return true }
        // NIOCore.ChannelError — raw NIO transport failure that escaped SwiftMail's IMAPError wrapping
        // (e.g. writeAndFlush on an already-closed channel during auth/IDLE/command paths). The case
        // name (`alreadyClosed`, `ioOnClosedChannel`, `connectPending`, …) does not match any of the
        // substrings below, and `error.localizedDescription` becomes the bridged NSError form
        // ("The operation couldn't be completed. (NIOCore.ChannelError error N.)") which leaks to the
        // UI when this predicate misses it. Domain check covers every case without importing NIO.
        if (error as NSError).domain == "NIOCore.ChannelError" { return true }
        let msg = "\(error)"
        return msg.contains("notConnected") || msg.contains("not connected")
            || msg.contains("Connection reset") || msg.contains("command failed")
            || msg.contains("broken pipe") || msg.contains("connection closed") || msg.contains("Connection closed")
            || msg.contains("Connection failed") // IMAPError.connectionFailed — covers all inner reasons
            || msg.contains("closed channel") || msg.contains("I/O on closed")
            || msg.contains("bad(Error in IMAP")
            || msg.contains("EPIPE") || msg.contains("timed out")
            || msg.contains("IMAPDecoderError") || msg.contains("IMAPDecodeError")
            || msg.contains("NIOConnectionError") // NIOPosix.NIOConnectionError — TCP connection failed
            || msg.contains("ChannelError") // NIOCore.ChannelError (already-bridged string form)
            || msg.contains("DNS error") // NIO DNS resolution failure (no internet, DNS unreachable)
            || msg.contains("connection appears to be offline") // URLSession offline description
            || msg.contains("max_userip_connections") // Server rejected — too many IMAP connections (handled by adaptive concurrency)
    }
}
