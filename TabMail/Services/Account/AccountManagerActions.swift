/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountManager {

    // MARK: - Actions (optimistic UI + persistent queue)
    //
    // All actions update GRDB state immediately (optimistic UI) then queue the
    // remote operation for async execution. The queue drains when:
    // - NetworkMonitor detects connection restored
    // - Foreground return (SyncScheduler.startForegroundPolling)
    // - After each successful sync poll
    // - On app launch (reconcilePendingOperations → drainPendingQueue)
    //
    // If the server state changed after queueing (message moved/deleted remotely),
    // the queued operation is dropped (conflict detection in drainPendingQueue).

    func markRead(_ messages: [MessageHeader]) async {

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                let expanded = try Self.expandWithSiblingsByRfc822(messages: messages, db: db)
                let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let stableIds = msgs.map(\.stableId)
                    let msgIds = msgs.map(\.id)
                    let folderId = msgs[0].folderId
                    folderIds.insert(folderId)
                    let newlyRead = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: true))
                    if newlyRead > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
                    }
                    try PendingOperation(type: .markRead, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markRead write failed: \(error)")
            affectedFolderIds = []
        }
        // Clear delivered notifications for messages the user just read
        for msg in messages {
            NSEDataBridge.clearNotification(accountId: msg.accountId, messageId: msg.messageId)
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: the optimistic write above already decremented
        // folder.unreadCount, so the app-icon badge can update NOW (bg-task
        // protected) — without it, a read→immediate-background leaves the badge
        // stale until the next foreground recount.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    func markUnread(_ messages: [MessageHeader]) async {

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                // Mirror of markRead: expand to sibling rows in other folders so an
                // unread mark on the inbox copy of a self-send also flips the Sent copy.
                let expanded = try Self.expandWithSiblingsByRfc822(messages: messages, db: db)
                let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let stableIds = msgs.map(\.stableId)
                    let msgIds = msgs.map(\.id)
                    // Count unread BEFORE marking unread — fresh DB read to compute delta
                    let folderId = msgs[0].folderId
                    folderIds.insert(folderId)
                    let alreadyUnread = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    let newlyUnread = msgIds.count - alreadyUnread
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: false))
                    if newlyUnread > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
                    }
                    try PendingOperation(type: .markUnread, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markUnread write failed: \(error)")
            affectedFolderIds = []
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: optimistic write already adjusted folder.unreadCount,
        // so the badge updates NOW (bg-task protected) and survives a quick background.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    // MARK: - Unread Count Helpers

    /// Count currently-unread messages from the DB inside an active transaction.
    /// Always re-reads from DB to avoid stale-snapshot races (e.g., markRead + move
    /// firing as concurrent Tasks — the second write must see the first's committed state).
    private nonisolated static func countCurrentlyUnread(msgIds: [String], db: Database) throws -> Int {
        guard !msgIds.isEmpty else { return 0 }
        let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
            arguments: StatementArguments(msgIds)) ?? 0
    }

    /// Expand a list of messages to also include sibling rows that share the same
    /// `(accountId, rfc822MessageId)` but live in a different folder.
    ///
    /// Why: Gmail (and any IMAP server with shared message storage) represents a
    /// "send to self" as one underlying message that lives in both INBOX and Sent.
    /// On iOS we materialize that as two `MessageHeader` rows (keyed by folderId).
    /// When the user marks one row read, the other row should optimistically flip
    /// too — otherwise the Sent copy looks unread until the next delta sync.
    ///
    /// This is also correct for non-Gmail IMAP servers where self-send creates two
    /// independent UIDs: each sibling becomes its own per-folder group, so the
    /// caller's grouping logic emits a separate `PendingOperation` per folder, and
    /// the drain loop issues the appropriate STORE / API call against each.
    ///
    /// Sync acts as the safety net — if a sibling is missed (e.g., null or stale
    /// `rfc822MessageId`), the next delta sync reconciles it.
    nonisolated static func expandWithSiblingsByRfc822(
        messages: [MessageHeader],
        db: Database
    ) throws -> [MessageHeader] {
        // Group rfc822MessageIds by accountId (sibling lookups never cross accounts).
        var lookups: [String: Set<String>] = [:]
        for msg in messages {
            guard let rfc = msg.rfc822MessageId, !rfc.isEmpty else { continue }
            lookups[msg.accountId, default: []].insert(rfc)
        }
        if lookups.isEmpty { return messages }

        var seenIds = Set(messages.map(\.id))
        var result = messages
        for (accountId, rfcSet) in lookups {
            let rfcArray = Array(rfcSet)
            let placeholders = rfcArray.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [accountId]
            args.append(contentsOf: rfcArray)
            let siblings = try MessageHeader.fetchAll(
                db,
                sql: "SELECT * FROM messageHeader WHERE accountId = ? AND rfc822MessageId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            for sibling in siblings where !seenIds.contains(sibling.id) {
                result.append(sibling)
                seenIds.insert(sibling.id)
            }
        }
        return result
    }

    // MARK: - Optimistic Move (shared by archive, delete, move)

    /// Core optimistic move: reassigns messages to the destination folder in GRDB,
    /// queues tag removal if leaving inbox, and queues the PendingOperation.
    /// Unread counts are adjusted inline (same transaction) for immediate UI feedback.
    /// UnreadCountManager async recount serves as safety net.
    /// Post-drain sync reconciles UIDs via stale detection + UID remap.
    ///
    /// Gmail-specific: archive destination is the synthetic "__GMAIL_ALL_MAIL__" folder;
    /// the provider-level archive just removes the INBOX label. The optimistic folder
    /// assignment works the same regardless.
    /// Returns the set of affected folder IDs (source + destination) for unread recount.
    @discardableResult
    private nonisolated static func optimisticMoveToFolder(
        msgs: [MessageHeader],
        accountId: String,
        folderPath: String,
        destinationPath: String,
        opType: OperationType,
        removeTagsIfLeavingInbox: Bool,
        db: Database
    ) throws -> Set<String> {
        // Self-move is a no-op — don't create PendingOperation or touch local state.
        // Happens when archiving from All Mail on Gmail (source=dest=__GMAIL_ALL_MAIL__).
        guard folderPath != destinationPath else {
            print("[Queue] Skipping no-op move (source==dest): \(folderPath)")
            return []
        }
        let stableIds = msgs.map(\.stableId)
        let leavingInbox = msgs[0].isInInbox

        // Queue tag removal BEFORE the move — FIFO ordering ensures correct execution.
        // IMAP MOVE copies flags, so keyword must be gone before COPY.
        if removeTagsIfLeavingInbox && leavingInbox {
            for msg in msgs where msg.actionTag != nil {
                try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: accountId, folderPath: folderPath, tagValue: msg.actionTag?.rawValue).insert(db)
            }
        }

        // Optimistic local update — move to destination folder immediately.
        // Message appears in destination right away; post-drain sync reconciles UIDs.
        let destFolderId = "\(accountId):\(destinationPath)"
        let destFolder = try Folder.fetchOne(db, key: destFolderId)
        let destIsInbox = destFolder?.role == .inbox

        let msgIds = msgs.map(\.id)
        try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
            Column("folderId").set(to: destFolderId),
            Column("folderPath").set(to: destinationPath),
            Column("isInInbox").set(to: destIsInbox)
        )

        // Inline unread count update — fresh DB read, not stale snapshot.
        // Re-read isRead from DB to avoid double-decrement when markRead + move race.
        let unreadMoving = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
        if unreadMoving > 0 {
            let sourceFolderId = msgs[0].folderId
            try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
            try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
        }

        try PendingOperation(type: opType, messageIds: stableIds, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath).insert(db)
        print("[Queue] Queued \(opType.rawValue) for \(stableIds.count) msgs: \(folderPath) → \(destinationPath) (account: \(accountId))")
        return [msgs[0].folderId, destFolderId]
    }

    func move(_ messages: [MessageHeader], to destinationPath: String) async {
        // Same-folder move is a no-op. Drop those messages here — the single
        // choke point for every surface (swipe, detail view, agent tools) —
        // so we never queue a pointless PendingOperation whose server-side
        // MOVE has provider-dependent effects (e.g. archive-from-Archive).
        let movable = messages.filter { $0.folderPath != destinationPath }
        guard !movable.isEmpty else { return }

        let grouped = Dictionary(grouping: movable) { "\($0.accountId)|\($0.folderPath)" }
        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let moved = try Self.optimisticMoveToFolder(msgs: msgs, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath, opType: .move, removeTagsIfLeavingInbox: true, db: db)
                    folderIds.formUnion(moved)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: move write failed: \(error)")
            affectedFolderIds = []
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds) }
        Task { await drainPendingQueue() }
    }

    func markFlagged(_ messages: [MessageHeader], flagged: Bool) async {

        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
        do {
            try await dbPool.write { db in
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let stableIds = msgs.map(\.stableId)
                    for msg in msgs {
                        try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [flagged, msg.id])
                    }
                    let opType: OperationType = flagged ? .markFlagged : .markUnflagged
                    try PendingOperation(type: opType, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
            }
        } catch {
            print("[Queue] ERROR: markFlagged write failed: \(error)")
        }
        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }
        Task { await drainPendingQueue() }
    }

    /// Drop messages whose CURRENT folder already has `role` — same-role moves
    /// (archive-from-Archive, delete-from-Trash) are no-ops. Accounts can carry
    /// more than one folder per role (e.g. iCloud "Trash" + "Deleted Messages"),
    /// so the path-equality filter in `move()` alone can't catch these: the
    /// canonical `fetchOne` destination may be the OTHER same-role folder.
    private func messagesNotInRole(_ messages: [MessageHeader], role: FolderRole) async -> [MessageHeader] {
        let folderIds = Set(messages.map(\.folderId))
        let roleFolderIds: Set<String> = (try? await dbPool.read { db in
            let rows = try Folder
                .filter(folderIds.contains(Column("id")) && Column("role") == role.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.id))
        }) ?? []
        guard !roleFolderIds.isEmpty else { return messages }
        return messages.filter { !roleFolderIds.contains($0.folderId) }
    }

    func archive(_ messages: [MessageHeader]) async {
        let movable = await messagesNotInRole(messages, role: .archive)
        guard let first = movable.first else { return }
        let archivePath: String? = try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == first.accountId && Column("role") == FolderRole.archive.rawValue)
                .fetchOne(db)?.path
        }
        guard let archivePath else {
            print("[Queue] ERROR: no archive folder found for account \(first.accountId)")
            return
        }
        await move(movable, to: archivePath)
    }

    func delete(_ messages: [MessageHeader]) async {
        guard let first = messages.first else { return }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "AccountManager.delete")
        let movable = await messagesNotInRole(messages, role: .trash)
        guard let firstMovable = movable.first else { return }
        let trashPath: String? = try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == firstMovable.accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchOne(db)?.path
        }
        guard let trashPath else {
            print("[Queue] ERROR: no trash folder found for account \(firstMovable.accountId)")
            return
        }
        await move(movable, to: trashPath)
    }

    /// Diagnostic-only: log the trash-folder lookup result and the message(s) being deleted
    /// so we can correlate a delete action with the destinationPath that ends up on the
    /// PendingOperation. Includes every role=.trash candidate to surface duplicate or
    /// cross-account contamination.
    /// `callSite` identifies the entry point (multiple code paths queue a delete).
    static nonisolated func logDeleteTrace(accountId: String, messages: [MessageHeader], callSite: String) {
        let allTrash: [Folder] = (try? AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchAll(db)
        }) ?? []
        let trashFolder = allTrash.first
        print("[DeleteTrace] \(callSite) — accountId=\(accountId) msgCount=\(messages.count) resolvedTrash=\(trashFolder.map { "id=\($0.id) name=\($0.name) path=\($0.path) role=\($0.role.rawValue)" } ?? "<nil>") trashCandidates=\(allTrash.count)")
        for f in allTrash {
            print("[DeleteTrace] trashCandidate: id=\(f.id) name=\(f.name) path=\(f.path)")
        }
        for m in messages {
            print("[DeleteTrace] msg: id=\(m.id) folderPath=\(m.folderPath) accountId=\(m.accountId) messageId=\(m.messageId) rfc822=\(m.rfc822MessageId ?? "<nil>") stableId=\(m.stableId)")
        }
    }

    // MARK: - Search

    func search(query: String, account: Account, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        guard let queue = workQueues[account.id] else { throw ProviderError.notConnected }
        return try await queue.execute(priority: .userAction) {
            try await queue.provider.search(query: query, folder: folder, after: after, before: before, from: from, to: to)
        }
    }

    // MARK: - Undo Support

    /// Unified undo for archive, delete, and move. Cancels queued ops if still pending,
    /// otherwise queues a move-back. Restores messages to original folder and adjusts
    /// unread counts on both source (current) and destination (original) folders.
    func undoDestructiveAction(
        _ messages: [MessageHeader],
        accountId: String,
        originalOpType: OperationType,
        fromFolderPath: String,
        toFolderPath: String,
        toFolderId: String
    ) async {
        let ids = messages.map(\.messageId)
        let idsSet = Set(ids)
        let stableIdsSet = Set(messages.map(\.stableId))
        let label = originalOpType.rawValue
        print("[UndoStack] undo\(label) ENTER — msgIds=\(ids) from=\(fromFolderPath) restoreTo=\(toFolderPath) restoreFolderId=\(toFolderId)")
        do {
            try await dbPool.write { db in
                let queuedOps = try PendingOperation
                    .filter(Column("accountId") == accountId)
                    .filter(Column("status") == PendingStatus.queued.rawValue)
                    .fetchAll(db)
                print("[UndoStack] undo\(label) — found \(queuedOps.count) queued ops for account")
                for op in queuedOps {
                    print("[UndoStack] undo\(label) — queued op: id=\(op.id.prefix(8)) type=\(op.type.rawValue) msgIds=\(op.messageIds) status=\(op.status)")
                }

                let inFlightOps = try PendingOperation
                    .filter(Column("accountId") == accountId)
                    .filter(Column("status") == PendingStatus.inFlight.rawValue)
                    .fetchAll(db)
                if !inFlightOps.isEmpty {
                    print("[UndoStack] undo\(label) — WARNING: \(inFlightOps.count) inFlight ops:")
                    for op in inFlightOps {
                        print("[UndoStack]   inFlight: id=\(op.id.prefix(8)) type=\(op.type.rawValue) msgIds=\(op.messageIds)")
                    }
                }

                var cancelledOriginal = false
                for op in queuedOps {
                    let opMsgIds = Set(op.messageIds)
                    // Match by both numeric UIDs and stable IDs (rfc822MessageId)
                    // since pending ops may contain either format.
                    if (!opMsgIds.isDisjoint(with: idsSet) || !opMsgIds.isDisjoint(with: stableIdsSet)) &&
                       (op.type == originalOpType || op.type == .removeTag) {
                        var cancelled = op
                        cancelled.status = PendingStatus.cancelled.rawValue
                        try cancelled.save(db)
                        print("[UndoStack] undo\(label) — CANCELLED op id=\(op.id.prefix(8)) type=\(op.type.rawValue)")
                        if op.type == originalOpType { cancelledOriginal = true }
                    }
                }

                // Restore messages — use save() (upsert) in case drain cleanup already deleted the row.
                // The snapshot's folderPath/isInInbox are from the original source folder — save() restores all columns.
                for msg in messages {
                    let existing = try MessageHeader.fetchOne(db, key: msg.id)
                    print("[UndoStack] undo\(label) — restore msg id=\(msg.id) existing=\(existing == nil ? "nil(deleted)" : "folderId=\(existing!.folderId)") → setting folderId=\(toFolderId)")
                    var restored = msg
                    restored.folderId = toFolderId
                    try restored.save(db)
                }

                // Inline unread count update — fresh DB read after restore.
                // Messages were just restored via save(db) above, so re-read their
                // current isRead state from DB rather than trusting the caller snapshot.
                let restoredMsgIds = messages.map(\.id)
                let unreadRestored = try Self.countCurrentlyUnread(msgIds: restoredMsgIds, db: db)
                if unreadRestored > 0 {
                    let fromFolderId = "\(accountId):\(fromFolderPath)"
                    if !fromFolderPath.isEmpty {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadRestored, fromFolderId])
                    }
                    try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadRestored, toFolderId])
                }

                if !cancelledOriginal {
                    // IMAP MOVE changes UIDs — use rfc822MessageId for move-back so resolveUID
                    // does a Message-ID header search in the destination folder (finds correct UID).
                    // Gmail/Exchange use stable IDs that don't change on move.
                    let account = try Account.fetchOne(db, key: accountId)
                    let moveBackIds: [String]
                    if account?.provider == .imap || account?.provider == .icloud {
                        moveBackIds = messages.compactMap(\.rfc822MessageId)
                        if moveBackIds.count != messages.count {
                            print("[UndoStack] undo\(label) — WARNING: \(messages.count - moveBackIds.count) messages missing rfc822MessageId for move-back")
                        }
                    } else {
                        moveBackIds = ids
                    }
                    if !moveBackIds.isEmpty {
                        let moveBack = PendingOperation(type: .move, messageIds: moveBackIds, accountId: accountId, folderPath: fromFolderPath, destinationPath: toFolderPath)
                        try moveBack.insert(db)
                        print("[UndoStack] undo\(label) — original already executed/inFlight, queued MOVE-BACK id=\(moveBack.id.prefix(8)) from=\(fromFolderPath) to=\(toFolderPath) moveBackIds=\(moveBackIds)")
                    } else {
                        print("[UndoStack] undo\(label) — ERROR: no valid IDs for move-back (missing rfc822MessageId)")
                    }
                } else {
                    print("[UndoStack] undo\(label) — CANCELLED original \(label) op, no move-back needed")
                }
            }
        } catch {
            print("[UndoStack] ERROR: undo\(label) write failed: \(error)")
        }
        // Undo-restored messages are protected by their PendingOp(move-back) in the sync engine.
        // No separate undoProtectedIds needed — the pending-op check handles it.
        let fromFolderId = "\(accountId):\(fromFolderPath)"
        var affectedFolderIds: Set<String> = [toFolderId]
        if !fromFolderPath.isEmpty { affectedFolderIds.insert(fromFolderId) }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil) }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds) }
        Task {
            print("[UndoStack] undo\(label) — triggering drainPendingQueue (isDraining=\(isDraining))")
            await drainPendingQueue()
        }
    }

    // MARK: - Draft Queue (persistent save/delete)

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) async throws -> String {
        try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }

    /// Queue a draft save to the server's Drafts folder via PendingOperation.
    /// Creates/updates an optimistic MessageHeader in the Drafts folder so the draft
    /// appears immediately in the UI (before IMAP APPEND completes).
    func queueDraftSave(draftId: String, accountId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)

            // Write transaction returns FTS data for post-transaction indexing.
            let ftsInfo: (record: FTSHeaderRecord, bodyText: String)? = try await dbPool.write { db -> (FTSHeaderRecord, String)? in
                // Optimistic MessageHeader — draft appears in Drafts folder immediately.
                // Uses rfc822MessageId for dedup when sync brings in the real IMAP UID.
                guard let draft = try Draft.fetchOne(db, key: draftId) else {
                    print("[Queue] WARNING: Draft \(draftId) not found in DB, skipping queueDraftSave")
                    return nil
                }

                let folderId = "\(accountId):\(folderPath)"
                var rfc822 = draft.rfc822MessageId

                // Adopt the server-synced header if present. This catches the
                // ServerDraftCompose case: a draft was created by server sync
                // with its own rfc822MessageId (from the IMAP/Gmail header)
                // and a server-assigned messageId. Draft.rfc822MessageId on
                // the matched local Draft row is nil, so a naive
                // "generate new rfc822 + create optimistic header" path
                // produces an orphan next to the server-synced header. The
                // sync stale-check then deletes our optimistic orphan, the
                // list reverts to the pre-edit server-synced header, and the
                // user sees stale content.
                //
                // Resolution: if the draft has serverDraftId, find the
                // existing server-synced MessageHeader by its PK and adopt
                // its rfc822MessageId for the Draft row. The update branch
                // below then finds that same header and updates it in place.
                if rfc822 == nil, let sid = draft.serverDraftId {
                    let serverHeaderId = "\(accountId):\(folderPath):\(sid)"
                    if let serverHeader = try MessageHeader.fetchOne(db, key: serverHeaderId),
                       let serverRfc822 = serverHeader.rfc822MessageId,
                       !serverRfc822.isEmpty {
                        rfc822 = serverRfc822
                        try db.execute(
                            sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?",
                            arguments: [rfc822, draftId]
                        )
                        print("[Queue] queueDraftSave: adopted rfc822 from server header \(serverHeaderId) → \(serverRfc822)")
                    } else {
                        print("[Queue] queueDraftSave: no server header found for serverDraftId=\(sid) — will generate fresh rfc822")
                    }
                }

                // Generate stable rfc822MessageId if still not assigned (fresh local draft).
                if rfc822 == nil {
                    let domain = accountId.contains("@") ? String(accountId.split(separator: "@").last ?? "tabmail.local") : "tabmail.local"
                    rfc822 = "draft-\(UUID().uuidString)@\(domain)"
                    // Persist to Draft table so pushDraftToServer reuses it
                    try db.execute(sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?", arguments: [rfc822, draftId])
                }
                // Placeholder messageId — will be replaced by real IMAP UID via rfc822MessageId dedup in sync
                let placeholderMsgId = "draft-\(draftId)"
                let headerId = "\(accountId):\(folderPath):\(placeholderMsgId)"
                let senderAccount = try Account.fetchOne(db, key: accountId)
                let senderEmail = senderAccount?.emailAddress ?? accountId
                let senderDisplayName = senderAccount?.displayName ?? senderEmail
                let snippet = EmailFilter.snippetFromPlainText(draft.body)
                let dateMs = Int64(draft.updatedAt * 1000)

                var capturedHeaderId: String
                var capturedMessageId: String

                // Lookup strategy:
                //   1. By rfc822MessageId — the primary dedup key across sync/optimistic paths.
                //   2. By serverDraftId (constructed PK) — catches the ServerDraftCompose
                //      case where a local Draft row exists but its rfc822MessageId wasn't
                //      adopted above (e.g. server header was deleted but Draft persisted).
                var lookedUp = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchOne(db)
                if lookedUp == nil, let sid = draft.serverDraftId {
                    lookedUp = try MessageHeader.fetchOne(
                        db, key: "\(accountId):\(folderPath):\(sid)"
                    )
                }
                if var existing = lookedUp {
                    // Update existing header (either optimistic or server-synced) in place —
                    // this is the snippet/subject/recipient refresh path. No orphan created.
                    print("[Queue] queueDraftSave: updating existing header id=\(existing.id) msgId=\(existing.messageId) rfc822=\(existing.rfc822MessageId ?? "nil") → newSnippet=\(String(snippet.prefix(60)))")
                    existing.subject = draft.subject
                    existing.to = draft.toArray.joined(separator: ", ")
                    existing.snippet = snippet
                    existing.date = Date(timeIntervalSince1970: draft.updatedAt)
                    // Ensure rfc822MessageId is populated so subsequent syncs can dedup.
                    if existing.rfc822MessageId == nil || existing.rfc822MessageId?.isEmpty == true {
                        existing.rfc822MessageId = rfc822
                    }
                    try existing.update(db)
                    // Update body so draft content is viewable immediately
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: existing.id, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = existing.id
                    capturedMessageId = existing.messageId
                } else {
                    print("[Queue] queueDraftSave: no existing header found — creating optimistic with placeholder=\(placeholderMsgId) rfc822=\(rfc822 ?? "nil") serverDraftId=\(draft.serverDraftId ?? "nil")")
                    var header = MessageHeader(
                        messageId: placeholderMsgId,
                        subject: draft.subject,
                        from: senderDisplayName,
                        fromAddress: senderEmail,
                        to: draft.toArray.joined(separator: ", "),
                        date: Date(timeIntervalSince1970: draft.updatedAt),
                        snippet: snippet,
                        folderId: folderId,
                        accountId: accountId,
                        folderPath: folderPath,
                        isInInbox: false
                    )
                    header.rfc822MessageId = rfc822
                    header.cc = draft.ccArray.joined(separator: ", ")
                    header.bcc = draft.bccArray.joined(separator: ", ")
                    header.isRead = true // Drafts are always read
                    try header.insert(db)

                    // Also create MessageBody so draft content is viewable
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: headerId, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = headerId
                    capturedMessageId = placeholderMsgId
                }

                // Include both draftId (for drain execution) and placeholder messageId
                // (for pendingAllIds protection). The stale check uses pendingAllIds to
                // protect optimistic headers from deletion while the push is pending.
                // This is critical for offline support — the drain can't run until
                // back online, but sync might try to clean up the placeholder.
                let opPlaceholder = "draft-\(draftId)"
                var opMsgIds = [draftId, opPlaceholder]
                // Also include rfc822MessageId for rfc822-based protection matching
                // (rfc822 is guaranteed non-nil here — either from draft or freshly generated)
                if let rfc822Id = rfc822 {
                    opMsgIds.append(rfc822Id)
                }
                try PendingOperation(
                    type: .saveDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)

                return (FTSHeaderRecord(
                    headerId: capturedHeaderId,
                    messageId: capturedMessageId,
                    subject: draft.subject,
                    from: "\(senderDisplayName) <\(senderEmail)>",
                    to: draft.toArray.joined(separator: ", "),
                    cc: draft.ccArray.joined(separator: ", "),
                    bcc: draft.bccArray.joined(separator: ", "),
                    dateMs: dateMs,
                    folderId: folderId
                ), draft.body)
            }

            // FTS indexing + headerComplete — runs after GRDB write succeeds.
            // Each step is independently caught so a failure in one doesn't block the others.
            // Priority: headerComplete=1 (visibility) > FTS body (searchability) > FTS header.
            if let ftsInfo {
                do {
                    _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                    if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await SearchIndex.shared.updateBodies([(headerId: ftsInfo.record.headerId, body: ftsInfo.bodyText)])
                    }
                } catch {
                    print("[Queue] WARNING: FTS indexing failed for draft \(ftsInfo.record.headerId): \(error)")
                }
                // Always set headerComplete=1 so the draft appears in folder queries,
                // regardless of whether FTS succeeded. Caught separately so notification
                // still fires even if this write fails (draft stays at headerComplete=0
                // but user gets the reload signal).
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                            arguments: [ftsInfo.record.headerId]
                        )
                    }
                } catch {
                    print("[Queue] WARNING: headerComplete write failed for draft \(ftsInfo.record.headerId): \(error)")
                }
            }

            // Always post reload notification — even if FTS or headerComplete failed,
            // the GRDB header + body exist and may become visible on retry.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftSave failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Queue a draft delete from the server's Drafts folder via PendingOperation.
    /// Optimistically removes the MessageHeader from the Drafts folder immediately.
    /// Requires the serverDraftId (IMAP UID / Gmail ID) from the Draft record.
    /// Pass rfc822MessageId to also remove optimistic headers (which use placeholder messageIds).
    func queueDraftDelete(serverDraftId: String, accountId: String, rfc822MessageId: String? = nil) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            try await dbPool.write { db in
                // Optimistic removal — draft disappears from UI immediately
                let folderId = "\(accountId):\(folderPath)"
                // Remove by server UID (synced header)
                let serverId = "\(accountId):\(folderPath):\(serverDraftId)"
                if try MessageHeader.deleteOne(db, key: serverId) {
                    _ = try? MessageBody.deleteOne(db, key: serverId)
                }
                // Also remove optimistic header by rfc822MessageId (placeholder UID)
                if let rfc822 = rfc822MessageId {
                    let optimistic = try MessageHeader
                        .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                        .fetchAll(db)
                    for header in optimistic {
                        _ = try? MessageBody.deleteOne(db, key: header.id)
                        try header.delete(db)
                    }
                }

                // Include rfc822MessageId in the PendingOperation messageIds so
                // sync protection (pendingAllIds) prevents re-inserting a stale draft
                // from the server during the brief window before .deleteDraft drains.
                // Matches the protection pattern in queueDraftSave.
                var opMsgIds = [serverDraftId]
                if let rfc822 = rfc822MessageId {
                    opMsgIds.append(rfc822)
                }
                try PendingOperation(
                    type: .deleteDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)
            }
            // Refresh UI so the optimistic removal is visible immediately.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftDelete failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Remove optimistic draft MessageHeader (no server op needed — draft was never pushed).
    func removeOptimisticDraftHeader(accountId: String, rfc822MessageId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            let folderId = "\(accountId):\(folderPath)"
            try await dbPool.write { db in
                let headers = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822MessageId)
                    .fetchAll(db)
                for header in headers {
                    _ = try? MessageBody.deleteOne(db, key: header.id)
                    try header.delete(db)
                }
            }
        } catch {
            print("[Queue] ERROR: removeOptimisticDraftHeader failed: \(error)")
        }
    }

}
