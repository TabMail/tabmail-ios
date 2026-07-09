/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Delta Sync

    /// Attempt a delta sync. Returns (succeeded, hadChanges).
    /// succeeded=false means full sync needed. hadChanges=true means data was written.
    /// - Parameter inboxOnly: When true, IMAP delta sync only checks inbox folder (BGAppRefresh path).
    ///   Gmail/Exchange ignore this flag — their delta APIs return changes across all folders implicitly.
    func performDeltaSync(account: Account, provider: any EmailProvider, inboxOnly: Bool = false) async throws -> (succeeded: Bool, hadChanges: Bool) {
        if account.provider == .gmail, let gmailProvider = provider as? GmailProvider {
            return try await gmailDeltaSync(account: account, provider: gmailProvider)
        } else if account.provider == .outlook, let exchangeProvider = provider as? ExchangeProvider {
            return try await exchangeDeltaSync(account: account, provider: exchangeProvider)
        } else if (account.provider == .imap || account.provider == .icloud), let imapProvider = provider as? IMAPProvider {
            return try await imapDeltaSync(account: account, provider: imapProvider, inboxOnly: inboxOnly)
        }
        return (false, false)
    }

    /// Publish downloading phase for a specific account.
    private func publishDownloading(_ count: Int, forAccount accountId: String) {
        Task { @MainActor in
            AccountManagerState.shared.setSyncPhase(.downloading(count), forAccount: accountId)
        }
    }

    /// Gmail delta sync using history.list API.
    /// Fetches only what changed since lastHistoryId — typically 1 API call when nothing changed.
    private func gmailDeltaSync(account: Account, provider: GmailProvider) async throws -> (succeeded: Bool, hadChanges: Bool) {
        guard let historyId = account.lastHistoryId else {
            print("[Sync] Gmail delta: no historyId for \(account.emailAddress) — skipping (needs full sync)")
            BackgroundSyncLogger.log("gmailDelta: \(account.emailAddress) noHistoryId")
            return (false, false)
        }

        print("[Sync] Gmail delta: fetching history since \(historyId) for \(account.emailAddress)")
        guard let history = try await provider.fetchHistory(since: historyId) else {
            // History expired (404) — clear cursor so next sync does full
            print("[Sync] Gmail delta: history expired (404) for \(account.emailAddress) — clearing cursor")
            BackgroundSyncLogger.log("gmailDelta: \(account.emailAddress) historyExpired(404)")
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db, Column("lastHistoryId").set(to: nil as String?))
            }
            return (false, false)
        }

        let totalChanges = history.messagesAdded.count + history.messagesDeleted.count +
            history.labelsAdded.count + history.labelsRemoved.count
        let deltaLog = "gmailDelta: \(account.emailAddress) hid=\(historyId)→\(history.newHistoryId) +\(history.messagesAdded.count) -\(history.messagesDeleted.count) ~\(history.labelsAdded.count + history.labelsRemoved.count)"
        print("[Sync] \(deltaLog)")
        BackgroundSyncLogger.log(deltaLog)

        // historyId is advanced AFTER processing completes successfully (at end of method).
        // Advancing before processing risks losing messages: if processing is interrupted
        // (timeout, app kill, error), the cursor is past the changes but messages weren't
        // inserted. All future syncs then see "no changes." Re-processing the same changes
        // on retry is harmless (idempotent deletes/upserts) and far better than data loss.
        let newHistoryId = history.newHistoryId

        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id).fetchAll(db)
        }

        if totalChanges == 0 {
            // No changes — safe to advance cursor immediately
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db, Column("lastHistoryId").set(to: newHistoryId))
            }
            print("[Sync] Gmail delta: no changes")
            return (true, false)
        }

        print("[Sync] Gmail delta: +\(history.messagesAdded.count) added, -\(history.messagesDeleted.count) deleted, \(history.labelsAdded.count + history.labelsRemoved.count) label changes")

        // Collect all affected message IDs
        var toFetch = Set<String>()
        var toDelete = Set<String>()

        for msg in history.messagesAdded { toFetch.insert(msg.messageId) }
        for msg in history.messagesDeleted { toDelete.insert(msg.messageId) }
        for change in history.labelsAdded { toFetch.insert(change.messageId) }
        for change in history.labelsRemoved { toFetch.insert(change.messageId) }

        // Don't re-fetch deleted messages
        toFetch.subtract(toDelete)

        if !toFetch.isEmpty { publishDownloading(toFetch.count, forAccount: account.id) }

        // Capture recentlyCompleted (30s TTL) — bridges the gap between PendingOp deletion
        // and historyId cursor lag. Replaces per-folder recentActions.
        let mgr = AccountManager.shared
        let recentlyCompletedSnapshot = await mgr.recentlyCompleted

        // Delete removed messages — skip messages with pending operations.
        // Pending ops loaded INSIDE write to prevent TOCTOU race with user actions.

        if !toDelete.isEmpty {
            let deleteSet = toDelete
            let accountIdCapture = account.id
            let removedIds: [String] = try await dbPool.write { db in
                let snapshot = try PendingOperationSnapshot.load(accountId: accountIdCapture, db: db)
                var ids: [String] = []
                for deleteId in deleteSet {
                    let matches = try MessageHeader
                        .filter(Column("messageId") == deleteId)
                        .limit(10) // same message can be in multiple folders
                        .fetchAll(db)
                    for msg in matches {
                        // Two-key pending check: PendingOperation.messageIds uses
                        // `stableId` which is rfc822 for IMAP and messageId for
                        // Gmail/Exchange — checking only `deleteId` misses IMAP.
                        if snapshot.all.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId) {
                            continue
                        }
                        // Draft rekey visibility: pushDraftToServer mints a fresh
                        // Gmail message.id on every push (Gmail replaces rather than
                        // updates draft messages), so a background delta sync can
                        // observe the OLD draft message as "deleted" here — this is
                        // one half of the drafts-folder rekey (the matching insert
                        // for the NEW message.id is logged below). Narrow to the
                        // Drafts folder so this doesn't spray logs for ordinary mail.
                        if DebugModeManager.isLoggingEnabled(),
                           let draftsFolder = folders.first(where: { $0.id == msg.folderId && $0.role == .drafts }) {
                            print("[DraftRekey] Gmail delta: deleting drafts-folder header id=\(msg.id) messageId=\(msg.messageId) rfc822=\(msg.rfc822MessageId ?? "nil") folder=\(draftsFolder.name)")
                        }
                        ids.append(msg.id)
                        try msg.delete(db)
                    }
                }
                return ids
            }
            if !removedIds.isEmpty {
                removeHeadersFromFTS(removedIds)
                print("[Sync] Gmail delta: removed \(removedIds.count) messages")
            }
        }

        // Fetch current state of all changed messages and upsert
        var newHeaders: [MessageHeader] = []
        if !toFetch.isEmpty {
            let details = try await provider.fetchMessageDetails(ids: Array(toFetch))

            // Pending ops loaded INSIDE write transaction to prevent TOCTOU race with user actions.
            // Scoped to this account — Gmail IDs are globally unique so cross-folder collision
            // isn't possible, but accountId scoping prevents loading unrelated IMAP ops.
            let accountIdCapture = account.id
            let writeResult: (headers: [MessageHeader], discoveredParents: [String], removedIds: [String]) = try await dbPool.write { db in
                let snapshot = try PendingOperationSnapshot.load(accountId: accountIdCapture, db: db)
                var headers: [MessageHeader] = []
                var discoveredParents: [String] = []
                // Header ids removed from a folder by a label change (Gmail
                // archive/trash = INBOX label dropped). These must be pulled from
                // FTS too — otherwise the entry survives under its old folder-bearing
                // id, drifts from GRDB, and search re-hydration silently drops it.
                var removedIds: [String] = []
                for detail in details {
                    let info = detail.header
                    let labelIds = detail.labelIds
                    let isPendingAny = snapshot.all.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)
                    let isPendingDestructive = snapshot.destructive.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)

                    // Check all tracked folders for this message.
                    // Skip synthetic "All Mail" folder — membership is defined by absence of other
                    // labels, so labelIds.contains() can never match. Full sync handles it correctly.
                    for folder in folders where folder.path != GmailProvider.archivePath {
                        let existing = try MessageHeader
                            .filter(Column("messageId") == info.messageId && Column("folderId") == folder.id)
                            .fetchOne(db)
                        let existsLocally = existing != nil
                        let belongsInFolder = labelIds.contains(folder.path)

                        if existsLocally && !belongsInFolder && !isPendingAny {
                            // Message was removed from this folder (e.g., archived from inbox)
                            print("[MoveTrace] deltaSync — removing \(info.messageId) from \(folder.name)(\(folder.id)) — not in labels \(labelIds)")
                            if let existing {
                                removedIds.append(existing.id)
                                try existing.delete(db)
                            }
                        } else if existsLocally && !belongsInFolder && isPendingAny {
                            print("[MoveTrace] deltaSync — SKIPPING removal of \(info.messageId) from \(folder.name) — has pending op")
                        } else if !existsLocally && belongsInFolder && isPendingDestructive {
                            print("[MoveTrace] deltaSync — SKIPPING insert of \(info.messageId) into \(folder.name) — has pending destructive op")
                        } else if !existsLocally && belongsInFolder && recentlyCompletedSnapshot[info.messageId] != nil {
                            print("[MoveTrace] deltaSync — SKIPPING insert of \(info.messageId) into \(folder.name) — recently completed op")
                        } else if !existsLocally && belongsInFolder && !isPendingDestructive {
                            // New message in this folder
                            print("[MoveTrace] deltaSync — inserting \(info.messageId) into \(folder.name)(\(folder.id)) — labels=\(labelIds)")
                            // Other half of draft rekey visibility (see the matching
                            // delete-side log above): the NEW message.id Gmail minted
                            // for a re-pushed draft lands here as an ordinary insert.
                            if DebugModeManager.isLoggingEnabled(), folder.role == .drafts {
                                print("[DraftRekey] Gmail delta: inserting drafts-folder header messageId=\(info.messageId) into \(folder.name)")
                            }
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
                                accountId: account.id,
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
                                    accountId: account.id,
                                    folderPath: folder.path,
                                    tagValue: ActionTag.none.rawValue
                                )
                                try tagOp.insert(db)
                                print("[ReplyDetect] Delta insert: reply→none for \(header.messageId) (already replied)")
                            }
                            // Check for orphaned row with same id but wrong folderId
                            // (left behind by no-op optimistic move, e.g., archive from
                            // All Mail on Gmail). `fetchOne(db, key: header.id)` is safe
                            // because `header.id` encodes folderPath — two rows for the
                            // same UID in different folders never collide.
                            if var orphaned = try MessageHeader.fetchOne(db, key: header.id) {
                                // Respect pending user intention — if this row is queued for
                                // a destructive op (archive/delete/move), the user's
                                // optimistic folderPath is authoritative. Overwriting it
                                // with server state would silently undo the move; sync will
                                // converge when the op drains. This is the core orphan-reclaim fix.
                                let orphanIsPending = snapshot.destructive.containsAnyKey(
                                    messageId: orphaned.messageId,
                                    rfc822MessageId: orphaned.rfc822MessageId
                                )
                                if orphanIsPending {
                                    print("[MoveTrace] deltaSync — SKIPPING orphan reclaim for \(orphaned.id) — pending destructive op (server folder=\(folder.name) but user moved locally)")
                                    continue
                                }
                                print("[Sync] deltaSync reclaiming orphaned row \(header.id): folderId \(orphaned.folderId) → \(folder.id)")
                                orphaned.folderId = folder.id
                                orphaned.folderPath = folder.path
                                orphaned.isInInbox = folder.role == .inbox
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
                                headers.append(orphaned)
                            } else {
                                // Dedup optimistic sent headers by rfc822MessageId.
                                // Defer body insert until after header insert (FK constraint).
                                var deferredSentBody: MessageBody?
                                if folder.role == .sent,
                                   let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
                                   let optimistic = try MessageHeader
                                    .filter(Column("folderId") == folder.id && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                                    .fetchOne(db) {
                                    let oldId = optimistic.id
                                    if let body = try MessageBody.fetchOne(db, key: oldId) {
                                        var newBody = body
                                        newBody.id = header.id
                                        try MessageBody.deleteOne(db, key: oldId)
                                        deferredSentBody = newBody
                                    }
                                    removedIds.append(oldId)
                                    try optimistic.delete(db)
                                    print("[Sync] Gmail delta dedup: replaced optimistic sent header \(oldId) with \(header.id)")
                                }
                                // Defensive — an unrelated path (optimistic sent insert,
                                // NSE, sibling folder iteration) may have written this id
                                // inside the same transaction. Skipping the insert is
                                // always safer than throwing UNIQUE.
                                guard try MessageHeader.fetchOne(db, key: header.id) == nil else {
                                    print("[MoveTrace] deltaSync — SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                                    continue
                                }
                                try header.insert(db)
                                if let sentBody = deferredSentBody { try sentBody.insert(db) }
                                try ThreadUtils.insertMessageReferences(for: header, db: db)

                                // Insert user label associations
                                for labelId in info.userLabelIds {
                                    try UserLabel(id: labelId, accountId: account.id, name: labelId, isSystem: false)
                                        .insert(db, onConflict: .ignore)
                                    try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                                        .insert(db, onConflict: .ignore)
                                }

                                headers.append(header)

                                // Sent-folder reply discovery — no-op when folder.role != .sent.
                                let parents = try ReplyParentResolver.markParentsReplied(
                                    inReplyTos: [info.inReplyTo],
                                    folderRole: folder.role,
                                    accountId: account.id,
                                    db: db
                                )
                                discoveredParents.append(contentsOf: parents)
                            }
                        } else if existsLocally && belongsInFolder {
                            // Update flags on existing message.
                            if var existing {
                                let isPendingFlag = snapshot.flag.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)
                                if !isPendingFlag && recentlyCompletedSnapshot[info.messageId] == nil {
                                    existing.isRead = info.isRead
                                    existing.isFlagged = info.isFlagged
                                    if let serverTag = info.actionTag {
                                        if existing.actionTag != serverTag {
                                            print("[Sync] Gmail delta: remote tag change for \(info.messageId): \(existing.actionTag?.rawValue ?? "nil") -> \(serverTag.rawValue)")
                                            try MessageAICache.writeThrough(
                                                accountId: account.id,
                                                folderPath: folder.path,
                                                rfc822MessageId: existing.rfc822MessageId,
                                                actionTag: serverTag,
                                                db: db
                                            )
                                        }
                                        existing.actionTag = serverTag
                                        existing.tagSortOrder = serverTag.sortOrder
                                    }
                                }
                                existing.rfc822MessageId = info.rfc822MessageId
                                existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                                try existing.update(db)
                            }
                        }
                    }
                }
                return (headers, discoveredParents, removedIds)
            }
            newHeaders = writeResult.headers
            ReplyParentResolver.postParentNotifications(writeResult.discoveredParents)
            // Keep FTS aligned with GRDB: drop entries for messages that left a
            // folder via label change. Mirrors the messages-deleted path above.
            if !writeResult.removedIds.isEmpty {
                removeHeadersFromFTS(writeResult.removedIds)
                print("[Sync] Gmail delta: removed \(writeResult.removedIds.count) FTS entries for folder-departed messages")
            }

        }

        // Recount unread once after ALL header mutations (deletes + upserts + flag changes)
        // are committed to GRDB — before FTS/body queue which can take seconds.
        await UnreadCountManager.shared.requestRecount(folderIds: Set(folders.map(\.id)))

        if !newHeaders.isEmpty {
            await indexHeadersForFTS(newHeaders)
            print("[Sync] Gmail delta: +\(newHeaders.count) new messages")
            await ActiveBodyQueue.shared.enqueueBatch(newHeaders)
        }

        // Advance sync generation for all folders touched by this delta cycle.
        // Advance historyId AFTER all processing completed successfully.
        // If we crash/timeout before reaching this point, the next sync will
        // re-fetch and re-process the same changes (idempotent, no data loss).
        try await dbPool.write { db in
            _ = try Account.filter(Column("id") == account.id)
                .updateAll(db, Column("lastHistoryId").set(to: newHistoryId))
        }
        return (true, true)
    }

    /// Exchange delta sync using Graph delta API.
    /// Fetches only what changed since lastHistoryId (deltaLink token).
    private func exchangeDeltaSync(account: Account, provider: ExchangeProvider) async throws -> (succeeded: Bool, hadChanges: Bool) {
        guard let deltaToken = account.lastHistoryId else {
            print("[Sync] Exchange delta: no deltaToken for \(account.emailAddress) — skipping (needs full sync)")
            BackgroundSyncLogger.log("exchangeDelta: \(account.emailAddress) noToken")
            return (false, false)
        }

        guard let history = try await provider.fetchHistory(since: deltaToken) else {
            // Delta expired — clear cursor so next sync does full
            print("[Sync] Exchange delta: token expired for \(account.emailAddress) — clearing cursor")
            BackgroundSyncLogger.log("exchangeDelta: \(account.emailAddress) tokenExpired")
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db, Column("lastHistoryId").set(to: nil as String?))
            }
            return (false, false)
        }

        let totalChanges = history.messagesAdded.count + history.messagesDeleted.count +
            history.labelsAdded.count + history.labelsRemoved.count
        let exDeltaLog = "exchangeDelta: \(account.emailAddress) +\(history.messagesAdded.count) -\(history.messagesDeleted.count) ~\(history.labelsAdded.count + history.labelsRemoved.count)"
        print("[Sync] \(exDeltaLog)")
        BackgroundSyncLogger.log(exDeltaLog)

        // deltaToken is advanced AFTER processing completes successfully (at end of method).
        // Same rationale as Gmail: advancing before processing risks losing messages
        // if interrupted. Re-processing is idempotent and harmless.
        let newDeltaToken = history.newHistoryId

        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id).fetchAll(db)
        }

        if totalChanges == 0 {
            // No changes — safe to advance cursor immediately
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db, Column("lastHistoryId").set(to: newDeltaToken))
            }
            print("[Sync] Exchange delta: no changes")
            return (true, false)
        }

        print("[Sync] Exchange delta: +\(history.messagesAdded.count) added, -\(history.messagesDeleted.count) deleted, \(history.labelsAdded.count + history.labelsRemoved.count) label changes")

        // Collect all affected message IDs
        var toFetch = Set<String>()
        var toDelete = Set<String>()

        for msg in history.messagesAdded { toFetch.insert(msg.messageId) }
        for msg in history.messagesDeleted { toDelete.insert(msg.messageId) }
        for change in history.labelsAdded { toFetch.insert(change.messageId) }
        for change in history.labelsRemoved { toFetch.insert(change.messageId) }

        // Don't re-fetch deleted messages
        toFetch.subtract(toDelete)

        if !toFetch.isEmpty { publishDownloading(toFetch.count, forAccount: account.id) }

        // Capture recentlyCompleted — same guard as Gmail delta.
        let exMgr = AccountManager.shared
        let exRecentlyCompleted = await exMgr.recentlyCompleted

        // Delete removed messages — skip messages with pending operations.
        if !toDelete.isEmpty {
            let deleteSet = toDelete
            let exchangeAccountId = account.id
            let removedIds: [String] = try await dbPool.write { db in
                let snapshot = try PendingOperationSnapshot.load(accountId: exchangeAccountId, db: db)
                var ids: [String] = []
                for deleteId in deleteSet {
                    let matches = try MessageHeader
                        .filter(Column("messageId") == deleteId)
                        .limit(10)
                        .fetchAll(db)
                    for msg in matches {
                        if snapshot.all.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId) {
                            continue
                        }
                        ids.append(msg.id)
                        try msg.delete(db)
                    }
                }
                return ids
            }
            if !removedIds.isEmpty {
                removeHeadersFromFTS(removedIds)
                print("[Sync] Exchange delta: removed \(removedIds.count) messages")
            }
        }

        // Fetch current state of all changed messages and upsert
        var exNewHeaders: [MessageHeader] = []
        if !toFetch.isEmpty {
            let details = try await provider.fetchMessageDetails(ids: Array(toFetch))

            let exchangeAccountId = account.id
            let writeResult: (headers: [MessageHeader], discoveredParents: [String], removedIds: [String]) = try await dbPool.write { db in
                let snapshot = try PendingOperationSnapshot.load(accountId: exchangeAccountId, db: db)
                var headers: [MessageHeader] = []
                var discoveredParents: [String] = []
                // Header ids deleted by sent-dedup — must be pulled from FTS too,
                // or the optimistic entry survives as a stale orphan.
                var removedIds: [String] = []
                for detail in details {
                    let info = detail.header
                    let folderId = detail.parentFolderId

                    // Find matching local folder
                    guard let folder = folders.first(where: { $0.id == folderId || $0.path == folderId }) else {
                        continue
                    }

                    let existing = try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folder.id)
                        .fetchOne(db)
                    let existsLocally = existing != nil
                    let isPendingDestructive = snapshot.destructive.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)
                    let isPendingFlag = snapshot.flag.containsAnyKey(messageId: info.messageId, rfc822MessageId: info.rfc822MessageId)

                    let isRecentlyDone = exRecentlyCompleted[info.messageId] != nil

                    if existsLocally && (isPendingFlag || isRecentlyDone) {
                        // Has pending or recently completed flag ops — only update non-flag fields
                        if var existing {
                            existing.rfc822MessageId = info.rfc822MessageId
                            existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                            try existing.update(db)
                        }
                    } else if existsLocally {
                        // Update flags on existing message
                        if var existing {
                            existing.isRead = info.isRead
                            existing.isFlagged = info.isFlagged
                            if let serverTag = info.actionTag {
                                if existing.actionTag != serverTag {
                                    print("[Sync] Exchange delta: remote tag change for \(info.messageId): \(existing.actionTag?.rawValue ?? "nil") -> \(serverTag.rawValue)")
                                    try MessageAICache.writeThrough(
                                        accountId: account.id,
                                        folderPath: folder.path,
                                        rfc822MessageId: existing.rfc822MessageId,
                                        actionTag: serverTag,
                                        db: db
                                    )
                                }
                                existing.actionTag = serverTag
                                existing.tagSortOrder = serverTag.sortOrder
                            }
                            existing.rfc822MessageId = info.rfc822MessageId
                            existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                            try existing.update(db)
                        }
                    } else if isPendingDestructive || isRecentlyDone {
                        // Skip — pending destructive op or recently completed
                        print("[MoveTrace] exchangeDelta — SKIPPING insert of \(info.messageId) into \(folder.name) — has pending destructive op or recent completion")
                    } else {
                        // New message
                        print("[MoveTrace] exchangeDelta — inserting \(info.messageId) into \(folder.name)(\(folder.id))")
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
                            accountId: account.id,
                            folderPath: folder.path,
                            db: db
                        )
                        if header.isReplied && header.actionTag == .reply {
                            header.actionTag = ActionTag.none
                            header.tagSortOrder = ActionTag.none.sortOrder
                            let tagOp = PendingOperation(
                                type: .setTag,
                                messageIds: [header.stableId],
                                accountId: account.id,
                                folderPath: folder.path,
                                tagValue: ActionTag.none.rawValue
                            )
                            try tagOp.insert(db)
                            print("[ReplyDetect] Delta insert: reply→none for \(header.messageId) (already replied)")
                        }
                        // Check for orphaned row with same id but wrong folderId.
                        if var orphaned = try MessageHeader.fetchOne(db, key: header.id) {
                            let orphanIsPending = snapshot.destructive.containsAnyKey(
                                messageId: orphaned.messageId,
                                rfc822MessageId: orphaned.rfc822MessageId
                            )
                            if orphanIsPending {
                                print("[MoveTrace] exchangeDelta — SKIPPING orphan reclaim for \(orphaned.id) — pending destructive op (server folder=\(folder.name) but user moved locally)")
                                continue
                            }
                            print("[Sync] exchangeDelta reclaiming orphaned row \(header.id): folderId \(orphaned.folderId) → \(folder.id)")
                            orphaned.folderId = folder.id
                            orphaned.folderPath = folder.path
                            orphaned.isInInbox = folder.role == .inbox
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
                            headers.append(orphaned)
                        } else {
                            // Dedup optimistic sent headers by rfc822MessageId.
                            // Defer body insert until after header insert (FK constraint).
                            var deferredSentBody: MessageBody?
                            if folder.role == .sent,
                               let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
                               let optimistic = try MessageHeader
                                .filter(Column("folderId") == folder.id && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                                .fetchOne(db) {
                                let oldId = optimistic.id
                                if let body = try MessageBody.fetchOne(db, key: oldId) {
                                    var newBody = body
                                    newBody.id = header.id
                                    try MessageBody.deleteOne(db, key: oldId)
                                    deferredSentBody = newBody
                                }
                                removedIds.append(oldId)
                                try optimistic.delete(db)
                                print("[Sync] Exchange delta dedup: replaced optimistic sent header \(oldId) with \(header.id)")
                            }
                            guard try MessageHeader.fetchOne(db, key: header.id) == nil else {
                                print("[MoveTrace] exchangeDelta — SKIPPING insert for id=\(header.id) — already exists (post-snapshot)")
                                continue
                            }
                            try header.insert(db)
                            if let sentBody = deferredSentBody { try sentBody.insert(db) }
                            try ThreadUtils.insertMessageReferences(for: header, db: db)

                            // Insert user label associations (Exchange: empty for now)
                            for labelId in info.userLabelIds {
                                try UserLabel(id: labelId, accountId: account.id, name: labelId, isSystem: false)
                                    .insert(db, onConflict: .ignore)
                                try MessageUserLabel(messageId: header.id, userLabelId: labelId)
                                    .insert(db, onConflict: .ignore)
                            }

                            headers.append(header)

                            // Sent-folder reply discovery — no-op when folder.role != .sent.
                            let parents = try ReplyParentResolver.markParentsReplied(
                                inReplyTos: [info.inReplyTo],
                                folderRole: folder.role,
                                accountId: account.id,
                                db: db
                            )
                            discoveredParents.append(contentsOf: parents)
                        }
                    }
                }
                return (headers, discoveredParents, removedIds)
            }
            exNewHeaders = writeResult.headers
            ReplyParentResolver.postParentNotifications(writeResult.discoveredParents)
            // Keep FTS aligned with GRDB: drop entries for sent-dedup-replaced headers.
            if !writeResult.removedIds.isEmpty {
                removeHeadersFromFTS(writeResult.removedIds)
            }

        }

        // Recount unread once after ALL header mutations (deletes + upserts + flag changes)
        // are committed to GRDB — before FTS/body queue which can take seconds.
        await UnreadCountManager.shared.requestRecount(folderIds: Set(folders.map(\.id)))

        if !exNewHeaders.isEmpty {
            await indexHeadersForFTS(exNewHeaders)
            print("[Sync] Exchange delta: +\(exNewHeaders.count) new messages")
            await ActiveBodyQueue.shared.enqueueBatch(exNewHeaders)
        }

        // Advance deltaToken AFTER all processing completed successfully.
        try await dbPool.write { db in
            _ = try Account.filter(Column("id") == account.id)
                .updateAll(db, Column("lastHistoryId").set(to: newDeltaToken))
        }
        return (true, true)
    }

    /// CONDSTORE (RFC 7162) flag-change signal for IMAP delta: does the server's
    /// current HIGHESTMODSEQ indicate a change since our cached cursor? True ONLY when
    /// both are present AND differ. A nil `server` (server doesn't advertise CONDSTORE)
    /// or nil `cached` (first observation / not yet recorded) yields false → the caller
    /// falls back to its uidNext+count comparison (exactly today's behavior). Pure +
    /// nonisolated for unit testing; the epoch (UIDVALIDITY) subtlety is handled safely
    /// upstream because this only gates FETCHING, never deletion.
    nonisolated static func modSeqIndicatesChange(server: Int?, cached: Int?) -> Bool {
        guard let server, let cached else { return false }
        return server != cached
    }

    /// IMAP delta sync using STATUS-based change detection.
    /// Calls STATUS on each folder to check uidNext/messageCount — skips unchanged folders.
    private func imapDeltaSync(account: Account, provider: IMAPProvider, inboxOnly: Bool = false) async throws -> (succeeded: Bool, hadChanges: Bool) {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id).fetchAll(db)
        }
        let syncableFolders = folders.filter { folder in
            guard !folder.path.isEmpty else { return false }
            if inboxOnly {
                // BGAppRefresh: only check inbox to minimize battery drain
                return folder.role == .inbox
            }
            return primaryRoles.contains(folder.role) ||
                secondaryRoles.contains(folder.role) ||
                folder.isFavorite
        }

        guard !syncableFolders.isEmpty else { return (true, false) }

        // SELECT INBOX + NOOP flushes pending server-side state — without this,
        // some IMAP servers return cached STATUS values on persistent connections
        // and miss new mail. SELECT is the lowest-common-denominator approach.
        try await provider.flushServerState()

        var anyChanged = false
        for folder in syncableFolders {
            let status = try await provider.folderStatus(path: folder.path)

            let uidNextChanged = folder.lastKnownUidNext != nil && status.uidNext != folder.lastKnownUidNext
            let countChanged = status.messageCount != folder.totalCount
            // CONDSTORE flag-awareness (RFC 7162): HIGHESTMODSEQ bumps on \Seen/flag
            // changes to EXISTING messages that leave uidNext+count unchanged — which the
            // two checks above MISS today (a message read on another client stays "unread"
            // on iOS until an unrelated add/delete happens to trip a resync, or never, if
            // it's below the top-N window). This gate only decides whether we FETCH, never
            // whether we delete (stale/reconcile own deletions, with their own UIDVALIDITY
            // guards), so it's safe by construction: a wrong result at worst delays a flag
            // update one cycle. Non-CONDSTORE servers (nil modseq) and the first
            // observation (nil cursor) yield no modseq signal → exactly today's behavior.
            // A UIDVALIDITY change resets the server's modseq, but that also moves
            // uidNext/count → caught by those; we still refresh the cursor below.
            let modSeqChanged = Self.modSeqIndicatesChange(
                server: status.highestModSeq, cached: folder.lastKnownHighestModSeq)

            if !uidNextChanged && !countChanged && !modSeqChanged {
                print("[Sync] IMAP delta: \(folder.name) unchanged (uidNext=\(status.uidNext), count=\(status.messageCount), modseq=\(status.highestModSeq.map(String.init) ?? "-"))")
                continue
            }

            // Something changed — sync this folder
            print("[Sync] IMAP delta: \(folder.name) changed (uidNext: \(folder.lastKnownUidNext ?? 0)→\(status.uidNext), count: \(folder.totalCount)→\(status.messageCount))")
            let newCount = max(0, status.messageCount - folder.totalCount)
            if newCount > 0 { publishDownloading(newCount, forAccount: account.id) }
            do {
                try await syncMessages(
                    for: folder,
                    provider: provider,
                    limit: SyncConfig.syncMessageLimit
                )
            } catch {
                if SyncEngine.isSelectFailedError(error) {
                    print("[Sync] IMAP delta: SELECT failed for \(folder.name) — skipping")
                    continue
                }
                throw error
            }

            // Update cached state (uidNext, totalCount) — unread recount handled by UnreadCountManager
            try await dbPool.write { db in
                var assignments: [ColumnAssignment] = [
                    Column("lastKnownUidNext").set(to: status.uidNext),
                    Column("totalCount").set(to: status.messageCount)
                ]
                // Refresh the CONDSTORE cursor so the NEXT delta can detect flag-only
                // changes. A UIDVALIDITY change moves uidNext/count (→ this path re-runs),
                // so a stale-epoch modseq self-corrects on the following cycle.
                if let modseq = status.highestModSeq {
                    assignments.append(Column("lastKnownHighestModSeq").set(to: modseq))
                }
                _ = try Folder.filter(Column("id") == folder.id).updateAll(db, assignments)
            }

            // ADR-IOS-051 Phase 2 trigger: compare the LIVE local header count
            // against the just-fetched STATUS count (NOT the cached totalCount,
            // which the overwrite above consumes). Local GRDB is a partial
            // mirror — optimistic local deletes only LOWER local count — so
            // localCount > serverCount proves ghost rows below the windowed
            // sync's UID floor. `local < server` is backfill-normal and never
            // triggers.
            do {
                let folderId = folder.id
                let localCount = try await dbPool.read { db in
                    try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
                }
                if Self.shouldReconcileDeletions(
                    localCount: localCount,
                    serverCount: status.messageCount,
                    tolerance: SyncConfig.deletionReconcileCountTolerance
                ) {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] IMAP delta: \(folder.name) local=\(localCount) > server=\(status.messageCount) — reconciling external deletions")
                    }
                    await reconcileExternallyDeletedMessages(
                        folder: folder,
                        provider: provider,
                        expectedGhosts: localCount - status.messageCount
                    )
                }
            } catch {
                // Trigger evaluation is best-effort — the evidence is durable
                // and re-fires on the next delta/full sync pass.
                if DebugModeManager.isLoggingEnabled() {
                    print("[Sync] IMAP delta: reconcile trigger check failed for \(folder.name): \(error)")
                }
            }

            // syncGeneration advanced inside syncMessages() — no need to advance here.
            anyChanged = true
        }

        if !anyChanged {
            print("[Sync] IMAP delta: no changes across \(syncableFolders.count) folders")
            BackgroundSyncLogger.log("imapDelta: \(account.emailAddress) noChanges (\(syncableFolders.count) folders)")
        } else {
            BackgroundSyncLogger.log("imapDelta: \(account.emailAddress) changed")
            // Unread recount is now handled per-folder inside syncMessages, immediately after header commit.
        }

        return (true, anyChanged)
    }

    /// Capture sync cursors after a full sync so delta sync can detect changes next time.
    /// For Gmail: only advances historyId forward (never overwrites a newer cursor from delta sync).
    func captureSyncCursors(account: Account, provider: any EmailProvider) async {
        if account.provider == .gmail, let gmailProvider = provider as? GmailProvider {
            do {
                let newHistoryId = try await gmailProvider.getCurrentHistoryId()
                try await dbPool.write { db in
                    // Only advance — never go backwards. Delta sync may have set a
                    // more recent historyId that this profile API call must not overwrite.
                    if let newId = newHistoryId,
                       let current = try Account.fetchOne(db, key: account.id)?.lastHistoryId,
                       let newVal = UInt64(newId),
                       let curVal = UInt64(current),
                       newVal <= curVal {
                        print("[Sync] Gmail historyId: keeping \(current) (profile returned \(newId))")
                        return
                    }
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastHistoryId").set(to: newHistoryId))
                }
                print("[Sync] Captured Gmail historyId: \(newHistoryId ?? "nil")")
            } catch {
                print("[Sync] Failed to capture Gmail historyId: \(error)")
            }
        } else if account.provider == .outlook, let exchangeProvider = provider as? ExchangeProvider {
            do {
                // Capture delta link for inbox folder
                let inboxFolder = try await dbPool.read { db in
                    try Folder.filter(Column("accountId") == account.id && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
                }
                guard let inboxFolder else {
                    print("[Sync] No inbox folder found for Exchange account — skipping delta capture")
                    return
                }
                let deltaLink = try await exchangeProvider.getCurrentDeltaLink(folderId: inboxFolder.path)
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastHistoryId").set(to: deltaLink))
                }
                print("[Sync] Captured Exchange deltaLink: \(deltaLink != nil ? "present" : "nil")")
            } catch {
                print("[Sync] Failed to capture Exchange deltaLink: \(error)")
            }
        } else if account.provider == .imap || account.provider == .icloud {
            // uidNext is set during fullSync → fetchFolders via FolderInfo.uidNext
        }
    }
}
