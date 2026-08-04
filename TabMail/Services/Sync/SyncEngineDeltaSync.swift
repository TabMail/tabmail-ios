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

        // Capture recentlyCompleted — bridges the gap between PendingOp deletion
        // and historyId cursor lag (default TTL), and protects freshly push-merged
        // arrivals (longer TTL). Replaces per-folder recentActions. Prune first: the
        // reads below are presence checks (`!= nil`), which don't consult the
        // per-entry expiry — an unpruned map would treat expired entries as still
        // protected forever.
        let mgr = AccountManager.shared
        await mgr.pruneRecentlyCompleted()
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
                                orphaned.observedUidValidity = nil
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
                                    if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
                                        var newBody = body
                                        newBody.id = ContentKey(rawValue: header.id)
                                        try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
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
                                    let labelRow = UserLabel(accountId: account.id, providerLabelId: labelId, name: labelId, isSystem: false)
                                    try labelRow.insert(db, onConflict: .ignore)
                                    // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                                    // the bare provider value (D10 / `IOS-LABEL-001`).
                                    try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
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
                                existing.observedUidValidity = nil
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

        // Capture recentlyCompleted — same guard as Gmail delta. Prune first (see
        // comment above the Gmail delta snapshot) since the reads below are
        // presence checks that don't consult per-entry expiry.
        let exMgr = AccountManager.shared
        await exMgr.pruneRecentlyCompleted()
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
                            existing.observedUidValidity = nil
                            existing.rfc822MessageId = info.rfc822MessageId
                            existing.referencesJSON = MessageHeader.encodeReferences(info.references)
                            try existing.update(db)
                        }
                    } else if existsLocally {
                        // Update flags on existing message
                        if var existing {
                            existing.observedUidValidity = nil
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
                            orphaned.observedUidValidity = nil
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
                                if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
                                    var newBody = body
                                    newBody.id = ContentKey(rawValue: header.id)
                                    try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
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
                                let labelRow = UserLabel(accountId: account.id, providerLabelId: labelId, name: labelId, isSystem: false)
                                try labelRow.insert(db, onConflict: .ignore)
                                // The join FK is `userLabel.id` — the account-prefixed SURROGATE, never
                                // the bare provider value (D10 / `IOS-LABEL-001`).
                                try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
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

    /// A UIDVALIDITY the server ACTUALLY reported, or nil for "unknown" — the
    /// shared choke point every epoch predicate and every epoch write below
    /// normalises through.
    ///
    /// RFC 3501 §2.3.1.1 types UIDVALIDITY as `nz-number` (a NON-ZERO unsigned
    /// 32-bit value), so `0` can only ever mean "not reported". The repo already
    /// settled that convention: `UIDExistenceResult.uidValidity` is documented
    /// *"0 = the server did not report a value (callers must treat as unknown and
    /// abort any deletion decision — never delete on uncertainty)"* and enforced at
    /// `SyncEngineDeletionReconcile.swift:144`. Normalising HERE — rather than at
    /// each call site — is what stops a future SELECT-sourced caller from
    /// introducing one: `Mailbox.Selection.uidValidity` is non-optional only
    /// because SwiftMail DEFAULTS it to `UIDValidity(0)`
    /// (`SwiftMail/IMAP/Models/Mailbox.swift:160`), which is not an RFC guarantee.
    /// Persisting that 0 would make every downstream epoch comparison `0 == 0`,
    /// i.e. vacuously true, silently disarming the guards built on it.
    ///
    /// REFERENCE (`v2final`): identical convention — `guard observed != 0 else
    /// { return }` at the head of the single persist API
    /// (`AccountManager.recordObservedUidValidity`), plus `known > 0` on every
    /// read of `Folder.lastKnownUidValidity` into its epoch ledger.
    nonisolated static func knownUidValidity(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// The value a SYNC path may persist into `Folder.lastKnownUidValidity`, or nil
    /// for "write nothing". **BOOTSTRAP-ONLY — this is a data-safety rule, not an
    /// optimisation.**
    ///
    /// That column is not a general-purpose "last epoch the server reported" field:
    /// it is the deletion-reconcile walk's ABORT GUARD (ADR-IOS-051, see
    /// `Folder.swift`), and its safety depends on it meaning *the epoch the LOCAL
    /// UIDs belong to*. The walk reads it from the DB
    /// (`SyncEngineDeletionReconcile.swift:373`) and aborts when the live SELECT
    /// disagrees (`:151-155`). Keeping the column synced to the live server epoch
    /// would make that comparison always equal — so on a real UIDVALIDITY turnover
    /// the walk would stop aborting and instead delete every local header as a
    /// "ghost", up to `expectedGhosts + SyncConfig.deletionReconcileCapSlack`. Hence:
    ///
    /// - observation unknown (nil, or the `0` sentinel) ⇒ write nothing;
    /// - column already holds a value ⇒ write nothing, whether it AGREES (no
    ///   redundant write — WAL etiquette) or DIFFERS (a turnover; the UID-remap /
    ///   resync machinery owns stamping a new epoch, only ever together with the
    ///   purge of the rows that belonged to the old one);
    /// - column empty + observation known ⇒ bootstrap it (the point of the item:
    ///   a folder the walk has never visited still ends up with a usable epoch).
    ///
    /// ⚠ **T4.S6b added a FOURTH branch, and it is NOT expressible here.** A folder
    /// that already HOLDS `messageHeader` rows may not be stamped by assertion — see
    /// `uidValidityBootstrapWrite(observed:stored:folderHoldsRows:)` below and the
    /// `NOT EXISTS` term in `bootstrapFolderUidValidity`. This two-argument form is
    /// pure and answers only the observed-vs-stored half of the decision; every
    /// caller must ALSO discharge the header-existence half, either through the
    /// three-argument overload (callers holding a `Database` and their own record)
    /// or by routing the write through `bootstrapFolderUidValidity` (which carries
    /// the term in the STATEMENT).
    ///
    /// REFERENCE (`v2final`): the identical three-branch contract, expressed as the
    /// single persist API `AccountManager.recordObservedUidValidity`
    /// (`AccountManager.swift:838`) — *"First observation … persist … Same value:
    /// no write (WAL etiquette) … CHANGED value: does NOT overwrite the stored value
    /// (a later stage's reaction owns stamping the new epoch, as part of the purge)
    /// … `observed == 0`: unreported, never recorded, never compared."*
    /// Pure + nonisolated for unit testing.
    nonisolated static func uidValidityBootstrapWrite(observed: Int?, stored: Int?) -> Int? {
        guard stored == nil else { return nil }
        return knownUidValidity(observed)
    }

    /// The T4.S6b form: the same decision, plus the header-existence term that makes
    /// an UNVERIFIED stamp impossible. For callers that hold a `Database` AND the
    /// `Folder` record they are about to `update`/`insert` inside that same write
    /// transaction — today the two folder-list upsert arms in `SyncEngine.fullSync`,
    /// which cannot route through `bootstrapFolderUidValidity` because they set the
    /// field on a record rather than issuing a statement.
    ///
    /// `folderHoldsRows` MUST be read from the SAME write transaction as the write
    /// it gates (no suspension in between), for the same TOCTOU reason the
    /// `lastKnownUidValidity IS NULL` predicate lives in the statement.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`.** Verified three ways, so the next agent
    /// does not re-derive them: (1) `v2final`'s single persist API
    /// `AccountManager.recordObservedUidValidity` stamps a nil row without ever
    /// asking whether headers exist; (2) `git grep` over
    /// `v2final -- 'TabMail/Services/Sync/*' 'TabMail/Services/Account/*'` finds no
    /// `localHeaders`, no `fetchCount(db)` near any epoch write, and no
    /// `prePopulated`/`unverified`/`verifyEpoch` term; (3) `v2final`'s
    /// `uidValidityWriteAllowed`/`uidValidityWalkWriteAllowed` are OBSERVED-VS-STORED
    /// comparisons that both fail OPEN on a nil stored side. The reference never
    /// named this hazard; v3's `Folder.lastKnownUidValidity` doc comment is where it
    /// was first named, and this is where it is closed.
    nonisolated static func uidValidityBootstrapWrite(
        observed: Int?, stored: Int?, folderHoldsRows: Bool
    ) -> Int? {
        guard !folderHoldsRows else { return nil }
        return uidValidityBootstrapWrite(observed: observed, stored: stored)
    }

    /// The bootstrap epoch write itself, as ONE conditional UPDATE, inside a
    /// transaction the caller already owns. Used by delta sync's unchanged and
    /// changed branches (STATUS-sourced), by `runSyncMessages` (SELECT-sourced,
    /// T1.2b) and by `SyncEngine.runBackfill`'s IMAP branch, through the gated
    /// wrapper `SyncEngine.bootstrapCrawledFolderUidValidity` (SELECT-sourced, the
    /// T1.3 anti-brick).
    ///
    /// ⚠ Round 7 described that backfill caller as "the ONLY writer that reaches a
    /// custom non-favourite folder, which no `syncableFolders` pass ever visits".
    /// RETRACTED (round 8): on-demand navigation reaches ANY folder via
    /// `AccountManager.syncFolders(_:)` → `SyncEngine.syncFolderMessages` →
    /// `runSyncMessages`, whose filter is `!folder.path.isEmpty` and nothing else.
    /// The crawl's bootstrap is still needed — backfill makes a folder's mail
    /// account-wide searchable long before the user ever opens it — but the window
    /// it closes is INDEFINITE, not permanent.
    ///
    /// ⚠ It is NOT the only writer of `Folder.lastKnownUidValidity`, and treating
    /// it as one would be dangerous — this column's safety property depends on
    /// knowing every writer (see the column's own doc comment on `Folder`). The
    /// complete set of BOOTSTRAP writers is THREE (a fourth writer, which ADVANCES
    /// rather than bootstraps, is enumerated after them):
    ///  1. this function — `runSyncMessages` and delta sync's changed branch call it
    ///     directly, delta sync's unchanged branch through the async wrapper of the
    ///     same name below, and `runBackfill`'s IMAP branch (in the FILE
    ///     `SyncEngineBackfillWalk.swift`, which is an `extension SyncEngine`; there
    ///     is no `SyncEngineBackfillWalk` type to cite) through
    ///     `bootstrapCrawledFolderUidValidity`, which adds a "the folder holds no
    ///     local UID yet" precondition on top of this one and must be the crawl's
    ///     only door to this function;
    ///  2. the folder-list upsert in `SyncEngine.fullSync` (`SyncEngineFullSync.swift`), which sets the
    ///     field on the `Folder` record it is already updating/inserting rather
    ///     than issuing a separate statement — it is safe without the in-statement
    ///     predicate because it reads `localFolders` INSIDE its own write
    ///     transaction, so its snapshot cannot be stale, and it routes its decision
    ///     through the same `uidValidityBootstrapWrite`;
    ///  3. `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch` (in the FILE
    ///     `SyncEngineEpochVerify.swift`) — the T4.S6b VERIFIED door, and the ONLY
    ///     path by which a folder that already holds rows may ever be stamped. It
    ///     does NOT come through this function: it writes through
    ///     `bootstrapVerifiedFolderUidValidity` below, which omits the `NOT EXISTS`
    ///     term and keeps `lastKnownUidValidity IS NULL`, because by the time it
    ///     runs it has PROVEN by FETCH that the folder's own rows still answer at
    ///     their own UIDs under the epoch it is about to stamp.
    /// Every one of the three is bootstrap-only and 0-filtered. Another bootstrap
    /// writer must be too, and must be added to this list.
    ///
    /// ⚠ **RETRACTED (T4.S6b): writer 3 used to be `persistFolderUidValidity` in
    /// `SyncEngineDeletionReconcile.swift`, the deletion-reconcile walk's own
    /// bootstrap — the ONLY writer that existed in `v1.6.38`. It is GONE.** The walk
    /// now REFUSES to run against a folder with no stored epoch
    /// (`runDeletionReconcileWalk`, abort reason `"epoch unverified"`) instead of
    /// adopting its first chunk's SELECT epoch and deleting on that authority, so
    /// there is nothing left for it to persist. That refusal, not the write, is what
    /// closes the shipped mass-deletion path: with the `NOT EXISTS` term below the
    /// write was already a no-op for a populated folder, while the in-memory
    /// adoption would have kept deleting — strictly worse than before.
    ///
    /// ⚠ **FOURTH WRITER — the only one that OVERWRITES a non-nil value (T4.S6):**
    /// `AccountManager.uidValidityResetStampFreshEpoch`, step 5 of the
    /// purge-and-resync reaction (`AccountManagerUidValidityReset.swift`). It does
    /// NOT carry the `lastKnownUidValidity IS NULL` predicate, on purpose — its job
    /// is precisely to advance the column across a turnover. What makes that safe is
    /// that it discharges the precondition the predicate stands in for: step 3 has
    /// already DELETED every `messageHeader` row of the folder in its own committed
    /// transaction, so there are no local UIDs left for the new stamp to
    /// misdescribe, and the walk's abort guard has nothing to be disarmed over. It
    /// is reachable only from inside a reaction that armed
    /// `Folder.uidValidityResetPendingAt` (it re-reads and requires that flag in its
    /// own write), and it clears the flag in the SAME statement batch. A fifth
    /// writer that advanced without both halves would reintroduce ADR-IOS-051.
    ///
    /// ⚠ One path CLEARS the column and writes no value:
    /// `SyncEngine.resetEmptyFolderCrawlEpoch` (in the FILE
    /// `SyncEngineBackfillWalk.swift`) sets it — and `backfillUidCursor` — back to
    /// NULL for a folder whose `MessageHeader` count is zero IN THE SAME
    /// TRANSACTION, so the stamp it drops describes an empty set and asserts
    /// nothing. It exists because bootstrap-only monotonicity, on its own, makes a
    /// stale stamp on an EMPTY folder a permanent crawl refusal (round-9 blocker
    /// 1). It never writes a value: the re-stamp is this function's, on the crawl's
    /// next iteration, under the same gate as any other first bootstrap. Keep it
    /// that way — a clearer that also stamped would be the fourth value-writer and
    /// would have to carry every rule above.
    ///
    /// The `lastKnownUidValidity IS NULL` predicate belongs in the STATEMENT, not in
    /// a Swift `if` over a `Folder` row read earlier: every sync caller reads its row
    /// BEFORE a network round trip (STATUS/SELECT) and writes AFTER it, and the
    /// deletion-reconcile walk writes this same column from its own task. Deciding on
    /// the pre-suspension snapshot is a TOCTOU that would let a live epoch land on top
    /// of the epoch the local UIDs belong to — the exact overwrite that disarms the
    /// walk's abort guard (ADR-IOS-051). SQLite evaluates the predicate at write time,
    /// inside the writer's serialized transaction, so the race cannot be lost.
    ///
    /// `knownUidValidity` is applied HERE as well as at the STATUS/SELECT
    /// boundaries, so a `0` cannot reach the column even through a caller that
    /// forgot to normalise. That is belt-and-braces on purpose: a stored `0`
    /// makes every later epoch comparison `0 == 0` and therefore vacuous.
    ///
    /// 🚨 **T4.S6b — the `NOT EXISTS (SELECT 1 FROM messageHeader …)` term is the
    /// point of this function now, and it belongs in the STATEMENT for exactly the
    /// same reason `lastKnownUidValidity IS NULL` does.** `nil` in that column means
    /// UNKNOWN, never "empty/fresh folder": a folder populated before migration
    /// `v63` added the column, or one whose row was deleted on a remote
    /// disappearance and re-created for the same deterministic `accountId:path` id
    /// (re-adopting its orphaned headers — migration `v2` dropped the
    /// `messageHeader.folderId` FK), holds OLD-epoch rows under a nil epoch. The
    /// three-branch rule above then let the first observation ASSERT that those rows
    /// belong to the epoch just observed — and if the numbering had in fact turned
    /// over, that assertion is what disarms the deletion-reconcile walk's abort
    /// guard and turns it into a mass deleter (ADR-IOS-051, the shipped defect this
    /// item closes). Making the write IMPOSSIBLE at the SQL level covers every blind
    /// caller at once, including ones added later.
    ///
    /// The precedent for the predicate is already in-tree:
    /// `bootstrapCrawledFolderUidValidity` (`SyncEngineBackfillWalk.swift`) has
    /// carried the identical `localHeaders == 0` gate since T1.3, for the identical
    /// reason. That Swift-side gate is now redundant with this one and is KEPT — it
    /// is evaluated inside the same write transaction, so the two cannot disagree,
    /// and it documents the crawl's own precondition at the crawl's own call site.
    ///
    /// A folder that already holds rows is NOT abandoned: `SyncEngine
    /// .verifyAndBootstrapPrePopulatedFolderEpoch` samples its own rows against the
    /// live mailbox and, on proof, stamps through
    /// `bootstrapVerifiedFolderUidValidity`. Until that runs the column stays nil,
    /// which is the `IOS-EPOCH-001` accepted window (gestures refused, the reconcile
    /// walk refuses, NO data touched) — not data loss.
    nonisolated static func bootstrapFolderUidValidity(
        _ db: Database, folderId: String, observed: Int?
    ) throws {
        guard let epoch = knownUidValidity(observed) else { return }
        try db.execute(
            sql: """
                UPDATE folder SET lastKnownUidValidity = :epoch
                 WHERE id = :folderId
                   AND lastKnownUidValidity IS NULL
                   AND NOT EXISTS (SELECT 1 FROM messageHeader WHERE folderId = :folderId)
                """,
            arguments: ["epoch": epoch, "folderId": folderId]
        )
    }

    /// The VERIFIED bootstrap write — `bootstrapFolderUidValidity` minus ONLY the
    /// `NOT EXISTS` term, keeping `lastKnownUidValidity IS NULL`.
    ///
    /// ⚠ **Exactly ONE caller may ever exist**, and it is not a stylistic rule:
    /// `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`, which reaches here
    /// only after FETCHing a sample of the folder's OWN stored UIDs from the live
    /// mailbox and finding at least one whose normalized RFC-822 Message-ID still
    /// matches, with zero mismatches. That FETCH is what discharges the precondition
    /// the `NOT EXISTS` term stands in for — the same discipline
    /// `AccountManager.uidValidityResetStampFreshEpoch` follows when it advances a
    /// non-nil value (there the purge, here the proof). A second caller that skipped
    /// the proof would re-open the exact hazard the term exists to close.
    ///
    /// Still BOOTSTRAP-ONLY: `lastKnownUidValidity IS NULL` stays in the statement,
    /// so this can never overwrite an epoch the local UIDs already belong to, and a
    /// concurrent bootstrap that landed during the verification's network round trip
    /// wins (its value is by construction the one the rows are already judged
    /// against).
    nonisolated static func bootstrapVerifiedFolderUidValidity(
        _ db: Database, folderId: String, observed: Int?
    ) throws {
        guard let epoch = knownUidValidity(observed) else { return }
        _ = try Folder
            .filter(Column("id") == folderId && Column("lastKnownUidValidity") == nil)
            .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
    }

    /// `bootstrapFolderUidValidity(_:folderId:observed:)` in a transaction of its
    /// own, for callers that are not already inside one.
    func bootstrapFolderUidValidity(folderId: String, observed: Int?) async throws {
        guard Self.knownUidValidity(observed) != nil else { return }
        try await dbPool.write { db in
            try Self.bootstrapFolderUidValidity(db, folderId: folderId, observed: observed)
        }
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
            // T4.S6 re-drive: a folder left quarantined by an interrupted reaction
            // branches into the reaction rather than being delta-synced. Same
            // ownership rule as full sync's per-folder loop.
            if folder.uidValidityResetPendingAt != nil {
                await AccountManager.shared.runUidValidityResetReaction(
                    accountId: account.id, folderPath: folder.path
                )
                continue
            }
            let status = try await provider.folderStatus(path: folder.path)

            // T4.S6 free trigger: STATUS reports UIDVALIDITY at no extra cost on a
            // UIDPLUS server. Both sides must be KNOWN — a server that omits the
            // attribute yields no signal (nil), and a folder whose epoch has never
            // been bootstrapped has nothing to disagree with. This is a TRIGGER, not
            // a guard: it decides nothing about this folder's pass, and the reaction
            // it fires re-reads every value fresh rather than trusting these.
            if let observedStatusEpoch = Self.knownUidValidity(status.uidValidity).flatMap({ UInt32(exactly: $0) }),
               let storedEpoch = Self.knownUidValidity(folder.lastKnownUidValidity).flatMap({ UInt32(exactly: $0) }),
               observedStatusEpoch != storedEpoch {
                AccountManager.shared.fireUidValidityChangeHandler(
                    accountId: account.id, folderPath: folder.path,
                    storedValue: storedEpoch, observedValue: observedStatusEpoch
                )
                continue
            }

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
                // A QUIET folder is exactly the folder that would otherwise never get an
                // epoch: the changed-branch persist below never runs for it, and the
                // deletion-reconcile walk (the only other writer) only fires on a count
                // mismatch. BOOTSTRAP the observed UIDVALIDITY before the early return —
                // and only bootstrap: `uidValidityBootstrapWrite` returns nil the moment
                // the column holds anything, so the steady state opens no write at all and
                // a turnover can NEVER be stamped over the epoch the local UIDs belong to
                // (that would disarm the reconcile walk's abort guard — ADR-IOS-051).
                //
                // The pre-read check is a cheap early-out only (WAL etiquette: the steady
                // state opens no write transaction at all). The BINDING checks are the
                // `lastKnownUidValidity IS NULL` **and** `NOT EXISTS (… messageHeader …)`
                // predicates inside the UPDATE itself — `folder` was read BEFORE the
                // STATUS round trip suspended us, so its epoch is a stale snapshot and a
                // reentrant path (another sync pass, a merge, the NSE bridge) can have
                // bootstrapped the column OR inserted the folder's first row in between.
                // T4.S6b: a QUIET folder that already holds rows is therefore NOT stamped
                // here — the verified door owns that case.
                if Self.uidValidityBootstrapWrite(
                    observed: status.uidValidity, stored: folder.lastKnownUidValidity) != nil {
                    try await bootstrapFolderUidValidity(
                        folderId: folder.id, observed: status.uidValidity)
                }
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
                // BOOTSTRAP the epoch in the SAME transaction but as its OWN conditional
                // statement: the `lastKnownUidValidity IS NULL` predicate must be evaluated
                // by SQLite at write time, never against `folder` — that snapshot predates
                // the STATUS round trip, so it cannot decide whether the column is still
                // empty. Never an overwrite (see `uidValidityBootstrapWrite`): stamping a
                // live epoch over the one the local UIDs belong to disarms the
                // deletion-reconcile walk's abort guard (ADR-IOS-051).
                try Self.bootstrapFolderUidValidity(
                    db, folderId: folder.id, observed: status.uidValidity)
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
