/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Background Maintenance (nonisolated)

    /// Nonisolated prune — runs entirely off the main thread.
    nonisolated static func runPruneIfOverBudget(dbPool: PrioritizedDatabase) {
        guard StorageEstimator.isOverBudget() else { return }

        let totalMB = StorageEstimator.totalSizeMB()
        let budgetMB = StorageEstimator.budgetMB
        let floor = StorageEstimator.floorPerFolder
        print("[Prune] Over budget (\(String(format: "%.1f", totalMB))MB / \(budgetMB)MB)")

        let accounts = (try? dbPool.read { db in try Account.fetchAll(db) }) ?? []
        let pruneChunkSize = SyncConfig.pruneChunkSize

        // Fetch all folders once — reused for both body and header pruning
        var foldersByAccount: [String: [Folder]] = [:]
        for account in accounts {
            foldersByAccount[account.id] = (try? dbPool.read { db in
                try Folder.filter(Column("accountId") == account.id).fetchAll(db)
            }) ?? []
        }

        var bodiesRemoved = 0
        for account in accounts {
            let folders = foldersByAccount[account.id] ?? []
            for folder in folders {
                guard StorageEstimator.isOverBudget() else { break }
                let totalInFolder = (try? dbPool.read { db in
                    try MessageHeader.filter(Column("folderId") == folder.id).fetchCount(db)
                }) ?? 0
                guard totalInFolder > floor else { continue }
                let pruneCount = totalInFolder - floor

                var offset = 0
                while offset < pruneCount, StorageEstimator.isOverBudget() {
                    let headerIds: [String] = (try? dbPool.read { db in
                        try String.fetchAll(db,
                            MessageHeader
                                .select(Column("id"))
                                .filter(Column("folderId") == folder.id)
                                .order(Column("date").asc)
                                .limit(pruneChunkSize, offset: offset)
                        )
                    }) ?? []
                    guard !headerIds.isEmpty else { break }
                    let deleted = (try? dbPool.write { db in
                        try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(db)
                    }) ?? 0
                    bodiesRemoved += deleted
                    offset += headerIds.count
                }
            }
        }
        if bodiesRemoved > 0 {
            print("[Prune] Removed \(bodiesRemoved) message bodies")
        }

        var headersRemoved = 0
        for account in accounts {
            let folders = foldersByAccount[account.id] ?? []
            for folder in folders {
                guard StorageEstimator.isOverBudget() else { break }
                while StorageEstimator.isOverBudget() {
                    let currentCount = (try? dbPool.read { db in
                        try MessageHeader.filter(Column("folderId") == folder.id).fetchCount(db)
                    }) ?? 0
                    guard currentCount > floor else { break }
                    let batch: [MessageHeader] = (try? dbPool.read { db in
                        try MessageHeader
                            .filter(Column("folderId") == folder.id)
                            .order(Column("date").asc)
                            .limit(pruneChunkSize)
                            .fetchAll(db)
                    }) ?? []
                    guard !batch.isEmpty else { break }

                    var chunkIds: [String] = []
                    do {
                        try dbPool.write { db in
                            for msg in batch {
                                guard StorageEstimator.isOverBudget() else { break }
                                chunkIds.append(msg.id)
                                try msg.delete(db)
                                headersRemoved += 1
                            }
                        }
                    } catch {
                        print("[Prune] Delete failed: \(error)")
                    }
                    if !chunkIds.isEmpty {
                        // Routed through `MessageContentStore`. The headers were
                        // deleted in the write transaction just above, so this
                        // detached release counts owners in the post-delete world.
                        let keys = chunkIds.map(ContentKey.init(rawValue:))
                        Task.detached(priority: .utility) {
                            await MessageContentStore.releaseUnowned(
                                keys, stores: .searchIndex, pool: dbPool)
                        }
                    }
                }
            }
        }
        if headersRemoved > 0 {
            print("[Prune] Removed \(headersRemoved) message headers")
        }
        print("[Prune] Done — now \(String(format: "%.1f", StorageEstimator.totalSizeMB()))MB")
    }

    /// Nonisolated evict — runs entirely off the main thread.
    nonisolated static func runEvictStaleBodies(dbPool: PrioritizedDatabase, undoProtectedBodyIds: Set<String>) {
        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date()) ?? Date.distantPast
        let recentPerFolder = SyncConfig.bodyCacheRecentPerFolder
        let chunkSize = SyncConfig.pruneChunkSize

        let totalStale = (try? dbPool.read { db in
            try MessageBody.filter(Column("fetchedAt") < ttlCutoff).fetchCount(db)
        }) ?? 0
        guard totalStale > 0 else { return }

        var recentCache: [String: Set<String>] = [:]
        var evicted = 0
        var skipCount = 0
        while !Task.isCancelled {
            do {
                let batchResult = try dbPool.write { db -> (evicted: Int, skipped: Int, batchEmpty: Bool) in
                    let batch = try MessageBody
                        .filter(Column("fetchedAt") < ttlCutoff)
                        .limit(chunkSize, offset: skipCount)
                        .fetchAll(db)
                    guard !batch.isEmpty else { return (0, 0, true) }

                    var batchEvicted = 0
                    var batchSkipped = 0
                    for body in batch {
                        // ⚠ STAGE E1 — TWO CROSSINGS IN FOUR LINES. `body.id` is a
                        // CONTENT key; `undoProtectedBodyIds` holds `messageHeader.id`s
                        // (`UndoService.undoStack … messages.map(\.id)`) and the
                        // `fetchOne` below addresses `messageHeader` by primary key.
                        // Byte-identical today. At E1 the undo guard stops matching
                        // (a body the user can still undo gets evicted) and the header
                        // lookup misses (`header == nil` → the body is DELETED as an
                        // orphan). GRDB's `fetchOne(_:key:)` is generic over
                        // `DatabaseValueConvertible`, so neither crossing is
                        // compiler-visible — `.rawValue` is spelled out to make them
                        // greppable.
                        if undoProtectedBodyIds.contains(body.id.rawValue) {
                            batchSkipped += 1
                            continue
                        }
                        guard let header = try MessageHeader.fetchOne(db, key: body.id.rawValue) else {
                            try body.delete(db)
                            batchEvicted += 1
                            continue
                        }
                        if header.isInInbox {
                            batchSkipped += 1
                            continue
                        }
                        if recentCache[header.folderId] == nil {
                            let recentIds = try Set(String.fetchAll(db,
                                MessageHeader
                                    .select(Column("id"))
                                    .filter(Column("folderId") == header.folderId)
                                    .order(Column("date").desc)
                                    .limit(recentPerFolder)
                            ))
                            recentCache[header.folderId] = recentIds
                        }
                        if recentCache[header.folderId]?.contains(header.id) == true {
                            batchSkipped += 1
                            continue
                        }
                        try body.delete(db)
                        batchEvicted += 1
                    }
                    return (batchEvicted, batchSkipped, false)
                }
                if batchResult.batchEmpty { break }
                evicted += batchResult.evicted
                skipCount += batchResult.skipped
            } catch {
                print("[BodyCache] Eviction failed: \(error)")
                break
            }
        }
        if evicted > 0 {
            print("[BodyCache] Evicted \(evicted) stale bodies (TTL=\(SyncConfig.bodyCacheTTLHours)h)")
        }
    }

    /// Lazy TTL touch + purge — runs after AI queue drains, not during sync.
    /// Touches updatedAt on all inbox AI cache entries, then purges expired ones.
    /// Runs on a background thread to avoid GRDB writer lock contention on MainActor.
    nonisolated static func refreshAICacheTTLAndPurge(dbPool: PrioritizedDatabase) {
        // Touch: refresh TTL for all inbox messages' AI cache entries
        do {
            let touchedCount = try dbPool.write { db in
                // Get all inbox folder IDs
                let inboxFolderIds = try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchAll(db).map(\.id)
                guard !inboxFolderIds.isEmpty else { return 0 }

                // Build prefix patterns for LIKE queries
                var totalTouched = 0
                for folderId in inboxFolderIds {
                    let prefix = "\(folderId):"
                    let count = try MessageAICache
                        .filter(Column("key").like("\(prefix)%"))
                        .updateAll(db, Column("updatedAt").set(to: Date()))
                    totalTouched += count
                }
                return totalTouched
            }
            if touchedCount > 0 {
                print("[AICache] TTL refresh: touched \(touchedCount) inbox AI cache entries")
            }
        } catch {
            print("[AICache] TTL refresh failed: \(error)")
        }

        // Purge expired entries
        runPurgeExpiredAICache(dbPool: dbPool)
    }

    /// Nonisolated purge — runs entirely off the main thread.
    nonisolated static func runPurgeExpiredAICache(dbPool: PrioritizedDatabase) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: Date()) ?? Date.distantPast
        let chunkSize = SyncConfig.pruneChunkSize

        let count = (try? dbPool.read { db in
            try MessageAICache.filter(Column("updatedAt") < cutoff).fetchCount(db)
        }) ?? 0
        guard count > 0 else { return }

        let now = Date()
        var purged = 0
        var rescued = 0
        var skipCount = 0
        while true {
            do {
                let batchResult = try dbPool.write { db -> (purged: Int, rescued: Int, batchEmpty: Bool) in
                    let batch = try MessageAICache
                        .filter(Column("updatedAt") < cutoff)
                        .limit(chunkSize, offset: skipCount)
                        .fetchAll(db)
                    guard !batch.isEmpty else { return (0, 0, true) }

                    var batchPurged = 0
                    var batchRescued = 0
                    for var entry in batch {
                        if let msgId = entry.rfc822MessageId.map({ EmailFilter.normalizeMessageId($0) }), !msgId.isEmpty {
                            let headers = try MessageHeader
                                .filter(Column("rfc822MessageId") == msgId)
                                .limit(5)
                                .fetchAll(db)
                            if headers.contains(where: { $0.isInInbox }) {
                                entry.updatedAt = now
                                try entry.update(db)
                                batchRescued += 1
                                continue
                            }
                        }
                        try entry.delete(db)
                        batchPurged += 1
                    }
                    return (batchPurged, batchRescued, false)
                }
                if batchResult.batchEmpty { break }
                purged += batchResult.purged
                rescued += batchResult.rescued
                skipCount += batchResult.rescued
            } catch {
                print("[AICache] Purge failed: \(error)")
                break
            }
        }
        if purged > 0 || rescued > 0 {
            print("[AICache] Purged \(purged) expired entries, rescued \(rescued) still-in-inbox (TTL=\(SyncConfig.aiCacheTTLDays)d)")
        }
    }

    // MARK: - Stale Action Tag Sweep

    /// Clear local `actionTag` on non-inbox messages. Action tags are
    /// inbox-scoped — the chip should not follow a message into Archive /
    /// Trash / custom folders. Server-side keyword/label writes were
    /// removed in ADR-IOS-036 (action tags are local-only now), so this
    /// pass only touches GRDB.
    ///
    /// Gmail duplicate-label safety: if the same rfc822MessageId still
    /// exists in inbox, the tag is legitimate (Gmail shows the same
    /// message in both Inbox and All Mail) and we skip it.
    func sweepStaleActionTags(account: Account, provider _: any EmailProvider) async {
        let maxPerSweep = SyncConfig.pruneChunkSize

        // Collect inbox rfc822MessageIds for the duplicate-label guard.
        let inboxRfc822Ids: Set<String> = (try? await dbPool.read { db in
            let inboxHeaders = try MessageHeader
                .filter(Column("accountId") == account.id && Column("isInInbox") == true)
                .limit(SyncConfig.maxLoadedMessages)
                .fetchAll(db)
            var ids = Set<String>()
            for msg in inboxHeaders {
                if let rfc = msg.rfc822MessageId, !rfc.isEmpty {
                    ids.insert(rfc)
                }
            }
            return ids
        }) ?? []

        let folders = (try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id && Column("role") != FolderRole.inbox.rawValue).fetchAll(db)
        }) ?? []

        var cleared = 0
        for folder in folders {
            guard cleared < maxPerSweep else { break }
            let remaining = maxPerSweep - cleared
            let msgs: [MessageHeader] = (try? await dbPool.read { db in
                try MessageHeader
                    .filter(Column("folderId") == folder.id)
                    .limit(remaining)
                    .fetchAll(db)
            }) ?? []
            for msg in msgs where msg.actionTag != nil {
                guard cleared < maxPerSweep else { break }

                // Gmail safety: if this rfc822MessageId is still in inbox, skip.
                if let rfc = msg.rfc822MessageId, !rfc.isEmpty, inboxRfc822Ids.contains(rfc) {
                    continue
                }

                // Clear local state — action tags are local-only (ADR-IOS-036),
                // no server-side sync needed.
                let tag = msg.actionTag
                let messageId = msg.messageId
                try? await dbPool.write { db in
                    _ = try MessageHeader.filter(Column("id") == msg.id)
                        .updateAll(db,
                            Column("actionTag").set(to: nil as String?),
                            Column("tagSortOrder").set(to: 99)
                        )
                }

                cleared += 1
                print("[StaleTagSweep] Cleared \(tag?.rawValue ?? "?") from \(messageId) in \(folder.name)")
            }
        }

        if cleared > 0 {
            print("[StaleTagSweep] Swept \(cleared) stale tags for \(account.emailAddress)")
        }
    }

    // MARK: - Chat Session Eviction

    /// Evict old chat sessions and enforce global memory cap.
    ///
    /// **Session vs History distinction:**
    /// - *Resumable sessions* have raw `[Email](N)` references + ChatIdTranslator mappings.
    ///   The agent can interact with email references on resume.
    /// - *History* (memory) has dereferenced content — subjects baked in, no translator needed.
    ///   Searchable by MemorySearchTool but NOT resumable.
    ///
    /// **Phases:**
    /// 1. Message-detail: dereference sessions whose message left inbox (session→history transition)
    /// 2. Compose: delete turns older than TTL (compose sessions are never resumable; each opens fresh)
    /// 3. Compose drafts: DraftStore model eviction (count-based)
    /// 4. Global turn cap: delete oldest turns across all types (enforces Memory setting)
    nonisolated static func runEvictChatSessions(dbPool: PrioritizedDatabase) {
        let msgLimit = SyncConfig.maxMessageChatSessions
        let composeLimit = SyncConfig.maxComposeDraftSessions
        let composeTTL = SyncConfig.composeChatSessionTTLDays
        let maxTurns = UserDefaults.standard.integer(forKey: ChatPillState.maxMemoryTurnsKey)
        let effectiveMaxTurns = maxTurns > 0 ? maxTurns : ChatPillState.defaultMaxMemoryTurns

        // Phase 0: Inbox sessions — delete oldest beyond the Sessions limit.
        let inboxLimit = UserDefaults.standard.integer(forKey: ChatPillState.maxSessionsKey)
        let effectiveInboxLimit = inboxLimit > 0 ? inboxLimit : ChatPillState.defaultMaxSessions
        do {
            let evicted = try ChatStore.shared.evictInboxSessionsSync(dbPool: dbPool, limit: effectiveInboxLimit)
            if evicted > 0 {
                print("[ChatEviction] Evicted \(evicted) inbox sessions (limit=\(effectiveInboxLimit))")
            }
        } catch {
            print("[ChatEviction] Inbox session eviction failed: \(error)")
        }

        // Phase 1: Message-detail sessions — delete sessions whose message left inbox.
        do {
            let evicted = try ChatStore.shared.evictMessageDetailSessionsSync(dbPool: dbPool, limit: msgLimit)
            if evicted > 0 {
                print("[ChatEviction] Dereferenced \(evicted) message-detail sessions (limit=\(msgLimit))")
            }
        } catch {
            print("[ChatEviction] Message-detail eviction failed: \(error)")
        }

        // Phase 2: Compose chat turns — TTL-based deletion. Compose sessions are never
        // resumable (each new compose creates a fresh session). Old turns kept for memory
        // search until TTL expires.
        do {
            let evicted = try ChatStore.shared.evictComposeSessionsSync(dbPool: dbPool, ttlDays: composeTTL)
            if evicted > 0 {
                print("[ChatEviction] Evicted \(evicted) compose sessions (ttl=\(composeTTL) days)")
            }
        } catch {
            print("[ChatEviction] Compose chat session eviction failed: \(error)")
        }

        // Phase 3: Compose drafts (DraftStore model eviction)
        do {
            let evicted = try DraftStore.shared.evictSync(dbPool: dbPool, limit: composeLimit)
            if evicted > 0 {
                print("[ChatEviction] Evicted \(evicted) compose drafts (limit=\(composeLimit))")
            }
        } catch {
            print("[ChatEviction] Compose draft eviction failed: \(error)")
        }

        // Phase 4: Global turn cap — delete oldest turns first (across all session types).
        // This is the hard limit on total GRDB memory. User-configurable "Memory" setting.
        // Cascade evicted IDs to memory.db so `memory_search` doesn't surface content
        // that was evicted by the cap (ADR-IOS-034).
        do {
            let evictedIds = try ChatStore.shared.evictHistoryBeyondCapSync(dbPool: dbPool, maxTurns: effectiveMaxTurns)
            if !evictedIds.isEmpty {
                print("[ChatEviction] Evicted \(evictedIds.count) turns beyond cap (max=\(effectiveMaxTurns))")
                Task { @Sendable [evictedIds] in
                    await MemoryIndex.shared.deleteTurns(chatHistoryIds: evictedIds)
                }
            }
        } catch {
            print("[ChatEviction] Turn cap eviction failed: \(error)")
        }
    }
}
